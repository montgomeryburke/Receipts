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

SPACING_TEST = '-- The pacing has to be by DISTANCE, not by time. A boost chevron is nine\n-- studs long. A fixed 20 Hz sample is ten studs apart at full speed, so the\n-- pads on the run-up to a ramp get stepped straight over and the jump beyond\n-- never works -- which is a silent failure, because the car still drives.\nDUMP("")\nDUMP("Probe spacing at speed:")\ndo\n\tlocal samples = {}\n\tKEEP_RAYCAST = true\n\tlocal saved = rawget(workspace, "_props").Raycast\n\trawget(workspace, "_props").Raycast = function(_, origin)\n\t\ttable.insert(samples, origin)\n\t\treturn flatGround()\n\tend\n\n\trunCar(1, 0, true, 4) -- full throttle, turbo, long enough to top out\n\trawget(workspace, "_props").Raycast = saved\n\tKEEP_RAYCAST = false\n\n\tlocal widest = 0\n\tfor index = 2, #samples do\n\t\tlocal gap = (samples[index] - samples[index - 1]).Magnitude\n\t\twidest = math.max(widest, gap)\n\tend\n\n\t-- A boost chevron is nine studs long along the direction of travel, so\n\t-- the widest gap has to stay comfortably under that.\n\tcheck("samples are never more than a boost pad apart", widest <= 7,\n\t\tstring.format("widest gap %.1f studs over %d samples", widest, #samples))\n\tcheck("and it still is not sampling every frame", #samples < 240,\n\t\tstring.format("%d samples in 240 frames", #samples))\nend\n\n'

