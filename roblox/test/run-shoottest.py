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


SHARED = ['Config', 'Signal', 'Util', 'Remotes', 'Sound', 'Shot']
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

-- A witness standing nearby. Shot visuals are broadcast to everyone close
-- enough to see them -- and NOT to the shooter, whose own client already drew
-- the shot the instant they pulled the trigger. With only one player on the
-- server there is nobody to broadcast to, so the test would prove nothing.
local witnessChar = makeCharacter("Witness", Vector3.new(14, 5, 0))
local witness = Instance.new("Player")
witness._props.Name = "Witness"
witness._props.UserId = 2
witness._props.Character = witnessChar
witness._props.CharacterAdded = SIGNAL()
witness._props.LoadCharacterAsync = function() end

rawget(Players, "_props").GetPlayers = function() return { shooter, witness } end
rawget(Players, "_props").GetPlayerFromCharacter = function(_, c)
	if c == shooterChar then return shooter end
	if c == witnessChar then return witness end
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
FIRED = {}
fireRemote._props.OnServerEvent._fire(shooter, Vector3.new(0, 0, -1))

-- The shot now reaches other players as one small event rather than as
-- replicated parts, and the shooter is deliberately left out: their own
-- client drew the flash, the bang and the tracer the moment they fired,
-- instead of a network round trip later.
local shotEvents = FIRED_TO("ShotFired")
check("a shot is fired", #shotEvents > 0, string.format("%d broadcasts", #shotEvents))

local toldShooter = false
for _, call in shotEvents do
	if call.player == shooter then toldShooter = true end
end
check("the shooter is not told about their own shot", not toldShooter, "")

if #shotEvents > 0 then
	local payload = shotEvents[1].args[1]
	check("the broadcast carries where the shot went",
		payload ~= nil and typeof(payload.origin) == "Vector3"
			and typeof(payload.endPoint) == "Vector3",
		"")
end

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

-- --------------------------------------------- armed in every sport
-- The shape of the whole game: a shooter with sports scattered through it,
-- and you can shoot people while playing any of them. A seat that quietly
-- stopped your guns working would be a different game, so every piece of
-- gear gets checked rather than trusted.
DUMP("")
DUMP("Shooting from the sports gear:")
check("the rule is on", Config.WeaponsAlwaysAvailable == true, "")

do
	local gear = { "Tube", "Glider" }
	for _, kind in gear do
		-- Past the last shot's cooldown. Without this the second piece of
		-- gear reads as "cannot shoot" when all that happened is the sniper
		-- was still reloading from the first.
		ADVANCE(3)
		local ride = VehicleService.SpawnKind(kind, Vector3.new(0, 5, 0))
		if not ride then
			check(kind .. " exists", false, "SpawnKind returned nothing")
			continue
		end

		-- Put the shooter in it, the way sitting down would.
		local seat = ride:FindFirstChild("DriverSeat")
		local humanoid = shooterChar:FindFirstChildOfClass("Humanoid")
		seat._props.Occupant = humanoid
		humanoid._props.SeatPart = seat
		seat._props.GetPropertyChangedSignal = nil
		local state = PlayerState.Get(shooter)
		state.vehicle = ride
		state.seatRole = "Rider"

		FIRED = {}
		fireRemote._props.OnServerEvent._fire(shooter, Vector3.new(0, 0, -1))
		check("you can shoot from a " .. string.lower(kind), #FIRED_TO("ShotFired") > 0,
			string.format("%d shots", #FIRED_TO("ShotFired")))

		-- And it must not have silently handed you a mounted gun instead of
		-- the rifle you were carrying.
		check("a " .. string.lower(kind) .. " does not replace your weapon",
			WeaponService.EquippedForTests(shooter) == state.equipped,
			WeaponService.EquippedForTests(shooter))

		state.vehicle = nil
		state.seatRole = nil
		humanoid._props.SeatPart = nil
		ride:Destroy()
	end
end

-- ------------------------------------------------------- the grenade key
-- Halo's grenade button threw without changing what was in your hands, and
-- that is the whole point of it: you can throw one mid-fight and still have
-- your rifle. So the key must throw, must NOT change the equipped weapon,
-- and must keep working even when the grenade is not in the loadout at all.
DUMP("")
DUMP("The dedicated grenade key:")
do
	local grenadeRemote = Remotes.Event("ThrowGrenade")
	check("ThrowGrenade has a server listener", grenadeRemote._props.OnServerEvent ~= nil, "")

	local heldBefore = WeaponService.EquippedForTests(shooter)
	local projectilesBefore = liveProjectiles()
	grenadeRemote._props.OnServerEvent._fire(shooter, Vector3.new(0, 0.4, -1))
	RUN_SPAWNED()

	check("the key throws something", liveProjectiles() > projectilesBefore,
		string.format("%d in flight, was %d", liveProjectiles(), projectilesBefore))
	check("it does not change what you are holding",
		WeaponService.EquippedForTests(shooter) == heldBefore,
		string.format("%s, was %s", WeaponService.EquippedForTests(shooter), heldBefore))

	-- Now take the grenade out of the loadout entirely, the way a weapon
	-- pickup can. The key has to carry on working.
	local state = PlayerState.Get(shooter)
	state.weapons[Config.GrenadeKeyWeapon] = nil
	local without = liveProjectiles()
	grenadeRemote._props.OnServerEvent._fire(shooter, Vector3.new(0, 0.4, -1))
	RUN_SPAWNED()
	check("it still works with no grenade in the loadout", liveProjectiles() > without,
		string.format("%d in flight, was %d", liveProjectiles(), without))
end

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

--[[
	Exit non-zero on failure.

	Without this the suite only PRINTED its failures and exited 0, so
	run-all.sh reported success no matter what broke, and any automation
	trusting its exit code was being told a comforting lie. error() at the
	top level is what makes the luau CLI exit non-zero.
]]
if failures > 0 then
	error("shooting: " .. failures .. " failures", 0)
end
''')

sys.stdout.write('\n'.join(parts))
