--!strict
--[[
	Nuclear Mud Arena — client start-up.

	Draws the interface, wires up the controls, and listens for the handful of
	things the server tells us about.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Sound = require(Shared:WaitForChild("Sound"))
local Shot = require(Shared:WaitForChild("Shot"))

local modules = script:WaitForChild("modules")
local Hud = require(modules:WaitForChild("Hud"))
local Controls = require(modules:WaitForChild("Controls"))
local Feel = require(modules:WaitForChild("Feel"))
local Radar = require(modules:WaitForChild("Radar"))
local Props = require(modules:WaitForChild("Props"))
local Visuals = require(modules:WaitForChild("Visuals"))

local player = Players.LocalPlayer

local hudOk = pcall(Hud.Build)

-- A travel row is the same join the walk-in prompt and the B menu use, so
-- arriving by teleport fills the teams out with bots exactly as walking in
-- would. A travel button that dropped you at an empty rink would be a worse
-- answer than making you walk there.
Hud.OnTravel(function(id)
	Remotes.Event("JoinArcade"):FireServer(id)
end)
if not hudOk then
	warn("[Nuclear Mud Arena] HUD failed to build.")
end

local function startControls(): string
	Controls.Start()
	return "ok"
end

if not pcall(Feel.Start) then
	warn("[Nuclear Mud Arena] Camera feel failed to start.")
end

if not pcall(Visuals.Start) then
	warn("[Nuclear Mud Arena] Player outlines failed to start.")
end

if not pcall(Props.Start) then
	warn("[Nuclear Mud Arena] Pickup animation failed to start.")
end

if not pcall(Radar.Start) then
	warn("[Nuclear Mud Arena] Motion tracker failed to start.")
end

local controlsOk, controlsErr = pcall(startControls)
if controlsOk then
	Hud.SetStatus("Controls ready · WASD drive · E enter vehicle · Shift turbo · F mega", true)
else
	warn(`[Nuclear Mud Arena] Controls failed to start: {controlsErr}`)
	Hud.SetStatus(`CONTROLS FAILED: {controlsErr}`, false)

	task.spawn(function()
		for attempt = 1, 10 do
			task.wait(1)
			local ok = pcall(startControls)
			if ok then
				Hud.SetStatus(`Controls ready (recovered on attempt {attempt})`, true)
				return
			end
		end
		Hud.SetStatus("CONTROLS FAILED — check the Output window in Studio", false)
	end)
end

-- ============================================================ HEALTH TRACKING ==

local characterConnections: { RBXScriptConnection } = {}
local lastWatchedCharacter: Model? = nil

local function disconnectCharacter()
	for _, conn in characterConnections do
		conn:Disconnect()
	end
	table.clear(characterConnections)
end

--[[ Follow the health bar of whichever body we are currently wearing. ]]
local function watchCharacter(character: Model)
	if lastWatchedCharacter == character then
		return
	end
	disconnectCharacter()
	lastWatchedCharacter = character

	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") or lastWatchedCharacter ~= character then
		return
	end

	local lastHealth = humanoid.Health

	local function refresh()
		Hud.SetHealth(humanoid.Health, humanoid.MaxHealth)

		local lost = lastHealth - humanoid.Health
		lastHealth = humanoid.Health
		if lost > 0 and humanoid.Health > 0 then
			Feel.Shake(math.clamp(lost * 0.06, 0.3, 2.2))
		end
	end

	table.insert(characterConnections, humanoid.HealthChanged:Connect(refresh))
	refresh()

	local fallFrom: number? = nil
	table.insert(characterConnections, humanoid.StateChanged:Connect(function(_, new)
		local root = humanoid.RootPart
		if new == Enum.HumanoidStateType.Freefall then
			fallFrom = if root then root.Position.Y else nil
		elseif new == Enum.HumanoidStateType.Landed then
			local from = fallFrom
			fallFrom = nil
			if from and root then
				local drop = from - root.Position.Y
				if drop > 18 then
					Feel.Shake(math.clamp(drop * 0.03, 0.4, 2.5))
				end
			end
		elseif new ~= Enum.HumanoidStateType.Jumping then
			fallFrom = nil
		end
	end))
end

player.CharacterRemoving:Connect(function(character)
	if lastWatchedCharacter == character then
		disconnectCharacter()
		lastWatchedCharacter = nil
	end
end)

if player.Character then
	task.spawn(watchCharacter, player.Character)
end
player.CharacterAdded:Connect(watchCharacter)

-- =================================================================== LISTENERS ==

local receivedHudUpdate = false

local function applyHudState(state: { [string]: any })
	Hud.SetShield(state.shield or 0, state.maxShield or 0)
	Hud.SetWeapon(state.weaponName or "—", state.ammo or 0, state.magSize or 0, state.reloading == true)
	Hud.SetStats(
		state.keys or 0,
		state.carTierName or "—",
		state.megaCharges or 0,
		state.kills or 0,
		state.deaths or 0
	)
end

Remotes.Event("HudUpdate").OnClientEvent:Connect(function(state)
	if typeof(state) ~= "table" then
		return
	end
	receivedHudUpdate = true
	applyHudState(state)
end)

Remotes.Event("MatchState").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	Hud.SetMatch(
		payload.phase or "Warmup",
		payload.timeLeft or 0,
		payload.scores or { 0, 0 },
		payload.mapName or "—",
		payload.modeName,
		payload.flags
	)
	if payload.phase ~= "Voting" then
		Hud.HideVote()
		Controls.SetMouseFree(false)
	else
		Controls.SetMouseFree(true)
	end
end)

Remotes.Event("VoteOptions").OnClientEvent:Connect(function(options)
	if typeof(options) ~= "table" then
		return
	end
	Hud.ShowVote(options, function(choice)
		Remotes.Event("CastVote"):FireServer(choice)
	end)
end)

Remotes.Event("DeathScreen").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	Hud.ShowDeath(payload.duration or 2.5, payload.killer)
end)

