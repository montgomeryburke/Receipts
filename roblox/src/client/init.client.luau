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

local modules = script:WaitForChild("modules")
local Hud = require(modules:WaitForChild("Hud"))
local Controls = require(modules:WaitForChild("Controls"))

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

	local function refresh()
		Hud.SetHealth(humanoid.Health, humanoid.MaxHealth)
	end

	humanoid.HealthChanged:Connect(refresh)
	refresh()
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
