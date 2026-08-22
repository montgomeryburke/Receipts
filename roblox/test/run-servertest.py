#!/usr/bin/env python3
"""
Run the entire server bootstrap outside Roblox.

Roblox Studio cannot be driven from a terminal, so this stitches every real
server module together with stand-ins for the Roblox API and executes
init.server.luau completely unmodified. It answers the one question that
matters: does opening this place actually produce a world?

    python3 test/run-servertest.py > /tmp/a.luau && luau /tmp/a.luau
    python3 test/run-servertest.py --block-datastore > /tmp/b.luau && luau /tmp/b.luau

The second run simulates an UNPUBLISHED place, where Roblox refuses DataStore
access. That exact case once killed the server script before it built the
arena, and players fell through an empty sky. Both runs must print ARENA: true.
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'src')
BLOCK_DATASTORE = '--block-datastore' in sys.argv

def read(*p): return open(os.path.join(*p)).read()

def strip(s):
    out = []
    for line in s.split('\n'):
        if re.match(r'^local \w+ = game:GetService\(', line): continue
        if re.match(r'^local Shared = ', line): continue
        if re.match(r'^local \w+ = require\(', line): continue
        out.append(line)
    return '\n'.join(out)

SHARED = ['Config', 'Signal', 'Util', 'Remotes']
SERVER = ['PlayerState', 'MapService', 'VehicleService', 'DamageService', 'WildlifeService',
          'CarnivalService', 'ProjectileService', 'WeaponService', 'TeamService', 'PickupService',
          'EffectService', 'FlagService', 'MonetizationService', 'MatchService', 'GraphicsService']

parts = [read(HERE, 'stubs.luau'), read(HERE, 'serverstubs.luau')]
parts.append(f'DATASTORE_THROWS = {"true" if BLOCK_DATASTORE else "false"}\n')
parts.append('''
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
''')

for n in SHARED:
    parts.append(f'local {n} = (function()\n{strip(read(SRC, "shared", n + ".luau"))}\nend)()\n')
for n in SERVER:
    parts.append(f'local {n} = (function()\n{strip(read(SRC, "server", "modules", n + ".luau"))}\nend)()\n')

registry = ', '.join(f'{n} = {n}' for n in SHARED + SERVER)
parts.append(f'''
-- A stand-in module tree, so init.server.luau can run completely unmodified:
-- its own WaitForChild / FindFirstChild / require calls all resolve here.
local REGISTRY = {{ {registry} }}

local function container(names)
	local box = {{}}
	local children = {{}}
	for _, n in names do children[n] = {{ __module = n }} end
	box.FindFirstChild = function(_, n) return children[n] end
	box.WaitForChild = function(_, n) return children[n] end
	return setmetatable(box, {{ __index = function(_, k) return rawget(box, k) end }})
end

local sharedBox = container({{ {', '.join(f'"{n}"' for n in SHARED)} }})
local modulesBox = container({{ {', '.join(f'"{n}"' for n in SERVER)} }})

script = {{ WaitForChild = function(_, n) if n == "modules" then return modulesBox end end }}

require = function(token)
	if type(token) == "table" and token.__module then
		local m = REGISTRY[token.__module]
		if m == nil then error("no such module: " .. token.__module, 0) end
		return m
	end
	error("unexpected require", 0)
end

local rsMeta = rawget(ReplicatedStorage, "_props")
rsMeta.WaitForChild = function(_, n) if n == "Shared" then return sharedBox end end
rsMeta.FindFirstChild = function(_, n) if n == "Shared" then return sharedBox end end

-- ------------------------------------------- the real bootstrap, verbatim
local bootOk, bootErr = pcall(function()
{read(SRC, 'server', 'init.server.luau')}
end)

DUMP("boot completed:", bootOk, bootOk and "" or tostring(bootErr))
local arena = workspace:FindFirstChild("Arena")
local fallback = workspace:FindFirstChild("FallbackGround")
DUMP("ARENA:", arena ~= nil, arena and (#arena:GetDescendants() .. " parts") or "-")
DUMP("FALLBACK GROUND:", fallback ~= nil)
for _, w in WARNINGS do DUMP("  warn:", w) end
for _, p in PRINTS do DUMP("  print:", p) end
''')

sys.stdout.write('\n'.join(parts))