GEAR_TEST = '-- ==================================================== tubes and gliders\n-- The resort is only worth having if the kit actually moves. A tube has no\n-- engine at all: the river\'s current or a snow slope pushes it, and nothing\n-- else does. So these drive it against a stand-in river and a stand-in\n-- mountain and check it goes the right way in each.\n\nlocal function rideTube(surface, seconds)\n\tlocal tube = VehicleService.SpawnTube(Vector3.new(0, 5, 0))\n\tlocal hub = tube:FindFirstChild("Chassis")\n\thub._props.CFrame = CFrame.new(0, 5, 0)\n\thub._props.AssemblyLinearVelocity = Vector3.new()\n\n\tlocal seat = tube:FindFirstChild("DriverSeat")\n\tseat._props.Occupant = Instance.new("Humanoid")\n\tseat._props.Throttle = 0\n\tseat._props.Steer = 0\n\n\tlocal saved = rawget(workspace, "_props").Raycast\n\trawget(workspace, "_props").Raycast = surface\n\n    local dt = 1 / 60\n\tfor _ = 1, math.floor(seconds * 60) do\n\t\tADVANCE(dt)\n\t\tRunService.Heartbeat._fire(dt)\n\t\t-- Integrate whatever velocity the tube driver set.\n\t\tlocal velocity = hub._props.AssemblyLinearVelocity or Vector3.new()\n\t\thub._props.CFrame = CFrame.new(hub._props.CFrame.Position + velocity * dt)\n\t\t\t* hub._props.CFrame.Rotation\n\tend\n\n\trawget(workspace, "_props").Raycast = saved\n\tlocal finish = hub._props.CFrame.Position\n\ttube:Destroy()\n\treturn finish\nend\n\nDUMP("")\nDUMP("The lazy river:")\ndo\n\t-- A flow zone pushing along +X.\n\tlocal flowPart = Instance.new("Part")\n\tflowPart._props.Name = "FlowZone"\n\tflowPart:SetAttribute("FlowX", 1)\n\tflowPart:SetAttribute("FlowY", 0)\n\tflowPart:SetAttribute("FlowZ", 0)\n\n\tlocal finish = rideTube(function()\n\t\treturn {\n\t\t\tInstance = flowPart,\n\t\t\tPosition = Vector3.new(0, 4, 0),\n\t\t\tMaterial = Enum.Material.Water,\n\t\t\tNormal = Vector3.new(0, 1, 0),\n\t\t}\n\tend, 3)\n\n\tcheck("the current carries a tube downstream", finish.X > 60,\n\t\tstring.format("%.0f studs along the flow", finish.X))\n\tcheck("and does not carry it sideways", math.abs(finish.Z) < 10,\n\t\tstring.format("%.1f studs off course", finish.Z))\nend\n\nDUMP("")\nDUMP("The ski run:")\ndo\n\t-- A snow slope tilted so its normal leans toward -Z: downhill is -Z.\n\tlocal snow = Instance.new("Part")\n\tsnow._props.Name = "Piste"\n\n\tlocal finish = rideTube(function()\n\t\treturn {\n\t\t\tInstance = snow,\n\t\t\tPosition = Vector3.new(0, 4, 0),\n\t\t\tMaterial = Enum.Material.Snow,\n\t\t\tNormal = Vector3.new(0, 0.82, -0.57),\n\t\t}\n\tend, 3)\n\n\tcheck("a tube slides down a snow slope", finish.Z < -60,\n\t\tstring.format("%.0f studs downhill", finish.Z))\nend\n\nDUMP("")\nDUMP("Flat snow:")\ndo\n\tlocal flatSnow = Instance.new("Part")\n\tflatSnow._props.Name = "Summit"\n\n\tlocal finish = rideTube(function()\n\t\treturn {\n\t\t\tInstance = flatSnow,\n\t\t\tPosition = Vector3.new(0, 4, 0),\n\t\t\tMaterial = Enum.Material.Snow,\n\t\t\tNormal = Vector3.new(0, 1, 0),\n\t\t}\n\tend, 3)\n\n\t-- A flat surface has a vertical normal and therefore no downhill at all,\n\t-- which has to mean "sit still" rather than "drift in some direction".\n\tcheck("a tube sits still on the flat", finish.Magnitude < 12,\n\t\tstring.format("drifted %.1f studs", finish.Magnitude))\nend\n\nDUMP("")\nDUMP("The hang glider:")\ndo\n\tlocal glider = VehicleService.SpawnGlider(Vector3.new(0, 300, 0))\n\tlocal frame = glider:FindFirstChild("Chassis")\n\tlocal seat = glider:FindFirstChild("DriverSeat")\n\tcheck("the glider has a seat", seat ~= nil, "")\n\n\tseat._props.Occupant = Instance.new("Humanoid")\n\tseat._props.Throttle = 0\n\tseat._props.Steer = 0\n\n\tlocal lift = nil\n\tfor _, child in frame:GetChildren() do\n\t\tif child._props.Name == "DriveVelocity" then lift = child end\n\tend\n\tcheck("the glider has a wing to push it", lift ~= nil, "")\n\n\tfor _ = 1, 120 do\n\t\tADVANCE(1 / 60)\n\t\tRunService.Heartbeat._fire(1 / 60)\n\tend\n\n\tlocal velocity = lift and lift._props.VectorVelocity or Vector3.new()\n\tcheck("a glider flies forwards", velocity.Magnitude > 30,\n\t\tstring.format("%.0f studs/sec", velocity.Magnitude))\n\t-- It is a glider, not a helicopter: it must always be coming down.\n\tcheck("and always sinks", velocity.Y < 0, string.format("%.1f studs/sec vertical", velocity.Y))\n\n\t-- Nose down should be faster than level.\n\tlocal levelSpeed = velocity.Magnitude\n\tseat._props.Throttle = 1\n\tfor _ = 1, 120 do\n\t\tADVANCE(1 / 60)\n\t\tRunService.Heartbeat._fire(1 / 60)\n\tend\n\tlocal diveSpeed = (lift and lift._props.VectorVelocity or Vector3.new()).Magnitude\n\tcheck("diving trades height for speed", diveSpeed > levelSpeed,\n\t\tstring.format("%.0f diving vs %.0f level", diveSpeed, levelSpeed))\n\n\tglider:Destroy()\nend\n\nDUMP("")\nDUMP("Skis and tricks:")\ndo\n\tlocal skis = VehicleService.SpawnSkis(Vector3.new(0, 5, 0))\n\tlocal board = skis:FindFirstChild("Chassis")\n\tcheck("the skis have a board", board ~= nil, "")\n\n\t-- A rider, strapped on.\n\tlocal character = Instance.new("Model")\n\tlocal root = Instance.new("Part")\n\troot._props.Name = "HumanoidRootPart"\n\troot._props.CFrame = CFrame.new(0, 8, 0)\n\troot.Parent = character\n\tlocal humanoid = Instance.new("Humanoid")\n\thumanoid._props.Health = 100\n\thumanoid._props.MoveDirection = Vector3.new()\n\thumanoid.Parent = character\n\tcharacter.Parent = workspace\n\n\tlocal skier = Instance.new("Player")\n\tskier._props.Name = "Skier"\n\tskier._props.DisplayName = "Skier"\n\tskier._props.UserId = 77\n\tskier._props.Character = character\n\t-- Parented, because driveSkis drops a rider whose Parent is nil -- which\n\t-- is exactly right (that is a player who has left), and which silently\n\t-- made this whole block do nothing until the stand-in had a parent.\n\tskier.Parent = Players\n\trawget(Players, "_props").GetPlayerFromCharacter = function(_, c)\n\t\tif c == character then return skier end\n\t\treturn nil\n\tend\n\n\tVehicleService.MountSkis(skier, skis)\n\tcheck("a skier is strapped on", VehicleService.GetState(skis).rider == skier, "")\n\tcheck("and stands up rather than sitting", humanoid._props.PlatformStand == true, "")\n\n\t-- Tricks are measured, never reported: the server watches airtime and\n\t-- spin itself, so there is nothing for a client to lie about.\n\tlocal landed = {}\n\tVehicleService.TrickLanded.Connect(function(who, name, points, airtime)\n\t\ttable.insert(landed, { who = who, name = name, points = points, airtime = airtime })\n\tend)\n\n\tlocal function fly(seconds, spinDegrees, grounded)\n\t\tlocal steps = math.floor(seconds * 60)\n\t\tlocal perStep = spinDegrees / math.max(1, steps)\n\t\trawget(workspace, "_props").Raycast = function()\n\t\t\tif not grounded then return nil end\n\t\t\treturn {\n\t\t\t\tInstance = board,\n\t\t\t\tPosition = Vector3.new(0, 4, 0),\n\t\t\t\tMaterial = Enum.Material.Snow,\n\t\t\t\tNormal = Vector3.new(0, 1, 0),\n\t\t\t}\n\t\tend\n\t\tfor _ = 1, steps do\n\t\t\tADVANCE(1 / 60)\n\t\t\tboard._props.CFrame = board._props.CFrame * CFrame.Angles(0, math.rad(perStep), 0)\n\t\t\tRunService.Heartbeat._fire(1 / 60)\n\t\tend\n\t\t-- Signal.Fire hands each listener to task.spawn, so the trick\n\t\t-- announcement sits in the queue until it is flushed. Without this\n\t\t-- the whole block read as "tricks never score".\n\t\tRUN_SPAWNED()\n\tend\n\n\t-- A small bump must NOT pay out, or every seam in the piste is a trick.\n\tlanded = {}\n\tfly(0.2, 10, false)\n\tfly(0.2, 0, true)\n\tcheck("a bump in the piste is not a trick", #landed == 0,\n\t\tstring.format("%d tricks", #landed))\n\n\t-- Real air, with a spin, must.\n\tlanded = {}\n\tfly(1.4, 540, false)\n\tfly(0.2, 0, true)\n\tcheck("real air off a jump scores", #landed == 1, string.format("%d tricks", #landed))\n\tif #landed == 1 then\n\t\tcheck("it is credited to the rider", landed[1].who == skier, tostring(landed[1].who))\n\t\tcheck("it is worth real points", landed[1].points > 50,\n\t\t\tstring.format("%d points for %s", landed[1].points, landed[1].name))\n\t\tcheck("a big spin gets a big name", landed[1].name ~= "BIG AIR", landed[1].name)\n\tend\n\n\t-- Straight air with no rotation still counts, but for less.\n\tlanded = {}\n\tfly(1.4, 0, false)\n\tfly(0.2, 0, true)\n\tcheck("straight air counts for less", #landed == 1 and landed[1].name == "BIG AIR",\n\t\tif #landed == 1 then landed[1].name else "nothing")\n\n\trawget(workspace, "_props").Raycast = function() return nil end\n\tVehicleService.DismountSkis(skier)\n\tcheck("you can get off the skis", VehicleService.GetState(skis).rider == nil, "")\n\tcheck("and walk again", humanoid._props.PlatformStand == false, "")\n\n\tskis:Destroy()\nend\n\nDUMP("")\nDUMP("Off-roaders:")\ndo\n\t-- The climb assist is gone, and deliberately so. It tilted the drive\n\t-- axis up a slope to compensate for a car being SHOVED along a\n\t-- horizontal line; now the wheels drive the car through tire friction,\n\t-- so an off-roader climbs because it grips. What is left to check is\n\t-- that the three of them still exist and are still the slow, grippy\n\t-- ones.\n\tlocal found = {}\n\tfor _, body in Config.CarBodies do\n\t\tif body.OffRoad then\n\t\t\ttable.insert(found, body.Name)\n\t\tend\n\tend\n\tcheck("the off-roaders are still there", #found == 3, table.concat(found, ", "))\n\n\tlocal fastest = 0\n\tfor _, body in Config.CarBodies do\n\t\tif not body.OffRoad then\n\t\t\tfastest = math.max(fastest, body.SpeedBias)\n\t\tend\n\tend\n\tlocal slowest = math.huge\n\tfor _, body in Config.CarBodies do\n\t\tif body.OffRoad then\n\t\t\tslowest = math.min(slowest, body.SpeedBias)\n\t\tend\n\tend\n\tcheck("and slower on the flat than a road car", slowest < fastest,\n\t\tstring.format("%.2f vs %.2f", slowest, fastest))\nend\n'

