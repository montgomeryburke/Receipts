#!/usr/bin/env python3
"""
Run the client bootstrap outside Roblox.

The client once died silently: Controls.Start() asked the server for the
weapon list, that call threw because the server had not finished booting, and
every input handler after the throw was never connected. No firing, no E, no
turbo, and nothing on screen saying why.

This runs the real client code with a DELIBERATELY HOSTILE server — every
RemoteFunction call throws — and checks that input is still connected anyway.

    python3 test/run-clienttest.py > /tmp/c.luau && luau /tmp/c.luau
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
        if re.match(r'^local modules = script', line): continue
        kept.append(line)
    return '\n'.join(kept)


harness = f"""
{read(HERE, 'stubs.luau')}
{read(HERE, 'serverstubs.luau')}

-- Count how much input actually got wired up.
INPUT_CONNECTIONS = 0
local function countingSignal()
	local s = SIGNAL()
	local realConnect = s.Connect
	s.Connect = function(self, fn)
		INPUT_CONNECTIONS += 1
		return realConnect(self, fn)
	end
	return s
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UserInputService = game:GetService("UserInputService")
rawget(UserInputService, "_props").InputBegan = countingSignal()
rawget(UserInputService, "_props").InputEnded = countingSignal()
rawget(UserInputService, "_props").TouchEnabled = false

local localPlayer = Instance.new("Player")
local playerGui = Instance.new("PlayerGui")
playerGui.Parent = localPlayer
localPlayer._props.CharacterAdded = SIGNAL()
localPlayer._props.WaitForChild = function(_, n) if n == "PlayerGui" then return playerGui end end
rawget(Players, "_props").LocalPlayer = localPlayer

rawget(workspace, "_props").CurrentCamera = (function()
	local cam = Instance.new("Camera")
	cam._props.FieldOfView = 70
	cam._props.CFrame = CFrame.new()
	return cam
end)()

-- HOSTILE SERVER: every RemoteFunction call blows up, the way it did when
-- the server had not finished starting.
HOSTILE = true

local Config = (function()
{strip(read(SRC, 'shared', 'Config.luau'))}
end)()
local Util = (function()
{strip(read(SRC, 'shared', 'Util.luau'))}
end)()

-- A stand-in Remotes that refuses every request.
local Remotes = {{
	Event = function(_name)
		return {{ FireServer = function() end, OnClientEvent = SIGNAL() }}
	end,
	Function = function(_name)
		return {{ InvokeServer = function()
			if HOSTILE then error("server is not ready", 0) end
			return {{}}
		end }}
	end,
}}

local Hud = (function()
{strip(read(SRC, 'client', 'modules', 'Hud.luau'))}
end)()

local Controls = (function()
local Hud = Hud
{strip(read(SRC, 'client', 'modules', 'Controls.luau'))}
end)()

local hudOk = pcall(Hud.Build)
DUMP("HUD built:", hudOk)

local function startControls(): string
	Controls.Start()
	return "ok"
end

local ok, err = pcall(startControls)
DUMP("Controls started:", ok, ok and "" or tostring(err))
DUMP("INPUT HANDLERS CONNECTED:", INPUT_CONNECTIONS)

local guns = 0
for _ in Config.Weapons do guns += 1 end
DUMP("weapons in config:", guns)
DUMP("equipped after start:", Controls.EquippedName())

local failures = 0
if not ok then failures += 1 end
if INPUT_CONNECTIONS < 2 then
	DUMP("  ^ INPUT NOT WIRED — firing and E would do nothing")
	failures += 1
end
if Controls.EquippedName() == "" then
	DUMP("  ^ NO WEAPON EQUIPPED")
	failures += 1
end

DUMP("")
DUMP(if failures == 0 then "CLIENT OK EVEN WITH A DEAD SERVER" else failures .. " FAILURES")
"""

sys.stdout.write(harness)
