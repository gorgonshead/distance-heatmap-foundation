local mod = ...

-- Walking distance from a building through walked cells, as a job that settles a
-- budgeted number of cells per frame.
--
-- Dijkstra's algorithm on the grid with 16 step directions: the 8 neighbours
-- plus the 8 knight steps (2 cells one way, 1 the other). With 8 directions a
-- straight route at an odd angle measures up to 8% long; with 16, about 3%. A
-- knight step needs one of the two cells it passes between to be walked, so it
-- cannot hop the gap between two separate trails.

local cfg = PathHeatmap.cfg
local grid = PathHeatmap.grid
local CELL, STRIDE = grid.CELL, grid.STRIDE
local BANDS = cfg.BANDS
local MAX_DIST = BANDS[#BANDS]
local floor, ceil, sqrt = math.floor, math.ceil, math.sqrt

-- Steps as key offsets, in parallel arrays. VIA_A/VIA_B are false except for
-- knight steps, where they are the two cells passed between.
local STEP_OFFSET, STEP_COST, VIA_A, VIA_B = {}, {}, {}, {}
local function addStep(dx, dz, a, b)
	local i = #STEP_OFFSET + 1
	STEP_OFFSET[i] = dx * STRIDE + dz
	STEP_COST[i] = sqrt(dx * dx + dz * dz) * CELL
	VIA_A[i] = a and (a[1] * STRIDE + a[2]) or false
	VIA_B[i] = b and (b[1] * STRIDE + b[2]) or false
end
for dx = -1, 1 do
	for dz = -1, 1 do
		if dx ~= 0 or dz ~= 0 then addStep(dx, dz) end
	end
end
for _, s in ipairs({ { 2, 1 }, { 2, -1 }, { -2, 1 }, { -2, -1 } }) do
	local long, side = s[1], s[2]
	local half = long / 2
	addStep(long, side, { half, 0 }, { half, side }) -- 2 along x, 1 along z
	addStep(side, long, { 0, half }, { side, half }) -- 1 along x, 2 along z
end
local STEPS = #STEP_OFFSET

-- Index into BANDS for a distance (1 = nearest band), or nil past the last.
function PathHeatmap.bandOf(d)
	for i = 1, #BANDS do
		if d <= BANDS[i] then return i end
	end
end

-- A search from start points { x, z, radius }: walked cells within `radius` of a
-- point start at their straight-line distance from it, so several entrances are
-- searched at once. job.step(budget) settles up to `budget` heap entries and
-- returns true when finished; job.dist then maps key -> metres, or is nil if no
-- walked cell was near any start point.
function PathHeatmap.newSearchJob(points)
	local job = { done = false, settled = 0, seeds = 0 }
	local dist, settled = {}, {}
	local heapD, heapK, size = {}, {}, 0

	local function push(d, k)
		size = size + 1
		local i = size
		while i > 1 do
			local p = floor(i / 2)
			local pd = heapD[p]
			if pd <= d then break end
			heapD[i], heapK[i] = pd, heapK[p]
			i = p
		end
		heapD[i], heapK[i] = d, k
	end

	local function pop()
		local d0, k0 = heapD[1], heapK[1]
		local d, k = heapD[size], heapK[size]
		heapD[size], heapK[size] = nil, nil
		size = size - 1
		if size > 0 then
			local i = 1
			while true do
				local c = i * 2
				if c > size then break end
				if c < size and heapD[c + 1] < heapD[c] then c = c + 1 end
				if heapD[c] >= d then break end
				heapD[i], heapK[i] = heapD[c], heapK[c]
				i = c
			end
			heapD[i], heapK[i] = d, k
		end
		return d0, k0
	end

	for _, pt in ipairs(points) do
		local ox, oz = floor(pt.x / CELL), floor(pt.z / CELL)
		local radius = pt.radius or cfg.SEED_RADIUS
		local reach = ceil(radius / CELL)
		for dx = -reach, reach do
			for dz = -reach, reach do
				local key = grid.keyOf(ox + dx, oz + dz)
				if grid.isActive(key) then
					local ex = (ox + dx + 0.5) * CELL - pt.x
					local ez = (oz + dz + 0.5) * CELL - pt.z
					local d = sqrt(ex * ex + ez * ez)
					if d <= radius and (dist[key] == nil or d < dist[key]) then
						if dist[key] == nil then job.seeds = job.seeds + 1 end
						dist[key] = d
						push(d, key)
					end
				end
			end
		end
	end

	function job.step(budget)
		-- Read live: prune may rebase the weights between frames.
		local weights, threshold = grid.weights, grid.activeScaled
		while budget > 0 and size > 0 do
			budget = budget - 1
			local d, k = pop()
			if not settled[k] and d <= dist[k] then
				settled[k] = true
				job.settled = job.settled + 1
				for i = 1, STEPS do
					local nd = d + STEP_COST[i]
					if nd <= MAX_DIST then
						local nk = k + STEP_OFFSET[i]
						local current = dist[nk]
						if current == nil or nd < current then
							local s = weights[nk]
							if s and s >= threshold then
								local a = VIA_A[i]
								if not a or (weights[k + a] or 0) >= threshold
										or (weights[k + VIA_B[i]] or 0) >= threshold then
									dist[nk] = nd
									push(nd, nk)
								end
							end
						end
					end
				end
			end
		end
		if size == 0 then
			job.done = true
			job.dist = job.seeds > 0 and dist or nil
		end
		return job.done
	end

	return job
end

-- Cells per band, for the debug log.
function PathHeatmap.bandCounts(dist)
	local counts = {}
	for i = 1, #BANDS do counts[i] = 0 end
	for _, d in pairs(dist) do
		local b = PathHeatmap.bandOf(d)
		if b then counts[b] = counts[b] + 1 end
	end
	return counts
end
