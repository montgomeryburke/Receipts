#!/usr/bin/env python3
"""
Prove a vehicle actually moves.

Roblox Studio cannot be driven from a terminal, so this does the next best
thing: it runs the REAL driving code, then applies Roblox's documented
constraint behaviour by hand and integrates the result over time.

What it genuinely proves:
  - a seated driver's throttle reaches the drive constraint
  - the constraint is enabled, and is given a non-zero target speed
  - force limits are not left in a state that produces zero force
  - steering changes the heading, turbo increases speed, an empty car
    stays put

What it cannot prove: that Roblox's own physics engine behaves the way its
documentation says. That last mile still needs a human pressing W.

    python3 test/run-drivetest.py > /tmp/d.luau && luau /tmp/d.luau
"""
import os
import re
import sys

SPACING_TEST = '-- The pacing has to be by DISTANCE, not by time. A boost chevron is nine\n-- studs long. A fixed 20 Hz sample is ten studs apart at full speed, so the\n-- pads on the run-up to a ramp get stepped straight over and the jump beyond\n-- never works -- which is a silent failure, because the car still drives.\nDUMP("")\nDUMP("Probe spacing at speed:")\ndo\n\tlocal samples = {}\n\tlocal saved = rawget(workspace, "_props").Raycast\n\trawget(workspace, "_props").Raycast = function(_, origin)\n\t\ttable.insert(samples, origin)\n\t\treturn nil\n\tend\n\n\trunCar(1, 0, true, 4) -- full throttle, turbo, long enough to top out\n\trawget(workspace, "_props").Raycast = saved\n\n\tlocal widest = 0\n\tfor index = 2, #samples do\n\t\tlocal gap = (samples[index] - samples[index - 1]).Magnitude\n\t\twidest = math.max(widest, gap)\n\tend\n\n\t-- A boost chevron is nine studs long along the direction of travel, so\n\t-- the widest gap has to stay comfortably under that.\n\tcheck("samples are never more than a boost pad apart", widest <= 7,\n\t\tstring.format("widest gap %.1f studs over %d samples", widest, #samples))\n\tcheck("and it still is not sampling every frame", #samples < 240,\n\t\tstring.format("%d samples in 240 frames", #samples))\nend\n\n'

