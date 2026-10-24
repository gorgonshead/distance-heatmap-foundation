local mod = ...

-- Overlay markers: one empty object per planned shape, carrying a particle
-- emitter, placed on the ground and turned along its path.
--
-- All markers are children of one container object, so clearing the overlay is
-- one destroy, and a container captured by a save is found with one name
-- search on load.  The state lives in a global that survives mod reloads,
-- so a reload can clear what the previous load created.

local cfg = PathHeatmap.cfg
local grid = PathHeatmap.grid
local CELL = grid.CELL
local abs, sqrt, cos, sin = math.abs, math.sqrt, math.cos, math.sin

local CONTAINER_NAME = "PATH_HEATMAP_MARKERS"
local EMPTY_PREFAB = "PREFAB_EMPTY_PART"
local UP = { x = 0, y = 1, z = 0 }
-- rayCast's flag is a bit field of OBJECT_FLAG numbers (the wiki's Enumerations
-- page). Passing the enum value itself filters nothing: rays then stop on
-- buildings and villagers too.
local TERRAIN_ONLY = bit.lshift(1, OBJECT_FLAG.TERRAIN:toNumber()) -- 4 in game (TERRAIN is 2)

local overlay = {}
PathHeatmap.overlay = overlay

-- The container: its children first, in case destroying a parent leaves them.
local function destroyTree(obj)
	obj:destroyAllChild()
	obj:destroy()
end

-- What a previous load left in the globals may already be gone. Looking up a
-- method on a destroyed object errors, so the whole call goes inside the pcall.
local function destroyStale(obj)
	if obj then pcall(destroyTree, obj) end
end

PathHeatmapOverlay = PathHeatmapOverlay or {}
local state = PathHeatmapOverlay
destroyStale(state.container)
state.container, state.markers = nil, {}

function overlay.markerCount()
	local n = 0
	for _ in pairs(state.markers) do n = n + 1 end
	return n
end

function overlay.clear()
	if state.container then destroyTree(state.container) end
	state.container, state.markers = nil, {}
end

-- Objects captured by a save made while a building was selected come back
-- untracked after loading. Repeated name searches stop at the first repeat, in
-- case destroy is deferred.
local function sweepByName(name, limit)
	local removed, seen = 0, {}
	for _ = 1, limit do
		local obj = foundation.findGameObject(name)
		if not obj then break end
		local id = tostring(obj:getId())
		if seen[id] then break end
		seen[id] = true
		destroyTree(obj)
		removed = removed + 1
	end
	return removed
end

function overlay.sweep()
	local containers = sweepByName(CONTAINER_NAME, 20)
	if containers > 0 then
		mod:log(string.format("removed saved overlay: %d containers", containers))
	end
end

-- Placement ------------------------------------------------------------------

-- Terrain height and slope at (x, z). rayCast fills a plain Lua table passed as
-- its out argument with Position and Normal.
local function groundAt(level, x, yHint, z)
	local out = {}
	local hit = level:rayCast({ x, yHint + 40, z }, { x, yHint - 40, z }, out, TERRAIN_ONLY)
	if not hit or not out.Position or not out.Normal then return nil end
	local p, n = out.Position, out.Normal
	return { x = p.x, y = p.y, z = p.z }, { x = n.x, y = n.y, z = n.z }
end

