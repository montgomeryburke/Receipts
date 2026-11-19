--!strict
--[[
	Config — every number you might want to change lives in this one file.

	FREE MODE
	---------
	Config.FreeMode is true, which means every gun, every vehicle and every
	perk is unlocked for everybody and nothing costs Robux. That is deliberate:
	get the game fun first, turn on the till later.

	When you are ready to make money, set FreeMode = false and paste your real
	IDs into Config.GamePasses / Config.Products. Nothing else needs to change —
	the shop, the purchase handling and the ownership checks are all already
	written and just switch on.
]]

local Config = {}

Config.FreeMode = true

--[[
	Endless ammo. Guns never run dry and nothing needs reloading.

	Set this to false if you ever want scarcity back — the magazine sizes and
	reload times below are all still here and still correct.
]]
Config.InfiniteAmmo = true

-- ============================================================ MONETIZATION ==
-- Ignored entirely while FreeMode is true. Left here so future-you has it ready.

Config.GamePasses = {
	DiamondBullets = 0,
	FastStart = 0,
	ShieldPlating = 0,
}

Config.Products = {
	MegaDetonations = 0,
	Revive = 0,
	InstantTopCar = 0,
}

Config.ProductGrants = {
	MegaDetonations = 10,
	InstantTopCarTier = 4,
}

-- =================================================================== MATCH ==

--[[
	GAME MODES.

	Two, voted on between rounds along with the map.

	  Slayer  shoot people for points; the team with the most at the final
	          whistle wins.
	  CTF     take the enemy flag back to your own. Kills still score, but a
	          capture is worth far more than any of them.
]]
Config.Modes = {
	{
		Id = "Slayer",
		Name = "Slayer",
		Blurb = "Shoot everything. Most points wins.",
		-- Roughly a hundred kills' worth, so the clock usually decides it.
		ScoreLimit = 3000,
	},
	{
		Id = "CTF",
		Name = "Capture the Flag",
		Blurb = "Take theirs. Defend yours.",
		-- Three captures, plus whatever the kills add.
		ScoreLimit = 1600,
	},
}

Config.CTF = {
	-- What a capture is worth. Deliberately far more than any kill.
	CapturePoints = 500,
	-- And a little something for the effort of taking it and bringing it back.
	FlagTakenPoints = 25,
	FlagReturnPoints = 40,
	-- Seconds a dropped flag lies there before it goes home on its own.
	DroppedReturnDelay = 25,
	-- Halo's rule: you cannot score unless your own flag is on its stand.
	RequireOwnFlagHome = true,
	-- Carrying slows you down, so a runner can be caught.
	CarrierSpeedFactor = 0.82,
}

Config.Match = {
	MaxPlayers = 20,
	VoteDuration = 20,
	RoundDuration = 300,
	IntermissionDuration = 15,
	MapChoices = 3,
	MinPlayers = 1,
	-- Fallback only; each mode carries its own. This was 80 back when a kill
	-- was worth 2 points, and once weapons started scoring 10 to 35 apiece it
	-- meant a round ended after about three kills.
	ScoreLimit = 3000,
	PointsPerKill = 10,
}

-- ================================================================== COMBAT ==

Config.Combat = {
	MaxHealth = 100,
	-- Halo's rhythm: a few seconds of not being shot, then a fast refill. It
	-- is what makes ducking behind cover mid-fight worth doing, and at the
	-- old 6 seconds and 8 a second a 50-point shield took seven seconds to
	-- come back, which is longer than most fights last.
	ShieldRegenDelay = 3,
	ShieldRegenPerSecond = 26,
	SpawnProtection = 3,
	-- Auto-aim only grabs targets inside this cone, in degrees, and this far.
	AutoAimConeDegrees = 12,
	AutoAimRange = 500,
	-- The server re-checks aim against this wider cone before trusting a shot.
	AutoAimServerToleranceDegrees = 25,
}

