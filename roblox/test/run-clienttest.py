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

RADAR_TEST = '\n-- ================================================== motion tracker\n-- The radar changes how the map is played, so its geometry has to be right:\n-- a contact behind you must read as behind you, not in front.\n\nlocal radarPlayers = { localPlayer }\nrawget(Players, "_props").GetPlayers = function() return radarPlayers end\n\nlocal function contact(name, position, team, health)\n\tlocal character = Instance.new("Model")\n\tlocal root = Instance.new("Part")\n\troot._props.Name = "HumanoidRootPart"\n\troot._props.CFrame = CFrame.new(position.X, position.Y, position.Z)\n\troot.Parent = character\n\tlocal humanoid = Instance.new("Humanoid")\n\thumanoid._props.Health = health or 100\n\thumanoid.Parent = character\n\n\tlocal p = Instance.new("Player")\n\tp._props.Name = name\n\tp._props.Character = character\n\tp._props.Team = team\n\ttable.insert(radarPlayers, p)\n\treturn p\nend\n\n-- Me at the origin, looking down -Z, which is Roblox\'s forward.\nlocal myCharacter = Instance.new("Model")\nlocal myRoot = Instance.new("Part")\nmyRoot._props.Name = "HumanoidRootPart"\nmyRoot._props.CFrame = CFrame.new(0, 5, 0)\nmyRoot.Parent = myCharacter\nlocal myHumanoid = Instance.new("Humanoid")\nmyHumanoid.Parent = myCharacter\nlocalPlayer._props.Character = myCharacter\n\nlocal redTeam = Instance.new("Team")\nredTeam._props.Name = "Red"\nredTeam._props.TeamColor = BrickColor.new("Bright red")\nlocal blueTeam = Instance.new("Team")\nblueTeam._props.Name = "Blue"\nblueTeam._props.TeamColor = BrickColor.new("Bright blue")\nlocalPlayer._props.Team = redTeam\n\nrawget(workspace, "_props").CurrentCamera._props.CFrame = CFrame.new()\n\nlocal dial = Radar.Build(Instance.new("ScreenGui"))\ncheck("the dial is built", dial ~= nil, "")\n\n-- An enemy 60 studs straight ahead, an ally 60 studs behind, and someone\n-- two maps away who must not appear at all.\nlocal ahead = contact("Ahead", Vector3.new(0, 5, -60), blueTeam)\nlocal behind = contact("Behind", Vector3.new(0, 5, 60), redTeam)\nlocal faraway = contact("Faraway", Vector3.new(0, 5, -4000), blueTeam)\n\nRadar.RefreshForTests()\ncheck("contacts in range show, the far one does not", Radar.VisibleContacts() == 2,\n\tstring.format("%d dots", Radar.VisibleContacts()))\n\nlocal shown = Radar.ContactsForTests()\nlocal aheadDot, behindDot\nfor _, entry in shown do\n\tif entry.offsetY < 0 then aheadDot = entry else behindDot = entry end\nend\n\ncheck("a contact ahead plots above centre", aheadDot ~= nil,\n\taheadDot and string.format("y offset %.0f px", aheadDot.offsetY) or "missing")\ncheck("a contact behind plots below centre", behindDot ~= nil,\n\tbehindDot and string.format("y offset %.0f px", behindDot.offsetY) or "missing")\n\n-- Enemies red, team-mates not.\nif aheadDot and behindDot then\n\tcheck("the enemy ahead is red", aheadDot.color.R > 0.8 and aheadDot.color.G < 0.4,\n\t\tstring.format("%.2f %.2f %.2f", aheadDot.color.R, aheadDot.color.G, aheadDot.color.B))\n\t-- A team-mate has to be clearly NOT red even when your own team colour\n\t-- is red, which is why the ally colour is fixed rather than the team\'s.\n\tcheck("the team-mate behind is clearly not red", behindDot.color.G > 0.6,\n\t\tstring.format("%.2f %.2f %.2f", behindDot.color.R, behindDot.color.G, behindDot.color.B))\nend\n\n-- Turn around. The dots must swap sides, because the dial is oriented to\n-- where you are LOOKING, not to north.\nrawget(workspace, "_props").CurrentCamera._props.CFrame = CFrame.Angles(0, math.pi, 0)\nRadar.RefreshForTests()\nlocal turned = Radar.ContactsForTests()\nlocal nowAhead\nfor _, entry in turned do\n\tif entry.offsetY < 0 then nowAhead = entry end\nend\ncheck("turning around swaps the dots over",\n\tnowAhead ~= nil and nowAhead.color.G > 0.6,\n\tnowAhead and string.format("%.2f %.2f %.2f", nowAhead.color.R, nowAhead.color.G, nowAhead.color.B) or "missing")\n\n-- A dead player is not a contact.\nrawget(workspace, "_props").CurrentCamera._props.CFrame = CFrame.new()\nrawget(ahead, "_props").Character:FindFirstChildOfClass("Humanoid")._props.Health = 0\nRadar.RefreshForTests()\ncheck("a dead player is not tracked", Radar.VisibleContacts() == 1,\n\tstring.format("%d dots", Radar.VisibleContacts()))\n\n-- Someone on a fifth-floor roof must not read as standing on you.\nrawget(ahead, "_props").Character:FindFirstChildOfClass("Humanoid")._props.Health = 100\nrawget(ahead, "_props").Character:FindFirstChild("HumanoidRootPart")._props.CFrame =\n\tCFrame.new(0, 400, -60)\nRadar.RefreshForTests()\ncheck("a contact far overhead is off the dial", Radar.VisibleContacts() == 1,\n\tstring.format("%d dots", Radar.VisibleContacts()))\n\nlocal _ = faraway\n'

