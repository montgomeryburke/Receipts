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
          'ProjectileService', 'WeaponService', 'TeamService', 'PickupService', 'EffectService']

parts = [read(HERE, 'stubs.luau'), read(HERE, 'serverstubs.luau'), '''
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
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
DUMP("Firing the starting pistol:")
local before = countInWorkspace("Tracer")
fireRemote._props.OnServerEvent._fire(shooter, Vector3.new(0, 0, -1))
local after = countInWorkspace("Tracer")
check("a shot is fired", after > before, string.format("%d tracers", after - before))

local state = PlayerState.Get(shooter)
check("ammo is spent", state.weapons.Pistol.ammo < Config.Weapons.Pistol.MagSize,
	string.format("%d rounds left", state.weapons.Pistol.ammo))

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
DUMP("Elephants and poop:")
WildlifeService.Populate(700)
check("animals spawn", WildlifeService.Count() == Config.Beast.Count,
	string.format("%d walking about", WildlifeService.Count()))

-- Run a while so they walk and drop something.
for _ = 1, 60 * 12 do
	ADVANCE(1 / 60)
	RunService.Heartbeat._fire(1 / 60)
end
-- Only if an elephant happens to be among them; the species are random.
local hasElephant = false
for _, id in WildlifeService.SpeciesPresent() do
	if id == "Elephant" then hasElephant = true end
end
if hasElephant then
	check("elephants poop", WildlifeService.PoopCount() > 0,
		string.format("%d piles", WildlifeService.PoopCount()))
else
	DUMP("  skip  no elephant in this spawn, nothing to poop")
end

-- ------------------------------------------------------------------ drone
DUMP("")
DUMP("Hunter drone:")
local droneState = PlayerState.Get(shooter)
droneState.equipped = "Drone"
droneState.weapons.Drone.ammo = 2
droneState.weapons.Drone.nextFireAt = 0
local beforeDrone = liveProjectiles()
fireRemote._props.OnServerEvent._fire(shooter, Vector3.new(0, 0, -1))
check("drone launches", liveProjectiles() > beforeDrone,
	string.format("%d in flight", liveProjectiles() - beforeDrone))

-- ------------------------------------------------------- the giant animals
DUMP("")
DUMP("Giant animals:")
WildlifeService.Populate(700)
local present = WildlifeService.SpeciesPresent()
check("animals spawn", #present == Config.Beast.Count, table.concat(present, ", "))

local distinct = {}
local allDifferent = true
for _, id in present do
	if distinct[id] then allDifferent = false end
	distinct[id] = true
end
check("all different species", allDifferent, "")

-- Shooting one should annoy it, not kill it.
local beastPart
for _, child in workspace:GetChildren() do
	if child:GetAttribute("IsBeast") then
		beastPart = child:FindFirstChild("Body")
		break
	end
end
check("an animal has a body to shoot", beastPart ~= nil, "")
if beastPart then
	check("bullets register but do not kill", WildlifeService.RegisterHit(beastPart), "")
	check("animal survives being shot", #WildlifeService.SpeciesPresent() == Config.Beast.Count,
		string.format("%d still standing", #WildlifeService.SpeciesPresent()))
end

-- Riding takes your guns away.
DUMP("")
DUMP("Riding:")
local ridingState = PlayerState.Get(shooter)
ridingState.equipped = "Pistol"
ridingState.weapons.Pistol.ammo = 12
ridingState.weapons.Pistol.nextFireAt = 0
ridingState.seatRole = "Beast"
local tracersBefore = countInWorkspace("Tracer")
fireRemote._props.OnServerEvent._fire(shooter, Vector3.new(0, 0, -1))
check("guns are disabled while riding", countInWorkspace("Tracer") == tracersBefore,
	"no shot fired")
ridingState.seatRole = nil

-- Only the mega-detonation kills one, and what comes back is different.
DUMP("")
DUMP("Mega-detonation:")
local before = WildlifeService.SpeciesPresent()
local victimSpecies = before[1]
local victimPosition
for _, child in workspace:GetChildren() do
	if child:GetAttribute("IsBeast") and child:GetAttribute("Species") == victimSpecies then
		victimPosition = child:FindFirstChild("Body")._props.CFrame.Position
		break
	end
end

DamageService.MegaBlast.Fire(victimPosition, 140, shooter)
-- Signals hand each listener its own thread; run them.
RUN_SPAWNED()
-- At least the one at the centre. Two animals standing close together can
-- both be caught, which is fine.
check("mega blast bursts the animal", #WildlifeService.SpeciesPresent() < Config.Beast.Count,
	string.format("%d left of %d", #WildlifeService.SpeciesPresent(), Config.Beast.Count))

-- Fast-forward the respawn timer.
RUN_DELAYED()
local after = WildlifeService.SpeciesPresent()
check("it comes back", #after == Config.Beast.Count, table.concat(after, ", "))
check("the burst species is gone", (function()
	for _, id in after do
		if id == victimSpecies then return false end
	end
	return true
end)(), string.format("%s did not return", tostring(victimSpecies)))

local cameBackSame = false
for _, id in after do
	local wasThere = false
	for _, old in before do
		if old == id then wasThere = true end
	end
	if not wasThere then cameBackSame = false end
end
local replacement
for _, id in after do
	local matched = false
	for _, old in before do
		if old == id then matched = true end
	end
	if not matched then replacement = id end
end
check("it comes back as a DIFFERENT animal", replacement ~= nil and replacement ~= victimSpecies,
	string.format("%s became %s", tostring(victimSpecies), tostring(replacement)))
local _ = cameBackSame

DUMP("")
DUMP(if failures == 0 then "SHOOTING WORKS" else failures .. " FAILURES")
''')

sys.stdout.write('\n'.join(parts))
