-- Extra stand-ins so the WHOLE server bootstrap can be executed, not just the
-- map generator. Anything that yields or waits is made instant; the match loop
-- is captured rather than run, so we can inspect what Start() did before it.

SPAWNED = {}
-- Everything the server sends to a client, so a test can assert on what the
-- player would actually be told rather than only on internal state.
WAIT_BUDGET = 100000
FIRED = {}
FIRED_TO = function(remoteName)
	local out = {}
	for _, call in FIRED do
		if call.remote == remoteName then table.insert(out, call) end
	end
	return out
end
DELAYED = {}
--[[
	Run every thread that task.spawn captured.

	A copy of the FIRED / FIRED_TO definitions used to sit INSIDE this
	function, pasted in by accident. Both are already defined above, so the
	only thing the duplicate did was reset FIRED to {} on every call --
	which silently threw away the record of everything the server had sent.

	Any test that fired a remote, flushed the spawned threads and then asked
	what the player was told saw an empty list, and read as a feature that
	had sent nothing. The evidence was being destroyed by the act of
	looking at it.
]]
RUN_SPAWNED = function()
	local pending = SPAWNED
	SPAWNED = {}
	WAIT_BUDGET = 20000
	for _, item in pending do
		local ok, err = pcall(item.fn, table.unpack(item.args, 1, item.args.n))
		if not ok then
			table.insert(WARNINGS, "spawned thread errored: " .. tostring(err))
		end
	end
	return #pending
end
RUN_DELAYED = function()
	local pending = DELAYED
	DELAYED = {}
	for _, item in pending do
		pcall(item.fn)
	end
	return #pending
end
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
		-- Captured, not run: the match loop would never return. The arguments
		-- are captured too — dropping them meant every signal listener ran
		-- with nil for everything and failed inside its own pcall.
		table.insert(SPAWNED, { fn = fn, args = table.pack(...) })
	end,
	-- Recorded rather than dropped, so a test can fast-forward a timer.
	delay = function(seconds, fn)
		table.insert(DELAYED, { at = seconds, fn = fn })
	end,
	-- A safety net. If a test ever flushes a thread containing the match
	-- loop, that loop never returns and the process dies of memory
	-- exhaustion with nothing to show for it. This turns the hang into a
	-- plain error instead.
	wait = function()
		WAIT_BUDGET -= 1
		if WAIT_BUDGET < 0 then
			error("__RUNAWAY_LOOP__: a flushed thread never finished", 0)
		end
	end,
	defer = function() end,
}

local function signal()
	local handlers = {}
	local function disconnect(fn)
		for index, candidate in handlers do
			if candidate == fn then
				table.remove(handlers, index)
				return
			end
		end
	end
	return {
		Connect = function(_, fn)
			table.insert(handlers, fn)
			-- A real Disconnect, not a no-op. Code that connects, acts and
			-- disconnects was being left connected here, so anything that
			-- unsubscribes to avoid double work looked correct while doing
			-- the work twice.
			return {
				Disconnect = function()
					disconnect(fn)
				end,
			}
		end,
		-- What Destroy calls on every signal an instance owns.
		DisconnectAll = function()
			table.clear(handlers)
		end,
		Wait = function() end,
		-- Exposed so a test can ask whether anything is listening at all.
		-- A button with no handler looks identical to a working one until
		-- somebody taps it.
		_handlers = handlers,
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
	--[[
		Find the player who owns a character.

		This returned nil unconditionally, which quietly disabled a large
		part of the game inside every test. Anything that identifies somebody
		by their character took the "not a player" branch every single time:
		burn damage went to the bot path instead of the player path, and the
		vehicle code that works out who is in the driver's seat could never
		find anybody, so the whole off-road fitting layer was untestable
		while looking perfectly well tested.

		Searches PLAYERS_FOR_TEAMS, which is the harness's list of who is in
		the game -- the same list Team:GetPlayers uses, so the two cannot
		disagree about who exists.
	]]
	GetPlayerFromCharacter = function(_, character)
		if not character then
			return nil
		end
		for _, player in (PLAYERS_FOR_TEAMS or {}) do
			if rawget(player, "_props").Character == character then
				return player
			end
		end
		return nil
	end,
	--[[
		Find a player by user id.

		Returned nil unconditionally, which made every piece of
		ATTRIBUTION untestable -- anything that records "who touched this
		last" as a user id and looks the player up later got nobody. A
		basket credited to nil looks identical to a basket credited
		correctly unless the test checks the name.
	]]
	GetPlayerByUserId = function(_, userId)
		for _, player in (PLAYERS_FOR_TEAMS or {}) do
			if rawget(player, "_props").UserId == userId then
				return player
			end
		end
		return nil
	end,
	CharacterAutoLoads = true,
})
service("RunService", {
	Heartbeat = signal(),
	-- The client draws on RenderStepped. Leaving it out made every HUD that
	-- animates anything fail to build, and the failure looked like a bug in
	-- the HUD rather than a hole in the harness.
	RenderStepped = signal(),
	PreRender = signal(),
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
-- The box query, used by the chairlift to find a vehicle parked on a deck.
rawget(workspace, "_props").GetPartBoundsInBox = function() return {} end

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
		props.FireClient = function(self, player, ...)
			table.insert(FIRED, {
				remote = rawget(self, "_props").Name,
				player = player,
				args = table.pack(...),
			})
		end
		props.FireAllClients = function(self, ...)
			table.insert(FIRED, {
				remote = rawget(self, "_props").Name,
				player = nil,
				args = table.pack(...),
			})
		end
		props.FireServer = function() end
	elseif class == "RemoteFunction" then
		props.OnServerInvoke = nil
		props.InvokeServer = function() return {} end
	end
	--[[
		The SAME signal for the same property, every time.

		Handing back a fresh one per call meant a module that connected on
		one call and a test that fired on another were holding two unrelated
		signals, so the handler never ran and the wiring looked dead.
	]]
	local changedSignals = {}
	props.GetPropertyChangedSignal = function(_, property)
		local existing = changedSignals[property]
		if existing then
			return existing
		end
		local made = SIGNAL()
		changedSignals[property] = made
		return made
	end
	props.Destroying = SIGNAL()
	props.Touched = SIGNAL()
	props.Triggered = SIGNAL()
	props.PromptShown = SIGNAL()
	props.Died = SIGNAL()
	props.TouchEnded = SIGNAL()
	props.Changed = SIGNAL()
	props.HealthChanged = SIGNAL()
	props.GetPlayers = props.GetPlayers or nil
	return inst
end }
