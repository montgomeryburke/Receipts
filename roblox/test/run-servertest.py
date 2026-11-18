#!/usr/bin/env python3
"""
Run the entire server bootstrap outside Roblox.

Roblox Studio cannot be driven from a terminal, so this stitches every real
server module together with stand-ins for the Roblox API and executes
init.server.luau completely unmodified. It answers the one question that
matters: does opening this place actually produce a world?

    python3 test/run-servertest.py > /tmp/a.luau && luau /tmp/a.luau
    python3 test/run-servertest.py --block-datastore > /tmp/b.luau && luau /tmp/b.luau

The second run simulates an UNPUBLISHED place, where Roblox refuses DataStore
access. That exact case once killed the server script before it built the
arena, and players fell through an empty sky. Both runs must print ARENA: true.
"""
import os, re, sys

# Kept out of the harness f-string on purpose: Luau is full of braces, and
# an f-string reads every one of them as an expression.
MEDAL_TEST = '''
-- ------------------------------------------------------- medals and feed
-- Throw away whatever boot spawned before testing anything. The match loop
-- is in there and it never returns, so flushing it would hang.
SPAWNED = {}

local failures = 0
local function check(label, condition, detail)
	if condition then
		DUMP(string.format("  PASS  %-40s %s", label, detail or ""))
	else
		DUMP(string.format("  FAIL  %-40s %s", label, detail or ""))
		failures += 1
	end
end

local function makeFighter(name, userId)
	local character = Instance.new("Model")
	character._props.Name = name
	local root = Instance.new("Part")
	root._props.Name = "HumanoidRootPart"
	root._props.CFrame = CFrame.new(0, 5, 0)
	root.Parent = character
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character
	character.Parent = workspace

	local player = Instance.new("Player")
	player._props.Name = name
	player._props.DisplayName = name
	player._props.UserId = userId
	player._props.Character = character
	player._props.CharacterAdded = SIGNAL()
	player._props.LoadCharacterAsync = function() end
	-- Parented, because plenty of real code treats a nil Parent as "this
	-- player has left" and bails -- correctly. Without it a hockey fight was
	-- discarded as an abandoned one instead of being settled, and the skis
	-- dropped their rider on the first frame.
	player.Parent = Players
	return player
end

local killer = makeFighter("Killer", 10)
local prey = makeFighter("Prey", 11)
rawget(Players, "_props").GetPlayers = function() return { killer, prey } end
PLAYERS_FOR_TEAMS = { killer, prey }
TeamService.Assign(killer)
TeamService.Assign(prey)
if killer._props.Team == prey._props.Team then
	prey._props.Team = TeamService.Get(if TeamService.IndexOf(killer) == 1 then 2 else 1)
end

MatchService.ForceRoundForTests()

local function medalsSent()
	local names = {}
	for _, call in FIRED_TO("Medal") do
		table.insert(names, tostring(call.args[1]))
	end
	return names
end

FIRED = {}
DamageService.Killed.Fire(prey, killer, "Sniper Rifle")
RUN_SPAWNED()
check("a kill reaches the kill feed", #FIRED_TO("KillFeed") > 0,
	string.format("%d lines", #FIRED_TO("KillFeed")))
check("the killer hears a confirm", #FIRED_TO("PlaySound") > 0, "")
check("one kill earns no medal", #medalsSent() == 0, table.concat(medalsSent(), ", "))

DamageService.Killed.Fire(prey, killer, "Sniper Rifle")
RUN_SPAWNED()
check("two quick kills is a DOUBLE KILL",
	string.find(table.concat(medalsSent(), ","), "DOUBLE KILL") ~= nil,
	table.concat(medalsSent(), ", "))

FIRED = {}
DamageService.Killed.Fire(prey, killer, "Sniper Rifle")
RUN_SPAWNED()
check("three is a TRIPLE KILL",
	string.find(table.concat(medalsSent(), ","), "TRIPLE KILL") ~= nil,
	table.concat(medalsSent(), ", "))

FIRED = {}
DamageService.Killed.Fire(prey, killer, "Sniper Rifle")
DamageService.Killed.Fire(prey, killer, "Sniper Rifle")
RUN_SPAWNED()
check("five without dying is a SPREE",
	string.find(table.concat(medalsSent(), ","), "KILLING SPREE") ~= nil,
	table.concat(medalsSent(), ", "))

FIRED = {}
DamageService.Killed.Fire(killer, prey, "Pistol")
RUN_SPAWNED()
FIRED = {}
DamageService.Killed.Fire(prey, killer, "Sniper Rifle")
RUN_SPAWNED()
check("dying resets the multikill window", #medalsSent() == 0,
	table.concat(medalsSent(), ", "))

-- ------------------------------------------------------------ scoreboard
-- A game scored by points is unplayable without one, and it has to survive
-- the awkward cases: a player with no team, and a request arriving before
-- anybody has scored anything.
PlayerState.AwardPoints(killer, 250)
PlayerState.AwardPoints(prey, 90)

FIRED = {}
ScoreboardService.Send(killer)
local sent = FIRED_TO("Scoreboard")
check("a request gets a scoreboard back", #sent == 1, string.format("%d payloads", #sent))

if #sent == 1 then
	local payload = sent[1].args[1]
	local rows = payload and payload.rows
	check("it lists every player", rows and #rows == 2, string.format("%d rows", rows and #rows or 0))
	check("the heading totals the teams",
		payload and type(payload.heading) == "string" and #payload.heading > 0,
		tostring(payload and payload.heading))

	if rows and #rows == 2 then
		-- Sorted by team, then by points within the team. Both players are
		-- on different teams here, so check the fields arrived at all.
		local found = 0
		local marked = 0
		for _, row in rows do
			if row.points and row.points > 0 then found += 1 end
			if row.isYou then marked += 1 end
		end
		check("points reach the panel", found == 2, string.format("%d rows scored", found))
		check("your own row is marked", marked == 1, string.format("%d marked", marked))
	end
end

-- The end of a round pushes it to everybody unasked.
FIRED = {}
ScoreboardService.PushAll()
check("the round end pushes to everyone", #FIRED_TO("Scoreboard") == 2,
	string.format("%d pushes", #FIRED_TO("Scoreboard")))

-- --------------------------------------------------------------- zombies
-- Every zombie used to walk the whole player list itself, every frame. The
-- scan is shared now, so this checks the behaviour that change could break:
-- that a zombie still finds the nearest living player and closes on them,
-- and still ignores a dead one.
WildlifeService.Populate(900)
check("the map is populated", WildlifeService.CountOf("Zombie") > 0,
	string.format("%d zombies, %d civilians",
		WildlifeService.CountOf("Zombie"), WildlifeService.CountOf("Civilian")))

do
	-- Put the prey somewhere definite and well inside the chase range.
	local preyRoot = prey._props.Character:FindFirstChild("HumanoidRootPart")
	preyRoot._props.CFrame = CFrame.new(0, 5, 0)
	local killerRoot = killer._props.Character:FindFirstChild("HumanoidRootPart")
	killerRoot._props.CFrame = CFrame.new(2000, 5, 2000) -- far away, not the target

	local zombie = WildlifeService.NearestZombieForTests(Vector3.new(0, 5, 0))
	check("a zombie exists to chase", zombie ~= nil, "")

	if zombie then
		local before = (zombie.position - Vector3.new(0, 5, 0)).Magnitude
		for _ = 1, 120 do
			ADVANCE(1 / 60)
			RunService.Heartbeat._fire(1 / 60)
		end
		local after = (zombie.position - Vector3.new(0, 5, 0)).Magnitude
		check("a zombie closes on the nearest player", after < before - 5,
			string.format("%.0f studs away, was %.0f", after, before))

		-- A dead player is not prey.
		prey._props.Character:FindFirstChildOfClass("Humanoid")._props.Health = 0
		local stalled = (zombie.position - Vector3.new(0, 5, 0)).Magnitude
		for _ = 1, 120 do
			ADVANCE(1 / 60)
			RunService.Heartbeat._fire(1 / 60)
		end
		local wandered = (zombie.position - Vector3.new(0, 5, 0)).Magnitude
		check("a dead player is not chased", wandered >= stalled - 1,
			string.format("%.0f studs away, was %.0f", wandered, stalled))
	end
end

-- ------------------------------------------------- wrecked vehicles hurt
-- Every exploding vehicle used to deal exactly zero damage: the blast was a
-- raw Explosion instance with joint-breaking switched off, which is the only
-- damage a Roblox Explosion does. Riding a torpedo into somebody -- the
-- entire purpose of the torpedo -- did nothing to them. It typechecked fine
-- and looked right on screen, which is why it survived so long.
do
	local preyHumanoid = prey._props.Character:FindFirstChildOfClass("Humanoid")
	local preyRoot = prey._props.Character:FindFirstChild("HumanoidRootPart")
	preyRoot._props.CFrame = CFrame.new(0, 5, 0)
	preyHumanoid._props.Health = 100
	preyHumanoid._props.MaxHealth = 100
	PlayerState.Reset(prey, false)

	local torpedo = VehicleService.SpawnTorpedo(Vector3.new(0, 5, 0))
	check("a torpedo spawns", torpedo ~= nil, "")

	-- A freshly reset player has spawn protection, and a blast must respect
	-- it. Worth asserting on the way past, since it is the reason the first
	-- version of this test read as a failure when the code was fine.
	local shielded = PlayerState.Get(prey)
	VehicleService.Explode(torpedo)
	RUN_SPAWNED()
	check("spawn protection soaks a blast", preyHumanoid._props.Health == 100,
		string.format("%.0f health", preyHumanoid._props.Health))

	-- Now out of protection, standing on top of one.
	shielded.spawnProtectedUntil = 0
	shielded.burgerUntil = 0
	shielded.shield = 0
	local armed = VehicleService.SpawnTorpedo(Vector3.new(0, 5, 0))
	local before = preyHumanoid._props.Health
	VehicleService.Explode(armed)
	RUN_SPAWNED()
	local after = preyHumanoid._props.Health

	check("a wrecked vehicle damages somebody beside it", after < before,
		string.format("%.0f health, was %.0f", after, before))

	-- And not somebody on the other side of the map.
	preyHumanoid._props.Health = 100
	shielded.spawnProtectedUntil = 0
	shielded.burgerUntil = 0
	preyRoot._props.CFrame = CFrame.new(5000, 5, 5000)
	local faraway = VehicleService.SpawnTorpedo(Vector3.new(0, 5, 0))
	VehicleService.Explode(faraway)
	RUN_SPAWNED()
	check("and not somebody across the map", preyHumanoid._props.Health == 100,
		string.format("%.0f health", preyHumanoid._props.Health))
end

-- ------------------------------------------------------------- the rink
DUMP("")
DUMP("Hockey:")
do
	HockeyService.Build(1900)
	local thePuck = HockeyService.Puck()
	check("a puck is dropped", thePuck ~= nil, "")

	-- Shooting the puck IS playing hockey here, so a bullet has to move it.
	if thePuck then
		thePuck._props.AssemblyLinearVelocity = Vector3.new()
		local handled = HockeyService.RegisterHit(thePuck, killer, Vector3.new(0, 0, -1))
		check("a bullet moves the puck", handled
			and thePuck._props.AssemblyLinearVelocity.Magnitude > 50,
			string.format("%.0f studs/sec", thePuck._props.AssemblyLinearVelocity.Magnitude))
		check("and the shooter is credited for the touch",
			thePuck:GetAttribute("LastTouchUserId") == killer._props.UserId, "")
	end

	-- Fights. Two fighters with fight health, a punch and a guard. A clean
	-- punch bites, a punch into a raised guard barely stings, and dropping
	-- to zero knocks you down and sends you to the box.
	PlayerState.Reset(killer, false)
	PlayerState.Reset(prey, false)

	local settled = {}
	HockeyService.FightOver.Connect(function(winner, loser, brokeStick)
		table.insert(settled, { winner = winner, loser = loser, brokeStick = brokeStick })
	end)

	check("a fight starts between opponents", HockeyService.StartFight(killer, prey),
		string.format("%d running", HockeyService.FightCount()))
	check("and not twice over", HockeyService.StartFight(killer, prey) == false, "")

	-- A fight takes your legs, not your gun. That distinction is the whole
	-- rule of this map, so it is worth asserting both halves.
	local killerHum = killer._props.Character:FindFirstChildOfClass("Humanoid")
	local preyHum = prey._props.Character:FindFirstChildOfClass("Humanoid")
	check("a fight pins both fighters in place",
		killerHum._props.WalkSpeed == 0 and preyHum._props.WalkSpeed == 0,
		string.format("%.0f / %.0f walkspeed", killerHum._props.WalkSpeed, preyHum._props.WalkSpeed))
	check("but nobody is disarmed mid-fight",
		PlayerState.Get(killer).equipped ~= nil, tostring(PlayerState.Get(killer).equipped))

	check("both start on full fight health",
		HockeyService.FightHealthOf(killer) == Config.Hockey.FightHealth
			and HockeyService.FightHealthOf(prey) == Config.Hockey.FightHealth,
		string.format("%d / %d", HockeyService.FightHealthOf(killer) or -1,
			HockeyService.FightHealthOf(prey) or -1))

	-- One punch lands for real damage.
	ADVANCE(1)
	HockeyService.Punch(killer)
	local afterOne = HockeyService.FightHealthOf(prey) or -1
	check("a clean punch takes a real bite",
		afterOne <= Config.Hockey.FightHealth - Config.Hockey.PunchDamageMin
			and afterOne >= Config.Hockey.FightHealth - Config.Hockey.PunchDamageMax,
		string.format("%d health left", afterOne))

	-- Mashing gains nothing: the cooldown eats the second punch.
	HockeyService.Punch(killer)
	HockeyService.Punch(killer)
	check("mashing the punch key is rate limited",
		HockeyService.FightHealthOf(prey) == afterOne,
		string.format("%d health, still", HockeyService.FightHealthOf(prey) or -1))

	-- A raised guard turns the next one into a graze.
	HockeyService.Block(prey, true)
	check("the guard goes up", HockeyService.IsBlocking(prey), "")
	ADVANCE(Config.Hockey.PunchCooldown + 0.05)
	HockeyService.Punch(killer)
	check("a punch into a raised guard barely stings",
		HockeyService.FightHealthOf(prey) == afterOne - Config.Hockey.BlockedDamage,
		string.format("%d damage", afterOne - (HockeyService.FightHealthOf(prey) or 0)))

	-- Throwing a punch drops your own guard -- you cannot hide and hit.
	HockeyService.Block(prey, true)
	ADVANCE(Config.Hockey.PunchCooldown + 0.05)
	HockeyService.Punch(prey)
	check("throwing a punch drops your own guard",
		HockeyService.IsBlocking(prey) == false, "")

	check("the fight is still running", HockeyService.FightCount() == 1, "")

	-- Now punch him out. Worst case is PunchDamageMin a punch with the guard
	-- down, so this many swings always reaches zero.
	local swings = math.ceil(Config.Hockey.FightHealth / Config.Hockey.PunchDamageMin) + 2
	for _ = 1, swings do
		ADVANCE(Config.Hockey.PunchCooldown + 0.05)
		HockeyService.Punch(killer)
	end
	RUN_SPAWNED()

	check("running out of fight health ends it", #settled == 1,
		string.format("%d results", #settled))
	check("a knockout ends the fight without waiting for the clock",
		HockeyService.FightCount() == 0, string.format("%d running", HockeyService.FightCount()))
	if #settled == 1 then
		check("whoever landed more wins", settled[1].winner == killer,
			tostring(settled[1].winner and settled[1].winner._props.Name))
		check("the loser is knocked down, not killed",
			prey._props.Character:FindFirstChildOfClass("Humanoid")._props.Health > 0,
			string.format("%.0f health",
				prey._props.Character:FindFirstChildOfClass("Humanoid")._props.Health))
		check("the winner takes points", PlayerState.Get(killer).points > 0,
			string.format("%d points", PlayerState.Get(killer).points))
		check("and both get their legs back",
			killerHum._props.WalkSpeed > 0 and preyHum._props.WalkSpeed > 0,
			string.format("%.0f / %.0f walkspeed",
				killerHum._props.WalkSpeed, preyHum._props.WalkSpeed))
	end

	-- The loser serves time: after the knockdown they are put in the box,
	-- which is a real place on the map rather than a nil position.
	ADVANCE(Config.Hockey.KnockdownSeconds + 0.5)
	RUN_DELAYED()
	local preyRoot = prey._props.Character:FindFirstChild("HumanoidRootPart")
	local boxed = preyRoot and preyRoot._props.CFrame
	local box = HockeyService.PenaltyBox()
	check("the rink actually has a penalty box", box.Magnitude > 1,
		string.format("%.0f, %.0f, %.0f", box.X, box.Y, box.Z))
	check("the loser is sent to the penalty box",
		boxed ~= nil and (boxed.Position - box).Magnitude < 1,
		if boxed then string.format("at %.0f, %.0f, %.0f vs box %.0f, %.0f, %.0f",
			boxed.Position.X, boxed.Position.Y, boxed.Position.Z, box.X, box.Y, box.Z)
			else "no root")

	-- A fight with a team-mate is not a fight.
	prey._props.Team = killer._props.Team
	check("you cannot fight your own team", HockeyService.StartFight(killer, prey) == false, "")
end

-- --------------------------------------------------------- the sub-games
-- The whole point of these is discoverability: a 2000-stud map hides its own
-- contents, so there is a menu that takes you straight to a game, and a
-- prompt if you walk into one. And a venue is filled out with bots, because
-- an empty rink is worse than no rink.
DUMP("")
DUMP("Petrol and fire:")
do
	--[[
		The interesting part of a gas can is the SETUP, not the fire. A
		flamethrower is a gun that does damage in a cone; a can of petrol is
		a plan -- pour a trail across the doorway somebody keeps using, back
		off, wait. So these check the plan can actually be laid and then
		followed through, and that the fire travels rather than just
		existing.
	]]
	FireService.Build(1900)
	check("gas cans are out on the map", FireService.CanCount() > 0,
		string.format("%d cans", FireService.CanCount()))

	-- Pouring. The raycast needs ground under the player, and the harness
	-- stubs Raycast to find nothing, so give it something to find.
	local ground = { Position = Vector3.new(0, 0, 0), Instance = Instance.new("Part") }
	rawget(workspace, "_props").Raycast = function()
		return ground
	end

	-- The stubbed raycast reports the origin, so every puddle lands there.
	-- The killer's stand-in spawns 4950 studs away, which is a long way to
	-- throw a match: put them next to their own petrol.
	local killerRoot = killer._props.Character:FindFirstChild("HumanoidRootPart")
	killerRoot._props.CFrame = CFrame.new(0, 3, 0)

	FireService.GiveCan(killer)
	check("picking up a can fills it", FireService.FuelOf(killer) == Config.Fire.CanFuel,
		tostring(FireService.FuelOf(killer)))

	local poured = 0
	for _ = 1, 4 do
		ADVANCE(Config.Fire.PourInterval + 0.01)
		FireService.Pour(killer)
		poured += 1
	end
	check("pouring leaves puddles", FireService.PuddleCount() == poured,
		string.format("%d puddles from %d pours", FireService.PuddleCount(), poured))
	check("and costs fuel", (FireService.FuelOf(killer) or Config.Fire.CanFuel)
		< Config.Fire.CanFuel,
		string.format("%s left", tostring(FireService.FuelOf(killer))))

	-- Pouring is paced. Without the interval a held key would be sixty
	-- puddles a second, which is a different game and a dead server.
	local before = FireService.PuddleCount()
	FireService.Pour(killer)
	FireService.Pour(killer)
	check("pouring is rate limited", FireService.PuddleCount() == before,
		string.format("%d extra from two instant pours", FireService.PuddleCount() - before))

	-- Lighting it. The puddles are all at the stubbed raycast position, so
	-- they are within reach of each other and of the player.
	check("nothing is burning yet", FireService.BurningCount() == 0, "")
	FireService.Light(killer)
	check("lighting it sets the petrol alight", FireService.BurningCount() > 0,
		string.format("%d burning", FireService.BurningCount()))

	--[[
		Fire SPREADS, which is the thing that makes a trail a fuse.

		Without it a trail would have to be lit from inside itself, and the
		whole point is lighting it from somewhere safe and watching it
		travel towards somebody. The spread is a task.delay, so it needs
		the delayed queue flushed.
	]]
	RUN_DELAYED()
	check("and the fire spreads along the trail",
		FireService.BurningCount() == FireService.PuddleCount(),
		string.format("%d of %d puddles alight",
			FireService.BurningCount(), FireService.PuddleCount()))

	--[[
		Standing in it hurts, through DamageService so the kill is attributed.

		The hockey section above put prey on killer's team to prove you
		cannot fight a team-mate, and friendly fire is off -- so without
		putting them back on opposite sides the burn correctly does nothing
		and this reads as a broken fire rather than a working rule.
	]]
	prey._props.Team = Instance.new("Team")
	prey._props.Team._props.Name = "Blue"
	PlayerState.Get(prey).shield = 0
	local victimHumanoid = prey._props.Character:FindFirstChildOfClass("Humanoid")
	victimHumanoid._props.Health = 100
	rawget(workspace, "_props").GetPartBoundsInRadius = function()
		return { prey._props.Character:FindFirstChild("HumanoidRootPart") }
	end

	ADVANCE(Config.Fire.BurnInterval + 0.01)
	FireService.StepForTests()
	local burned = 100 - victimHumanoid._props.Health
	check("standing in fire burns you", burned > 0,
		string.format("%.0f damage", burned))

	--[[
		Once per character per tick, not once per part.

		A ragdoll has a dozen parts and all of them are inside the radius, so
		charging per-part would burn a player twelve times as fast as
		intended -- and twelve times as fast as the number in Config claims,
		which is the sort of mismatch nobody finds by playing.
	]]
	local root = prey._props.Character:FindFirstChild("HumanoidRootPart")
	rawget(workspace, "_props").GetPartBoundsInRadius = function()
		return { root, root, root, root, root, root }
	end
	victimHumanoid._props.Health = 100
	ADVANCE(Config.Fire.BurnInterval + 0.01)
	FireService.StepForTests()
	local once = 100 - victimHumanoid._props.Health
	-- Has to actually burn AND be capped. Asserting only the cap passes
	-- happily on zero damage, which is how this check sat green while the
	-- fire was doing nothing at all.
	check("and only once per tick however many limbs are in it",
		once > 0 and once <= Config.Fire.BurnDamage + 0.001,
		string.format("%.0f damage for 6 overlapping parts, cap %d",
			once, Config.Fire.BurnDamage))

	rawget(workspace, "_props").GetPartBoundsInRadius = function()
		return {}
	end

	--[[
		A can is a bomb anybody can set off, including whoever placed it.

		Asserted on the can RECORDS rather than on a count: a detonated can
		schedules its own respawn, and the delayed queue in this harness runs
		every pending callback regardless of its deadline -- so a count would
		show the can coming straight back and read as if nothing had
		happened.

		The cluster is what makes this testable at all. Cans used to be
		spread evenly on a ring 310 studs apart, so no two were ever within
		the 18-stud chain radius and this whole path was dead code.
	]]
	local target = FireService.CansForTests()[1]
	check("there is a can to shoot", target ~= nil, "")
	if target then
		-- Its cluster-mates: the ones close enough to go with it.
		local neighbours = {}
		for _, other in FireService.CansForTests() do
			if other ~= target and not other.gone then
				if (other.part.Position - target.part.Position).Magnitude
					<= Config.Fire.CanChainRadius
				then
					table.insert(neighbours, other)
				end
			end
		end
		check("a can has cluster-mates within chain range", #neighbours > 0,
			string.format("%d within %d studs", #neighbours, Config.Fire.CanChainRadius))

		local handled = FireService.RegisterHit(target.part, killer)
		check("shooting a gas can sets it off", handled and target.gone,
			string.format("handled=%s gone=%s", tostring(handled), tostring(target.gone)))

		-- Staggered, so a row reads as a chain rather than one bang -- and
		-- so the second one can catch somebody running from the first.
		local wentEarly = 0
		for _, other in neighbours do
			if other.gone then
				wentEarly += 1
			end
		end
		check("the neighbours do not go at the same instant", wentEarly == 0,
			string.format("%d went immediately", wentEarly))

		RUN_DELAYED()
		local chained = 0
		for _, other in neighbours do
			if other.gone then
				chained += 1
			end
		end
		-- Non-vacuous on purpose: "0 of 0 chained" is not a chain working,
		-- it is a chain that could never have happened.
		check("and it takes its cluster with it",
			#neighbours > 0 and chained == #neighbours,
			string.format("%d of %d chained", chained, #neighbours))
	end

	FireService.Clear()
	check("clearing takes the petrol with it",
		FireService.PuddleCount() == 0 and FireService.CanCount() == 0,
		string.format("%d puddles, %d cans",
			FireService.PuddleCount(), FireService.CanCount()))
end

DUMP("")
DUMP("Sub-games:")
do
	local menu = ArcadeService.Menu()
	check("the venues are registered", #menu >= 3,
		string.format("%d games: %s", #menu, (function()
			local names = {}
			for _, g in menu do table.insert(names, g.id) end
			return table.concat(names, ", ")
		end)()))

	local hasHockey = false
	for _, game in menu do
		if game.id == "hockey" then hasHockey = true end
	end
	check("hockey is one of them", hasHockey, "")

	-- Every game needs a one-line objective, because that line IS the
	-- instructions and a game nobody can work out is a game nobody plays.
	local silent = {}
	for _, game in menu do
		if type(game.objective) ~= "string" or #game.objective < 10 then
			table.insert(silent, game.id)
		end
	end
	check("every game says how to play it", #silent == 0, table.concat(silent, ", "))

	-- Joining puts you there and fills the teams out with bots.
	BotService.Clear(nil)
	local joined = ArcadeService.Join(killer, "hockey")
	check("you can join a game", joined, "")
	check("and you are taken to it", ArcadeService.VenueOf(killer) == "hockey",
		tostring(ArcadeService.VenueOf(killer)))

	local staff = BotService.InVenue("hockey")
	check("the teams are filled with CPU players", #staff > 0,
		string.format("%d bots", #staff))

	-- A real player takes a slot, so one fewer bot is needed on that side.
	local before = #BotService.InVenue("hockey")
	ArcadeService.Join(prey, "hockey")
	local after = #BotService.InVenue("hockey")
	check("a second player replaces a bot rather than adding to the game",
		after <= before, string.format("%d bots, was %d", after, before))

	-- And joining goes to the smaller side, so it never makes it lopsided.
	check("players are split across both sides",
		ArcadeService.SideOf(killer) ~= ArcadeService.SideOf(prey),
		string.format("%s vs %s", tostring(ArcadeService.SideOf(killer)),
			tostring(ArcadeService.SideOf(prey))))

	-- Bots are shootable, like everything else here.
	local target = BotService.InVenue("hockey")[1]
	if target then
		local head = target.model:FindFirstChild("Head")
		local handled = BotService.RegisterHit(head, 1000, killer)
		check("a bot can be shot", handled and target.dead, tostring(target.dead))
	end

	ArcadeService.Leave(killer)
	check("and you can leave", ArcadeService.VenueOf(killer) == nil, "")

	--[[
		Light pillars over every activity.

		A menu solves discoverability for a player who thinks to open a
		menu. A pillar of light solves it for everyone else, including at
		speed from the far side of the map -- which is the case that
		actually matters, because the map is 2000 studs across and you
		cannot see any of its contents from where you spawn.
	]]
	ArcadeService.BuildBeacons()
	check("every activity gets a beacon",
		ArcadeService.BeaconCount() == #ArcadeService.Menu(),
		string.format("%d beacons for %d activities",
			ArcadeService.BeaconCount(), #ArcadeService.Menu()))

	local holder = workspace:FindFirstChild("ActivityBeacons")
	check("the beacons are in the world", holder ~= nil, "")

	if holder then
		local pillars = holder:GetChildren()
		local solid, opaque, short, unnamed = {}, {}, {}, {}
		local colours = {}
		for _, pillar in pillars do
			local props = pillar._props
			-- A solid pillar through the middle of a rink is a wall in the
			-- way of the game it is advertising.
			if props.CanCollide ~= false then
				table.insert(solid, props.Name)
			end
			-- And one a bullet stops dead against is worse: every shot
			-- fired through it would die in mid-air on scenery.
			if props.CanQuery ~= false then
				table.insert(opaque, props.Name)
			end
			-- Tall enough to clear the towers, or it is not visible from
			-- anywhere useful and there was no point building it.
			if props.Size.Y < 200 then
				table.insert(short, props.Name)
			end
			if not pillar:FindFirstChild("BeaconName") then
				table.insert(unnamed, props.Name)
			end
			local c = props.Color
			if c then
				local key = string.format("%.2f,%.2f,%.2f", c.R, c.G, c.B)
				colours[key] = (colours[key] or 0) + 1
			end
		end

		check("no beacon blocks the game it advertises", #solid == 0,
			table.concat(solid, ", "))
		check("and none of them stops a bullet", #opaque == 0,
			table.concat(opaque, ", "))
		check("each one is tall enough to see from across the map", #short == 0,
			table.concat(short, ", "))
		check("each one says what it is", #unnamed == 0, table.concat(unnamed, ", "))

		-- Colour-coded, not six identical lights. A colour you cannot tell
		-- apart from the next one carries no information.
		local distinct = 0
		for _ in colours do
			distinct += 1
		end
		check("the beacons are told apart by colour", distinct == #pillars,
			string.format("%d colours for %d beacons", distinct, #pillars))
	end
end

DUMP(if failures == 0 then "MEDALS WORK" else failures .. " MEDAL FAILURES")
'''

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'src')
BLOCK_DATASTORE = '--block-datastore' in sys.argv

