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

local player = Players.LocalPlayer

--[[
	Start the interface and the controls, separately and defensively.

	These used to be two bare calls. When Controls.Start() threw — which it did
	if the server had not finished booting — every input handler after the
	throw was never connected, so nothing responded to the mouse or keyboard
	and there was no visible sign of why.
]]
local hudOk = pcall(Hud.Build)
if not hudOk then
	warn("[Nuclear Mud Arena] HUD failed to build.")
end

-- The closure returns a value so that a failure's error message comes back
-- as pcall's second result rather than being dropped.
local function startControls(): string
	Controls.Start()
	return "ok"
end

-- The camera reactions. Nothing else depends on this, so a failure here
-- must not take the controls down with it.
if not pcall(Feel.Start) then
	warn("[Nuclear Mud Arena] Camera feel failed to start.")
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

	-- Keep trying. Whatever it was waiting for may simply not be ready yet.
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

--[[ Follow the health bar of whichever body we are currently wearing. ]]
local function watchCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end

	local lastHealth = humanoid.Health

	local function refresh()
		Hud.SetHealth(humanoid.Health, humanoid.MaxHealth)

		-- Flinch when hit. Being shot at from somewhere you cannot see is
		-- the one thing a HUD number alone never communicates in time.
		local lost = lastHealth - humanoid.Health
		lastHealth = humanoid.Health
		if lost > 0 and humanoid.Health > 0 then
			Feel.Shake(math.clamp(lost * 0.06, 0.3, 2.2))
		end
	end

	humanoid.HealthChanged:Connect(refresh)
	refresh()

	-- A hard landing should land. Track where the fall started, because the
	-- vertical velocity has already been zeroed by the time Roblox reports
	-- the landing itself.
	local fallFrom: number? = nil
	humanoid.StateChanged:Connect(function(_, new)
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
		end
	end)
end

if player.Character then
	task.spawn(watchCharacter, player.Character)
end
player.CharacterAdded:Connect(watchCharacter)

-- =================================================================== LISTENERS ==

Remotes.Event("HudUpdate").OnClientEvent:Connect(function(state)
	if typeof(state) ~= "table" then
		return
	end
	Hud.SetShield(state.shield or 0, state.maxShield or 0)
	Hud.SetWeapon(state.weaponName or "—", state.ammo or 0, state.magSize or 0, state.reloading == true)
	Hud.SetStats(
		state.keys or 0,
		state.carTierName or "—",
		state.megaCharges or 0,
		state.kills or 0,
		state.deaths or 0
	)
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
	-- The ballot only belongs on screen while voting is actually open, and
	-- the cursor has to come free to click it.
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

--[[
	Rattle the camera for every explosion, wherever it came from.

	Watching for the replicated Explosion instances rather than sending a
	message per blast means this covers grenades, rockets, mines, cluster
	bombs, torpedoes, wrecked vehicles and the diamond mega-detonation
	without any of them having to know the camera exists.
]]
workspace.DescendantAdded:Connect(function(descendant)
	local blast = descendant :: Instance
	if not blast:IsA("Explosion") then
		return
	end
	local radius: number = blast.BlastRadius
	-- Bigger blast, harder shake and felt from further away.
	Feel.ShakeFrom(blast.Position, math.clamp(radius * 0.06, 0.8, 3.6), radius * 2.6)
end)

--[[ Somebody else's shot. Ours was drawn locally the moment we fired. ]]
Remotes.Event("ShotFired").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	if typeof(payload.origin) ~= "Vector3" or typeof(payload.endPoint) ~= "Vector3" then
		return
	end
	local colour = if typeof(payload.color) == "Color3"
		then payload.color
		else Color3.fromRGB(255, 240, 180)
	Shot.Full(
		payload.origin,
		payload.endPoint,
		colour,
		if typeof(payload.normal) == "Vector3" then payload.normal else nil
	)
	if typeof(payload.sound) == "string" then
		Sound.At(payload.sound, payload.origin)
	end
end)

--[[ The scoreboard we asked for, or the one pushed at the end of a round. ]]
Remotes.Event("Scoreboard").OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" or typeof(payload.rows) ~= "table" then
		return
	end
	Hud.SetScoreboard(payload.rows, payload.heading)
end)

--[[ A shot connected. Marker, number, and the right click in your ears. ]]
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

--[[ A noise the server wants this player specifically to hear. ]]
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

-- Ask once for where we stand, in case we joined mid-round.
task.spawn(function()
	local state = Remotes.Function("GetPlayerState"):InvokeServer()
	if typeof(state) == "table" then
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
end)

print("[Nuclear Mud Arena] Client ready. WASD drives, F mega-detonates.")
