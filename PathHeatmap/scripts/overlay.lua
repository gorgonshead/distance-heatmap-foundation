local mod = ...

-- Marker overlay. Terrain dirt circles cannot be removed once painted, so the
-- overlay is made of ordinary objects: particle circles sized to cover
-- contiguous walked cells, one colour per distance band, all destroyed on
-- deselect. Markers are shared through a global that survives mod reloads, so a
-- reload can clean up what the previous load left behind.

local MARKER_NAME = "PATH_HEATMAP_MARKER" -- lets a later load find markers a save captured
local MARKER_SCALE = 2
local TILT_TO_GROUND = true
local MAX_GROUND_MISMATCH = 1.5 -- metres the terrain ray may differ from the walked height
local GROUND_LIFT = 0.6 -- keeps flat particles from z-fighting with the terrain
local BAND_PREFABS = {
	[50] = "PREFAB_RESOURCE_VISUAL_CRATE",
	[100] = "PREFAB_RESOURCE_VISUAL_PLANK",
	[150] = "PREFAB_RESOURCE_VISUAL_STONE_01A",
}

-- Particle systems registered in particles.lua: PATHHEAT_PS_<name>_<width>_<aspect>.
local BAND_NAMES = { [50] = "NEAR", [100] = "MID", [150] = "FAR" }
local FILL = 0.6 -- share of a disc that must be walked cells of one band
local EMPTY_PREFAB = "PREFAB_EMPTY_PART"

local function destroyAll(markers)
	local n = 0
	for key, m in pairs(markers) do
		if pcall(function() m.obj:destroy() end) then n = n + 1 end
		markers[key] = nil
	end
	return n
end

PathHeatmapMarkers = PathHeatmapMarkers or {}
local leftover = destroyAll(PathHeatmapMarkers)
if leftover > 0 then mod:log("removed " .. leftover .. " markers left by previous load") end

-- Markers are ordinary level objects, so a save taken while a building is
-- selected stores them and they come back untracked after loading. Find them by
-- name and remove them.
function PathHeatmap.sweepMarkers()
	local removed, seen = 0, {}
	for _ = 1, 5000 do
		local ok, obj = pcall(foundation.findGameObject, MARKER_NAME)
		if not ok or not obj then break end
		local id = tostring(obj:getId())
		if seen[id] then break end -- destroy is deferred; stop rather than loop forever
		seen[id] = true
		if pcall(function() obj:destroy() end) then removed = removed + 1 end
	end
	if removed > 0 then mod:log("swept " .. removed .. " markers from the level") end
	return removed
end

local prefabs = {}
local function prefabFor(band)
	if prefabs[band] == nil then
		local asset = foundation.findAsset(BAND_PREFABS[band])
		if not asset then
			mod:logWarning("missing prefab " .. BAND_PREFABS[band] .. ", using crate")
			asset = foundation.findAsset(BAND_PREFABS[50])
		end
		prefabs[band] = asset
	end
	return prefabs[band]
end

local function bandOf(d)
	for _, b in ipairs(PathHeatmap.BANDS) do
		if d <= b then return b end
	end
end

function PathHeatmap.clearMarkers()
	destroyAll(PathHeatmapMarkers)
end

-- An empty object carrying a COMP_PARTICLE_EMITTER for the band's particle
-- system. Returns nil (and logs once) if any step fails, so the caller can use a
-- plain prefab marker instead. Which way of passing the asset works is unknown,
-- so the id string is tried first, then the asset object.
function PathHeatmap.createParticleMarker(level, band, wi, ai, pos)
	if PathHeatmap.particlesBroken then return nil end
	local obj = nil
	local ok, err = pcall(function()
		obj = level:createObject(foundation.findAsset(EMPTY_PREFAB), pos)
		local function attach(value)
			obj:addComponent("COMP_PARTICLE_EMITTER", function(emitter)
				emitter.ParticleSystem = value
			end)
		end
		local id = "PATHHEAT_PS_" .. BAND_NAMES[band] .. "_" .. wi .. "_" .. ai
		local idOk = pcall(attach, id)
		if not idOk then
			local asset = foundation.findAsset(id)
			if not asset then error("particle asset " .. id .. " not found") end
			attach(asset)
			if not PathHeatmap.particleAssetLogged then
				PathHeatmap.particleAssetLogged = true
				mod:log("particles: emitter needed the asset object, not the id string")
			end
		end
	end)
	if not ok then
		if obj then pcall(function() obj:destroy() end) end
		PathHeatmap.particlesBroken = true
		mod:logWarning("particle markers unavailable, using prefab markers: " .. tostring(err))
		return nil
	end
	return obj
