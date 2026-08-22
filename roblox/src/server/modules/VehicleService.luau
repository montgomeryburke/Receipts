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

-- Its own random stream, so picking a car body cannot shift map generation.
local bodyPicker = Random.new()

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
	One wheel.

	These are welded on and purely for looks. An earlier version drove them
	with hinge motors, which is the "proper" way and also the way that gives
	you a vehicle that silently does nothing if a single constraint axis is
	off by ninety degrees. Driving is now done by setting the chassis velocity
	directly — see driveWheeled — which is arcade-y, completely predictable,
	and cannot fail quietly.
]]
local function addWheel(chassis: BasePart, offset: Vector3, model: Model)
	local wheel = Util.Part({
		Name = "Wheel",
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
	Util.Weld(chassis, wheel)
	return wheel
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

	-- The two constraints that actually move the car.
	--
	-- This matters more than it looks: the moment a player sits in a
	-- VehicleSeat, Roblox hands network ownership of the whole vehicle to
	-- that player's computer, and physics is simulated there. Anything the
	-- server writes straight onto the part's velocity gets overwritten by the
	-- owning client on the very next frame — the car twitches and goes
	-- nowhere. Constraint *properties*, on the other hand, replicate, and the
	-- owning client simulates them. So we steer the constraints, not the part.
	local driveRoot = Util.Attachment(chassis, Vector3.zero, "DriveRoot")

	local drive = Instance.new("LinearVelocity")
	drive.Name = "DriveVelocity"
	drive.Attachment0 = driveRoot
	-- Line mode constrains one axis only, leaving gravity to do its job, so
	-- ramps and jumps still behave.
	drive.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	-- WORLD space, with the direction recomputed every frame from the
	-- chassis, rather than a fixed direction in the attachment's frame.
	--
	-- Attachment-relative was reported driving the truck straight up: forward
	-- launched it into the sky, reverse slammed it into the ground. Whatever
	-- the attachment's orientation was actually doing, this removes the
	-- question — the direction is computed, flattened, and inspectable, so
	-- the drive axis is horizontal by construction and a car cannot be
	-- driven vertically at all.
	drive.RelativeTo = Enum.ActuatorRelativeTo.World
	drive.LineDirection = Vector3.new(0, 0, -1)
	drive.LineVelocity = 0
	-- THE ONE THAT ACTUALLY MATTERS.
	--
	-- LinearVelocity has two separate force limits: MaxForce, used when
	-- ForceLimitMode is Magnitude, and MaxAxesForce, used when it is PerAxis.
	-- Set the wrong one of the pair and the constraint is left with no force
	-- to push with, so the vehicle sits there doing nothing — no error, no
	-- warning, just a car that will not move.
	--
	-- Turning the limits off entirely sidesteps the whole trap: the
	-- constraint gets whatever force it needs to hit the requested speed.
	drive.ForceLimitsEnabled = false
	drive.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	drive.MaxForce = math.huge
	drive.MaxAxesForce = Vector3.new(math.huge, math.huge, math.huge)
	drive.Enabled = false
	drive.Parent = chassis

	local turn = Instance.new("AngularVelocity")
	turn.Name = "TurnVelocity"
	turn.Attachment0 = driveRoot
	turn.RelativeTo = Enum.ActuatorRelativeTo.World
	turn.AngularVelocity = Vector3.zero
	turn.MaxTorque = 900000
	turn.Enabled = false
	turn.Parent = chassis

	local halfBase = wheelbase * 0.5
	local halfTrack = track * 0.5
	local axleDrop = -bodySize.Y * 0.5

	addWheel(chassis, Vector3.new(-halfTrack, axleDrop, -halfBase), model)
	addWheel(chassis, Vector3.new(halfTrack, axleDrop, -halfBase), model)
	addWheel(chassis, Vector3.new(-halfTrack, axleDrop, halfBase), model)
	addWheel(chassis, Vector3.new(halfTrack, axleDrop, halfBase), model)

	return model, chassis
end

--[[
	Put a "press E" prompt on a seat.

	Without this you cannot get into anything. The seat sits on top of the
	chassis at about 8.5 studs, and a Roblox character jumps roughly 7.2 —
	so there is no way to climb aboard by walking into it. Walk up, press E.
]]
local function addSitPrompt(seat: Seat | VehicleSeat, actionText: string, vehicleName: string)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SitPrompt"
	prompt.ActionText = actionText
	prompt.ObjectText = vehicleName
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 16
	-- The car body is between you and the seat, so line of sight would stop
	-- the prompt appearing exactly where you need it.
	prompt.RequiresLineOfSight = false
	prompt.Parent = seat

	prompt.Triggered:Connect(function(player)
		local character = player.Character
		if not character then
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			return
		end
		-- Already sitting somewhere? Get out rather than teleporting across.
		if humanoid.SeatPart then
			return
		end
		-- Seat and VehicleSeat both have Sit, but Roblox makes them siblings
		-- rather than parent and child, so the call has to be narrowed first.
		if seat:IsA("VehicleSeat") then
			seat:Sit(humanoid)
		else
			seat:Sit(humanoid)
		end
	end)

	return prompt
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
	addSitPrompt(seat, "Drive", model.Name)
	return seat
end

--[[
	A floating name over a vehicle, readable from right across the map.

	The big vehicles sit on pads a couple of hundred studs apart, which is a
	very long walk if you cannot see where they are.
]]
local function addVehicleLabel(chassis: BasePart, text: string, colour: Color3)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "VehicleLabel"
	billboard.Size = UDim2.fromScale(14, 3)
	billboard.StudsOffset = Vector3.new(0, 9, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 1200
	billboard.Parent = chassis

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = colour
	label.TextStrokeTransparency = 0.25
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = billboard
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
	addSitPrompt(seat, if name == "GunnerSeat" then "Man the gun" else "Sit", model.Name)
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

	-- Raised well clear of the gunner and pushed forward off the drum. The
	-- previous barrel sat at head height and long enough to clip the rider,
	-- which stopped them turning.
	local barrel = Util.Part({
		Name = "Barrel",
		Size = Vector3.new(1.6, 1.6, barrelLength),
		CFrame = drum.CFrame * CFrame.new(0, 3.6, -barrelLength * 0.5 - 3),
		Color = Color3.fromRGB(40, 40, 44),
		Material = Enum.Material.Metal,
		Anchored = false,
		Massless = true,
		Parent = model,
	})
	Util.Weld(drum, barrel)

	-- Where bullets actually come out.
	Util.Attachment(barrel, Vector3.new(0, 0, -barrelLength * 0.5), "Muzzle")

	local gunnerSeat = addPassengerSeat(drum, model, Vector3.new(0, 1.5, 3.5), "GunnerSeat")

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

--[[
	A car. Tier decides how fast it is; the body style is a coin flip between
	a truck and a Lamborghini, so what pulls up beside you varies.
]]
function VehicleService.SpawnCar(tierIndex: number, position: Vector3, owner: Player?): Model
	local tier = Config.CarTiers[math.clamp(tierIndex, 1, #Config.CarTiers)]
	local body = Config.CarBodies[bodyPicker:NextInteger(1, #Config.CarBodies)]

	local model, chassis = buildChassis(
		`{body.Name}_{tier.Name}`,
		position,
		body.Size,
		-- The tier colour tints the body so you can still read how fast
		-- somebody's car is at a glance.
		body.Color:Lerp(tier.Color, 0.45),
		14,
		10
	)
	local seat = addDriverSeat(chassis, model, Vector3.new(0, body.Size.Y * 0.5 + 0.5, 1))
	bindSeat(seat, model, "Driver")
	addVehicleLabel(chassis, `{body.Name} · {tier.Name}`, Color3.fromRGB(230, 240, 250))

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
		maxSpeed = tier.MaxSpeed * body.SpeedBias,
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
		addTurret(chassis, model, Vector3.new(0, CHASSIS_HEIGHT * 0.5 + 2, 6), 8, spec.Color)

	bindSeat(seat, model, "Driver")
	bindSeat(gunnerSeat, model, "Gunner")

	addVehicleLabel(chassis, "Turret Truck · 2 seats", Color3.fromRGB(180, 230, 140))

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
		addTurret(chassis, model, Vector3.new(0, 3.5, 2), 14, spec.Color)

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

	addVehicleLabel(chassis, "Tank", Color3.fromRGB(150, 220, 150))

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
	-- Limits off, for the same reason as the cars.
	velocity.ForceLimitsEnabled = false
	velocity.MaxForce = math.huge
	velocity.MaxAxesForce = Vector3.new(math.huge, math.huge, math.huge)
	velocity.VectorVelocity = Vector3.zero
	velocity.Enabled = false
	velocity.Parent = body

	local orientation = Instance.new("AlignOrientation")
	orientation.Attachment0 = root
	orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	-- Rigid alignment ignores the torque and angular-velocity limits entirely,
	-- which is what we want: MaxAngularVelocity was never being set, and a
	-- zero there means the aircraft cannot turn no matter the torque.
	orientation.RigidityEnabled = true
	orientation.MaxTorque = math.huge
	orientation.MaxAngularVelocity = math.huge
	orientation.Responsiveness = 25
	orientation.Enabled = false
	orientation.Parent = body

	bindSeat(seat, model, "Driver")

	addVehicleLabel(body, "Plane", Color3.fromRGB(160, 210, 255))

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
	addSitPrompt(saddle, "Ride it", "Torpedo")

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
	velocity.ForceLimitsEnabled = false
	velocity.MaxForce = math.huge
	velocity.MaxAxesForce = Vector3.new(math.huge, math.huge, math.huge)
	velocity.VectorVelocity = Vector3.zero
	velocity.Enabled = false
	velocity.Parent = body

	local orientation = Instance.new("AlignOrientation")
	orientation.Attachment0 = root
	orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orientation.RigidityEnabled = true
	orientation.MaxTorque = math.huge
	orientation.MaxAngularVelocity = math.huge
	orientation.Responsiveness = 20
	orientation.Enabled = false
	orientation.Parent = body

	bindSeat(saddle, model, "Driver")

	addVehicleLabel(body, "Rideable Torpedo", Color3.fromRGB(255, 140, 140))

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

--[[
	Drive a wheeled vehicle.

	We set constraint targets, never the part's velocity directly — see the
	note in buildChassis for why that distinction decides whether the car
	moves at all.

	Speed is eased toward the target rather than snapped to it. That is what
	gives the thing mass: it winds up, it carries momentum into a corner, and
	it does not turn on a coin at walking pace.
]]
local function driveWheeled(model: Model, state: any, deltaTime: number)
	local seat = state.seat :: VehicleSeat
	local chassis = state.chassis :: BasePart

	local drive = chassis:FindFirstChild("DriveVelocity") :: LinearVelocity?
	local turn = chassis:FindFirstChild("TurnVelocity") :: AngularVelocity?
	if not drive or not turn then
		return
	end

	state.currentSpeed = state.currentSpeed or 0

	local throttle = if seat.Occupant then seat.Throttle else 0
	local steer = if seat.Occupant then seat.Steer else 0

	-- On a phone there is no W key, so the on-screen pedals send their value
	-- here and it overrides the seat's own throttle when pressed.
	local pedal = model:GetAttribute("Pedal")
	if seat.Occupant and typeof(pedal) == "number" and math.abs(pedal) > 0.01 then
		throttle = math.clamp(pedal, -1, 1)
	end

	-- Mud drags you down. We look at what is actually under the wheels
	-- rather than trusting a flag.
	local speedFactor = 1
	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	groundParams.FilterDescendantsInstances = { model }
	local ground = workspace:Raycast(chassis.Position, Vector3.new(0, -14, 0), groundParams)
	if ground and (ground.Instance.Name == "Mud" or ground.Material == Enum.Material.Mud) then
		speedFactor = Config.MudSpeedFactor
	end

	-- Boost chevrons. Driving over one flings you forward, which is what
	-- makes the jump beyond it worth hitting.
	local boosted = false
	if ground and ground.Instance:GetAttribute("Boost") then
		boosted = true
	end

	-- Turbo, held by the driver.
	if model:GetAttribute("Turbo") == true then
		speedFactor *= Config.Turbo.Multiplier
	end

	local topSpeed = state.maxSpeed * speedFactor
	local target = throttle * topSpeed
	local current = state.currentSpeed

	-- Winding up, braking and coasting are three different rates.
	local rate
	if throttle == 0 then
		rate = Config.Driving.Coast
	elseif (target > current and current < 0) or (target < current and current > 0) then
		rate = Config.Driving.BrakeDeceleration
	else
		rate = Config.Driving.Acceleration
	end

	local difference = target - current
	local step = rate * deltaTime
	current = if math.abs(difference) <= step then target else current + math.sign(difference) * step

	-- A boost pad overrides the gradual wind-up entirely: you leave it fast.
	if boosted and throttle >= 0 then
		current = math.max(current, Config.Boost.Speed)
	end

	state.currentSpeed = current

	-- An empty car rolls to a stop and then stops asking for anything.
	if not seat.Occupant and math.abs(current) < 0.5 then
		state.currentSpeed = 0
		drive.Enabled = false
		turn.Enabled = false
		return
	end

	-- The drive axis: the chassis's forward, flattened onto the horizontal.
	-- Flattening is what guarantees the car drives along the ground instead
	-- of nosing into the sky when it tips on a ramp.
	local look = chassis.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, -1)

	drive.Enabled = true
	turn.Enabled = true
	drive.LineDirection = flat
	drive.LineVelocity = current

	-- Steering bites less the slower you are going, and reverses when you
	-- are reversing, the way a real car does.
	local speedFraction = math.abs(current) / math.max(topSpeed, 1)
	local grip = math.clamp(speedFraction / Config.Driving.SteerGripSpeed, 0, 1)
	local direction = if current < 0 then -1 else 1
	turn.AngularVelocity =
		Vector3.new(0, -steer * math.rad(state.turnSpeed) * grip * direction, 0)
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

--[[
	Turn a player's turbo on or off.

	Works on whatever they are currently driving; on foot it just makes them
	run faster, so the same key always means "go faster".
]]
function VehicleService.SetTurbo(player: Player, on: boolean)
	local state = PlayerState.Get(player)

	if state.vehicle and state.vehicle.Parent and state.seatRole == "Driver" then
		state.vehicle:SetAttribute("Turbo", on)
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = if on then Config.Turbo.SprintWalkSpeed else Config.Turbo.WalkSpeed
	end
end

--[[ The on-screen gas and brake pedals, for players without a keyboard. ]]
function VehicleService.SetPedal(player: Player, value: number)
	local state = PlayerState.Get(player)
	if state.vehicle and state.vehicle.Parent and state.seatRole == "Driver" then
		state.vehicle:SetAttribute("Pedal", math.clamp(value, -1, 1))
	end
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
			driveWheeled(model, state, deltaTime)
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
