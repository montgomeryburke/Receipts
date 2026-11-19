--!strict
--[[
	MatchService — the clock the whole game runs on.

	Vote on a map, fight on it, celebrate, repeat. Everything else in the game
	is a system this loop turns on and off at the right moment.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local MapService = require(script.Parent:WaitForChild("MapService"))
local PickupService = require(script.Parent:WaitForChild("PickupService"))
local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local TeamService = require(script.Parent:WaitForChild("TeamService"))
local VehicleService = require(script.Parent:WaitForChild("VehicleService"))
local HockeyService = require(script.Parent:WaitForChild("HockeyService"))
local WildlifeService = require(script.Parent:WaitForChild("WildlifeService"))
local FlagService = require(script.Parent:WaitForChild("FlagService"))
local CarnivalService = require(script.Parent:WaitForChild("CarnivalService"))
local BasketballService = require(script.Parent:WaitForChild("BasketballService"))
local BowlingService = require(script.Parent:WaitForChild("BowlingService"))
local FireService = require(script.Parent:WaitForChild("FireService"))
local ProjectileService = require(script.Parent:WaitForChild("ProjectileService"))
local DamageService = require(script.Parent:WaitForChild("DamageService"))
local EffectService = require(script.Parent:WaitForChild("EffectService"))
local MedalService = require(script.Parent:WaitForChild("MedalService"))
local ScoreboardService = require(script.Parent:WaitForChild("ScoreboardService"))
local HockeyService = require(script.Parent:WaitForChild("HockeyService"))
local ResortService = require(script.Parent:WaitForChild("ResortService"))

local MatchService = {}

local rng = Random.new()

local phase = "Warmup"
local phaseEndsAt = 0
local scores = { 0, 0 }
local currentMap: MapService.MapBuild? = nil
local currentMapSpec: Config.MapSpec? = nil
local currentMode = Config.Modes[1]

-- Map voting. Each option is a map paired with a mode, so one vote picks
-- both what you play and where.
local ballot: { { map: Config.MapSpec, mode: typeof(Config.Modes[1]) } } = {}
local votes: { [Player]: number } = {}

-- The one car each player currently owns.
local playerCars: { [Player]: Model } = {}

--[[
	Medals.

	Halo's two kinds, and they are different things: a MULTIKILL is several
	kills close together in time, and a SPREE is many kills without dying.
	Tracked per player and reset by death.
]]
local recentKills: { [Player]: { number } } = {}
local sprees: { [Player]: number } = {}

local MULTIKILL_WINDOW = 4.5

local MULTIKILL_NAMES = {
	[2] = "DOUBLE KILL",
	[3] = "TRIPLE KILL",
	[4] = "OVERKILL",
	[5] = "KILLTACULAR",
	[6] = "KILLTROCITY",
}

local SPREE_NAMES = {
	[5] = "KILLING SPREE",
	[10] = "RUNNING RIOT",
	[15] = "RAMPAGE",
	[20] = "UNTOUCHABLE",
}

--[[ Everybody sees who killed whom. ]]
local function killFeed(killer: Player?, victim: Player, cause: string)
	local line = if killer
		then `{killer.DisplayName}  ▸  {cause}  ▸  {victim.DisplayName}`
		else `{victim.DisplayName} died — {cause}`

	for _, player in Players:GetPlayers() do
		Remotes.Event("KillFeed"):FireClient(player, line, player == killer)
	end
end

--[[ Work out whether this kill earned a medal, and announce it if so. ]]
local function awardMedals(killer: Player)
	local now = os.clock()

	-- Multikill: how many in the last few seconds.
	local window = recentKills[killer] or {}
	table.insert(window, now)
	for index = #window, 1, -1 do
		if now - window[index] > MULTIKILL_WINDOW then
			table.remove(window, index)
		end
	end
	recentKills[killer] = window

	local multi = MULTIKILL_NAMES[#window]
	if multi then
		Remotes.Event("Medal"):FireClient(killer, multi)
		Remotes.Event("PlaySound"):FireClient(killer, "Medal")
	end

	-- Spree: how many since last dying.
	sprees[killer] = (sprees[killer] or 0) + 1
	local spree = SPREE_NAMES[sprees[killer]]
	if spree then
		for _, player in Players:GetPlayers() do
			Remotes.Event("Medal"):FireClient(player, `{killer.DisplayName}: {spree}`)
		end
		Remotes.Event("PlaySound"):FireClient(killer, "Medal")
	end
end

--[[ The two team colours, for painting the spawn pads. ]]
local function teamColours(): { BrickColor }
	local colours = {}
	for index, spec in Config.Teams do
		colours[index] = spec.Color
	end
	return colours
end

--[[
	Tear down whatever arena is standing and put a new one up.

	This is deliberately separate from starting a round, because the world
	must never be empty: an arena exists from the moment the server boots,
	long before the first round begins.
]]
local function buildArena(entry: { map: Config.MapSpec, mode: typeof(Config.Modes[1]) })
	local spec = entry.map
	currentMapSpec = spec
	currentMode = entry.mode

	ProjectileService.ClearAll()
	VehicleService.ClearAll()
	PickupService.Clear()

	currentMap = MapService.Build(spec, teamColours())
	local build = currentMap
	if build then
		PickupService.Build(build.pickupPads)
	end
	MatchService.SpawnMapVehicles()

	WildlifeService.Populate(spec.Size)
	CarnivalService.Build(spec.Size)
	-- Gas cans out in the open where routes cross, so they get used and
	-- shot rather than sitting unfound inside a building.
	FireService.Build(spec.Size)
	BasketballService.Build(spec.Size)
	BowlingService.Build(spec.Size)
	-- And the rink, which builds its own model beside the arena.
	HockeyService.Build(spec.Size)

	-- Flags only exist in Capture the Flag.
	FlagService.Clear()
	if currentMode.Id == "CTF" and build then
		FlagService.Setup(build, teamColours())
	end
end

--[[ Push the scoreboard and the clock to everybody's screen. ]]
local function broadcast()
	local payload = {
		phase = phase,
		timeLeft = math.max(0, phaseEndsAt - os.clock()),
		scores = scores,
		mapName = if currentMapSpec then currentMapSpec.Name else "—",
		modeName = currentMode.Name,
		-- Only meaningful in Capture the Flag, ignored otherwise.
		flags = if FlagService.IsActive()
			then { FlagService.StateOf(1), FlagService.StateOf(2) }
			else nil,
	}
	Remotes.Event("MatchState"):FireAllClients(payload)
end

--[[ The same noise in everybody's ears at once, for match-wide moments. ]]
local function fanfare(soundName: string)
	for _, player in Players:GetPlayers() do
		Remotes.Event("PlaySound"):FireClient(player, soundName)
	end
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

	if not player.Parent then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and not keepProgress then
		humanoid.Sit = false
		humanoid.Health = humanoid.MaxHealth
	end

	--[[
		How fast you move on foot, and how high you jump.

		Nothing set these. Config.Turbo.WalkSpeed existed and was read when
		turbo switched OFF and when a flag carrier was slowed down -- but
		never to establish the baseline -- so everybody walked at Roblox's
		default 16 studs a second regardless of what the config said, which
		is a plod across a 2000-stud map.
	]]
	if humanoid then
		humanoid.WalkSpeed = Config.Turbo.WalkSpeed
		humanoid.JumpPower = Config.Movement.JumpPower
		humanoid.UseJumpPower = true
	end

	PlayerState.Reset(player, keepProgress)

	local teamIndex = TeamService.IndexOf(player)
	local spawns = build.teamSpawns[teamIndex]
	if not spawns or #spawns == 0 then
		spawns = { Vector3.new(0, 8, 0) }
	end
	local spot = spawns[rng:NextInteger(1, #spawns)]

	root.CFrame = CFrame.new(spot + Vector3.new(0, 5, 0))

	-- A car of your own, parked next to you, at whatever tier your keys earned.
	-- The last one goes first, so dying twenty times does not leave twenty
	-- abandoned cars sitting on the map.
	local previous = playerCars[player]
	if previous and previous.Parent then
		previous:Destroy()
	end

	local state = PlayerState.Get(player)
	playerCars[player] = VehicleService.SpawnCar(state.carTier, spot + Vector3.new(14, 0, 0), player)
end

--[[ Everybody gets put back on the field. ]]
local function deployAll()
	for _, player in Players:GetPlayers() do
		if player.Character then
			deployPlayer(player, false)
		else
			PlayerState.Reset(player, false)
			task.spawn(function()
				if player.Parent then
					player:LoadCharacterAsync()
				end
			end)
		end
	end
end

--[[ Park one of each big toy on its pad, and put it back when it is wrecked. ]]
function MatchService.SpawnMapVehicles()
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
	for index = 1, math.min(Config.Match.MapChoices, #pool) do
		local pick = rng:NextInteger(1, #pool)
		-- Alternate the modes down the ballot so both are always on offer.
		local mode = Config.Modes[((index - 1) % #Config.Modes) + 1]
		table.insert(ballot, { map = pool[pick], mode = mode })
		table.remove(pool, pick)
	end

	local options = {}
	for index, entry in ballot do
		options[index] = {
			id = entry.map.Id,
			name = `{entry.mode.Name} · {entry.map.Name}`,
			blurb = entry.mode.Blurb,
		}
	end
	Remotes.Event("VoteOptions"):FireAllClients(options, Config.Match.VoteDuration)

	while os.clock() < phaseEndsAt do
		broadcast()
		task.wait(0.5)
	end
end

--[[ Count the votes. A tie, or nobody voting at all, is broken at random. ]]
local function tallyVotes(): { map: Config.MapSpec, mode: typeof(Config.Modes[1]) }
	local counts = table.create(#ballot, 0)
	for _, choice in votes do
		if ballot[choice] then
			counts[choice] += 1
		end
	end

	local bestCount = -1
	local tied: { number } = {}
	for index = 1, #ballot do
		if counts[index] > bestCount then
			bestCount = counts[index]
			table.clear(tied)
			table.insert(tied, index)
		elseif counts[index] == bestCount then
			table.insert(tied, index)
		end
	end

	if bestCount <= 0 or #tied == 0 then
		return ballot[rng:NextInteger(1, #ballot)]
	end
	return ballot[tied[rng:NextInteger(1, #tied)]]
end

local function runRound()
	-- The arena is already standing; a round is just the clock and the score.
	scores = { 0, 0 }
	table.clear(recentKills)
	table.clear(sprees)
	phase = "Playing"
	phaseEndsAt = os.clock() + Config.Match.RoundDuration

	deployAll()
	fanfare("RoundStart")

	while os.clock() < phaseEndsAt do
		broadcast()
		-- Each mode has its own target.
		local limit = currentMode.ScoreLimit or Config.Match.ScoreLimit
		if scores[1] >= limit or scores[2] >= limit then
			break
		end
		task.wait(0.5)
	end
end

local function runIntermission()
	phase = "Intermission"
	phaseEndsAt = os.clock() + Config.Match.IntermissionDuration

	-- Who won, and the WIENER treatment for them.
	-- Whichever team has the most points at the whistle, in either mode.
	local winnerIndex = if scores[1] == scores[2] then 0 elseif scores[1] > scores[2] then 1 else 2
	local winnerName = if winnerIndex == 0 then "NOBODY" else Config.Teams[winnerIndex].Name
	EffectService.CelebrateWinner(winnerName)
	fanfare("RoundEnd")

	--[[
		The MVP, named with what they did it at.

		"Won the round by dominating the minigames" is only a real claim if
		the game can point at the minigames, so the shout says what they
		scored most of their points doing -- a round won at the carnival and
		a round won by shooting people produce the same number and are not
		the same round.
	]]
	local mvpName, mvpPoints, mvpAt = ScoreboardService.Mvp()
	if mvpName then
		Remotes.Event("KillFeed"):FireAllClients(
			if mvpAt
				then `MVP: {mvpName} — {mvpPoints} pts, mostly {mvpAt}`
				else `MVP: {mvpName} — {mvpPoints} pts`,
			false
		)
	end

	-- Put the final standings up without anybody having to reach for Tab.
	-- It is the one moment everyone wants to see them.
	pcall(ScoreboardService.PushAll)

	while os.clock() < phaseEndsAt do
		broadcast()
		task.wait(0.5)
	end

	-- Wreckage and bullets go; the arena itself stays standing until the
	-- next one is built, so there is never a moment with no world.
	ProjectileService.ClearAll()
end

--[[
	The loop itself. It never stops for as long as the server is up.

	Order matters: we fight on the arena that is already standing, and only
	vote for the next map afterwards. Voting first would mean twenty seconds
	of everybody staring at an empty sky.
]]
local function loop()
	while true do
		if #Players:GetPlayers() < Config.Match.MinPlayers then
			-- Nobody here yet. The arena still exists, so anyone who does
			-- turn up can drive around it while they wait.
			phase = "Warmup"
			phaseEndsAt = os.clock() + 1
			broadcast()
			task.wait(1)
			continue
		end

		runRound()
		runIntermission()
		runVoting()
		buildArena(tallyVotes())
	end
end

-- =================================================================== SETUP ==

function MatchService.Start()
	-- A kill is worth points to the killer's team.
	-- What each weapon's display name is worth, so a kill can be scored by
	-- the thing that made it.
	local pointsByWeapon: { [string]: number } = {}
	for _, spec in Config.Weapons do
		pointsByWeapon[spec.DisplayName] = spec.Points or Config.Match.PointsPerKill
	end
	pointsByWeapon.Melee = 20
	pointsByWeapon.Trampled = 15
	pointsByWeapon.Explosion = 15

	--[[
		Everything that scores, scoring for the team.

		One subscription instead of a signal per activity. Before this the
		round was decided by the four things MatchService happened to be
		wired to -- kills, flag captures, hockey goals, tricks -- so a
		carnival stall, a bot kill, a won hockey fight and a flag grab all
		gave personal points that could not win the round. Nobody would ever
		notice from playing: the number on your own scoreboard went up.

		The point of doing it here rather than in each service is that the
		next activity added gets this for free. A new minigame that calls
		AwardPoints is part of the round whether or not whoever wrote it
		knew this file existed.
	]]
	PlayerState.Scored.Connect(function(player: Player, earned: number, reason: string)
		if phase ~= "Playing" or not player.Parent then
			return
		end
		local teamIndex = TeamService.IndexOf(player)
		if teamIndex ~= 1 and teamIndex ~= 2 then
			return
		end
		scores[teamIndex] += earned
		Remotes.Event("Notify"):FireClient(player, `+{earned} — {reason}`)
		broadcast()
	end)

	DamageService.Killed.Connect(function(victim: Player, killer: Player?, cause: string)
		local character = victim.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			EffectService.PlayDeathGag(root.Position)
		end

		EffectService.ShowDeathScreen(victim, if killer then killer.DisplayName else nil)
		killFeed(killer, victim, cause)

		-- Dying ends your spree and your multikill window.
		sprees[victim] = 0
		recentKills[victim] = {}

		if killer and killer ~= victim and killer.Parent and phase == "Playing" then
			local base = pointsByWeapon[cause] or Config.Match.PointsPerKill
			-- The team score moves in the Scored handler below, which every
			-- award goes through. Adding it here as well would count a kill
			-- twice for the round and once for the player.
			PlayerState.AwardPoints(killer, base, cause)
			Remotes.Event("PlaySound"):FireClient(killer, "KillConfirm")

			--[[
				Shot somebody while off the ground.

				Checked here rather than in the weapon code because it is a
				fact about the KILLER at the moment of the kill, and this is
				where a kill is known about. FloorMaterial is the engine's
				own answer to "are they standing on anything", which beats
				guessing from vertical velocity -- that reads as airborne at
				the top of a ramp and on a lift.

				Hang gliding over the map is the main way this happens, and
				it is exactly the thing worth rewarding about hang gliding
				over the map.
			]]
			local killerCharacter = killer.Character
			local killerHumanoid = killerCharacter
				and killerCharacter:FindFirstChildOfClass("Humanoid")
			if killerHumanoid and killerHumanoid.FloorMaterial == Enum.Material.Air then
				MedalService.Award(killer, "AirborneKill")
			end

			awardMedals(killer)
		end
	end)

	--[[
		A capture already scored through AwardPoints inside FlagService, so
		this only exists for what the capture SAYS. The sum used to be here
		too, which meant a capture moved the team score twice.
	]]
	FlagService.Captured.Connect(function(_player: Player, _teamIndex: number, _points: number)
		if phase == "Playing" then
			broadcast()
		end
	end)

	HockeyService.Goal.Connect(function(scorer: Player?, teamIndex: number, points: number)
		if phase == "Playing" then
			--[[
				An own goal, or a goal nobody can be blamed for, still has
				to count for the team that benefits.

				A scorer on the right side already scored through
				AwardPoints, which moves the team total in the Scored
				handler. With no scorer -- a deflection off a car, a puck
				that drifted in -- there is nobody to award, so the goal is
				credited straight to the team here. Without this a goal with
				no clear scorer was simply not a goal.
			]]
			if not (scorer and scorer.Parent and TeamService.IndexOf(scorer) == teamIndex) then
				scores[teamIndex] += points
			end
			broadcast()
		end
		if scorer and scorer.Parent then
			Remotes.Event("KillFeed"):FireAllClients(`{scorer.DisplayName} SCORED A GOAL! (+{points})`, false)
		end
	end)

	FlagService.Start()
	ResortService.Start()

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

	--[[
		Set a player up. Pulled out of the PlayerAdded handler because in
		Studio the local player can already be in the game by the time this
		script runs — in which case PlayerAdded never fires for them, and
		without this they would never be assigned a team or given a car.
	]]
	local function setUpPlayer(player: Player)
		TeamService.Assign(player)

		player.CharacterAdded:Connect(function()
			task.wait(0.35)
			if player.Parent then
				deployPlayer(player, true)
			end
		end)

		if player.Character then
			task.spawn(function()
				task.wait(0.35)
				if player.Parent then
					deployPlayer(player, true)
				end
			end)
		end
	end

	Players.PlayerAdded:Connect(setUpPlayer)

	-- Anybody already here before this script got going. Called directly
	-- rather than deferred: there is nothing to wait for, and running it now
	-- means a player who is already present is set up before the first round.
	for _, player in Players:GetPlayers() do
		setUpPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		votes[player] = nil
		recentKills[player] = nil
		sprees[player] = nil
		local car = playerCars[player]
		if car and car.Parent then
			car:Destroy()
		end
		playerCars[player] = nil
	end)

	-- A safety net. Fly a plane over the boundary wall and you would otherwise
	-- fall forever; this notices and respawns you instead.
	RunService.Heartbeat:Connect(function()
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and root.Position.Y < -120 then
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health > 0 then
					DamageService.ApplyDamage(player, humanoid.MaxHealth + 1000, nil, "Void")
					if humanoid.Health > 0 then
						humanoid.Health = 0
					end
				end
			end
		end
	end)

	-- The world exists before anybody can possibly join it.
	buildArena({
		map = Config.Maps[rng:NextInteger(1, #Config.Maps)],
		mode = Config.Modes[rng:NextInteger(1, #Config.Modes)],
	})

	task.spawn(loop)
end

--[[
	Put the match straight into a running round.

	Only the tests use this: kills are deliberately ignored outside a round,
	so without it a test would have to wait out the real loop to score one.
]]
--[[
	Shout about a landed trick.

	Tricks come out of VehicleService, which has no idea the HUD exists, so
	the announcement is wired up here where the kill feed and the medals
	already live.
]]
VehicleService.TrickLanded.Connect(function(player: Player, name: string, points: number, airtime: number)
	if not player.Parent then
		return
	end
	-- Scored through AwardPoints in VehicleService; this is the celebration.
	if phase == "Playing" then
		broadcast()
	end
	Remotes.Event("Medal"):FireClient(player, `{name}  +{points}`)
	Remotes.Event("PlaySound"):FireClient(player, "Medal")

	local team = player.Team
	if team then
		Remotes.Event("KillFeed"):FireAllClients(
			`{player.DisplayName} landed a {name} ({string.format("%.1f", airtime)}s air)`,
			false
		)
	end
end)

function MatchService.ForceRoundForTests()
	phase = "Playing"
	phaseEndsAt = os.clock() + Config.Match.RoundDuration
	scores = { 0, 0 }
	table.clear(recentKills)
	table.clear(sprees)
end

--[[ Which phase the game is in, for anything that needs to care. ]]
function MatchService.Phase(): string
	return phase
end

--[[
	The team totals, for tests.

	Exposed because the claim worth testing is not "AwardPoints adds up" --
	it is that scoring at a carnival stall moves the number that ENDS the
	round. Without a way to read it, the only proof of that would be reading
	the code and believing it.
]]
function MatchService.ScoresForTests(): { number }
	return { scores[1], scores[2] }
end

--[[ Force the phase, so the between-rounds guard can be tested at all. ]]
function MatchService.SetPhaseForTests(next: string)
	phase = next
end

return MatchService