GROUND_HELPER = '-- A flat road under the car. The suite used to run every driving check with\n-- Raycast returning nil, which is a car suspended in a void -- fine for the\n-- drive constraint, useless for anything that asks what it is standing on.\nlocal ROAD = Instance.new("Part")\nROAD._props.Name = "Street"\n\n-- Set by any test that installs its own Raycast, so runCar leaves it alone\n-- rather than replacing it with plain road and quietly measuring nothing.\nKEEP_RAYCAST = false\n\nlocal function flatGround()\n\treturn {\n\t\tInstance = ROAD,\n\t\tPosition = Vector3.new(0, 0, 0),\n\t\tMaterial = Enum.Material.Asphalt,\n\t\tNormal = Vector3.new(0, 1, 0),\n\t}\nend\n\n'

HOG_TEST = 'DUMP("")\nDUMP("The Warthog:")\ndo\n\t--[[\n\t\tThree things make it a Warthog rather than a jeep with a gun, and\n\t\tall three are checkable without a contact solver: the rears steer\n\t\tthe OTHER way, the handbrake locks only the back, and the flip\n\t\tprompt only exists when it is upside down.\n\t]]\n\tlocal hog = VehicleService.SpawnWarthog(Vector3.new(0, 5, 0))\n\tlocal chassis = hog:FindFirstChild("Chassis")\n\tchassis._props.CFrame = CFrame.new(0, 5, 0)\n\tlocal seat = hog:FindFirstChild("DriverSeat")\n\n\t-- Three seats: a driver, a gunner, and somebody who just rides along\n\t-- and shoots their own rifle. That is what makes it a squad vehicle.\n\t-- Descendants, not children: the gunner\'s seat hangs off the turret\n\t-- drum rather than off the model, so counting only direct children\n\t-- finds two and reads as a missing seat.\n\t--[[\n\t\tBoth seat classes count.\n\n\t\tOnly the driver\'s is a VehicleSeat; the gunner\'s and the\n\t\tpassenger\'s are plain Seats, which cannot steer by construction\n\t\trather than by having their numbers zeroed. Counting only\n\t\tVehicleSeats finds one and reads as two missing seats.\n\t]]\n\tlocal seats = 0\n\tfor _, thing in hog:GetDescendants() do\n\t\tif thing._class == "VehicleSeat" or thing._class == "Seat" then\n\t\t\tseats += 1\n\t\tend\n\tend\n\tcheck("the Warthog seats three", seats == 3, string.format("%d seats", seats))\n\tcheck("one of them is a passenger seat",\n\t\thog:FindFirstChild("PassengerSeat") ~= nil, "")\n\n\t--[[\n\t\tAll four wheels steer.\n\n\t\tOn every other car the rears are pinned at zero. Here they are\n\t\tservos too, which is what lets it pivot about its middle.\n\t]]\n\tlocal steerers = 0\n\tfor _, child in chassis:GetChildren() do\n\t\tif child._props.Name == "SteerSlider" then\n\t\t\tsteerers += 1\n\t\tend\n\tend\n\tcheck("all four wheels steer", steerers == 4, string.format("%d steering", steerers))\n\n\tlocal function angles()\n\t\tlocal front, rear = 0, 0\n\t\tfor _, wheel in VehicleService.GetState(hog).wheels do\n\t\t\tlocal slider = wheel.slider\n\t\t\tif slider then\n\t\t\t\tif wheel.front then\n\t\t\t\t\tfront = slider._props.TargetAngle or 0\n\t\t\t\telse\n\t\t\t\t\trear = slider._props.TargetAngle or 0\n\t\t\t\tend\n\t\t\tend\n\t\tend\n\t\treturn front, rear\n\tend\n\n\tseat._props.Occupant = Instance.new("Humanoid")\n\tseat._props.ThrottleFloat = 1\n\tseat._props.SteerFloat = 1\n\tchassis._props.AssemblyLinearVelocity = Vector3.new()\n\tADVANCE(1 / 60)\n\tRunService.Heartbeat._fire(1 / 60)\n\n\tlocal front, rear = angles()\n\tcheck("the fronts turn", math.abs(front) > 1, string.format("%.1f degrees", front))\n\t--[[\n\t\tTHE signature: opposite sign.\n\n\t\tIf the rears turned the same way it would crab sideways instead of\n\t\tturning, and if they stayed at zero it would just be a jeep.\n\t]]\n\tcheck("and the rears turn the OTHER way", front * rear < 0,\n\t\tstring.format("front %.1f, rear %.1f degrees", front, rear))\n\tcheck("but not as far, or it crabs instead of turning",\n\t\tmath.abs(rear) < math.abs(front),\n\t\tstring.format("%.1f vs %.1f degrees", math.abs(rear), math.abs(front)))\n\n\t--[[\n\t\tThe handbrake locks the REAR only.\n\n\t\tLocking all four is just a brake. Locking the rears while the\n\t\tfronts keep turning and keep their grip is what throws the back end\n\t\tround, which is the whole manoeuvre.\n\t]]\n\tlocal driver = Instance.new("Player")\n\tdriver._props.Name = "Driver"\n\tdriver._props.UserId = 404\n\tlocal driverCharacter = Instance.new("Model")\n\tlocal driverHumanoid = Instance.new("Humanoid")\n\tdriverHumanoid.Parent = driverCharacter\n\tdriver._props.Character = driverCharacter\n\tdriver.Parent = Players\n\tseat._props.Occupant = driverHumanoid\n\trawget(Players, "_props").GetPlayerFromCharacter = function(_, c)\n\t\tif c == driverCharacter then return driver end\n\t\treturn nil\n\tend\n\n\tVehicleService.SetHandbrake(driver, true)\n\tADVANCE(1 / 60)\n\tRunService.Heartbeat._fire(1 / 60)\n\n\tlocal frontTurning, rearLocked = 0, 0\n\tlocal rearGrip = nil\n\tfor _, wheel in VehicleService.GetState(hog).wheels do\n\t\tlocal axle = wheel.axle\n\t\tif axle then\n\t\t\tif wheel.front then\n\t\t\t\tif math.abs(axle._props.AngularVelocity or 0) > 1 then\n\t\t\t\t\tfrontTurning += 1\n\t\t\t\tend\n\t\t\telse\n\t\t\t\tif math.abs(axle._props.AngularVelocity or 0) < 0.01 then\n\t\t\t\t\trearLocked += 1\n\t\t\t\tend\n\t\t\t\trearGrip = wheel.part._props.CustomPhysicalProperties.Friction\n\t\t\tend\n\t\tend\n\tend\n\tcheck("the handbrake locks the back wheels", rearLocked == 2,\n\t\tstring.format("%d locked", rearLocked))\n\tcheck("while the fronts keep driving", frontTurning == 2,\n\t\tstring.format("%d driving", frontTurning))\n\tcheck("and the back loses grip, which is the whole point",\n\t\trearGrip ~= nil and rearGrip < Config.Driving.WheelFriction,\n\t\tstring.format("%.2f vs %.2f normally",\n\t\t\trearGrip or -1, Config.Driving.WheelFriction))\n\n\tVehicleService.SetHandbrake(driver, false)\n\n\t--[[\n\t\tThe flip prompt exists only when it is on its roof.\n\n\t\tOtherwise every upright Warthog has a prompt hanging off it, and\n\t\tthere is a free "put my car where I am standing" button.\n\t]]\n\tlocal prompt = chassis:FindFirstChild("FlipPrompt")\n\tcheck("there is a flip prompt", prompt ~= nil, "")\n\n\tchassis._props.CFrame = CFrame.new(0, 5, 0)\n\tADVANCE(1 / 60)\n\tRunService.Heartbeat._fire(1 / 60)\n\tcheck("it is hidden while the right way up",\n\t\tprompt ~= nil and prompt._props.Enabled == false,\n\t\ttostring(prompt and prompt._props.Enabled))\n\n\t-- On its roof.\n\tchassis._props.CFrame = CFrame.new(0, 5, 0) * CFrame.Angles(math.pi, 0, 0)\n\tADVANCE(1 / 60)\n\tRunService.Heartbeat._fire(1 / 60)\n\tcheck("and offered once it is upside down",\n\t\tprompt ~= nil and prompt._props.Enabled == true,\n\t\ttostring(prompt and prompt._props.Enabled))\n\n\t-- Triggering it sets it back on its wheels.\n\tif prompt then\n\t\tprompt._props.Triggered._fire(driver)\n\t\tlocal upright = chassis._props.CFrame.UpVector:Dot(Vector3.new(0, 1, 0))\n\t\tcheck("flipping it puts it back on its wheels", upright > 0.9,\n\t\t\tstring.format("%.2f upright", upright))\n\tend\n\n\thog:Destroy()\nend\n\n'