def read(*p): return open(os.path.join(*p)).read()

def strip(s):
    out = []
    for line in s.split('\n'):
        if re.match(r'^local \w+ = game:GetService\(', line): continue
        if re.match(r'^local Shared = ', line): continue
        if re.match(r'^local \w+ = require\(', line): continue
        out.append(line)
    return '\n'.join(out)

SHARED = ['Config', 'Signal', 'Util', 'Remotes', 'Sound', 'Shot']
SERVER = ['PlayerState', 'TeamService', 'BotService', 'ArcadeService', 'ResortService', 'HockeyService', 'MapService', 'VehicleService', 'DamageService', 'WildlifeService',
          'CarnivalService', 'FireService', 'ProjectileService', 'WeaponService', 'PickupService',
          'EffectService', 'FlagService', 'MonetizationService', 'ScoreboardService', 'MatchService',
          'GraphicsService']

parts = [read(HERE, 'stubs.luau'), read(HERE, 'serverstubs.luau')]
parts.append(f'DATASTORE_THROWS = {"true" if BLOCK_DATASTORE else "false"}\n')
parts.append('''
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local CollectionService = game:GetService("CollectionService")
''')

for n in SHARED:
    parts.append(f'local {n} = (function()\n{strip(read(SRC, "shared", n + ".luau"))}\nend)()\n')