GEAR_TEST = '-- ==================================================== tubes and gliders\n-- The resort is only worth having if the kit actually moves. A tube has no\n-- engine at all: the river\'s current or a snow slope pushes it, and nothing\n-- else does. So these drive it against a stand-in river and a stand-in\n-- mountain and check it goes the right way in each.\n\nlocal function rideTube(surface, seconds)\n\tlocal tube = VehicleService.SpawnTube(Vector3.new(0, 5, 0))\n\tlocal hub = tube:FindFirstChild("Chassis")\n\thub._props.CFrame = CFrame.new(0, 5, 0)\n\thub._props.AssemblyLinearVelocity = Vector3.new()\n\n\tlocal seat = tube:FindFirstChild("DriverSeat")\n\tseat._props.Occupant = Instance.new("Humanoid")\n\tseat._props.Throttle = 0\n\tseat._props.Steer = 0\n\n\tlocal saved = rawget(workspace, "_props").Raycast\n\trawget(workspace, "_props").Raycast = surface\n\n    local dt = 1 / 60\n\tfor _ = 1, math.floor(seconds * 60) do\n\t\tADVANCE(dt)\n\t\tRunService.Heartbeat._fire(dt)\n\t\t-- Integrate whatever velocity the tube driver set.\n\t\tlocal velocity = hub._props.AssemblyLinearVelocity or Vector3.new()\n\t\thub._props.CFrame = CFrame.new(hub._props.CFrame.Position + velocity * dt)\n\t\t\t* hub._props.CFrame.Rotation\n\tend\n\n\trawget(workspace, "_props").Raycast = saved\n\tlocal finish = hub._props.CFrame.Position\n\ttube:Destroy()\n\treturn finish\nend\n\nDUMP("")\nDUMP("The lazy river:")\ndo\n\t-- A flow zone pushing along +X.\n\tlocal flowPart = Instance.new("Part")\n\tflowPart._props.Name = "FlowZone"\n\tflowPart:SetAttribute("FlowX", 1)\n\tflowPart:SetAttribute("FlowY", 0)\n\tflowPart:SetAttribute("FlowZ", 0)\n\n\tlocal finish = rideTube(function()\n\t\treturn {\n\t\t\tInstance = flowPart,\n\t\t\tPosition = Vector3.new(0, 4, 0),\n\t\t\tMaterial = Enum.Material.Water,\n\t\t\tNormal = Vector3.new(0, 1, 0),\n\t\t}\n\tend, 3)\n\n\tcheck("the current carries a tube downstream", finish.X > 60,\n\t\tstring.format("%.0f studs along the flow", finish.X))\n\tcheck("and does not carry it sideways", math.abs(finish.Z) < 10,\n\t\tstring.format("%.1f studs off course", finish.Z))\nend\n\nDUMP("")\nDUMP("The ski run:")\ndo\n\t-- A snow slope tilted so its normal leans toward -Z: downhill is -Z.\n\tlocal snow = Instance.new("Part")\n\tsnow._props.Name = "Piste"\n\n\tlocal finish = rideTube(function()\n\t\treturn {\n\t\t\tInstance = snow,\n\t\t\tPosition = Vector3.new(0, 4, 0),\n\t\t\tMaterial = Enum.Material.Snow,\n\t\t\tNormal = Vector3.new(0, 0.82, -0.57),\n\t\t}\n\tend, 3)\n\n\tcheck("a tube slides down a snow slope", finish.Z < -60,\n\t\tstring.format("%.0f studs downhill", finish.Z))\nend\n\nDUMP("")\nDUMP("Flat snow:")\ndo\n\tlocal flatSnow = Instance.new("Part")\n\tflatSnow._props.Name = "Summit"\n\n\tlocal finish = rideTube(function()\n\t\treturn {\n\t\t\tInstance = flatSnow,\n\t\t\tPosition = Vector3.new(0, 4, 0),\n\t\t\tMaterial = Enum.Material.Snow,\n\t\t\tNormal = Vector3.new(0, 1, 0),\n\t\t}\n\tend, 3)\n\n\t-- A flat surface has a vertical normal and therefore no downhill at all,\n\t-- which has to mean "sit still" rather than "drift in some direction".\n\tcheck("a tube sits still on the flat", finish.Magnitude < 12,\n\t\tstring.format("drifted %.1f studs", finish.Magnitude))\nend\n\nDUMP("")\nDUMP("The hang glider:")\ndo\n\tlocal glider = VehicleService.SpawnGlider(Vector3.new(0, 300, 0))\n\tlocal frame = glider:FindFirstChild("Chassis")\n\tlocal seat = glider:FindFirstChild("DriverSeat")\n\tcheck("the glider has a seat", seat ~= nil, "")\n\n\tseat._props.Occupant = Instance.new("Humanoid")\n\tseat._props.Throttle = 0\n\tseat._props.Steer = 0\n\n\tlocal lift = nil\n\tfor _, child in frame:GetChildren() do\n\t\tif child._props.Name == "DriveVelocity" then lift = child end\n\tend\n\tcheck("the glider has a wing to push it", lift ~= nil, "")\n\n\tfor _ = 1, 120 do\n\t\tADVANCE(1 / 60)\n\t\tRunService.Heartbeat._fire(1 / 60)\n\tend\n\n\tlocal velocity = lift and lift._props.VectorVelocity or Vector3.new()\n\tcheck("a glider flies forwards", velocity.Magnitude > 30,\n\t\tstring.format("%.0f studs/sec", velocity.Magnitude))\n\t-- It is a glider, not a helicopter: it must always be coming down.\n\tcheck("and always sinks", velocity.Y < 0, string.format("%.1f studs/sec vertical", velocity.Y))\n\n\t-- Nose down should be faster than level.\n\tlocal levelSpeed = velocity.Magnitude\n\tseat._props.Throttle = 1\n\tfor _ = 1, 120 do\n\t\tADVANCE(1 / 60)\n\t\tRunService.Heartbeat._fire(1 / 60)\n\tend\n\tlocal diveSpeed = (lift and lift._props.VectorVelocity or Vector3.new()).Magnitude\n\tcheck("diving trades height for speed", diveSpeed > levelSpeed,\n\t\tstring.format("%.0f diving vs %.0f level", diveSpeed, levelSpeed))\n\n\tglider:Destroy()\nend\n\nDUMP("")\nDUMP("Skis and tricks:")\ndo\n\tlocal skis = VehicleService.SpawnSkis(Vector3.new(0, 5, 0))\n\tlocal board = skis:FindFirstChild("Chassis")\n\tcheck("the skis have a board", board ~= nil, "")\n\n\t-- A rider, strapped on.\n\tlocal character = Instance.new("Model")\n\tlocal root = Instance.new("Part")\n\troot._props.Name = "HumanoidRootPart"\n\troot._props.CFrame = CFrame.new(0, 8, 0)\n\troot.Parent = character\n\tlocal humanoid = Instance.new("Humanoid")\n\thumanoid._props.Health = 100\n\thumanoid._props.MoveDirection = Vector3.new()\n\thumanoid.Parent = character\n\tcharacter.Parent = workspace\n\n\tlocal skier = Instance.new("Player")\n\tskier._props.Name = "Skier"\n\tskier._props.DisplayName = "Skier"\n\tskier._props.UserId = 77\n\tskier._props.Character = character\n\t-- Parented, because driveSkis drops a rider whose Parent is nil -- which\n\t-- is exactly right (that is a player who has left), and which silently\n\t-- made this whole block do nothing until the stand-in had a parent.\n\tskier.Parent = Players\n\trawget(Players, "_props").GetPlayerFromCharacter = function(_, c)\n\t\tif c == character then return skier end\n\t\treturn nil\n\tend\n\n\tVehicleService.MountSkis(skier, skis)\n\tcheck("a skier is strapped on", VehicleService.GetState(skis).rider == skier, "")\n\tcheck("and stands up rather than sitting", humanoid._props.PlatformStand == true, "")\n\n\t-- Tricks are measured, never reported: the server watches airtime and\n\t-- spin itself, so there is nothing for a client to lie about.\n\tlocal landed = {}\n\tVehicleService.TrickLanded.Connect(function(who, name, points, airtime)\n\t\ttable.insert(landed, { who = who, name = name, points = points, airtime = airtime })\n\tend)\n\n\tlocal function fly(seconds, spinDegrees, grounded)\n\t\tlocal steps = math.floor(seconds * 60)\n\t\tlocal perStep = spinDegrees / math.max(1, steps)\n\t\trawget(workspace, "_props").Raycast = function()\n\t\t\tif not grounded then return nil end\n\t\t\treturn {\n\t\t\t\tInstance = board,\n\t\t\t\tPosition = Vector3.new(0, 4, 0),\n\t\t\t\tMaterial = Enum.Material.Snow,\n\t\t\t\tNormal = Vector3.new(0, 1, 0),\n\t\t\t}\n\t\tend\n\t\tfor _ = 1, steps do\n\t\t\tADVANCE(1 / 60)\n\t\t\tboard._props.CFrame = board._props.CFrame * CFrame.Angles(0, math.rad(perStep), 0)\n\t\t\tRunService.Heartbeat._fire(1 / 60)\n\t\tend\n\t\t-- Signal.Fire hands each listener to task.spawn, so the trick\n\t\t-- announcement sits in the queue until it is flushed. Without this\n\t\t-- the whole block read as "tricks never score".\n\t\tRUN_SPAWNED()\n\tend\n\n\t-- A small bump must NOT pay out, or every seam in the piste is a trick.\n\tlanded = {}\n\tfly(0.2, 10, false)\n\tfly(0.2, 0, true)\n\tcheck("a bump in the piste is not a trick", #landed == 0,\n\t\tstring.format("%d tricks", #landed))\n\n\t-- Real air, with a spin, must.\n\tlanded = {}\n\tfly(1.4, 540, false)\n\tfly(0.2, 0, true)\n\tcheck("real air off a jump scores", #landed == 1, string.format("%d tricks", #landed))\n\tif #landed == 1 then\n\t\tcheck("it is credited to the rider", landed[1].who == skier, tostring(landed[1].who))\n\t\tcheck("it is worth real points", landed[1].points > 50,\n\t\t\tstring.format("%d points for %s", landed[1].points, landed[1].name))\n\t\tcheck("a big spin gets a big name", landed[1].name ~= "BIG AIR", landed[1].name)\n\tend\n\n\t-- Straight air with no rotation still counts, but for less.\n\tlanded = {}\n\tfly(1.4, 0, false)\n\tfly(0.2, 0, true)\n\tcheck("straight air counts for less", #landed == 1 and landed[1].name == "BIG AIR",\n\t\tif #landed == 1 then landed[1].name else "nothing")\n\n\trawget(workspace, "_props").Raycast = function() return nil end\n\tVehicleService.DismountSkis(skier)\n\tcheck("you can get off the skis", VehicleService.GetState(skis).rider == nil, "")\n\tcheck("and walk again", humanoid._props.PlatformStand == false, "")\n\n\tskis:Destroy()\nend\n\nDUMP("")\nDUMP("Off-roaders on a slope:")\ndo\n\t-- A slope whose normal leans, i.e. ground tilted uphill.\n\tlocal slope = Instance.new("Part")\n\tslope._props.Name = "TrailSegment"\n\tlocal saved = rawget(workspace, "_props").Raycast\n\trawget(workspace, "_props").Raycast = function()\n\t\treturn {\n\t\t\tInstance = slope,\n\t\t\tPosition = Vector3.new(0, 0, 0),\n\t\t\tMaterial = Enum.Material.Ground,\n\t\t\tNormal = Vector3.new(0, 0.84, 0.54),\n\t\t}\n\tend\n\n\tlocal function driveAxisFor(bodyName)\n\t\tlocal car = VehicleService.SpawnCar(1, Vector3.new(0, 5, 0), nil, bodyName)\n\t\tlocal chassis = car:FindFirstChild("Chassis")\n\t\tchassis._props.CFrame = CFrame.new(0, 5, 0)\n\t\tlocal seat = car:FindFirstChild("DriverSeat")\n\t\tseat._props.Occupant = Instance.new("Humanoid")\n\t\tseat._props.Throttle = 1\n\t\tseat._props.Steer = 0\n\n\t\tfor _ = 1, 60 do\n\t\t\tADVANCE(1 / 60)\n\t\t\tRunService.Heartbeat._fire(1 / 60)\n\t\tend\n\n\t\tlocal drive\n\t\tfor _, child in chassis:GetChildren() do\n\t\t\tif child._props.Name == "DriveVelocity" then drive = child end\n\t\tend\n\t\tlocal axis = drive and drive._props.LineDirection or Vector3.new()\n\t\tcar:Destroy()\n\t\treturn axis\n\tend\n\n\tlocal hummer = driveAxisFor("Hummer")\n\tlocal lambo = driveAxisFor("Lamborghini")\n\trawget(workspace, "_props").Raycast = saved\n\n\t-- An off-roader is allowed to tilt its drive axis up the slope it is\n\t-- standing on. That is the whole mechanic that gets it up the mountain.\n\tcheck("an off-roader points up the slope", hummer.Y > 0.08,\n\t\tstring.format("drive axis Y = %.3f", hummer.Y))\n\n\t-- An ordinary car must not. A non-flattened drive axis is exactly what\n\t-- used to fire trucks into the sky.\n\tcheck("an ordinary car stays dead level", math.abs(lambo.Y) < 0.001,\n\t\tstring.format("drive axis Y = %.3f", lambo.Y))\nend\n'

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


