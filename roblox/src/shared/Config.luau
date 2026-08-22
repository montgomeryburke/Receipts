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
	},
	Revolver = {
		Slot = 1, Category = "Sidearm", DisplayName = ".44 Revolver",
		Kind = "Hitscan", Damage = 34, Cooldown = 0.7, Range = 500,
		MagSize = 6, ReloadTime = 2.1, Spread = 0.8,
		Color = Color3.fromRGB(150, 130, 90),
	},
	Deagle = {
		Slot = 1, Category = "Sidearm", DisplayName = "Hand Cannon",
		Kind = "Hitscan", Damage = 42, Cooldown = 0.75, Range = 480,
		MagSize = 7, ReloadTime = 2.0, Spread = 1.0,
		Color = Color3.fromRGB(200, 180, 110),
	},

	-- ------------------------------------------------------------ AUTOMATIC
	SMG = {
		Slot = 2, Category = "Automatic", DisplayName = "Backroad SMG",
		Kind = "Hitscan", Damage = 7, Cooldown = 0.075, Range = 380,
		MagSize = 35, ReloadTime = 1.7, Spread = 2.6, Automatic = true,
		Color = Color3.fromRGB(70, 76, 84),
	},
	AssaultRifle = {
		Slot = 2, Category = "Automatic", DisplayName = "Assault Rifle",
		Kind = "Hitscan", Damage = 14, Cooldown = 0.11, Range = 700,
		MagSize = 30, ReloadTime = 2.0, Spread = 1.5, Automatic = true,
		Color = Color3.fromRGB(60, 68, 58),
	},
	MachineGun = {
		Slot = 2, Category = "Automatic", DisplayName = "Machine Gun",
		Kind = "Hitscan", Damage = 11, Cooldown = 0.09, Range = 650,
		MagSize = 80, ReloadTime = 3.4, Spread = 2.2, Automatic = true,
		Color = Color3.fromRGB(52, 54, 58),
	},
	Minigun = {
		Slot = 2, Category = "Automatic", DisplayName = "Mud Minigun",
		Kind = "Hitscan", Damage = 9, Cooldown = 0.045, Range = 600,
		MagSize = 200, ReloadTime = 5.0, Spread = 3.4, Automatic = true,
		-- Slows you down while you hold the trigger, because it is enormous.
		MoveSpeedFactor = 0.45,
		Color = Color3.fromRGB(96, 100, 104),
	},

	-- ------------------------------------------------------------- SHOTGUNS
	Shotgun = {
		Slot = 3, Category = "Shotgun", DisplayName = "Pump Shotgun",
		Kind = "Hitscan", Damage = 9, Cooldown = 0.85, Range = 160,
		MagSize = 6, ReloadTime = 2.6, Spread = 6.0, Pellets = 9,
		Color = Color3.fromRGB(120, 84, 52),
	},
	AutoShotgun = {
		Slot = 3, Category = "Shotgun", DisplayName = "Auto Shotgun",
		Kind = "Hitscan", Damage = 7, Cooldown = 0.4, Range = 140,
		MagSize = 8, ReloadTime = 3.0, Spread = 7.5, Pellets = 8, Automatic = true,
		Color = Color3.fromRGB(90, 70, 60),
	},

	-- -------------------------------------------------------------- SNIPERS
	Sniper = {
		Slot = 4, Category = "Sniper", DisplayName = "Zoom Sniper",
		Kind = "Hitscan", Damage = 62, Cooldown = 1.5, Range = 2400,
		MagSize = 5, ReloadTime = 2.8, Spread = 0.0,
		ZoomFov = 22, AutoAim = true,
		Color = Color3.fromRGB(46, 56, 46),
	},
	AntiMaterial = {
		Slot = 4, Category = "Sniper", DisplayName = "Anti-Truck Rifle",
		Kind = "Projectile", Damage = 90, Cooldown = 2.4, Range = 2600, Speed = 1200,
		MagSize = 3, ReloadTime = 3.6, Spread = 0.0,
		ZoomFov = 16, AutoAim = true,
		-- Wrecks vehicles specifically.
		VehicleDamageMultiplier = 3,
		Color = Color3.fromRGB(60, 60, 70),
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
	},

	-- --------------------------------------------------------- EXPLOSIVES
	Grenade = {
		Slot = 6, Category = "Explosive", DisplayName = "Frag Grenade",
		Kind = "Arcing", Damage = 0, Cooldown = 1.1, Range = 220, Speed = 90,
		MagSize = 3, ReloadTime = 4.0, Spread = 0.0,
		FuseTime = 3.0, BlastRadius = 26, BlastDamage = 85,
		Color = Color3.fromRGB(70, 92, 62),
	},
	StickyGrenade = {
		Slot = 6, Category = "Explosive", DisplayName = "Sticky Bomb",
		Kind = "Arcing", Damage = 0, Cooldown = 1.3, Range = 200, Speed = 80,
		MagSize = 2, ReloadTime = 4.5, Spread = 0.0,
		FuseTime = 2.5, BlastRadius = 30, BlastDamage = 100, Sticky = true,
		Color = Color3.fromRGB(180, 90, 190),
	},
	RPG = {
		Slot = 6, Category = "Explosive", DisplayName = "Rocket Propelled Grenade",
		Kind = "Rocket", Damage = 0, Cooldown = 2.2, Range = 1400, Speed = 180,
		MagSize = 1, ReloadTime = 3.2, Spread = 0.0,
		BlastRadius = 34, BlastDamage = 110,
		VehicleDamageMultiplier = 2,
		Color = Color3.fromRGB(170, 70, 50),
	},

	-- --------------------------------------------------- VEHICLE-MOUNTED
	-- These are not carried on foot; they come attached to a vehicle seat.
	FiftyCal = {
		Slot = 0, Category = "Mounted", DisplayName = "50 Cal",
		Kind = "Projectile", Damage = 28, Cooldown = 0.14, Range = 1600, Speed = 900,
		MagSize = 100, ReloadTime = 4.0, Spread = 1.4, Automatic = true,
		Pierces = 2, BlastRadius = 6, BlastDamage = 10,
		VehicleDamageMultiplier = 2, MountedOnly = true, AutoAim = true,
		Color = Color3.fromRGB(58, 60, 64),
	},
	TankCannon = {
		Slot = 0, Category = "Mounted", DisplayName = "Tank Cannon",
		Kind = "Rocket", Damage = 0, Cooldown = 3.0, Range = 2000, Speed = 420,
		MagSize = 1, ReloadTime = 3.0, Spread = 0.0,
		BlastRadius = 40, BlastDamage = 130,
		VehicleDamageMultiplier = 3, MountedOnly = true,
		Color = Color3.fromRGB(74, 84, 66),
	},
	PlaneGun = {
		Slot = 0, Category = "Mounted", DisplayName = "Wing Guns",
		Kind = "Projectile", Damage = 16, Cooldown = 0.1, Range = 1200, Speed = 800,
		MagSize = 150, ReloadTime = 5.0, Spread = 2.0, Automatic = true,
		MountedOnly = true,
		Color = Color3.fromRGB(120, 128, 136),
	},
}

