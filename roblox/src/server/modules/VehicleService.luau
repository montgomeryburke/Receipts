--!strict
--[[
	VehicleService — builds and drives everything with an engine in it.

	Every vehicle is assembled from plain parts and constraints at runtime, so
	there are no models to import and nothing to break when you edit a number.

	HOW THE CARS STEER
	------------------
	Roblox's VehicleSeat hands us two numbers for free when a player holds WASD:
	  Throttle  -1 (S) to 1 (W)
	  Steer     -1 (A) to 1 (D)

	We turn those into motor speeds. Each front wheel hangs off a "knuckle" —
	a small part on a servo hinge that swings left and right — and each wheel
	spins on its own motor hinge. Back wheels have no knuckle; they just drive.
	This is the standard Roblox car layout, which matters because if you ever
	need help with it, every tutorial online will match what is here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))

local VehicleService = {}

local WHEEL_DIAMETER = 7
local WHEEL_WIDTH = 4
local CHASSIS_HEIGHT = 4

-- Wheels want grip; the chassis wants weight so it does not tip over.
local WHEEL_PHYSICS = PhysicalProperties.new(1.2, 2.0, 0.1, 100, 1)
local CHASSIS_PHYSICS = PhysicalProperties.new(4.5, 0.3, 0.2, 1, 1)

--[[ Every vehicle currently alive in the world, so we can drive them each frame. ]]
local active: { [Model]: any } = {}

-- ============================================================ PART HELPERS ==

local function noCollide(a: BasePart, b: BasePart)
	local constraint = Instance.new("NoCollisionConstraint")
	constraint.Part0 = a
	constraint.Part1 = b
	constraint.Parent = a
end

--[[
	A hinge between two parts.

	`axisTurn` decides which way the hinge axis points. An Attachment's axis is
	its own X direction, so:
	  nil  -> X stays X, the hinge spins like a wheel (sideways axle)
	  "up" -> X is rotated onto Y, the hinge swings like a door (vertical axle)
]]
local function hinge(
	partA: BasePart,
	partB: BasePart,
	worldPosition: Vector3,
	axisTurn: string?,
	actuator: Enum.ActuatorType
): HingeConstraint
	local localTwist = if axisTurn == "up" then CFrame.Angles(0, 0, math.rad(90)) else CFrame.identity

	local attachA = Instance.new("Attachment")
	attachA.CFrame = partA.CFrame:ToObjectSpace(CFrame.new(worldPosition) * partA.CFrame.Rotation) * localTwist
	attachA.Parent = partA

	local attachB = Instance.new("Attachment")
	attachB.CFrame = partB.CFrame:ToObjectSpace(CFrame.new(worldPosition) * partB.CFrame.Rotation) * localTwist
	attachB.Parent = partB

	local constraint = Instance.new("HingeConstraint")
	constraint.Attachment0 = attachA
	constraint.Attachment1 = attachB
	constraint.ActuatorType = actuator
	constraint.Parent = partA

	noCollide(partA, partB)
	return constraint
end

--[[
	One wheel, optionally steerable.

	A steerable wheel gets an extra part in the middle — the knuckle — so the
	wheel can spin and swing at the same time without those two jobs fighting.
]]
local function addWheel(chassis: BasePart, offset: Vector3, steerable: boolean, model: Model)
	local worldPosition = (chassis.CFrame * CFrame.new(offset)).Position

	local wheel = Util.Part({
		Name = if steerable then "SteerWheel" else "DriveWheel",
		Size = Vector3.new(WHEEL_WIDTH, WHEEL_DIAMETER, WHEEL_DIAMETER),
		-- A cylinder's flat faces point along its own X, which is already the
		-- car's left-right axis, so no extra rotation is needed here.
		CFrame = chassis.CFrame * CFrame.new(offset),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(30, 30, 34),
		Material = Enum.Material.Rubber,
		Anchored = false,
		CustomPhysicalProperties = WHEEL_PHYSICS,
		Parent = model,
	})

	if not steerable then
		local motor = hinge(chassis, wheel, worldPosition, nil, Enum.ActuatorType.Motor)
		motor.Name = "DriveMotor"
		return
	end

	-- Knuckle: an invisible stub that swings left and right on a vertical axle.
	local knuckle = Util.Part({
		Name = "Knuckle",
		Size = Vector3.new(1, 1, 1),
		CFrame = chassis.CFrame * CFrame.new(offset),
		Transparency = 1,
		CanCollide = false,
		Anchored = false,
		Massless = true,
		Parent = model,
	})

	local steer = hinge(chassis, knuckle, worldPosition, "up", Enum.ActuatorType.Servo)
	steer.Name = "SteerServo"
	steer.ServoMaxTorque = 90000
	steer.AngularSpeed = 8
	steer.LimitsEnabled = true
	steer.UpperAngle = 40
	steer.LowerAngle = -40

	local motor = hinge(knuckle, wheel, worldPosition, nil, Enum.ActuatorType.Motor)
	motor.Name = "DriveMotor"

	noCollide(wheel, chassis)
