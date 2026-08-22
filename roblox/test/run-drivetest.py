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

local Config = (function()
{strip(read(SRC, 'shared', 'Config.luau'))}
end)()
local Signal = (function()
{strip(read(SRC, 'shared', 'Signal.luau'))}
end)()
local Util = (function()
{strip(read(SRC, 'shared', 'Util.luau'))}
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

	local dt = 1 / 60
	for _ = 1, math.floor(seconds * 60) do
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
"""

sys.stdout.write(harness)
