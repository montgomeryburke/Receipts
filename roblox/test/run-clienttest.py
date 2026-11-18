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

FEEL_TEST = '\n-- ================================================== camera feel\n-- Shooting only feels like shooting because the camera moves. These check\n-- that it moves, that it always comes back, and that it can never be driven\n-- somewhere a player cannot recover from.\n\nlocal function cameraPitch()\n\t-- How far off level the camera is looking, in degrees.\n\tlocal look = rawget(workspace, "_props").CurrentCamera._props.CFrame.LookVector\n\treturn math.deg(math.asin(math.clamp(look.Y, -1, 1)))\nend\n\nlocal function level()\n\trawget(workspace, "_props").CurrentCamera._props.CFrame = CFrame.new()\nend\n\n--[[\n\tDrive frames by hand.\n\n\tRoblox\'s own camera script recomputes CurrentCamera.CFrame from scratch\n\tevery frame, BEFORE our step runs -- that is what the render priority is\n\tfor. So the module applies an absolute offset each frame rather than an\n\tincrement, and the test has to level the camera each frame too or it\n\twould be measuring an accumulation the engine never performs.\n\n\tThe step count is rounded rather than floored: 0.3 / (1/30) comes out as\n\t8.999999 in binary, so flooring it silently runs one frame short and the\n\tframerate-independence check fails on a rounding error.\n]]\nlocal function step(seconds, slice)\n\tslice = slice or 1 / 60\n\tfor _ = 1, math.floor(seconds / slice + 0.5) do\n\t\tlevel()\n\t\tRENDER_STEP(slice)\n\tend\nend\n\ncheck("the camera step is bound", RENDER_STEP ~= nil, "")\n\nif RENDER_STEP then\n\tlevel()\n\tFeel.Kick(3.2) -- a sniper shot\n\tRENDER_STEP(1 / 60)\n\tlocal kicked = cameraPitch()\n\tcheck("a shot kicks the view up", kicked > 1.5, string.format("%.2f degrees", kicked))\n\n\t-- It has to come back, or every burst would walk the view at the sky.\n\tstep(0.6)\n\tlocal settled = math.abs(cameraPitch())\n\tcheck("the kick settles back", settled < 0.1, string.format("%.3f degrees left", settled))\n\n\t-- A minigun held down is 22 shots a second. The view must not spin.\n\tfor _ = 1, 60 do\n\t\tlevel()\n\t\tFeel.Kick(0.35)\n\t\tRENDER_STEP(1 / 60)\n\tend\n\tlocal held = Feel.Debug().kick\n\tcheck("held fire cannot spin the camera", held <= 7.0001, string.format("%.2f degrees of kick", held))\n\tcheck("and the view never leaves the cap", math.abs(cameraPitch()) <= 7.5,\n\t\tstring.format("%.2f degrees off level", cameraPitch()))\n\n\t-- Framerate independence: the same kick must take the same TIME to fade\n\t-- at 30fps as at 240, or the game would feel different on every machine.\n\tlocal function decayFrom(slice)\n\t\tFeel.Stop()\n\t\tFeel.Start()\n\t\tFeel.Kick(4)\n\t\tstep(0.3, slice)\n\t\treturn Feel.Debug().kick\n\tend\n\tlocal slow = decayFrom(1 / 30)\n\tlocal fast = decayFrom(1 / 240)\n\tcheck("decay does not depend on framerate",\n\t\tmath.abs(slow - fast) < 0.05, string.format("%.3f at 30fps vs %.3f at 240fps", slow, fast))\n\n\t-- Explosions: violent up close, nothing at all across the map.\n\tFeel.Stop()\n\tFeel.Start()\n\tFeel.ShakeFrom(Vector3.new(0, 0, 10), 3, 100)\n\tlocal near = Feel.Debug().shake\n\tcheck("a blast at your feet shakes hard", near > 1.5, string.format("%.2f", near))\n\n\tFeel.Stop()\n\tFeel.Start()\n\tFeel.ShakeFrom(Vector3.new(0, 0, 4000), 3, 100)\n\tcheck("a blast across the map does nothing", Feel.Debug().shake == 0,\n\t\tstring.format("%.4f", Feel.Debug().shake))\nend\n'

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

-- Capture the render-step callback so the test can drive frames by hand.
RENDER_STEP = nil
rawget(RunService, "_props").BindToRenderStep = function(_, _name, _priority, fn)
	RENDER_STEP = fn
end
rawget(RunService, "_props").UnbindFromRenderStep = function() RENDER_STEP = nil end

local Feel = (function()
local Workspace = workspace
{strip(read(SRC, 'client', 'modules', 'Feel.luau'))}
end)()

local Controls = (function()
local Hud = Hud
local Feel = Feel
{strip(read(SRC, 'client', 'modules', 'Controls.luau'))}
end)()

Feel.Start()

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
local function check(label, condition, detail)
	if condition then
		DUMP(string.format("  PASS  %-42s %s", label, detail or ""))
	else
		DUMP(string.format("  FAIL  %-42s %s", label, detail or ""))
		failures += 1
	end
end

--[[FEELTEST]]

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

sys.stdout.write(harness.replace('--[[FEELTEST]]', FEEL_TEST))