-- Slope from the walked heights: a least-squares plane through the feet heights
-- recorded within SLOPE_REACH cells. That is the surface people stand on, so it
-- holds where they walk above the terrain, such as on a building platform.
-- Returns nil with too few samples or samples along one line.
local SLOPE_REACH = 3
local MIN_NORMAL_Y = 0.7 -- steepest tilt allowed, about 45 degrees
local SLOPE_OFFSET, SLOPE_X, SLOPE_Z = {}, {}, {}
for dx = -SLOPE_REACH, SLOPE_REACH do
	for dz = -SLOPE_REACH, SLOPE_REACH do
		SLOPE_OFFSET[#SLOPE_OFFSET + 1] = dx * grid.STRIDE + dz
		SLOPE_X[#SLOPE_X + 1] = dx * CELL
		SLOPE_Z[#SLOPE_Z + 1] = dz * CELL
	end
end

local function slopeFromWalked(key)
	local heights = grid.heights
	local n, sumX, sumZ, sumH = 0, 0, 0, 0
	local px, pz, ph = {}, {}, {}
	for i = 1, #SLOPE_OFFSET do
		local h = heights[key + SLOPE_OFFSET[i]]
		if h then
			n = n + 1
			px[n], pz[n], ph[n] = SLOPE_X[i], SLOPE_Z[i], h
			sumX, sumZ, sumH = sumX + SLOPE_X[i], sumZ + SLOPE_Z[i], sumH + h
		end
	end
	if n < 5 then return nil end
	local mx, mz, mh = sumX / n, sumZ / n, sumH / n
	local sxx, szz, sxz, sxh, szh = 0, 0, 0, 0, 0
	for i = 1, n do
		local x, z, h = px[i] - mx, pz[i] - mz, ph[i] - mh
		sxx, szz, sxz = sxx + x * x, szz + z * z, sxz + x * z
		sxh, szh = sxh + x * h, szh + z * h
	end
	local det = sxx * szz - sxz * sxz
	if det < 1e-3 then return nil end
	local gx = (sxh * szz - szh * sxz) / det -- height change per metre along x
	local gz = (szh * sxx - sxh * sxz) / det
	local len = sqrt(gx * gx + 1 + gz * gz)
	local ny = 1 / len
	if ny < MIN_NORMAL_Y then
		-- Flatten extreme fits (stairs, someone on a bench) to the steepest tilt.
		local scale = sqrt((1 - MIN_NORMAL_Y * MIN_NORMAL_Y) / (1 - ny * ny))
		return { x = -gx / len * scale, y = MIN_NORMAL_Y, z = -gz / len * scale }
	end
	return { x = -gx / len, y = ny, z = -gz / len }
end

-- Turn an object so its up axis follows `normal` and its forward axis points
-- along (hx, hz) projected onto the slope.
local function orient(obj, px, py, pz, normal, hx, hz)
	local dot = hx * normal.x + hz * normal.z
	local fx, fy, fz = hx - normal.x * dot, -normal.y * dot, hz - normal.z * dot
	local len = sqrt(fx * fx + fy * fy + fz * fz)
	if len < 0.001 then fx, fy, fz, len = 1, 0, 0, 1 end
	obj:lookAt({ px + fx / len, py + fy / len, pz + fz / len }, { normal.x, normal.y, normal.z }, false)
end

local emptyPrefab
local pendingParticle
local function setParticle(emitter)
	emitter.ParticleSystem = pendingParticle
end

-- Creates the marker for a planned shape at `key`.
local function createMarker(level, key, spec, stats)
	local cx, cz = grid.coordsOf(key)
	local x, z = (cx + 0.5) * CELL, (cz + 0.5) * CELL
	-- The centre is a walked cell, so the feet height recorded there is the
	-- surface that matters. Where the terrain is far from it, people walk on
	-- something built (a platform, a bridge), so use the walked height and the
	-- slope fitted to it.
	local y = grid.heights[key] or 0
	local ground, normal = groundAt(level, x, y, z)
	if ground and abs(ground.y - y) > cfg.MAX_GROUND_MISMATCH then
		stats.mismatches = stats.mismatches + 1
		ground, normal = nil, nil
	end
	normal = normal or slopeFromWalked(key) or UP
	local lift = cfg.GROUND_LIFT
	local bx, by, bz = x, y, z
	if ground then bx, by, bz = ground.x, ground.y, ground.z end
	local px, py, pz = bx + normal.x * lift, by + normal.y * lift, bz + normal.z * lift

	emptyPrefab = emptyPrefab or foundation.findAsset(EMPTY_PREFAB)
	local obj = level:createObject(emptyPrefab, { px, py, pz })
	pendingParticle = "PATHHEAT_PS_" .. spec.band .. "_" .. spec.wi .. "_" .. spec.ai
	obj:addComponent("COMP_PARTICLE_EMITTER", setParticle)

	-- The quad's long side is its sideways axis, so face across the heading.
	local angle = (spec.hi - 1) * PathHeatmap.HEADING_STEP
	orient(obj, px, py, pz, normal, -sin(angle), cos(angle))

	obj:setParent(state.container, true)
	return obj
end

local function sameSpec(a, b)
	return a and b and a.band == b.band and a.wi == b.wi and a.ai == b.ai and a.hi == b.hi
end

-- Brings the markers in line with a plan, a few per frame: new and changed
-- shapes are created nearest the building first, so the overlay grows outward,
-- and replaced or dropped ones are destroyed after that. job.step() returns
-- true when done.
function overlay.newReconcileJob(level, plan)
	local job = { done = false, created = 0, destroyed = 0 }
	local stats = { mismatches = 0 }
	local markers = state.markers

	if not state.container then
		state.container = level:createObject()
		state.container.Name = CONTAINER_NAME
	end

	local toDestroy, toCreate = {}, {}
	for key, m in pairs(markers) do
		if not sameSpec(plan[key], m.spec) then
			toDestroy[#toDestroy + 1] = m.obj
			markers[key] = nil
		end
	end
	for key in pairs(plan) do
		if not markers[key] then toCreate[#toCreate + 1] = key end
	end
	table.sort(toCreate, function(a, b)
		local da, db = plan[a].d, plan[b].d
		if da ~= db then return da < db end
		return a < b
	end)

	local createIndex, destroyIndex = 1, 1

	function job.step()
		if createIndex <= #toCreate then
			local last = math.min(createIndex + cfg.CREATE_PER_FRAME - 1, #toCreate)
			for i = createIndex, last do
				local key = toCreate[i]
				markers[key] = { obj = createMarker(level, key, plan[key], stats), spec = plan[key] }
			end
			job.created = job.created + (last - createIndex + 1)
			createIndex = last + 1
		elseif destroyIndex <= #toDestroy then
			local last = math.min(destroyIndex + cfg.DESTROY_PER_FRAME - 1, #toDestroy)
			for i = destroyIndex, last do toDestroy[i]:destroy() end
			job.destroyed = job.destroyed + (last - destroyIndex + 1)
			destroyIndex = last + 1
		else
			job.done = true
			job.mismatches = stats.mismatches
		end
		return job.done
	end

	return job
end