Remotes.Event("PlayEffect").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.effect == "Wiener" then
		Hud.ShowWiener(payload.team or "NOBODY", payload.duration or 8)
	elseif payload.effect == "Splat" then
		Hud.Splat(payload.duration or 4)
	end
end)

workspace.DescendantAdded:Connect(function(descendant)
	local blast = descendant :: Instance
	if not blast:IsA("Explosion") then
		return
	end
	task.defer(function()
		if not blast.Parent then
			return
		end
		local radius: number = blast.BlastRadius
		Feel.ShakeFrom(blast.Position, math.clamp(radius * 0.06, 0.8, 3.6), radius * 2.6)
	end)
end)

--[[ Somebody else's shot. Supports both single and batched pellet payloads. ]]
Remotes.Event("ShotFired").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	if typeof(payload.origin) ~= "Vector3" then
		return
	end
	local colour = if typeof(payload.color) == "Color3"
		then payload.color
		else Color3.fromRGB(255, 240, 180)

	if typeof(payload.rays) == "table" then
		Shot.MuzzleFlash(payload.origin, colour)
		for _, ray in payload.rays do
			if typeof(ray) == "table" and typeof(ray.endPoint) == "Vector3" then
				Shot.Tracer(payload.origin, ray.endPoint, colour)
				if typeof(ray.normal) == "Vector3" then
					Shot.Impact(ray.endPoint, ray.normal, colour)
				end
			end
		end
	elseif typeof(payload.endPoint) == "Vector3" then
		Shot.Full(
			payload.origin,
			payload.endPoint,
			colour,
			if typeof(payload.normal) == "Vector3" then payload.normal else nil
		)
	end

	if typeof(payload.sound) == "string" then
		Sound.At(payload.sound, payload.origin)
	end
end)

Remotes.Event("FightStarted").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	Controls.SetFighting(true)
	Hud.ShowFight(tostring(payload.opponent or "SOMEBODY"), payload.duration or 4)
	Sound.Flat("MeleeSwing")
end)

--[[
	The sub-games, which were sending into the void.

	Every one of these four was fired by the server and listened to by
	nobody: ArcadeMenu, ArcadeOffer, ArcadeJoined and ArcadeLeft. Hud had a
	menu panel, an offer banner and a join toast all built and ready;
	Controls had SetMenuOrder and SetPendingOffer sitting there with no
	callers. So pressing B asked for the menu, the server answered, and
	nothing happened -- which is the literal cause of not being able to
	figure out how to play the different games. The pieces were all written.
	They were never connected.
]]
--[[
	What is in your hands.

	This is what flips the control context: holding a gas can claims F for
	lighting the trail, which would otherwise set off a diamond round at
	your own feet while standing in petrol. The server is the one that knows,
	so the server is the one that says.
]]
Remotes.Event("CarryItem").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	local item = if typeof(payload.item) == "string" then payload.item else nil
	Controls.SetTool(item)
	if item and typeof(payload.fuel) == "number" then
		Hud.Toast(`GAS CAN — {math.floor(payload.fuel)}%  ·  HOLD LMB TO POUR, F TO LIGHT`)
	end