end

-- ================================================================== CHASSIS ==

--[[ The shared skeleton every wheeled vehicle is built on. ]]
local function buildChassis(
	name: string,
	position: Vector3,
	bodySize: Vector3,
	color: Color3,
	wheelbase: number,
	track: number
): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = name

	local chassis = Util.Part({
		Name = "Chassis",
		Size = bodySize,
		CFrame = CFrame.new(position + Vector3.new(0, WHEEL_DIAMETER * 0.5 + CHASSIS_HEIGHT, 0)),
		Color = color,
		Material = Enum.Material.Metal,
		Anchored = false,
		CustomPhysicalProperties = CHASSIS_PHYSICS,
		Parent = model,
	})
	model.PrimaryPart = chassis

	local halfBase = wheelbase * 0.5
	local halfTrack = track * 0.5
	local axleDrop = -bodySize.Y * 0.5

	addWheel(chassis, Vector3.new(-halfTrack, axleDrop, -halfBase), true, model)
	addWheel(chassis, Vector3.new(halfTrack, axleDrop, -halfBase), true, model)
	addWheel(chassis, Vector3.new(-halfTrack, axleDrop, halfBase), false, model)
	addWheel(chassis, Vector3.new(halfTrack, axleDrop, halfBase), false, model)

	return model, chassis
end

