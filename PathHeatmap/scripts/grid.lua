local mod = ...

-- Decaying grid of where people have walked.
--
-- Positions are binned into CELL-sized squares on the ground plane. Each cell
-- holds seconds of presence that halve every half-life, so old routes fade.
--
-- Decay is applied without touching cells: a weight is stored multiplied by
-- gain = 2^((t - epoch) / halfLife) for the time t it was written. Reading at
-- time now divides by the gain at now. Adding, capping and the walkable test
-- then need no power function per cell, only the one gain per frame. The gain
-- grows without bound, so prune() occasionally rebases every cell onto a new
-- epoch.

local cfg = PathHeatmap.cfg
local CELL = cfg.CELL
local MAX_WEIGHT = cfg.MAX_WEIGHT
local ACTIVE_WEIGHT = cfg.ACTIVE_WEIGHT
local floor = math.floor

-- A key packs two cell coordinates into one number: (cx + OFFSET) * STRIDE +
-- (cz + OFFSET). Neighbouring keys differ by fixed amounts (dx * STRIDE + dz),
-- which the search and planner use as precomputed offsets.
local OFFSET, STRIDE = 50000, 100000

local REBASE_ABOVE = 2 ^ 30 -- gain at which prune() rebases

local grid = {
	weights = {}, -- key -> weight x gain at write time
	heights = {}, -- key -> last height seen, for marker placement
	epoch = 0,
	halfLife = 300, -- game seconds; replaced from the day length at level start
	now = 0,
	gain = 1,
	activeScaled = ACTIVE_WEIGHT, -- ACTIVE_WEIGHT x gain: the walkable test
	capScaled = MAX_WEIGHT,
	CELL = CELL,
	STRIDE = STRIDE,
}
PathHeatmap.grid = grid

function grid.keyOf(cx, cz)
	return (cx + OFFSET) * STRIDE + (cz + OFFSET)
end

function grid.coordsOf(key)
	return floor(key / STRIDE) - OFFSET, key % STRIDE - OFFSET
end

function grid.keyAt(x, z)
	return (floor(x / CELL) + OFFSET) * STRIDE + (floor(z / CELL) + OFFSET)
end

function grid.reset()
	grid.weights, grid.heights = {}, {}
	grid.epoch, grid.now = 0, 0
	grid.setTime(0)
end

function grid.configureDecay(seconds)
	grid.halfLife = seconds * cfg.HALF_LIFE_DAYS
	grid.setTime(grid.now)
end

-- Call once per frame before sampling or searching.
function grid.setTime(now)
	grid.now = now
	grid.gain = 2 ^ ((now - grid.epoch) / grid.halfLife)
	grid.activeScaled = ACTIVE_WEIGHT * grid.gain
	grid.capScaled = MAX_WEIGHT * grid.gain
end

function grid.addSample(x, y, z, weight)
	local key = (floor(x / CELL) + OFFSET) * STRIDE + (floor(z / CELL) + OFFSET)
	local weights = grid.weights
	local s = (weights[key] or 0) + weight * grid.gain
	local cap = grid.capScaled
	if s > cap then s = cap end
	weights[key] = s
	grid.heights[key] = y
end

function grid.weightAt(key)
	local s = grid.weights[key]
	return s and s / grid.gain or 0
end

function grid.isActive(key)
	local s = grid.weights[key]
	return s ~= nil and s >= grid.activeScaled
end

-- Remove cells that are no longer walkable; they add nothing to a search, and a
-- re-walked cell is walkable again after one crossing. Rebases when the gain
-- gets large. Returns the number of cells removed.
function grid.prune()
	local weights, heights = grid.weights, grid.heights
	local threshold = grid.activeScaled
	local rebase = grid.gain > REBASE_ABOVE
	local scale = rebase and 1 / grid.gain or 1
	local removed = 0
	for key, s in pairs(weights) do
		if s < threshold then
			weights[key] = nil
			heights[key] = nil
			removed = removed + 1
		elseif rebase then
			weights[key] = s * scale
		end
	end
	if rebase then
		grid.epoch = grid.now
		grid.setTime(grid.now)
	end
	return removed