--[[
	THE ARSENAL
	-----------
	Every gun is just a row in this table, so adding a new one is a copy, a
	paste and a rename — no new code anywhere.

	Kind:
	  "Hitscan"    instant hit, good for fast-firing guns
	  "Projectile" a visible travelling bullet
	  "Arcing"     lobbed and affected by gravity (grenades)
	  "Rocket"     travels flat and fast, explodes on contact (RPG)

	Slot is the number key you press. Several guns can share a slot — pressing
	the key again cycles through them.
]]
Config.Weapons = {
	-- ------------------------------------------------------------- SIDEARMS
	Pistol = {
		Slot = 1, Category = "Sidearm", DisplayName = "9mm Pistol", Recoil = 0.9,
		Kind = "Hitscan", Damage = 12, Cooldown = 0.28, Range = 400,
		MagSize = 12, ReloadTime = 1.3, Spread = 1.2,
		-- 2x, like the pistol in the game this is in the spirit of.
		ZoomFov = 38,
		Color = Color3.fromRGB(90, 90, 96),
		Automatic = true,
		Points = 10,
	},
	Revolver = {
		Slot = 1, Category = "Sidearm", DisplayName = ".44 Revolver", Recoil = 2.6,
		Kind = "Hitscan", Damage = 34, Cooldown = 0.7, Range = 500,
		MagSize = 6, ReloadTime = 2.1, Spread = 0.8,
		ZoomFov = 34,
		Color = Color3.fromRGB(150, 130, 90),
		Automatic = true,
		Points = 15,
	},
	Deagle = {
		Slot = 1, Category = "Sidearm", DisplayName = "Hand Cannon", Recoil = 2.9,
		Kind = "Hitscan", Damage = 42, Cooldown = 0.75, Range = 480,
		MagSize = 7, ReloadTime = 2.0, Spread = 1.0,
		ZoomFov = 34,
		Color = Color3.fromRGB(200, 180, 110),
		Automatic = true,
		Points = 15,
	},

	-- ------------------------------------------------------------ AUTOMATIC
	SMG = {
		Slot = 2, Category = "Automatic", DisplayName = "Backroad SMG", Recoil = 0.5,
		Kind = "Hitscan", Damage = 7, Cooldown = 0.075, Range = 380,
		MagSize = 35, ReloadTime = 1.7, Spread = 2.6, Automatic = true,
		-- Barely more than a steadier hold: a submachine gun is a
		-- close-range weapon and a big magnification on one is a trap.
		ZoomFov = 58,
		Color = Color3.fromRGB(70, 76, 84),
		Points = 8,
	},
	AssaultRifle = {
		Slot = 2, Category = "Automatic", DisplayName = "Assault Rifle", Recoil = 0.7,
		Kind = "Hitscan", Damage = 14, Cooldown = 0.11, Range = 700,
		MagSize = 30, ReloadTime = 2.0, Spread = 1.5, Automatic = true,
		ZoomFov = 47,
		Color = Color3.fromRGB(60, 68, 58),
		Points = 10,
	},
	MachineGun = {
		Slot = 2, Category = "Automatic", DisplayName = "Machine Gun", Recoil = 0.6,
		Kind = "Hitscan", Damage = 11, Cooldown = 0.09, Range = 650,
		MagSize = 80, ReloadTime = 3.4, Spread = 2.2, Automatic = true,
		ZoomFov = 50,
		Color = Color3.fromRGB(52, 54, 58),
		Points = 10,
	},
	Minigun = {
		Slot = 2, Category = "Automatic", DisplayName = "Mud Minigun", Recoil = 0.35,
		Kind = "Hitscan", Damage = 9, Cooldown = 0.045, Range = 600,
		MagSize = 200, ReloadTime = 5.0, Spread = 3.4, Automatic = true,
		-- Slows you down while you hold the trigger, because it is enormous.
		MoveSpeedFactor = 0.45,
		-- And no sight. It is the one gun in the game whose whole character
		-- is spraying from the hip, and a scope on it would be a worse
		-- version of the machine gun.
		Color = Color3.fromRGB(96, 100, 104),
		Points = 8,
	},

	-- ------------------------------------------------------------- SHOTGUNS
	Shotgun = {
		Slot = 3, Category = "Shotgun", DisplayName = "Pump Shotgun", Recoil = 3.4,
		Kind = "Hitscan", Damage = 9, Cooldown = 0.85, Range = 160,
		MagSize = 6, ReloadTime = 2.6, Spread = 6.0, Pellets = 9,
		-- A modest one. Magnifying a nine-pellet cone at 160 studs tells
		-- you nothing you did not already know, but the steadier hold is
		-- still worth having in a doorway.
		ZoomFov = 62,
		Color = Color3.fromRGB(120, 84, 52),
		Automatic = true,
		Points = 14,
	},
	AutoShotgun = {
		Slot = 3, Category = "Shotgun", DisplayName = "Auto Shotgun", Recoil = 2.2,
		Kind = "Hitscan", Damage = 7, Cooldown = 0.4, Range = 140,
		MagSize = 8, ReloadTime = 3.0, Spread = 7.5, Pellets = 8, Automatic = true,
		ZoomFov = 64,
		Color = Color3.fromRGB(90, 70, 60),
		Points = 12,
	},

	-- -------------------------------------------------------------- SNIPERS
	Sniper = {
		Slot = 4, Category = "Sniper", DisplayName = "Sniper Rifle", Recoil = 3.2,
		Kind = "Hitscan", Damage = 62, Cooldown = 1.5, Range = 2400,
		MagSize = 4, ReloadTime = 2.8, Spread = 0.0,
		-- Halo's sniper had two scope stages. This has four, because the ask
		-- was to be able to line up close-range headshots too: 2x is usable
		-- across a room, 10x reaches the other end of the map.
		-- 5x, 10x, 50x, stepped round on right click and then back to
		-- hipfire. The 50 is absurd and that is the point of it: it is for
		-- picking somebody off the far side of the map.
		ZoomLevels = { 5, 10, 50 },
		ZoomFov = 22, AutoAim = true,
		-- Holds down from the hip; one shot at a time once scoped, so a
		-- long-range rifle still has to be aimed.
		Automatic = true,
		SemiAutoWhenScoped = true,
		Color = Color3.fromRGB(46, 56, 46),
		Points = 30,
	},
	AntiMaterial = {
		Slot = 4, Category = "Sniper", DisplayName = "Anti-Truck Rifle", Recoil = 4.5,
		Kind = "Projectile", Damage = 90, Cooldown = 2.4, Range = 2600, Speed = 1200,
		MagSize = 3, ReloadTime = 3.6, Spread = 0.0,
		ZoomLevels = { 6, 14, 30 },
		ZoomFov = 16, AutoAim = true,
		Automatic = true,
		SemiAutoWhenScoped = true,
		-- Wrecks vehicles specifically.
		VehicleDamageMultiplier = 3,
		Color = Color3.fromRGB(60, 60, 70),
		Points = 35,
	},

	-- ------------------------------------------------------- THE STAR ITEM
	DiamondGun = {
		Slot = 5, Category = "Special", DisplayName = "Nuclear Diamond Gun", Recoil = 1.6,
		Kind = "Projectile", Damage = 10, Cooldown = 0.55, Range = 900, Speed = 320,
		MagSize = 8, ReloadTime = 2.2, Spread = 0.0,
		-- The whole point: it goes through things, and every thing it goes
		-- through detonates.
		Pierces = 8,
		BlastRadius = 14,
		BlastDamage = 12,
		-- Press F while it is in the air to make that blast ten times bigger.
		CanMegaDetonate = true,
		AutoAim = true,
		Color = Color3.fromRGB(120, 230, 245),
		Automatic = true,
		Points = 25,
	},

	-- --------------------------------------------------------- EXPLOSIVES
	Grenade = {
		Slot = 6, Category = "Explosive", DisplayName = "Frag Grenade", Recoil = 0.4,
		Kind = "Arcing", Damage = 0, Cooldown = 1.1, Range = 220, Speed = 90,
		MagSize = 3, ReloadTime = 4.0, Spread = 0.0,
		-- Was 26. A literal ten-times radius would be 260 studs, which is a
		-- third of the map from one grenade; 95 is enormous without being
		-- absurd. Change this one number if you want it bigger still.
		FuseTime = 3.0, BlastRadius = 95, BlastDamage = 150,
		Color = Color3.fromRGB(70, 92, 62),
		Points = 20,
	},
	StickyGrenade = {
		Slot = 6, Category = "Explosive", DisplayName = "Sticky Bomb", Recoil = 0.4,
		Kind = "Arcing", Damage = 0, Cooldown = 1.3, Range = 200, Speed = 80,
		MagSize = 2, ReloadTime = 4.5, Spread = 0.0,
		FuseTime = 2.5, BlastRadius = 110, BlastDamage = 170, Sticky = true,
		Color = Color3.fromRGB(180, 90, 190),
		Points = 22,
	},
	RPG = {
		Slot = 6, Category = "Explosive", DisplayName = "Rocket Propelled Grenade", Recoil = 3.0,
		Kind = "Rocket", Damage = 0, Cooldown = 2.2, Range = 1400, Speed = 180,
		MagSize = 1, ReloadTime = 3.2, Spread = 0.0,
		BlastRadius = 90, BlastDamage = 150,
		VehicleDamageMultiplier = 2,
		Color = Color3.fromRGB(170, 70, 50),
		Points = 25,
	},

	-- ------------------------------------------------------------- UTILITY
	-- Both of these are found on the map rather than carried from spawn, and
	-- neither reloads: what you pick up is what you have.
	--[[
		The hockey stick, and what is left of it after a fight.

		Both are hitscan with almost no range, which is how you build a melee
		weapon out of the existing shooting code rather than a parallel one:
		the swing is a very short, very wide shot. The broken half hits far
		harder than the whole stick, which is the entire incentive to start
		a fight on the ice in the first place.
	]]
	HockeyStick = {
		Slot = 7, Category = "Utility", DisplayName = "Hockey Stick", Recoil = 0.5,
		Kind = "Hitscan", Damage = 34, Cooldown = 0.5, Range = 14,
		MagSize = 1, ReloadTime = 0, Spread = 6,
		Color = Color3.fromRGB(190, 170, 140),
		Automatic = true,
		Points = 18,
	},
	BrokenStick = {
		Slot = 7, Category = "Utility", DisplayName = "Broken Stick", Recoil = 0.9,
		Kind = "Hitscan", Damage = 78, Cooldown = 0.45, Range = 13,
		MagSize = 1, ReloadTime = 0, Spread = 7,
		Color = Color3.fromRGB(210, 120, 90),
		Automatic = true,
		Points = 40,
	},
	Poop = {
		Slot = 7, Category = "Utility", DisplayName = "Elephant Poop", Recoil = 0.2,
		Kind = "Arcing", Damage = 6, Cooldown = 0.55, Range = 220, Speed = 88,
		MagSize = 6, ReloadTime = 0, Spread = 1.5,
		FuseTime = 0,
		-- Splatters across whoever it hits and blocks their view.
		Splat = true,
		AmmoFromPickupsOnly = true,
		Color = Color3.fromRGB(92, 64, 38),
		Automatic = true,
		Points = 5,
	},
	Drone = {
		Slot = 7, Category = "Utility", DisplayName = "Hunter Drone", Recoil = 0.6,
		Kind = "Homing", Damage = 0, Cooldown = 1.6, Range = 1000, Speed = 92,
		MagSize = 2, ReloadTime = 0, Spread = 0,
		BlastRadius = 28, BlastDamage = 95,
		-- How hard it can turn while chasing, and how long its battery lasts.
		HomingTurnRate = 3.4,
		HomingLifetime = 14,
		AmmoFromPickupsOnly = true,
		AutoAim = true,
		Color = Color3.fromRGB(120, 205, 255),
		Points = 30,
	},

	LandMine = {
		Slot = 6, Category = "Explosive", DisplayName = "Land Mine", Recoil = 0.2,
		Kind = "Arcing", Damage = 0, Cooldown = 1.0, Range = 90, Speed = 40,
		MagSize = 4, ReloadTime = 3.0, Spread = 0.0,
		-- Sits where it lands and waits. A long fuse is what makes it a mine
		-- rather than a grenade.
		FuseTime = 40, Sticky = true,
		BlastRadius = 70, BlastDamage = 190,
		VehicleDamageMultiplier = 3,
		Points = 28, Automatic = true,
		Color = Color3.fromRGB(90, 96, 70),
	},
	ClusterBomb = {
		Slot = 6, Category = "Explosive", DisplayName = "Cluster Bomb", Recoil = 0.5,
		Kind = "Arcing", Damage = 0, Cooldown = 1.6, Range = 240, Speed = 95,
		MagSize = 2, ReloadTime = 4.5, Spread = 0.0,
		FuseTime = 2.2,
		BlastRadius = 60, BlastDamage = 110,
		-- Bursts into this many smaller bomblets when it goes off.
		Cluster = 8,
		ClusterRadius = 34,
		ClusterDamage = 70,
		Points = 26, Automatic = true,
		Color = Color3.fromRGB(200, 140, 60),
	},

	-- --------------------------------------------------- VEHICLE-MOUNTED
	-- These are not carried on foot; they come attached to a vehicle seat.
	FiftyCal = {
		Slot = 0, Category = "Mounted", DisplayName = "50 Cal", Recoil = 1.1,
		Kind = "Projectile", Damage = 28, Cooldown = 0.14, Range = 1600, Speed = 900,
		MagSize = 100, ReloadTime = 4.0, Spread = 1.4, Automatic = true,
		Pierces = 2, BlastRadius = 6, BlastDamage = 10,
		ZoomLevels = { 2, 4 },
		VehicleDamageMultiplier = 2, MountedOnly = true, AutoAim = true,
		Color = Color3.fromRGB(58, 60, 64),
		Points = 18,
	},
	TankCannon = {
		Slot = 0, Category = "Mounted", DisplayName = "Tank Cannon", Recoil = 4.0,
		Kind = "Rocket", Damage = 0, Cooldown = 3.0, Range = 2000, Speed = 420,
		MagSize = 1, ReloadTime = 3.0, Spread = 0.0,
		BlastRadius = 40, BlastDamage = 130,
		VehicleDamageMultiplier = 3, MountedOnly = true,
		Color = Color3.fromRGB(74, 84, 66),
		Points = 25,
	},
	PlaneGun = {
		Slot = 0, Category = "Mounted", DisplayName = "Wing Guns", Recoil = 0.5,
		Kind = "Projectile", Damage = 16, Cooldown = 0.1, Range = 1200, Speed = 800,
		MagSize = 150, ReloadTime = 5.0, Spread = 2.0, Automatic = true,
		MountedOnly = true,
		Color = Color3.fromRGB(120, 128, 136),
		Points = 15,
	},
}

--[[ Which guns you spawn holding. Everything else is found on the map. ]]
Config.StartingLoadout = { "MachineGun", "AssaultRifle", "Shotgun", "Sniper", "DiamondGun", "Grenade", "Pistol" }

--[[
	Melee, on Q.

	The other half of Halo's close-range rhythm: shoot the shield down, then
	finish with a hit. From behind it kills outright.
]]
Config.Melee = {
	Damage = 55,
	Range = 9,
	Cooldown = 0.8,
	-- A hit from behind is lethal, as it should be.
	BackstabMultiplier = 10,
	-- How far round the back counts as "behind", in degrees.
	BackstabArc = 80,
}