RIG_TEST = 'DUMP("The drivetrain rig:")\n\n--[[\n\tWhat this can and cannot prove, stated plainly.\n\n\tThe car is now driven by hinge motors at four wheels, held up by springs,\n\tsteered by servos, with traction coming from tire friction. None of that\n\tcan be simulated in a terminal: there is no contact solver here, so no\n\tamount of asking will make a stand-in car physically move.\n\n\tWhat IS checkable, and what actually went wrong before, is the rig and\n\tthe commands sent to it -- whether the wheels are attached at all,\n\twhether the motors are asked to turn the right way at the right rate,\n\twhether the brakes are brakes, whether the steering falls off with speed.\n\tThose were the real bugs. "Does Roblox\'s contact solver work" was never\n\tone of them.\n]]\nlocal function newCar()\n\tlocal car = VehicleService.SpawnCar(1, Vector3.new(0, 5, 0), nil, "Truck")\n\tlocal chassis = car:FindFirstChild("Chassis")\n\tchassis._props.CFrame = CFrame.new(0, 5, 0)\n\tlocal seat = car:FindFirstChild("DriverSeat")\n\treturn car, chassis, seat\nend\n\nlocal function drive(seat, throttle, steer)\n\tseat._props.Occupant = seat._props.Occupant or Instance.new("Humanoid")\n\tseat._props.Throttle = throttle\n\tseat._props.Steer = steer\n\tseat._props.ThrottleFloat = throttle\n\tseat._props.SteerFloat = steer\nend\n\nlocal function wheelsOf(car)\n\tlocal out = {}\n\tfor _, child in car:GetChildren() do\n\t\tif child._props.Name == "Wheel" then\n\t\t\ttable.insert(out, child)\n\t\tend\n\tend\n\treturn out\nend\n\nlocal function partsNamed(car, name)\n\tlocal out = {}\n\tfor _, child in car:GetChildren() do\n\t\tif child._props.Name == name then\n\t\t\ttable.insert(out, child)\n\t\tend\n\t\tfor _, grand in child:GetChildren() do\n\t\t\tif grand._props.Name == name then\n\t\t\t\ttable.insert(out, grand)\n\t\t\tend\n\t\tend\n\tend\n\treturn out\nend\n\ndo\n\tlocal car, chassis, seat = newCar()\n\n\tlocal wheels = wheelsOf(car)\n\tcheck("the car has four wheels", #wheels == 4, string.format("%d wheels", #wheels))\n\n\t-- The original bug. An anchored wheel is teleported rather than\n\t-- simulated, which is exactly why they looked like they fell off.\n\tlocal anchored = 0\n\tfor _, wheel in wheels do\n\t\tif wheel._props.Anchored == true then anchored += 1 end\n\tend\n\tcheck("no wheel is anchored", anchored == 0, string.format("%d anchored", anchored))\n\n\tcheck("each wheel has a knuckle", #partsNamed(car, "Knuckle") == 4,\n\t\tstring.format("%d knuckles", #partsNamed(car, "Knuckle")))\n\n\t-- Springs are what hold the car up. Without them it sits on the limit\n\t-- of its slider and rides like a brick.\n\tlocal springs = 0\n\tlocal sliders = 0\n\tlocal steerers = 0\n\tfor _, child in chassis:GetChildren() do\n\t\tlocal n = child._props.Name\n\t\tif n == "Spring" then springs += 1 end\n\t\tif n == "Slider" or n == "SteerSlider" then sliders += 1 end\n\t\tif n == "SteerSlider" then steerers += 1 end\n\tend\n\tcheck("all four corners are sprung", springs == 4, string.format("%d springs", springs))\n\tcheck("all four have suspension travel", sliders == 4, string.format("%d sliders", sliders))\n\tcheck("and exactly two of them steer", steerers == 2, string.format("%d steering", steerers))\n\n\tcar:Destroy()\nend\n\nDUMP("")\nDUMP("Throttle, brake and coast:")\ndo\n\tlocal car, chassis, seat = newCar()\n\tlocal axles = partsNamed(car, "Axle")\n\tcheck("every wheel has a motor", #axles == 4, string.format("%d axles", #axles))\n\n\t-- Full throttle: the motors are asked to turn, in the direction that\n\t-- drives the car forwards.\n\tdrive(seat, 1, 0)\n\tADVANCE(1 / 60)\n\tRunService.Heartbeat._fire(1 / 60)\n\n\tlocal spinning = 0\n\tlocal torque = 0\n\tfor _, axle in axles do\n\t\tif math.abs(axle._props.AngularVelocity or 0) > 1 then spinning += 1 end\n\t\ttorque = axle._props.MotorMaxTorque or 0\n\tend\n\tcheck("throttle turns all four motors", spinning == 4,\n\t\tstring.format("%d turning", spinning))\n\tcheck("with drive torque behind them", torque >= Config.Driving.MotorTorque,\n\t\tstring.format("%.0f", torque))\n\n\t-- Braking is asking for zero with a lot of torque, which is what a\n\t-- brake is. Reverse while rolling forwards must brake, not reverse.\n\tchassis._props.AssemblyLinearVelocity = chassis._props.CFrame.LookVector * 40\n\tdrive(seat, -1, 0)\n\tADVANCE(1 / 60)\n\tRunService.Heartbeat._fire(1 / 60)\n\n\tlocal braked = true\n\tlocal brakeTorque = 0\n\tfor _, axle in axles do\n\t\tif math.abs(axle._props.AngularVelocity or 0) > 0.01 then braked = false end\n\t\tbrakeTorque = axle._props.MotorMaxTorque or 0\n\tend\n\tcheck("reverse while rolling forward brakes", braked, "")\n\tcheck("and brakes harder than it drives",\n\t\tbrakeTorque >= Config.Driving.BrakeTorque, string.format("%.0f", brakeTorque))\n\n\t-- Off the throttle it coasts: zero, with barely any torque. That is\n\t-- engine braking rather than a handbrake.\n\tchassis._props.AssemblyLinearVelocity = Vector3.new()\n\tdrive(seat, 0, 0)\n\tADVANCE(1 / 60)\n\tRunService.Heartbeat._fire(1 / 60)\n\tlocal coastTorque = 0\n\tfor _, axle in axles do\n\t\tcoastTorque = axle._props.MotorMaxTorque or 0\n\tend\n\tcheck("coasting is gentle, not a handbrake",\n\t\tcoastTorque < Config.Driving.MotorTorque * 0.5, string.format("%.0f", coastTorque))\n\n\tcar:Destroy()\nend\n\nDUMP("")\nDUMP("Steering:")\ndo\n\tlocal car, chassis, seat = newCar()\n\n\tlocal function steerAngles()\n\t\tlocal front = {}\n\t\tfor _, child in chassis:GetChildren() do\n\t\t\tif child._props.Name == "SteerSlider" then\n\t\t\t\ttable.insert(front, child._props.TargetAngle or 0)\n\t\t\tend\n\t\tend\n\t\treturn front\n\tend\n\n\tchassis._props.AssemblyLinearVelocity = Vector3.new()\n\tdrive(seat, 1, 1)\n\tADVANCE(1 / 60)\n\tRunService.Heartbeat._fire(1 / 60)\n\tlocal slow = steerAngles()\n\n\tlocal turning = 0\n\tfor _, angle in slow do\n\t\tif math.abs(angle) > 1 then turning += 1 end\n\tend\n\tcheck("steering turns the front wheels", turning == 2,\n\t\tstring.format("%d turned", turning))\n\n\t-- Ackermann: the inner wheel turns sharper than the outer, or the front\n\t-- end scrubs through a tight corner.\n\tlocal widest, narrowest = 0, math.huge\n\tfor _, angle in slow do\n\t\twidest = math.max(widest, math.abs(angle))\n\t\tnarrowest = math.min(narrowest, math.abs(angle))\n\tend\n\tcheck("the inner wheel turns sharper than the outer", widest > narrowest + 0.5,\n\t\tstring.format("%.1f vs %.1f degrees", widest, narrowest))\n\n\t-- And lock falls away with speed, or a twitch at 100 studs a second\n\t-- rolls the car.\n\tchassis._props.AssemblyLinearVelocity = chassis._props.CFrame.LookVector * 400\n\tADVANCE(1 / 60)\n\tRunService.Heartbeat._fire(1 / 60)\n\tlocal fast = steerAngles()\n\tlocal fastMax = 0\n\tfor _, angle in fast do\n\t\tfastMax = math.max(fastMax, math.abs(angle))\n\tend\n\tcheck("there is less lock at speed", fastMax < widest - 1,\n\t\tstring.format("%.1f degrees at speed vs %.1f stopped", fastMax, widest))\n\n\tcar:Destroy()\nend\n\nDUMP("")\nDUMP("Turbo, mud and boost:")\ndo\n\tlocal function requestedSpeed(setup)\n\t\tlocal car, chassis, seat = newCar()\n\t\tchassis._props.AssemblyLinearVelocity = Vector3.new()\n\t\tdrive(seat, 1, 0)\n\t\tsetup(car, chassis)\n\t\tADVANCE(1 / 60)\n\t\tRunService.Heartbeat._fire(1 / 60)\n\t\tlocal fastest = 0\n\t\tfor _, axle in partsNamed(car, "Axle") do\n\t\t\tfastest = math.max(fastest, math.abs(axle._props.AngularVelocity or 0))\n\t\tend\n\t\tcar:Destroy()\n\t\treturn fastest\n\tend\n\n\tlocal plain = requestedSpeed(function() end)\n\tlocal turbo = requestedSpeed(function(car)\n\t\tcar:SetAttribute("Turbo", true)\n\tend)\n\tcheck("turbo asks for more speed", turbo > plain,\n\t\tstring.format("%.1f vs %.1f rad/sec", turbo, plain))\n\n\t-- Mud: the probe has to see mud under the car.\n\tKEEP_RAYCAST = true\n\tlocal mudPart = Instance.new("Part")\n\tmudPart._props.Name = "Mud"\n\tlocal saved = rawget(workspace, "_props").Raycast\n\trawget(workspace, "_props").Raycast = function()\n\t\treturn {\n\t\t\tInstance = mudPart,\n\t\t\tPosition = Vector3.new(0, 0, 0),\n\t\t\tMaterial = Enum.Material.Mud,\n\t\t\tNormal = Vector3.new(0, 1, 0),\n\t\t}\n\tend\n\tlocal mud = requestedSpeed(function() end)\n\trawget(workspace, "_props").Raycast = saved\n\tKEEP_RAYCAST = false\n\n\tcheck("mud slows it down", mud < plain,\n\t\tstring.format("%.1f in mud vs %.1f on road", mud, plain))\nend\n\n'

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