end

-- Exact terrain height and slope at (x, z). rayCast takes a plain Lua table as
-- its out argument and fills Position and Normal. Returns nil if nothing is hit.
local function groundAt(level, x, yHint, z)
	local out = {}
	local ok, hit = pcall(function()
		return level:rayCast({ x, yHint + 40, z }, { x, yHint - 40, z }, out, OBJECT_FLAG.TERRAIN)
	end)
	if not ok or not hit or not out.Position or not out.Normal then return nil end
	local p, n = out.Position, out.Normal
	return { x = p.x, y = p.y, z = p.z }, { x = n.x, y = n.y, z = n.z }
end

-- Slope from the walked heights themselves: a least-squares plane through the
-- recorded feet heights of walked cells around (cx, cz). This is the surface
-- people stand on, so it stays right where the terrain ray hits something else.
-- Returns a unit normal, or nil if there are too few or too collinear samples.
local SLOPE_REACH = 3 -- cells
local MAX_SLOPE_TILT = 0.7 -- smallest allowed normal.y, about 45 degrees
local function slopeFromWalked(cx, cz)
	local C, keyOf, heights = PathHeatmap.CELL, PathHeatmap.keyOf, PathHeatmap.heights
	local pts, sumX, sumZ, sumH = {}, 0, 0, 0
	for dx = -SLOPE_REACH, SLOPE_REACH do
		for dz = -SLOPE_REACH, SLOPE_REACH do
			local h = heights[keyOf(cx + dx, cz + dz)]
			if h then
				pts[#pts + 1] = { dx * C, dz * C, h }
				sumX, sumZ, sumH = sumX + dx * C, sumZ + dz * C, sumH + h
			end
		end
	end
	local n = #pts
	if n < 5 then return nil end
	local mx, mz, mh = sumX / n, sumZ / n, sumH / n
	local sxx, szz, sxz, sxh, szh = 0, 0, 0, 0, 0
	for _, p in ipairs(pts) do
		local x, z, h = p[1] - mx, p[2] - mz, p[3] - mh
		sxx, szz, sxz = sxx + x * x, szz + z * z, sxz + x * z
		sxh, szh = sxh + x * h, szh + z * h
	end
	local det = sxx * szz - sxz * sxz
	if det < 1e-3 then return nil end -- points lie along a line, slope across it unknown
	local gx = (sxh * szz - szh * sxz) / det -- metres of height per metre in x
	local gz = (szh * sxx - sxh * sxz) / det
	local len = math.sqrt(gx * gx + 1 + gz * gz)
	local ny = 1 / len
	if ny < MAX_SLOPE_TILT then
		-- Flatten extreme fits (stairs, a villager on a bench) to the maximum tilt.
		local scale = math.sqrt((1 - MAX_SLOPE_TILT ^ 2) / (1 - ny ^ 2))
		return { x = -gx / len * scale, y = MAX_SLOPE_TILT, z = -gz / len * scale }
	end
	return { x = -gx / len, y = ny, z = -gz / len }
end

-- Turn an object so its local up axis follows `normal` and its forward axis
-- points along `heading` (a horizontal x, z direction) projected onto the slope.
-- Whether the particle quads follow the emitter's orientation is untested, so a
-- failure is logged once and the marker stays upright.
local function orient(obj, pos, normal, hx, hz)
	local dot = hx * normal.x + hz * normal.z
	local fx, fy, fz = hx - normal.x * dot, -normal.y * dot, hz - normal.z * dot
	local len = math.sqrt(fx * fx + fy * fy + fz * fz)
	if len < 0.001 then fx, fy, fz, len = 1, 0, 0, 1 end
	local ok, err = pcall(function()
		obj:lookAt({ pos.x + fx / len, pos.y + fy / len, pos.z + fz / len }, { normal.x, normal.y, normal.z }, false)
	end)
	if not ok and not PathHeatmap.tiltWarned then
		PathHeatmap.tiltWarned = true
		mod:logWarning("could not orient marker: " .. tostring(err))
	end
	return ok
end

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local ANGLE_STEP = math.pi / 12 -- headings are quantised so markers do not churn
local NEIGHBOURHOOD = 4 -- cells around a seed used to find the local direction

-- Principal direction and elongation of the walked cells of `set` around a cell
-- (cx, cz): angle of the long axis in the x-z plane, and the aspect class
-- (1 round, 2 stretched, 3 strongly stretched).
local function localShape(set, cx, cz)
	local keyOf = PathHeatmap.keyOf
	local n, sx, sz, sxx, szz, sxz = 0, 0, 0, 0, 0, 0
	for dx = -NEIGHBOURHOOD, NEIGHBOURHOOD do
		for dz = -NEIGHBOURHOOD, NEIGHBOURHOOD do
			if dx * dx + dz * dz <= NEIGHBOURHOOD * NEIGHBOURHOOD and set[keyOf(cx + dx, cz + dz)] then
				n = n + 1
				sx, sz = sx + dx, sz + dz
				sxx, szz, sxz = sxx + dx * dx, szz + dz * dz, sxz + dx * dz
			end
		end
	end
	if n < 4 then return 0, 1 end
	local mx, mz = sx / n, sz / n
	local a, b, c = sxx / n - mx * mx, sxz / n - mx * mz, szz / n - mz * mz
	local mean, diff = (a + c) / 2, math.sqrt(((a - c) / 2) ^ 2 + b * b)
	local l1, l2 = mean + diff, math.max(mean - diff, 0.05)
	local elong = math.sqrt(l1 / l2)
	local ai = 1
	if elong >= 2.6 then ai = 3 elseif elong >= 1.5 then ai = 2 end
	if ai == 1 then return 0, 1 end -- a round shape has no heading
	local angle = 0.5 * atan2(2 * b, a - c)
	return math.floor(angle / ANGLE_STEP + 0.5) * ANGLE_STEP, ai
end

-- Visit the cells inside an ellipse centred on (cx, cz): semi-axes a (along
-- `angle`) and b across, in metres. Calls visit(key).
local function eachInEllipse(cx, cz, angle, a, b, visit)
	local C, keyOf = PathHeatmap.CELL, PathHeatmap.keyOf
	local cosA, sinA = math.cos(angle), math.sin(angle)
	local reach = math.ceil(math.max(a, b) / C)
	for dx = -reach, reach do
		for dz = -reach, reach do
			local u = (dx * cosA + dz * sinA) * C
			local v = (-dx * sinA + dz * cosA) * C
			if (u / a) ^ 2 + (v / b) ^ 2 <= 1 then visit(keyOf(cx + dx, cz + dz)) end
		end
	end
end

-- Choose ellipses that cover the walked cells of each band. A seed cell takes
-- its local direction and stretch, then the widest ellipse of that stretch that
-- is still at least FILL walked cells of its band. Seeds with the largest
-- ellipses are placed first and skip cells already covered, so open ground gets
-- a few big round shapes and a path one long strip. Any cell still uncovered
-- at the end gets a small circle.
local function planShapes(dist)
	local radii, aspects = PathHeatmap.RADII, PathHeatmap.ASPECTS
	local coordsOf = PathHeatmap.coordsOf

	local sets = {}
	for key, d in pairs(dist) do
		local band = bandOf(d)
		sets[band] = sets[band] or {}
		sets[band][key] = true
	end

	local plan = {}
	for band, set in pairs(sets) do
		local keys = {}
		for key in pairs(set) do keys[#keys + 1] = key end
		table.sort(keys)

		-- One seed per 2 x 2 block keeps the search affordable.
		local seeds, seenBlock = {}, {}
		for _, key in ipairs(keys) do
			local cx, cz = coordsOf(key)
			local block = math.floor(cx / 2) * 100000 + math.floor(cz / 2)
			if not seenBlock[block] then
				seenBlock[block] = true
				local angle, ai = localShape(set, cx, cz)
				local wi = 1
				for w = 2, #radii do
					local b = radii[w]
					local a = b * aspects[ai]
					if a > PathHeatmap.MAX_MAJOR then break end
					local total, walked = 0, 0
					eachInEllipse(cx, cz, angle, a, b, function(k)
						total = total + 1
						if set[k] then walked = walked + 1 end
					end)
					if walked / total < FILL then break end
					wi = w
				end
				seeds[#seeds + 1] = { key = key, cx = cx, cz = cz, angle = angle, wi = wi, ai = ai,
					score = radii[wi] * radii[wi] * aspects[ai] }
			end
		end
		table.sort(seeds, function(p, q)
			if p.score ~= q.score then return p.score > q.score end
			return p.key < q.key
		end)

		local covered = {}
		local function place(seed)
			plan[seed.key] = { band = band, wi = seed.wi, ai = seed.ai, angle = seed.angle }
			local b = radii[seed.wi]
			eachInEllipse(seed.cx, seed.cz, seed.angle, b * aspects[seed.ai], b, function(k) covered[k] = true end)
		end
		for _, seed in ipairs(seeds) do
			if not covered[seed.key] then place(seed) end
		end
		for _, key in ipairs(keys) do
			if not covered[key] then
				local cx, cz = coordsOf(key)
				place({ key = key, cx = cx, cz = cz, angle = 0, wi = 1, ai = 1 })
			end
		end
	end
	return plan
end

-- Reconcile markers with the plan: keep shapes unchanged in band, size, stretch
-- and heading, destroy the rest, create the missing.
function PathHeatmap.updateMarkers(level, dist)
	local plan = planShapes(dist)

	for key, m in pairs(PathHeatmapMarkers) do
		local want = plan[key]
		if not want or want.band ~= m.band or want.wi ~= m.wi or want.ai ~= m.ai or want.angle ~= m.angle then
			pcall(function() m.obj:destroy() end)
			PathHeatmapMarkers[key] = nil
		end
	end

	local created, mismatches, worst = 0, 0, 0
	for key, want in pairs(plan) do
		if not PathHeatmapMarkers[key] then
			local cx, cz = PathHeatmap.coordsOf(key)
			local c = PathHeatmap.CELL
			local x, z = (cx + 0.5) * c, (cz + 0.5) * c
			-- The circle's centre is a walked cell, so villagers' feet height is
			-- the surface that matters. The terrain ray supplies the slope, but
			-- where it disagrees with the walked height (a building platform,
			-- for instance) it is hitting something else, so ignore it there.
			local y = PathHeatmap.heights[key] or 0
			local ground, normal = groundAt(level, x, y, z)
			if ground and math.abs(ground.y - y) > MAX_GROUND_MISMATCH then
				mismatches = mismatches + 1
				worst = math.max(worst, math.abs(ground.y - y))
				ground, normal = nil, nil
			end
			normal = normal or slopeFromWalked(cx, cz) or { x = 0, y = 1, z = 0 }
			local pos
			if ground then
				pos = { ground.x + normal.x * GROUND_LIFT, ground.y + normal.y * GROUND_LIFT, ground.z + normal.z * GROUND_LIFT }
			else
				pos = { x + normal.x * GROUND_LIFT, y + normal.y * GROUND_LIFT, z + normal.z * GROUND_LIFT }
			end

			local obj = PathHeatmap.createParticleMarker(level, want.band, want.wi, want.ai, pos)
			if obj and TILT_TO_GROUND then
				-- The long axis follows the path heading; which emitter axis is
				-- the long one is a flag, so turn 90 degrees if it is the side axis.
				local hx, hz = math.cos(want.angle), math.sin(want.angle)
				if not PathHeatmap.STRIP_ALONG_FORWARD then hx, hz = -hz, hx end
				orient(obj, { x = pos[1], y = pos[2], z = pos[3] }, normal, hx, hz)
			end
			if not obj then
				obj = level:createObject(prefabFor(want.band), pos)
				pcall(function() obj:setScale(MARKER_SCALE) end)
			end
			local named = pcall(function() obj.Name = MARKER_NAME end)
			if not named and not PathHeatmap.nameWarned then
				PathHeatmap.nameWarned = true
				mod:logWarning("could not name marker; saved markers cannot be swept")
			end
			PathHeatmapMarkers[key] = { obj = obj, band = want.band, wi = want.wi, ai = want.ai, angle = want.angle }
			created = created + 1
		end
	end
	if mismatches > 0 then
		PathHeatmap.debug(string.format("terrain ray disagreed with walked height at %d of %d new markers (worst %.1f m); used walked height and slope",
			mismatches, created, worst))
	end
	return created
end