--[[
	Driving weight.

	A car that snaps to top speed feels like a cursor. These give it mass:
	it winds up, it carries momentum, and it steers less sharply the slower
	it is going.
]]
Config.Driving = {
	-- Punchier than before: they still have weight, but they get going.
	Acceleration = 72,
	BrakeDeceleration = 130,
	Coast = 34,
	-- Below this fraction of top speed, steering is reduced.
	SteerGripSpeed = 0.35,

	--[[
		The drivetrain.

		The wheels drive the car now, through hinge motors, with real springs
		holding it up and a servo steering the front pair. So these are the
		numbers of an actual car rather than the numbers of a push: torque
		accelerates, friction grips, and the spring decides whether it rides
		like a truck or a go-kart.
	]]
	MotorTorque = 15000,
	BrakeTorque = 25000,
	SuspensionHeight = 2,
	SuspensionTravel = 1,
	SpringStiffness = 8000,
	-- Around a tenth of the stiffness. Much less and it pogos.
	SpringDamping = 800,
	MaxSteerAngle = 32,
	-- Less lock at speed, or a twitch at 100 studs a second rolls the car.
	MinSteerAngle = 10,
	SteerSpeed = 6,
	SteerTorque = 100000,
	-- Grip. Lower is driftier; the weight makes tire friction beat whatever
	-- the road material claims.
	WheelFriction = 1.5,
	WheelFrictionWeight = 5,

	--[[
		Drivetrain modes, for the off-roaders.

		The point of three modes is that the mud pit should be a decision
		rather than a wall. In 2WD you bog down and have to pick a line; drop
		to 4L and you crawl through anything but cannot chase anybody. The
		numbers are deliberately a trade: 4L has four times the torque of
		2WD and less than half the speed, so nobody drives around in it.

		Cycled in this order, and the middle one is where a vehicle starts,
		because 4H is the one that is never actively wrong.
	]]
	Modes = {
		{ id = "2WD", label = "2WD", speedBias = 1.12, torqueBias = 0.75, allWheel = false },
		{ id = "4H", label = "4H", speedBias = 1.0, torqueBias = 1.0, allWheel = true },
		{ id = "4L", label = "4L", speedBias = 0.48, torqueBias = 2.2, allWheel = true },
	},
	StartingMode = 2,

	--[[
		Mud takes grip, not just speed.

		Mud used to only slow you down, which made it a speed bump rather
		than terrain -- and left the diff lock with nothing to do. Taking
		grip instead means mud makes you slide and spin, and locking the diff
		is the answer to it. That is the whole reason the button exists.
	]]
	MudGripFactor = 0.42,
	DiffLockGripBias = 1.7,
	DiffLockTorqueBias = 1.25,

	--[[
		Four-wheel steering, and the handbrake.

		The rear factor is well under one on purpose: a one-to-one
		counter-steer makes a vehicle crab sideways rather than turn, which
		feels broken rather than agile. A third is enough to pivot it about
		its middle and turn inside its own length.
	]]
	RearSteerFactor = 0.34,
	-- A handbrake takes most of the rear grip away. That IS the manoeuvre.
	HandbrakeGripFactor = 0.3,

	-- The winch: hook to anything anchored and reel yourself out.
	WinchRange = 70,
	WinchReelSpeed = 14,
	WinchMinLength = 6,
}

--[[
	The elephant.

	It wanders the map on its own, minds its own business, and leaves a great
	deal of poop behind it. The poop is the point: walk over it to pick it up,
	then throw it at people.
]]
Config.Wildlife = {
	ElephantCount = 2,
	ElephantSpeed = 15,
	-- Seconds between droppings.
	PoopInterval = 5,
	-- How long a dropping sits there before it fades.
	PoopLifetime = 90,
	-- How many throws one pile is worth.
	PoopPerPile = 2,
	-- Never more than this many piles on the map at once.
	MaxPoopPiles = 40,
	-- Seconds the victim's screen stays covered.
	SplatDuration = 4,
}

--[[
	SOUND.

	Every path here is an rbxasset:// file that ships inside the Roblox client
	itself. That matters: a numeric asset ID can fail to load, be moderated,
	or simply be wrong, and a wrong one is a runtime error in a place that has
	never been published. These cannot be wrong — they are part of the engine.

	The variety comes from pitch and volume rather than from a big library, so
	the whole game is scored off about eight files. Swap any `Asset` for a
	Toolbox sound you prefer and nothing else needs to change.

	Pitch is a range: every play picks a random value inside it, which is what
	stops a machine gun sounding like a metronome.
]]
--[[
	Medals: the moments worth announcing.

	Halo's medals worked because each one marked something you DID rather
	than something that happened to you -- a headshot is a decision, a
	chain reaction is a plan, a knockout is a fight you won. So there is no
	medal for taking damage, dying well, or surviving; those are not
	achievements, they are weather.

	Only moments that EXIST are listed. A medal for bowling a strike would
	be a promise the game cannot keep yet, and an unearnable medal is worse
	than a missing one -- it sends players looking for something that is not
	there. Strike and the low-blow sting arrive with the lanes and the kick.

	`points` is awarded through the one scoring path, so a medal moves the
	team score like everything else.
]]
Config.Medals = {
	Headshot = { name = "HEADSHOT", points = 15, sound = "Headshot" },
	ThreePointer = { name = "FROM THE ARC", points = 25, sound = "Bell" },
	Strike = { name = "STRIKE", points = 30, sound = "PinCrash" },
	Knockout = { name = "KNOCKOUT", points = 40, sound = "MeleeHit" },
	AirborneKill = { name = "AIRBORNE KILL", points = 35, sound = "Medal" },
	ChainReaction = { name = "CHAIN REACTION", points = 50, sound = "ExplosionBig" },
}

Config.Sounds = {
	-- ----------------------------------------------------------- gunfire
	ShotLight = { Asset = "rbxasset://sounds/clickfast.wav", Volume = 0.45, Pitch = { 1.6, 2.0 } },
	ShotHeavy = { Asset = "rbxasset://sounds/collide.wav", Volume = 0.6, Pitch = { 1.5, 1.9 } },
	ShotShotgun = { Asset = "rbxasset://sounds/collide.wav", Volume = 0.85, Pitch = { 0.7, 0.85 } },
	ShotSniper = { Asset = "rbxasset://sounds/bass.wav", Volume = 0.8, Pitch = { 1.5, 1.6 } },
	ShotLaunch = { Asset = "rbxasset://sounds/swoosh.wav", Volume = 0.7, Pitch = { 0.8, 1.0 } },
	ShotDiamond = { Asset = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.7, Pitch = { 0.8, 1.0 } },

	-- -------------------------------------------------------- explosions
	Explosion = { Asset = "rbxasset://sounds/bass.wav", Volume = 1, Pitch = { 0.45, 0.6 } },
	ExplosionBig = { Asset = "rbxasset://sounds/bass.wav", Volume = 1, Pitch = { 0.22, 0.3 } },

	-- ------------------------------------------------------------ combat
	Hitmarker = { Asset = "rbxasset://sounds/snap.wav", Volume = 0.5, Pitch = { 1.8, 2.0 } },
	Headshot = { Asset = "rbxasset://sounds/snap.wav", Volume = 0.7, Pitch = { 2.4, 2.6 } },
	KillConfirm = { Asset = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.6, Pitch = { 1.3, 1.4 } },
	Death = { Asset = "rbxasset://sounds/uuhhh.wav", Volume = 0.8, Pitch = { 0.9, 1.1 } },
	ShieldBreak = { Asset = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.7, Pitch = { 0.6, 0.7 } },
	MeleeSwing = { Asset = "rbxasset://sounds/swoosh.wav", Volume = 0.6, Pitch = { 1.4, 1.7 } },
	MeleeHit = { Asset = "rbxasset://sounds/collide.wav", Volume = 0.9, Pitch = { 0.5, 0.65 } },

	-- -------------------------------------------------------------- kit
	Pickup = { Asset = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.55, Pitch = { 1.5, 1.7 } },
	PickupBig = { Asset = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.8, Pitch = { 1.0, 1.1 } },
	WeaponSwitch = { Asset = "rbxasset://sounds/snap.wav", Volume = 0.35, Pitch = { 1.2, 1.3 } },

	-- ------------------------------------------------------------ events
	FlagTaken = { Asset = "rbxasset://sounds/electronicpingshort.wav", Volume = 1, Pitch = { 0.85, 0.85 } },
	FlagCapture = { Asset = "rbxasset://sounds/bass.wav", Volume = 1, Pitch = { 1.1, 1.1 } },
	RoundStart = { Asset = "rbxasset://sounds/bass.wav", Volume = 1, Pitch = { 0.9, 0.9 } },
	RoundEnd = { Asset = "rbxasset://sounds/bass.wav", Volume = 1, Pitch = { 0.6, 0.6 } },
	Medal = { Asset = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.9, Pitch = { 1.7, 1.7 } },

	-- ------------------------------------------------------- signature
	--[[
		The noises that belong to one thing and nothing else.

		All of these are built from the same handful of rbxasset files as
		everything above -- pitched, and in two cases layered. That is a real
		constraint, not laziness: a numeric asset ID can fail to load in an
		unpublished place or after a moderation sweep, and a goal horn that
		sometimes does not exist is worse than one made of a bass note.

		A horn is a long low note. A crowd is many voices at once, which is
		why CrowdVoice is pitched wide and played several times over rather
		than being one file -- layering is how you make a crowd out of a
		groan.
	]]
	GoalHorn = { Asset = "rbxasset://sounds/bass.wav", Volume = 1, Pitch = { 0.32, 0.34 } },
	CrowdVoice = { Asset = "rbxasset://sounds/uuhhh.wav", Volume = 0.5, Pitch = { 0.8, 1.9 } },
	-- A rifle crack is the snap, not the boom. The boom is ShotSniper; this
	-- is the layer on top that makes it read as a high-powered rifle.
	SniperCrack = { Asset = "rbxasset://sounds/snap.wav", Volume = 0.8, Pitch = { 2.2, 2.4 } },
	--[[
		Ten pins going over.

		Played several times at once by the caller, because one collide is
		one thing falling over and a strike is ten -- the clatter IS the
		layering.
	]]
	PinCrash = { Asset = "rbxasset://sounds/collide.wav", Volume = 0.8, Pitch = { 0.8, 1.4 } },
	-- The turret winding up before it fires, and the rattle while it does.
	TurretSpool = { Asset = "rbxasset://sounds/swoosh.wav", Volume = 0.7, Pitch = { 0.5, 0.6 } },
	TurretRattle = { Asset = "rbxasset://sounds/clickfast.wav", Volume = 0.5, Pitch = { 0.9, 1.1 } },

	-- --------------------------------------------------------- the world
	EngineLoop = { Asset = "rbxasset://sounds/collide.wav", Volume = 0.35, Pitch = { 0.5, 0.5 }, Looped = true },
	Boost = { Asset = "rbxasset://sounds/swoosh.wav", Volume = 0.8, Pitch = { 0.6, 0.7 } },
	Splash = { Asset = "rbxasset://sounds/impact_water.mp3", Volume = 1, Pitch = { 0.9, 1.1 } },
	Bell = { Asset = "rbxasset://sounds/electronicpingshort.wav", Volume = 1, Pitch = { 2.2, 2.2 } },
	ZombieGrowl = { Asset = "rbxasset://sounds/uuhhh.wav", Volume = 0.6, Pitch = { 0.5, 0.65 } },
	Fart = { Asset = "rbxasset://sounds/uuhhh.wav", Volume = 0.7, Pitch = { 0.35, 0.45 } },
	ParachuteOpen = { Asset = "rbxasset://sounds/swoosh.wav", Volume = 1, Pitch = { 0.5, 0.6 } },
	Jump = { Asset = "rbxasset://sounds/action_jump.mp3", Volume = 0.5, Pitch = { 1, 1 } },
}

