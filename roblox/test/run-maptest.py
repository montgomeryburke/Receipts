#!/usr/bin/env python3
"""
Run the map generator outside Roblox.

Roblox Studio cannot be scripted from a terminal, so this stitches the real
MapService together with the stand-ins in stubs.luau and executes it with the
plain Luau interpreter. It proves the generator runs without erroring and that
what it produces is sane: ground exists, spawns exist, no broken geometry.

    python3 test/run-maptest.py | luau /dev/stdin

or write it to a file first:

    python3 test/run-maptest.py > /tmp/maptest.luau && luau /tmp/maptest.luau
"""
import os
import re
import sys

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

local MapService = (function()
local Util = Util
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
"""

sys.stdout.write(harness)
