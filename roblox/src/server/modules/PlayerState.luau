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
	nextMeleeAt: number,
	-- Points scored this round, and the multiplier ticking down on them.
	points: number,
	--[[
		Points by reason: "hockey goal", "won the fight", "Rifle", a trick
		name, a carnival stall's own wording.

		This is what lets the end of a round say HOW somebody won it rather
		than only that they did. "Won the round by dominating minigames" is
		only a real claim if the game can point at the minigames.
	]]
	scoredBy: { [string]: number },
	multiplierUntil: number,
	multiplierAmount: number,
	kills: number,
	deaths: number,
	-- The vehicle this player is sitting in, if any.
	vehicle: Model?,
	seatRole: string?,
}

local states: { [Player]: State } = {}

--[[ Fired whenever anything changes that the player's screen should show. ]]
PlayerState.Changed = Signal.new()

--[[
	Fired as (player, earned, reason) whenever anybody scores anything.

	MatchService listens to this to move the team score, so the round is
	decided by the same number the player sees on their own scoreboard. One
	subscriber, one truth.
]]
PlayerState.Scored = Signal.new()

local function freshWeapons(): { [string]: WeaponSlotState }
	local weapons = {}
	for name, spec in Config.Weapons do
		weapons[name] = {
			ammo = if spec.AmmoFromPickupsOnly then 0 else spec.MagSize,
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
		megaCharges = if keepProgress and previous
			then math.max(Config.Mega.FreeChargesPerLife, previous.megaCharges)
			else Config.Mega.FreeChargesPerLife,
		equipped = Config.StartingLoadout[1],
		weapons = freshWeapons(),
		burgerUntil = 0,
		friesUntil = 0,
		spawnProtectedUntil = os.clock() + Config.Combat.SpawnProtection,
		nextMeleeAt = 0,
		-- Points, kills and deaths are per ROUND, so they survive a respawn
		-- but are wiped when a new round deploys everybody fresh.
		points = if keepProgress and previous then previous.points else 0,
		scoredBy = if keepProgress and previous then previous.scoredBy else {},
		multiplierUntil = if keepProgress and previous then previous.multiplierUntil else 0,
		multiplierAmount = if keepProgress and previous then previous.multiplierAmount else 1,
		kills = if keepProgress and previous then previous.kills else 0,
		deaths = if keepProgress and previous then previous.deaths else 0,
		vehicle = nil,
		seatRole = nil,
	}

	PlayerState.Changed.Fire(player)
end

--[[ The live state for a player, creating it if this is the first ask. ]]
function PlayerState.Get(player: Player): State
	local existing = states[player]
	if existing then
		return existing
	end
	if not player.Parent then
		-- Return an untracked dummy state so departed players never leak into `states`.
		return {
			shield = 0,
			maxShield = 0,
			lastDamagedAt = 0,
			keys = 0,
			carTier = 1,
			megaCharges = 0,
			equipped = Config.StartingLoadout[1],
			weapons = freshWeapons(),
			burgerUntil = 0,
			friesUntil = 0,
			spawnProtectedUntil = 0,
			nextMeleeAt = 0,
			points = 0,
			scoredBy = {},
			multiplierUntil = 0,
			multiplierAmount = 1,
			kills = 0,
			deaths = 0,
			vehicle = nil,
			seatRole = nil,
		}
	end
	PlayerState.Reset(player, false)
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

--[[ The multiplier on this player's points right now, or 1. ]]
function PlayerState.PointMultiplier(player: Player): number
	local state = PlayerState.Get(player)
	if os.clock() < state.multiplierUntil then
		return state.multiplierAmount
	end
	return 1
end

--[[
	Score, with whatever multiplier is running applied.

	THIS IS THE ONLY WAY TO SCORE, and the Scored signal is what makes that
	worth anything. Every activity on the map already called this for its
	personal points, but the ROUND was decided by four signals MatchService
	happened to be wired to -- kills, flag captures, hockey goals, tricks.
	So winning a carnival stall, killing a bot, winning a hockey fight or
	grabbing a flag gave you points that could never win the round, and the
	only way to tell was to read MatchService and notice what was missing.

	Inverting it means anything that awards a point moves the team score by
	construction, including the next activity somebody adds without reading
	this comment.

	The reason string is not decoration: it is what the kill feed says, what
	the medal check reads, and the only record of WHY a point was given --
	which is the thing you want when a score looks wrong.
]]
function PlayerState.AwardPoints(player: Player, base: number, reason: string?): number
	local state = PlayerState.Get(player)
	local earned = math.floor(base * PlayerState.PointMultiplier(player))
	if earned == 0 then
		-- A zero award still fires Changed below in the old code, but there
		-- is nothing to tell the match about and no reason to redraw.
		return 0
	end
	local why = reason or "scored"
	state.points += earned
	state.scoredBy[why] = (state.scoredBy[why] or 0) + earned
	PlayerState.Changed.Fire(player)
	PlayerState.Scored.Fire(player, earned, why)
	return earned
end

--[[ Shields grow back once nobody has shot you for a few seconds. ]]
function PlayerState.RegenerateShields(deltaTime: number)
	local now = os.clock()
	for player, state in states do
		if not player.Parent then
			states[player] = nil
			continue
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			continue
		end
		if state.maxShield > 0
			and state.shield < state.maxShield
			and now - state.lastDamagedAt > Config.Combat.ShieldRegenDelay
		then
			local prevFloor = math.floor(state.shield)
			state.shield = math.min(
				state.maxShield,
				state.shield + Config.Combat.ShieldRegenPerSecond * deltaTime
			)
			if math.floor(state.shield) ~= prevFloor or state.shield >= state.maxShield then
				PlayerState.Changed.Fire(player)
			end
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
