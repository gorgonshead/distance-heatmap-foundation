local mod = ...

-- One global component on the level's manager prefab. It samples where people
-- walk, watches building selection, and runs the overlay pipeline for the
-- selected building a budgeted amount per frame:
--   search (walking distances) -> plan (shapes) -> reconcile (markers).
-- (PREFAB_MANAGER resolves; guessed agent prefab ids break new-game setup.)

local cfg = PathHeatmap.cfg
local grid = PathHeatmap.grid
local overlay = PathHeatmap.overlay
local trace = PathHeatmap.debug
local DEBUG = cfg.DEBUG

local COMP_PATH_SAMPLER = {
	TypeName = "COMP_PATH_SAMPLER",
	ParentType = "COMPONENT",
	Properties = {
		-- Walk history, written by grid export jobs and read back in init().
		{ Name = "SavedCells", Type = "string", Default = "", Flags = { "SAVE_GAME" } },
	},
}

-- Sampling ---------------------------------------------------------------------
-- One sampler exists per level and only one level updates at a time, so the
-- per-cycle values live in upvalues; the callbacks are made once, not per frame.

local addSample = grid.addSample
local sampleWeight, sampledCount = 0, 0
local cycleManagers = {}

local function sampleAgent(agent)
	local p = agent:getOwner():getGlobalPosition()
	addSample(p.x, p.y, p.z, sampleWeight)
	sampledCount = sampledCount + 1
end

local function sampleCycle()
	for i = 1, #cycleManagers do
		cycleManagers[i]:getAllEnabledComponent():forEach(sampleAgent)
	end
end

-- Entrances ----------------------------------------------------------------------

-- The game's own marker for where villagers enter a building. Looser matches
-- ("door", "gate") also catch door model parts and attach nodes: a tax office
-- reported 31 "entrances" that way, and has two. No child carries the
-- engine's COMP_ENTRANCE_LOCATION, so the name is the only handle.
local ENTRANCE_NAME = "Building Entrance Indicator"

-- Events after which a building's entrances may have moved.
local BUILDING_CHANGE_EVENTS = {
	"ON_BUILDING_CHANGED", "ON_BUILDING_PART_BUILT", "ON_BUILDING_PART_REMOVED",
	"ON_UPGRADING", "ON_BUILDING_COMPLETED",
}