end)

Remotes.Event("BallCarry").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	local holding = payload.carrying == true
	-- The same remote serves both, flagged, so the client does not need a
	-- second message for a second ball-shaped thing.
	if payload.bowling == true then
		Controls.SetCarryingBowling(holding)
		Hud.SetBowlingBall(holding)
	else
		Controls.SetCarryingBall(holding)
		Hud.SetBall(holding)
	end
end)

Remotes.Event("HockeyScore").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	Hud.SetPuck(payload.carrying == true)
	-- Carrying is what makes F worth offering on the action bar.
	Controls.SetCarrying(payload.carrying == true)
end)

Remotes.Event("ArcadeMenu").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" or typeof(payload.games) ~= "table" then
		return
	end

	local ids = {}
	for _, game in payload.games do
		table.insert(ids, tostring(game.id))
	end
	-- The number keys pick from this list, so the order has to be the one
	-- that was drawn rather than whatever order it arrives in next time.
	Controls.SetMenuOrder(ids)
	Hud.ShowArcadeMenu(payload.games)
	-- The travel tab lists the same activities with the same counts, so the
	-- two ways in never disagree about what is out there.
	Hud.SetTravelList(payload.games)
end)

Remotes.Event("ArcadeOffer").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	Controls.SetPendingOffer(tostring(payload.id))
	Hud.ShowArcadeOffer(
		tostring(payload.name or "A GAME"),
		tostring(payload.objective or ""),
		"Y"
	)
end)

Remotes.Event("ArcadeJoined").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	Controls.SetPendingOffer(nil)
	Hud.HideArcadeOffer()
	Hud.HideArcadeMenu()
	Hud.HideHelp()
	Controls.SetMouseFree(false)
	-- The objective is the whole of the game's instructions, so it is worth
	-- putting on screen at the moment somebody arrives in one.
	Controls.SetVenue(tostring(payload.id))
	Hud.Toast(`{string.upper(tostring(payload.name or "GAME"))} — {tostring(payload.objective or "")}`)
end)

Remotes.Event("ArcadeLeft").OnClientEvent:Connect(function()
	Controls.SetPendingOffer(nil)
	Controls.SetVenue(nil)
	Hud.SetPuck(false)
	Hud.HideArcadeOffer()
end)

Remotes.Event("FightUpdate").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	Hud.FightHealth(
		tonumber(payload.health) or 0,
		tonumber(payload.opponentHealth) or 0,
		tonumber(payload.maxHealth) or 100,
		payload.opponentBlocking == true,
		payload.blocking == true
	)
end)

Remotes.Event("FightResult").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	Controls.SetFighting(false)
	Hud.FightResult(payload.won == true, payload.draw == true, payload.brokeStick == true)
end)

Remotes.Event("Scoreboard").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" or typeof(payload.rows) ~= "table" then
		return
	end
	Hud.SetScoreboard(payload.rows, payload.heading)
end)

Remotes.Event("Hitmarker").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	local headshot = payload.headshot == true
	Hud.Hit(payload.damage or 0, headshot)
	Sound.Flat(if headshot then "Headshot" else "Hitmarker")
end)

Remotes.Event("KillFeed").OnClientEvent:Connect(function(line, mine)
	if typeof(line) == "string" then
		Hud.KillFeed(line, mine == true)
	end
end)

Remotes.Event("Medal").OnClientEvent:Connect(function(text)
	if typeof(text) == "string" then
		Hud.Medal(text)
	end
end)

Remotes.Event("PlaySound").OnClientEvent:Connect(function(name)
	if typeof(name) == "string" then
		Sound.Flat(name)
	end
end)

Remotes.Event("Notify").OnClientEvent:Connect(function(message)
	if typeof(message) == "string" then
		Hud.Toast(message)
	end
end)

--[[
	Which way a hit came from.

	A world position, not an angle: the server has no idea which way the
	camera is pointing, and the HUD turns it into a bearing itself.
]]
Remotes.Event("Hurt").OnClientEvent:Connect(function(from)
	if typeof(from) == "Vector3" then
		Hud.ShowHurtFrom(from)
	end
end)

task.spawn(function()
	local ok, state = pcall(function()
		return Remotes.Function("GetPlayerState"):InvokeServer()
	end)
	if ok and not receivedHudUpdate and typeof(state) == "table" then
		applyHudState(state)
	end
end)

print("[Nuclear Mud Arena] Client ready. WASD drives, F mega-detonates.")