TOUCH_TEST = '\n-- ================================================== touch controls\n-- A phone player had no way to change weapon, throw a grenade, bail out of\n-- a vehicle or read the scoreboard: there is no number row, no G, no space\n-- bar and no Tab on glass. That is not a missing convenience, it is a\n-- different game. These check the buttons exist and that each one actually\n-- does something.\n\n-- A key must act once per press, not once on the way down and again on the\n-- way up. The grenade key was copied into the release handler by a\n-- search-and-replace with no count, so one press threw two grenades.\ndo\n\t-- A shot needs a Head to come out of, so give the stand-in character one.\n\t-- Without it shotOrigin returns nil, nothing is ever thrown, and the\n\t-- check below reads zero whether the bug is present or not.\n\tlocal head = Instance.new("Part")\n\thead._props.Name = "Head"\n\thead._props.CFrame = CFrame.new(0, 6, 0)\n\thead.Parent = localPlayer._props.Character\n\n\tlocal thrown = 0\n\tlocal realEvent = Remotes.Event\n\tRemotes.Event = function(name)\n\t\tif name == "ThrowGrenade" then\n\t\t\treturn { FireServer = function() thrown += 1 end, OnClientEvent = SIGNAL() }\n\t\tend\n\t\treturn realEvent(name)\n\tend\n\n\tlocal g = { KeyCode = Enum.KeyCode.G, UserInputType = Enum.UserInputType.Keyboard }\n\trawget(UserInputService, "_props").InputBegan._fire(g, false)\n\trawget(UserInputService, "_props").InputEnded._fire(g)\n\tRemotes.Event = realEvent\n\n\tcheck("one grenade press throws exactly one grenade", thrown == 1,\n\t\tstring.format("%d thrown", thrown))\nend\n\n-- Dragging a thumb across a phone screen is how you look around. It used to\n-- fire the gun, because raw Touch input was handled alongside the mouse.\ndo\n\tlocal fired = 0\n\tlocal realEvent = Remotes.Event\n\tRemotes.Event = function(name)\n\t\tif name == "FireWeapon" then\n\t\t\treturn { FireServer = function() fired += 1 end, OnClientEvent = SIGNAL() }\n\t\tend\n\t\treturn realEvent(name)\n\tend\n\n\tlocal touch = { UserInputType = Enum.UserInputType.Touch, KeyCode = Enum.KeyCode.Unknown }\n\tfor _ = 1, 5 do\n\t\trawget(UserInputService, "_props").InputBegan._fire(touch, false)\n\tend\n\tRemotes.Event = realEvent\n\n\tcheck("dragging to look does not fire the gun", fired == 0,\n\t\tstring.format("%d shots from 5 drags", fired))\nend\n\n-- The scoreboard flag is shared between Tab and the touch button, so a Tab\n-- press must not leave the button needing two taps.\ndo\n\tlocal tab = { KeyCode = Enum.KeyCode.Tab, UserInputType = Enum.UserInputType.Keyboard }\n\trawget(UserInputService, "_props").InputBegan._fire(tab, false)\n\trawget(UserInputService, "_props").InputEnded._fire(tab)\n\tcheck("Tab leaves the scoreboard closed", not Controls.ScoreboardOpenForTests(), "")\nend\n\n-- Restart the controls as a touch device this time.\n--\n-- Start() is idempotent now, which is the right fix for the retry loop\n-- double-connecting every handler -- so the latch has to be cleared or this\n-- second call does nothing and the touch layer is never built. A phone also\n-- has no mouse, and the auto-aim and touch gates both check for that.\nrawget(UserInputService, "_props").TouchEnabled = true\nrawget(UserInputService, "_props").MouseEnabled = false\nControls.ResetForTests()\nlocal touchOk, touchErr = pcall(Controls.Start)\ncheck("controls start on a touch device", touchOk, touchOk and "" or tostring(touchErr))\n\nlocal touchGui\nfor _, child in playerGui:GetChildren() do\n\tif child._props.Name == "TouchControls" then touchGui = child end\nend\ncheck("the touch layer is built", touchGui ~= nil, "")\n\nif touchGui then\n\tlocal labels = {}\n\tlocal buttons = {}\n\tfor _, child in touchGui:GetChildren() do\n\t\tif child._props.Text then\n\t\t\tlabels[child._props.Text] = true\n\t\t\tbuttons[child._props.Text] = child\n\t\tend\n\tend\n\n\tlocal wanted = { "FIRE", "MEGA", "NADE", "GUN ▶", "GAS", "BRAKE", "TURBO", "BAIL", "SCORE" }\n\tlocal missing = {}\n\tfor _, name in wanted do\n\t\tif not labels[name] then table.insert(missing, name) end\n\tend\n\tcheck("every action has a button", #missing == 0, table.concat(missing, ", "))\n\n\t-- The weapon button has to actually change the weapon, and has to keep\n\t-- changing it rather than sticking on one.\n\tlocal gunButton = buttons["GUN ▶"]\n\tif gunButton then\n\t\tlocal seen = {}\n\t\tlocal distinct = 0\n\t\tfor _ = 1, 12 do\n\t\t\tgunButton._props.Activated._fire()\n\t\t\tlocal now = Controls.EquippedName()\n\t\t\tif not seen[now] then\n\t\t\t\tseen[now] = true\n\t\t\t\tdistinct += 1\n\t\t\tend\n\t\tend\n\t\tcheck("the weapon button cycles through weapons", distinct >= 4,\n\t\t\tstring.format("%d different weapons in 12 taps", distinct))\n\n\t\t-- And never lands on a gun you cannot hold on foot.\n\t\tlocal mounted = false\n\t\tfor name in seen do\n\t\t\tif Config.Weapons[name] and Config.Weapons[name].MountedOnly then\n\t\t\t\tmounted = true\n\t\t\tend\n\t\tend\n\t\tcheck("it never equips a vehicle-mounted gun", not mounted, "")\n\tend\n\n\t-- Every other button must be wired to something.\n\tlocal unwired = {}\n\tfor _, name in { "FIRE", "MEGA", "NADE", "GAS", "BRAKE", "TURBO", "BAIL", "SCORE" } do\n\t\tlocal button = buttons[name]\n\t\tlocal down = button and rawget(button, "_props").MouseButton1Down\n\t\tlocal tap = button and rawget(button, "_props").Activated\n\t\tlocal wired = (down and #down._handlers > 0) or (tap and #tap._handlers > 0)\n\t\tif not wired then table.insert(unwired, name) end\n\tend\n\tcheck("no button is a decoration", #unwired == 0, table.concat(unwired, ", "))\n\n\t-- The motion tracker owns the bottom-left corner. A thumb button sitting\n\t-- on top of the radar costs you the radar, and TURBO and BAIL both did.\n\tlocal DIAL_RIGHT_EDGE = 24 + 164\n\tlocal DIAL_TOP = -(164 + 120)\n\tlocal overlapping = {}\n\tfor name, button in buttons do\n\t\tlocal pos, size = button._props.Position, button._props.Size\n\t\tlocal left, top = pos.X.Offset, pos.Y.Offset\n\t\t-- Only the buttons anchored to the bottom-left can collide with it.\n\t\tif pos.X.Scale == 0 and pos.Y.Scale == 1 then\n\t\t\tlocal right = left + size.X.Offset\n\t\t\tlocal bottom = top + size.Y.Offset\n\t\t\tif right > 24 and left < DIAL_RIGHT_EDGE and bottom > DIAL_TOP then\n\t\t\t\ttable.insert(overlapping, name)\n\t\t\tend\n\t\tend\n\tend\n\tcheck("no touch button covers the motion tracker", #overlapping == 0,\n\t\ttable.concat(overlapping, ", "))\n\n\tcheck("the touch layer draws above the HUD", (touchGui._props.DisplayOrder or 0) > 0,\n\t\ttostring(touchGui._props.DisplayOrder))\nend\n\nrawget(UserInputService, "_props").TouchEnabled = false\n'

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
-- Losing window focus has to drop whatever is held down, so Controls
-- connects to this. Missing, Controls.Start threw partway through and no
-- input after that line was ever wired -- the exact failure this suite
-- exists to catch.
rawget(UserInputService, "_props").WindowFocusReleased = countingSignal()
rawget(UserInputService, "_props").MouseEnabled = true

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