--[[
	THE POPULATION.

	Zombies roam and come for you. Civilians wander and say something
	regrettable when shot. Bullseye targets stand around for practice.

	All three are worth points, and all three come back.
]]
Config.Population = {
	Zombies = 10,
	Civilians = 8,
	Targets = 12,

	-- Two shots from the starting rifle, which does 14. They were 120,
	-- which is nine shots, and a crowd of them was a chore rather than a
	-- threat.
	ZombieHealth = 28,
--[[
		The tallest thing a dweller can walk up.

		They have no Humanoid and no collision, so they are moved by hand --
		which means the ground under them is found with a downward ray and
		they are snapped to whatever it hits. The ray used to start six
		studs above their feet and take the first hit, so ANY ledge above
		their ankles pulled them up onto it: a kerb, a roof lip, the
		underside of a skybridge. Walking past a building put them on it.

		A step height makes the difference explicit. Anything up to this is
		a kerb and they step up; anything more is a wall and they walk round
		it instead.
	]]
	StepHeight = 4,
	ZombieSpeed = 13,
	ZombiePoints = 25,
	-- How close a zombie has to get before it starts swinging.
	ZombieReach = 9,
	ZombieDamage = 18,

	CivilianHealth = 60,
	CivilianSpeed = 11,
	CivilianPoints = 5,

	TargetHealth = 100,
	TargetPoints = 15,

	-- Seconds before a dead one is replaced.
	RespawnDelay = 12,
}

--[[ What a civilian says when you shoot them. ]]
Config.CivilianLines = {
	"OW! That was a smelly one!",
	"PBBBT! ... sorry, that always happens.",
	"You shot me and I farted. We are both embarrassed.",
	"Rude! And now I have gas.",
	"AAAH — oh no, that one squeaked.",
	"I was having a lovely day!",
	"Not the trousers! Not the trousers!",
	"That is coming out of your wages.",
}

--[[
	The motion tracker.

	Deliberately short-sighted, the way Halo's was: far enough that nobody
	walks up behind you, short enough that it never replaces looking.
]]
--[[
	What the dedicated grenade key throws.

	Halo had a grenade button separate from the weapon in your hands, so you
	could throw one mid-fight without giving up your rifle for it.
]]
Config.GrenadeKeyWeapon = "Grenade"

--[[
	You are always armed.

	This is the shape of the whole game: a shooter with sports scattered
	through it -- the lazy river, the ski run, the hang glider, the hockey
	rink -- and you can shoot people while playing any of them. No gear, no
	seat and no minigame may ever take your weapons away.

	It is here as a flag rather than only as a convention so that the sanity
	test can assert it, and so that anybody adding the next sport reads it
	before they add a "you cannot shoot while..." check.
]]
Config.WeaponsAlwaysAvailable = true

--[[
	Moving about on foot.

	Set on every spawn. These used to be left at Roblox's defaults, which is
	a 16-stud-a-second walk and a 50 jump -- fine for an obby, a plod across
	a two-thousand-stud arena.
]]
--[[
	Computer players.

	A venue with nobody in it is worse than no venue at all, and on a quiet
	server that is every venue -- so every sub-game fills itself out with
	bots. They are shootable and worth points, because the rule here is that
	you can shoot anybody at any time, the goalie included.
]]
--[[
	The sub-games.

	Two ways in, on purpose: a menu key from anywhere, and a prompt when you
	walk into a venue. Nobody should have to cross a 2000-stud map to find
	out what is in the corner of it, and nobody who is already standing on a
	basketball court should have to open a menu to use it.
]]
--[[
	The fairground.

	Seven stalls now. The payouts are deliberately uneven: a single balloon
	is worth almost nothing and clearing a whole board is worth a kill, which
	is what makes a stall worth standing at rather than walking past.
]]
--[[
	How hard a shot hits something that is not a player.

	A rocket's Damage is zero -- all of its damage is the blast -- so reading
	Damage alone makes the loudest weapon in the game the feeblest thing you
	can hit a high striker with. Anything scoring a shot by its force wants
	this rather than the raw field.
]]
--[[
	How much to slow a player down, and how much to fine the mouse, for a
	given magnification.

	Both live here rather than in the client because both are the same
	judgement -- how much a sight should cost -- and because the server needs
	the speed half of it. A 1.3x hold costs almost nothing; a 50x scope costs
	you standing still.
]]
function Config.ZoomSpeedFactor(magnification: number): number
	local span = math.max(Config.Movement.ScopedSlowAt - 1, 0.001)
	local t = math.clamp((magnification - 1) / span, 0, 1)
	return 1 + (Config.Movement.ScopedSpeedFactor - 1) * t
end

function Config.ZoomSensitivity(magnification: number): number
	if magnification <= 1 then
		return 1
	end
	for _, band in Config.Visuals.ScopedSensitivity do
		if magnification <= band.upTo then
			return band.factor
		end
	end
	return 1
end

function Config.ShotPower(spec: { Damage: number?, BlastDamage: number? }): number
	return math.max(spec.Damage or 0, spec.BlastDamage or 0)
end

Config.Carnival = {
	BalloonPoints = 12,
	BalloonClearBonus = 240,
	BottlePoints = 20,
	BottleStackBonus = 180,
	MolePoints = 35,
	-- How long a whacked mole stays down before it dares come back.
	MoleDownSeconds = 2.4,
	MoleUpSeconds = 1.9,
	CratePoints = 15,
	CrateStackBonus = 300,
	CannonCooldown = 2.2,
	--[[
		The high striker reads the gun you shot it with.

		StrikerFullPower is the shot power that sends the puck all the way to
		the bell. Set just under the anti-tank rifle's 62 so one hitscan
		weapon in the game can ring it cleanly, with every explosive doing it
		too -- the reward for carrying the heaviest thing you own across the
		fairground. The weakest throw stops the submachine gun looking
		broken: the puck still leaves the pad.
	]]
	StrikerFullPower = 58,
	StrikerWeakestThrow = 0.16,
	-- Long enough for the puck to fly and settle before the next shot counts.
	StrikerCooldown = 1.6,
	-- How long before a cleared stall sets itself up again.
	ResetSeconds = 5,
}

Config.Arcade = {
	-- A pillar of light over every activity. Tall enough to clear the
	-- tallest tower so it is visible from the far side of the map, which is
	-- the entire point of it.
	BeaconHeight = 420,
	-- Past this the name is clutter; the colour alone still reads.
	BeaconNameDistance = 900,
	--[[
		How long you can stand in an empty venue before it fills itself.

		Short, because the failure it fixes is standing on an empty sheet of
		ice wondering whether the game is broken -- and that judgement is
		made in a couple of seconds, not a minute. Long enough that walking
		across a corner of the rink on your way somewhere does not summon a
		hockey team.
	]]
	SoloFillSeconds = 5,
	-- How close you have to be for a venue to offer you a game.
	OfferRadius = 150,
	-- And how long before it asks again, if you said no or ignored it.
	ReofferSeconds = 45,
}

--[[
	The goalie.

	Named, numbered and stationary, which is three things no other bot is.
	A goalie that chases the puck is not a goalie, it is a fifth skater --
	so this one holds its crease and only shuffles sideways to stay between
	the puck and the net. That is both the correct behaviour and the cheaper
	one, since it never needs to path anywhere.

	Both nets get a Milo. Two of him, one at each end, which is funnier than
	picking a side.
]]
--[[
	Basketball.

	The charged shot is the whole sport here: a tap drops the ball at your
	feet, a full wind-up sails over the backboard, and the useful shot is
	somewhere in between. That makes shooting a judgement rather than a
	button, which is the only way a basketball court earns its place in a
	shooter -- and the wind-up is timed on the server, because a client that
	simply announced "full power" would be claiming a wind-up it never
	waited through.

	Lift scales WITH the throw rather than being a constant. A constant lift
	makes a soft shot float and a hard one skim, so the arc would change
	shape at every power and aiming would be unlearnable.
]]
--[[
	Bowling.

	Scored per BALL rather than over ten frames, which is a deliberate
	departure from how the sport works. Ten frames is a ten-minute
	commitment and this map's round is already the clock -- a player locked
	into a game longer than the round is a player who cannot be shot at,
	which is the one thing no activity here is allowed to be.

	The second ball at a gap is kept, though, because that is the only part
	of the structure that changes the shot: picking off two pins at the back
	is a different and harder problem than hitting a full rack.

	The oil is the feel of the sport. Friction near zero is why a bowling
	ball slides and hooks rather than rolling to a stop in six feet.
]]
Config.Bowling = {
	Lanes = 2,
	LaneLength = 150,
	LaneWidth = 16,
	PinSpacing = 4.2,
	PinHeight = 5,

	PickupRange = 12,
	FullChargeSeconds = 1,
	RollSpeed = 150,
	--[[
		How long after the roll the pins are counted.

		A fixed delay rather than waiting for stillness: a ball in the
		gutter never stops and a strike dead centre stops almost at once, so
		waiting would mean a different delay for every roll and none at all
		for the worst ones.
	]]
	SettleSeconds = 3.5,

	-- A pin is down when it has tipped past this, or been knocked this far
	-- off its spot. Tilt catches the ones that matter; height alone would
	-- miss a pin shunted flat along the deck.
	DownTilt = 0.72,
	DownDistance = 3.5,

	PointsPerPin = 12,
	StrikeBonus = 120,
	SpareBonus = 60,
}

--[[
	Where each venue sits, as fractions of the map size.

	One place, because this answer is needed TWICE for every venue and in
	two different modules: the venue itself needs it to know where to build,
	and MapService needs it to keep the city off that ground -- and
	MapService has to know before the venue exists, since most of them are
	built after the city is laid out.

	It was hardcoded in both places, which is how the carnival ended up with
	buildings in it: its builder knew where it was and the city did not.
	The basketball court and bowling alley then arrived with the same split,
	because nothing connected the two numbers.

	Spread deliberately around the compass so the distractions are in
	different directions from the middle rather than clustered.
]]
Config.Venues = {
	Carnival = { x = 0.3, z = 0, radius = 120 },
	Hockey = { x = -0.3, z = 0.06, radius = 180 },
	Basketball = { x = 0.28, z = -0.22, radius = 90 },
	Bowling = { x = -0.26, z = -0.24, radius = 115 },
}

--[[ Where a venue is on a map of this size. ]]
function Config.VenueCentre(name: string, mapSize: number): Vector3
	local spot = Config.Venues[name]
	if not spot then
		return Vector3.new()
	end
	return Vector3.new(mapSize * spot.x, 0, mapSize * spot.z)
