local mod = ...

-- One global component on the level's manager prefab. Each frame it samples
-- every walking agent into the decaying grid, and it listens for building
-- selection so the distance field can be computed from the selected building.
-- (PREFAB_MANAGER resolves; guessed agent prefab ids break new-game setup.)

local COMP_PATH_SAMPLER = {
	TypeName = "COMP_PATH_SAMPLER",
	ParentType = "COMPONENT",
	Properties = {
		-- Walk history, written by export() and read back in init().
		{ Name = "SavedCells", Type = "string", Default = "", Flags = { "SAVE_GAME" } },
	},
}

-- Component types that represent walking people.
local AGENT_TYPES = { "COMP_VILLAGER", "COMP_VISITOR", "COMP_GUEST" }
local RECOMPUTE_EVERY = 5 -- seconds, while a building is selected
local PRUNE_EVERY = 60
local LOG_EVERY = 10
local SAVE_EVERY = 30 -- game seconds between refreshes of the saved string

function COMP_PATH_SAMPLER:create()
	self._sinceRecompute = 0
	self._sincePrune = 0
	self._sinceLog = 0
	self._sinceSave = 0
end

function COMP_PATH_SAMPLER:init()
	local level = self:getLevel()

	local ok, dayLength = pcall(function()
		return level:find("COMP_MAIN_GAME_LOOP"):getDayDurationInSeconds()
	end)
	if ok and type(dayLength) == "number" and dayLength > 0 then
		PathHeatmap.setDayLength(dayLength)
	end
	mod:log("day length " .. tostring(dayLength) .. " s, half-life " .. PathHeatmap.halfLife .. " s")

	PathHeatmap.sweepMarkers()

	PathHeatmap.clock = PathHeatmap.clock or 0
	local saved = self.SavedCells
	local restored = PathHeatmap.import(saved, PathHeatmap.clock)
	mod:log("restored " .. restored .. " cells from save (" .. tostring(saved and #saved or "nil") .. " chars)")

	local buildings = level:getComponentManager("COMP_BUILDING")
	buildings:getAllComponent():forEach(function(building)
		self:watchBuilding(building)
	end)
	event.register(self, buildings.ON_COMPONENT_INITIALIZED, function(building)
		self:watchBuilding(building)
	end)
end

function COMP_PATH_SAMPLER:watchBuilding(building)
	event.register(self, building.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, function(isHighlighted)
		self:onHighlight(building, isHighlighted)
	end)
end

local ENTRANCE_RADIUS = 6 -- metres from an entrance to look for a walked cell
-- The game's own marker for where villagers enter a building. Looser matches
-- ("door", "gate") also catch door model parts and attach nodes, which are not
-- entrances: a tax office reported 31 "entrances" that way, and has two.
local ENTRANCE_NAME = "Building Entrance Indicator"

local function isEntrance(name)
	return string.sub(name, 1, #ENTRANCE_NAME) == ENTRANCE_NAME
end

-- Start points for the distance search: entrance objects found in the
-- building's object tree, or the building origin if none is found.
-- getComponentManager("COMP_ENTRANCE_LOCATION") is rejected, and no child carries
-- that component, so entrances are found by their object name. What is found is
-- logged on selection, since none of this is documented.
function COMP_PATH_SAMPLER:findStartPoints(building)
	local owner = building:getOwner()
	local origin = owner:getGlobalPosition()
	local points, children = {}, 0

	local ok, err = pcall(function()
		owner:forEachChildRecursive(function(child)
			children = children + 1
			if isEntrance(tostring(child.Name)) then
				local p = child:getGlobalPosition()
				-- The same indicator is reachable twice through the object tree
				-- on some buildings; skip repeats at the same spot.
				local seen = false
				for _, q in ipairs(points) do
					if math.abs(q.x - p.x) < 0.25 and math.abs(q.z - p.z) < 0.25 then seen = true end
				end
				if not seen then
					points[#points + 1] = { x = p.x, z = p.z, radius = ENTRANCE_RADIUS }
					PathHeatmap.debug(string.format("  entrance at %+.1f, %+.1f from origin", p.x - origin.x, p.z - origin.z))
				end
			end
		end)
	end)
	if not ok then mod:logWarning("child walk failed: " .. tostring(err)) end

	PathHeatmap.debug(string.format("children: %d, entrances: %d", children, #points))

	if #points == 0 then
		points[1] = { x = origin.x, z = origin.z, radius = PathHeatmap.SEED_RADIUS }
	end
	return points
end

function COMP_PATH_SAMPLER:onHighlight(building, isHighlighted)
	local name = tostring(building:getOwner().Name)
	if isHighlighted then
		PathHeatmap.selected = building
		PathHeatmap.debug("selected: " .. name)
		PathHeatmap.startPoints = self:findStartPoints(building)
		self:recompute(true)
	elseif PathHeatmap.selected == building then
		PathHeatmap.selected = nil
		PathHeatmap.field = nil
		PathHeatmap.clearMarkers()
		PathHeatmap.debug("deselected: " .. name)
	end
end

function COMP_PATH_SAMPLER:recompute(verbose)
	local building = PathHeatmap.selected
	if not building then return end
	local dist, counts, status = PathHeatmap.distanceField(PathHeatmap.startPoints, PathHeatmap.clock)
	PathHeatmap.field = dist
	if dist then
		local ok, err = pcall(PathHeatmap.updateMarkers, self:getLevel(), dist)
		if not ok then mod:logError("updateMarkers failed: " .. tostring(err)) end
	else
		PathHeatmap.clearMarkers()
	end
	if verbose then
		if not dist then
			PathHeatmap.debug("distance field: " .. status)
		else
			local parts = {}
			for _, b in ipairs(PathHeatmap.BANDS) do
				parts[#parts + 1] = string.format("<=%dm: %d cells", b, counts[b] or 0)
			end
			PathHeatmap.debug("distance field (" .. status .. "): " .. table.concat(parts, ", "))
		end
	end
end

function COMP_PATH_SAMPLER:sampleType(typeName, dt)
	local ok, list = pcall(function()
		return self:getLevel():getComponentManager(typeName):getAllEnabledComponent()
	end)
	if not ok then return 0 end
	local n = 0
	list:forEach(function(agent)
		local pos = agent:getOwner():getGlobalPosition()
		PathHeatmap.addSample(pos.x, pos.y, pos.z, dt, PathHeatmap.clock)
		n = n + 1
	end)
	return n
end

function COMP_PATH_SAMPLER:update()
	local level = self:getLevel()
	local dt = level:getDeltaTime()
	PathHeatmap.clock = (PathHeatmap.clock or 0) + dt
	PathHeatmap.realClock = (PathHeatmap.realClock or 0) + level:getUnscaledDeltaTime()

	local counts = {}
	for _, t in ipairs(AGENT_TYPES) do
		counts[#counts + 1] = t .. "=" .. self:sampleType(t, dt)
	end

	self._sinceRecompute = self._sinceRecompute + dt
	if PathHeatmap.selected and self._sinceRecompute >= RECOMPUTE_EVERY then
		self._sinceRecompute = 0
		self:recompute(false)
	end

	self._sincePrune = self._sincePrune + dt
	if self._sincePrune >= PRUNE_EVERY then
		self._sincePrune = 0
		PathHeatmap.prune(PathHeatmap.clock)
	end

	self._sinceSave = self._sinceSave + dt
	if self._sinceSave >= SAVE_EVERY then
		self._sinceSave = 0
		self:store()
	end

	self._sinceLog = self._sinceLog + dt
	if self._sinceLog >= LOG_EVERY then
		self._sinceLog = 0
		local total, active = PathHeatmap.countCells(PathHeatmap.clock)
		PathHeatmap.debug(string.format("time: scale=%.2f game=%.1fs real=%.1fs",
			level:getTimeScale(), PathHeatmap.clock, PathHeatmap.realClock))
		PathHeatmap.debug("sample " .. table.concat(counts, " ") .. string.format(", cells=%d active=%d", total, active))
	end
end

function COMP_PATH_SAMPLER:store()
	local ok, err = pcall(function()
		self.SavedCells = PathHeatmap.export(PathHeatmap.clock)
	end)
	if not ok then mod:logError("saving cells failed: " .. tostring(err)) end
end

function COMP_PATH_SAMPLER:onFinalize(isClearingLevel)
	self:store()
	PathHeatmap.clearMarkers()
end

mod:registerClass(COMP_PATH_SAMPLER)
mod:registerPrefabComponent("PREFAB_MANAGER", { DataType = "COMP_PATH_SAMPLER" })
