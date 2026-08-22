#!/usr/bin/env python3
"""
Fire a gun, end to end, outside Roblox.

"Left click does nothing" has been reported twice. Client-side input being
connected is not enough — the request has to reach a server handler, survive
every check, and produce a shot. This drives the FireWeapon remote exactly
as the client does and looks for the tracer that proves a shot happened.

    python3 test/run-shoottest.py > /tmp/s.luau && luau /tmp/s.luau
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'src')


def read(*p):
    with open(os.path.join(*p)) as handle:
        return handle.read()


def strip(s):
    kept = []
    for line in s.split('\n'):
        if re.match(r'^local \w+ = game:GetService\(', line): continue
        if re.match(r'^local Shared = ', line): continue
        if re.match(r'^local \w+ = require\(', line): continue
        kept.append(line)
    return '\n'.join(kept)


SHARED = ['Config', 'Signal', 'Util', 'Remotes']
SERVER = ['PlayerState', 'MapService', 'VehicleService', 'DamageService', 'WildlifeService',
          'CarnivalService', 'ProjectileService', 'WeaponService', 'TeamService', 'PickupService',
          'EffectService', 'FlagService']

parts = [read(HERE, 'stubs.luau'), read(HERE, 'serverstubs.luau'), '''
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
''']

for n in SHARED:
    parts.append(f'local {n} = (function()\n{strip(read(SRC, "shared", n + ".luau"))}\nend)()\n')
for n in SERVER:
    parts.append(f'local {n} = (function()\n{strip(read(SRC, "server", "modules", n + ".luau"))}\nend)()\n')

parts.append('''
-- A shooter with a body, and a victim to shoot at.
local function makeCharacter(name, position)
	local character = Instance.new("Model")
	character._props.Name = name
	local root = Instance.new("Part")
	root._props.Name = "HumanoidRootPart"
	root._props.CFrame = CFrame.new(position)
	root.Parent = character
	local head = Instance.new("Part")
	head._props.Name = "Head"
	head._props.CFrame = CFrame.new(position + Vector3.new(0, 2, 0))
	head.Parent = character
	local humanoid = Instance.new("Humanoid")
	humanoid._props.Health = 100
	humanoid._props.MaxHealth = 100
	humanoid.Parent = character
	character.Parent = workspace
	return character, humanoid
end

local shooterChar = makeCharacter("Shooter", Vector3.new(0, 5, 0))
local shooter = Instance.new("Player")
shooter._props.Name = "Shooter"
shooter._props.UserId = 1
shooter._props.Character = shooterChar
shooter._props.CharacterAdded = SIGNAL()
shooter._props.LoadCharacterAsync = function() end

rawget(Players, "_props").GetPlayers = function() return { shooter } end
rawget(Players, "_props").GetPlayerFromCharacter = function(_, c)
	if c == shooterChar then return shooter end
	return nil
end

local failures = 0
local function check(label, condition, detail)
	if condition then
		DUMP(string.format("  PASS  %-36s %s", label, detail or ""))
	else
		DUMP(string.format("  FAIL  %-36s %s", label, detail or ""))
		failures += 1
	end
end

-- Bring the weapon systems up exactly the way the server does.
local startOk, startErr = pcall(WeaponService.Start)
check("WeaponService.Start succeeds", startOk, startOk and "" or tostring(startErr))

-- Does the remote the client fires actually have anyone listening?
local fireRemote = Remotes.Event("FireWeapon")
local listeners = fireRemote._props.OnServerEvent
check("FireWeapon has a server listener", listeners ~= nil, "")

local function countInWorkspace(name)
	local n = 0
	for _, child in workspace:GetChildren() do
		if child._props.Name == name then n += 1 end
	end
	return n
end

local function liveProjectiles()
	return countInWorkspace("Projectile")
end

-- ---------------------------------------------------------------- hitscan
DUMP("")
DUMP("Firing the starting weapon:")
local before = countInWorkspace("Tracer")
fireRemote._props.OnServerEvent._fire(shooter, Vector3.new(0, 0, -1))
local after = countInWorkspace("Tracer")
check("a shot is fired", after > before, string.format("%d tracers", after - before))

-- Ammo is endless by design now, so the magazine should NOT go down.
local state = PlayerState.Get(shooter)
local starting = Config.StartingLoadout[1]
check("the starting weapon is held", state.equipped == starting, state.equipped)
check("ammo does not deplete", state.weapons[starting].ammo == Config.Weapons[starting].MagSize,
	string.format("%d rounds", state.weapons[starting].ammo))

-- ------------------------------------------------------------- projectile
DUMP("")
DUMP("Switching to the diamond gun and firing:")
Remotes.Event("EquipWeapon")._props.OnServerEvent._fire(shooter, "DiamondGun")
check("weapon switches", PlayerState.Get(shooter).equipped == "DiamondGun",
	PlayerState.Get(shooter).equipped)

local beforeShots = liveProjectiles()
fireRemote._props.OnServerEvent._fire(shooter, Vector3.new(0, 0, -1))
check("a diamond round launches", liveProjectiles() > beforeShots,
	string.format("%d in flight", liveProjectiles() - beforeShots))

-- ------------------------------------------------------------ gun in hand
DUMP("")
DUMP("A gun in his hand:")
-- Give the character a hand to hold it in.
local hand = Instance.new("Part")
hand._props.Name = "RightHand"
hand._props.CFrame = CFrame.new(1, 4, 0)
hand.Parent = shooterChar

WeaponService.UpdateHeldWeapon(shooter)
local held = shooterChar:FindFirstChild("HeldWeapon")
check("a weapon model is held", held ~= nil, "")
if held then
	local barrel = held:FindFirstChild("Barrel")
	check("it has a barrel", barrel ~= nil, "")
end

-- Switching weapons swaps the model rather than stacking them.
Remotes.Event("EquipWeapon")._props.OnServerEvent._fire(shooter, "Sniper")
local heldCount = 0
for _, child in shooterChar:GetChildren() do
	if child._props.Name == "HeldWeapon" then heldCount += 1 end
end
check("only ever one weapon held", heldCount == 1, string.format("%d models", heldCount))

-- ------------------------------------------------------------------ melee
DUMP("")
DUMP("Melee and turbo remotes:")
local meleeOk = pcall(function()
	Remotes.Event("Melee")._props.OnServerEvent._fire(shooter)
end)
check("melee is handled", meleeOk, "")

local turboOk = pcall(function()
	Remotes.Event("SetTurbo")._props.OnServerEvent._fire(shooter, true)
end)
check("turbo is handled", turboOk, "")

-- --------------------------------------------------------------- wildlife
DUMP("")
DUMP("The population:")
WildlifeService.Populate(700)
check("zombies spawn", WildlifeService.CountOf("Zombie") == Config.Population.Zombies,
	string.format("%d zombies", WildlifeService.CountOf("Zombie")))
check("civilians spawn", WildlifeService.CountOf("Civilian") == Config.Population.Civilians,
	string.format("%d civilians", WildlifeService.CountOf("Civilian")))
check("targets spawn", WildlifeService.CountOf("Target") == Config.Population.Targets,
	string.format("%d targets", WildlifeService.CountOf("Target")))
check("poop is scattered about", WildlifeService.PoopCount() > 0,
	string.format("%d piles", WildlifeService.PoopCount()))

-- Shooting a zombie should hurt it and eventually kill it for points.
DUMP("")
DUMP("Shooting the locals:")
local zombieTorso
for _, child in workspace:GetChildren() do
	if child:GetAttribute("Dweller") == "Zombie" then
		zombieTorso = child:FindFirstChild("Torso")
		break
	end
end
check("a zombie can be found", zombieTorso ~= nil, "")

local pointsBefore = PlayerState.Get(shooter).points
if zombieTorso then
	check("the hit registers", WildlifeService.RegisterHit(zombieTorso, 20, shooter), "")
	-- Enough damage to finish it.
	for _ = 1, 10 do
		WildlifeService.RegisterHit(zombieTorso, 20, shooter)
	end
	RUN_SPAWNED()
	check("killing it scores points", PlayerState.Get(shooter).points > pointsBefore,
		string.format("%d points", PlayerState.Get(shooter).points))
	check("the zombie is gone", WildlifeService.CountOf("Zombie") < Config.Population.Zombies,
		string.format("%d left", WildlifeService.CountOf("Zombie")))
end

-- Shooting a poop pile raises a tower with stairs.
DUMP("")
DUMP("Poop towers:")
local pile
for _, child in workspace:GetChildren() do
	if child:GetAttribute("Poop") then pile = child break end
end
check("a poop pile can be found", pile ~= nil, "")
if pile then
	WildlifeService.RegisterHit(pile, 20, shooter)
	local column, stairs = nil, 0
	for _, child in workspace:GetChildren() do
		if child._props.Name == "PoopColumn" then
			column = child
			for _, piece in child:GetChildren() do
				if piece._props.Name == "SpiralStep" then stairs += 1 end
			end
		end
	end
	check("a tower rises", column ~= nil, "")
	check("with stairs to the top", stairs > 30, string.format("%d steps", stairs))
end

-- Endless ammo.
DUMP("")
DUMP("Endless ammo:")
local ammoState = PlayerState.Get(shooter)
ammoState.equipped = "MachineGun"
ammoState.weapons.MachineGun.nextFireAt = 0
local startAmmo = ammoState.weapons.MachineGun.ammo
for shot = 1, 30 do
	ammoState.weapons.MachineGun.nextFireAt = 0
	fireRemote._props.OnServerEvent._fire(shooter, Vector3.new(0, 0, -1))
end
check("ammo never runs down", ammoState.weapons.MachineGun.ammo == startAmmo,
	string.format("%d rounds after 30 shots", ammoState.weapons.MachineGun.ammo))

-- ---------------------------------------------------- capture the flag
DUMP("")
DUMP("Capture the Flag:")
TeamService.Start()
TeamService.Assign(shooter)
FlagService.Start()

local teamColours = { BrickColor.new("Bright red"), BrickColor.new("Bright blue") }
local fakeBuild = {
	teamSpawns = {
		{ Vector3.new(0, 4, -300), Vector3.new(20, 4, -300) },
		{ Vector3.new(0, 4, 300), Vector3.new(20, 4, 300) },
	},
}
FlagService.Setup(fakeBuild, teamColours)
check("CTF is running", FlagService.IsActive(), "")
check("both flags start home",
	FlagService.StateOf(1) == "Home" and FlagService.StateOf(2) == "Home",
	string.format("%s / %s", FlagService.StateOf(1), FlagService.StateOf(2)))

local myTeam = TeamService.IndexOf(shooter)
local enemyTeam = if myTeam == 1 then 2 else 1

-- Find the enemy flag pole and walk into it.
local enemyPole, myStand
for _, child in workspace:GetChildren() do
	if child._props.Name == "CaptureTheFlag" then
		for _, piece in child:GetChildren() do
			if piece._props.Name == string.format("Flag_%d", enemyTeam) then
				enemyPole = piece:FindFirstChild("Pole")
			end
		end
		for _, piece in child:GetChildren() do
			if piece._props.Name == "FlagStand" then
				-- Whichever stand is on our side of the map.
				local z = piece._props.CFrame.Position.Z
				local mine = if myTeam == 1 then z < 0 else z > 0
				if mine then myStand = piece end
			end
		end
	end
end

check("the enemy flag exists", enemyPole ~= nil, "")
if enemyPole then
	enemyPole._props.Touched._fire(shooterChar:FindFirstChild("HumanoidRootPart"))
	RUN_SPAWNED()
	check("picking it up works", FlagService.StateOf(enemyTeam) == "Carried",
		FlagService.StateOf(enemyTeam))
end

local captured = false
FlagService.Captured.Connect(function() captured = true end)

check("our own stand exists", myStand ~= nil, "")
if myStand then
	myStand._props.Touched._fire(shooterChar:FindFirstChild("HumanoidRootPart"))
	RUN_SPAWNED()
	check("carrying it home scores", captured, "capture fired")
	check("the flag goes back on its stand", FlagService.StateOf(enemyTeam) == "Home",
		FlagService.StateOf(enemyTeam))
end

-- ------------------------------------------------------------ carnival
DUMP("")
DUMP("The carnival:")
CarnivalService.Build(700)

local dunkTarget, duck, strikerPad
for _, child in workspace:GetChildren() do
	if child._props.Name == "Carnival" then
		for _, piece in child:GetChildren() do
			local kind = piece:GetAttribute("Carnival")
			if kind == "Dunk" and not dunkTarget then dunkTarget = piece end
			if kind == "Duck" and not duck then duck = piece end
			if kind == "Striker" and not strikerPad then strikerPad = piece end
		end
	end
end

check("the dunk tank is built", dunkTarget ~= nil, "")
check("the shooting gallery is built", duck ~= nil, "")
check("the high striker is built", strikerPad ~= nil, "")

local carnivalPoints = PlayerState.Get(shooter).points
if dunkTarget then
	check("shooting the dunk target counts",
		CarnivalService.RegisterHit(dunkTarget, shooter), "")
end
if duck then
	check("shooting a duck counts", CarnivalService.RegisterHit(duck, shooter), "")
end
if strikerPad then
	check("shooting the striker counts", CarnivalService.RegisterHit(strikerPad, shooter), "")
end
check("carnival games score points", PlayerState.Get(shooter).points > carnivalPoints,
	string.format("%d points", PlayerState.Get(shooter).points))

DUMP("")
DUMP(if failures == 0 then "SHOOTING WORKS" else failures .. " FAILURES")
''')

sys.stdout.write('\n'.join(parts))
