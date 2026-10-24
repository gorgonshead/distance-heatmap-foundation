-- Tests for the mod's logic, runnable outside the game with Lua 5.1 or LuaJIT:
--   lua tests/run.lua            (from the repository root)
-- or through Python with the lupa package: python tests/run_lupa.py

ROOT = ROOT or "."
package.path = ROOT .. "/tests/?.lua;" .. package.path

local fake = dofile(ROOT .. "/tests/fake_engine.lua")

local failures, passed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
	else
		failures = failures + 1
		print("FAIL " .. name .. ": " .. tostring(err))
	end
end
local function near(a, b, tolerance, what)
	if math.abs(a - b) > tolerance then
		error(string.format("%s: expected %.4f, got %.4f", what or "value", b, a), 2)
	end
end

-- Loads the whole mod through mod.lua against a fresh fake engine.
local function loadMod(cfgOverrides)
	local mod = fake.newMod(ROOT)
	foundation.createMod = function() return mod end
	PathHeatmapOverlay = nil
	local chunk = assert(loadfile(ROOT .. "/PathHeatmap/mod.lua"))
	-- Apply overrides between config load and the rest: patch dofile.
	local original = mod.dofile
	function mod:dofile(path, ...)
		local result = original(self, path, ...)
		if path == "scripts/config.lua" and cfgOverrides then
			for k, v in pairs(cfgOverrides) do PathHeatmap.cfg[k] = v end
		end
		return result
	end
	chunk()
	return mod
end

-- Sets cells walked along a list of cells, each with the given weight.
local function walk(cells, weight)
	local grid = PathHeatmap.grid
	for _, c in ipairs(cells) do
		grid.addSample((c[1] + 0.5) * grid.CELL, 10, (c[2] + 0.5) * grid.CELL, weight or 2)
	end
end

