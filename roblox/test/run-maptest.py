#!/usr/bin/env python3
"""
Run the map generator outside Roblox.

Roblox Studio cannot be scripted from a terminal, so this stitches the real
MapService together with the stand-ins in stubs.luau and executes it with the
plain Luau interpreter. It proves the generator runs without erroring and that
what it produces is sane: ground exists, spawns exist, no broken geometry, the
configured number of buildings actually got built, and -- the one that used to
be wrong -- that no building stands in the middle of a road.

    python3 test/run-maptest.py | luau /dev/stdin

or write it to a file first:

    python3 test/run-maptest.py > /tmp/maptest.luau && luau /tmp/maptest.luau
"""
import os
import re
import sys

CITY_CHECK = '\t-- ------------------------------------------------- is it actually a city?\n\t--\n\t-- Buildings used to be scattered at random, independent of the street\n\t-- grid, so they stood in the middle of roads and the streets led nowhere.\n\t-- These two checks are the invariants that fix introduced.\n\n\t-- One rooftop HVAC unit per building, built before any early return, so\n\t-- this is an exact count. The lips used to stand in for it, which was\n\t-- already off by a quarter (a ramped building has three, not four) and\n\t-- went properly wrong the moment the ramp gap widened to two faces.\n\tlocal built = named["RoofHVAC"] or 0\n\tif built < math.floor(spec.Buildings * 0.7) then\n\t\tprint(string.format("      ^ ONLY %d OF %d BUILDINGS FIT", built, spec.Buildings))\n\t\tfailures += 1\n\tend\n\n\t-- Work the carriageways out of the generated Street parts rather than\n\t-- assuming them, so the check cannot drift away from the generator.\n\tlocal lanesX, lanesZ, roadWidth = {}, {}, math.huge\n\tfor _, part in STATS.parts do\n\t\tif part._props.Name == "Street" then\n\t\t\tlocal size = part._props.Size\n\t\t\tlocal at = part._props.CFrame.Position\n\t\t\tif size.X < size.Z then\n\t\t\t\ttable.insert(lanesX, at.X)\n\t\t\t\troadWidth = math.min(roadWidth, size.X)\n\t\t\telse\n\t\t\t\ttable.insert(lanesZ, at.Z)\n\t\t\t\troadWidth = math.min(roadWidth, size.Z)\n\t\t\tend\n\t\tend\n\tend\n\n\t-- Ramps and jumps belong ON the road. Structure never does.\n\tlocal blocking = {\n\t\tWall = true, Floor = true, Step = true, RoofLip = true,\n\t\tPlaza = true, Mud = true, Cover = true, Barricade = true,\n\t}\n\tlocal inRoad = 0\n\tlocal worst = ""\n\tlocal byName = {}\n\tfor _, part in STATS.parts do\n\t\tif blocking[part._props.Name] then\n\t\t\tlocal at = part._props.CFrame.Position\n\t\t\tlocal size = part._props.Size\n\t\t\tfor _, lane in lanesX do\n\t\t\t\t-- How far the part reaches past the kerb, if at all.\n\t\t\t\tlocal intrusion = roadWidth * 0.5 - (math.abs(at.X - lane) - size.X * 0.5)\n\t\t\t\tif intrusion > 1 then\n\t\t\t\t\tinRoad += 1\n\t\t\t\t\tbyName[part._props.Name] = (byName[part._props.Name] or 0) + 1\n\t\t\t\t\tworst = string.format("%s %.0f studs into the x=%.0f road", part._props.Name, intrusion, lane)\n\t\t\t\t\tbreak\n\t\t\t\tend\n\t\t\tend\n\t\t\tfor _, lane in lanesZ do\n\t\t\t\tlocal intrusion = roadWidth * 0.5 - (math.abs(at.Z - lane) - size.Z * 0.5)\n\t\t\t\tif intrusion > 1 then\n\t\t\t\t\tinRoad += 1\n\t\t\t\t\tbyName[part._props.Name] = (byName[part._props.Name] or 0) + 1\n\t\t\t\t\tworst = string.format("%s %.0f studs into the z=%.0f road", part._props.Name, intrusion, lane)\n\t\t\t\t\tbreak\n\t\t\t\tend\n\t\t\tend\n\t\tend\n\tend\n\n\tlocal breakdown = {}\n\tfor name, count in byName do\n\t\ttable.insert(breakdown, string.format("%s x%d", name, count))\n\tend\n\ttable.sort(breakdown)\n\tprint(string.format("      buildings=%-3d in-road=%-4d %s | %s",\n\t\tbuilt, inRoad, table.concat(breakdown, " "), worst))\n\tif inRoad > 0 then failures += 1 end\n\n\n\t--[[\n\t\tAnything gameplay RAYCASTS for has to be queryable.\n\n\t\tThe river\'s FlowZone parts were created with CanQuery = false, and a\n\t\traycast cannot hit a part with CanQuery off -- so the current could\n\t\tnever have moved a tube in the real game. The drive test passed\n\t\tanyway, because a headless harness stubs workspace:Raycast and hands\n\t\tback whatever the test wants. No amount of behavioural testing finds\n\t\tthis; only looking at the flag does.\n\t]]\n\tlocal unqueryable = {}\n\tfor _, part in STATS.parts do\n\t\tlocal name = part._props.Name\n\t\t-- These are the parts the game casts a ray at to decide something.\n\t\tif name == "FlowZone" or name == "BoostPad" or name == "Piste"\n\t\t\tor name == "Ice" or name == "Mud"\n\t\tthen\n\t\t\tif part._props.CanQuery == false then\n\t\t\t\ttable.insert(unqueryable, name)\n\t\t\tend\n\t\tend\n\tend\n\tif #unqueryable > 0 then\n\t\tprint(string.format("      ^ NOT QUERYABLE, SO RAYCASTS MISS THEM: %s",\n\t\t\ttable.concat(unqueryable, ", ")))\n\t\tfailures += 1\n\tend\n\n\t--[[\n\t\tEvery activity got a beacon.\n\n\t\tThe beacons are generated FROM the venue registry, so building them\n\t\tbefore the last builder has registered gives beacons to only some of\n\t\tthe activities. That reads as a missing beacon rather than as an\n\t\tordering mistake, and nobody goes looking for it.\n\t]]\n\tif BEACONS_SAW < 0 then\n\t\tprint("      ^ BEACONS WERE NEVER BUILT")\n\t\tfailures += 1\n\telseif BEACONS_SAW < #ARCADE_REGISTERED then\n\t\tprint(string.format("      ^ BEACONS BUILT TOO EARLY: saw %d of %d activities",\n\t\t\tBEACONS_SAW, #ARCADE_REGISTERED))\n\t\tfailures += 1\n\tend\n\n\t--[[\n\t\tNothing is left hanging when its support is destroyed.\n\n\t\tThe sandbags along the top of a barricade used to be siblings of the\n\t\twall rather than children of it, so blowing the barricade apart left\n\t\tthree of them floating in mid-air where the top had been -- which\n\t\tlooked like a glitch and was still shootable cover at head height\n\t\twith nothing underneath. Destroy takes descendants, so being a child\n\t\tis what makes them go together.\n\t]]\n\tlocal orphanBags = 0\n\tfor _, part in STATS.parts do\n\t\tif part._props.Name == "Sandbag" then\n\t\t\tlocal parent = part._parent\n\t\t\tif not parent or parent._props.Name ~= "Barricade" then\n\t\t\t\torphanBags += 1\n\t\t\tend\n\t\tend\n\tend\n\tif orphanBags > 0 then\n\t\tprint(string.format("      ^ %d SANDBAGS WOULD SURVIVE THEIR WALL", orphanBags))\n\t\tfailures += 1\n\tend\n\n\t--[[\n\t\tEvery venue\'s ground is clear of the city.\n\n\t\tMost venues are built AFTER the city, so they cannot be measured\n\t\twhile it is being laid out -- only declared. That split is how the\n\t\tcarnival ended up with buildings in it: its builder knew where it\n\t\twas and the city did not, and the basketball court and bowling alley\n\t\tarrived with the same gap because nothing connected the two numbers.\n\n\t\tBoth now read Config.Venues, and this fails if anything structural\n\t\tstands inside one -- so a venue added without a footprint is caught\n\t\there rather than by somebody finding a warehouse on the dunk tank.\n\t]]\n\tlocal structural = {\n\t\tWall = true, Floor = true, Step = true, RoofLip = true,\n\t\tBarricade = true, Sandbag = true, Cover = true, Bench = true,\n\t}\n\tlocal intruders = {}\n\tfor name, spot in Config.Venues do\n\t\tlocal at = Config.VenueCentre(name, spec.Size)\n\t\tfor _, part in STATS.parts do\n\t\t\tif structural[part._props.Name] then\n\t\t\t\tlocal here = part._props.CFrame.Position\n\t\t\t\tlocal flat = Vector3.new(here.X - at.X, 0, here.Z - at.Z)\n\t\t\t\tif flat.Magnitude < spot.radius then\n\t\t\t\t\tintruders[name] = (intruders[name] or 0) + 1\n\t\t\t\tend\n\t\t\tend\n\t\tend\n\tend\n\tlocal worstVenue, worstCount = nil, 0\n\tfor name, count in intruders do\n\t\tif count > worstCount then\n\t\t\tworstVenue, worstCount = name, count\n\t\tend\n\tend\n\tif worstVenue then\n\t\tprint(string.format("      ^ CITY BUILT INSIDE %s: %d parts",\n\t\t\tstring.upper(worstVenue), worstCount))\n\t\tfailures += 1\n\tend\n\n\t--[[\n\t\tNo sky bridge ends inside a building.\n\n\t\tA bridge is drawn at the LOWER of the two roofs it joins, so if the\n\t\troofs differ the far end is below the taller tower\'s roofline --\n\t\twhich means the deck passes through its wall and stops inside the\n\t\ttop floor. From the street it reads as a slab sticking out of a wall\n\t\tfor no reason.\n\n\t\tChecked on the pairing rather than on geometry, because the pairing\n\t\tis the decision: two roofs within a step of each other can always be\n\t\tbridged, and two that are not, cannot.\n\t]]\n\tlocal piercing = 0\n\tlocal worstGap = 0\n\tfor _, span in MapService.BridgesForTests() do\n\t\tlocal difference = math.abs(span.aRoof - span.bRoof)\n\t\tif difference > 6 then\n\t\t\tpiercing += 1\n\t\t\tworstGap = math.max(worstGap, difference)\n\t\tend\n\tend\n\tif piercing > 0 then\n\t\tprint(string.format("      ^ %d SKY BRIDGES END INSIDE A BUILDING (worst %.0f studs below the roof)",\n\t\t\tpiercing, worstGap))\n\t\tfailures += 1\n\tend\n\n\t--[[\n\t\tThe vehicle ramp actually reaches the roof.\n\n\t\tA building\'s roof lip is left open where the switchback arrives, and\n\t\tthat gap was hardcoded to the -Z face while the arrival corner MOVES\n\t\twith the storey count -- so on half the buildings the car drove up ten\n\t\tfloors and hit a wall, and on the other half it caught the lip on the\n\t\tperpendicular face. Nothing about that is visible from the code: both\n\t\tparts are built correctly, just not in agreement.\n\n\t\tChecked by walking the roof ramp\'s centreline and asking whether any\n\t\tlip stands on it, which is the question a driver asks.\n\t]]\n\tlocal lips = {}\n\tfor _, part in STATS.parts do\n\t\tif part._props.Name == "RoofLip" then\n\t\t\ttable.insert(lips, part._props)\n\t\tend\n\tend\n\n\tlocal blockedRamps = 0\n\tlocal worstBlock = ""\n\tfor _, part in STATS.parts do\n\t\tif part._props.Name ~= "RoofRamp" then\n\t\t\tcontinue\n\t\tend\n\t\tlocal cf = part._props.CFrame\n\t\tlocal length = part._props.Size.Z\n\t\tlocal halfWidth = part._props.Size.X * 0.5\n\t\tlocal tail = cf.Position - cf.LookVector * (length * 0.5)\n\t\tlocal blocker = nil\n\t\tfor step = 0, 24 do\n\t\t\tlocal here = tail + cf.LookVector * (length * (step / 24))\n\t\t\tfor _, lip in lips do\n\t\t\t\tlocal at = lip.CFrame.Position\n\t\t\t\t-- Only lips on this roof, not one across the street.\n\t\t\t\tif math.abs(at.Y - cf.Position.Y) > 8 then\n\t\t\t\t\tcontinue\n\t\t\t\tend\n\t\t\t\t-- The ramp is wide, so clipping its edge still stops a car.\n\t\t\t\tlocal reachX = lip.Size.X * 0.5 + (if lip.Size.X < lip.Size.Z then halfWidth else 0)\n\t\t\t\tlocal reachZ = lip.Size.Z * 0.5 + (if lip.Size.Z < lip.Size.X then halfWidth else 0)\n\t\t\t\tif math.abs(here.X - at.X) < reachX and math.abs(here.Z - at.Z) < reachZ then\n\t\t\t\t\tblocker = string.format("at x=%.0f z=%.0f", at.X, at.Z)\n\t\t\t\t\tbreak\n\t\t\t\tend\n\t\t\tend\n\t\t\tif blocker then\n\t\t\t\tbreak\n\t\t\tend\n\t\tend\n\t\tif blocker then\n\t\t\tblockedRamps += 1\n\t\t\tworstBlock = blocker\n\t\tend\n\tend\n\tif blockedRamps > 0 then\n\t\tprint(string.format("      ^ %d OF %d ROOF RAMPS ARE WALLED OFF BY A ROOF LIP (%s)",\n\t\t\tblockedRamps, built, worstBlock))\n\t\tfailures += 1\n\tend\n'

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src")


