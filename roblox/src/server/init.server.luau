--!strict
--[[
	Nuclear Mud Arena — server start-up.

	This is the only Script on the server. Everything else is a module it turns
	on, in an order that matters: teams before anybody joins, weapons before
	anybody shoots, the match loop last because it is what starts the game.
]]

local modules = script:WaitForChild("modules")

-- Creating the remotes is the first job, because the client is already
-- waiting for them.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
require(Shared:WaitForChild("Remotes"))

local TeamService = require(modules:WaitForChild("TeamService"))
local WeaponService = require(modules:WaitForChild("WeaponService"))
local MonetizationService = require(modules:WaitForChild("MonetizationService"))
local MatchService = require(modules:WaitForChild("MatchService"))
local PlayerState = require(modules:WaitForChild("PlayerState"))

TeamService.Start()
WeaponService.Start()
MonetizationService.Start()
MatchService.Start()

local Remotes = require(Shared:WaitForChild("Remotes"))

--[[
	Everything one player's screen needs to draw itself. Built in one place so
	the pushed update and the asked-for update can never disagree.
]]
local function describe(player: Player)
	local state = PlayerState.Get(player)

	-- The gun in their hands might be a mounted one they are sitting behind.
	local equipped = state.equipped
	if state.vehicle and state.vehicle.Parent then
		local mounted = state.vehicle:GetAttribute("MountedWeapon")
		local isGunner = state.seatRole == "Gunner"
		local isPilot = state.seatRole == "Driver" and state.vehicle:GetAttribute("VehicleKind") == "Plane"
		if typeof(mounted) == "string" and (isGunner or isPilot) then
			equipped = mounted
		end
	end

	local spec = Config.Weapons[equipped]
	local slot = state.weapons[equipped]

	return {
		shield = state.shield,
		maxShield = state.maxShield,
		keys = state.keys,
		carTier = state.carTier,
		carTierName = Config.CarTiers[math.clamp(state.carTier, 1, #Config.CarTiers)].Name,
		megaCharges = state.megaCharges,
		kills = state.kills,
		deaths = state.deaths,

		equipped = equipped,
		weaponName = if spec then spec.DisplayName else equipped,
		ammo = if slot then slot.ammo else 0,
		magSize = if spec then spec.MagSize else 0,
		reloading = if slot then slot.reloadingUntil > os.clock() else false,
	}
end

-- Push a fresh HUD whenever anything about a player actually changes, rather
-- than having every client ask twenty times a second.
PlayerState.Changed.Connect(function(player: Player)
	if player and player.Parent then
		Remotes.Event("HudUpdate"):FireClient(player, describe(player))
	end
end)

-- Still answer a direct ask, for when a client first loads in.
Remotes.Function("GetPlayerState").OnServerInvoke = function(player)
	return describe(player)
end

if Config.FreeMode then
	print("[Nuclear Mud Arena] Running in FREE MODE — every weapon and vehicle is unlocked.")
end
print("[Nuclear Mud Arena] Server ready.")
