local mod = ...

-- Decaying walk-sample grid and walking-distance search.
--
-- Villager positions are binned into CELL-sized squares on the ground plane.
-- Each cell holds "seconds of presence", which halves every HALF_LIFE_DAYS so
-- old routes fade. A cell counts as walkable while its decayed weight stays
-- above ACTIVE_WEIGHT. Distance from a building is a Dijkstra search over
-- walkable cells, so it follows where people really walk, not straight lines.

local CELL = 2.0
-- Decay tuning. A villager crossing a cell adds about 1.3 s of presence, so with
-- these values one crossing keeps a cell walkable for about 7 game days, and a
-- cell pinned at MAX_WEIGHT by someone standing there fades after about 14. A
-- game day is 60 s here, so those are 7 and 14 minutes at normal speed. Raise
-- HALF_LIFE_DAYS if trails fragment, lower it if abandoned routes linger.
local MAX_WEIGHT = 6        -- cap so idle workers do not pin a cell for long
local ACTIVE_WEIGHT = 0.25  -- decayed weight needed to count as walkable
local SEED_RADIUS = 12      -- default reach from a start point to a walked cell; entrances override it
local MAX_DIST = 150
local BANDS = { 50, 100, 150 }
local HALF_LIFE_DAYS = 3
local DIAG = CELL * 1.41421356

local OFFSET, STRIDE = 50000, 100000

local function cellOf(x, z)
	return math.floor(x / CELL), math.floor(z / CELL)
end

local function keyOf(cx, cz)
	return (cx + OFFSET) * STRIDE + (cz + OFFSET)
end

local function coordsOf(key)
	return math.floor(key / STRIDE) - OFFSET, key % STRIDE - OFFSET
end

PathHeatmap.weights = {}
PathHeatmap.stamps = {}
PathHeatmap.heights = {} -- last ground height seen per cell, for marker placement
PathHeatmap.halfLife = 300 -- seconds; overwritten from the day length once known

function PathHeatmap.setDayLength(seconds)
	PathHeatmap.halfLife = seconds * HALF_LIFE_DAYS
end

local function weightAt(key, now)
	local w = PathHeatmap.weights[key]
	if not w then return 0 end
	return w * 0.5 ^ ((now - PathHeatmap.stamps[key]) / PathHeatmap.halfLife)
end

function PathHeatmap.addSample(x, y, z, dt, now)
	local key = keyOf(cellOf(x, z))
	PathHeatmap.heights[key] = y
	PathHeatmap.weights[key] = math.min(weightAt(key, now) + dt, MAX_WEIGHT)
	PathHeatmap.stamps[key] = now
end

function PathHeatmap.prune(now)
	local removed = 0
	for key in pairs(PathHeatmap.weights) do
		if weightAt(key, now) < ACTIVE_WEIGHT * 0.1 then
			PathHeatmap.weights[key] = nil
			PathHeatmap.stamps[key] = nil
			PathHeatmap.heights[key] = nil
			removed = removed + 1
		end
	end
	return removed
end

function PathHeatmap.countCells(now)
	local total, active = 0, 0
	for key in pairs(PathHeatmap.weights) do
		total = total + 1
		if weightAt(key, now) >= ACTIVE_WEIGHT then active = active + 1 end
	end
	return total, active
end