local Radar = (function()
local Workspace = workspace
local Config = Config
{strip(read(SRC, 'client', 'modules', 'Radar.luau'))}
end)()

local Shot = (function()
{strip(read(SRC, 'shared', 'Shot.luau'))}
end)()

local Sound = (function()
local Config = Config
local SoundService = game:GetService("SoundService")
{strip(read(SRC, 'shared', 'Sound.luau'))}
end)()

local Hud = (function()
local Radar = Radar
{strip(read(SRC, 'client', 'modules', 'Hud.luau'))}
end)()

local Controls = (function()
local Hud = Hud
local Feel = Feel
local Sound = Sound
local Shot = Shot
{strip(read(SRC, 'client', 'modules', 'Controls.luau'))}
end)()

Feel.Start()

local hudOk, hudErr = pcall(Hud.Build)
DUMP("HUD built:", hudOk, hudOk and "" or tostring(hudErr))

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

--[[RADARTEST]]

--[[TOUCHTEST]]

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

--[[
	Exit non-zero on failure.

	Without this the suite only PRINTED its failures and exited 0, so
	run-all.sh reported success no matter what broke, and any automation
	trusting its exit code was being told a comforting lie. error() at the
	top level is what makes the luau CLI exit non-zero.
]]
if failures > 0 then
	error("client: " .. failures .. " failures", 0)
end
"""

sys.stdout.write(
    harness
    .replace('--[[FEELTEST]]', FEEL_TEST)
    .replace('--[[RADARTEST]]', RADAR_TEST)
    .replace('--[[TOUCHTEST]]', TOUCH_TEST)
)