end

Config.Basketball = {
	CourtWidth = 70,
	CourtLength = 120,
	-- Far enough out that a three is a decision, close enough that it is
	-- not a novelty.
	ThreeLine = 30,
	TwoPoints = 45,
	ThreePoints = 80,

	PickupRange = 8,
	CarryDistance = 4,
	-- Cannot scoop up your own shot instantly, or a tap next to the hoop
	-- becomes an infinite dunk.
	ReclaimDelay = 0.9,

	FullChargeSeconds = 1.1,
	ThrowSpeed = 95,
	LiftFactor = 0.55,
	-- How hard a bullet shoves the ball. Shooting it is legitimate: a rifle
	-- makes a perfectly good pass.
	ShotNudge = 60,
}

Config.Goalie = {
	Name = "Milo",
	Number = 29,
	-- How far off his line he will drift to track the puck. Small on
	-- purpose: a goalie who wanders is a goalie who gets scored on.
	SideToSide = 11,
	-- How quickly he tracks across. Fast enough to cover a pass, slow
	-- enough that a hard shot to the far corner beats him.
	TrackSpeed = 14,
}

--[[
	Target dummies.

	The point of these is that every toy in this game needs something to try
	it on. A sniper with a 50x scope, a gas trail, a land mine and a winch
	are all things you want to TEST, and testing them on the only other
	player in the server is how you lose the only other player in the
	server. So there are a few wanderers by the carnival, where the shooting
	gallery already is, who come back when you kill them.

	They wander rather than stand still because a stationary target teaches
	you nothing about leading a shot, which is the whole skill a long scope
	asks for.
]]
Config.Dummies = {
	Count = 4,
	-- How far from their post they will stray, and how often they pick a
	-- new spot. Slow enough to hit, moving enough to have to aim.
	Radius = 46,
	WanderSeconds = 4,
}

Config.Bots = {
	Health = 70,
	WalkSpeed = 20,
	Points = 60,
	RespawnDelay = 9,
	-- How often a bot reconsiders. Four times a second looks identical to
	-- sixty and costs a fifteenth as much, which matters at twenty bots.
	ThinkInterval = 0.25,
}

--[[
	How readable the fight is.

	Both of these are about what one pair of eyes can see rather than about
	the world, so they are applied on the client -- but they live here
	because the scope code tweens BACK to the base field of view, and two
	places disagreeing about what that is shows up as a scope that un-zooms
	to the wrong place.
]]
--[[
	The help panel's contents.

	This exists because of a specific play-test complaint -- "I cannot
	figure out how to play the different games" -- and that complaint is the
	whole specification. A 2000-stud map with a dozen activities and three
	keys that mean different things in each of them is unlearnable by
	exploration alone.

	Every entry describes something that EXISTS. The temptation with a help
	file is to write it from the plan rather than from the game, which
	produces instructions for features nobody can find -- worse than no help
	at all, because it makes the player hunt for something that is not
	there. Entries get added as systems land, not before.

	The keywords are what the search box matches on, so they include the
	words a player would actually type, including the wrong ones: "gun" for
	the weapon list, "stuck" for the winch, "lost" for travel.
]]
Config.Help = {
	{
		question = "How do I find the different games?",
		answer = "Press B for the menu and pick one -- it takes you straight there "
			.. "and fills the teams out with bots. Or look for the coloured pillars "
			.. "of light: there is one over every activity on the map.",
		keywords = { "games", "lost", "menu", "find", "where", "travel", "beacon", "sub" },
	},
	{
		question = "What do the keys along the bottom of the screen mean?",
		answer = "Those are the keys that are live RIGHT NOW. They change depending on "
			.. "what you are doing, so Q is your melee on foot, your guard in a "
			.. "fight and your drivetrain in a truck. The strip always shows the "
			.. "current set.",
		keywords = { "keys", "controls", "buttons", "bar", "bottom", "strip", "bind" },
	},
	{
		question = "How do I shoot and switch weapons?",
		answer = "Left click fires, R reloads, and the number keys 1 to 7 pick a "
			.. "weapon. G throws a grenade without changing what is in your hands. "
			.. "F sets off a diamond round.",
		keywords = { "shoot", "gun", "fire", "weapon", "reload", "grenade", "nade", "switch" },
	},
	{
		question = "How does the sniper zoom work?",
		answer = "Right click to zoom, and keep right clicking to step through the "
			.. "magnifications. Press N while scoped for night vision. Your mouse "
			.. "gets finer the further you zoom, which is the only thing that makes "
			.. "50x usable -- and you move much slower while scoped, which stops it "
			.. "being a free sprinting wallhack.",
		keywords = { "sniper", "zoom", "scope", "rifle", "magnify", "aim" },
	},
	{
		question = "How do I play hockey, and how do fights work?",
		answer = "Skate over the puck to pick it up, then F to shoot it -- or just "
			.. "shoot the loose puck with any gun, which works fine. Get next to an "
			.. "opponent to drop the gloves. In a fight: F punches, hold Q to guard. "
			.. "Punching into a raised guard barely hurts, so watch for theirs to "
			.. "drop. Your gun works the whole time, and X leaves a game.",
		keywords = { "hockey", "ice", "puck", "fight", "punch", "block", "guard", "stick", "rink" },
	},
	{
		question = "How do I ski, snowboard or ride a tube?",
		answer = "Take the chairlift or drive an off-roader up the mountain, then "
			.. "grab gear from the rack at the summit. E shoves and boosts, space "
			.. "bails out. Hit the table-top jumps for tricks -- spin in the air and "
			.. "it scores. Crossing the line at the bottom scores the run, and first "
			.. "one down gets a bonus. A tube goes off the bottom into the river.",
		keywords = { "ski", "snowboard", "tube", "mountain", "jump", "trick", "slope", "river", "bike" },
	},
	{
		question = "How do I hang glide?",
		answer = "Grab a glider at the summit and run off the edge. W dives for speed, "
			.. "S climbs. Your guns work in the air, which is the point of being up "
			.. "there. Space pops a parachute if you get shot down.",
		keywords = { "glide", "glider", "hang", "fly", "air", "parachute", "bail" },
	},
	{
		question = "How do I drive, and what if I get stuck?",
		answer = "WASD drives, shift is turbo, space bails out. On something fitted "
			.. "for it: Q changes drivetrain, E locks the diff, C hooks the winch to "
			.. "a tree and holding X reels you out of the mud.",
		keywords = { "drive", "car", "truck", "vehicle", "stuck", "winch", "mud", "diff", "4wd", "gear" },
	},
	{
		question = "Can I kick someone I just dropped?",
		answer = "Yes. Stand next to somebody who went down in the last few seconds "
			.. "and press Q -- the melee key kicks them instead of swinging. It does "
			.. "no damage at all and they get told about it, which is the whole "
			.. "point.",
		keywords = { "kick", "dead", "body", "corpse", "shove", "melee", "taunt", "low" },
	},
	{
		question = "What are the blinking metal discs?",
		answer = "Land mines. Step or drive on one and it goes off, then throws a "
			.. "fireball into the sky that explodes again wherever it comes down -- "
			.. "so the second bang is somewhere nobody can predict. The red light "
			.. "blinking on top is your warning.",
		keywords = { "mine", "mines", "landmine", "disc", "blinking", "fireball", "explode", "bomb" },
	},
	{
		question = "How do I play basketball?",
		answer = "Walk into the ball to pick it up, then HOLD F to wind up and let go "
			.. "to shoot -- a tap drops it at your feet and a full charge sails over, "
			.. "so the useful shot is in between. Behind the painted arc is worth "
			.. "three. You can also just shoot the ball with a gun.",
		keywords = { "basketball", "hoop", "ball", "court", "dunk", "three", "shoot" },
	},
	{
		question = "How do I bowl?",
		answer = "Walk up to a ball at the end of a lane, HOLD F to wind up and let go "
			.. "to roll -- you aim where you look, and the lane is oiled so the ball "
			.. "slides. Ten pins; clear them all for a strike. Any pins left get a "
			.. "second ball. Shooting the ball down the lane also counts.",
		keywords = { "bowling", "bowl", "pins", "lane", "strike", "spare", "ball", "alley" },
	},
	{
		question = "What is there at the carnival?",
		answer = "Seven stalls, all played by shooting them: a dunk tank, a duck "
			.. "gallery, a high striker, a balloon board, milk bottles, whack-a-mole "
			.. "and a cannon range. Clearing a whole board pays a bonus.",
		keywords = { "carnival", "fair", "stall", "dunk", "duck", "balloon", "bottle", "mole", "cannon" },
	},
}

Config.Visuals = {
	-- Wider than Roblox's 70. More of the map on screen and a stronger
	-- sense of speed, which is most of why a modern shooter feels quick.
	BaseFieldOfView = 75,
	-- Enemies and team-mates are told apart by colour, not just by having
	-- an outline. Knowing somebody is there is half the information;
	-- knowing whether to shoot them is the other half. These match the
	-- motion tracker's colours so the two readouts never disagree.
	EnemyOutline = Color3.fromRGB(255, 70, 70),
	FriendlyOutline = Color3.fromRGB(90, 230, 140),
	OutlineTransparency = 0.15,

	--[[
		Night vision, down the scope only.

		Parented to the CAMERA rather than to Lighting, which is not a
		workaround for the rule that GraphicsService owns Lighting -- it is
		the correct place for it. An effect on the camera applies to one
		viewer by construction, so there is no way for it to leak into
		anybody else's screen, and no way for two scripts to fight over it.
		Night vision on everyone's screen because one player scoped in would
		be a strange bug to debug.

		The tint is green because that is what the convention is, and the
		contrast lift is what actually does the work: brightening alone
		turns a dark scene grey.
	]]
	NightVisionTint = Color3.fromRGB(140, 255, 190),
	NightVisionBrightness = 0.25,
	NightVisionContrast = 0.3,

	--[[
		Mouse sensitivity down the sight.

		At 50x, one pixel of mouse movement is a wall-to-wall sweep of the
		target, which is why a long scope feels unusable rather than
		powerful. Scaling the sensitivity with the magnification is what
		makes the top zoom level worth having at all.

		Keyed by zoom STAGE rather than by magnification, because the stages
		are what the player steps through.
	]]
	--[[
		How much finer the mouse gets when you are zoomed in.

		Read against MAGNIFICATION, not against which click of the scope you
		are on: the first band whose `upTo` covers your magnification wins.
		Indexing by the stage number was fine while only the long scopes had
		sights, because stage 1 always meant 5x or 6x -- but now every gun
		has one, and stage 1 on a submachine gun is 1.3x. Cutting the mouse
		to 45% for that would make aiming down a red dot feel like dragging
		it through treacle.

		The sniper's three clicks still land on exactly the values they were
		tuned to: 5x on 0.45, 10x on 0.22, 50x on 0.1.
	]]
	ScopedSensitivity = {
		{ upTo = 1.4, factor = 0.9 },
		{ upTo = 2.5, factor = 0.7 },
		{ upTo = 4, factor = 0.55 },
		{ upTo = 7, factor = 0.45 },
		{ upTo = 12, factor = 0.22 },
		{ upTo = math.huge, factor = 0.1 },
	},
}