--[[GROUND]]

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
		-- The analog pair is what the drive loop actually reads.
		seat._props.ThrottleFloat = throttle
		seat._props.SteerFloat = steer
	end
	car:SetAttribute("Turbo", turbo)

	-- Advance the virtual clock with the frames, not just the frame count.
	-- Without this os.clock() stood still for the whole run, so every piece
	-- of time-based logic in the drive code -- the throttled ground probe,
	-- anything on a cooldown -- was only ever tested at a single instant.
	local savedRay = rawget(workspace, "_props").Raycast
	if not KEEP_RAYCAST then
		rawget(workspace, "_props").Raycast = flatGround
	end

	local dt = 1 / 60
	for _ = 1, math.floor(seconds * 60) do
		ADVANCE(dt)
		RunService.Heartbeat._fire(dt)
		simulate(car, dt)
	end
	rawget(workspace, "_props").Raycast = savedRay

	-- Displacement from where it started, not distance from the world origin.
	-- Measuring from the origin made a stationary car look like it had
	-- travelled its own spawn height.
	local finish = chassis._props.CFrame
	local travelled = (finish.Position - Vector3.new(0, 5, 0)).Magnitude
	car:Destroy()
	return travelled, finish
end

--[[RIG]]

--[[HOG]]

--[[GEAR]]

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
    .replace('--[[GROUND]]', GROUND_HELPER)
    .replace('--[[RIG]]', RIG_TEST)
    .replace('--[[HOG]]', HOG_TEST)
)
