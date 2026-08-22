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

Hud.Build()
Controls.Start()

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
		payload.mapName or "—"
	)
	-- The ballot only belongs on screen while voting is actually open.
	if payload.phase ~= "Voting" then
		Hud.HideVote()
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
