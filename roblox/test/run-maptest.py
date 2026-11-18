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

CITY_CHECK = '\t-- ------------------------------------------------- is it actually a city?\n\t--\n\t-- Buildings used to be scattered at random, independent of the street\n\t-- grid, so they stood in the middle of roads and the streets led nowhere.\n\t-- These two checks are the invariants that fix introduced.\n\n\t-- Every building has four roof lips, so that count is the building count.\n\tlocal built = math.floor((named["RoofLip"] or 0) / 4)\n\tif built < math.floor(spec.Buildings * 0.7) then\n\t\tprint(string.format("      ^ ONLY %d OF %d BUILDINGS FIT", built, spec.Buildings))\n\t\tfailures += 1\n\tend\n\n\t-- Work the carriageways out of the generated Street parts rather than\n\t-- assuming them, so the check cannot drift away from the generator.\n\tlocal lanesX, lanesZ, roadWidth = {}, {}, math.huge\n\tfor _, part in STATS.parts do\n\t\tif part._props.Name == "Street" then\n\t\t\tlocal size = part._props.Size\n\t\t\tlocal at = part._props.CFrame.Position\n\t\t\tif size.X < size.Z then\n\t\t\t\ttable.insert(lanesX, at.X)\n\t\t\t\troadWidth = math.min(roadWidth, size.X)\n\t\t\telse\n\t\t\t\ttable.insert(lanesZ, at.Z)\n\t\t\t\troadWidth = math.min(roadWidth, size.Z)\n\t\t\tend\n\t\tend\n\tend\n\n\t-- Ramps and jumps belong ON the road. Structure never does.\n\tlocal blocking = {\n\t\tWall = true, Floor = true, Step = true, RoofLip = true,\n\t\tPlaza = true, Mud = true, Cover = true, Barricade = true,\n\t}\n\tlocal inRoad = 0\n\tlocal worst = ""\n\tlocal byName = {}\n\tfor _, part in STATS.parts do\n\t\tif blocking[part._props.Name] then\n\t\t\tlocal at = part._props.CFrame.Position\n\t\t\tlocal size = part._props.Size\n\t\t\tfor _, lane in lanesX do\n\t\t\t\t-- How far the part reaches past the kerb, if at all.\n\t\t\t\tlocal intrusion = roadWidth * 0.5 - (math.abs(at.X - lane) - size.X * 0.5)\n\t\t\t\tif intrusion > 1 then\n\t\t\t\t\tinRoad += 1\n\t\t\t\t\tbyName[part._props.Name] = (byName[part._props.Name] or 0) + 1\n\t\t\t\t\tworst = string.format("%s %.0f studs into the x=%.0f road", part._props.Name, intrusion, lane)\n\t\t\t\t\tbreak\n\t\t\t\tend\n\t\t\tend\n\t\t\tfor _, lane in lanesZ do\n\t\t\t\tlocal intrusion = roadWidth * 0.5 - (math.abs(at.Z - lane) - size.Z * 0.5)\n\t\t\t\tif intrusion > 1 then\n\t\t\t\t\tinRoad += 1\n\t\t\t\t\tbyName[part._props.Name] = (byName[part._props.Name] or 0) + 1\n\t\t\t\t\tworst = string.format("%s %.0f studs into the z=%.0f road", part._props.Name, intrusion, lane)\n\t\t\t\t\tbreak\n\t\t\t\tend\n\t\t\tend\n\t\tend\n\tend\n\n\tlocal breakdown = {}\n\tfor name, count in byName do\n\t\ttable.insert(breakdown, string.format("%s x%d", name, count))\n\tend\n\ttable.sort(breakdown)\n\tprint(string.format("      buildings=%-3d in-road=%-4d %s | %s",\n\t\tbuilt, inRoad, table.concat(breakdown, " "), worst))\n\tif inRoad > 0 then failures += 1 end\n\n\n\t--[[\n\t\tAnything gameplay RAYCASTS for has to be queryable.\n\n\t\tThe river\'s FlowZone parts were created with CanQuery = false, and a\n\t\traycast cannot hit a part with CanQuery off -- so the current could\n\t\tnever have moved a tube in the real game. The drive test passed\n\t\tanyway, because a headless harness stubs workspace:Raycast and hands\n\t\tback whatever the test wants. No amount of behavioural testing finds\n\t\tthis; only looking at the flag does.\n\t]]\n\tlocal unqueryable = {}\n\tfor _, part in STATS.parts do\n\t\tlocal name = part._props.Name\n\t\t-- These are the parts the game casts a ray at to decide something.\n\t\tif name == "FlowZone" or name == "BoostPad" or name == "Piste"\n\t\t\tor name == "Ice" or name == "Mud"\n\t\tthen\n\t\t\tif part._props.CanQuery == false then\n\t\t\t\ttable.insert(unqueryable, name)\n\t\t\tend\n\t\tend\n\tend\n\tif #unqueryable > 0 then\n\t\tprint(string.format("      ^ NOT QUERYABLE, SO RAYCASTS MISS THEM: %s",\n\t\t\ttable.concat(unqueryable, ", ")))\n\t\tfailures += 1\n\tend\n'

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
local ArcadeService = {{
	Register = function(info) table.insert(ARCADE_REGISTERED, info) end,
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