for n in SERVER:
    parts.append(f'local {n} = (function()\n{strip(read(SRC, "server", "modules", n + ".luau"))}\nend)()\n')

registry = ', '.join(f'{n} = {n}' for n in SHARED + SERVER)
parts.append(f'''
-- A stand-in module tree, so init.server.luau can run completely unmodified:
-- its own WaitForChild / FindFirstChild / require calls all resolve here.
local REGISTRY = {{ {registry} }}

local function container(names)
	local box = {{}}
	local children = {{}}
	for _, n in names do children[n] = {{ __module = n }} end
	box.FindFirstChild = function(_, n) return children[n] end
	box.WaitForChild = function(_, n) return children[n] end
	return setmetatable(box, {{ __index = function(_, k) return rawget(box, k) end }})
end

local sharedBox = container({{ {', '.join(f'"{n}"' for n in SHARED)} }})
local modulesBox = container({{ {', '.join(f'"{n}"' for n in SERVER)} }})

script = {{ WaitForChild = function(_, n) if n == "modules" then return modulesBox end end }}

require = function(token)
	if type(token) == "table" and token.__module then
		local m = REGISTRY[token.__module]
		if m == nil then error("no such module: " .. token.__module, 0) end
		return m
	end
	error("unexpected require", 0)
end

local rsMeta = rawget(ReplicatedStorage, "_props")
rsMeta.WaitForChild = function(_, n) if n == "Shared" then return sharedBox end end
rsMeta.FindFirstChild = function(_, n) if n == "Shared" then return sharedBox end end

-- ------------------------------------------- the real bootstrap, verbatim
local bootOk, bootErr = pcall(function()
{read(SRC, 'server', 'init.server.luau')}
end)

DUMP("boot completed:", bootOk, bootOk and "" or tostring(bootErr))
--[[MEDALS]]
local arena = workspace:FindFirstChild("Arena")
local fallback = workspace:FindFirstChild("FallbackGround")
DUMP("ARENA:", arena ~= nil, arena and (#arena:GetDescendants() .. " parts") or "-")
DUMP("FALLBACK GROUND:", fallback ~= nil)
for _, w in WARNINGS do DUMP("  warn:", w) end

--[[
	A subsystem that failed to start is a FAILURE, not a note.

	The bootstrap wraps each service in a pcall on purpose, so one broken
	module cannot stop the rest of the game coming up. That is right for
	players and wrong for a test: this harness used to print the warning and
	exit 0, so MatchService failing to start -- which is precisely the
	original "player falls through an empty blue sky" bug -- read as a pass.
]]
local started = true
for _, w in WARNINGS do
	if string.find(tostring(w), "failed to start", 1, true)
		or string.find(tostring(w), "could not be loaded", 1, true)
	then
		DUMP("SUBSYSTEM DID NOT START:", w)
		started = false
	end
end

if not arena then
	DUMP("NO ARENA WAS BUILT")
	started = false
end

DUMP(if started then "SERVER CAME UP CLEAN" else "SERVER DID NOT COME UP")

--[[
	Exit non-zero on failure.

	Without this the suite only PRINTED its failures and exited 0, so
	run-all.sh reported success no matter what broke, and any automation
	trusting its exit code was being told a comforting lie. error() at the
	top level is what makes the luau CLI exit non-zero.
]]
if not started or failures > 0 then
	error("server did not come up clean", 0)
end
for _, p in PRINTS do DUMP("  print:", p) end
''')

sys.stdout.write('\n'.join(parts).replace('--[[MEDALS]]', MEDAL_TEST))