--[[ Which guns you spawn holding. Everything else is found on the map. ]]
Config.StartingLoadout = { "Pistol", "AssaultRifle", "Shotgun", "Sniper", "DiamondGun", "Grenade" }

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
	{ Name = "Rust Bucket", KeysRequired = 0, MaxSpeed = 60, Torque = 12000, TurnSpeed = 30, Color = Color3.fromRGB(120, 100, 80) },
	{ Name = "Mud Runner", KeysRequired = 2, MaxSpeed = 82, Torque = 17000, TurnSpeed = 34, Color = Color3.fromRGB(80, 130, 90) },
	{ Name = "Swamp Devil", KeysRequired = 5, MaxSpeed = 104, Torque = 22000, TurnSpeed = 38, Color = Color3.fromRGB(180, 120, 40) },
	{ Name = "Nuclear Hauler", KeysRequired = 9, MaxSpeed = 130, Torque = 28000, TurnSpeed = 42, Color = Color3.fromRGB(90, 210, 220) },
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

-- ================================================================= PICKUPS ==

Config.Pickups = {
	RespawnDelay = 25,
	Burger = { DisplayName = "Invincibility Burger", Duration = 10, Color = Color3.fromRGB(200, 140, 60) },
	Fries = { DisplayName = "Triple-Gun Fries", Duration = 15, Barrels = 3, SpreadDegrees = 7, Color = Color3.fromRGB(240, 200, 70) },
	Shield = { DisplayName = "Shield Cell", Amount = 50, Color = Color3.fromRGB(90, 180, 240) },
	Ammo = { DisplayName = "Ammo Crate", Color = Color3.fromRGB(140, 120, 70) },
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
	{ Id = "BogBasin", Name = "Bog Basin", Size = 700, MudFraction = 0.55, Buildings = 12, Jumps = 8, Ramps = 10, Theme = Color3.fromRGB(96, 78, 52) },
	{ Id = "DiamondQuarry", Name = "Diamond Quarry", Size = 760, MudFraction = 0.25, Buildings = 16, Jumps = 12, Ramps = 14, Theme = Color3.fromRGB(150, 160, 170) },
	{ Id = "SwampCircuit", Name = "Swamp Circuit", Size = 820, MudFraction = 0.6, Buildings = 9, Jumps = 14, Ramps = 12, Theme = Color3.fromRGB(70, 96, 66) },
	{ Id = "RustyOverpass", Name = "Rusty Overpass", Size = 720, MudFraction = 0.2, Buildings = 20, Jumps = 16, Ramps = 18, Theme = Color3.fromRGB(140, 84, 56) },
	{ Id = "GatorCreek", Name = "Gator Creek", Size = 780, MudFraction = 0.7, Buildings = 10, Jumps = 9, Ramps = 10, Theme = Color3.fromRGB(64, 88, 74) },
	{ Id = "FalloutFlats", Name = "Fallout Flats", Size = 900, MudFraction = 0.15, Buildings = 14, Jumps = 10, Ramps = 8, Theme = Color3.fromRGB(122, 122, 96) },
	{ Id = "HollerHills", Name = "Holler Hills", Size = 760, MudFraction = 0.45, Buildings = 11, Jumps = 18, Ramps = 16, Theme = Color3.fromRGB(88, 110, 70) },
	{ Id = "ScrapyardSprint", Name = "Scrapyard Sprint", Size = 680, MudFraction = 0.3, Buildings = 22, Jumps = 11, Ramps = 20, Theme = Color3.fromRGB(110, 100, 106) },
	{ Id = "MoonshineMile", Name = "Moonshine Mile", Size = 960, MudFraction = 0.35, Buildings = 13, Jumps = 20, Ramps = 12, Theme = Color3.fromRGB(104, 92, 64) },
	{ Id = "ReactorRidge", Name = "Reactor Ridge", Size = 820, MudFraction = 0.4, Buildings = 18, Jumps = 13, Ramps = 15, Theme = Color3.fromRGB(74, 130, 132) },
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
	FuseTime: number?,
	Sticky: boolean?,
	MountedOnly: boolean?,
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

	CarTiers: { CarTier },
	Vehicles: { [string]: VehicleSpec },
	MudSpeedFactor: number,

	Pickups: {
		RespawnDelay: number,
		Burger: { DisplayName: string, Duration: number, Color: Color3 },
		Fries: { DisplayName: string, Duration: number, Barrels: number, SpreadDegrees: number, Color: Color3 },
		Shield: { DisplayName: string, Amount: number, Color: Color3 },
		Ammo: { DisplayName: string, Color: Color3 },
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
