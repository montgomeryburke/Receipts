--!strict
--[[
	PlayerState — everything the server remembers about a player for the
	length of a round: shields, keys, ammo, which perks are ticking down.

	Kept in one place so no two systems can disagree about how much shield
	somebody has.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Signal = require(Shared:WaitForChild("Signal"))

local PlayerState = {}

export type WeaponSlotState = {
	ammo: number,
	reloadingUntil: number,
	nextFireAt: number,
}

export type State = {
	shield: number,
	maxShield: number,
	lastDamagedAt: number,
	keys: number,
	carTier: number,
	megaCharges: number,
	equipped: string,
	weapons: { [string]: WeaponSlotState },
	burgerUntil: number,
	friesUntil: number,
	spawnProtectedUntil: number,
	kills: number,
	deaths: number,
	-- The vehicle this player is sitting in, if any.
	vehicle: Model?,
	seatRole: string?,
}

local states: { [Player]: State } = {}

--[[ Fired whenever anything changes that the player's screen should show. ]]
PlayerState.Changed = Signal.new()

local function freshWeapons(): { [string]: WeaponSlotState }
	local weapons = {}
	for name, spec in Config.Weapons do
		weapons[name] = {
			ammo = spec.MagSize,
			reloadingUntil = 0,
			nextFireAt = 0,
		}
	end
	return weapons
end

--[[ Start a player from scratch. Called on join and at every respawn. ]]
function PlayerState.Reset(player: Player, keepProgress: boolean)
	local previous = states[player]

	local shieldBonus = 0
	-- The shield game pass adds permanent plating. In free mode everybody has it.
	if Config.FreeMode then
		shieldBonus = 50
	end

	states[player] = {
		shield = shieldBonus,
		maxShield = shieldBonus,
		lastDamagedAt = 0,
		keys = if keepProgress and previous then previous.keys else 0,
		carTier = if keepProgress and previous then previous.carTier else 1,
		megaCharges = Config.Mega.FreeChargesPerLife,
		equipped = Config.StartingLoadout[1],
		weapons = freshWeapons(),
		burgerUntil = 0,
		friesUntil = 0,
		spawnProtectedUntil = os.clock() + Config.Combat.SpawnProtection,
		kills = if previous then previous.kills else 0,
		deaths = if previous then previous.deaths else 0,
		vehicle = nil,
		seatRole = nil,
	}

	PlayerState.Changed.Fire(player)
end

--[[ The live state for a player, creating it if this is the first ask. ]]
function PlayerState.Get(player: Player): State
	if not states[player] then
		PlayerState.Reset(player, false)
	end
	return states[player]
end

function PlayerState.Clear(player: Player)
	states[player] = nil
end

--[[ Is this player untouchable right now — just spawned, or holding a burger? ]]
function PlayerState.IsInvincible(player: Player): boolean
	local state = PlayerState.Get(player)
	local now = os.clock()
	return now < state.spawnProtectedUntil or now < state.burgerUntil
end

--[[ How many barrels this player's gun fires at once. Fries make it three. ]]
function PlayerState.BarrelCount(player: Player): number
	local state = PlayerState.Get(player)
	if os.clock() < state.friesUntil then
		return Config.Pickups.Fries.Barrels
	end
	return 1
end

--[[ Shields grow back once nobody has shot you for a few seconds. ]]
function PlayerState.RegenerateShields(deltaTime: number)
	local now = os.clock()
	for player, state in states do
		if state.maxShield > 0
			and state.shield < state.maxShield
			and now - state.lastDamagedAt > Config.Combat.ShieldRegenDelay
		then
			state.shield = math.min(
				state.maxShield,
				state.shield + Config.Combat.ShieldRegenPerSecond * deltaTime
			)
			PlayerState.Changed.Fire(player)
		end
	end
end

--[[ Hand out a key, and upgrade the car if that key was enough. ]]
function PlayerState.AwardKeys(player: Player, count: number)
	local state = PlayerState.Get(player)
	state.keys += count

	for tierIndex = #Config.CarTiers, 1, -1 do
		if state.keys >= Config.CarTiers[tierIndex].KeysRequired then
			if tierIndex > state.carTier then
				state.carTier = tierIndex
			end
			break
		end
	end

	PlayerState.Changed.Fire(player)
end

Players.PlayerRemoving:Connect(function(player)
	PlayerState.Clear(player)
end)

return PlayerState
