--!strict
--[[
	MatchService — the clock the whole game runs on.

	Vote on a map, fight on it, celebrate, repeat. Everything else in the game
	is a system this loop turns on and off at the right moment.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local MapService = require(script.Parent:WaitForChild("MapService"))
local PickupService = require(script.Parent:WaitForChild("PickupService"))
local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local TeamService = require(script.Parent:WaitForChild("TeamService"))
local VehicleService = require(script.Parent:WaitForChild("VehicleService"))
local ProjectileService = require(script.Parent:WaitForChild("ProjectileService"))
local DamageService = require(script.Parent:WaitForChild("DamageService"))
local EffectService = require(script.Parent:WaitForChild("EffectService"))

local MatchService = {}

local rng = Random.new()

local phase = "Warmup"
local phaseEndsAt = 0
local scores = { 0, 0 }
local currentMap: MapService.MapBuild? = nil
local currentMapSpec: Config.MapSpec? = nil

-- Map voting.
local ballot: { Config.MapSpec } = {}
local votes: { [Player]: number } = {}

--[[ Push the scoreboard and the clock to everybody's screen. ]]
local function broadcast()
	local payload = {
		phase = phase,
		timeLeft = math.max(0, phaseEndsAt - os.clock()),
		scores = scores,
		mapName = if currentMapSpec then currentMapSpec.Name else "—",
	}
	Remotes.Event("MatchState"):FireAllClients(payload)
end

--[[ Put a player on the ground at their team's end of the map, in a car. ]]
local function deployPlayer(player: Player, keepProgress: boolean)
	local build = currentMap
	if not build then
		return
	end

	local character = player.Character
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	PlayerState.Reset(player, keepProgress)

	local teamIndex = TeamService.IndexOf(player)
	local spawns = build.teamSpawns[teamIndex]
	local spot = spawns[rng:NextInteger(1, #spawns)]

	root.CFrame = CFrame.new(spot + Vector3.new(0, 5, 0))

	-- A car of your own, parked next to you, at whatever tier your keys earned.
	local state = PlayerState.Get(player)
	local car = VehicleService.SpawnCar(state.carTier, spot + Vector3.new(14, 0, 0), player)
	-- Wrecks clear themselves so the map does not fill up with dead cars.
	task.delay(Config.Match.RoundDuration, function()
		if car and car.Parent then
			car:Destroy()
		end
	end)
end

--[[ Everybody gets put back on the field. ]]
local function deployAll()
	for _, player in Players:GetPlayers() do
		if player.Character then
			deployPlayer(player, false)
		else
			task.spawn(function()
				player:LoadCharacterAsync()
			end)
		end
	end
end

--[[ Park one of each big toy on its pad, and put it back when it is wrecked. ]]
local function spawnMapVehicles()
	local build = currentMap
	if not build then
		return
	end

	for _, pad in build.vehiclePads do
		local spec = Config.Vehicles[pad.kind]
		local respawnDelay = if spec then spec.RespawnDelay else 30

		local function place()
			-- Stop respawning once the round that owns this pad is over.
			if currentMap ~= build then
				return
			end
			local vehicle = VehicleService.SpawnKind(pad.kind, pad.position)
			if not vehicle then
				return
			end
			vehicle.Destroying:Connect(function()
				task.delay(respawnDelay, place)
			end)
		end

		place()
	end
end

-- ================================================================== PHASES ==

local function runVoting()
	phase = "Voting"
	phaseEndsAt = os.clock() + Config.Match.VoteDuration
	table.clear(votes)

	-- Offer a few maps at random out of the ten.
	local pool = table.clone(Config.Maps)
	ballot = {}
	for _ = 1, math.min(Config.Match.MapChoices, #pool) do
		local pick = rng:NextInteger(1, #pool)
		table.insert(ballot, pool[pick])
		table.remove(pool, pick)
	end

	local options = {}
	for index, map in ballot do
		options[index] = { id = map.Id, name = map.Name }
	end
	Remotes.Event("VoteOptions"):FireAllClients(options, Config.Match.VoteDuration)

	while os.clock() < phaseEndsAt do
		broadcast()
		task.wait(0.5)
	end
end

--[[ Count the votes. A tie, or nobody voting at all, is broken at random. ]]
local function tallyVotes(): Config.MapSpec
	local counts = table.create(#ballot, 0)
	for _, choice in votes do
		if ballot[choice] then
			counts[choice] += 1
		end
	end

	local best, bestCount = 1, -1
	for index = 1, #ballot do
		if counts[index] > bestCount then
			best, bestCount = index, counts[index]
		end
	end

	if bestCount <= 0 then
		best = rng:NextInteger(1, #ballot)
	end
	return ballot[best]
end

local function runRound()
	local chosen = tallyVotes()
	currentMapSpec = chosen

	ProjectileService.ClearAll()
	VehicleService.ClearAll()

	currentMap = MapService.Build(chosen)
	local build = currentMap
	if build then
		PickupService.Build(build.pickupPads)
	end
	spawnMapVehicles()

	scores = { 0, 0 }
	phase = "Playing"
	phaseEndsAt = os.clock() + Config.Match.RoundDuration

	deployAll()

	while os.clock() < phaseEndsAt do
		broadcast()
		if scores[1] >= Config.Match.ScoreLimit or scores[2] >= Config.Match.ScoreLimit then
			break
		end
		task.wait(0.5)
	end
end

local function runIntermission()
	phase = "Intermission"
	phaseEndsAt = os.clock() + Config.Match.IntermissionDuration

	-- Who won, and the WIENER treatment for them.
	local winnerIndex = if scores[1] == scores[2] then 0 elseif scores[1] > scores[2] then 1 else 2
	local winnerName = if winnerIndex == 0 then "NOBODY" else Config.Teams[winnerIndex].Name
	EffectService.CelebrateWinner(winnerName)

	while os.clock() < phaseEndsAt do
		broadcast()
		task.wait(0.5)
	end

	ProjectileService.ClearAll()
	VehicleService.ClearAll()
	PickupService.Clear()
	MapService.Clear()
	currentMap = nil
end

--[[ The loop itself. It never stops for as long as the server is up. ]]
local function loop()
	while true do
		if #Players:GetPlayers() < Config.Match.MinPlayers then
			phase = "Warmup"
			phaseEndsAt = os.clock() + 1
			broadcast()
			task.wait(1)
			continue
		end

		runVoting()
		runRound()
		runIntermission()
	end
end

-- =================================================================== SETUP ==

function MatchService.Start()
	-- A kill is worth points to the killer's team.
	DamageService.Killed.Connect(function(victim: Player, killer: Player?, _cause: string)
		local character = victim.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			EffectService.PlayDeathGag(root.Position)
		end

		EffectService.ShowDeathScreen(victim, if killer then killer.DisplayName else nil)

		if killer and killer ~= victim and phase == "Playing" then
			local teamIndex = TeamService.IndexOf(killer)
			scores[teamIndex] += Config.Match.PointsPerKill
			broadcast()
		end
	end)

	Remotes.Event("CastVote").OnServerEvent:Connect(function(player, choice)
		if phase ~= "Voting" then
			return
		end
		if typeof(choice) ~= "number" then
			return
		end
		local index = math.floor(choice)
		if ballot[index] then
			votes[player] = index
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		TeamService.Assign(player)

		player.CharacterAdded:Connect(function()
			-- Give the character a moment to finish assembling before moving it.
			task.wait(0.35)
			if phase == "Playing" then
				-- Respawning mid-round keeps your keys, so a good run is not
				-- wiped out by one unlucky rocket.
				deployPlayer(player, true)
			end
		end)

		if player.Character then
			task.wait(0.35)
			deployPlayer(player, true)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		votes[player] = nil
	end)

	task.spawn(loop)
end

--[[ Which phase the game is in, for anything that needs to care. ]]
function MatchService.Phase(): string
	return phase
end

return MatchService
