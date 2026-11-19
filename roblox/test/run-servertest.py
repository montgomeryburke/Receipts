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
	-- A real character always has one, and the held-weapon model welds to
	-- it, so without a hand nothing could ever be seen in anybody's hands.
	local hand = Instance.new("Part")
	hand._props.Name = "Right Arm"
	hand._props.CFrame = CFrame.new(1, 5, 0)
	hand.Parent = character
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
PlayerState.AwardPoints(killer, 250, "Rifle")
PlayerState.AwardPoints(prey, 90, "balloon pop")

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

--[[
	One award path, and it decides the ROUND.

	Every activity already called AwardPoints for its personal points, but
	the team score -- the thing that actually ends a round -- was moved by
	four signals MatchService happened to be wired to: kills, flag captures,
	hockey goals and tricks. So a carnival stall, a bot kill, a won hockey
	fight and a flag grab gave you points that could not win the round, and
	nothing about playing would tell you: the number on your own scoreboard
	went up exactly as it should.

	These check the inversion: scoring anything at all reaches the team, and
	it reaches it exactly once.
]]
do
	local told = {}
	PlayerState.Scored.Connect(function(who, earned, reason)
		table.insert(told, { who = who, earned = earned, reason = reason })
	end)

	PlayerState.AwardPoints(killer, 40, "whack-a-mole")
	RUN_SPAWNED()
	check("scoring anything announces itself", #told == 1,
		string.format("%d announcements", #told))
	if #told == 1 then
		check("with the reason it was scored for", told[1].reason == "whack-a-mole",
			tostring(told[1].reason))
		check("and the amount actually awarded", told[1].earned == 40,
			tostring(told[1].earned))
	end

	-- A zero award is not an event. Firing one would put "+0" on screen and
	-- redraw the scoreboard for nothing.
	told = {}
	PlayerState.AwardPoints(killer, 0, "nothing")
	RUN_SPAWNED()
	check("scoring nothing announces nothing", #told == 0,
		string.format("%d announcements", #told))
end

--[[
	THE CLAIM: a carnival stall can win a round.

	This is the whole point of unifying the scoring, and it is the one thing
	that could not be checked before -- the team total was moved by four
	hand-wired signals, so anything not on that list added to your personal
	score and nothing else. Reading MatchService and noticing the absence
	was the only way to find it.
]]
do
	MatchService.ForceRoundForTests()
	local before = MatchService.ScoresForTests()
	local mine = TeamService.IndexOf(killer)

	-- Something with no signal of its own, scored through the one path.
	PlayerState.AwardPoints(killer, 120, "milk bottles")
	RUN_SPAWNED()

	local after = MatchService.ScoresForTests()
	check("winning a fairground stall moves the team score",
		after[mine] == before[mine] + 120,
		string.format("%d -> %d", before[mine], after[mine]))

	local other = if mine == 1 then 2 else 1
	check("and only that team's score", after[other] == before[other],
		string.format("%d -> %d", before[other], after[other]))

	--[[
		Exactly once.

		A hockey goal both awards the scorer AND fires its own Goal signal.
		With the team sum in both places a goal counted twice for the round
		and once for the player, which is the kind of thing that looks like
		a scoring bug nobody can reproduce.
	]]
	local goalBefore = MatchService.ScoresForTests()
	local points = Config.Hockey.GoalPoints
	PlayerState.AwardPoints(killer, points, "hockey goal")
	HockeyService.Goal.Fire(killer, mine, points)
	RUN_SPAWNED()
	local goalAfter = MatchService.ScoresForTests()
	check("a hockey goal counts once, not twice",
		goalAfter[mine] == goalBefore[mine] + points,
		string.format("%d -> %d for a %d point goal",
			goalBefore[mine], goalAfter[mine], points))

	--[[
		A goal nobody can be credited for still counts.

		With no scorer -- a deflection off a car, a puck that drifted in --
		there is nobody to award, so it has to be credited to the team
		directly or it is simply not a goal.
	]]
	local ownBefore = MatchService.ScoresForTests()
	HockeyService.Goal.Fire(nil, mine, points)
	RUN_SPAWNED()
	local ownAfter = MatchService.ScoresForTests()
	check("a goal with no scorer still counts for the team",
		ownAfter[mine] == ownBefore[mine] + points,
		string.format("%d -> %d", ownBefore[mine], ownAfter[mine]))

	--[[
		Nothing scores between rounds.

		Mattering because the scoreboard is pushed to everybody at the
		whistle and stays up through the intermission: a stall still being
		shot at while the final standings are on screen must not change
		them under everyone.
	]]
	MatchService.SetPhaseForTests("Intermission")
	local idleBefore = MatchService.ScoresForTests()
	PlayerState.AwardPoints(killer, 999, "after the whistle")
	RUN_SPAWNED()
	check("scoring between rounds does not count",
		MatchService.ScoresForTests()[mine] == idleBefore[mine],
		string.format("%d -> %d", idleBefore[mine], MatchService.ScoresForTests()[mine]))
	MatchService.SetPhaseForTests("Playing")
end

--[[
	The MVP, and what they did it at.

	Nobody is MVP on zero: at the start of a round that would crown whoever
	happens to sort first, which is worse than crowning nobody.
]]
do
	local name, points, at = ScoreboardService.Mvp()
	check("the top scorer is the MVP", name == killer._props.DisplayName,
		string.format("%s with %d", tostring(name), points))
	check("and it says what they did it at", at ~= nil, tostring(at))

	-- The marker is on exactly one row, and it is that one -- read from the
	-- same Build the panel uses, so the shout and the row cannot disagree.
	local rows = ScoreboardService.Build(killer)
	local marked, markedName = 0, nil
	for _, row in rows do
		if row.isMvp then
			marked += 1
			markedName = row.name
		end
	end
	check("exactly one row carries the marker", marked == 1,
		string.format("%d marked", marked))
	check("and it is the same player the shout names", markedName == name,
		string.format("%s vs %s", tostring(markedName), tostring(name)))

	-- What somebody scored most of their points doing. prey only ever
	-- scored at the balloons here.
	check("the panel knows what each player scored at",
		ScoreboardService.BestAt(prey) == "balloon pop",
		tostring(ScoreboardService.BestAt(prey)))
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

DUMP("")
DUMP("You hold the gun you are holding:")
do
	--[[
		THE CLAIM: picking a gun up does not change what is in your hands.

		It did not. `state.equipped` is written in three places -- the equip
		key, picking a weapon off the floor, and winning a hockey fight with
		a stick that breaks -- and only the equip key rebuilt the hand model.
		So a rocket launcher off the floor left you visibly holding a pistol
		that fired rockets, and the line above the pickup code says "puts it
		straight in your hands" while doing nothing of the kind.

		Fixed by driving the model off PlayerState.Changed, which all three
		writers already fire, so a fourth writer cannot forget. The test is
		written against the STATE rather than against any one writer, for
		the same reason.
	]]
	WeaponService.Start()

	local state = PlayerState.Get(killer)
	state.equipped = "Pistol"
	WeaponService.UpdateHeldWeapon(killer)
	check("you start out holding something",
		WeaponService.HeldWeaponOf(killer) == "Pistol",
		tostring(WeaponService.HeldWeaponOf(killer)))

	local shownBefore = WeaponService.HeldWeaponOf(killer)

	-- What a pickup does: set the field and announce the change.
	state.equipped = "RPG"
	PlayerState.Changed.Fire(killer)
	RUN_SPAWNED()

	check("picking a gun up changes what you are holding",
		WeaponService.HeldWeaponOf(killer) == "RPG",
		string.format("%s, was %s",
			tostring(WeaponService.HeldWeaponOf(killer)), tostring(shownBefore)))

	-- And the model in the world agrees, not just the bookkeeping.
	local held = killer._props.Character:FindFirstChild("HeldWeapon")
	local barrel = held and held:FindFirstChild("Barrel")
	check("and there is a gun in the world to show it",
		barrel ~= nil and barrel._props.Color == Config.Weapons.RPG.Color,
		if barrel then "coloured as the RPG" else "no barrel")

	--[[
		Only when it actually changes.

		Changed fires for shields, ammo, points and the multiplier, many
		times a second for twenty players. Rebuilding the model on each of
		those would mean destroying and welding four parts per player per
		frame, so the whole fix rests on the compare.
	]]
	local rebuilt = killer._props.Character:FindFirstChild("HeldWeapon")
	for _ = 1, 20 do
		PlayerState.Changed.Fire(killer)
		RUN_SPAWNED()
	end
	check("and not on every other thing that changes",
		killer._props.Character:FindFirstChild("HeldWeapon") == rebuilt,
		"same model kept")

	-- Put the pistol back so nothing downstream inherits a rocket launcher.
	state.equipped = "Pistol"
	PlayerState.Changed.Fire(killer)
	RUN_SPAWNED()
end

DUMP("")
DUMP("Poop is a renewable resource:")
do
	--[[
		THE CLAIM: the one ammunition you cannot buy keeps coming.

		Elephant poop is marked AmmoFromPickupsOnly, so the piles lying
		about the map ARE the ammunition. Twelve were seeded at the start of
		the round and nothing ever made another, which meant the weapon died
		for the rest of the match the moment the last pile was walked over.

		Config had PoopInterval and PoopLifetime from the beginning and
		nothing in the game read either of them -- the quietest sort of bug
		there is, because a setting that does nothing looks exactly like a
		setting that works.
	]]
	local seeded = WildlifeService.PoopCount()
	check("the map starts with poop on it", seeded > 0,
		string.format("%d piles", seeded))

	-- Walk over the lot of them.
	for _ = 1, seeded do
		local pile = WildlifeService.NearestPoopForTests(Vector3.new(0, 0, 0))
		if pile then
			pile:Destroy()
		end
		RunService.Heartbeat._fire(1 / 60)
	end
	check("and they can all be taken", WildlifeService.PoopCount() == 0,
		string.format("%d left", WildlifeService.PoopCount()))

	-- Wait out one interval.
	ADVANCE(Config.Wildlife.PoopInterval + 0.1)
	RunService.Heartbeat._fire(1 / 60)
	check("more arrives on its own", WildlifeService.PoopCount() > 0,
		string.format("%d piles", WildlifeService.PoopCount()))

	--[[
		And it goes stale.

		Without this the map fills to MaxPoopPiles and stays there, which is
		forty brown spheres standing in the mud for the rest of the round.
	]]
	local fresh = WildlifeService.NearestPoopForTests(Vector3.new(0, 0, 0))
	ADVANCE(Config.Wildlife.PoopLifetime + 1)
	RunService.Heartbeat._fire(1 / 60)
	check("and an old pile rots away", fresh ~= nil and fresh._props.Parent == nil,
		if fresh then tostring(fresh._props.Parent ~= nil) else "none")

	--[[
		It lands on the ground, not at a guessed height.

		Piles were placed at a flat y = 4 wherever the dice fell, which is
		the ground only where the ground is at zero. On a road embankment or
		a building floor the pile was buried, and a pickup you cannot see is
		indistinguishable from a pickup that does not work.
	]]
	ADVANCE(Config.Wildlife.PoopInterval + 0.1)
	RunService.Heartbeat._fire(1 / 60)
	local placed = WildlifeService.NearestPoopForTests(Vector3.new(0, 0, 0))
	check("a pile sits on whatever is under it",
		placed ~= nil and placed._props.CFrame.Position.Y > -60,
		if placed then string.format("y=%.1f", placed._props.CFrame.Position.Y) else "none")
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
DUMP("Nothing stalls when you are alone:")
do
	--[[
		Standing in an empty venue on your own.

		Joining a game already fills it out with bots. The gap was walking in
		WITHOUT joining, which is what people actually do -- a rink looks
		like a place you can just skate onto. You would stand on an empty
		sheet of ice with a prompt in the corner and nothing happening, which
		reads as a broken game rather than an unaccepted invitation.
	]]
	--[[
		Deliberately NOT ArcadeService.Clear() here.

		Clearing wipes the venue REGISTRY, not just the bots -- so doing it
		mid-suite left every later test seeing two activities instead of
		four, and the failure surfaced three sections away from its cause.
		The rink is already registered by this point; only the bots need
		clearing.
	]]
	BotService.Clear(nil)
	for _, player in { killer, prey } do
		ArcadeService.Leave(player)
	end

	-- Put the player on the rink, not in the game.
	local rinkCentre = ArcadeService.CentreOf("hockey")
	check("the rink knows where it is", rinkCentre ~= nil, tostring(rinkCentre))
	local root = killer._props.Character:FindFirstChild("HumanoidRootPart")
	root._props.CFrame = CFrame.new(rinkCentre or Vector3.new())
	killer._props.Character:FindFirstChildOfClass("Humanoid")._props.Health = 100

	check("walking in is not joining", ArcadeService.VenueOf(killer) == nil, "")

	-- One sweep: too soon to fill. The wait exists so that crossing a
	-- corner of the rink on the way somewhere does not summon a team.
	ArcadeService.SweepForTests()
	check("it does not fill the instant you arrive",
		#BotService.AllForTests() == 0,
		string.format("%d bots", #BotService.AllForTests()))

	-- Still alone a few seconds later: now it fills itself.
	ADVANCE(Config.Arcade.SoloFillSeconds + 1)
	ArcadeService.SweepForTests()
	check("standing there alone fills the game out",
		#BotService.AllForTests() > 0,
		string.format("%d bots after %d seconds",
			#BotService.AllForTests(), Config.Arcade.SoloFillSeconds))

	-- And it still did not drag them into a team they did not ask for.
	check("without joining them to anything",
		ArcadeService.VenueOf(killer) == nil,
		tostring(ArcadeService.VenueOf(killer)))

	--[[
		Something to test the toys on.

		A 50x scope, a gas trail and a land mine all need a target, and
		testing them on the only other player in the server is how you lose
		the only other player in the server.
	]]
	BotService.Clear(nil)
	CarnivalService.Build(1900)
	local dummies = 0
	for _, bot in BotService.AllForTests() do
		if bot.role == "dummy" then
			dummies += 1
		end
	end
	check("there are targets by the shooting gallery", dummies > 0,
		string.format("%d dummies", dummies))

	-- They WANDER. A stationary target teaches you nothing about leading a
	-- shot, which is the one skill a long scope asks for.
	local wanderer = nil
	for _, bot in BotService.AllForTests() do
		if bot.role == "dummy" then
			wanderer = bot
			break
		end
	end
	if wanderer then
		local first = wanderer.goal
		ADVANCE(Config.Dummies.WanderSeconds + 0.1)
		BotService.StepForTests()
		local second = wanderer.goal
		check("and they move about rather than standing still",
			second ~= nil and (first == nil or (second - first).Magnitude > 0.01),
			if second then string.format("%.0f, %.0f", second.X, second.Z) else "no goal")

		check("staying near their post",
			second ~= nil and (second - wanderer.home).Magnitude
				<= Config.Dummies.Radius + 0.5,
			if second then string.format("%.0f studs from post",
				(second - wanderer.home).Magnitude) else "none")

		-- Nobody's side, so friendly fire never refuses a shot at one.
		check("a dummy is on nobody's team", wanderer.team == 0,
			tostring(wanderer.team))
	end
end

DUMP("")
DUMP("The high striker is a test of strength:")
do
	--[[
		THE CLAIM: the puck goes as far up the tower as the shot deserves.

		It did not. Every hit on the pad sent the puck the full 56 studs,
		rang the bell and paid the same 35 points, whatever you shot it
		with -- so the high striker was a button labelled DING, and the
		strongest weapon in the game was worth exactly as much at it as the
		weakest. Nothing in the code looked wrong, because nothing in the
		code looked at the gun.

		Shot power now decides the throw, which means the test can shoot the
		same pad twice and compare.
	]]
	local pad = nil
	for _, thing in workspace:GetDescendants() do
		if thing._props.Name == "StrikerPad" then
			pad = thing
			break
		end
	end
	check("the fairground has a high striker", pad ~= nil)

	if pad then
		local smg = Config.Weapons.SMG
		local atRifle = Config.Weapons.AntiMaterial
		check("and two guns far enough apart to tell apart",
			smg ~= nil and atRifle ~= nil
				and Config.ShotPower(atRifle) > Config.ShotPower(smg) * 3,
			string.format("%d vs %d",
				Config.ShotPower(smg or {}), Config.ShotPower(atRifle or {})))

		-- A popgun.
		ADVANCE(Config.Carnival.StrikerCooldown + 0.1)
		CarnivalService.RegisterHit(pad, killer, nil, Config.ShotPower(smg))
		local weak = CarnivalService.StrikerPeakForTests()

		-- The heaviest rifle in the game.
		ADVANCE(Config.Carnival.StrikerCooldown + 0.1)
		CarnivalService.RegisterHit(pad, killer, nil, Config.ShotPower(atRifle))
		local strong = CarnivalService.StrikerPeakForTests()

		check("a submachine gun barely lifts the puck", weak < 0.4,
			string.format("%.0f%% of the tower", weak * 100))
		check("the anti-material rifle rings the bell", strong >= 1,
			string.format("%.0f%% of the tower", strong * 100))
		check("so the tower actually reads the gun", strong > weak * 2,
			string.format("%.2f vs %.2f", strong, weak))

		--[[
			A rocket is not a feeble shot.

			Every explosive in the game has Damage = 0 -- all of its damage
			is the blast -- so scoring a hit by Damage alone would have made
			the loudest weapon in the game the weakest thing you could hit a
			high striker with. Config.ShotPower exists for exactly this.
		]]
		local rocket = Config.Weapons.RPG
		if rocket then
			check("and a rocket counts as a rocket",
				Config.ShotPower(rocket) > Config.ShotPower(smg),
				string.format("power %d, raw damage %d",
					Config.ShotPower(rocket), rocket.Damage))
		end

		--[[
			The puck comes back down.

			It is driven ballistically off a launch time, so a throw that
			never cleared itself would leave the puck parked in mid-air
			against the bell for the rest of the round.
		]]
		ADVANCE(4)
		RunService.Heartbeat._fire(1 / 60)
		local puck = nil
		for _, thing in workspace:GetDescendants() do
			if thing._props.Name == "StrikerPuck" then
				puck = thing
				break
			end
		end
		check("and it settles back on the pad afterwards",
			puck ~= nil and puck._props.CFrame.Position.Y < 20,
			if puck then string.format("y=%.1f", puck._props.CFrame.Position.Y) else "no puck")
	end
end

DUMP("")
DUMP("The hill as a race:")
do
	--[[
		Always open, always timed.

		The pasted ski battle built a formal 1v1 with a queue, a countdown
		and a lockout. That is the same mistake bowling's ten frames would
		have been: an activity that takes you out of the round is the one
		thing nothing here is allowed to be, and a queue for two means
		standing about on a mountain. So the run is always open -- cross the
		line and you score, and first down since the line went quiet gets
		the bonus. Nothing to join, nothing to wait for.
	]]
	local gate
	for _, thing in workspace:GetDescendants() do
		if thing._props.Name == "SkiFinish" then
			gate = thing
			break
		end
	end
	check("there is a line at the bottom of the run", gate ~= nil, "")

	if gate then
		-- You must be able to ski THROUGH it. A solid gate at the bottom of
		-- a long run would be the most annoying object on the map.
		check("it is something you ski through, not into",
			gate._props.CanCollide == false, tostring(gate._props.CanCollide))

		local root = killer._props.Character:FindFirstChild("HumanoidRootPart")
		killer._props.Character:FindFirstChildOfClass("Humanoid")._props.Health = 100

		local function skiDown(seconds)
			-- Start high on the hill.
			root._props.CFrame =
				CFrame.new(gate.Position + Vector3.new(0, Config.SkiRace.MinimumHeightDrop + 40, 0))
			ResortService.StepRaceForTests()
			-- Then cross the line.
			ADVANCE(seconds)
			root._props.CFrame = CFrame.new(gate.Position)
			local before = PlayerState.Get(killer).points
			ResortService.StepRaceForTests()
			RUN_SPAWNED()
			return PlayerState.Get(killer).points - before
		end

		--[[
			Sliding over the line from a standing start is not a run.

			Without a minimum time, the bottom of the piste is a points
			button you can stand next to.
		]]
		local instant = skiDown(0.1)
		check("sliding over the line is not a run", instant == 0,
			string.format("%d points", instant))

		-- A real descent scores, and the first one gets the bonus.
		local first = skiDown(Config.SkiRace.MinimumRunSeconds + 2)
		check("a real run down scores", first > 0, string.format("%d points", first))
		check("and the first one down gets the bonus",
			first >= Config.SkiRace.FinishPoints + Config.SkiRace.FirstDownBonus,
			string.format("%d points, bonus is %d",
				first, Config.SkiRace.FirstDownBonus))

		--[[
			The next one down shortly after is second, not first.

			The bonus is for beating whoever is on the hill WITH you -- not
			for being the only person who has skied all round.
		]]
		local second = skiDown(Config.SkiRace.MinimumRunSeconds + 1)
		check("the next one down is not also first", second < first,
			string.format("%d vs %d points", second, first))
		check("but still scores for the run", second > 0,
			string.format("%d points", second))

		-- Once the line has been quiet long enough, it is first again.
		ADVANCE(Config.SkiRace.FirstDownSeconds + 1)
		local later = skiDown(Config.SkiRace.MinimumRunSeconds + 1)
		check("and first is up for grabs again later", later == first,
			string.format("%d vs %d points", later, first))
	end
end

DUMP("")
DUMP("Zombies stay on the ground:")
do
	--[[
		A zombie must walk ROUND a building, not up it.

		These have no Humanoid and no collision, so they are moved by hand
		and snapped to whatever a downward ray finds. The ray used to start
		six studs above their feet and take the first hit, which meant any
		ledge above their ankles pulled them onto it -- a kerb, a roof lip,
		the underside of a skybridge. Walking past a building put a zombie
		on the roof, and from up there it chased you across the rooftops.
	]]
	local preyRoot = prey._props.Character:FindFirstChild("HumanoidRootPart")
	preyRoot._props.CFrame = CFrame.new(0, 5, 0)
	prey._props.Character:FindFirstChildOfClass("Humanoid")._props.Health = 100
	local killerRoot = killer._props.Character:FindFirstChild("HumanoidRootPart")
	killerRoot._props.CFrame = CFrame.new(4000, 5, 4000)

	local zombie = WildlifeService.NearestZombieForTests(Vector3.new(0, 5, 0))
	check("there is a zombie to test", zombie ~= nil, "")

	if zombie then
		--[[
			A wall between the zombie and its target.

			The stand-in raycast reports a surface 40 studs up for anything
			it is asked about, which is what a roof looks like to the ground
			probe: far above the feet, and the first thing a ray from
			overhead would hit.
		]]
		local roof = Instance.new("Part")
		roof._props.Name = "RoofLip"
		local saved = rawget(workspace, "_props").Raycast
		rawget(workspace, "_props").Raycast = function()
			return {
				Instance = roof,
				Position = Vector3.new(0, 40, 0),
				Material = Enum.Material.Concrete,
				Normal = Vector3.new(0, 1, 0),
			}
		end

		local startedAt = zombie.position.Y
		for _ = 1, 120 do
			ADVANCE(1 / 60)
			RunService.Heartbeat._fire(1 / 60)
		end
		local climbed = zombie.position.Y - startedAt

		rawget(workspace, "_props").Raycast = saved

		check("a wall does not lift a zombie onto it",
			climbed <= Config.Population.StepHeight + 0.001,
			string.format("climbed %.1f studs, step height is %d",
				climbed, Config.Population.StepHeight))

		--[[
			But a kerb still works.

			The fix must not turn them into things that cannot step up at
			all, or they would stop at the first pavement and the streets
			would be lined with stuck zombies.
		]]
		local kerb = Instance.new("Part")
		kerb._props.Name = "Street"
		rawget(workspace, "_props").Raycast = function(_, origin)
			return {
				Instance = kerb,
				-- Two studs up: a kerb, not a wall.
				Position = Vector3.new(origin.X, zombie.position.Y + 2, origin.Z),
				Material = Enum.Material.Concrete,
				Normal = Vector3.new(0, 1, 0),
			}
		end

		local beforeKerb = zombie.position.Y
		for _ = 1, 60 do
			ADVANCE(1 / 60)
			RunService.Heartbeat._fire(1 / 60)
		end
		check("but a kerb can still be stepped up", zombie.position.Y > beforeKerb,
			string.format("%.1f -> %.1f", beforeKerb, zombie.position.Y))

		rawget(workspace, "_props").Raycast = saved
	end
end

DUMP("")
DUMP("Cluster bombs:")
do
	--[[
		A cluster bomb that does not cluster is a worse grenade with a
		longer reload.

		The config has said Cluster = 8 since it was written and the code to
		honour it exists, so this is checking the two are actually connected
		-- which is exactly the kind of thing that can be true in config,
		true in code, and false in the game.
	]]
	ProjectileService.ClearAll()
	local spec = Config.Weapons.ClusterBomb
	check("the cluster bomb is set to burst", (spec :: any).Cluster > 0,
		string.format("%d bomblets", (spec :: any).Cluster))

	local root = killer._props.Character:FindFirstChild("HumanoidRootPart")
	root._props.CFrame = CFrame.new(0, 10, 0)
	killer._props.Character:FindFirstChildOfClass("Humanoid")._props.Health = 100

	ProjectileService.Spawn(killer, "ClusterBomb", Vector3.new(0, 10, 0), Vector3.new(0, 0, -1))
	check("the bomb is in the air", ProjectileService.LiveCount() == 1,
		string.format("%d live", ProjectileService.LiveCount()))

	--[[
		Wait out the fuse.

		The bomb has to actually go off for the bomblets to exist, so the
		clock moves past FuseTime and the step runs -- rather than reaching
		in and calling detonate, which would prove the function works and
		not that anything calls it.
	]]
	for _ = 1, 200 do
		ADVANCE(1 / 60)
		RunService.Heartbeat._fire(1 / 60)
		if ProjectileService.LiveCount() > 1 then
			break
		end
	end

	check("it bursts into bomblets", ProjectileService.LiveCount() > 1,
		string.format("%d live after the fuse", ProjectileService.LiveCount()))
	check("one for each the config asks for",
		ProjectileService.LiveCount() >= (spec :: any).Cluster,
		string.format("%d of %d", ProjectileService.LiveCount(), (spec :: any).Cluster))

	--[[
		And the bomblets must not themselves burst.

		Cluster was cleared on the sub-spec for a reason: without it each
		bomblet spawns eight more, every one of those spawns eight more, and
		one grenade ends the server.
	]]
	local peak = ProjectileService.LiveCount()
	for _ = 1, 400 do
		ADVANCE(1 / 60)
		RunService.Heartbeat._fire(1 / 60)
	end
	check("the bomblets do not cluster again",
		ProjectileService.LiveCount() < peak,
		string.format("%d live, peaked at %d", ProjectileService.LiveCount(), peak))

	ProjectileService.ClearAll()
end

DUMP("")
DUMP("The cheap shot:")
do
	--[[
		Kicking somebody who has just gone down.

		Entirely cosmetic and entirely the point: no damage, no advantage,
		it exists because standing over somebody you just dropped and giving
		them a shove is a thing people do, and because it is funny. On the
		MELEE key rather than its own, because there is no situation where
		you would rather swing at a corpse than kick it.
	]]
	MatchService.SetPhaseForTests("Playing")
	PlayerState.Reset(killer, false)
	PlayerState.Reset(prey, false)

	--[[
		Stating this block's own preconditions.

		Two earlier sections leave state behind that silently breaks a melee
		swing: the hockey section puts prey on killer's team to prove you
		cannot fight a team-mate, and friendly fire is off -- and another
		stubs workspace:Raycast to return a hit, which the swing reads as a
		wall between them. Both are correct game behaviour, so the fix is
		for this block to say what it needs rather than to inherit whatever
		the last one wanted.
	]]
	local redTeam = Instance.new("Team")
	redTeam._props.Name = "KickRed"
	local blueTeam = Instance.new("Team")
	blueTeam._props.Name = "KickBlue"
	killer._props.Team = redTeam
	prey._props.Team = blueTeam
	rawget(workspace, "_props").Raycast = function()
		return nil
	end
	-- And past spawn protection, which Reset grants and which correctly
	-- refuses all damage while it lasts.
	ADVANCE(Config.Combat.SpawnProtection + 0.5)

	local kickerRoot = killer._props.Character:FindFirstChild("HumanoidRootPart")
	local victimRoot = prey._props.Character:FindFirstChild("HumanoidRootPart")
	local victimHumanoid = prey._props.Character:FindFirstChildOfClass("Humanoid")
	local kickerHumanoid = killer._props.Character:FindFirstChildOfClass("Humanoid")

	kickerHumanoid._props.Health = 100
	kickerHumanoid._props.SeatPart = nil
	kickerRoot._props.CFrame = CFrame.new(0, 3, 0)
	-- In FRONT of the kicker: Roblox's forward is -Z, and a melee swing
	-- correctly refuses to hit somebody standing behind you. (The kick
	-- turns to face its target, which is why putting them behind still
	-- kicked fine and only the swing missed.)
	victimRoot._props.CFrame = CFrame.new(0, 3, -6)
	victimHumanoid._props.Health = 100

	-- A living opponent in reach is a SWING, not a kick. The kick must not
	-- quietly replace the melee.
	DamageService.ClearDeathRecord(prey)
	local healthBefore = victimHumanoid._props.Health
	WeaponService.MeleeForTests(killer)
	check("melee still swings at the living", victimHumanoid._props.Health < healthBefore,
		string.format("%.0f -> %.0f health", healthBefore, victimHumanoid._props.Health))

	--[[
		Now they are down, and recently.

		HandleDeath is what records the moment, so the kick reads the same
		fact the kill feed does rather than keeping its own.
	]]
	victimHumanoid._props.Health = 0
	DamageService.HandleDeath(prey, killer, "Rifle")
	RUN_SPAWNED()
	check("going down is recorded", DamageService.WentDownAt(prey) ~= nil, "")

	ADVANCE(Config.Kick.Cooldown + 0.1)
	FIRED = {}
	victimRoot._props.AssemblyLinearVelocity = Vector3.new()
	local pointsBefore = PlayerState.Get(killer).points
	WeaponService.MeleeForTests(killer)
	RUN_SPAWNED()

	check("the melee key kicks a fresh body",
		victimRoot._props.AssemblyLinearVelocity.Magnitude > 0,
		string.format("%.0f studs/sec", victimRoot._props.AssemblyLinearVelocity.Magnitude))
	check("and it throws them upward, not along the floor",
		victimRoot._props.AssemblyLinearVelocity.Y > 0,
		string.format("%.0f vertical", victimRoot._props.AssemblyLinearVelocity.Y))

	-- They are TOLD. A shove nobody notices is just physics; the one being
	-- kicked is the audience.
	local told = false
	for _, call in FIRED_TO("Notify") do
		if call.player == prey then
			told = true
		end
	end
	check("the victim is told about it", told, "")
	check("it is worth a couple of points, not a kill",
		PlayerState.Get(killer).points == pointsBefore + Config.Kick.Points,
		string.format("%d points", PlayerState.Get(killer).points - pointsBefore))

	--[[
		Once per body.

		Otherwise a corpse is a five-second points faucet, which turns a
		flourish into a farm.
	]]
	ADVANCE(Config.Kick.Cooldown + 0.1)
	local afterFirst = PlayerState.Get(killer).points
	WeaponService.MeleeForTests(killer)
	RUN_SPAWNED()
	check("a body can only be kicked once",
		PlayerState.Get(killer).points == afterFirst,
		string.format("%d more points", PlayerState.Get(killer).points - afterFirst))

	--[[
		And the window closes.

		Five seconds is long enough to walk over and do it, short enough
		that bodies lying around the map are not a permanent invitation --
		which would make it tedious rather than funny.
	]]
	DamageService.HandleDeath(prey, killer, "Rifle")
	RUN_SPAWNED()
	ADVANCE(Config.Kick.DeathWindow + 1)
	local afterWindow = PlayerState.Get(killer).points
	victimRoot._props.AssemblyLinearVelocity = Vector3.new()
	WeaponService.MeleeForTests(killer)
	RUN_SPAWNED()
	check("an old body is not kickable",
		PlayerState.Get(killer).points == afterWindow,
		string.format("%d more points", PlayerState.Get(killer).points - afterWindow))
end

DUMP("")
DUMP("Basketball:")
do
	--[[
		The charged shot is the sport.

		A tap drops the ball at your feet, a full wind-up sails over the
		backboard, and the useful shot is in between -- which makes shooting
		a judgement rather than a button. The wind-up is timed on the SERVER
		because a client announcing "full power" would be claiming a wind-up
		it never waited through.
	]]
	local built = BasketballService.Build(1900)
	check("the court is built", built ~= nil and built.ball ~= nil, "")
	check("with a hoop at each end", BasketballService.HoopCount() == 2,
		string.format("%d hoops", BasketballService.HoopCount()))

	local ballPart = BasketballService.Ball()
	check("and a ball", ballPart ~= nil, "")

	if ballPart and built then
		--[[
			The ball is PHYSICAL, which is the entire point of putting a
			court in a shooter: it can be shot out of the air, run over and
			blown up. An anchored ball would be a scoreboard with a prop.
		]]
		check("the ball is a physical object, not scenery",
			ballPart._props.Anchored == false, tostring(ballPart._props.Anchored))

		-- Walk into it to pick it up. Possession is proximity, like the
		-- puck: there is nothing to learn.
		local root = killer._props.Character:FindFirstChild("HumanoidRootPart")
		killer._props.Character:FindFirstChildOfClass("Humanoid")._props.Health = 100
		root._props.CFrame = CFrame.new(ballPart.Position)
		BasketballService.StepForTests()
		check("walking into the ball picks it up",
			BasketballService.Holder() == killer,
			tostring(BasketballService.Holder() and BasketballService.Holder()._props.Name))

		--[[
			Power comes from how long you held it.

			Checked by throwing twice from the same spot and comparing the
			speed: a tap must be clearly weaker than a full wind-up, or the
			charge is decoration.
		]]
		local function throwAfter(seconds)
			BasketballService.GiveBallForTests(killer)
			BasketballService.StartCharge(killer)
			ADVANCE(seconds)
			BasketballService.Release(killer, Vector3.new(0, 0, -1))
			return ballPart._props.AssemblyLinearVelocity.Magnitude
		end

		local tap = throwAfter(0.02)
		local full = throwAfter(Config.Basketball.FullChargeSeconds + 0.2)
		check("a tap is a weak throw", tap > 0, string.format("%.0f studs/sec", tap))
		check("and a full wind-up is much harder", full > tap * 2,
			string.format("%.0f vs %.0f studs/sec", full, tap))

		-- Charging longer than full does not keep helping, or the shot
		-- would reward holding the key down forever.
		local overcharged = throwAfter(Config.Basketball.FullChargeSeconds * 3)
		check("holding it longer than full earns nothing extra",
			math.abs(overcharged - full) < 1,
			string.format("%.0f vs %.0f studs/sec", overcharged, full))

		-- The throw arcs: it must leave your hands going upward, or every
		-- shot would be a flat pass at the floor.
		check("the throw arcs upward",
			ballPart._props.AssemblyLinearVelocity.Y > 0,
			string.format("%.0f studs/sec vertical",
				ballPart._props.AssemblyLinearVelocity.Y))

		--[[
			A basket only counts on the way DOWN.

			The sensor sits below the rim, so without the direction check a
			ball thrown up through the net from underneath would score --
			which is not a basket in any version of the sport.
		]]
		local scored = {}
		BasketballService.Scored.Connect(function(who, points, fromThree)
			table.insert(scored, { who = who, points = points, fromThree = fromThree })
		end)

		local hoopSensor
		for _, child in built and workspace:FindFirstChild("BasketballCourt"):GetChildren() do
			if child._props.Name == "HoopSensor" then
				hoopSensor = child
				break
			end
		end
		check("the hoop has a sensor under the rim", hoopSensor ~= nil, "")

		if hoopSensor then
			--[[
				Shot, then in flight -- not held.

				My first version of this kept the ball in the shooter's
				hands while placing it at the hoop, and possession dragged
				it DOWNWARD onto the sensor, so a ball thrown upwards
				scored. That was the test's fault rather than the code's,
				but it is worth doing it the real way: release the ball
				through the actual shooting path, then move it.
			]]
			BasketballService.GiveBallForTests(killer)
			BasketballService.StartCharge(killer)
			ADVANCE(Config.Basketball.FullChargeSeconds)
			BasketballService.Release(killer, Vector3.new(0, 0, -1))
			check("shooting releases the ball", BasketballService.Holder() == nil, "")

			-- Rising through it: not a basket.
			ballPart._props.CFrame = CFrame.new(hoopSensor.Position)
			ballPart._props.AssemblyLinearVelocity = Vector3.new(0, 40, 0)
			BasketballService.StepForTests()
			check("a ball going UP through the net is not a basket", #scored == 0,
				string.format("%d baskets", #scored))

			-- Falling through it: a basket.
			ADVANCE(2)
			ballPart._props.CFrame = CFrame.new(hoopSensor.Position)
			ballPart._props.AssemblyLinearVelocity = Vector3.new(0, -40, 0)
			BasketballService.StepForTests()
			RUN_SPAWNED()
			check("and falling through it is", #scored == 1,
				string.format("%d baskets", #scored))

			if #scored == 1 then
				check("credited to whoever touched it last",
					scored[1].who == killer,
					tostring(scored[1].who and scored[1].who._props.Name))
				-- Through the one scoring path, so it reaches the round.
				check("and worth points on the arena scoreboard",
					PlayerState.Get(killer).scoredBy["basket"] ~= nil
						or PlayerState.Get(killer).scoredBy["three pointer"] ~= nil,
					"")
			end

			-- The ball resets, or the next basket is scored by whoever is
			-- standing under the hoop.
			check("scoring returns the ball to the middle",
				BasketballService.Holder() == nil, "")
		end

		-- A bullet moves the ball, same as the puck.
		local before = ballPart._props.AssemblyLinearVelocity.Magnitude
		local handled = BasketballService.RegisterHit(ballPart, prey, Vector3.new(1, 0, 0))
		check("shooting the ball moves it", handled
			and ballPart._props.AssemblyLinearVelocity.Magnitude ~= before,
			string.format("handled=%s", tostring(handled)))
	end

	BasketballService.Clear()
end

DUMP("")
DUMP("Bowling:")
do
	--[[
		Scored per ball, not over ten frames.

		A deliberate departure from the sport: ten frames is a ten-minute
		commitment and the arena round is already the clock. A player locked
		into a game longer than the round is a player who cannot be shot at,
		which is the one thing nothing here is allowed to be.
	]]
	local built = BowlingService.Build(1900)
	check("the alley is built", built ~= nil and built.lanes == Config.Bowling.Lanes,
		string.format("%d lanes", BowlingService.LaneCount()))
	check("with ten pins on a lane", BowlingService.PinCount(1) == 10,
		string.format("%d pins", BowlingService.PinCount(1)))
	check("all standing to start", BowlingService.StandingCount(1) == 10,
		string.format("%d up", BowlingService.StandingCount(1)))

	local lane = BowlingService.LaneForTests(1)
	check("the lane is readable", lane ~= nil, "")

	if lane then
		--[[
			The oil.

			Friction near zero is why a bowling ball slides and hooks rather
			than rolling to a stop in six feet. It is most of what the sport
			feels like, and it is one number -- so it is worth asserting,
			because nothing about playing in a terminal would reveal it
			being wrong.
		]]
		local surface
		for _, child in workspace:FindFirstChild("BowlingAlley"):GetChildren() do
			if child._props.Name == "BowlingLane" then
				surface = child
				break
			end
		end
		check("the lane is oiled", surface ~= nil
			and surface._props.CustomPhysicalProperties.Friction < 0.1,
			if surface then string.format("%.3f friction",
				surface._props.CustomPhysicalProperties.Friction) else "no lane")

		-- Pins must be loose, or they cannot fall into each other and a
		-- strike becomes ten separate shots.
		check("the pins are loose, not bolted down",
			lane.pins[1].part._props.Anchored == false,
			tostring(lane.pins[1].part._props.Anchored))

		-- Walk up and the ball is yours.
		local root = killer._props.Character:FindFirstChild("HumanoidRootPart")
		killer._props.Character:FindFirstChildOfClass("Humanoid")._props.Health = 100
		root._props.CFrame = CFrame.new(lane.ball.Position)
		BowlingService.StepForTests()
		check("walking up to the ball picks it up",
			BowlingService.HolderLane(killer) == 1,
			tostring(BowlingService.HolderLane(killer)))

		-- Power from the wind-up, as everywhere else.
		local function rollAfter(seconds)
			BowlingService.GiveBallForTests(killer, 1)
			lane.rolling = false
			BowlingService.StartCharge(killer)
			ADVANCE(seconds)
			BowlingService.Roll(killer, Vector3.new(0, 0, -1))
			return lane.ball._props.AssemblyLinearVelocity.Magnitude
		end

		local gentle = rollAfter(0.02)
		local hard = rollAfter(Config.Bowling.FullChargeSeconds + 0.2)
		check("a gentle roll is slow", gentle > 0, string.format("%.0f studs/sec", gentle))
		check("and a full wind-up is fast", hard > gentle * 2,
			string.format("%.0f vs %.0f studs/sec", hard, gentle))

		-- A bowling ball goes DOWN the lane, not into the air.
		check("the roll stays on the ground",
			math.abs(lane.ball._props.AssemblyLinearVelocity.Y) < 0.01,
			string.format("%.2f studs/sec vertical",
				lane.ball._props.AssemblyLinearVelocity.Y))

		--[[
			A pin is down by TILT, not by height.

			A pin shunted flat along the deck without toppling would read as
			standing if this measured height, and that is exactly what a
			ball clipping the base does.
		]]
		local rolled = {}
		BowlingService.Rolled.Connect(function(who, pins, isStrike)
			table.insert(rolled, { who = who, pins = pins, strike = isStrike })
		end)

		-- Tip one over and nothing else.
		lane.pins[1].part._props.CFrame = lane.pins[1].home * CFrame.Angles(math.rad(85), 0, 0)
		check("a toppled pin counts as down", BowlingService.StandingCount(1) == 9,
			string.format("%d up", BowlingService.StandingCount(1)))

		-- Settle the roll: one pin, no strike.
		BowlingService.GiveBallForTests(killer, 1)
		lane.rolling = false
		BowlingService.StartCharge(killer)
		ADVANCE(0.4)
		BowlingService.Roll(killer, Vector3.new(0, 0, -1))
		ADVANCE(Config.Bowling.SettleSeconds + 0.1)
		BowlingService.StepForTests()
		RUN_SPAWNED()
		check("the roll is counted once it settles", #rolled == 1,
			string.format("%d rolls", #rolled))
		if #rolled == 1 then
			check("one pin is one pin, not a strike",
				rolled[1].pins == 1 and not rolled[1].strike,
				string.format("%d pins, strike=%s", rolled[1].pins, tostring(rolled[1].strike)))
		end

		--[[
			Pins left standing stay standing for the second ball.

			The only part of real bowling's structure worth keeping: two
			pins at the back is a different and harder shot than a full
			rack, and resetting between balls would throw that away.
		]]
		check("a partial knock leaves a second ball", lane.secondBall,
			tostring(lane.secondBall))

		-- Now flatten the lot: that is a strike only on the FIRST ball.
		lane.secondBall = false
		for _, pin in lane.pins do
			pin.part._props.CFrame = pin.home * CFrame.Angles(math.rad(90), 0, 0)
		end
		check("all ten down reads as all ten", BowlingService.StandingCount(1) == 0,
			string.format("%d up", BowlingService.StandingCount(1)))

		rolled = {}
		FIRED = {}
		local before = PlayerState.Get(killer).points
		BowlingService.GiveBallForTests(killer, 1)
		lane.rolling = false
		BowlingService.StartCharge(killer)
		ADVANCE(Config.Bowling.FullChargeSeconds)
		BowlingService.Roll(killer, Vector3.new(0, 0, -1))
		ADVANCE(Config.Bowling.SettleSeconds + 0.1)
		BowlingService.StepForTests()
		RUN_SPAWNED()

		check("clearing the rack is a strike",
			#rolled == 1 and rolled[1].strike,
			string.format("%d rolls, strike=%s", #rolled,
				tostring(rolled[1] and rolled[1].strike)))
		check("and it scores through the arena scoreboard",
			PlayerState.Get(killer).points > before
				and PlayerState.Get(killer).scoredBy["strike"] ~= nil,
			string.format("%d -> %d", before, PlayerState.Get(killer).points))

		-- A strike resets the rack, or the next ball scores ten free pins.
		check("a strike racks them up again", BowlingService.StandingCount(1) == 10,
			string.format("%d up", BowlingService.StandingCount(1)))
		check("and it is a fresh first ball", not lane.secondBall,
			tostring(lane.secondBall))

		-- Shooting the ball down the lane is a legitimate roll.
		lane.rolling = false
		local handled = BowlingService.RegisterHit(lane.ball, prey, Vector3.new(0, 0, -1))
		check("shooting the ball rolls it", handled and lane.roller == prey,
			string.format("handled=%s roller=%s", tostring(handled),
				tostring(lane.roller and lane.roller._props.Name)))
	end

	BowlingService.Clear()
end

DUMP("")
DUMP("Medals and the goalie:")
do
	--[[
		A medal marks something you DID.

		The catalogue deliberately holds no medal for taking damage, dying
		well or surviving -- those are not achievements, they are weather --
		and no medal for anything that cannot be earned yet, because an
		unearnable medal sends players hunting for something that is not
		there.
	]]
	MedalService.ResetForTests()
	MatchService.SetPhaseForTests("Playing")

	FIRED = {}
	local pointsBefore = PlayerState.Get(killer).points
	local gave = MedalService.Award(killer, "Headshot")
	RUN_SPAWNED()
	check("a medal is awarded", gave, tostring(gave))
	check("and reaches the player", #FIRED_TO("Medal") == 1,
		string.format("%d medals", #FIRED_TO("Medal")))
	check("with a noise of its own", #FIRED_TO("PlaySound") >= 1,
		string.format("%d sounds", #FIRED_TO("PlaySound")))

	--[[
		A medal scores through the one scoring path.

		Which means it moves the team total and appears in the end-of-round
		breakdown under its own name, rather than being a separate kind of
		number nobody can account for.
	]]
	check("a medal is worth points", PlayerState.Get(killer).points > pointsBefore,
		string.format("%d -> %d", pointsBefore, PlayerState.Get(killer).points))
	check("and the breakdown records what for",
		PlayerState.Get(killer).scoredBy["headshot"] ~= nil,
		tostring(PlayerState.Get(killer).scoredBy["headshot"]))

	--[[
		The same medal twice in an instant is one medal.

		A shotgun landing four pellets on a head is one headshot, and a
		chain reaction that sets off six cans is one chain reaction. Without
		the guard both would spam the screen and the score.
	]]
	FIRED = {}
	local again = MedalService.Award(killer, "Headshot")
	check("the same medal does not repeat instantly", not again,
		string.format("%d medals", #FIRED_TO("Medal")))

	-- After the guard, it can be earned again.
	ADVANCE(3)
	check("but can be earned again later", MedalService.Award(killer, "Headshot"), "")

	-- A medal that does not exist is loud rather than silent: an unawarded
	-- medal is invisible, and that is how a typo survives for months.
	WARNINGS = {}
	check("an unknown medal is refused", not MedalService.Award(killer, "NoSuchThing"), "")
	check("and warns about it", #WARNINGS > 0, string.format("%d warnings", #WARNINGS))

	--[[
		The goalie: named, numbered, and stays in his net.

		A goalie that chases the puck is a fifth skater. This one tracks
		sideways between his posts and never leaves his line, so beating him
		means picking a corner rather than waiting for him to wander off.
	]]
	ArcadeService.Staff("hockey")
	local goalies = {}
	for _, bot in BotService.AllForTests() do
		if bot.role == "goalie" then
			table.insert(goalies, bot)
		end
	end
	check("both nets have a keeper", #goalies == 2, string.format("%d goalies", #goalies))

	if #goalies == 2 then
		local named = 0
		local numbered = 0
		for _, bot in goalies do
			if bot.name == Config.Goalie.Name then
				named += 1
			end
			local torso = bot.model:FindFirstChild("Torso")
			local plate = torso and torso:FindFirstChild("Jersey")
			local label = plate and plate:GetChildren()[1]
			if label and label._props.Text == tostring(Config.Goalie.Number) then
				numbered += 1
			end
		end
		check("the keeper is called " .. Config.Goalie.Name, named == 2,
			string.format("%d of 2 named %s", named, Config.Goalie.Name))
		check("and wears " .. tostring(Config.Goalie.Number), numbered == 2,
			string.format("%d of 2 numbered", numbered))

		-- He tracks the puck sideways, but stays on his line.
		local keeper = goalies[1]
		local line = keeper.home.Z
		BotService.PuckPosition = Vector3.new(keeper.home.X + 400, 4, line)
		for _ = 1, 40 do
			ADVANCE(Config.Bots.ThinkInterval + 0.01)
			BotService.StepForTests()
		end
		local moved = keeper.root._props.CFrame.Position
		check("the keeper slides across to cover a shot",
			math.abs(moved.X - keeper.home.X) > 1,
			string.format("%.0f studs across", moved.X - keeper.home.X))
		check("but never further than his posts",
			math.abs(moved.X - keeper.home.X) <= Config.Goalie.SideToSide + 0.5,
			string.format("%.1f studs, limit %d",
				math.abs(moved.X - keeper.home.X), Config.Goalie.SideToSide))
		check("and never leaves his line",
			math.abs(moved.Z - line) < 1,
			string.format("%.1f studs off the line", math.abs(moved.Z - line)))

		BotService.PuckPosition = nil
	end
end

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

	--[[
		Land mines.

		The blinking light is what makes these fair rather than cruel: a
		mine you cannot see is a random death, and a mine with a red light
		on it is a thing you drove over anyway. The fireball is what keeps
		them interesting once the map is learned -- the mine is predictable
		and the second blast is not.
	]]
	check("there are mines on the map", FireService.MineCount() > 0,
		string.format("%d armed", FireService.MineCount()))

	local mine = FireService.MinesForTests()[1]
	check("a mine has a warning light", mine ~= nil and mine.led ~= nil, "")

	if mine then
		--[[
			The light blinks from the SHARED heartbeat.

			The pasted version gave every mine its own while-loop in its own
			thread: twenty mines is then twenty threads waking twice a
			second forever to toggle a colour. One shared flip looks
			identical and costs nothing.
		]]
		local first = mine.led._props.Color
		ADVANCE(Config.Fire.MineBlinkSeconds + 0.01)
		FireService.StepForTests()
		local second = mine.led._props.Color
		check("the light blinks", first ~= second,
			string.format("%.2f -> %.2f red", first.R, second.R))

		--[[
			The ground it sits on must not set it off.

			A mine rests on terrain and usually beside a kerb, and both touch
			it constantly. Only something that MOVED into it counts -- which
			is exactly the set of things that should trigger a mine.
		]]
		local floor = Instance.new("Part")
		floor._props.Anchored = true
		mine.body._props.Touched._fire(floor)
		check("the ground it rests on does not set it off", mine.armed,
			tostring(mine.armed))

		-- A player walking into it does.
		local armedBefore = FireService.MineCount()
		local root = prey._props.Character:FindFirstChild("HumanoidRootPart")
		root._props.Anchored = false
		mine.body._props.Touched._fire(root)
		check("stepping on one sets it off", not mine.armed, tostring(mine.armed))
		check("and it leaves the minefield", FireService.MineCount() < armedBefore,
			string.format("%d of %d left", FireService.MineCount(), armedBefore))

		--[[
			The fireball comes down on a timer and explodes again.

			Checked by flushing the delayed queue: the second blast is the
			whole point of a mine here, and without it this is just a
			slightly louder landmine.
		]]
		local scorchBefore = 0
		for _, child in workspace:GetChildren() do
			if child._props.Name == "Scorch" then
				scorchBefore += 1
			end
		end
		RUN_DELAYED()
		local scorchAfter = 0
		for _, child in workspace:GetChildren() do
			if child._props.Name == "Scorch" then
				scorchAfter += 1
			end
		end
		check("the fireball lands and burns the ground", scorchAfter > scorchBefore,
			string.format("%d scorch marks", scorchAfter))
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
SERVER = ['PlayerState', 'MedalService', 'TeamService', 'BotService', 'ArcadeService', 'ResortService', 'HockeyService', 'MapService', 'VehicleService', 'DamageService', 'WildlifeService',
          'CarnivalService', 'BasketballService', 'BowlingService', 'FireService', 'ProjectileService', 'WeaponService', 'PickupService',
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
