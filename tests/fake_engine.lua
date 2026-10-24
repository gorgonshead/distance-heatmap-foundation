-- A small stand-in for the parts of Foundation's Lua API the mod uses, so the
-- scripts can be loaded and driven outside the game. It mimics shapes and call
-- patterns only; it says nothing about the real engine's performance.

local fake = {}

-- Events: event.register(target, objectEvent, callback), fired by fake.fire.
local function newEvent() return { handlers = {} } end
fake.newEvent = newEvent

function fake.fire(ev, ...)
	for _, h in ipairs(ev.handlers) do h.callback(...) end
end

event = {
	register = function(target, ev, callback)
		for _, h in ipairs(ev.handlers) do
			if h.target == target then h.callback = callback return end
		end
		ev.handlers[#ev.handlers + 1] = { target = target, callback = callback }
	end,
	unregister = function() end,
	clear = function() end,
}

-- Lists returned by the engine support # and forEach only.
local function newList(items)
	return setmetatable({}, {
		__len = function() return #items end,
		__index = {
			forEach = function(_, fn)
				for _, item in ipairs(items) do
					if fn(item) == false then break end
				end
			end,
		},
	})
end
fake.newList = newList

-- Scene objects.
local scene = {}
fake.scene = scene
local nextId = 1

local Object = {}
Object.__index = Object

function fake.newObject(name, pos)
	local obj = setmetatable({
		Name = name or "Object",
		pos = { x = pos and pos[1] or 0, y = pos and pos[2] or 0, z = pos and pos[3] or 0 },
		children = {},
		components = {},
		id = nextId,
	}, Object)
	nextId = nextId + 1
	scene[obj] = true
	return obj
end

function Object:getGlobalPosition() return { x = self.pos.x, y = self.pos.y, z = self.pos.z } end
function Object:getParent() return self.parent end
function Object:getId() return "guid-" .. self.id end
function Object:addComponent(typeName, setter)
	assert(not self.destroyed, "addComponent on destroyed object")
	local comp = { type = typeName }
	if type(setter) == "function" then setter(comp) end
	self.components[#self.components + 1] = comp
	return comp
end
function Object:lookAt(target, up, lock)
	assert(type(target) == "table" and #target == 3, "lookAt target")
	assert(type(up) == "table" and #up == 3, "lookAt up")
	self.lookTarget, self.lookUp = target, up
end
function Object:setParent(parent, keep)
	assert(parent and not parent.destroyed, "setParent to a missing parent")
	self.parent = parent
	parent.children[#parent.children + 1] = self
end
function Object:destroy()
	if self.destroyed then return end
	self.destroyed = true
	scene[self] = nil
	for _, c in ipairs(self.children) do c:destroy() end
end
function Object:destroyAllChild()
	for _, c in ipairs(self.children) do c:destroy() end
	self.children = {}
end
function Object:forEachChildRecursive(fn)
	local function walk(o)
		for _, c in ipairs(o.children) do
			fn(c)
			walk(c)
		end
	end
	walk(self)
end

function fake.liveObjects(name)
	local n = 0
	for obj in pairs(scene) do
		if name == nil or obj.Name == name then n = n + 1 end
	end
	return n
end

foundation = {
	findAsset = function(name) return { asset = name } end,
	findGameObject = function(name)
		for obj in pairs(scene) do
			if obj.Name == name then return obj end
		end
	end,
}

PARTICLE_BILLBOARD_BEHAVIOR = { XZ = "XZ", FACE_CAMERA = "FACE_CAMERA" }
PARTICLE_QUALITY = { LOW = "LOW", MEDIUM = "MEDIUM" }
PARTICLE_TIME_SCALE_TYPE = { UNSCALED = "UNSCALED", DEFAULT = "DEFAULT" }
OBJECT_FLAG = { TERRAIN = 1 }

-- Component managers and the level.
function fake.newLevel(opts)
	opts = opts or {}
	local level = { managers = {}, dt = 0.016, unscaled = 0.016 }
	level.terrainHeight = opts.terrainHeight or function(x, z) return 10 end

	function level:getDeltaTime() return self.dt end
	function level:getUnscaledDeltaTime() return self.unscaled end
	function level:getTimeScale() return 1 end
	function level:find(typeName, out)
		if typeName == "COMP_MAIN_GAME_LOOP" then
			return { getDayDurationInSeconds = function() return 60 end }
		end
		if type(out) == "table" then
			for obj in pairs(scene) do
				if obj.Name == typeName then out[#out + 1] = obj end
			end
		end
	end
	function level:manager(typeName)
		local m = self.managers[typeName]
		if not m then
			m = { items = {}, ON_COMPONENT_INITIALIZED = newEvent() }
			function m:getAllEnabledComponent() return newList(self.items) end
			function m:getAllComponent() return newList(self.items) end
			self.managers[typeName] = m
		end
		return m
	end
	function level:getComponentManager(typeName)
		return self:manager(typeName)
	end
	function level:createObject(prefab, pos)
		if prefab ~= nil and type(prefab) ~= "table" then error("createObject: bad prefab") end
		return fake.newObject(prefab and prefab.asset or "Object", pos)
	end
	function level:rayCast(from, to, out, flag)
		local x, z = from[1], from[3]
		out.Position = { x = x, y = self.terrainHeight(x, z), z = z }
		out.Normal = { x = 0, y = 1, z = 0 }
		return true
	end
	return level
end

-- An agent component whose owner can be moved.
function fake.newAgent(level, typeName, x, y, z)
	local owner = fake.newObject("Agent", { x, y, z })
	local agent = { owner = owner }
	function agent:getOwner() return self.owner end
	local m = level:manager(typeName)
	m.items[#m.items + 1] = agent
	return agent
end

-- A building with entrance indicator children at the given offsets.
function fake.newBuilding(level, x, y, z, entrances)
	local owner = fake.newObject("BUILDING", { x, y, z })
	for _, e in ipairs(entrances or {}) do
		local part = fake.newObject("Part", { x, y, z })
		part.parent = owner
		owner.children[#owner.children + 1] = part
		local ind = fake.newObject("Building Entrance Indicator", { x + e[1], y, z + e[2] })
		part.children[#part.children + 1] = ind
	end
	local building = {
		owner = owner,
		ON_BUILDING_SELECTED_HIGHLIGHT_CHANGED = newEvent(),
		ON_BUILDING_DESTROYED = newEvent(),
	}
	function building:getOwner() return self.owner end
	function building:getBuildingPartList() return newList({}) end
	local m = level:manager("COMP_BUILDING")
	m.items[#m.items + 1] = building
	return building
end

-- The mod object: logging, script loading and asset registration.
function fake.newMod(root)
	local mod = { logs = {}, warnings = {}, errors = {}, assets = {}, classes = {}, prefabComponents = {} }
	function mod:log(m) self.logs[#self.logs + 1] = m end
	function mod:logWarning(m) self.warnings[#self.warnings + 1] = m end
	function mod:logError(m) self.errors[#self.errors + 1] = m end
	-- The engine passes the mod object to scripts loaded without arguments.
	function mod:dofile(path, ...)
		local chunk = assert(loadfile(root .. "/PathHeatmap/" .. path))
		if select("#", ...) == 0 then return chunk(self) end
		return chunk(...)
	end
	function mod:registerAssetId() end
	function mod:registerAsset(data)
		assert(data.Id and data.DataType, "asset without Id or DataType")
		self.assets[data.Id] = data
	end
	function mod:registerClass(info) self.classes[info.TypeName] = info end
	function mod:registerPrefabComponent(prefab, data) self.prefabComponents[#self.prefabComponents + 1] = { prefab, data } end
	return mod
end

return fake