local function line(x0, z0, x1, z1)
	local cells = {}
	local steps = math.max(math.abs(x1 - x0), math.abs(z1 - z0))
	for i = 0, steps do
		local t = steps == 0 and 0 or i / steps
		cells[#cells + 1] = { math.floor(x0 + (x1 - x0) * t + 0.5), math.floor(z0 + (z1 - z0) * t + 0.5) }
	end
	return cells
end

local function runJob(job, budget)
	local steps = 0
	while not job.step(budget) do
		steps = steps + 1
		assert(steps < 1e6, "job did not finish")
	end
	return steps
end

local function search(points, budget)
	local job = PathHeatmap.newSearchJob(points)
	runJob(job, budget or math.huge)
	return job.dist, job
end

local function pointAt(cx, cz, radius)
	local C = PathHeatmap.grid.CELL
	return { x = (cx + 0.5) * C, z = (cz + 0.5) * C, radius = radius or 1 }
end

-- Grid ----------------------------------------------------------------------------

test("loads with no errors or warnings", function()
	local mod = loadMod()
	assert(#mod.errors == 0, table.concat(mod.errors, "; "))
	assert(#mod.warnings == 0, table.concat(mod.warnings, "; "))
	assert(mod.classes.COMP_PATH_SAMPLER, "sampler class registered")
	local systems = 0
	for id in pairs(mod.assets) do
		if string.sub(id, 1, 12) == "PATHHEAT_PS_" then systems = systems + 1 end
	end
	assert(systems == 27, "27 particle systems, got " .. systems)
end)

test("weight halves every half-life", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	grid.configureDecay(60)
	grid.addSample(1, 0, 1, 2)
	local key = grid.keyAt(1, 1)
	near(grid.weightAt(key), 2, 1e-9, "fresh")
	grid.setTime(grid.halfLife)
	near(grid.weightAt(key), 1, 1e-9, "one half-life")
	grid.setTime(grid.halfLife * 3)
	near(grid.weightAt(key), 0.25, 1e-9, "three half-lives")
end)

test("weight is capped", function()
	loadMod()
	local grid, cfg = PathHeatmap.grid, PathHeatmap.cfg
	grid.reset()
	for _ = 1, 100 do grid.addSample(1, 0, 1, 1) end
	near(grid.weightAt(grid.keyAt(1, 1)), cfg.MAX_WEIGHT, 1e-9, "capped")
end)

test("prune drops faded cells and rebasing keeps weights", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	grid.configureDecay(60)
	grid.addSample(1, 0, 1, 0.3) -- fades below walkable quickly
	grid.addSample(11, 0, 11, 6)
	local strong = grid.keyAt(11, 11)
	-- Jump far ahead so the gain passes the rebase threshold.
	local t = grid.halfLife * 31
	grid.setTime(t)
	local before = grid.weightAt(strong)
	local removed = grid.prune()
	assert(removed >= 1, "faded cell removed")
	assert(grid.weights[grid.keyAt(1, 1)] == nil, "faded cell gone")
	if before >= PathHeatmap.cfg.ACTIVE_WEIGHT then
		near(grid.weightAt(strong), before, 1e-9, "weight after rebase")
	end
	assert(grid.gain < 2, "gain rebased, got " .. grid.gain)
end)

test("rebase keeps walkable cells walkable", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	grid.configureDecay(60)
	local t = grid.halfLife * 31
	grid.setTime(t)
	grid.addSample(1, 0, 1, 3)
	local key = grid.keyAt(1, 1)
	grid.prune()
	near(grid.weightAt(key), 3, 1e-9, "weight after rebase")
	assert(grid.isActive(key), "still walkable")
end)

test("save format v2 round trip", function()
	loadMod()
	local grid, cfg = PathHeatmap.grid, PathHeatmap.cfg
	grid.reset()
	math.randomseed(7)
	local expected = {}
	for _ = 1, 3000 do
		local cx, cz = math.random(-300, 900), math.random(-200, 1200)
		local key = grid.keyOf(cx, cz)
		local w = 0.3 + math.random() * (cfg.MAX_WEIGHT - 0.3)
		local h = -40 + math.random() * 300
		grid.weights[key] = w
		grid.heights[key] = h
		expected[key] = { w, h }
	end
	local str = grid.export()
	assert(string.sub(str, 1, 3) == "v2;", "v2 header")
	local count = 0
	for _ in pairs(expected) do count = count + 1 end
	grid.reset()
	local n, err = grid.import(str)
	assert(err == nil, err)
	assert(n == count, string.format("restored %d of %d", n, count))
	for key, v in pairs(expected) do
		near(grid.weightAt(key), v[1], cfg.MAX_WEIGHT / 63 / 2 + 1e-9, "weight")
		near(grid.heights[key], v[2], 0.125 + 1e-9, "height")
	end
end)

test("save format stays near 5 characters per cell on trails", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	-- A 3-cell-wide road network: contiguous runs, like real trails.
	for x = 0, 400 do for z = 0, 2 do grid.weights[grid.keyOf(x, z + 100)] = 2 end end
	for z = 0, 400 do for x = 0, 2 do grid.weights[grid.keyOf(x + 200, z)] = 2 end end
	local count = 0
	for _ in pairs(grid.weights) do count = count + 1 end
	local str = grid.export()
	assert(#str < count * 5.5, string.format("%d chars for %d cells", #str, count))
end)

test("chunked export matches one-shot export", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	for i = 1, 2000 do grid.weights[grid.keyOf(i % 97, math.floor(i / 97))] = 1 end
	local whole = grid.export()
	local job = grid.newExportJob()
	runJob(job, 7)
	assert(job.result == whole, "same string")
end)

test("damaged save keeps what it read and reports", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	grid.weights[grid.keyOf(1, 1)] = 1
	grid.weights[grid.keyOf(1, 2)] = 1
	local str = grid.export()
	grid.reset()
	local n, err = grid.import(string.sub(str, 1, #str - 2) .. "!!")
	assert(err ~= nil, "error reported")
	assert(n == 1, "first cell kept, got " .. n)
end)

-- Distance search ------------------------------------------------------------------

test("distance along a straight corridor", function()
	loadMod()
	PathHeatmap.grid.reset()
	walk(line(0, 0, 70, 0))
	local dist = search({ pointAt(0, 0, 0.5) })
	local key = PathHeatmap.grid.keyOf(50, 0)
	near(dist[key], 100, 0.01, "50 cells east")
	assert(dist[PathHeatmap.grid.keyOf(80, 0)] == nil, "unwalked cell not reached")
end)

test("distance at an odd angle is within 3% of straight-line", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	-- A two-cell-wide trail at about 22 degrees.
	local cells = line(0, 0, 60, 24)
	walk(cells)
	local shifted = {}
	for _, c in ipairs(cells) do shifted[#shifted + 1] = { c[1], c[2] + 1 } end
	walk(shifted)
	local dist = search({ pointAt(0, 0, 0.5) })
	local d = dist[grid.keyOf(60, 24)]
	assert(d, "end reached")
	local straight = math.sqrt(60 * 60 + 24 * 24) * grid.CELL
	assert(d <= straight * 1.03, string.format("%.1f m against %.1f m straight", d, straight))
end)

test("separate parallel trails stay separate", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	walk(line(0, 0, 40, 0))
	walk(line(0, 2, 40, 2)) -- one empty row between
	local dist = search({ pointAt(0, 0, 0.5) })
	assert(dist[grid.keyOf(20, 2)] == nil, "second trail not reached")
end)

test("faded cells do not connect", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	walk(line(0, 0, 40, 0), 0.1) -- below ACTIVE_WEIGHT
	local dist = search({ pointAt(0, 0, 0.5) })
	assert(dist == nil, "no walkable seed")
end)

test("search is the same at any budget", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	for x = 0, 40 do for z = 0, 30 do
		if (x * 7 + z * 3) % 5 ~= 0 then walk({ { x, z } }) end
	end end
	local whole = search({ pointAt(5, 5, 4) })
	local sliced = search({ pointAt(5, 5, 4) }, 3)
	for k, d in pairs(whole) do near(sliced[k], d, 1e-9, "same distance") end
	for k in pairs(sliced) do assert(whole[k], "same cells") end
end)

test("distance stops at the last band", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	walk(line(0, 0, 120, 0))
	local dist = search({ pointAt(0, 0, 0.5) })
	for _, d in pairs(dist) do assert(d <= 150, "within 150 m") end
	assert(dist[grid.keyOf(80, 0)] == nil, "160 m away not reached")
end)

-- Planning ---------------------------------------------------------------------------

local function covers(plan, dist)
	local covered = {}
	for key, spec in pairs(plan) do
		local stencil = PathHeatmap.STENCILS[spec.wi][spec.ai][spec.hi]
		for _, off in ipairs(stencil) do covered[key + off] = true end
	end
	for key in pairs(dist) do
		if not covered[key] then return false, key end
	end
	return true
end

test("a corridor is covered by strips along it", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	for x = 0, 20 do walk({ { x, 0 }, { x, 1 } }) end
	local dist = search({ pointAt(0, 0, 0.5) })
	local job = PathHeatmap.newPlanJob(dist)
	runJob(job, math.huge)
	local strips, shapes = 0, 0
	for _, spec in pairs(job.plan) do
		shapes = shapes + 1
		if spec.ai > 1 then
			strips = strips + 1
			assert(spec.hi == 1, "strip runs along x, heading index " .. spec.hi)
		end
	end
	assert(strips > 0, "some strips")
	assert(shapes < 21, "fewer shapes than corridor cells: " .. shapes)
	assert(covers(job.plan, dist), "every cell covered")
end)

test("open ground gets large round shapes", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	for x = 0, 20 do for z = 0, 20 do walk({ { x, z } }) end end
	local dist = search({ pointAt(10, 10, 1) })
	local job = PathHeatmap.newPlanJob(dist)
	runJob(job, math.huge)
	local largest = 0
	for _, spec in pairs(job.plan) do largest = math.max(largest, spec.wi) end
	assert(largest == #PathHeatmap.cfg.RADII, "widest class used")
	assert(covers(job.plan, dist), "every cell covered")
end)

test("plan is the same at any budget", function()
	loadMod()
	local grid = PathHeatmap.grid
	grid.reset()
	for x = 0, 50 do walk({ { x, math.floor(x / 3) }, { x, math.floor(x / 3) + 1 } }) end
	for z = 0, 30 do walk({ { 25, z } }) end
	local dist = search({ pointAt(0, 0, 1) })
	local a = PathHeatmap.newPlanJob(dist)
	runJob(a, math.huge)
	local b = PathHeatmap.newPlanJob(dist)
	runJob(b, 50)
	for key, spec in pairs(a.plan) do
		local other = b.plan[key]
		assert(other and other.wi == spec.wi and other.ai == spec.ai and other.hi == spec.hi, "same shape")
	end
	for key in pairs(b.plan) do assert(a.plan[key], "same keys") end
end)

-- The component, against the fake engine ---------------------------------------------------

local function newSampler(level, saved)
	local class = PathHeatmap and fake and nil
	local mod = loadMod({ DEBUG = true })
	local info = mod.classes.COMP_PATH_SAMPLER
	local comp = setmetatable({ SavedCells = saved or "" }, { __index = info })
	function comp:getLevel() return level end
	comp:create()
	comp:init()
	return comp, mod
end

local function frames(comp, n)
	for _ = 1, n do comp:update() end
end

local function idle(comp)
	return not comp._search and not comp._plan and not comp._reconcile and not comp._searchWanted
end

local function settle(comp)
	local n = 0
	while not idle(comp) do
		comp:update()
		n = n + 1
		assert(n < 10000, "pipeline did not settle")
	end
	return n
end

test("sampler: walking, selecting and deselecting", function()
	local level = fake.newLevel()
	local building = fake.newBuilding(level, 100, 10, 100, { { 4, 0 }, { -4, 0 }, { 4, 0 } })
	local comp, mod = newSampler(level)
	-- Ten agents pacing a cross of paths through the building.
	local agents = {}
	for i = 1, 10 do agents[i] = fake.newAgent(level, "COMP_VILLAGER", 100, 10, 100) end
	level.dt = 0.05
	for f = 1, 2400 do
		for i, a in ipairs(agents) do
			local phase = (f * 0.05 * 1.5 + i * 13) % 160 - 80
			if i % 2 == 0 then
				a.owner.pos.x, a.owner.pos.z = 100 + phase, 100
			else
				a.owner.pos.x, a.owner.pos.z = 100, 100 + phase
			end
		end
		comp:update()
	end
	local total, active = PathHeatmap.grid.count()
	assert(active > 100, "cells walked: " .. active)

	fake.fire(building.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, true)
	settle(comp)
	local markers = PathHeatmap.overlay.markerCount()
	assert(markers > 0, "markers created")
	assert(fake.liveObjects("PATH_HEATMAP_MARKERS") == 1, "one container")
	assert(#mod.errors == 0 and #mod.warnings == 0, table.concat(mod.errors, ";") .. table.concat(mod.warnings, ";"))

	-- Two distinct entrances (the third repeats one).
	local entrances = 0
	for _, line in ipairs(mod.logs) do
		local n = string.match(line, "(%d+) start points")
		if n then entrances = tonumber(n) end
	end
	assert(entrances == 2, "entrances found: " .. entrances)

	-- A refresh keeps unchanged markers.
	comp:requestSearch()
	settle(comp)
	assert(PathHeatmap.overlay.markerCount() == markers, "same markers after refresh")

	fake.fire(building.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, false)
	assert(PathHeatmap.overlay.markerCount() == 0, "markers cleared")
	assert(fake.liveObjects("PATH_HEATMAP_MARKERS") == 0, "container destroyed")
	assert(fake.liveObjects("PREFAB_EMPTY_PART") == 0, "no marker objects left")
end)

test("sampler: selection while paused still builds the overlay", function()
	local level = fake.newLevel()
	local building = fake.newBuilding(level, 50, 10, 50, { { 3, 0 } })
	local comp = newSampler(level)
	walk(line(25, 25, 60, 25))
	level.dt = 0
	fake.fire(building.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, true)
	settle(comp)
	assert(PathHeatmap.overlay.markerCount() > 0, "markers while paused")
end)

test("sampler: destroying the selected building clears the overlay", function()
	local level = fake.newLevel()
	local building = fake.newBuilding(level, 50, 10, 50, { { 3, 0 } })
	local comp = newSampler(level)
	walk(line(25, 25, 60, 25))
	fake.fire(building.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, true)
	settle(comp)
	fake.fire(building.ON_BUILDING_DESTROYED, building)
	assert(PathHeatmap.selected == nil, "deselected")
	assert(PathHeatmap.overlay.markerCount() == 0, "markers cleared")
end)

test("sampler: switching buildings replaces the overlay", function()
	local level = fake.newLevel()
	local a = fake.newBuilding(level, 50, 10, 50, { { 3, 0 } })
	local b = fake.newBuilding(level, 70, 10, 50, { { 3, 0 } })
	local comp = newSampler(level)
	walk(line(10, 25, 60, 25))
	fake.fire(a.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, true)
	frames(comp, 3) -- part way through
	fake.fire(b.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, true)
	fake.fire(a.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, false) -- arrives after, ignored
	settle(comp)
	assert(PathHeatmap.selected == b, "b selected")
	assert(fake.liveObjects("PATH_HEATMAP_MARKERS") == 1, "one container")
	assert(PathHeatmap.overlay.markerCount() > 0, "markers for b")
end)

test("sampler: history survives a save and a container in the save is swept", function()
	local level = fake.newLevel()
	local building = fake.newBuilding(level, 50, 10, 50, { { 3, 0 } })
	local comp = newSampler(level)
	walk(line(25, 25, 60, 25))
	fake.fire(building.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, true)
	settle(comp)
	local _, activeBefore = PathHeatmap.grid.count()
	level.dt = 0.1
	frames(comp, math.ceil(PathHeatmap.cfg.SAVE_EVERY / 0.1) + 50)
	local saved = comp.SavedCells
	assert(#saved > 3, "history saved")

	-- "Load": a new level object, same scene (the saved container survives).
	assert(fake.liveObjects("PATH_HEATMAP_MARKERS") == 1, "container present before load")
	PathHeatmapOverlay = nil
	local level2 = fake.newLevel()
	local comp2 = newSampler(level2, saved)
	assert(fake.liveObjects("PATH_HEATMAP_MARKERS") == 0, "saved container swept")
	local _, activeAfter = PathHeatmap.grid.count()
	assert(activeAfter > 0 and activeAfter <= activeBefore, string.format("restored %d of %d", activeAfter, activeBefore))
end)

test("sampler: a building without a destroyed event is still watched", function()
	local level = fake.newLevel()
	local building = fake.newBuilding(level, 50, 10, 50, { { 3, 0 } })
	building.ON_BUILDING_DESTROYED = nil
	local comp, mod = newSampler(level)
	walk(line(25, 25, 60, 25))
	fake.fire(building.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, true)
	settle(comp)
	assert(PathHeatmap.overlay.markerCount() > 0, "markers")
	assert(#mod.errors == 0, table.concat(mod.errors, ";"))
end)

test("sampler: agent type check reports overlaps", function()
	local level = fake.newLevel()
	local comp, mod = newSampler(level)
	local v = fake.newAgent(level, "COMP_VILLAGER", 10, 10, 10)
	fake.newAgent(level, "COMP_VISITOR", 12, 10, 10)
	local m = level:manager("COMP_VISITOR")
	m.items[#m.items + 1] = v -- the same agent under a second type
	level.dt = 0.1
	frames(comp, 120)
	local found
	for _, line in ipairs(mod.logs) do
		if string.find(line, "agents by type", 1, true) then found = line end
	end
	assert(found, "check logged")
	assert(string.find(found, "COMP_VILLAGER 1, COMP_VISITOR 2; 1 listed", 1, true), found)
end)

test("sampler: entrances are remembered until the building changes", function()
	local level = fake.newLevel()
	local building = fake.newBuilding(level, 50, 10, 50, { { 3, 0 } })
	building.ON_BUILDING_CHANGED = fake.newEvent()
	local comp, mod = newSampler(level)
	walk(line(25, 25, 60, 25))
	fake.fire(building.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, true)
	settle(comp)
	assert(comp._entrances[building], "cached after the first selection")
	fake.fire(building.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, false)
	fake.fire(building.ON_BUILDING_CHANGED)
	assert(comp._entrances[building] == nil, "forgotten after a change")
	fake.fire(building.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, true)
	settle(comp)
	assert(comp._entrances[building], "cached again")
	assert(#mod.errors == 0, table.concat(mod.errors, ";"))
end)

test("sampler: a frame's length is charged to the work done in it", function()
	local level = fake.newLevel()
	local comp, mod = newSampler(level)
	level.dt, level.unscaled = 0.05, 0.020
	frames(comp, 100) -- baseline near 20 ms
	comp:note("test") -- as an event handler after an update would
	level.unscaled = 0.120 -- that frame took 120 ms
	comp:update()
	level.unscaled = 0.020
	frames(comp, 5)
	local cost = comp._costs.test
	assert(cost and cost.count == 1, "charged once")
	near(cost.sum, 100, 1, "extra cost")
end)

test("sampler: selection timeline, and OVERLAY off skips the overlay", function()
	local level = fake.newLevel()
	local building = fake.newBuilding(level, 50, 10, 50, { { 3, 0 } })
	local comp, mod = newSampler(level)
	PathHeatmap.cfg.OVERLAY = false
	walk(line(25, 25, 60, 25))
	level.dt = 0.05
	frames(comp, 50)
	fake.fire(building.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, true)
	frames(comp, 400)
	local timelines, costs = 0, 0
	for _, line in ipairs(mod.logs) do
		if string.find(line, "frames after selecting", 1, true) then timelines = timelines + 1 end
		if string.find(line, "extra frame cost", 1, true) then costs = costs + 1 end
	end
	assert(timelines == 1, "timeline logged: " .. timelines)
	assert(costs > 0, "cost summary logged")
	assert(PathHeatmap.selected == nil and PathHeatmap.overlay.markerCount() == 0, "no overlay")
	assert(#mod.errors == 0 and #mod.warnings == 0, table.concat(mod.errors, ";") .. table.concat(mod.warnings, ";"))
	PathHeatmap.cfg.OVERLAY = true
end)

test("sampler: marker rays hit the terrain only", function()
	local level = fake.newLevel()
	local building = fake.newBuilding(level, 50, 10, 50, { { 3, 0 } })
	local comp = newSampler(level)
	walk(line(25, 25, 60, 25))
	fake.fire(building.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, true)
	settle(comp)
	assert(level.rays > 0, "rays cast")
	assert(level.badRayFlags == 0, level.badRayFlags .. " rays without the terrain mask")
end)

print(string.format("%d passed, %d failed", passed, failures))
return failures