--[[
	Riding: skis, snowboard, tube, bike.

	The boost is always worth pressing, which is deliberate -- at 80 studs a
	second down a mountain there is no time to agonise over a decision. What
	makes it interesting is that it is worth MORE next to somebody, because
	the same key shoves them off their line. That is what makes two people on
	the same hill a race rather than two solo runs.

	The shove is sideways and up, not forwards: the point is to put them into
	a tree, not to kill them. Shooting them is already available.
]]
--[[
	Petrol, and things burning.

	The numbers are tuned around one idea: pouring is a PLAN, not a weapon.
	A puddle takes a fifth of a can and goes down slowly, so laying a trail
	across a doorway costs you the fight you would otherwise be having --
	and an unlit one evaporates, so it has to be a plan you follow through.

	BurnDamage is per half-second, so standing in it is survivable for a
	moment and fatal if you panic and run the wrong way. That is the
	intended feeling: fire is an area you must leave, not an instant kill.
]]
Config.Fire = {
	CanFuel = 100,
	FuelPerPuddle = 20,
	PourInterval = 0.18,
	PuddleSize = 4.2,
	-- Unlit petrol evaporates, or twenty players pouring for ten minutes
	-- leaves the map permanently ankle-deep in it.
	PuddleLifetime = 60,

	-- Fire jumps between puddles this close, after a readable pause. The
	-- pause is what turns a line of puddles into a fuse you can watch
	-- travel rather than one long explosion.
	SpreadRadius = 7,
	SpreadDelay = 0.18,

	LightRange = 14,
	BurnSeconds = 12,
	BurnInterval = 0.5,
	BurnRadius = 3.4,
	BurnDamage = 8,

	--[[
		Cans come in small CLUSTERS, not spread evenly.

		They were on a ring of ten, which put them 310 studs apart -- so the
		chain reaction could never once fire between two map-spawned cans.
		The code for it was dead and the "chain reaction" idea was
		unachievable, which is the kind of thing that looks finished and is
		not. A huddle of three is a bomb worth shooting and a landmark worth
		remembering; a lone can is neither.
	]]
	CanClusters = 5,
	CansPerCluster = 3,
	ClusterSpread = 9,
	CanRingFactor = 0.26,
	CanRespawnSeconds = 18,
	CanBlastRadius = 18,
	CanBlastDamage = 72,
	CanVehicleMultiplier = 1.6,
	CanChainRadius = 18,
	ChainDelay = 0.15,
	-- A cluster of cans must not recurse forever.
	MaxChainDepth = 6,

	--[[
		Land mines.

		The blinking light is what makes these fair rather than cruel. A
		mine you cannot see is a random death; a mine with a red light on it
		is a thing you drove over anyway, which is a completely different
		feeling and a much better one.

		The fireball is the reason they stay interesting after you have
		learned where they are: the mine is predictable and the second blast
		is not, so the hazard does not stop mattering once the map is known.
	]]
	Mines = 8,
	MineRingFactor = 0.4,
	MineBlinkSeconds = 0.45,
	MineBlastRadius = 22,
	MineBlastDamage = 85,
	MineRespawnSeconds = 20,

	FireballLift = 120,
	FireballSpread = 65,
	-- It comes down on a timer, not on contact: the ball leaves the ground
	-- inside a blast that is still expanding, so a contact trigger fires
	-- instantly against whatever launched it.
	FireballFlightSeconds = 3.2,
	FireballBlastRadius = 18,
	FireballBlastDamage = 60,
	ScorchSeconds = 5,
}

--[[
	The ski run as a race, not just a way down.

	The pasted ski battle built a formal 1v1: a queue, a countdown, a
	lockout and a winner. That is the same mistake bowling's ten frames
	would have been -- an activity that takes you out of the round is the
	one thing nothing here is allowed to do, and a queue for two means
	standing about waiting on a mountain with a view of the whole map.

	So instead the run is always open and always timed. Cross the line at
	the bottom and you score for the descent; the first one down since the
	line last went quiet gets the bonus. That keeps the race -- somebody to
	beat, and a reason to take the jumps rather than the safe line -- with
	nothing to join and nothing to wait for.

	The shove and the boost are what make it a fight rather than two solo
	runs, and those already exist.
]]
Config.SkiRace = {
	-- Points for finishing at all, and for being first down.
	FinishPoints = 55,
	FirstDownBonus = 95,
	--[[
		How long the line stays "claimed" after somebody crosses it.

		Short, because the bonus is for winning a race against whoever is on
		the hill WITH you -- not for being the only person who has skied all
		round. Long enough that two people seconds apart are clearly first
		and second.
	]]
	FirstDownSeconds = 25,
	-- Minimum time on the hill to count, so sliding over the line at the
	-- bottom from a standing start is not a free score.
	MinimumRunSeconds = 4,
	FinishWidth = 90,
	--[[
		How far above the line counts as "on the hill".

		By HEIGHT rather than by a start gate at the summit, because people
		drop onto the piste halfway down off the chairlift or a glider, and
		a run that only counted from the very top would quietly refuse most
		of them.
	]]
	MinimumHeightDrop = 120,
}

Config.Riding = {
	BoostSeconds = 1.2,
	BoostMultiplier = 1.5,
	ShoveCooldown = 3.5,
	ShoveRange = 14,
	ShoveForce = 55,
	ShoveLift = 16,
}

--[[
	Kicking somebody who has just gone down.

	Entirely cosmetic and entirely the point. It does no damage, cannot
	finish anyone off and gives no advantage -- it exists because standing
	over somebody you just dropped and giving them a shove is a thing people
	do in shooters, and because it is funny.

	It is on the MELEE key rather than a key of its own. There is no
	situation where you would rather swing at a corpse than kick it, so the
	same key doing the right thing by context is better than a binding
	nobody remembers. A swing at a live opponent is still a swing.

	The window is short on purpose. Five seconds is long enough to walk over
	and do it, and short enough that bodies lying around the map are not a
	permanent invitation -- which would make it tedious rather than funny.
]]
Config.Kick = {
	Range = 11,
	DeathWindow = 5,
	Cooldown = 1.2,
	-- The shove. Sideways and up, so they tumble rather than slide.
	Force = 28,
	Lift = 18,
	-- Worth a couple of points, because it is a flourish and not an
	-- achievement. Enough that you notice; not enough to farm.
	Points = 5,
}

--[[
	Below this, you are falling and not coming back.

	One number, used by both the thing that kills you for leaving the map
	and the things that have to decide what to do with whatever you were
	holding when you did. It was written as a bare -120 in MatchService,
	which meant anything else needing the same answer had to guess it.
]]
Config.VoidHeight = -120

Config.Movement = {
	JumpPower = 62,
	-- How much a headshot multiplies damage by. Was hardcoded in two
	-- separate places, which is one place too many for a number anybody
	-- would want to tune.
	HeadshotMultiplier = 1.8,
	--[[
		Scoped, you move at a fraction of walking pace.

		It is the thing that stops a 50x scope being a free sprinting
		wallhack, and it is what makes committing to a shot feel like
		committing. It is also far too much to charge for a 1.3x red dot,
		which is why the penalty now arrives gradually: full speed at 1x,
		the full slowdown from ScopedSlowAt upwards, interpolated between.

		Before every gun had a sight this did not matter, because the only
		things that zoomed were the two long scopes.
	]]
	ScopedSpeedFactor = 0.42,
	ScopedSlowAt = 5,
}

--[[
	The ice rink.

	Hockey is scored like everything else, in team points, so a goal is worth
	putting the work in for -- and a fight is worth starting. Note that
	nothing here disables anybody's guns, which is the rule for every sport
	on this map: you can shoot your way out of a fight, or shoot two other
	people having one.
]]
Config.Hockey = {
	GoalPoints = 220,
	-- How long both players mash for. Short enough to be a scrap rather
	-- than a minigame you get stuck in.
	FightSeconds = 4,
	FightWinPoints = 130,
	KnockdownSeconds = 2.5,
	-- Blades of Steel. Breaking it is the point of fighting at all, because
	-- the splintered half is the best melee weapon in the game.
	StickBreakChance = 0.55,
	StickWeapon = "HockeyStick",
	-- Possession: how close you have to be to pick the puck up, how far in
	-- front of you it rides, and how hard you can shoot it.
	PickupRange = 9,
	CarryDistance = 4.5,
	ShotSpeed = 110,
	-- A fight is a punch-and-block contest now rather than a mash. These are
	-- its numbers.
	FightHealth = 100,
	PunchCooldown = 0.45,
	PunchDamageMin = 16,
	PunchDamageMax = 24,
	BlockedDamage = 5,
	PenaltySeconds = 10,
	BrokenStickWeapon = "BrokenStick",
}

Config.Radar = {
	Range = 170,
	-- Contacts further above or below than this are off the dial entirely.
	-- Without it a player on a fifth-floor roof shows as standing on you.
	VerticalRange = 60,
}

--[[
	Boost arrows: chevrons painted on the approach to every jump. Drive over
	them and you are flung up to this speed, which is what turns a ramp into
	serious air.
]]
Config.Boost = {
	-- Horizontal only. This used to be 190, which fired a truck off the
	-- following ramp like a trampoline; the arrows are meant to make you
	-- quick along the ground, and the ramp decides how much air you get.
	Speed = 118,
	Lift = 0,
}

--[[ The mega-detonation. Press F while a diamond bullet is still flying. ]]
Config.Mega = {
	Multiplier = 10,
	FreeChargesPerLife = 3,
	CraterDepth = 6,
}

-- ================================================================ VEHICLES ==