end

function grid.count()
	local total, active = 0, 0
	local threshold = grid.activeScaled
	for _, s in pairs(grid.weights) do
		total = total + 1
		if s >= threshold then active = active + 1 end
	end
	return total, active
end

-- Save format -----------------------------------------------------------------
--
-- v2: "v2;" followed by one record per grid column (fixed cx), in any order:
--   cx + 2048 as 2 base-64 digits, the cell count as 2 digits, then per cell in
--   ascending cz: the cz step as a base-32 varint (the first cell stores
--   cz + 2048), the weight as 1 digit (1..63 of MAX_WEIGHT), and the height as
--   2 digits (quarter metres from -512 m).
-- That is 3 to 6 characters per cell (columns along a trail are cheap, short
-- columns across one pay for their header), against about 25 for v1. Cells more
-- than 4 km from the map origin are not saved.
-- v1 (older saves): "v1;" then "cx,cz,weight,height" entries separated by ";".

local DIGITS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local DIGIT_BYTE, DIGIT_VALUE = {}, {}
for i = 1, 64 do
	local b = string.byte(DIGITS, i)
	DIGIT_BYTE[i - 1] = b
	DIGIT_VALUE[b] = i - 1
end
local COORD_OFFSET = 2048
local HEIGHT_OFFSET, HEIGHT_STEPS = 512, 4
local MAX_COLUMN = 4095
local unpack = unpack or table.unpack