--[[ The driver's seat. Sitting in it is what gives us Throttle and Steer. ]]
local function addDriverSeat(chassis: BasePart, model: Model, offset: Vector3): VehicleSeat
	local seat = Instance.new("VehicleSeat")
	seat.Name = "DriverSeat"
	seat.Size = Vector3.new(4, 1, 4)
	seat.CFrame = chassis.CFrame * CFrame.new(offset)
	seat.Color = Color3.fromRGB(40, 40, 44)
	seat.Anchored = false
	seat.Massless = true
	-- We drive the motors ourselves, so the built-in handling is turned off.
	seat.MaxSpeed = 0
	seat.Torque = 0
	seat.TurnSpeed = 0
	seat.Parent = model
	Util.Weld(chassis, seat)
	return seat
end

--[[ A passenger seat that does not drive — used by gunners. ]]
local function addPassengerSeat(attachTo: BasePart, model: Model, offset: Vector3, name: string): Seat
	local seat = Instance.new("Seat")
	seat.Name = name
	seat.Size = Vector3.new(4, 1, 4)
	seat.CFrame = attachTo.CFrame * CFrame.new(offset)
	seat.Color = Color3.fromRGB(60, 50, 40)
	seat.Anchored = false
	seat.Massless = true
	seat.Parent = model
	Util.Weld(attachTo, seat)
	return seat
end

--[[
	A turret: a rotating drum with a barrel, plus a seat for whoever is
	spinning it. Yaw and pitch are servo hinges the server points wherever the
	gunner is looking.
]]
local function addTurret(chassis: BasePart, model: Model, offset: Vector3, barrelLength: number, color: Color3)
	local drumPosition = chassis.CFrame * CFrame.new(offset)

	local drum = Util.Part({
		Name = "TurretDrum",
		Size = Vector3.new(7, 3, 7),
		CFrame = drumPosition,
		Color = color:Lerp(Color3.new(0, 0, 0), 0.2),
		Material = Enum.Material.Metal,
		Anchored = false,
		Parent = model,
	})

	local yaw = hinge(chassis, drum, drumPosition.Position, "up", Enum.ActuatorType.Servo)
	yaw.Name = "TurretYaw"
	yaw.ServoMaxTorque = 250000
	yaw.AngularSpeed = 3
	-- No limits: the turret spins all the way round.
	yaw.LimitsEnabled = false

	local barrel = Util.Part({
		Name = "Barrel",
		Size = Vector3.new(1.6, 1.6, barrelLength),
		CFrame = drum.CFrame * CFrame.new(0, 1.2, -barrelLength * 0.5),
		Color = Color3.fromRGB(40, 40, 44),
		Material = Enum.Material.Metal,
		Anchored = false,
		Massless = true,
		Parent = model,
	})
	Util.Weld(drum, barrel)

	-- Where bullets actually come out.
	Util.Attachment(barrel, Vector3.new(0, 0, -barrelLength * 0.5), "Muzzle")

	local gunnerSeat = addPassengerSeat(drum, model, Vector3.new(0, 2, 2.5), "GunnerSeat")

	return drum, barrel, gunnerSeat, yaw
end

--[[
	Watch a seat so the rest of the game knows who is sitting where.

	This is what lets the gunner of a turret truck fire the 50 cal while
	somebody else drives: the seat you are in decides which gun is yours.
]]
local function bindSeat(seat: Seat | VehicleSeat, model: Model, role: string)
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = seat.Occupant

		if occupant then
			local character = occupant.Parent
			local player = if character then Players:GetPlayerFromCharacter(character) else nil
			if player then
				local state = PlayerState.Get(player)
				state.vehicle = model
				state.seatRole = role
				PlayerState.Changed.Fire(player)
			end
			return
		end

		-- Somebody just got out. Clear whoever was pointing at this seat.
		for _, player in Players:GetPlayers() do
			local state = PlayerState.Get(player)
			if state.vehicle == model and state.seatRole == role then
				state.vehicle = nil
				state.seatRole = nil
				PlayerState.Changed.Fire(player)
			end
		end
	end)
end

-- ================================================================ BUILDERS ==

--[[ A plain car. Tier decides how fast and how mean it looks. ]]
function VehicleService.SpawnCar(tierIndex: number, position: Vector3, owner: Player?): Model
	local tier = Config.CarTiers[math.clamp(tierIndex, 1, #Config.CarTiers)]

	local model, chassis = buildChassis(
		`Car_{tier.Name}`,
		position,
		Vector3.new(10, CHASSIS_HEIGHT, 18),
		tier.Color,
		14,
		10
	)
	local seat = addDriverSeat(chassis, model, Vector3.new(0, CHASSIS_HEIGHT * 0.5 + 0.5, 1))

	bindSeat(seat, model, "Driver")

	model:SetAttribute("Health", 260)
	model:SetAttribute("MaxHealth", 260)
	model:SetAttribute("VehicleKind", "Car")
	if owner then
		model:SetAttribute("OwnerUserId", owner.UserId)
	end

	model.Parent = workspace
	active[model] = {
		kind = "Car",
		chassis = chassis,
		seat = seat,
		maxSpeed = tier.MaxSpeed,
		torque = tier.Torque,
		turnSpeed = tier.TurnSpeed,
	}
	return model
end

--[[ The turret truck: one player drives, another works the 50 cal on the back. ]]
function VehicleService.SpawnTurretTruck(position: Vector3): Model
	local spec = Config.Vehicles.TurretTruck

	local model, chassis = buildChassis(
		"TurretTruck",
		position,
		Vector3.new(12, CHASSIS_HEIGHT, 24),
		spec.Color,
		18,
		12
	)
	local seat = addDriverSeat(chassis, model, Vector3.new(0, CHASSIS_HEIGHT * 0.5 + 0.5, -6))
	local drum, barrel, gunnerSeat, yaw =
		addTurret(chassis, model, Vector3.new(0, CHASSIS_HEIGHT * 0.5 + 2, 6), 12, spec.Color)

	bindSeat(seat, model, "Driver")
	bindSeat(gunnerSeat, model, "Gunner")

	model:SetAttribute("Health", spec.Health)
	model:SetAttribute("MaxHealth", spec.Health)
	model:SetAttribute("VehicleKind", "TurretTruck")
	model:SetAttribute("MountedWeapon", spec.MountedWeapon)

	model.Parent = workspace
	active[model] = {
		kind = "TurretTruck",
		chassis = chassis,
		seat = seat,
		gunnerSeat = gunnerSeat,
		turretDrum = drum,
		barrel = barrel,
		turretYaw = yaw,
		maxSpeed = spec.MaxSpeed,
		torque = spec.Torque,
		turnSpeed = spec.TurnSpeed,
	}
	return model
end

--[[ The tank. Slow, enormously heavy, shrugs off rifle fire. ]]
function VehicleService.SpawnTank(position: Vector3): Model
	local spec = Config.Vehicles.Tank

	local model, chassis = buildChassis(
		"Tank",
		position,
		Vector3.new(16, 5, 26),
		spec.Color,
		18,
		15
	)
	local seat = addDriverSeat(chassis, model, Vector3.new(0, 3, -8))
	local drum, barrel, gunnerSeat, yaw =
		addTurret(chassis, model, Vector3.new(0, 3.5, 2), 20, spec.Color)

	-- Track skirts, purely so it reads as a tank rather than a big car.
	for _, side in { -1, 1 } do
		local skirt = Util.Part({
			Name = "TrackSkirt",
			Size = Vector3.new(2, 5, 26),
			CFrame = chassis.CFrame * CFrame.new(side * 8.5, -1.5, 0),
			Color = Color3.fromRGB(40, 42, 38),
			Material = Enum.Material.Metal,
			Anchored = false,
			Massless = true,
			CanCollide = false,
			Parent = model,
		})
		Util.Weld(chassis, skirt)
	end

	bindSeat(seat, model, "Driver")
	bindSeat(gunnerSeat, model, "Gunner")

	model:SetAttribute("Health", spec.Health)
	model:SetAttribute("MaxHealth", spec.Health)
	model:SetAttribute("VehicleKind", "Tank")
	model:SetAttribute("MountedWeapon", spec.MountedWeapon)
	model:SetAttribute("DamageResistance", spec.DamageResistance)

	model.Parent = workspace
	active[model] = {
		kind = "Tank",
		chassis = chassis,
		seat = seat,
		gunnerSeat = gunnerSeat,
		turretDrum = drum,
		barrel = barrel,
		turretYaw = yaw,
		maxSpeed = spec.MaxSpeed,
		torque = spec.Torque,
		turnSpeed = spec.TurnSpeed,
	}
	return model
end

--[[
	The plane. This one does not use wheels at all — a physics-accurate
	aeroplane is miserable to fly with a keyboard, so it flies on rails:
	constant forward speed, and the stick points the nose.
]]
function VehicleService.SpawnPlane(position: Vector3): Model
	local spec = Config.Vehicles.Plane

	local model = Instance.new("Model")
	model.Name = "Plane"

	local body = Util.Part({
		Name = "Chassis",
		Size = Vector3.new(6, 4, 26),
		CFrame = CFrame.new(position + Vector3.new(0, 12, 0)),
		Color = spec.Color,
		Material = Enum.Material.Metal,
		Anchored = false,
		CustomPhysicalProperties = PhysicalProperties.new(0.6, 0.3, 0.2, 1, 1),
		Parent = model,
	})
	model.PrimaryPart = body

	local wing = Util.Part({
		Name = "Wing",
		Size = Vector3.new(40, 1, 7),
		CFrame = body.CFrame * CFrame.new(0, 1, 1),
		Color = spec.Color,
		Material = Enum.Material.Metal,
		Anchored = false,
		Massless = true,
		Parent = model,
	})
	Util.Weld(body, wing)

	local tail = Util.Part({
		Name = "Tail",
		Size = Vector3.new(1, 7, 6),
		CFrame = body.CFrame * CFrame.new(0, 3, 11),
		Color = spec.Color,
		Material = Enum.Material.Metal,
		Anchored = false,
		Massless = true,
		Parent = model,
	})
	Util.Weld(body, tail)

	local seat = addDriverSeat(body, model, Vector3.new(0, 2.5, -4))
	Util.Attachment(body, Vector3.new(0, 0, -13), "Muzzle")

	-- The two forces that make it fly. Velocity pushes it along its own nose;
	-- orientation holds whatever attitude the pilot last asked for.
	local root = Util.Attachment(body, Vector3.zero, "FlightRoot")

	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = root
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.MaxForce = 900000
	velocity.VectorVelocity = Vector3.zero
	velocity.Enabled = false
	velocity.Parent = body

	local orientation = Instance.new("AlignOrientation")
	orientation.Attachment0 = root
	orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orientation.MaxTorque = 700000
	orientation.Responsiveness = 25
	orientation.Enabled = false
	orientation.Parent = body

	bindSeat(seat, model, "Driver")

	model:SetAttribute("Health", spec.Health)
	model:SetAttribute("MaxHealth", spec.Health)
	model:SetAttribute("VehicleKind", "Plane")
	model:SetAttribute("MountedWeapon", spec.MountedWeapon)

	model.Parent = workspace
	active[model] = {
		kind = "Plane",
		chassis = body,
		seat = seat,
		velocity = velocity,
		orientation = orientation,
		-- Attitude the pilot has steered to so far.
		heading = body.CFrame.Rotation,
		speed = spec.MinFlySpeed,
	}
	return model
end

--[[
	The rideable torpedo. You sit on it like a saddle, steer with WASD, and it
	goes off like a bomb the moment it touches anything.
]]
function VehicleService.SpawnTorpedo(position: Vector3): Model
	local spec = Config.Vehicles.Torpedo

	local model = Instance.new("Model")
	model.Name = "Torpedo"

	local body = Util.Part({
		Name = "Chassis",
		Size = Vector3.new(4, 4, 18),
		CFrame = CFrame.new(position + Vector3.new(0, 8, 0)),
		Shape = Enum.PartType.Cylinder,
		Color = spec.Color,
		Material = Enum.Material.Metal,
		Anchored = false,
		CustomPhysicalProperties = PhysicalProperties.new(0.4, 0.3, 0.2, 1, 1),
		Parent = model,
	})
	-- A cylinder points along its own X, but we want it pointing forwards,
	-- so the visible shell is rotated a quarter turn onto Z.
	body.CFrame = CFrame.new(position + Vector3.new(0, 8, 0)) * CFrame.Angles(0, math.rad(90), 0)
	model.PrimaryPart = body

	-- The saddle. This is the bit you actually sit on.
	-- It is a VehicleSeat rather than a plain Seat specifically so that WASD
	-- arrives as Throttle and Steer without the client having to send them.
	local saddle = Instance.new("VehicleSeat")
	saddle.Name = "DriverSeat"
	saddle.Size = Vector3.new(3, 1, 5)
	saddle.CFrame = body.CFrame * CFrame.new(0, 2.5, 0)
	saddle.Color = Color3.fromRGB(90, 60, 40)
	saddle.Anchored = false
	saddle.Massless = true
	saddle.MaxSpeed = 0
	saddle.Torque = 0
	saddle.TurnSpeed = 0
	saddle.Parent = model
	Util.Weld(body, saddle)

	local fins = Util.Part({
		Name = "Fins",
		Size = Vector3.new(7, 7, 2),
		CFrame = body.CFrame * CFrame.new(0, 0, 8),
		Color = Color3.fromRGB(60, 60, 64),
		Material = Enum.Material.Metal,
		Anchored = false,
		Massless = true,
		CanCollide = false,
		Parent = model,
	})
	Util.Weld(body, fins)

	local root = Util.Attachment(body, Vector3.zero, "FlightRoot")

	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = root
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.MaxForce = 400000
	velocity.VectorVelocity = Vector3.zero
	velocity.Enabled = false
	velocity.Parent = body

	local orientation = Instance.new("AlignOrientation")
	orientation.Attachment0 = root
	orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orientation.MaxTorque = 400000
	orientation.Responsiveness = 20
	orientation.Enabled = false
	orientation.Parent = body

	bindSeat(saddle, model, "Driver")

	model:SetAttribute("Health", spec.Health)
	model:SetAttribute("MaxHealth", spec.Health)
	model:SetAttribute("VehicleKind", "Torpedo")

	model.Parent = workspace
	active[model] = {
		kind = "Torpedo",
		chassis = body,
		seat = saddle,
		velocity = velocity,
		orientation = orientation,
		heading = body.CFrame.Rotation,
		armedAt = os.clock() + 1.0,
	}
	return model
end

--[[ Spawn whichever big toy a map pad asks for. ]]
function VehicleService.SpawnKind(kind: string, position: Vector3): Model?
	if kind == "TurretTruck" then
		return VehicleService.SpawnTurretTruck(position)
	elseif kind == "Tank" then
		return VehicleService.SpawnTank(position)
	elseif kind == "Plane" then
		return VehicleService.SpawnPlane(position)
	elseif kind == "Torpedo" then
		return VehicleService.SpawnTorpedo(position)
	end
	return nil
end

-- ================================================================= DRIVING ==

--[[ Point a wheeled vehicle's motors and steering at what the driver is holding. ]]
local function driveWheeled(model: Model, state: any)
	local seat = state.seat :: VehicleSeat
	local throttle = seat.Throttle
	local steer = seat.Steer

	-- No driver means no power, so an empty car does not creep away.
	if not seat.Occupant then
		throttle = 0
		steer = 0
	end

	-- Mud drags you down, which is the whole point of the mud.
	-- We look at what is actually under the wheels rather than trusting a
	-- flag, because nothing was ever setting that flag.
	local speedFactor = 1
	local chassis = state.chassis :: BasePart
	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	groundParams.FilterDescendantsInstances = { model }
	local ground = workspace:Raycast(chassis.Position, Vector3.new(0, -14, 0), groundParams)
	if ground and (ground.Instance.Name == "Mud" or ground.Material == Enum.Material.Mud) then
		speedFactor = Config.MudSpeedFactor
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("HingeConstraint") then
			if descendant.Name == "DriveMotor" then
				descendant.AngularVelocity = throttle * state.maxSpeed * speedFactor
				descendant.MotorMaxTorque = state.torque
			elseif descendant.Name == "SteerServo" then
				descendant.TargetAngle = -steer * state.turnSpeed
			end
		end
	end
end

--[[
	Fly a plane. Throttle changes speed, steering rolls and turns, and the
	nose pitches with the seat's own up/down input.
]]
local function drivePlane(model: Model, state: any, deltaTime: number)
	local spec = Config.Vehicles.Plane
	local seat = state.seat :: VehicleSeat
	local body = state.chassis :: BasePart

	if not seat.Occupant then
		state.velocity.Enabled = false
		state.orientation.Enabled = false
		return
	end

	state.velocity.Enabled = true
	state.orientation.Enabled = true

	-- Fallbacks here mean a half-edited Config still flies instead of erroring.
	local topSpeed = spec.FlySpeed or 180
	local stallSpeed = spec.MinFlySpeed or 60
	local rollRate = spec.RollRate or 2.2
	local pitchRate = spec.PitchRate or 1.4
	local yawRate = spec.YawRate or 0.8

	-- Throttle nudges the speed up and down between the stall and top speed.
	local target = state.speed + seat.Throttle * 90 * deltaTime
	state.speed = math.clamp(target, stallSpeed, topSpeed)

	-- Steering rolls the aircraft, and rolling is what turns it.
	local roll = -seat.Steer * rollRate * deltaTime
	local pitch = -seat.Throttle * pitchRate * deltaTime * 0.35
	local yaw = -seat.Steer * yawRate * deltaTime

	state.heading = state.heading * CFrame.Angles(pitch, yaw, roll)
	state.orientation.CFrame = state.heading

	state.velocity.VectorVelocity = state.heading.LookVector * state.speed

	-- If it belly-flops into the ground, that is a crash.
	if body.Position.Y < 6 then
		VehicleService.Damage(model, 9999, nil)
	end
end

--[[ Ride the torpedo. It only goes forward; you choose where forward is. ]]
local function driveTorpedo(model: Model, state: any, deltaTime: number)
	local spec = Config.Vehicles.Torpedo
	local seat = state.seat :: VehicleSeat

	if not seat.Occupant then
		state.velocity.Enabled = false
		state.orientation.Enabled = false
		return
	end

	state.velocity.Enabled = true
	state.orientation.Enabled = true

	-- A on the keyboard turns you left, W points the nose down so you can dive
	-- it into somebody. That is the whole control scheme.
	local steer = seat.Steer
	local pitch = seat.Throttle * 0.6

	local turnRate = spec.TurnRate or 1.6
	local runSpeed = spec.Speed or 150

	state.heading = state.heading
		* CFrame.Angles(pitch * turnRate * deltaTime, -steer * turnRate * deltaTime, 0)
	state.orientation.CFrame = state.heading
	state.velocity.VectorVelocity = state.heading.LookVector * runSpeed
end

--[[ Hurt a vehicle. At zero health it explodes and takes its riders with it. ]]
function VehicleService.Damage(model: Model, amount: number, _attacker: Player?)
	if not model or not model.Parent then
		return
	end
	local health = model:GetAttribute("Health")
	if typeof(health) ~= "number" then
		return
	end

	local resistance = model:GetAttribute("DamageResistance")
	if typeof(resistance) == "number" then
		amount *= (1 - resistance)
	end

	health -= amount
	model:SetAttribute("Health", health)

	if health <= 0 then
		VehicleService.Explode(model)
	end
end

--[[ Blow a vehicle up, throwing anybody nearby around. ]]
function VehicleService.Explode(model: Model)
	local state = active[model]
	if not state then
		if model and model.Parent then
			model:Destroy()
		end
		return
	end

	local chassis = state.chassis :: BasePart
	local position = chassis.Position
	local kind = model:GetAttribute("VehicleKind")

	local blastRadius = 30
	if kind == "Torpedo" then
		blastRadius = Config.Vehicles.Torpedo.BlastRadius or 45
	end

	local explosion = Instance.new("Explosion")
	explosion.Position = position
	explosion.BlastRadius = blastRadius
	explosion.BlastPressure = 250000
	explosion.DestroyJointRadiusPercent = 0
	explosion.Parent = workspace

	active[model] = nil
	model:Destroy()
end

--[[ Every vehicle in the world gets a turn, every frame. ]]
local function step(deltaTime: number)
	for model, state in active do
		if not model.Parent then
			active[model] = nil
			continue
		end

		if state.kind == "Plane" then
			drivePlane(model, state, deltaTime)
		elseif state.kind == "Torpedo" then
			driveTorpedo(model, state, deltaTime)
		else
			driveWheeled(model, state)
		end
	end
end

--[[ Look up a vehicle by any part of it — used when a bullet hits one. ]]
function VehicleService.FromPart(part: BasePart): Model?
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if active[model] then
			return model
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

--[[ The state table for a live vehicle, or nil if it is not one of ours. ]]
function VehicleService.GetState(model: Model): any
	return active[model]
end

--[[ Aim a turret at a point in the world, for whoever is in the gunner seat. ]]
function VehicleService.AimTurret(model: Model, worldTarget: Vector3)
	local state = active[model]
	if not state or not state.turretYaw then
		return
	end

	local chassis = state.chassis :: BasePart
	local drum = state.turretDrum :: BasePart

	-- Work out the target angle in the chassis's own frame, so the turret
	-- stays pointed at the target even while the truck is turning.
	local localTarget = chassis.CFrame:PointToObjectSpace(worldTarget)
	local angle = math.atan2(-localTarget.X, -localTarget.Z)
	state.turretYaw.TargetAngle = math.deg(angle)

	local _ = drum
end

--[[ Everything currently alive, so the round can clean up after itself. ]]
function VehicleService.ClearAll()
	for model in active do
		if model.Parent then
			model:Destroy()
		end
	end
	table.clear(active)
end

RunService.Heartbeat:Connect(step)

return VehicleService