--[[
	Ground cars you unlock by collecting keys, which drop from every player
	you eliminate.
]]
Config.CarTiers = {
	{ Name = "Rust Bucket", KeysRequired = 0, MaxSpeed = 75, Torque = 12000, TurnSpeed = 39, Color = Color3.fromRGB(120, 100, 80) },
	{ Name = "Mud Runner", KeysRequired = 2, MaxSpeed = 102, Torque = 17000, TurnSpeed = 44, Color = Color3.fromRGB(80, 130, 90) },
	{ Name = "Swamp Devil", KeysRequired = 5, MaxSpeed = 130, Torque = 22000, TurnSpeed = 49, Color = Color3.fromRGB(180, 120, 40) },
	{ Name = "Nuclear Hauler", KeysRequired = 9, MaxSpeed = 162, Torque = 28000, TurnSpeed = 54, Color = Color3.fromRGB(90, 210, 220) },
}

--[[
	The big toys. These sit on the map at marked pads and respawn after use,
	so there is always one to grab.
]]
Config.Vehicles = {
	Warthog = {
		DisplayName = "Turret Truck",
		-- Two seats: one drives, one spins the 50 cal on the back.
		Seats = 2,
		MaxSpeed = 78, Torque = 20000, TurnSpeed = 32,
		Health = 500,
		MountedWeapon = "FiftyCal",
		Color = Color3.fromRGB(96, 108, 78),
		RespawnDelay = 30,
	},
	Tank = {
		DisplayName = "Tank",
		Seats = 2,
		MaxSpeed = 44, Torque = 45000, TurnSpeed = 18,
		Health = 1400,
		MountedWeapon = "TankCannon",
		Color = Color3.fromRGB(74, 84, 66),
		RespawnDelay = 60,
		-- Shrugs off small arms.
		DamageResistance = 0.35,
	},
	Plane = {
		DisplayName = "Crop Duster",
		Seats = 1,
		-- Arcade flight: these are the numbers that make it feel good.
		FlySpeed = 180,
		MinFlySpeed = 60,
		PitchRate = 1.4,
		RollRate = 2.2,
		YawRate = 0.8,
		Health = 320,
		MountedWeapon = "PlaneGun",
		Color = Color3.fromRGB(200, 190, 150),
		RespawnDelay = 45,
	},
	Torpedo = {
		DisplayName = "Rideable Torpedo",
		Seats = 1,
		-- You sit on it like a horse and steer it into someone.
		Speed = 150,
		TurnRate = 1.6,
		Health = 60,
		BlastRadius = 45,
		BlastDamage = 200,
		-- It dies on its own after this long, with you on it.
		Lifetime = 20,
		Color = Color3.fromRGB(180, 60, 60),
		RespawnDelay = 40,
	},
}

Config.MudSpeedFactor = 0.55

--[[
	Turbo. Hold Left Shift.

	In a vehicle it multiplies your speed; on foot it makes you sprint. Same
	key either way, so it always just means "go faster".
]]
Config.Turbo = {
	Multiplier = 1.9,
	WalkSpeed = 24,
	SprintWalkSpeed = 42,
}

--[[
	The two cars that spawn beside you. Which one you get is a coin flip.

	The truck is slower but heavy and sits high; the Lamborghini is quick and
	low. Both use the same tier speeds, so the choice is feel, not advantage.
]]
--[[
	Car bodies.

	`OffRoad` bodies get a climb assist in driveWheeled, which is what lets
	them take the mountain trail. Without it the drive direction is flattened
	dead horizontal -- deliberately, because a non-flattened one is what used
	to launch trucks into the sky -- and a horizontal push cannot get you up
	anything steep.
]]
Config.CarBodies = {
	{
		Name = "Truck",
		Size = Vector3.new(11, 5, 20),
		RideHeight = 4,
		SpeedBias = 0.92,
		Color = Color3.fromRGB(120, 100, 80),
	},
	{
		Name = "Lamborghini",
		Size = Vector3.new(10, 2.6, 19),
		RideHeight = 2,
		SpeedBias = 1.15,
		Color = Color3.fromRGB(240, 190, 30),
	},
	-- The off-roaders. Slower on the flat, and the only things that will get
	-- you up the mountain trail under fire.
	{
		Name = "G-Wagon",
		Size = Vector3.new(11, 6, 18),
		RideHeight = 5,
		SpeedBias = 0.88,
		OffRoad = true,
		ClimbAssist = 0.42,
		Color = Color3.fromRGB(40, 42, 46),
	},
	{
		Name = "Hummer",
		Size = Vector3.new(13, 6.4, 20),
		RideHeight = 5.5,
		SpeedBias = 0.8,
		OffRoad = true,
		ClimbAssist = 0.5,
		Color = Color3.fromRGB(168, 160, 120),
	},
	{
		Name = "Jeep",
		Size = Vector3.new(10, 5.4, 17),
		RideHeight = 4.6,
		SpeedBias = 0.95,
		OffRoad = true,
		ClimbAssist = 0.38,
		Color = Color3.fromRGB(70, 110, 72),
	},
}

-- ================================================================= PICKUPS ==

Config.Pickups = {
	RespawnDelay = 25,
	Burger = { DisplayName = "Invincibility Burger", Duration = 10, Color = Color3.fromRGB(200, 140, 60) },
	Fries = { DisplayName = "Triple-Gun Fries", Duration = 15, Barrels = 3, SpreadDegrees = 7, Color = Color3.fromRGB(240, 200, 70) },
	Shield = { DisplayName = "Shield Cell", Amount = 50, Color = Color3.fromRGB(90, 180, 240) },
	Ammo = { DisplayName = "Ammo Crate", Color = Color3.fromRGB(140, 120, 70) },
	-- Hidden ones. These are tucked inside buildings and behind cover rather
	-- than sitting out on the open pads.
	Health = { DisplayName = "Health Pack", Color = Color3.fromRGB(240, 90, 110) },
	Invincibility = {
		DisplayName = "Invincibility Shield",
		Duration = 20,
		Color = Color3.fromRGB(190, 140, 255),
	},
	PoopAmmo = { DisplayName = "Poop", Color = Color3.fromRGB(92, 64, 38) },
	DroneAmmo = { DisplayName = "Hunter Drone", Color = Color3.fromRGB(120, 205, 255) },
	Multiplier = {
		DisplayName = "Double Points",
		Duration = 90,
		Amount = 3,
		Color = Color3.fromRGB(255, 215, 70),
	},
}

-- ================================================================= EFFECTS ==

--[[
	The silly stuff. All visual — no audio IDs are baked in, because a wrong
	audio ID throws a real error at runtime. The playbook shows you where to
	drop Toolbox sounds in.
]]
Config.Effects = {
	GagChance = 0.35,
	DeathScreenDuration = 2.5,
	WienerDuration = 8,
	Gags = { "Donkey", "Unicorn", "Cat" },
}

-- ==================================================================== MAPS ==

--[[
	Ten maps, each generated from these numbers at runtime. Every one is fully
	drivable — the buildings have ramps to their roofs and the jumps are built
	for four wheels, not for feet.
]]
Config.Maps = {
	{ Id = "BogBasin", Name = "Bog Basin", Size = 1900, MudFraction = 0.55, Buildings = 22, Jumps = 8, Ramps = 10, Theme = Color3.fromRGB(96, 78, 52) },
	{ Id = "DiamondQuarry", Name = "Diamond Quarry", Size = 2050, MudFraction = 0.25, Buildings = 28, Jumps = 12, Ramps = 14, Theme = Color3.fromRGB(150, 160, 170) },
	{ Id = "SwampCircuit", Name = "Swamp Circuit", Size = 1950, MudFraction = 0.6, Buildings = 18, Jumps = 14, Ramps = 12, Theme = Color3.fromRGB(70, 96, 66) },
	{ Id = "RustyOverpass", Name = "Rusty Overpass", Size = 1900, MudFraction = 0.2, Buildings = 30, Jumps = 16, Ramps = 18, Theme = Color3.fromRGB(140, 84, 56) },
	{ Id = "GatorCreek", Name = "Gator Creek", Size = 1950, MudFraction = 0.7, Buildings = 20, Jumps = 9, Ramps = 10, Theme = Color3.fromRGB(64, 88, 74) },
	{ Id = "FalloutFlats", Name = "Fallout Flats", Size = 2150, MudFraction = 0.15, Buildings = 26, Jumps = 10, Ramps = 8, Theme = Color3.fromRGB(122, 122, 96) },
	{ Id = "HollerHills", Name = "Holler Hills", Size = 2000, MudFraction = 0.45, Buildings = 22, Jumps = 18, Ramps = 16, Theme = Color3.fromRGB(88, 110, 70) },
	{ Id = "ScrapyardSprint", Name = "Scrapyard Sprint", Size = 1900, MudFraction = 0.3, Buildings = 32, Jumps = 11, Ramps = 20, Theme = Color3.fromRGB(110, 100, 106) },
	{ Id = "MoonshineMile", Name = "Moonshine Mile", Size = 2200, MudFraction = 0.35, Buildings = 24, Jumps = 20, Ramps = 12, Theme = Color3.fromRGB(104, 92, 64) },
	{ Id = "ReactorRidge", Name = "Reactor Ridge", Size = 2050, MudFraction = 0.4, Buildings = 29, Jumps = 13, Ramps = 15, Theme = Color3.fromRGB(74, 130, 132) },
}

Config.Teams = {
	{ Name = "Red Mud", Color = BrickColor.new("Bright red") },
	{ Name = "Blue Mud", Color = BrickColor.new("Bright blue") },
}

Config.DataStoreName = "NuclearMudArena_PlayerData_v1"

-- =================================================================== TYPES ==
--[[
	The shapes above, written down so the editor can catch a typo in a weapon
	name before the game ever runs. Optional fields end in `?` — a pistol has
	no BlastRadius and that is fine.
]]

export type WeaponSpec = {
	Slot: number,
	Category: string,
	DisplayName: string,
	Kind: string,
	Damage: number,
	Cooldown: number,
	Recoil: number?, -- camera kick in degrees, per shot
	Range: number,
	MagSize: number,
	ReloadTime: number,
	Spread: number,
	Color: Color3,

	Speed: number?,
	Pellets: number?,
	Automatic: boolean?,
	Pierces: number?,
	BlastRadius: number?,
	BlastDamage: number?,
	CanMegaDetonate: boolean?,
	AutoAim: boolean?,
	ZoomFov: number?,
	ZoomLevels: { number }?,
	SemiAutoWhenScoped: boolean?,
	Points: number?,
	Cluster: number?,
	ClusterRadius: number?,
	ClusterDamage: number?,
	FuseTime: number?,
	Sticky: boolean?,
	MountedOnly: boolean?,
	Splat: boolean?,
	AmmoFromPickupsOnly: boolean?,
	HomingTurnRate: number?,
	HomingLifetime: number?,
	VehicleDamageMultiplier: number?,
	MoveSpeedFactor: number?,
}