def read(*parts):
    with open(os.path.join(*parts)) as handle:
        return handle.read()


def strip_requires(source):
    """Drop the Roblox service lookups; the harness supplies those directly."""
    kept = []
    for line in source.split("\n"):
        if re.match(r"^local \w+ = game:GetService\(", line):
            continue
        if re.match(r"^local Shared = ", line):
            continue
        if re.match(r"^local \w+ = require\(", line):
            continue
        kept.append(line)
    return "\n".join(kept)


harness = f"""
{read(HERE, "stubs.luau")}

local Util = (function()
{read(SRC, "shared", "Util.luau")}
end)()

local Config = (function()
{read(SRC, "shared", "Config.luau")}
end)()

-- The resort and the rink both offer themselves as sub-games now. A map test
-- does not care which games exist, only that the geometry builds, so this
-- records the registrations and ignores them.
ARCADE_REGISTERED = {{}}
-- How many venues existed when the beacons were built. The beacons are
-- generated FROM the registry, so building them before every builder has
-- registered silently gives beacons to only some activities -- which looks
-- like a missing beacon rather than like an ordering mistake, and is exactly
-- the sort of thing nobody goes looking for.
BEACONS_SAW = -1
local ArcadeService = {{
	Register = function(info) table.insert(ARCADE_REGISTERED, info) end,
	BuildBeacons = function() BEACONS_SAW = #ARCADE_REGISTERED end,
}}

local ResortService = (function()
local ArcadeService = ArcadeService
local Util = Util
-- The chairlift runs on a Heartbeat now, so the resort needs RunService.
local RunService = game:GetService("RunService")
{strip_requires(read(SRC, "server", "modules", "ResortService.luau"))}
end)()

local Signal = (function()
{read(SRC, "shared", "Signal.luau")}
end)()

local HockeyService = (function()
local ArcadeService = ArcadeService
local Util = Util
local Config = Config
local Signal = Signal
-- MapService only asks this module where the rink sits. The rest of it needs
-- remotes, sound and player state, none of which a map test has or wants.
local Remotes = {{ Event = function() return {{ FireClient = function() end, FireAllClients = function() end, OnServerEvent = {{ Connect = function() end }} }} end }}
local Sound = {{ At = function() end, Flat = function() end, ForWeapon = function() return "GunGeneric" end }}
local PlayerState = {{ Get = function() return {{ weapons = {{}} }} end, AwardPoints = function() end, Changed = {{ Fire = function() end }} }}
{strip_requires(read(SRC, "server", "modules", "HockeyService.luau"))}
end)()

local MapService = (function()
local Util = Util
local ResortService = ResortService
local HockeyService = HockeyService
{strip_requires(read(SRC, "server", "modules", "MapService.luau"))}
end)()

local teamColours = {{ BrickColor.new("Bright red"), BrickColor.new("Bright blue") }}
local failures = 0

for _, spec in Config.Maps do
	STATS.created = 0
	STATS.byClass = {{}}
	STATS.parts = {{}}

	local ok, err = pcall(function()
		return MapService.Build(spec, teamColours)
	end)

	if not ok then
		print(string.format("FAIL  %-18s %s", spec.Id, tostring(err)))
		failures += 1
		continue
	end

	local named = {{}}
	local bad = 0
	local minY, maxY = math.huge, -math.huge

	for _, part in STATS.parts do
		local cframe = part._props.CFrame
		local size = part._props.Size
		named[part._props.Name] = (named[part._props.Name] or 0) + 1
		if cframe then
			local y = cframe.Position.Y
			if y ~= y or y == math.huge or y == -math.huge then
				bad += 1
			else
				minY = math.min(minY, y)
				maxY = math.max(maxY, y)
			end
		end
		if size and (size.X ~= size.X or size.X <= 0 or size.Y <= 0 or size.Z <= 0) then
			bad += 1
		end
	end

	print(string.format(
		"ok    %-18s parts=%-5d spawns=%-2d y=%.0f..%.0f bad=%d streets=%d stairs=%d walls=%d floors=%d ramps=%d",
		spec.Id, #STATS.parts, STATS.byClass["SpawnLocation"] or 0, minY, maxY, bad,
		named["Street"] or 0, named["Step"] or 0, named["Wall"] or 0,
		named["Floor"] or 0, named["Ramp"] or 0
	))

--[[CITYCHECK]]
	if bad > 0 then failures += 1 end
	if (STATS.byClass["SpawnLocation"] or 0) < 2 then
		print("      ^ NOT ENOUGH SPAWNS")
		failures += 1
	end
	if (named["Ground"] or 0) < 1 then
		print("      ^ NO GROUND")
		failures += 1
	end
end

print("")
print(if failures == 0 then "ALL MAPS BUILD CLEAN" else string.format("%d FAILURES", failures))

--[[
	Exit non-zero on failure.

	Without this the suite only PRINTED its failures and exited 0, so
	run-all.sh reported success no matter what broke, and any automation
	trusting its exit code was being told a comforting lie. error() at the
	top level is what makes the luau CLI exit non-zero.
]]
if failures > 0 then
	error("maps: " .. failures .. " failures", 0)
end
"""

sys.stdout.write(harness.replace('--[[CITYCHECK]]', CITY_CHECK))
