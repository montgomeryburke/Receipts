#!/usr/bin/env python3
"""
Config sanity checks.

These are the invariants that are obvious in hindsight and invisible in a
diff. The round score limit sat at 80 while weapons scored 10 to 35 a kill
and a flag capture scored 500 — so a round ended after about three kills and
nobody noticed, because every other test passed.

    python3 test/run-sanitytest.py > /tmp/n.luau && luau /tmp/n.luau
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


TEMPLATE = """
--[[STUBS]]

local Config = (function()
--[[CONFIG]]
end)()

local Sound = (function()
local Config = Config
--[[SOUND]]
end)()

local failures = 0
local function check(label, condition, detail)
	if condition then
		print(string.format("  PASS  %-46s %s", label, detail or ""))
	else
		print(string.format("  FAIL  %-46s %s", label, detail or ""))
		failures += 1
	end
end

-- ------------------------------------------------- how much a thing is worth
local biggestAward = 0
local biggestName = ""
for name, spec in Config.Weapons do
	local points = spec.Points or 0
	if points > biggestAward then
		biggestAward, biggestName = points, name
	end
end
biggestAward = math.max(biggestAward, Config.CTF.CapturePoints)
if Config.CTF.CapturePoints >= biggestAward then
	biggestName = "a flag capture"
end

print("Scoring balance:")
check("a round cannot be ended by one score",
	(function()
		for _, mode in Config.Modes do
			if (mode.ScoreLimit or 0) < biggestAward * 3 then return false end
		end
		return true
	end)(),
	string.format("biggest single award is %d (%s)", biggestAward, biggestName))

for _, mode in Config.Modes do
	check(string.format("%s has a score limit", mode.Name),
		(mode.ScoreLimit or 0) > 0, tostring(mode.ScoreLimit))
end

-- --------------------------------------------------------------- the arsenal
print("")
print("Weapons:")
local weaponCount, missingPoints, badNumbers, badSlots = 0, {}, {}, {}
for name, spec in Config.Weapons do
	weaponCount += 1
	if not spec.Points then table.insert(missingPoints, name) end
	if spec.Cooldown <= 0 or spec.MagSize <= 0 or spec.Range <= 0 then
		table.insert(badNumbers, name)
	end
	if spec.Slot < 0 or spec.Slot > 7 then table.insert(badSlots, name) end
	if spec.Kind ~= "Hitscan" and spec.Kind ~= "Projectile"
		and spec.Kind ~= "Arcing" and spec.Kind ~= "Rocket" and spec.Kind ~= "Homing"
	then
		table.insert(badNumbers, name .. " (kind " .. tostring(spec.Kind) .. ")")
	end
end

