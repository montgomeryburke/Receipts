-- Extra stand-ins so the WHOLE server bootstrap can be executed, not just the
-- map generator. Anything that yields or waits is made instant; the match loop
-- is captured rather than run, so we can inspect what Start() did before it.

SPAWNED = {}
WARNINGS = {}
PRINTS = {}

-- DataStore access is the thing Studio blocks in an unpublished place, so it
-- is switchable here: we test both the happy path and the blocked one.
DATASTORE_THROWS = true

local realPrint = print
function print(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
	table.insert(PRINTS, table.concat(parts, " "))
end
function warn(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
	table.insert(WARNINGS, table.concat(parts, " "))
end
DUMP = function(...) realPrint(...) end

-- VIRTUAL CLOCK.
-- Simulated frames run in microseconds of real time, so anything waiting on
-- os.clock() would never come due. Tests advance this by hand instead.
local virtualNow = 1000
local realOs = os
-- `os` itself is frozen, so it is shadowed rather than modified.
os = setmetatable({ clock = function() return virtualNow end }, { __index = realOs })
ADVANCE = function(seconds) virtualNow += seconds end

task = {
	spawn = function(fn, ...)
		-- Captured, not run: the match loop would never return.
		table.insert(SPAWNED, fn)
	end,
	delay = function(_, fn) end,
	wait = function() end,
	defer = function() end,
}

local function signal()
	local handlers = {}
	return {
		Connect = function(_, fn)
			table.insert(handlers, fn)
			return { Disconnect = function() end }
		end,
		Wait = function() end,
		_fire = function(...)
			for _, fn in handlers do fn(...) end
		end,
	}
end
SIGNAL = signal

local services = {}

local function service(name, extra)
	local svc = Instance.new(name)
	for k, v in extra or {} do
		rawget(svc, "_props")[k] = v
	end
	services[name] = svc
	return svc
end

service("Players", {
	GetPlayers = function() return {} end,
	PlayerAdded = signal(),
	PlayerRemoving = signal(),
	GetPlayerFromCharacter = function() return nil end,
	GetPlayerByUserId = function() return nil end,
	CharacterAutoLoads = true,
})
service("RunService", {
	Heartbeat = signal(),
	Stepped = signal(),
	IsServer = function() return true end,
	IsClient = function() return false end,
})
service("Teams", {})
service("Debris", { AddItem = function() end })
service("TweenService", { Create = function() return { Play = function() end, Completed = signal() } end })
service("MarketplaceService", {
	UserOwnsGamePassAsync = function() return false end,
})
service("DataStoreService", {
	GetDataStore = function()
		if DATASTORE_THROWS then
			-- This is what Studio does in a place that was never published.
			error("502: API Services rejected request", 0)
		end
		return { GetAsync = function() return nil end, SetAsync = function() end }
	end,
})
service("ReplicatedStorage", {})
service("ServerScriptService", {})
service("SoundService", {})
service("StarterGui", {})
service("Lighting", {})

-- Raycasts and spatial queries find nothing; combat is not what we are testing.
rawget(workspace, "_props").Raycast = function() return nil end
rawget(workspace, "_props").GetPartBoundsInRadius = function() return {} end

game = {
	GetService = function(_, name)
		if not services[name] then service(name, {}) end
		return services[name]
	end,
	BindToClose = function() end,
}

RaycastParams = { new = function() return {} end }
-- RemoteEvents/Functions and property signals, so server modules can wire up.
local baseNew = Instance.new
Instance = { new = function(class)
	local inst = baseNew(class)
	local props = rawget(inst, "_props")
	if class == "RemoteEvent" or class == "UnreliableRemoteEvent" then
		props.OnServerEvent = SIGNAL()
		props.OnClientEvent = SIGNAL()
		props.FireClient = function() end
		props.FireAllClients = function() end
		props.FireServer = function() end
	elseif class == "RemoteFunction" then
		props.OnServerInvoke = nil
		props.InvokeServer = function() return {} end
	end
	props.GetPropertyChangedSignal = function() return SIGNAL() end
	props.Destroying = SIGNAL()
	props.Touched = SIGNAL()
	props.Triggered = SIGNAL()
	props.PromptShown = SIGNAL()
	props.Died = SIGNAL()
	props.TouchEnded = SIGNAL()
	props.Changed = SIGNAL()
	props.HealthChanged = SIGNAL()
	props.FindFirstAncestorOfClass = function() return nil end
	props.GetPlayers = props.GetPlayers or nil
	return inst
end }