-- Debug only: the chain of parents from an indicator up to the building, to
-- learn where indicators sit in the tree.
local pathsLogged = 0
local function logEntrancePath(indicator, owner)
	local names, node, depth = { ENTRANCE_NAME }, indicator, 0
	local ownerName = tostring(owner.Name)
	while depth < 10 do
		local ok, parent = pcall(node.getParent, node)
		if not ok or not parent then break end
		depth = depth + 1
		local name = tostring(parent.Name)
		names[#names + 1] = name
		if name == ownerName then break end
		node = parent
	end
	trace(string.format("entrance path (%d levels below %s): %s", depth, ownerName, table.concat(names, " < ")))
end

-- Walks the whole object tree under the building. Costs one engine call per
-- child object, which is thousands on a large building.
local function walkEntrances(building)
	local owner = building:getOwner()
	local origin = owner:getGlobalPosition()
	local points, children = {}, 0
	local logPath = DEBUG and pathsLogged < 6
	local ok, err = pcall(owner.forEachChildRecursive, owner, function(child)
		children = children + 1
		if string.sub(tostring(child.Name), 1, #ENTRANCE_NAME) == ENTRANCE_NAME then
			local p = child:getGlobalPosition()
			-- Some buildings reach the same indicator twice through the tree.
			for _, q in ipairs(points) do
				if math.abs(q.x - p.x) < 0.25 and math.abs(q.z - p.z) < 0.25 then return end
			end
			points[#points + 1] = { x = p.x, z = p.z, radius = cfg.ENTRANCE_RADIUS }
			if logPath then
				logPath = false
				pathsLogged = pathsLogged + 1
				logEntrancePath(child, owner)
			end
		end
	end)
	if not ok then mod:logWarning("child walk failed: " .. tostring(err)) end
	if #points == 0 then
		points[1] = { x = origin.x, z = origin.z, radius = cfg.SEED_RADIUS }
	end
	return points, children
end

-- Debug only, once: whether level:find accepts a plain table as its out list,
-- and how many indicators the level holds. Decides whether a level-wide lookup
-- could replace the tree walk.
local function probeFind(level)
	local out = {}
	local ok, err = pcall(level.find, level, ENTRANCE_NAME, out)
	local count = 0
	for _ in pairs(out) do count = count + 1 end
	trace(string.format("level:find probe: %s, %d indicators returned",
		ok and "call accepted" or ("failed: " .. tostring(err)), count))
end

-- Debug only, once: whether the entrance list in the building part asset can be
-- read from Lua. BUILDING_PATH_DATA holds an EntranceList (WaypointId, Hidden,
-- Water) indexing a WaypointPositionList; the game data stores it in each
-- BUILDING_PART asset, apparently as "BuildingPath", which the documentation
-- does not list. Also checks whether a placed part leads back to its asset.
local function field(obj, name)
	local ok, v = pcall(function() return obj[name] end)
	if ok then return v end
end

local function describe(v)
	if v == nil then return "nil" end
	local ok, len = pcall(function() return #v end)
	return type(v) .. ((ok and type(len) == "number") and (" of " .. len) or "")
end

local function probePathData(building)
	local out = {}
	local asset = field(building, "AssetBuilding")
	out[#out + 1] = "AssetBuilding " .. describe(asset)
	local core = asset and field(asset, "AssetCoreBuildingPart")
	out[#out + 1] = "AssetCoreBuildingPart " .. describe(core)
	if core then
		for _, name in ipairs({ "BuildingPath", "PathData", "BuildingPathData" }) do
			local data = field(core, name)
			out[#out + 1] = name .. " " .. describe(data)
			if data then
				local entrances = field(data, "EntranceList")
				local waypoints = field(data, "WaypointPositionList")
				out[#out + 1] = "EntranceList " .. describe(entrances)
				out[#out + 1] = "WaypointPositionList " .. describe(waypoints)
				pcall(function()
					entrances:forEach(function(e)
						out[#out + 1] = string.format("entrance at waypoint %s, hidden %s, water %s",
							tostring(field(e, "WaypointId")), tostring(field(e, "Hidden")), tostring(field(e, "Water")))
					end)
				end)
				local i = 0
				pcall(function()
					waypoints:forEach(function(p)
						i = i + 1
						if i <= 4 then out[#out + 1] = string.format("waypoint %d (%.1f, %.1f, %.1f)", i, p.x, p.y, p.z) end
					end)
				end)
				break
			end
		end
	end
	local ok, parts = pcall(building.getBuildingPartList, building)
	if ok and parts then
		out[#out + 1] = "parts " .. describe(parts)
		local first
		pcall(function() parts:forEach(function(p) if not first then first = p end end) end)
		if first then
			for _, name in ipairs({ "AssetBuildingPart", "BuildingPart", "Asset" }) do
				out[#out + 1] = "part." .. name .. " " .. describe(field(first, name))
			end
		end
	end
	trace("path data probe: " .. table.concat(out, "; "))
end

-- Lifecycle ------------------------------------------------------------------------

function COMP_PATH_SAMPLER:create()
	self._sinceSample = 0
	self._sinceRecompute = 0
	self._sincePrune = 0
	self._sinceSave = 0
	self._sinceLog = 0
	self._entrances = {} -- building -> start points, until the building changes
	self._work = { kinds = {}, details = {} }
	self._costs = {}
end

function COMP_PATH_SAMPLER:init()
	local level = self:getLevel()
	self._level = level

	-- Start from a clean grid: the mod is reloaded with each save, but relying on
	-- that would let one village's history leak into another if it ever isn't.
	grid.reset()
	PathHeatmap.clock = 0
	local ok, dayLength = pcall(function()
		return level:find("COMP_MAIN_GAME_LOOP"):getDayDurationInSeconds()
	end)
	if ok and type(dayLength) == "number" and dayLength > 0 then
		grid.setDayLength(dayLength)
	end

	overlay.sweep()

	local saved = self.SavedCells
	local restored, importError = grid.import(saved)
	mod:log(string.format("day length %s s; restored %d cells from save (%d chars)",
		tostring(dayLength), restored, type(saved) == "string" and #saved or 0))
	if importError then mod:logWarning("saved history was damaged: " .. importError) end

	-- Resolve the agent managers once; drop types this game version lacks.
	self._managers, self._managerNames = {}, {}
	for _, typeName in ipairs(cfg.AGENT_TYPES) do
		local okManager, manager = pcall(level.getComponentManager, level, typeName)
		if okManager and manager and pcall(manager.getAllEnabledComponent, manager) then
			self._managers[#self._managers + 1] = manager
			self._managerNames[#self._managerNames + 1] = typeName
		end
	end
	trace("sampling " .. table.concat(self._managerNames, ", "))

	local buildings = level:getComponentManager("COMP_BUILDING")
	buildings:getAllComponent():forEach(function(building)
		self:watchBuilding(building)
	end)
	event.register(self, buildings.ON_COMPONENT_INITIALIZED, function(building)
		self:watchBuilding(building)
	end)
end

-- Events are registered only where the building has them, in case a building
-- type lacks one.
local function listen(target, building, eventName, callback)
	local ev = building[eventName]
	if ev then pcall(event.register, target, ev, callback) end
end

function COMP_PATH_SAMPLER:watchBuilding(building)
	event.register(self, building.ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED, function(isHighlighted)
		self:onHighlight(building, isHighlighted)
	end)
	-- A destroyed building may never report being deselected.
	listen(self, building, "ON_BUILDING_DESTROYED", function()
		self._entrances[building] = nil
		if PathHeatmap.selected == building then self:deselect() end
	end)
	local function forget() self._entrances[building] = nil end
	for _, eventName in ipairs(BUILDING_CHANGE_EVENTS) do
		listen(self, building, eventName, forget)
	end
end

function COMP_PATH_SAMPLER:onFinalize(isClearingLevel)
	pcall(function() self.SavedCells = grid.export() end)
	overlay.clear()
end

-- Selection ------------------------------------------------------------------------

function COMP_PATH_SAMPLER:onHighlight(building, isHighlighted)
	if isHighlighted then
		if PathHeatmap.selected ~= building then
			-- A different building: drop everything shown or in progress.
			self:cancelPipeline()
			overlay.clear()
		end
		PathHeatmap.selected = building
		local points = self._entrances[building]
		if points then
			self:note("select", "cached")
		else
			local children
			points, children = walkEntrances(building)
			self._entrances[building] = points
			self:note("select", children .. " children")
			if DEBUG and not self._probed then
				self._probed = true
				probeFind(self._level)
				local okProbe, err = pcall(probePathData, building)
				if not okProbe then trace("path data probe failed: " .. tostring(err)) end
			end
		end
		trace(string.format("selected %s, %d start points", tostring(building:getOwner().Name), #points))
		self._startPoints = points
		self:requestSearch()
	elseif PathHeatmap.selected == building then
		self:deselect()
	end
end

function COMP_PATH_SAMPLER:deselect()
	PathHeatmap.selected = nil
	self:cancelPipeline()
	overlay.clear()
end

function COMP_PATH_SAMPLER:cancelPipeline()
	self._search, self._plan, self._reconcile = nil, nil, nil
	self._searchWanted = false
end

-- A refresh waits for a running plan or reconcile to finish, so markers are
-- never left half replaced.
function COMP_PATH_SAMPLER:requestSearch()
	self._searchWanted = true
	self._sinceRecompute = 0
end

-- Advances the pipeline by one stage's budget.
function COMP_PATH_SAMPLER:stepPipeline()
	if self._search then
		local job = self._search
		self:note("search")
		if job.step(cfg.SEARCH_POPS_PER_FRAME) then
			self._search = nil
			if job.dist then
				self._plan = PathHeatmap.newPlanJob(job.dist)
				if DEBUG then
					local counts = PathHeatmap.bandCounts(job.dist)
					trace(string.format("search: %d seeds, %d cells settled, bands %s",
						job.seeds, job.settled, table.concat(counts, "/")))
				end
			else
				trace("search: no walked cells near the building")
				overlay.clear()
			end
		end
	elseif self._plan then
		local job = self._plan
		self:note("plan")
		if job.step(cfg.PLAN_WORK_PER_FRAME) then
			self._plan = nil
			local ok, result = pcall(overlay.newReconcileJob, self._level, job.plan)
			if ok then
				self._reconcile = result
			else
				mod:logError("overlay update failed: " .. tostring(result))
			end
		end
	elseif self._reconcile then
		local job = self._reconcile
		self:note("markers")
		if job.step() then
			self._reconcile = nil
			if DEBUG then
				trace(string.format("markers: %d created, %d destroyed, %d failed, %d now; %d off the terrain ray",
					job.created, job.destroyed, job.failed, overlay.markerCount(), job.mismatches or 0))
			end
		end
	elseif self._searchWanted and PathHeatmap.selected then
		self._searchWanted = false
		self._search = PathHeatmap.newSearchJob(self._startPoints)
		self:note("search")
	end
end

-- Frame --------------------------------------------------------------------------

function COMP_PATH_SAMPLER:update()
	local level = self._level
	if not level then return end
	if DEBUG then self:chargeLastFrame() end
	local dt = level:getDeltaTime()

	-- Game time stops while paused; sampling and timers stop with it, but the
	-- overlay pipeline keeps going so a selection while paused still shows.
	if dt > 0 then
		PathHeatmap.clock = PathHeatmap.clock + dt
		grid.setTime(PathHeatmap.clock)

		-- An export walking the grid needs it to hold still for a few frames;
		-- the time carries over into the next sample's weight.
		self._sinceSample = self._sinceSample + dt
		local frozen = self._export and self._export.snapshotting
		if self._sinceSample >= cfg.SAMPLE_INTERVAL and not frozen then
			sampleWeight = math.min(self._sinceSample, cfg.MAX_SAMPLE_WEIGHT)
			self._sinceSample = 0
			sampledCount = 0
			cycleManagers = self._managers
			local ok, err = pcall(sampleCycle)
			if not ok and not self._sampleWarned then
				self._sampleWarned = true
				mod:logWarning("sampling failed: " .. tostring(err))
			end
			self._lastSampled = sampledCount
			self:note("sample")
		end

		if PathHeatmap.selected then
			self._sinceRecompute = self._sinceRecompute + dt
			if self._sinceRecompute >= cfg.RECOMPUTE_EVERY then self:requestSearch() end
		end

		-- Prune and export both walk every cell; the export also needs the cell
		-- set to hold still, so prune waits for it.
		self._sincePrune = self._sincePrune + dt
		if self._sincePrune >= cfg.PRUNE_EVERY and not self._export then
			self._sincePrune = 0
			local removed = grid.prune()
			self:note("prune", removed .. " removed")
		end

		self._sinceSave = self._sinceSave + dt
		if self._sinceSave >= cfg.SAVE_EVERY and not self._export then
			self._sinceSave = 0
			self._export = grid.newExportJob()
		end
	end

	if self._export then
		if self._export.step(cfg.EXPORT_CELLS_PER_FRAME) then
			-- Writing the finished string into the save property is its own cost.
			self.SavedCells = self._export.result
			self:note("export end", self._export.cells .. " cells, " .. #self._export.result .. " chars")
			self._export = nil
		else
			self:note("export")
		end
	end

	self:stepPipeline()

	if DEBUG then self:summarize(dt) end
end

-- Debug profiling ------------------------------------------------------------------
-- There is no clock, but the frame delta read at the start of an update is the
-- length of the frame before. Work is noted by kind as it happens and charged
-- with that length on the next update. Frames with no work give the baseline;
-- frames with exactly one kind give that kind's average extra cost. Selection
-- work runs in an event handler, outside the update; it is charged to the frame
-- of the next update, which assumes input is handled before components update.

function COMP_PATH_SAMPLER:note(kind, detail)
	if not DEBUG then return end
	local work = self._work
	work.kinds[#work.kinds + 1] = kind
	if detail then work.details[#work.details + 1] = kind .. " (" .. detail .. ")" end
end

function COMP_PATH_SAMPLER:chargeLastFrame()
	local frameMs = self._level:getUnscaledDeltaTime() * 1000
	local work = self._charged
	self._charged, self._work = self._work, { kinds = {}, details = {} }
	if not work then return end

	local kinds = work.kinds
	if #kinds == 0 then
		self._baseline = self._baseline and (self._baseline * 0.95 + frameMs * 0.05) or frameMs
		return
	end
	local baseline = self._baseline
	if not baseline then return end
	if #kinds == 1 then
		local cost = self._costs[kinds[1]] or { sum = 0, count = 0, worst = 0 }
		self._costs[kinds[1]] = cost
		local extra = frameMs - baseline
		cost.sum, cost.count = cost.sum + extra, cost.count + 1
		if extra > cost.worst then cost.worst = extra end
	end
	if frameMs > baseline * 1.5 + 4 then
		local label = #work.details > 0 and table.concat(work.details, ", ") or table.concat(kinds, ", ")
		if #work.details > 0 then
			-- Kinds without a detail still belong in the label.
			local seen = {}
			for _, d in ipairs(work.details) do seen[string.match(d, "^[^(]+")] = true end
			for _, k in ipairs(kinds) do
				if not seen[k .. " "] then label = label .. ", " .. k end
			end
		end
		trace(string.format("slow frame %.1f ms (baseline %.1f) after: %s", frameMs, baseline, label))
	end
end

function COMP_PATH_SAMPLER:summarize(dt)
	self._sinceLog = self._sinceLog + dt
	if self._sinceLog < 10 then return end
	self._sinceLog = 0
	if not self._typesLogged then
		self._typesLogged = true
		local ok, err = pcall(self.logAgentTypes, self)
		if not ok then trace("agent type check failed: " .. tostring(err)) end
	end
	local total, active = grid.count()
	trace(string.format("summary: %d agents per sample, %d cells (%d walkable), %d markers, baseline frame %.1f ms",
		self._lastSampled or 0, total, active, overlay.markerCount(), self._baseline or 0))
	local kinds = {}
	for kind in pairs(self._costs) do kinds[#kinds + 1] = kind end
	table.sort(kinds)
	local parts = {}
	for _, kind in ipairs(kinds) do
		local c = self._costs[kind]
		parts[#parts + 1] = string.format("%s %+.1f ms avg, %+.1f worst (%d)", kind, c.sum / c.count, c.worst, c.count)
	end
	if #parts > 0 then trace("extra frame cost: " .. table.concat(parts, "; ")) end
end

-- How many agents each type contributes, and how many are listed under more
-- than one type (their steps would count twice). Debug only, once per level.
function COMP_PATH_SAMPLER:logAgentTypes()
	local seen, parts, shared = {}, {}, 0
	for i, manager in ipairs(self._managers) do
		local n = 0
		manager:getAllEnabledComponent():forEach(function(agent)
			n = n + 1
			local id = tostring(agent:getOwner():getId())
			if seen[id] then shared = shared + 1 else seen[id] = true end
		end)
		parts[#parts + 1] = self._managerNames[i] .. " " .. n
	end
	trace(string.format("agents by type: %s; %d listed under more than one type",
		table.concat(parts, ", "), shared))
end

mod:registerClass(COMP_PATH_SAMPLER)
mod:registerPrefabComponent("PREFAB_MANAGER", { DataType = "COMP_PATH_SAMPLER" })
