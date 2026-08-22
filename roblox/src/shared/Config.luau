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

Config.Match = {
	MaxPlayers = 20,
	VoteDuration = 20,
	RoundDuration = 300,
	IntermissionDuration = 15,
	MapChoices = 3,
	MinPlayers = 1,
	ScoreLimit = 80,
	PointsPerKill = 2,
}

-- ================================================================== COMBAT ==

Config.Combat = {
	MaxHealth = 100,
	ShieldRegenDelay = 6,
	ShieldRegenPerSecond = 8,
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
		Slot = 1, Category = "Sidearm", DisplayName = "9mm Pistol",
		Kind = "Hitscan", Damage = 12, Cooldown = 0.28, Range = 400,
		MagSize = 12, ReloadTime = 1.3, Spread = 1.2,
		Color = Color3.fromRGB(90, 90, 96),
		Automatic = true,
		Points = 10,
	},
	Revolver = {
		Slot = 1, Category = "Sidearm", DisplayName = ".44 Revolver",
		Kind = "Hitscan", Damage = 34, Cooldown = 0.7, Range = 500,
		MagSize = 6, ReloadTime = 2.1, Spread = 0.8,
		Color = Color3.fromRGB(150, 130, 90),
		Automatic = true,
		Points = 15,
	},
	Deagle = {
		Slot = 1, Category = "Sidearm", DisplayName = "Hand Cannon",
		Kind = "Hitscan", Damage = 42, Cooldown = 0.75, Range = 480,
		MagSize = 7, ReloadTime = 2.0, Spread = 1.0,
		Color = Color3.fromRGB(200, 180, 110),
		Automatic = true,
		Points = 15,
	},

	-- ------------------------------------------------------------ AUTOMATIC
	SMG = {
		Slot = 2, Category = "Automatic", DisplayName = "Backroad SMG",
		Kind = "Hitscan", Damage = 7, Cooldown = 0.075, Range = 380,
		MagSize = 35, ReloadTime = 1.7, Spread = 2.6, Automatic = true,
		Color = Color3.fromRGB(70, 76, 84),
		Points = 8,
	},
	AssaultRifle = {
		Slot = 2, Category = "Automatic", DisplayName = "Assault Rifle",
		Kind = "Hitscan", Damage = 14, Cooldown = 0.11, Range = 700,
		MagSize = 30, ReloadTime = 2.0, Spread = 1.5, Automatic = true,
		Color = Color3.fromRGB(60, 68, 58),
		Points = 10,
	},
	MachineGun = {
		Slot = 2, Category = "Automatic", DisplayName = "Machine Gun",
		Kind = "Hitscan", Damage = 11, Cooldown = 0.09, Range = 650,
		MagSize = 80, ReloadTime = 3.4, Spread = 2.2, Automatic = true,
		Color = Color3.fromRGB(52, 54, 58),
		Points = 10,
	},
	Minigun = {
		Slot = 2, Category = "Automatic", DisplayName = "Mud Minigun",
		Kind = "Hitscan", Damage = 9, Cooldown = 0.045, Range = 600,
		MagSize = 200, ReloadTime = 5.0, Spread = 3.4, Automatic = true,
		-- Slows you down while you hold the trigger, because it is enormous.
		MoveSpeedFactor = 0.45,
		Color = Color3.fromRGB(96, 100, 104),
		Points = 8,
	},

	-- ------------------------------------------------------------- SHOTGUNS
	Shotgun = {
		Slot = 3, Category = "Shotgun", DisplayName = "Pump Shotgun",
		Kind = "Hitscan", Damage = 9, Cooldown = 0.85, Range = 160,
		MagSize = 6, ReloadTime = 2.6, Spread = 6.0, Pellets = 9,
		Color = Color3.fromRGB(120, 84, 52),
		Automatic = true,
		Points = 14,
	},
	AutoShotgun = {
		Slot = 3, Category = "Shotgun", DisplayName = "Auto Shotgun",
		Kind = "Hitscan", Damage = 7, Cooldown = 0.4, Range = 140,
		MagSize = 8, ReloadTime = 3.0, Spread = 7.5, Pellets = 8, Automatic = true,
		Color = Color3.fromRGB(90, 70, 60),
		Points = 12,
	},

	-- -------------------------------------------------------------- SNIPERS
	Sniper = {
		Slot = 4, Category = "Sniper", DisplayName = "Sniper Rifle",
		Kind = "Hitscan", Damage = 62, Cooldown = 1.5, Range = 2400,
		MagSize = 4, ReloadTime = 2.8, Spread = 0.0,
		-- Halo's sniper had two scope stages. This has four, because the ask
		-- was to be able to line up close-range headshots too: 2x is usable
		-- across a room, 10x reaches the other end of the map.
		ZoomLevels = { 2, 4, 6, 10 },
		ZoomFov = 22, AutoAim = true,
		-- Holds down from the hip; one shot at a time once scoped, so a
		-- long-range rifle still has to be aimed.
		Automatic = true,
		SemiAutoWhenScoped = true,
		Color = Color3.fromRGB(46, 56, 46),
		Points = 30,
	},
	AntiMaterial = {
		Slot = 4, Category = "Sniper", DisplayName = "Anti-Truck Rifle",
		Kind = "Projectile", Damage = 90, Cooldown = 2.4, Range = 2600, Speed = 1200,
		MagSize = 3, ReloadTime = 3.6, Spread = 0.0,
		ZoomLevels = { 2, 5, 10, 16 },
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
		Slot = 5, Category = "Special", DisplayName = "Nuclear Diamond Gun",
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
		Slot = 6, Category = "Explosive", DisplayName = "Frag Grenade",
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
		Slot = 6, Category = "Explosive", DisplayName = "Sticky Bomb",
		Kind = "Arcing", Damage = 0, Cooldown = 1.3, Range = 200, Speed = 80,
		MagSize = 2, ReloadTime = 4.5, Spread = 0.0,
		FuseTime = 2.5, BlastRadius = 110, BlastDamage = 170, Sticky = true,
		Color = Color3.fromRGB(180, 90, 190),
		Points = 22,
	},
	RPG = {
		Slot = 6, Category = "Explosive", DisplayName = "Rocket Propelled Grenade",
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
	Poop = {
		Slot = 7, Category = "Utility", DisplayName = "Elephant Poop",
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
		Slot = 7, Category = "Utility", DisplayName = "Hunter Drone",
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
		Slot = 6, Category = "Explosive", DisplayName = "Land Mine",
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
		Slot = 6, Category = "Explosive", DisplayName = "Cluster Bomb",
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
		Slot = 0, Category = "Mounted", DisplayName = "50 Cal",
		Kind = "Projectile", Damage = 28, Cooldown = 0.14, Range = 1600, Speed = 900,
		MagSize = 100, ReloadTime = 4.0, Spread = 1.4, Automatic = true,
		Pierces = 2, BlastRadius = 6, BlastDamage = 10,
		ZoomLevels = { 2, 4 },
		VehicleDamageMultiplier = 2, MountedOnly = true, AutoAim = true,
		Color = Color3.fromRGB(58, 60, 64),
		Points = 18,
	},
	TankCannon = {
		Slot = 0, Category = "Mounted", DisplayName = "Tank Cannon",
		Kind = "Rocket", Damage = 0, Cooldown = 3.0, Range = 2000, Speed = 420,
		MagSize = 1, ReloadTime = 3.0, Spread = 0.0,
		BlastRadius = 40, BlastDamage = 130,
		VehicleDamageMultiplier = 3, MountedOnly = true,
		Color = Color3.fromRGB(74, 84, 66),
		Points = 25,
	},
	PlaneGun = {
		Slot = 0, Category = "Mounted", DisplayName = "Wing Guns",
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
	THE POPULATION.

	Zombies roam and come for you. Civilians wander and say something
	regrettable when shot. Bullseye targets stand around for practice.

	All three are worth points, and all three come back.
]]
Config.Population = {
	Zombies = 10,
	Civilians = 8,
	Targets = 12,

	ZombieHealth = 120,
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
	TurretTruck = {
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
	WalkSpeed = 16,
	SprintWalkSpeed = 30,
}

--[[
	The two cars that spawn beside you. Which one you get is a coin flip.

	The truck is slower but heavy and sits high; the Lamborghini is quick and
	low. Both use the same tier speeds, so the choice is feel, not advantage.
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
	{ Id = "BogBasin", Name = "Bog Basin", Size = 700, MudFraction = 0.55, Buildings = 25, Jumps = 8, Ramps = 10, Theme = Color3.fromRGB(96, 78, 52) },
	{ Id = "DiamondQuarry", Name = "Diamond Quarry", Size = 760, MudFraction = 0.25, Buildings = 33, Jumps = 12, Ramps = 14, Theme = Color3.fromRGB(150, 160, 170) },
	{ Id = "SwampCircuit", Name = "Swamp Circuit", Size = 820, MudFraction = 0.6, Buildings = 18, Jumps = 14, Ramps = 12, Theme = Color3.fromRGB(70, 96, 66) },
	{ Id = "RustyOverpass", Name = "Rusty Overpass", Size = 720, MudFraction = 0.2, Buildings = 42, Jumps = 16, Ramps = 18, Theme = Color3.fromRGB(140, 84, 56) },
	{ Id = "GatorCreek", Name = "Gator Creek", Size = 780, MudFraction = 0.7, Buildings = 21, Jumps = 9, Ramps = 10, Theme = Color3.fromRGB(64, 88, 74) },
	{ Id = "FalloutFlats", Name = "Fallout Flats", Size = 900, MudFraction = 0.15, Buildings = 29, Jumps = 10, Ramps = 8, Theme = Color3.fromRGB(122, 122, 96) },
	{ Id = "HollerHills", Name = "Holler Hills", Size = 760, MudFraction = 0.45, Buildings = 23, Jumps = 18, Ramps = 16, Theme = Color3.fromRGB(88, 110, 70) },
	{ Id = "ScrapyardSprint", Name = "Scrapyard Sprint", Size = 680, MudFraction = 0.3, Buildings = 46, Jumps = 11, Ramps = 20, Theme = Color3.fromRGB(110, 100, 106) },
	{ Id = "MoonshineMile", Name = "Moonshine Mile", Size = 960, MudFraction = 0.35, Buildings = 27, Jumps = 20, Ramps = 12, Theme = Color3.fromRGB(104, 92, 64) },
	{ Id = "ReactorRidge", Name = "Reactor Ridge", Size = 820, MudFraction = 0.4, Buildings = 37, Jumps = 13, Ramps = 15, Theme = Color3.fromRGB(74, 130, 132) },
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
	},
	Wildlife: {
		ElephantCount: number, ElephantSpeed: number,
		PoopInterval: number, PoopLifetime: number, PoopPerPile: number,
		MaxPoopPiles: number, SplatDuration: number,
	},
	Boost: { Speed: number, Lift: number },
	Population: {
		Zombies: number, Civilians: number, Targets: number,
		ZombieHealth: number, ZombieSpeed: number, ZombiePoints: number,
		ZombieReach: number, ZombieDamage: number,
		CivilianHealth: number, CivilianSpeed: number, CivilianPoints: number,
		TargetHealth: number, TargetPoints: number,
		RespawnDelay: number,
	},
	CivilianLines: { string },

	CarTiers: { CarTier },
	Turbo: { Multiplier: number, WalkSpeed: number, SprintWalkSpeed: number },
	CarBodies: {
		{ Name: string, Size: Vector3, RideHeight: number, SpeedBias: number, Color: Color3 }
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