export type CarTier = {
	Name: string,
	KeysRequired: number,
	MaxSpeed: number,
	Torque: number,
	TurnSpeed: number,
	Color: Color3,
}

export type VehicleSpec = {
	DisplayName: string,
	Seats: number,
	Health: number,
	Color: Color3,
	RespawnDelay: number,

	MaxSpeed: number?,
	Torque: number?,
	TurnSpeed: number?,
	MountedWeapon: string?,
	DamageResistance: number?,
	FlySpeed: number?,
	MinFlySpeed: number?,
	PitchRate: number?,
	RollRate: number?,
	YawRate: number?,
	Speed: number?,
	TurnRate: number?,
	BlastRadius: number?,
	BlastDamage: number?,
	Lifetime: number?,
}

export type MapSpec = {
	Id: string,
	Name: string,
	Size: number,
	MudFraction: number,
	Buildings: number,
	Jumps: number,
	Ramps: number,
	Theme: Color3,
}

export type ConfigType = {
	FreeMode: boolean,
	InfiniteAmmo: boolean,

	GamePasses: { [string]: number },
	Products: { [string]: number },
	ProductGrants: { MegaDetonations: number, InstantTopCarTier: number },

	Modes: { { Id: string, Name: string, Blurb: string, ScoreLimit: number } },
	CTF: {
		CapturePoints: number, FlagTakenPoints: number, FlagReturnPoints: number,
		DroppedReturnDelay: number, RequireOwnFlagHome: boolean,
		CarrierSpeedFactor: number,
	},
	Match: {
		MaxPlayers: number,
		VoteDuration: number,
		RoundDuration: number,
		IntermissionDuration: number,
		MapChoices: number,
		MinPlayers: number,
		ScoreLimit: number,
		PointsPerKill: number,
	},

	Combat: {
		MaxHealth: number,
		ShieldRegenDelay: number,
		ShieldRegenPerSecond: number,
		SpawnProtection: number,
		AutoAimConeDegrees: number,
		AutoAimRange: number,
		AutoAimServerToleranceDegrees: number,
	},

	Weapons: { [string]: WeaponSpec },
	StartingLoadout: { string },

	Mega: { Multiplier: number, FreeChargesPerLife: number, CraterDepth: number },
	Melee: {
		Damage: number, Range: number, Cooldown: number,
		BackstabMultiplier: number, BackstabArc: number,
	},
	Driving: {
		Acceleration: number, BrakeDeceleration: number,
		Coast: number, SteerGripSpeed: number,
		MotorTorque: number, BrakeTorque: number,
		SuspensionHeight: number, SuspensionTravel: number,
		SpringStiffness: number, SpringDamping: number,
		MaxSteerAngle: number, MinSteerAngle: number,
		SteerSpeed: number, SteerTorque: number,
		WheelFriction: number, WheelFrictionWeight: number,
		Modes: { { id: string, label: string, speedBias: number, torqueBias: number, allWheel: boolean } },
		StartingMode: number,
		MudGripFactor: number, DiffLockGripBias: number, DiffLockTorqueBias: number,
		RearSteerFactor: number, HandbrakeGripFactor: number,
		WinchRange: number, WinchReelSpeed: number, WinchMinLength: number,
	},
	Wildlife: {
		ElephantCount: number, ElephantSpeed: number,
		PoopInterval: number, PoopLifetime: number, PoopPerPile: number,
		MaxPoopPiles: number, SplatDuration: number,
	},
	GrenadeKeyWeapon: string,
	WeaponsAlwaysAvailable: boolean,
	Kick: {
		Range: number, DeathWindow: number, Cooldown: number,
		Force: number, Lift: number, Points: number,
	},
	VoidHeight: number,
	Movement: {
		JumpPower: number,
		HeadshotMultiplier: number,
		ScopedSpeedFactor: number,
		ScopedSlowAt: number,
	},
	Help: { { question: string, answer: string, keywords: { string } } },
	Medals: { [string]: { name: string, points: number, sound: string } },
	Fire: {
		CanFuel: number, FuelPerPuddle: number, PourInterval: number,
		PuddleSize: number, PuddleLifetime: number,
		SpreadRadius: number, SpreadDelay: number,
		LightRange: number, BurnSeconds: number, BurnInterval: number,
		BurnRadius: number, BurnDamage: number,
		CanClusters: number, CansPerCluster: number, ClusterSpread: number,
		CanRingFactor: number, CanRespawnSeconds: number,
		CanBlastRadius: number, CanBlastDamage: number,
		CanVehicleMultiplier: number, CanChainRadius: number,
		ChainDelay: number, MaxChainDepth: number,
		Mines: number, MineRingFactor: number, MineBlinkSeconds: number,
		MineBlastRadius: number, MineBlastDamage: number, MineRespawnSeconds: number,
		FireballLift: number, FireballSpread: number,
		FireballFlightSeconds: number, FireballBlastRadius: number,
		FireballBlastDamage: number, ScorchSeconds: number,
	},
	SkiRace: {
		FinishPoints: number, FirstDownBonus: number,
		FirstDownSeconds: number, MinimumRunSeconds: number,
		FinishWidth: number, MinimumHeightDrop: number,
	},
	Riding: {
		BoostSeconds: number, BoostMultiplier: number,
		ShoveCooldown: number, ShoveRange: number,
		ShoveForce: number, ShoveLift: number,
	},
	Visuals: {
		BaseFieldOfView: number,
		EnemyOutline: Color3,
		FriendlyOutline: Color3,
		OutlineTransparency: number,
		NightVisionTint: Color3,
		NightVisionBrightness: number,
		NightVisionContrast: number,
		ScopedSensitivity: { { upTo: number, factor: number } },
	},
	Carnival: {
		BalloonPoints: number, BalloonClearBonus: number,
		BottlePoints: number, BottleStackBonus: number,
		MolePoints: number, MoleDownSeconds: number, MoleUpSeconds: number,
		CratePoints: number, CrateStackBonus: number, CannonCooldown: number,
		ResetSeconds: number,
	},
	Arcade: {
		OfferRadius: number, ReofferSeconds: number,
		BeaconHeight: number, BeaconNameDistance: number,
		SoloFillSeconds: number,
	},
	Bowling: {
		Lanes: number, LaneLength: number, LaneWidth: number,
		PinSpacing: number, PinHeight: number,
		PickupRange: number, FullChargeSeconds: number, RollSpeed: number,
		SettleSeconds: number, DownTilt: number, DownDistance: number,
		PointsPerPin: number, StrikeBonus: number, SpareBonus: number,
	},
	Venues: { [string]: { x: number, z: number, radius: number } },
	VenueCentre: (string, number) -> Vector3,
	Basketball: {
		CourtWidth: number, CourtLength: number, ThreeLine: number,
		TwoPoints: number, ThreePoints: number,
		PickupRange: number, CarryDistance: number, ReclaimDelay: number,
		FullChargeSeconds: number, ThrowSpeed: number, LiftFactor: number,
		ShotNudge: number,
	},
	Goalie: { Name: string, Number: number, SideToSide: number, TrackSpeed: number },
	Dummies: { Count: number, Radius: number, WanderSeconds: number },
	Bots: {
		Health: number,
		WalkSpeed: number,
		Points: number,
		RespawnDelay: number,
		ThinkInterval: number,
	},
	Hockey: {
		GoalPoints: number,
		FightSeconds: number,
		FightWinPoints: number,
		KnockdownSeconds: number,
		StickBreakChance: number,
		StickWeapon: string,
		PickupRange: number, CarryDistance: number, ShotSpeed: number,
		FightHealth: number, PunchCooldown: number,
		PunchDamageMin: number, PunchDamageMax: number,
		BlockedDamage: number, PenaltySeconds: number,
		BrokenStickWeapon: string,
	},
	Radar: {
		Range: number,
		VerticalRange: number,
	},
	Boost: { Speed: number, Lift: number },
	Population: {
		Zombies: number, Civilians: number, Targets: number,
		StepHeight: number,
		ZombieHealth: number, ZombieSpeed: number, ZombiePoints: number,
		ZombieReach: number, ZombieDamage: number,
		CivilianHealth: number, CivilianSpeed: number, CivilianPoints: number,
		TargetHealth: number, TargetPoints: number,
		RespawnDelay: number,
	},
	CivilianLines: { string },
	Sounds: {
		[string]: {
			Asset: string, Volume: number,
			Pitch: { number }, Looped: boolean?,
		}
	},

	CarTiers: { CarTier },
	Turbo: { Multiplier: number, WalkSpeed: number, SprintWalkSpeed: number },
	CarBodies: {
		{
			Name: string,
			Size: Vector3,
			RideHeight: number,
			SpeedBias: number,
			Color: Color3,
			OffRoad: boolean?,
			ClimbAssist: number?,
		}
	},
	Vehicles: { [string]: VehicleSpec },
	MudSpeedFactor: number,

	Pickups: {
		RespawnDelay: number,
		Burger: { DisplayName: string, Duration: number, Color: Color3 },
		Fries: { DisplayName: string, Duration: number, Barrels: number, SpreadDegrees: number, Color: Color3 },
		Shield: { DisplayName: string, Amount: number, Color: Color3 },
		Ammo: { DisplayName: string, Color: Color3 },
		Health: { DisplayName: string, Color: Color3 },
		Invincibility: { DisplayName: string, Duration: number, Color: Color3 },
		PoopAmmo: { DisplayName: string, Color: Color3 },
		DroneAmmo: { DisplayName: string, Color: Color3 },
		Multiplier: { DisplayName: string, Duration: number, Amount: number, Color: Color3 },
	},

	Effects: {
		GagChance: number,
		DeathScreenDuration: number,
		WienerDuration: number,
		Gags: { string },
	},

	Maps: { MapSpec },
	Teams: { { Name: string, Color: BrickColor } },
	DataStoreName: string,
}

return (Config :: any) :: ConfigType