-- Builds the save string a few thousand cells per step, so a large history does
-- not stall one frame. First it walks the grid with next() to group cells into
-- columns: while job.snapshotting is true the grid must not gain or lose cells
-- (the sampler waits, prune waits for the whole job). Then it encodes the
-- columns into a byte buffer that becomes one string per step. Cells added
-- after the walk are left for the next export.
function grid.newExportJob()
	local job = { done = false, cells = 0, snapshotting = true }
	local columns, order = {}, {}
	local cursor = nil

	local function snapshot(budget)
		local weights, threshold = grid.weights, grid.activeScaled
		local key, s = next(weights, cursor)
		while key ~= nil and budget > 0 do
			budget = budget - 1
			if s >= threshold then
				local cx = floor(key / STRIDE) - OFFSET
				local col = columns[cx]
				if not col then
					col = {}
					columns[cx] = col
					order[#order + 1] = cx
				end
				col[#col + 1] = key % STRIDE - OFFSET
			end
			cursor = key
			key, s = next(weights, key)
		end
		if key == nil then job.snapshotting = false end
		return budget
	end

	local pieces = { "v2;" }
	local buf, n = {}, 0
	local index = 1

	local function flush()
		local i = 1
		while i <= n do
			local j = math.min(i + 3999, n)
			pieces[#pieces + 1] = string.char(unpack(buf, i, j))
			i = j + 1
		end
		n = 0
	end

	function job.step(budget)
		if job.snapshotting then
			-- Walking is cheaper per cell than encoding.
			snapshot(budget * 4)
			return false
		end
		local weights, heights = grid.weights, grid.heights
		local toWeight = 63 / (MAX_WEIGHT * grid.gain)
		while budget > 0 and index <= #order do
			local cx = order[index]
			index = index + 1
			local col = columns[cx]
			budget = budget - #col
			table.sort(col)
			local count = 0
			if cx >= -COORD_OFFSET and cx < COORD_OFFSET then
				for i = 1, #col do
					local cz = col[i]
					if cz >= -COORD_OFFSET and cz < COORD_OFFSET then count = count + 1 end
				end
			end
			if count > MAX_COLUMN then count = MAX_COLUMN end
			if count > 0 then
				local v = cx + COORD_OFFSET
				buf[n + 1], buf[n + 2] = DIGIT_BYTE[floor(v / 64)], DIGIT_BYTE[v % 64]
				buf[n + 3], buf[n + 4] = DIGIT_BYTE[floor(count / 64)], DIGIT_BYTE[count % 64]
				n = n + 4
				local base = (cx + OFFSET) * STRIDE + OFFSET
				local previous, written = nil, 0
				for i = 1, #col do
					local cz = col[i]
					if written < count and cz >= -COORD_OFFSET and cz < COORD_OFFSET then
						written = written + 1
						local key = base + cz
						v = previous and (cz - previous) or (cz + COORD_OFFSET)
						previous = cz
						while v >= 32 do
							n = n + 1
							buf[n] = DIGIT_BYTE[32 + v % 32]
							v = floor(v / 32)
						end
						local q = floor((weights[key] or 0) * toWeight + 0.5)
						if q < 1 then q = 1 elseif q > 63 then q = 63 end
						local h = floor(((heights[key] or 0) + HEIGHT_OFFSET) * HEIGHT_STEPS + 0.5)
						if h < 0 then h = 0 elseif h > 4095 then h = 4095 end
						buf[n + 1], buf[n + 2] = DIGIT_BYTE[v], DIGIT_BYTE[q]
						buf[n + 3], buf[n + 4] = DIGIT_BYTE[floor(h / 64)], DIGIT_BYTE[h % 64]
						n = n + 4
					end
				end
				job.cells = job.cells + count
			end
		end
		flush()
		if index > #order then
			job.result = table.concat(pieces)
			job.done = true
		end
		return job.done
	end

	return job
end

function grid.export()
	local job = grid.newExportJob()
	repeat until job.step(math.huge)
	return job.result
end

local function importV1(str, now)
	local n = 0
	for entry in string.gmatch(string.sub(str, 4), "[^;]+") do
		local cx, cz, w, y = string.match(entry, "^(-?%d+),(-?%d+),([%d.]+),(-?[%d.]+)$")
		if cx then
			local key = grid.keyOf(tonumber(cx), tonumber(cz))
			grid.weights[key] = math.min(tonumber(w), MAX_WEIGHT) * grid.gain -- older saves used a higher cap
			grid.heights[key] = tonumber(y)
			n = n + 1
		end
	end
	return n
end

local function importV2(str)
	local byte = string.byte
	local pos, len = 4, #str
	local function digit()
		local v = DIGIT_VALUE[byte(str, pos)]
		pos = pos + 1
		if v == nil then error("bad character at " .. (pos - 1)) end
		return v
	end
	local function get2()
		local hi = digit()
		return hi * 64 + digit()
	end
	local function getVarint()
		local v, scale = 0, 1
		while true do
			local d = digit()
			if d >= 32 then
				v = v + (d - 32) * scale
				scale = scale * 32
			else
				return v + d * scale
			end
		end
	end

	local weights, heights, gain = grid.weights, grid.heights, grid.gain
	local n = 0
	while pos <= len do
		local cx = get2() - COORD_OFFSET
		local count = get2()
		local cz = nil
		for _ = 1, count do
			local step = getVarint()
			cz = cz and (cz + step) or (step - COORD_OFFSET)
			local w = digit() * MAX_WEIGHT / 63
			local h = get2() / HEIGHT_STEPS - HEIGHT_OFFSET
			local key = grid.keyOf(cx, cz)
			weights[key] = w * gain
			heights[key] = h
			n = n + 1
		end
	end
	return n
end

-- Restores a saved history into the current grid. Returns the cell count, and an
-- error message if the string was damaged (cells read before the damage are kept).
function grid.import(str)
	if type(str) ~= "string" then return 0 end
	local version = string.sub(str, 1, 3)
	if version == "v1;" then return importV1(str) end
	if version ~= "v2;" then return 0 end
	local before = 0
	for _ in pairs(grid.weights) do before = before + 1 end
	local ok, result = pcall(importV2, str)
	if ok then return result end
	local after = 0
	for _ in pairs(grid.weights) do after = after + 1 end
	return after - before, tostring(result)
end
