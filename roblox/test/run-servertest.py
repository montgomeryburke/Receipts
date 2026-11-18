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

# Kept out of the harness f-string on purpose: Luau is full of braces, and
# an f-string reads every one of them as an expression.
MEDAL_TEST = '''
-- ------------------------------------------------------- medals and feed
-- Throw away whatever boot spawned before testing anything. The match loop
-- is in there and it never returns, so flushing it would hang.
SPAWNED = {}

local failures = 0
local function check(label, condition, detail)
	if condition then
		DUMP(string.format("  PASS  %-40s %s", label, detail or ""))
	else
		DUMP(string.format("  FAIL  %-40s %s", label, detail or ""))
		failures += 1
	end
end

local function makeFighter(name, userId)
	local character = Instance.new("Model")
	character._props.Name = name
	local root = Instance.new("Part")
	root._props.Name = "HumanoidRootPart"
	root._props.CFrame = CFrame.new(0, 5, 0)
	root.Parent = character
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character
	character.Parent = workspace

	local player = Instance.new("Player")
	player._props.Name = name
	player._props.DisplayName = name
	player._props.UserId = userId
	player._props.Character = character
	player._props.CharacterAdded = SIGNAL()
	player._props.LoadCharacterAsync = function() end
	return player
end

local killer = makeFighter("Killer", 10)
local prey = makeFighter("Prey", 11)
rawget(Players, "_props").GetPlayers = function() return { killer, prey } end
PLAYERS_FOR_TEAMS = { killer, prey }
TeamService.Assign(killer)
TeamService.Assign(prey)
if killer._props.Team == prey._props.Team then
	prey._props.Team = TeamService.Get(if TeamService.IndexOf(killer) == 1 then 2 else 1)
end

MatchService.ForceRoundForTests()

local function medalsSent()
	local names = {}
	for _, call in FIRED_TO("Medal") do
		table.insert(names, tostring(call.args[1]))
	end
	return names
end

FIRED = {}
DamageService.Killed.Fire(prey, killer, "Sniper Rifle")
RUN_SPAWNED()
check("a kill reaches the kill feed", #FIRED_TO("KillFeed") > 0,
	string.format("%d lines", #FIRED_TO("KillFeed")))
check("the killer hears a confirm", #FIRED_TO("PlaySound") > 0, "")
check("one kill earns no medal", #medalsSent() == 0, table.concat(medalsSent(), ", "))

DamageService.Killed.Fire(prey, killer, "Sniper Rifle")
RUN_SPAWNED()
check("two quick kills is a DOUBLE KILL",
	string.find(table.concat(medalsSent(), ","), "DOUBLE KILL") ~= nil,
	table.concat(medalsSent(), ", "))

FIRED = {}
DamageService.Killed.Fire(prey, killer, "Sniper Rifle")
RUN_SPAWNED()
check("three is a TRIPLE KILL",
	string.find(table.concat(medalsSent(), ","), "TRIPLE KILL") ~= nil,
	table.concat(medalsSent(), ", "))

FIRED = {}
DamageService.Killed.Fire(prey, killer, "Sniper Rifle")
DamageService.Killed.Fire(prey, killer, "Sniper Rifle")
RUN_SPAWNED()
check("five without dying is a SPREE",
	string.find(table.concat(medalsSent(), ","), "KILLING SPREE") ~= nil,
	table.concat(medalsSent(), ", "))

FIRED = {}
DamageService.Killed.Fire(killer, prey, "Pistol")
RUN_SPAWNED()
FIRED = {}
DamageService.Killed.Fire(prey, killer, "Sniper Rifle")
RUN_SPAWNED()
check("dying resets the multikill window", #medalsSent() == 0,
	table.concat(medalsSent(), ", "))

-- ------------------------------------------------------------ scoreboard
-- A game scored by points is unplayable without one, and it has to survive
-- the awkward cases: a player with no team, and a request arriving before
-- anybody has scored anything.
PlayerState.AwardPoints(killer, 250)
PlayerState.AwardPoints(prey, 90)

FIRED = {}
ScoreboardService.Send(killer)
local sent = FIRED_TO("Scoreboard")
check("a request gets a scoreboard back", #sent == 1, string.format("%d payloads", #sent))

if #sent == 1 then
	local payload = sent[1].args[1]
	local rows = payload and payload.rows
	check("it lists every player", rows and #rows == 2, string.format("%d rows", rows and #rows or 0))
	check("the heading totals the teams",
		payload and type(payload.heading) == "string" and #payload.heading > 0,
		tostring(payload and payload.heading))

	if rows and #rows == 2 then
		-- Sorted by team, then by points within the team. Both players are
		-- on different teams here, so check the fields arrived at all.
		local found = 0
		local marked = 0
		for _, row in rows do
			if row.points and row.points > 0 then found += 1 end
			if row.isYou then marked += 1 end
		end
		check("points reach the panel", found == 2, string.format("%d rows scored", found))
		check("your own row is marked", marked == 1, string.format("%d marked", marked))
	end
end

-- The end of a round pushes it to everybody unasked.
FIRED = {}
ScoreboardService.PushAll()
check("the round end pushes to everyone", #FIRED_TO("Scoreboard") == 2,
	string.format("%d pushes", #FIRED_TO("Scoreboard")))

DUMP(if failures == 0 then "MEDALS WORK" else failures .. " MEDAL FAILURES")
'''

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

SHARED = ['Config', 'Signal', 'Util', 'Remotes', 'Sound']
SERVER = ['PlayerState', 'MapService', 'VehicleService', 'DamageService', 'WildlifeService',
          'CarnivalService', 'ProjectileService', 'WeaponService', 'TeamService', 'PickupService',
          'EffectService', 'FlagService', 'MonetizationService', 'ScoreboardService', 'MatchService',
          'GraphicsService']

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
--[[MEDALS]]
local arena = workspace:FindFirstChild("Arena")
local fallback = workspace:FindFirstChild("FallbackGround")
DUMP("ARENA:", arena ~= nil, arena and (#arena:GetDescendants() .. " parts") or "-")
DUMP("FALLBACK GROUND:", fallback ~= nil)
for _, w in WARNINGS do DUMP("  warn:", w) end
for _, p in PRINTS do DUMP("  print:", p) end
''')

sys.stdout.write('\n'.join(parts).replace('--[[MEDALS]]', MEDAL_TEST))