harness = f"""
{read(HERE, 'stubs.luau')}
{read(HERE, 'serverstubs.luau')}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")

local Config = (function()
{strip(read(SRC, 'shared', 'Config.luau'))}
end)()
local Signal = (function()
{strip(read(SRC, 'shared', 'Signal.luau'))}
end)()
local Util = (function()
{strip(read(SRC, 'shared', 'Util.luau'))}
end)()
local Remotes = (function()
{strip(read(SRC, 'shared', 'Remotes.luau'))}
end)()
local Sound = (function()
local Config = Config
{strip(read(SRC, 'shared', 'Sound.luau'))}
end)()
local PlayerState = (function()
{strip(read(SRC, 'server', 'modules', 'PlayerState.luau'))}
end)()
local VehicleService = (function()
{strip(read(SRC, 'server', 'modules', 'VehicleService.luau'))}
end)()

-- ===================================================== the physics stand-in
--
-- Roblox's documented behaviour for the constraints this game uses:
--   LinearVelocity, Line mode, RelativeTo = Attachment0
--     drives the assembly's velocity along LineDirection (in the part's own
--     frame) up to LineVelocity, using force bounded by the limit settings.
--     With ForceLimitsEnabled = false there is no bound.
--   AngularVelocity, RelativeTo = World
--     drives the assembly's angular velocity to the requested vector.
--
-- Anything the drive code fails to set simply stays at its default, and a
-- default of zero shows up here as a car that does not move — which is the
-- exact failure this test exists to catch.

local function findConstraint(chassis, name)
	for _, child in chassis:GetChildren() do
		if child._props.Name == name then return child end
	end
	return nil
end

local function forceAvailable(constraint)
	local props = constraint._props
	-- Limits switched off means unlimited force.
	if props.ForceLimitsEnabled == false then return math.huge end
	local mode = props.ForceLimitMode
	if mode and mode.Name == "PerAxis" then
		local axes = props.MaxAxesForce
		return if axes then math.min(axes.X, axes.Y, axes.Z) else 0
	end
	-- Magnitude mode, which is also the default.
	return props.MaxForce or 0
end

local function simulate(model, dt)
	local chassis = model:FindFirstChild("Chassis")
	if not chassis then return end

	local drive = findConstraint(chassis, "DriveVelocity")
	local turn = findConstraint(chassis, "TurnVelocity")
	local cf = chassis._props.CFrame

	if turn and turn._props.Enabled and (turn._props.MaxTorque or 0) > 0 then
		local w = turn._props.AngularVelocity or Vector3.new()
		-- World-space spin, so it pre-multiplies the current rotation.
		cf = CFrame.Angles(0, w.Y * dt, 0) * cf
	end

	if drive and drive._props.Enabled and forceAvailable(drive) > 0 then
		local speed = drive._props.LineVelocity or 0
		local dir = drive._props.LineDirection or Vector3.new(0, 0, -1)
		-- RelativeTo decides whose frame that direction is in.
		local relative = drive._props.RelativeTo
		local worldDir = if relative and relative.Name == "World"
			then dir
			else cf:VectorToWorld(dir)
		cf = CFrame.new(cf.Position + worldDir * speed * dt) * cf.Rotation
	end

	chassis._props.CFrame = cf
end

-- ================================================================ the test
local failures = 0
local function check(label, condition, detail)
	if condition then
		DUMP(string.format("  PASS  %-34s %s", label, detail or ""))
	else
		DUMP(string.format("  FAIL  %-34s %s", label, detail or ""))
		failures += 1
	end
end

local function runCar(throttle, steer, turbo, seconds)
	local car = VehicleService.SpawnCar(1, Vector3.new(0, 5, 0), nil)
	local chassis = car:FindFirstChild("Chassis")
	chassis._props.CFrame = CFrame.new(0, 5, 0)

	local seat = car:FindFirstChild("DriverSeat")
	if throttle ~= nil then
		local humanoid = Instance.new("Humanoid")
		seat._props.Occupant = humanoid
		seat._props.Throttle = throttle
		seat._props.Steer = steer
	end
	car:SetAttribute("Turbo", turbo)

	-- Advance the virtual clock with the frames, not just the frame count.
	-- Without this os.clock() stood still for the whole run, so every piece
	-- of time-based logic in the drive code -- the throttled ground probe,
	-- anything on a cooldown -- was only ever tested at a single instant.
	local dt = 1 / 60
	for _ = 1, math.floor(seconds * 60) do
		ADVANCE(dt)
		RunService.Heartbeat._fire(dt)
		simulate(car, dt)
	end

	-- Displacement from where it started, not distance from the world origin.
	-- Measuring from the origin made a stationary car look like it had
	-- travelled its own spawn height.
	local finish = chassis._props.CFrame
	local travelled = (finish.Position - Vector3.new(0, 5, 0)).Magnitude
	car:Destroy()
	return travelled, finish
end

DUMP("Driving a car forward for 2 seconds at full throttle:")
local distance, endCF = runCar(1, 0, false, 2)
check("car moves forward", distance > 20, string.format("travelled %.0f studs", distance))

-- The reported bug: forward launched the truck into the sky and reverse
-- drove it into the ground. Motion must be HORIZONTAL.
local rise = math.abs(endCF.Position.Y - 5)
check("car does not fly upward", rise < 2, string.format("vertical drift %.2f studs", rise))

local horizontal = (endCF.Position - Vector3.new(0, endCF.Position.Y, 0)).Magnitude
check("motion is along the ground", horizontal > rise * 10,
	string.format("%.0f studs across vs %.2f up", horizontal, rise))

DUMP("")
DUMP("An empty car, same 2 seconds:")
local idle = runCar(nil, 0, false, 2)
check("empty car stays put", idle < 0.5, string.format("moved %.2f studs", idle))

DUMP("")
DUMP("Reverse:")
local back, backCF = runCar(-1, 0, false, 2)
check("reverse moves the car", back > 20, string.format("travelled %.0f studs", back))
local backRise = math.abs(backCF.Position.Y - 5)
check("reverse does not dive", backRise < 2, string.format("vertical drift %.2f studs", backRise))

DUMP("")
DUMP("Turbo:")
-- Run for long enough that both actually reach their top speed. Over a short
-- burst the two look similar, because a car with momentum spends the first
-- second or so winding up rather than cruising.
local plain = runCar(1, 0, false, 6)
local boosted = runCar(1, 0, true, 6)
check("turbo is faster", boosted > plain * 1.4,
	string.format("%.0f studs vs %.0f over 6s", boosted, plain))

-- The reported bug: boost pads launched the truck like a trampoline.
-- Wheels that sit locked solid make a working car look broken.
DUMP("")
DUMP("Wheels:")
do
	local car = VehicleService.SpawnCar(1, Vector3.new(0, 5, 0), nil)
	local chassis = car:FindFirstChild("Chassis")
	chassis._props.CFrame = CFrame.new(0, 5, 0)
	local seat = car:FindFirstChild("DriverSeat")
	seat._props.Occupant = Instance.new("Humanoid")
	seat._props.Throttle = 1
	seat._props.Steer = 0

	local wheel
	for _, child in car:GetChildren() do
		if child._props.Name == "Wheel" then wheel = child break end
	end
	check("the car has wheels", wheel ~= nil, "")

	local startUp = wheel and wheel._props.CFrame.UpVector
	for _ = 1, 60 do
		RunService.Heartbeat._fire(1 / 60)
		simulate(car, 1 / 60)
	end
	local endUp = wheel and wheel._props.CFrame.UpVector

	local spun = startUp and endUp and Util.AngleBetween(startUp, endUp) or 0
	check("wheels rotate while driving", spun > 20,
		string.format("rolled %.0f degrees in a second", spun))

	car:Destroy()
end

DUMP("")
DUMP("Boost pads:")
do
	local pad = Instance.new("Part")
	pad._props.Name = "BoostPad"
	pad:SetAttribute("Boost", true)
	local savedRaycast = rawget(workspace, "_props").Raycast
	rawget(workspace, "_props").Raycast = function()
		return {{
			Instance = pad,
			Position = Vector3.new(0, 0, 0),
			Material = Enum.Material.Plastic,
			Normal = Vector3.new(0, 1, 0),
		}}
	end

	local boostDistance, boostCF = runCar(1, 0, false, 2)
	rawget(workspace, "_props").Raycast = savedRaycast

	check("boost speeds the car up", boostDistance > distance,
		string.format("%.0f studs vs %.0f without", boostDistance, distance))

	-- The whole point of the report: forward, not upward.
	local boostRise = math.abs(boostCF.Position.Y - 5)
	check("boost does NOT launch it upward", boostRise < 2,
		string.format("vertical drift %.2f studs", boostRise))

	check("boost is not a trampoline", boostDistance < 400,
		string.format("%.0f studs in 2s is drivable", boostDistance))
end

-- A car used to allocate a fresh RaycastParams and cast a ground probe every
-- frame. Twenty players each with a car beside them made that two thousand
-- casts a second to answer "am I in mud".
DUMP("")
DUMP("Ground probing:")
do
	local casts = 0
	local saved = rawget(workspace, "_props").Raycast
	rawget(workspace, "_props").Raycast = function(...)
		casts += 1
		return nil
	end

	runCar(1, 0, false, 2) -- 120 frames of driving
	local driving = casts

	casts = 0
	runCar(nil, 0, false, 2) -- 120 frames parked and empty
	local parked = casts

	rawget(workspace, "_props").Raycast = saved

	check("a moving car probes, but not every frame", driving > 10 and driving < 110,
		string.format("%d casts in 120 frames", driving))
	check("a parked empty car does not probe at all", parked == 0,
		string.format("%d casts", parked))
end

--[[SPACING]]


--[[GEAR]]

DUMP("")
DUMP("Steering:")
local _, straightCF = runCar(1, 0, false, 2)
local _, turnedCF = runCar(1, 1, false, 2)
local straightHeading = straightCF.LookVector
local turnedHeading = turnedCF.LookVector
local swing = Util.AngleBetween(straightHeading, turnedHeading)
check("steering changes heading", swing > 15, string.format("turned %.0f degrees", swing))

DUMP("")
DUMP(if failures == 0 then "DRIVING WORKS" else failures .. " FAILURES")

--[[
	Exit non-zero on failure.

	Without this the suite only PRINTED its failures and exited 0, so
	run-all.sh reported success no matter what broke, and any automation
	trusting its exit code was being told a comforting lie. error() at the
	top level is what makes the luau CLI exit non-zero.
]]
if failures > 0 then
	error("driving: " .. failures .. " failures", 0)
end
"""

sys.stdout.write(
    harness
    .replace('--[[SPACING]]', SPACING_TEST)
    .replace('--[[GEAR]]', GEAR_TEST)
)
