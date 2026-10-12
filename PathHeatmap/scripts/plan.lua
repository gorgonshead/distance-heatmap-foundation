local mod = ...

-- Shapes that cover the walked cells of each distance band, planned as a job.
--
-- A seed cell takes the local direction and stretch of the walked cells around
-- it (principal axes), then the widest ellipse of that stretch that is still
-- at least FILL walked cells of its band. Seeds with the largest ellipses are
-- placed first and skip cells already covered, so open ground gets a few big
-- round shapes and a path one long strip. Cells still uncovered at the end get
-- a small circle.
--
-- Every ellipse (width x stretch x heading) is precomputed once as a list of key
-- offsets, so testing or covering one is a plain array walk.

local cfg = PathHeatmap.cfg
local grid = PathHeatmap.grid
local CELL, STRIDE = grid.CELL, grid.STRIDE
local RADII, ASPECTS = cfg.RADII, cfg.ASPECTS
local FILL = cfg.FILL
local floor, ceil, sqrt, max = math.floor, math.ceil, math.sqrt, math.max
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local HEADINGS = 12 -- an ellipse looks the same turned by 180 degrees
local HEADING_STEP = math.pi / HEADINGS
PathHeatmap.HEADING_STEP = HEADING_STEP

-- STENCILS[wi][ai][hi] lists the key offsets inside the ellipse with
-- semi-minor RADII[wi], semi-major RADII[wi] x ASPECTS[ai], long axis at
-- (hi - 1) x HEADING_STEP. Missing where the major axis exceeds MAX_MAJOR.
local STENCILS = {}
for wi, b in ipairs(RADII) do
	STENCILS[wi] = {}
	for ai, aspect in ipairs(ASPECTS) do
		local a = b * aspect
		STENCILS[wi][ai] = {}
		if wi == 1 or a <= cfg.MAX_MAJOR then
			for hi = 1, HEADINGS do
				if aspect == 1 and hi > 1 then
					STENCILS[wi][ai][hi] = STENCILS[wi][ai][1]
				else
					local angle = (hi - 1) * HEADING_STEP
					local cosA, sinA = math.cos(angle), math.sin(angle)
					local reach = ceil(max(a, b) / CELL)
					local offsets = {}
					for dx = -reach, reach do
						for dz = -reach, reach do
							local u = (dx * cosA + dz * sinA) * CELL / a
							local v = (-dx * sinA + dz * cosA) * CELL / b
							if u * u + v * v <= 1 then offsets[#offsets + 1] = dx * STRIDE + dz end
						end
					end
					STENCILS[wi][ai][hi] = offsets
				end
			end
		end
	end
end
PathHeatmap.STENCILS = STENCILS

-- Cells around a seed used to find the local direction.
local NEIGHBOURHOOD = 4
local NB_OFFSET, NB_DX, NB_DZ = {}, {}, {}
for dx = -NEIGHBOURHOOD, NEIGHBOURHOOD do
	for dz = -NEIGHBOURHOOD, NEIGHBOURHOOD do
		if dx * dx + dz * dz <= NEIGHBOURHOOD * NEIGHBOURHOOD then
			NB_OFFSET[#NB_OFFSET + 1] = dx * STRIDE + dz
			NB_DX[#NB_DX + 1] = dx
			NB_DZ[#NB_DZ + 1] = dz
		end
	end
end
local NB_COUNT = #NB_OFFSET

-- Stretch class (1 round, 2 stretched, 3 strongly) and heading index of the
-- walked cells of `set` around `key`.
local function localShape(set, key)
	local n, sx, sz, sxx, szz, sxz = 0, 0, 0, 0, 0, 0
	for i = 1, NB_COUNT do
		if set[key + NB_OFFSET[i]] then
			local dx, dz = NB_DX[i], NB_DZ[i]
			n = n + 1
			sx, sz = sx + dx, sz + dz
			sxx, szz, sxz = sxx + dx * dx, szz + dz * dz, sxz + dx * dz
		end
	end
	if n < 4 then return 1, 1 end
	local mx, mz = sx / n, sz / n
	local a, b, c = sxx / n - mx * mx, sxz / n - mx * mz, szz / n - mz * mz
	local half = (a - c) / 2
	local mean, diff = (a + c) / 2, sqrt(half * half + b * b)
	local elong = sqrt((mean + diff) / max(mean - diff, 0.05))
	local ai = 1
	if elong >= 2.6 then ai = 3 elseif elong >= 1.5 then ai = 2 end
	if ai == 1 then return 1, 1 end -- a round shape has no heading
	local angle = 0.5 * atan2(2 * b, a - c)
	return ai, floor(angle / HEADING_STEP + 0.5) % HEADINGS + 1
end

-- job.step(work) does about `work` cell lookups and returns true when done;
-- job.plan then maps a centre key to { band, wi, ai, hi, d }. Every phase is
-- resumable; walks over `dist` use next(), which is safe because nothing
-- changes `dist` while the job runs.
function PathHeatmap.newPlanJob(dist)
	local job = { done = false, plan = {} }
	local plan = job.plan
	local bandOf = PathHeatmap.bandOf
	local BAND_COUNT = #cfg.BANDS

	local sets, covered = {}, {}
	for b = 1, BAND_COUNT do sets[b], covered[b] = {}, {} end
	local blockSeed = {} -- block x 8 + band -> smallest key in the block
	local seedKey, seedBand = {}, {}
	local seedWi, seedAi, seedHi, seedScore = {}, {}, {}, {}
	local order, leftovers = {}, {}
	local phase, cursor, index = "group", nil, 1

	local function place(key, b, wi, ai, hi)
		plan[key] = { band = b, wi = wi, ai = ai, hi = hi, d = dist[key] }
		local cover = covered[b]
		local stencil = STENCILS[wi][ai][hi]
		for i = 1, #stencil do cover[key + stencil[i]] = true end
		return #stencil
	end

	local function evaluate(i)
		local key, b = seedKey[i], seedBand[i]
		local set = sets[b]
		local ai, hi = localShape(set, key)
		local work = NB_COUNT
		local wi = 1
		for w = 2, #RADII do
			local stencil = STENCILS[w][ai][hi]
			if not stencil then break end
			local count = #stencil
			local allowedMisses = count - FILL * count
			local misses = 0
			for j = 1, count do
				if not set[key + stencil[j]] then
					misses = misses + 1
					if misses > allowedMisses then break end
				end
			end
			work = work + count
			if misses > allowedMisses then break end
			wi = w
		end
		seedWi[i], seedAi[i], seedHi[i] = wi, ai, hi
		seedScore[i] = RADII[wi] * RADII[wi] * ASPECTS[ai]
		return work
	end

	function job.step(budget)
		while budget > 0 and not job.done do
			if phase == "group" then
				-- Split cells by band. One seed per 2 x 2 block keeps evaluation
				-- affordable; taking the smallest key makes the choice repeatable.
				local key, d = next(dist, cursor)
				if key == nil then
					phase, cursor = "seeds", nil
				else
					cursor = key
					budget = budget - 4
					local b = bandOf(d)
					if b then
						sets[b][key] = true
						local cx, cz = floor(key / STRIDE), key % STRIDE
						local block = (floor(cx / 2) * STRIDE + floor(cz / 2)) * 8 + b
						local current = blockSeed[block]
						if current == nil or key < current then blockSeed[block] = key end
					end
				end
			elseif phase == "seeds" then
				local block, key = next(blockSeed, cursor)
				if block == nil then
					phase, index = "evaluate", 1
				else
					cursor = block
					budget = budget - 1
					seedKey[#seedKey + 1] = key
					seedBand[#seedBand + 1] = block % 8
				end
			elseif phase == "evaluate" then
				if index > #seedKey then
					for i = 1, #seedKey do order[i] = i end
					table.sort(order, function(p, q)
						if seedScore[p] ~= seedScore[q] then return seedScore[p] > seedScore[q] end
						return seedKey[p] < seedKey[q]
					end)
					budget = budget - 4 * #order
					phase, index = "place", 1
				else
					budget = budget - evaluate(index)
					index = index + 1
				end
			elseif phase == "place" then
				if index > #order then
					phase, cursor = "leftover scan", nil
				else
					local i = order[index]
					index = index + 1
					local key, b = seedKey[i], seedBand[i]
					budget = budget - 1
					if not covered[b][key] then
						budget = budget - place(key, b, seedWi[i], seedAi[i], seedHi[i])
					end
				end
			elseif phase == "leftover scan" then
				-- Walked cells no shape reached get a small circle each, in key
				-- order so the result is repeatable.
				local key, d = next(dist, cursor)
				if key == nil then
					table.sort(leftovers)
					budget = budget - 4 * #leftovers
					phase, index = "leftover place", 1
				else
					cursor = key
					budget = budget - 2
					local b = bandOf(d)
					if b and not covered[b][key] then leftovers[#leftovers + 1] = key end
				end
			else -- leftover place
				if index > #leftovers then
					job.done = true
				else
					local key = leftovers[index]
					index = index + 1
					local b = bandOf(dist[key])
					budget = budget - 1
					if not covered[b][key] then
						budget = budget - place(key, b, 1, 1, 1)
					end
				end
			end
		end
		return job.done
	end

	return job
end
