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
local badRecoil = {}
for name, spec in Config.Weapons do
	weaponCount += 1
	if not spec.Points then table.insert(missingPoints, name) end

	-- Camera kick. Zero would mean a weapon that feels like nothing at all,
	-- and anything past the module's own cap would be a weapon that spins
	-- the view somewhere a player cannot recover from.
	if type(spec.Recoil) ~= "number" or spec.Recoil <= 0 or spec.Recoil > 5 then
		table.insert(badRecoil, name .. " = " .. tostring(spec.Recoil))
	end
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
check("every weapon has a camera kick", #badRecoil == 0, table.concat(badRecoil, ", "))
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

--[[
	The stand-ins themselves.

	Roughly half the bugs found in this project were holes in this harness
	rather than in the game, and a hole here does not announce itself -- it
	shows up as a suite that passes while the real game is broken, or as
	correct code that looks broken for no reason. So the stand-ins get their
	own checks, on the specific behaviours that have already bitten.
]]
print("")
print("Remotes:")
--[[REMOTECHECKS]]

print("")
print("Lighting ownership:")
--[[LIGHTINGCHECK]]

print("")
print("The harness itself:")

do
	-- GetChildren must COPY. Returning the live array meant the completely
	-- ordinary destroy-every-child loop walked a table that was shrinking
	-- underneath it and cleared about every other one.
	local parent = Instance.new("Folder")
	for index = 1, 6 do
		local child = Instance.new("Part")
		child._props.Name = "Child" .. index
		child.Parent = parent
	end

	local snapshot = parent:GetChildren()
	check("GetChildren returns a copy, not the live list",
		snapshot ~= rawget(parent, "_children"), "")

	for _, child in parent:GetChildren() do
		child:Destroy()
	end
	check("destroying every child in a loop clears all of them",
		#parent:GetChildren() == 0,
		string.format("%d left behind", #parent:GetChildren()))
end

do
	-- Destroy must be recursive. A great deal of this code guards on
	-- `thing.Parent` to ask "does this still exist?" -- a delayed callback
	-- checking a humanoid before touching it, a respawn timer checking its
	-- own part. A shallow Destroy answered "still here" for every
	-- descendant of a destroyed model, so lifetime bugs were invisible.
	local model = Instance.new("Model")
	local limb = Instance.new("Part")
	limb.Parent = model
	local nested = Instance.new("Part")
	nested.Parent = limb
	model.Parent = workspace

	model:Destroy()
	check("Destroy unparents the instance", model.Parent == nil, "")
	check("Destroy reaches its children", limb.Parent == nil, tostring(limb.Parent))
	check("Destroy reaches grandchildren", nested.Parent == nil, tostring(nested.Parent))
end

do
	local parent = Instance.new("Folder")
	for _ = 1, 4 do
		Instance.new("Part").Parent = parent
	end
	parent:ClearAllChildren()
	check("ClearAllChildren empties without destroying the parent",
		#parent:GetChildren() == 0 and parent ~= nil,
		string.format("%d left", #parent:GetChildren()))
end

do
	-- Destroy is idempotent, and locks Parent afterwards the way Roblox
	-- does. Letting a destroyed instance back into the world let a test
	-- resurrect something the engine would refuse, and hid stale-reference
	-- bugs where code hangs on to a thing after cleaning it up.
	local part = Instance.new("Part")
	part._props.Name = "Doomed"
	part.Parent = workspace
	part:Destroy()

	local twice = pcall(function()
		part:Destroy()
	end)
	check("destroying twice is not an error", twice, "")

	local reparented = pcall(function()
		part.Parent = workspace
	end)
	check("a destroyed instance cannot be re-parented", not reparented, "")
end

do
	-- A destroyed part's handlers must stop firing. A Touched that still
	-- works after Destroy makes a test pass that the real game would fail,
	-- which is the one thing a harness must never do.
	local prompt = Instance.new("ProximityPrompt")
	local fired = 0
	local triggered = prompt._props.Triggered
	triggered:Connect(function()
		fired += 1
	end)
	triggered._fire()
	check("a live prompt's handler fires", fired == 1, string.format("%d", fired))

	prompt:Destroy()
	triggered._fire()
	check("a destroyed instance's handler does not fire", fired == 1,
		string.format("%d after destroy", fired))
end

do
	-- Disconnect has to actually disconnect. It was a no-op, so anything
	-- that unsubscribes to avoid doing work twice looked correct while
	-- doing it twice.
	local prompt = Instance.new("ProximityPrompt")
	local triggered = prompt._props.Triggered
	local runs = 0
	local connection = triggered:Connect(function()
		runs += 1
	end)
	triggered._fire()
	connection:Disconnect()
	triggered._fire()
	check("Disconnect stops the handler", runs == 1,
		string.format("%d runs after disconnecting", runs))
end

do
	-- Enum items have to be the SAME value each time or no comparison
	-- against one can ever be true -- which is how it was discovered that
	-- no keyboard input had ever actually been testable.
	check("an Enum item is the same value every time",
		Enum.KeyCode.F == Enum.KeyCode.F, "")
	check("and two different items are not equal",
		Enum.KeyCode.F ~= Enum.KeyCode.Q, "")
end

print("")
print(if failures == 0 then "CONFIG IS SANE" else failures .. " FAILURES")

--[[
	Exit non-zero on failure.

	Without this the suite only PRINTED its failures and exited 0, so
	run-all.sh reported success no matter what broke, and any automation
	trusting its exit code was being told a comforting lie. error() at the
	top level is what makes the luau CLI exit non-zero.
]]
if failures > 0 then
	error("config: " .. failures .. " failures", 0)
end
"""


# ----------------------------------------------------------------------------
# Who writes Lighting?
#
# Global lighting is one shared resource with no merge: the last writer wins
# and the loser cannot tell it lost. Two modules each setting a look they are
# happy with produces a third look neither wanted, and which one you get
# depends on service start order -- so it changes between runs and cannot be
# reproduced. GraphicsService owns it; a venue that wants its own mood uses
# local SpotLight and PointLight rigs inside itself.
#
# This is checked by reading the source rather than by watching writes at run
# time, because the writes that matter are the ones in code paths a test may
# never reach.
LIGHTING_OWNER = "GraphicsService.luau"


def lighting_trespassers():
    offenders = []
    for folder in ("server", "client", "shared"):
        base = os.path.join(SRC, folder)
        if not os.path.isdir(base):
            continue
        for root, _dirs, names in os.walk(base):
            for name in sorted(names):
                if not name.endswith(".luau") or name == LIGHTING_OWNER:
                    continue
                path = os.path.join(root, name)
                with open(path, encoding="utf-8") as handle:
                    for number, line in enumerate(handle, 1):
                        stripped = line.strip()
                        # Comments are allowed to mention it; prose about the
                        # rule is not a violation of the rule.
                        if stripped.startswith("--"):
                            continue
                        if re.search(r"\bLighting\.\w+\s*=", line) or re.search(
                            r'GetService\(\s*"Lighting"\s*\)', line
                        ):
                            offenders.append("%s:%d" % (name, number))
    return offenders


TRESPASSERS = lighting_trespassers()
LIGHTING_CHECK = (
    'check("GraphicsService is the only module that touches Lighting", %s, %s)'
    % (
        "true" if not TRESPASSERS else "false",
        '""' if not TRESPASSERS else '"' + ", ".join(TRESPASSERS) + '"',
    )
)


# ----------------------------------------------------------------------------
# Is anybody listening?
#
# Every one of the four sub-game remotes was fired by the server and handled
# by nobody. Hud had the menu panel, the offer banner and the join toast all
# built; Controls had SetMenuOrder and SetPendingOffer with no callers. So
# pressing B asked the server for the menu, the server answered, and nothing
# happened -- which is the literal cause of "I cannot figure out how to play
# the different games". Every piece existed and none of them were connected.
#
# Nothing catches that by behaviour: both halves are correct on their own and
# the suite exercises each in isolation quite happily. It is only visible by
# asking, across the whole tree, whether each message has a reader.

FIRE_TO_CLIENT = re.compile(r'Remotes\.Event\(\s*"([A-Za-z]+)"\s*\)\s*:\s*Fire(?:All)?Clients?\b')
ON_CLIENT = re.compile(r'Remotes\.Event\(\s*"([A-Za-z]+)"\s*\)\s*\.\s*OnClientEvent')
FIRE_TO_SERVER = re.compile(r'Remotes\.Event\(\s*"([A-Za-z]+)"\s*\)\s*:\s*FireServer\b')
ON_SERVER = re.compile(r'Remotes\.Event\(\s*"([A-Za-z]+)"\s*\)\s*\.\s*OnServerEvent')


def scan(folders, pattern):
    found = set()
    for folder in folders:
        base = os.path.join(SRC, folder)
        if not os.path.isdir(base):
            continue
        for root, _dirs, names in os.walk(base):
            for name in sorted(names):
                if not name.endswith(".luau"):
                    continue
                with open(os.path.join(root, name), encoding="utf-8") as handle:
                    for line in handle:
                        if line.strip().startswith("--"):
                            continue
                        for hit in pattern.findall(line):
                            found.add(hit)
    return found


SENT_DOWN = scan(["server"], FIRE_TO_CLIENT)
HEARD_DOWN = scan(["client", "shared"], ON_CLIENT)
SENT_UP = scan(["client", "shared"], FIRE_TO_SERVER)
HEARD_UP = scan(["server"], ON_SERVER)

DEAF_CLIENT = sorted(SENT_DOWN - HEARD_DOWN)
DEAF_SERVER = sorted(SENT_UP - HEARD_UP)

# And the other way round: a handler nobody ever triggers.
#
# The first version of this check only looked for messages with no reader.
# It missed the mirror image -- a READER with no message -- which is how
# HockeyShoot survived: the server had a handler for shooting the puck, the
# client never sent it, and the only symptom was that you could pick the
# puck up and then not do anything with it. A feature that is half wired is
# indistinguishable from a feature that is finished until somebody tries it.
UNTRIGGERED_SERVER = sorted(HEARD_UP - SENT_UP)
UNTRIGGERED_CLIENT = sorted(HEARD_DOWN - SENT_DOWN)


def verdict(label, missing):
    return 'check("%s", %s, %s)' % (
        label,
        "true" if not missing else "false",
        '""' if not missing else '"' + ", ".join(missing) + '"',
    )


REMOTE_CHECKS = "\n".join([
    verdict("every remote the server fires has a client listening", DEAF_CLIENT),
    verdict("every remote the client fires has a server listening", DEAF_SERVER),
    verdict("every server handler is actually reachable", UNTRIGGERED_SERVER),
    verdict("every client handler is actually reachable", UNTRIGGERED_CLIENT),
])

harness = (
    TEMPLATE
    .replace("--[[REMOTECHECKS]]", REMOTE_CHECKS)
    .replace("--[[LIGHTINGCHECK]]", LIGHTING_CHECK)
    .replace("--[[STUBS]]", read(HERE, "stubs.luau"))
    .replace("--[[CONFIG]]", strip(read(SRC, "shared", "Config.luau")))
    .replace("--[[SOUND]]", strip(read(SRC, "shared", "Sound.luau")))
)

sys.stdout.write(harness)