-- Save/load. Weights are written already decayed to `now` and restored with a
-- fresh timestamp: the mod clock restarts at 0 on every load, and game time does
-- not pass while a save sits on disk. Format: "v1;" then ";"-separated
-- "cx,cz,weight,height" entries.
function PathHeatmap.export(now)
	local parts = { "v1" }
	for key in pairs(PathHeatmap.weights) do
		local w = weightAt(key, now)
		if w >= ACTIVE_WEIGHT * 0.1 then
			local cx, cz = coordsOf(key)
			parts[#parts + 1] = string.format("%d,%d,%.3f,%.1f", cx, cz, w, PathHeatmap.heights[key] or 0)
		end
	end
	return table.concat(parts, ";")
end

function PathHeatmap.import(str, now)
	if type(str) ~= "string" or string.sub(str, 1, 3) ~= "v1;" then return 0 end
	local n = 0
	for entry in string.gmatch(string.sub(str, 4), "[^;]+") do
		local cx, cz, w, y = string.match(entry, "^(-?%d+),(-?%d+),([%d.]+),(-?[%d.]+)$")
		if cx then
			local key = keyOf(tonumber(cx), tonumber(cz))
			PathHeatmap.weights[key] = math.min(tonumber(w), MAX_WEIGHT) -- older saves used a higher cap
			PathHeatmap.stamps[key] = now
			PathHeatmap.heights[key] = tonumber(y)
			n = n + 1
		end
	end
	return n
end

-- Minimal binary min-heap of { distance, key }.
local function heapPush(heap, d, key)
	local i = #heap + 1
	heap[i] = { d, key }
	while i > 1 do
		local p = math.floor(i / 2)
		if heap[p][1] <= heap[i][1] then break end
		heap[p], heap[i] = heap[i], heap[p]
		i = p
	end
end

local function heapPop(heap)
	local top = heap[1]
	local last = table.remove(heap)
	local n = #heap
	if n > 0 then
		heap[1] = last
		local i = 1
		while true do
			local l, r, m = i * 2, i * 2 + 1, i
			if l <= n and heap[l][1] < heap[m][1] then m = l end
			if r <= n and heap[r][1] < heap[m][1] then m = r end
			if m == i then break end
			heap[m], heap[i] = heap[i], heap[m]
			i = m
		end
	end
	return top
end

local NEIGHBOURS = {
	{ 1, 0, CELL }, { -1, 0, CELL }, { 0, 1, CELL }, { 0, -1, CELL },
	{ 1, 1, DIAG }, { 1, -1, DIAG }, { -1, 1, DIAG }, { -1, -1, DIAG },
}

-- Walking distance (metres) from a set of start points to every walked cell
-- within MAX_DIST. Each point is { x, z, radius }: walked cells within `radius`
-- metres of it become starting cells, at their straight-line distance from the
-- point. Several points (a building's entrances) are searched at once.
-- Returns dist (key -> metres), band counts, and a status string.
function PathHeatmap.distanceField(points, now)
	local heap, dist = {}, {}
	local seeds = 0
	for _, pt in ipairs(points) do
		local ox, oz = cellOf(pt.x, pt.z)
		local radius = pt.radius or SEED_RADIUS
		local reach = math.ceil(radius / CELL)
		for dx = -reach, reach do
			for dz = -reach, reach do
				local key = keyOf(ox + dx, oz + dz)
				if weightAt(key, now) >= ACTIVE_WEIGHT then
					local ex = (ox + dx + 0.5) * CELL - pt.x
					local ez = (oz + dz + 0.5) * CELL - pt.z
					local d = math.sqrt(ex * ex + ez * ez)
					if d <= radius and (dist[key] == nil or d < dist[key]) then
						if dist[key] == nil then seeds = seeds + 1 end
						dist[key] = d
						heapPush(heap, d, key)
					end
				end
			end
		end
	end
	if seeds == 0 then
		return nil, nil, "no walked cells near the building's start points"
	end

	local done = {}
	while #heap > 0 do
		local item = heapPop(heap)
		local d, key = item[1], item[2]
		if not done[key] and d <= dist[key] then
			done[key] = true
			local cx, cz = coordsOf(key)
			for _, n in ipairs(NEIGHBOURS) do
				local nk = keyOf(cx + n[1], cz + n[2])
				local nd = d + n[3]
				if nd <= MAX_DIST and (dist[nk] == nil or nd < dist[nk]) and weightAt(nk, now) >= ACTIVE_WEIGHT then
					dist[nk] = nd
					heapPush(heap, nd, nk)
				end
			end
		end
	end

	local counts = {}
	for _, b in ipairs(BANDS) do counts[b] = 0 end
	for _, d in pairs(dist) do
		for _, b in ipairs(BANDS) do
			if d <= b then
				counts[b] = counts[b] + 1
				break
			end
		end
	end
	return dist, counts, seeds .. " seed cells"
end

PathHeatmap.BANDS = BANDS
PathHeatmap.cellOf = cellOf
PathHeatmap.coordsOf = coordsOf
PathHeatmap.keyOf = keyOf
PathHeatmap.CELL = CELL
PathHeatmap.SEED_RADIUS = SEED_RADIUS