check("every weapon scores points", #missingPoints == 0, table.concat(missingPoints, ", "))
check("every weapon has sane numbers", #badNumbers == 0, table.concat(badNumbers, ", "))
check("every weapon sits in a real slot", #badSlots == 0, table.concat(badSlots, ", "))
check("the arsenal is not empty", weaponCount >= 16, string.format("%d weapons", weaponCount))

-- A projectile weapon with no speed would sit still in the air.
local noSpeed = {}
for name, spec in Config.Weapons do
	if spec.Kind ~= "Hitscan" and not spec.Speed then
		table.insert(noSpeed, name)
	end
end
check("travelling weapons have a speed", #noSpeed == 0, table.concat(noSpeed, ", "))

-- Anything that explodes needs both a radius and a damage, or it is a dud.
local halfExplosive = {}
for name, spec in Config.Weapons do
	local radius = spec.BlastRadius or 0
	local damage = spec.BlastDamage or 0
	if (radius > 0) ~= (damage > 0) then
		table.insert(halfExplosive, name)
	end
end
check("explosives have radius AND damage", #halfExplosive == 0, table.concat(halfExplosive, ", "))

-- ------------------------------------------------------------------- loadout
print("")
print("Loadout and slots:")
local missingFromArsenal = {}
for _, name in Config.StartingLoadout do
	if not Config.Weapons[name] then table.insert(missingFromArsenal, name) end
end
check("the starting loadout all exists", #missingFromArsenal == 0,
	table.concat(missingFromArsenal, ", "))

local mountedInLoadout = {}
for _, name in Config.StartingLoadout do
	local spec = Config.Weapons[name]
	if spec and spec.MountedOnly then table.insert(mountedInLoadout, name) end
end
check("no vehicle gun in the loadout", #mountedInLoadout == 0,
	table.concat(mountedInLoadout, ", "))

-- Every number key 1..7 should give you something.
local slotsUsed = {}
for _, spec in Config.Weapons do
	if not spec.MountedOnly then slotsUsed[spec.Slot] = true end
end
local emptySlots = {}
for slot = 1, 7 do
	if not slotsUsed[slot] then table.insert(emptySlots, tostring(slot)) end
end
check("every number key has a weapon", #emptySlots == 0,
	"empty: " .. table.concat(emptySlots, ", "))

-- ------------------------------------------------------------------ the maps
print("")
print("Maps and modes:")
local badMaps = {}
for _, map in Config.Maps do
	if map.Size < 400 or map.Buildings < 1 or map.MudFraction < 0 or map.MudFraction > 1 then
		table.insert(badMaps, map.Id)
	end
end
check("every map is sane", #badMaps == 0, table.concat(badMaps, ", "))
check("there are maps to vote on", #Config.Maps >= 3, string.format("%d maps", #Config.Maps))
check("the ballot can be filled", Config.Match.MapChoices <= #Config.Maps,
	string.format("%d choices from %d maps", Config.Match.MapChoices, #Config.Maps))
check("both modes are offered", #Config.Modes >= 2, string.format("%d modes", #Config.Modes))

-- -------------------------------------------------------------------- timing
print("")
print("Round timing:")
check("a round is long enough to be a round", Config.Match.RoundDuration >= 120,
	string.format("%ds", Config.Match.RoundDuration))
-- Halo's shield rhythm is the whole reason cover matters. A slow refill
-- quietly turns the game into one where you just die.
check("shields wait only a moment", Config.Combat.ShieldRegenDelay <= 4,
	string.format("%ds delay", Config.Combat.ShieldRegenDelay))
local shieldRefill = 50 / Config.Combat.ShieldRegenPerSecond
check("shields refill fast once they start", shieldRefill <= 3,
	string.format("%.1fs for a full 50", shieldRefill))
check("spawn protection is brief", Config.Combat.SpawnProtection <= 5,
	string.format("%ds", Config.Combat.SpawnProtection))
check("a dropped flag comes back", Config.CTF.DroppedReturnDelay > 0
	and Config.CTF.DroppedReturnDelay < Config.Match.RoundDuration,
	string.format("%ds", Config.CTF.DroppedReturnDelay))

-- ------------------------------------------------------------------- extras
print("")
print("Population and flavour:")
check("civilians have something to say", #Config.CivilianLines >= 4,
	string.format("%d lines", #Config.CivilianLines))
check("the map is populated",
	Config.Population.Zombies > 0 and Config.Population.Targets > 0,
	string.format("%d zombies, %d targets", Config.Population.Zombies, Config.Population.Targets))
check("boost pads do not launch you", Config.Boost.Lift == 0,
	string.format("lift %d", Config.Boost.Lift))
check("car tiers climb in speed", (function()
	for index = 2, #Config.CarTiers do
		if Config.CarTiers[index].MaxSpeed <= Config.CarTiers[index - 1].MaxSpeed then
			return false
		end
	end
	return true
end)(), string.format("%d tiers", #Config.CarTiers))

-- --------------------------------------------------------------------- sound
print("")
print("Sound:")
local soundCount, notBuiltIn, badVolume, badPitch = 0, {}, {}, {}
for name, spec in Config.Sounds do
	soundCount += 1
	-- A numeric asset ID can be wrong, moderated, or simply not load. An
	-- rbxasset:// path ships inside the client and cannot be any of those.
	if not string.match(spec.Asset, "^rbxasset://") then
		table.insert(notBuiltIn, name)
	end
	if spec.Volume <= 0 or spec.Volume > 2 then
		table.insert(badVolume, name)
	end
	local low = spec.Pitch and spec.Pitch[1]
	local high = spec.Pitch and spec.Pitch[2]
	if not low or low <= 0 or (high and high < low) then
		table.insert(badPitch, name)
	end
end

check("sounds are all engine built-ins", #notBuiltIn == 0, table.concat(notBuiltIn, ", "))
check("volumes are sane", #badVolume == 0, table.concat(badVolume, ", "))
check("pitch ranges are sane", #badPitch == 0, table.concat(badPitch, ", "))
check("the game is not silent", soundCount >= 15, string.format("%d sounds", soundCount))

-- Every weapon must map to a sound that actually exists, or firing it warns
-- at runtime and plays nothing.
local missingShot = {}
for name, spec in Config.Weapons do
	local soundName = Sound.ForWeapon(spec)
	if not Config.Sounds[soundName] then
		table.insert(missingShot, string.format("%s -> %s", name, tostring(soundName)))
	end
end
check("every weapon has a gunshot", #missingShot == 0, table.concat(missingShot, ", "))

-- Names referenced from code, checked here so a rename cannot quietly break
-- one of them.
local referenced = {
	"Hitmarker", "Headshot", "KillConfirm", "Death", "ShieldBreak",
	"MeleeSwing", "MeleeHit", "Pickup", "PickupBig", "WeaponSwitch",
	"FlagTaken", "FlagCapture", "RoundStart", "RoundEnd", "Medal",
	"EngineLoop", "Boost", "Splash", "Bell", "ZombieGrowl", "Fart",
	"ParachuteOpen", "Explosion", "ExplosionBig",
}
local missingReferenced = {}
for _, name in referenced do
	if not Config.Sounds[name] then
		table.insert(missingReferenced, name)
	end
end
check("every sound the code asks for exists", #missingReferenced == 0,
	table.concat(missingReferenced, ", "))

print("")
print(if failures == 0 then "CONFIG IS SANE" else failures .. " FAILURES")
"""

harness = (
    TEMPLATE
    .replace("--[[STUBS]]", read(HERE, "stubs.luau"))
    .replace("--[[CONFIG]]", strip(read(SRC, "shared", "Config.luau")))
    .replace("--[[SOUND]]", strip(read(SRC, "shared", "Sound.luau")))
)

sys.stdout.write(harness)
