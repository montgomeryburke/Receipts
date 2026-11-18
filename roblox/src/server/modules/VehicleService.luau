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

-- Shared between every vehicle, every frame: see driveWheeled.
--
-- The probe is paced by DISTANCE, not by time. A fixed 20 Hz looks like a
-- safe saving until you work out how far a car travels between samples: at
-- two hundred studs a second that is ten studs, and a boost chevron is nine
-- studs long, so the pads on the run-up to a ramp get stepped straight over
-- and the jump beyond never works.
--
-- The threshold is not the gap: a sample fires once the car has moved this
-- far, so the real gap is this plus one frame of travel, which at top speed
-- under turbo is another two studs. Four studs keeps the actual spacing
-- around six, with genuine margin against a nine-stud pad rather than the
-- eight-point-something that six studs produced.
local GROUND_SAMPLE_STUDS = 4
-- And a floor on the rate, so a crawling vehicle still notices mud.
local GROUND_SAMPLE_INTERVAL = 1 / 20
local GROUND_PROBE = Vector3.new(0, -14, 0)
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
local Remotes = require(Shared:WaitForChild("Remotes"))
local Sound = require(Shared:WaitForChild("Sound"))
local Util = require(Shared:WaitForChild("Util"))

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))

local Signal = require(Shared:WaitForChild("Signal"))

local VehicleService = {}

--[[
	A vehicle just went up: (position, radius, damage, lastDriver).

	DamageService listens and applies the blast. It cannot be called from
	here, because it requires this module.
]]
VehicleService.Wrecked = Signal.new()

--[[
	A trick was landed: (player, name, points, airtime).

	Announced so the HUD and the match feed can shout about it without this
	module needing to know either of them exists.
]]
VehicleService.TrickLanded = Signal.new()

local WHEEL_DIAMETER = 7
local WHEEL_WIDTH = 4
local CHASSIS_HEIGHT = 4

-- Wheels want grip; the chassis wants weight so it does not tip over.
local WHEEL_PHYSICS = PhysicalProperties.new(1.2, 2.0, 0.1, 100, 1)
-- Low friction: the chassis is what touches the ground now that the wheels
-- are decoration, and a high-grip box would drag against the drive
-- constraint instead of sliding along under it.
local CHASSIS_PHYSICS = PhysicalProperties.new(4.5, 0.08, 0.1, 1, 1)

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

	Wheels are anchored, non-colliding decoration that we rotate by hand. That
	sounds backwards, but welded colliding wheels cannot roll — they scrape,
	and their friction fights the drive constraint that is trying to move the
	car. Anchoring them takes them out of the physics entirely and lets us
	spin them at exactly road speed, so they look right and cost nothing.

	The chassis is what actually rests on the ground.
]]
--[[
	A wheel that stays on the car.

	The old ones were ANCHORED and had their CFrame written from the chassis
	once per Heartbeat. That is why they looked like they were falling off:
	the chassis is moved by physics, continuously and interpolated on the
	client, while an anchored part teleports sixty times a second from a
	position that is already stale. At any real speed the wheels visibly
	trailed the car they belonged to.

	These are unanchored, massless, non-colliding, and held on by a
	HingeConstraint. Roblox's own solver keeps them attached and the client
	interpolates them, so they cannot lag or detach -- and because the hinge
	is a MOTOR, the spin comes from setting one angular velocity rather than
	rewriting a CFrame every frame.

	Massless and non-colliding matters: a wheel with mass and collision
	fights the drive constraint, which is what made the cars feel like they
	were dragging an anchor.
]]
local function addWheel(model: Model, chassis: BasePart, offset: Vector3)
	local wheel = Util.Part({
		Name = "Wheel",
		Size = Vector3.new(WHEEL_WIDTH, WHEEL_DIAMETER, WHEEL_DIAMETER),
		-- A cylinder's flat faces point along its own X, which is already the
		-- car's left-right axis, so it is already oriented to roll.
		CFrame = chassis.CFrame * CFrame.new(offset),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(26, 26, 30),
		Material = Enum.Material.Rubber,
		Anchored = false,
		CanCollide = false,
		CanQuery = false,
		Massless = true,
		Parent = model,
	})

	-- A pale hub, welded on, so the rotation is actually visible from outside.
	local hub = Util.Part({
		Name = "Hub",
		Size = Vector3.new(WHEEL_WIDTH + 0.5, WHEEL_DIAMETER * 0.5, WHEEL_DIAMETER * 0.5),
		CFrame = wheel.CFrame,
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(198, 198, 208),
		Material = Enum.Material.Metal,
		Anchored = false,
		CanCollide = false,
		CanQuery = false,
		Massless = true,
		Parent = model,
	})
	Util.Weld(wheel, hub)

	-- The axle. Both attachments keep their part's own X as the hinge axis,
	-- which for the chassis is left-right and for the cylinder is the way it
	-- rolls -- so no extra orientation is needed.
	local hubAttachment = Instance.new("Attachment")
	hubAttachment.Name = "AxleHub"
	hubAttachment.Position = offset
	hubAttachment.Parent = chassis

	local wheelAttachment = Instance.new("Attachment")
	wheelAttachment.Name = "AxleWheel"
	wheelAttachment.Parent = wheel

	local axle = Instance.new("HingeConstraint")
	axle.Name = "Axle"
	axle.Attachment0 = hubAttachment
	axle.Attachment1 = wheelAttachment
	axle.ActuatorType = Enum.ActuatorType.Motor
	axle.AngularVelocity = 0
	-- Enough torque to hold the spin against nothing in particular; the
	-- wheels do not drive the car, they only have to look right.
	axle.MotorMaxAcceleration = math.huge
	axle.MotorMaxTorque = 120000
	axle.LimitsEnabled = false
	axle.Parent = chassis

	return wheel, hub, axle
end

local function buildChassis(
	name: string,
	position: Vector3,
	bodySize: Vector3,
	color: Color3,
	wheelbase: number,
	track: number
): (Model, BasePart, { { part: Part, hub: Part, axle: HingeConstraint } })
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

	-- An engine note, pitched by road speed. A silent vehicle feels like a
	-- prop being slid along the floor.
	local engine = Sound.Attach("EngineLoop", chassis)
	if engine then
		engine.Name = "Engine"
	end

	local wheels = {}
	for _, corner in {
		Vector3.new(-halfTrack, axleDrop, -halfBase),
		Vector3.new(halfTrack, axleDrop, -halfBase),
		Vector3.new(-halfTrack, axleDrop, halfBase),
		Vector3.new(halfTrack, axleDrop, halfBase),
	} do
		local wheel, hub, axle = addWheel(model, chassis, corner)
		table.insert(wheels, { part = wheel, hub = hub, axle = axle })
	end

	return model, chassis, wheels
end

--[[
	Put a "press E" prompt on a seat.

	Without this you cannot get into anything. The seat sits on top of the
	chassis at about 8.5 studs, and a Roblox character jumps roughly 7.2 —
	so there is no way to climb aboard by walking into it. Walk up, press E.
]]
--[[
	Bodywork: the bits that make a box look like a car.

	The chassis is one rectangular block, which is fine as a collision hull
	and reads as a brick. Everything here is welded, massless and
	non-colliding, so it changes how the thing looks and nothing about how it
	drives: a cabin set back from the nose, a bonnet, a windscreen raked over
	it, side windows, bumpers front and back, arches over each wheel, and
	lights at both ends.

	Massless matters. Bolting a dozen parts with mass onto a tuned chassis
	changes its centre of gravity and its handling, and then the car that
	drove well before the bodywork went on drives differently after.
]]
local function addBodywork(model: Model, chassis: BasePart, color: Color3, lowSlung: boolean)
	local size = chassis.Size
	local halfLength = size.Z * 0.5
	local halfWidth = size.X * 0.5
	local roofHeight = if lowSlung then size.Y * 0.55 else size.Y * 0.85

	local function panel(props: { [string]: any }): BasePart
		props.Anchored = false
		props.Massless = true
		props.CanCollide = false
		props.CanQuery = false
		props.Parent = model
		local part = Util.Part(props)
		Util.Weld(chassis, part)
		return part
	end

	local darker = color:Lerp(Color3.new(0, 0, 0), 0.45)
	local glass = Color3.fromRGB(150, 190, 215)

	-- The cabin, set back from the nose so there is a bonnet in front of it.
	panel({
		Name = "Cabin",
		Size = Vector3.new(size.X * 0.86, roofHeight, size.Z * 0.46),
		CFrame = chassis.CFrame * CFrame.new(0, size.Y * 0.5 + roofHeight * 0.5, halfLength * 0.18),
		Color = color,
		Material = Enum.Material.Metal,
	})

	-- The windscreen, raked back over the bonnet.
	panel({
		Name = "Windscreen",
		Size = Vector3.new(size.X * 0.8, roofHeight * 0.92, 0.4),
		CFrame = chassis.CFrame
			* CFrame.new(0, size.Y * 0.5 + roofHeight * 0.5, halfLength * 0.18 - size.Z * 0.24)
			* CFrame.Angles(math.rad(-22), 0, 0),
		Color = glass,
		Material = Enum.Material.Glass,
		Transparency = 0.35,
		Reflectance = 0.22,
	})

	-- Side glass, and a rear window.
	for _, side in { -1, 1 } do
		panel({
			Name = "SideWindow",
			Size = Vector3.new(0.3, roofHeight * 0.6, size.Z * 0.4),
			CFrame = chassis.CFrame
				* CFrame.new(side * halfWidth * 0.87, size.Y * 0.5 + roofHeight * 0.58, halfLength * 0.18),
			Color = glass,
			Material = Enum.Material.Glass,
			Transparency = 0.42,
			Reflectance = 0.18,
		})
	end
	panel({
		Name = "RearWindow",
		Size = Vector3.new(size.X * 0.78, roofHeight * 0.8, 0.4),
		CFrame = chassis.CFrame
			* CFrame.new(0, size.Y * 0.5 + roofHeight * 0.5, halfLength * 0.18 + size.Z * 0.23)
			* CFrame.Angles(math.rad(16), 0, 0),
		Color = glass,
		Material = Enum.Material.Glass,
		Transparency = 0.38,
	})

	-- Bonnet and boot, slightly proud of the chassis so there are edges.
	panel({
		Name = "Bonnet",
		Size = Vector3.new(size.X * 0.94, 0.6, size.Z * 0.3),
		CFrame = chassis.CFrame * CFrame.new(0, size.Y * 0.5 + 0.2, -halfLength * 0.6),
		Color = color,
		Material = Enum.Material.Metal,
	})

	-- Bumpers.
	for _, endZ in { -1, 1 } do
		panel({
			Name = "Bumper",
			Size = Vector3.new(size.X * 1.02, size.Y * 0.3, 1.6),
			CFrame = chassis.CFrame * CFrame.new(0, -size.Y * 0.28, endZ * (halfLength + 0.6)),
			Color = darker,
			Material = Enum.Material.Metal,
		})
	end

	-- Arches over each wheel, which is most of what stops the sides reading
	-- as a flat slab.
	for _, side in { -1, 1 } do
		for _, endZ in { -1, 1 } do
			panel({
				Name = "Arch",
				Size = Vector3.new(1.1, size.Y * 0.5, WHEEL_DIAMETER * 1.25),
				CFrame = chassis.CFrame
					* CFrame.new(side * (halfWidth + 0.4), -size.Y * 0.1, endZ * halfLength * 0.56),
				Color = darker,
				Material = Enum.Material.Metal,
			})
		end
	end

	-- Headlights and tail lights, with a real beam off the front.
	for _, side in { -1, 1 } do
		local lamp = panel({
			Name = "Headlight",
			Size = Vector3.new(size.X * 0.22, 1.3, 0.5),
			CFrame = chassis.CFrame
				* CFrame.new(side * halfWidth * 0.6, size.Y * 0.1, -(halfLength + 0.3)),
			Color = Color3.fromRGB(255, 248, 220),
			Material = Enum.Material.Neon,
		})
		local beam = Instance.new("SpotLight")
		beam.Color = Color3.fromRGB(255, 246, 214)
		beam.Brightness = 2.2
		beam.Range = 70
		beam.Angle = 62
		beam.Face = Enum.NormalId.Front
		beam.Shadows = false
		beam.Parent = lamp

		panel({
			Name = "TailLight",
			Size = Vector3.new(size.X * 0.2, 1.1, 0.5),
			CFrame = chassis.CFrame
				* CFrame.new(side * halfWidth * 0.62, size.Y * 0.1, halfLength + 0.3),
			Color = Color3.fromRGB(210, 40, 36),
			Material = Enum.Material.Neon,
		})
	end
end

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
	local lastOccupant: Player? = nil
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = seat.Occupant

		if occupant then
			local character = occupant.Parent
			local player = if character then Players:GetPlayerFromCharacter(character) else nil
			if player then
				lastOccupant = player
				local state = PlayerState.Get(player)
				state.vehicle = model
				state.seatRole = role
				PlayerState.Changed.Fire(player)

				local vehicleState = active[model]
				if vehicleState and role == "Driver" then
					vehicleState.lastDriver = player
				end
			end
			return
		end

		if role == "Driver" and model.Parent then
			model:SetAttribute("Turbo", false)
		end

		local departed = lastOccupant
		lastOccupant = nil
		if departed and departed.Parent then
			local state = PlayerState.Get(departed)
			if state.vehicle == model and state.seatRole == role then
				state.vehicle = nil
				state.seatRole = nil
				PlayerState.Changed.Fire(departed)
			end
		end
	end)
end

-- ================================================================ BUILDERS ==

--[[
	A car. Tier decides how fast it is; the body style is a coin flip between
	a truck and a Lamborghini, so what pulls up beside you varies.
]]
function VehicleService.SpawnCar(
	tierIndex: number,
	position: Vector3,
	owner: Player?,
	bodyName: string?
): Model
	local tier = Config.CarTiers[math.clamp(tierIndex, 1, #Config.CarTiers)]

	--[[
		Which body turns up.

		Normally a coin flip, so what pulls up beside you varies. Named
		explicitly for the mountain, where the whole point is that the thing
		waiting at the trailhead can actually climb it -- a Lamborghini at
		the bottom of a mountain trail is a joke, not a vehicle.
	]]
	local body = Config.CarBodies[bodyPicker:NextInteger(1, #Config.CarBodies)]
	if bodyName then
		for _, candidate in Config.CarBodies do
			if candidate.Name == bodyName then
				body = candidate
				break
			end
		end
	end

	local model, chassis, wheels = buildChassis(
		`{body.Name}_{tier.Name}`,
		position,
		body.Size,
		-- The tier colour tints the body so you can still read how fast
		-- somebody's car is at a glance.
		body.Color:Lerp(tier.Color, 0.45),
		14,
		10
	)
	-- Make it look like a car rather than a painted box.
	addBodywork(model, chassis, body.Color:Lerp(tier.Color, 0.45), body.Name == "Lamborghini")

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
		wheels = wheels,
		kind = "Car",
		chassis = chassis,
		seat = seat,
		maxSpeed = tier.MaxSpeed * body.SpeedBias,
		torque = tier.Torque,
		turnSpeed = tier.TurnSpeed,
		offRoad = body.OffRoad == true,
		climbAssist = body.ClimbAssist or 0,
	}
	return model
end

--[[ The turret truck: one player drives, another works the 50 cal on the back. ]]
function VehicleService.SpawnTurretTruck(position: Vector3): Model
	local spec = Config.Vehicles.TurretTruck

	local model, chassis, wheels = buildChassis(
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
		wheels = wheels,
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

	local model, chassis, wheels = buildChassis(
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
		wheels = wheels,
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
		Transparency = 1,
		Anchored = false,
		CustomPhysicalProperties = PhysicalProperties.new(0.4, 0.3, 0.2, 1, 1),
		Parent = model,
	})
	model.PrimaryPart = body

	-- Visual cylindrical torpedo hull (Size.X = length 18, Y/Z = diameter 4) rotated onto Z.
	local shell = Util.Part({
		Name = "TorpedoShell",
		Size = Vector3.new(18, 4, 4),
		CFrame = body.CFrame * CFrame.Angles(0, math.rad(90), 0),
		Shape = Enum.PartType.Cylinder,
		Color = spec.Color,
		Material = Enum.Material.Metal,
		Anchored = false,
		CanCollide = false,
		Massless = true,
		Parent = model,
	})
	Util.Weld(body, shell)

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
		-- Armed and timed from the moment someone actually climbs aboard.
		armedAt = nil,
		expiresAt = nil,
	}
	return model
end

--[[ Spawn whichever big toy a map pad asks for. ]]
--[[
	An inner tube.

	The one piece of kit that works on both halves of the resort: ride it
	down the ski run and it carries straight on into the lazy river at the
	bottom, because it is pushed by whatever it is sitting in or on -- the
	river's current, or gravity down a snow slope -- rather than by an engine
	of its own.

	It is a seat, so your guns keep working. That is the rule for every sport
	here: you are always armed.
]]
function VehicleService.SpawnTube(position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "Tube"

	local hub = Util.Part({
		Name = "Chassis",
		Size = Vector3.new(3, 11, 11),
		CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90)),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(250, 150, 40),
		Material = Enum.Material.Rubber,
		Anchored = false,
		CustomPhysicalProperties = PhysicalProperties.new(0.25, 0.08, 0.5, 1, 1),
		Parent = model,
	})
	model.PrimaryPart = hub

	-- The hole in the middle, which is what makes it read as a tube.
	Util.Part({
		Name = "TubeHole",
		Size = Vector3.new(3.4, 5.4, 5.4),
		CFrame = hub.CFrame,
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(40, 40, 46),
		Transparency = 0.75,
		CanCollide = false,
		Anchored = false,
		Massless = true,
		Parent = model,
	})
	Util.Weld(hub, model:FindFirstChild("TubeHole") :: BasePart)

	local seat = Instance.new("VehicleSeat")
	seat.Name = "DriverSeat"
	seat.Size = Vector3.new(4, 1, 4)
	seat.CFrame = CFrame.new(position + Vector3.new(0, 1.4, 0))
	seat.Color = Color3.fromRGB(240, 130, 30)
	seat.Transparency = 1
	seat.Anchored = false
	seat.Massless = true
	-- No engine of its own: the current and the slope do the work.
	seat.MaxSpeed = 0
	seat.Torque = 0
	seat.TurnSpeed = 0
	seat.Parent = model
	Util.Weld(hub, seat)

	-- Steering only. A LinearVelocity in plane mode would fight gravity, so
	-- the tube is pushed by an impulse each frame instead and this just
	-- points it.
	local turn = Instance.new("AngularVelocity")
	turn.Name = "TurnVelocity"
	turn.Attachment0 = Util.Attachment(hub, Vector3.new())
	turn.RelativeTo = Enum.ActuatorRelativeTo.World
	turn.MaxTorque = 90000
	turn.AngularVelocity = Vector3.new()
	turn.Enabled = true
	turn.Parent = hub

	addSitPrompt(seat, "Ride the tube", "Tube")
	bindSeat(seat, model, "Rider")
	addVehicleLabel(hub, "Tube", Color3.fromRGB(255, 190, 120))

	model:SetAttribute("Health", 40)
	model:SetAttribute("MaxHealth", 40)
	model:SetAttribute("VehicleKind", "Tube")
	model.Parent = workspace

	active[model] = {
		kind = "Tube",
		chassis = hub,
		seat = seat,
		turn = turn,
	}
	return model
end

--[[
	A hang glider.

	Launched off the summit, it gives you the one thing no other vehicle on
	the map does: a slow, quiet look down at everybody. It trades height for
	speed like a real wing -- pull the nose up and you climb briefly and then
	stall, push it down and you go fast and lose altitude.

	Spacebar bails out, and the existing parachute catches you, which is what
	makes being shot down survivable rather than just fatal.
]]
function VehicleService.SpawnGlider(position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "Glider"

	local frame = Util.Part({
		Name = "Chassis",
		Size = Vector3.new(4, 2, 12),
		CFrame = CFrame.new(position),
		Color = Color3.fromRGB(70, 74, 82),
		Material = Enum.Material.Metal,
		Anchored = false,
		CustomPhysicalProperties = PhysicalProperties.new(0.2, 0.3, 0.4, 1, 1),
		Parent = model,
	})
	model.PrimaryPart = frame

	-- The wing: a wide shallow delta, in two halves so it reads as swept.
	for _, side in { -1, 1 } do
		local panel = Util.Part({
			Name = "Wing",
			Size = Vector3.new(26, 0.6, 13),
			CFrame = CFrame.new(position + Vector3.new(side * 13, 3.4, 0))
				* CFrame.Angles(0, 0, math.rad(side * -9)),
			Color = if side < 0 then Color3.fromRGB(235, 80, 70) else Color3.fromRGB(70, 130, 235),
			Material = Enum.Material.Fabric,
			Anchored = false,
			Massless = true,
			Parent = model,
		})
		Util.Weld(frame, panel)
	end

	local seat = Instance.new("VehicleSeat")
	seat.Name = "DriverSeat"
	seat.Size = Vector3.new(3, 1, 4)
	seat.CFrame = CFrame.new(position + Vector3.new(0, 1, 0))
	seat.Color = Color3.fromRGB(60, 62, 70)
	seat.Anchored = false
	seat.Massless = true
	seat.MaxSpeed = 0
	seat.Torque = 0
	seat.TurnSpeed = 0
	seat.Parent = model
	Util.Weld(frame, seat)

	local lift = Instance.new("LinearVelocity")
	lift.Name = "DriveVelocity"
	lift.Attachment0 = Util.Attachment(frame, Vector3.new())
	lift.RelativeTo = Enum.ActuatorRelativeTo.World
	lift.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lift.ForceLimitsEnabled = false
	lift.VectorVelocity = Vector3.new()
	lift.Enabled = false
	lift.Parent = frame

	local attitude = Instance.new("AlignOrientation")
	attitude.Name = "Attitude"
	attitude.Attachment0 = Util.Attachment(frame, Vector3.new(), "AttitudeAnchor")
	attitude.Mode = Enum.OrientationAlignmentMode.OneAttachment
	attitude.RigidityEnabled = true
	attitude.CFrame = frame.CFrame.Rotation
	attitude.Enabled = false
	attitude.Parent = frame

	addSitPrompt(seat, "Take the glider", "Hang Glider")
	bindSeat(seat, model, "Rider")
	addVehicleLabel(frame, "Hang Glider", Color3.fromRGB(190, 220, 255))

	model:SetAttribute("Health", 55)
	model:SetAttribute("MaxHealth", 55)
	model:SetAttribute("VehicleKind", "Glider")
	model.Parent = workspace

	active[model] = {
		kind = "Glider",
		chassis = frame,
		seat = seat,
		velocity = lift,
		orientation = attitude,
		heading = frame.CFrame.Rotation,
		airspeed = 0,
	}
	return model
end

--[[
	Skis.

	These cannot be a seat. A Roblox seat puts the character into a sitting
	pose and there is no way round that, and the whole point of the ski run
	is that you come down it standing up, shooting at people. So the rider is
	welded to the board instead with PlatformStand set, which holds them
	upright and stops the walk controller fighting the slope.

	The upshot is that skiing is a shooting posture. Guns, grenades, the
	mega-detonate key -- all of it works on the way down, which is the rule
	for every sport on this map.
]]
local SKI_SLOPE_SPEED = 185
local SKI_CARVE_RATE = 2.3

function VehicleService.SpawnSkis(position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "Skis"

	-- The board: invisible, and the thing everything else is welded to. Two
	-- visible skis sit on top of it.
	local board = Util.Part({
		Name = "Chassis",
		Size = Vector3.new(4.5, 0.6, 13),
		CFrame = CFrame.new(position),
		Transparency = 1,
		Anchored = false,
		-- Slippery and light, so it carries speed down snow.
		CustomPhysicalProperties = PhysicalProperties.new(0.2, 0.04, 0.3, 1, 1),
		Parent = model,
	})
	model.PrimaryPart = board

	for _, side in { -1, 1 } do
		local ski = Util.Part({
			Name = "Ski",
			Size = Vector3.new(1.3, 0.4, 13),
			CFrame = CFrame.new(position + Vector3.new(side * 1.5, 0, 0)),
			Color = if side < 0 then Color3.fromRGB(240, 70, 60) else Color3.fromRGB(255, 200, 50),
			Material = Enum.Material.SmoothPlastic,
			Anchored = false,
			Massless = true,
			Parent = model,
		})
		-- The turned-up tip, which is most of what makes it read as a ski.
		local tip = Util.Part({
			Name = "SkiTip",
			Size = Vector3.new(1.3, 0.4, 2.2),
			CFrame = CFrame.new(position + Vector3.new(side * 1.5, 0.45, -7))
				* CFrame.Angles(math.rad(-24), 0, 0),
			Color = ski.Color,
			Material = Enum.Material.SmoothPlastic,
			Anchored = false,
			Massless = true,
			Parent = model,
		})
		Util.Weld(board, ski)
		Util.Weld(board, tip)
	end

	-- Steering, and something to hold the board the right way up so it does
	-- not simply topple over the first time it is nudged.
	local turn = Instance.new("AngularVelocity")
	turn.Name = "TurnVelocity"
	turn.Attachment0 = Util.Attachment(board, Vector3.new())
	turn.RelativeTo = Enum.ActuatorRelativeTo.World
	turn.MaxTorque = 160000
	turn.AngularVelocity = Vector3.new()
	turn.Enabled = true
	turn.Parent = board

	local upright = Instance.new("AlignOrientation")
	upright.Name = "Upright"
	upright.Attachment0 = Util.Attachment(board, Vector3.new(), "UprightAnchor")
	upright.Mode = Enum.OrientationAlignmentMode.OneAttachment
	-- NOT rigid: a rigid board cannot be tipped, and tipping it is how you
	-- do a trick.
	upright.MaxTorque = 42000
	upright.Responsiveness = 22
	upright.CFrame = board.CFrame.Rotation
	upright.Enabled = true
	upright.Parent = board

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SkiPrompt"
	prompt.ActionText = "Grab the skis"
	prompt.ObjectText = "Skis"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt.Parent = board

	prompt.Triggered:Connect(function(player)
		VehicleService.MountSkis(player, model)
	end)

	addVehicleLabel(board, "Skis", Color3.fromRGB(255, 230, 140))

	model:SetAttribute("Health", 30)
	model:SetAttribute("MaxHealth", 30)
	model:SetAttribute("VehicleKind", "Skis")
	model.Parent = workspace

	active[model] = {
		kind = "Skis",
		chassis = board,
		turn = turn,
		upright = upright,
		rider = nil,
		-- Trick bookkeeping, filled in by the drive loop.
		airborneSince = nil,
		spin = 0,
		lastFacing = nil,
	}
	return model
end

--[[ Strap a player onto a pair of skis. ]]
function VehicleService.MountSkis(player: Player, model: Model)
	local state = active[model]
	if not state or state.rider then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return
	end
	-- Not while sitting in something else.
	if humanoid.SeatPart then
		return
	end

	local board = state.chassis :: BasePart
	root.CFrame = board.CFrame * CFrame.new(0, 3.2, 0)

	local weld = Instance.new("WeldConstraint")
	weld.Name = "SkiWeld"
	weld.Part0 = board
	weld.Part1 = root
	weld.Parent = board

	-- Upright, and the walk controller out of the way.
	humanoid.PlatformStand = true

	state.rider = player
	local playerState = PlayerState.Get(player)
	-- Reusing the vehicle slot on purpose: everything that already knows
	-- about "the thing you are riding" -- the eject key, the aim reference,
	-- the mounted-weapon rules -- then works for skis with no special cases.
	playerState.vehicle = model
	playerState.seatRole = "Skier"
	PlayerState.Changed.Fire(player)
end

--[[ Let go of the skis. Harmless if the player is not on any. ]]
function VehicleService.DismountSkis(player: Player)
	for model, state in active do
		if state.kind == "Skis" and state.rider == player then
			local board = state.chassis :: BasePart
			local weld = board:FindFirstChild("SkiWeld")
			if weld then
				weld:Destroy()
			end

			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.PlatformStand = false
			end

			state.rider = nil
			local playerState = PlayerState.Get(player)
			if playerState.vehicle == model then
				playerState.vehicle = nil
				playerState.seatRole = nil
				PlayerState.Changed.Fire(player)
			end
			return true
		end
	end
	return false
end

--[[
	A snowboard, and a downhill bike.

	Both are the ski rig with different numbers and a different shape on top,
	which is the whole reason skis were built as a board you are welded to
	rather than a seat: anything you ride standing up is the same problem.

	  - The BOARD carves harder and holds its speed better than skis, and
	    spins more freely in the air, so it suits grabs and flips.
	  - The BIKE is faster downhill, takes the biggest jumps, and will run
	    the mountain trail as happily as the piste.

	Both leave your weapons alone. Every sport here does.
]]
local function boardLike(
	name: string,
	label: string,
	position: Vector3,
	slopeSpeed: number,
	carveRate: number,
	dress: (Model, BasePart) -> ()
): Model
	local model = Instance.new("Model")
	model.Name = name

	local board = Util.Part({
		Name = "Chassis",
		Size = Vector3.new(4.5, 0.6, 13),
		CFrame = CFrame.new(position),
		Transparency = 1,
		Anchored = false,
		CustomPhysicalProperties = PhysicalProperties.new(0.2, 0.04, 0.3, 1, 1),
		Parent = model,
	})
	model.PrimaryPart = board

	dress(model, board)

	local turn = Instance.new("AngularVelocity")
	turn.Name = "TurnVelocity"
	turn.Attachment0 = Util.Attachment(board, Vector3.new())
	turn.RelativeTo = Enum.ActuatorRelativeTo.World
	turn.MaxTorque = 160000
	turn.AngularVelocity = Vector3.new()
	turn.Enabled = true
	turn.Parent = board

	local upright = Instance.new("AlignOrientation")
	upright.Name = "Upright"
	upright.Attachment0 = Util.Attachment(board, Vector3.new(), "UprightAnchor")
	upright.Mode = Enum.OrientationAlignmentMode.OneAttachment
	-- Not rigid: tipping it is how a trick happens.
	upright.MaxTorque = 42000
	upright.Responsiveness = 22
	upright.CFrame = board.CFrame.Rotation
	upright.Enabled = true
	upright.Parent = board

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RidePrompt"
	prompt.ActionText = `Grab the {string.lower(label)}`
	prompt.ObjectText = label
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt.Parent = board
	prompt.Triggered:Connect(function(player)
		VehicleService.MountSkis(player, model)
	end)

	addVehicleLabel(board, label, Color3.fromRGB(230, 240, 255))

	model:SetAttribute("Health", 34)
	model:SetAttribute("MaxHealth", 34)
	model:SetAttribute("VehicleKind", name)
	model.Parent = workspace

	active[model] = {
		-- Driven by driveSkis: same physics, different numbers.
		kind = "Skis",
		chassis = board,
		turn = turn,
		upright = upright,
		rider = nil,
		airborneSince = nil,
		spin = 0,
		lastFacing = nil,
		slopeSpeed = slopeSpeed,
		carveRate = carveRate,
	}
	return model
end

function VehicleService.SpawnSnowboard(position: Vector3): Model
	return boardLike("Snowboard", "Snowboard", position, 205, 2.9, function(model, board)
		local deck = Util.Part({
			Name = "Deck",
			Size = Vector3.new(4.2, 0.5, 13),
			CFrame = board.CFrame,
			Color = Color3.fromRGB(60, 150, 230),
			Material = Enum.Material.SmoothPlastic,
			Anchored = false,
			Massless = true,
			Parent = model,
		})
		Util.Weld(board, deck)

		-- Turned-up nose and tail, which is what makes it read as a board.
		for _, endZ in { -1, 1 } do
			local tip = Util.Part({
				Name = "BoardTip",
				Size = Vector3.new(4.2, 0.5, 2.4),
				CFrame = board.CFrame
					* CFrame.new(0, 0.5, endZ * 7)
					* CFrame.Angles(math.rad(endZ * 22), 0, 0),
				Color = Color3.fromRGB(40, 120, 200),
				Material = Enum.Material.SmoothPlastic,
				Anchored = false,
				Massless = true,
				Parent = model,
			})
			Util.Weld(board, tip)
		end

		for _, side in { -1, 1 } do
			local binding = Util.Part({
				Name = "Binding",
				Size = Vector3.new(2.4, 0.9, 2.6),
				CFrame = board.CFrame * CFrame.new(0, 0.7, side * 2.2),
				Color = Color3.fromRGB(30, 32, 38),
				Material = Enum.Material.Rubber,
				Anchored = false,
				Massless = true,
				Parent = model,
			})
			Util.Weld(board, binding)
		end
	end)
end

function VehicleService.SpawnBike(position: Vector3): Model
	return boardLike("Bike", "Downhill Bike", position, 240, 2.5, function(model, board)
		local frame = Util.Part({
			Name = "BikeFrame",
			Size = Vector3.new(1, 3.2, 10),
			CFrame = board.CFrame * CFrame.new(0, 2.6, 0),
			Color = Color3.fromRGB(220, 70, 40),
			Material = Enum.Material.Metal,
			Anchored = false,
			Massless = true,
			Parent = model,
		})
		Util.Weld(board, frame)

		-- Two wheels, fore and aft, welded on: decoration, like the board
		-- itself, because the slope does the moving.
		for _, endZ in { -1, 1 } do
			local wheel = Util.Part({
				Name = "BikeWheel",
				Size = Vector3.new(0.7, 6.4, 6.4),
				CFrame = board.CFrame * CFrame.new(0, 1.4, endZ * 4.6),
				Shape = Enum.PartType.Cylinder,
				Color = Color3.fromRGB(24, 24, 28),
				Material = Enum.Material.Rubber,
				Anchored = false,
				Massless = true,
				Parent = model,
			})
			Util.Weld(board, wheel)
		end

		local bars = Util.Part({
			Name = "Handlebars",
			Size = Vector3.new(5, 0.6, 0.6),
			CFrame = board.CFrame * CFrame.new(0, 4.6, -3.6),
			Color = Color3.fromRGB(40, 42, 48),
			Material = Enum.Material.Metal,
			Anchored = false,
			Massless = true,
			Parent = model,
		})
		Util.Weld(board, bars)

		local saddle = Util.Part({
			Name = "Saddle",
			Size = Vector3.new(1.4, 0.6, 3),
			CFrame = board.CFrame * CFrame.new(0, 4.4, 2.6),
			Color = Color3.fromRGB(28, 28, 32),
			Material = Enum.Material.Fabric,
			Anchored = false,
			Massless = true,
			Parent = model,
		})
		Util.Weld(board, saddle)
	end)
end

function VehicleService.SpawnKind(kind: string, position: Vector3): Model?
	if kind == "TurretTruck" then
		return VehicleService.SpawnTurretTruck(position)
	elseif kind == "Tank" then
		return VehicleService.SpawnTank(position)
	elseif kind == "Plane" then
		return VehicleService.SpawnPlane(position)
	elseif kind == "Torpedo" then
		return VehicleService.SpawnTorpedo(position)
	elseif kind == "Tube" then
		return VehicleService.SpawnTube(position)
	elseif kind == "Glider" then
		return VehicleService.SpawnGlider(position)
	elseif kind == "Skis" then
		return VehicleService.SpawnSkis(position)
	elseif kind == "Snowboard" then
		return VehicleService.SpawnSnowboard(position)
	elseif kind == "Bike" then
		return VehicleService.SpawnBike(position)
	elseif kind == "G-Wagon" or kind == "Hummer" or kind == "Jeep" then
		-- The off-roaders, by name, for the mountain pads.
		return VehicleService.SpawnCar(3, position, nil, kind)
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
	state.nextGroundSampleAt = state.nextGroundSampleAt or 0

	local throttle = if seat.Occupant then seat.Throttle else 0
	local steer = if seat.Occupant then seat.Steer else 0

	-- On a phone there is no W key, so the on-screen pedals send their value
	-- here and it overrides the seat's own throttle when pressed.
	local pedal = model:GetAttribute("Pedal")
	if seat.Occupant and typeof(pedal) == "number" and math.abs(pedal) > 0.01 then
		throttle = math.clamp(pedal, -1, 1)
	end

	-- Mud drags you down and boost chevrons fling you forward. Both come
	-- from looking at what is actually under the wheels rather than
	-- trusting a flag.
	--
	-- This used to allocate a fresh RaycastParams and cast every frame for
	-- every vehicle on the map. With a car spawning beside each of twenty
	-- players that is about two thousand casts and two thousand throwaway
	-- objects a second, for a question whose answer is a 50-stud mud pool.
	-- So: one shared params object, and a sample at 20 Hz while actually
	-- moving. At full speed that is ten studs between looks, well inside
	-- the smallest thing worth noticing.
	local speedFactor = 1
	local boosted = false

	local rolling = math.abs(state.currentSpeed) > 1 or seat.Occupant ~= nil
	if rolling then
		local now = os.clock()
		local here = chassis.Position
		local moved = if state.lastGroundSampleAt
			then (here - state.lastGroundSampleAt).Magnitude
			else math.huge

		if moved >= GROUND_SAMPLE_STUDS or now >= state.nextGroundSampleAt then
			state.nextGroundSampleAt = now + GROUND_SAMPLE_INTERVAL
			state.lastGroundSampleAt = here
			groundParams.FilterDescendantsInstances = { model }
			local hit = workspace:Raycast(here, GROUND_PROBE, groundParams)
			state.groundIsMud = hit ~= nil
				and (hit.Instance.Name == "Mud" or hit.Material == Enum.Material.Mud)
			state.groundIsBoost = hit ~= nil and hit.Instance:GetAttribute("Boost") == true
			-- Kept for the climb assist below, which needs to know how
			-- steeply the ground under the car is tilted.
			state.groundNormal = if hit then hit.Normal else nil
		end
	else
		-- Parked: forget what it was standing on, so pulling away from a mud
		-- pool does not carry the drag with it.
		state.groundIsMud = false
		state.groundIsBoost = false
		state.groundNormal = nil
		state.nextGroundSampleAt = 0
		state.lastGroundSampleAt = nil
	end

	if state.groundIsMud then
		speedFactor = Config.MudSpeedFactor
	end
	if state.groundIsBoost then
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
		if current < Config.Boost.Speed * 0.9 then
			Sound.At("Boost", chassis.Position)
		end
		current = math.max(current, Config.Boost.Speed)
	end

	state.currentSpeed = current

	-- An empty car rolls to a stop and then stops asking for anything. Its
	-- wheels still have to be kept glued to it, or they are left behind.
	if not seat.Occupant and math.abs(current) < 0.5 then
		state.currentSpeed = 0
		drive.Enabled = false
		turn.Enabled = false
		local idleEngine = chassis:FindFirstChild("Engine")
		if idleEngine and idleEngine:IsA("Sound") and idleEngine.IsPlaying then
			idleEngine:Stop()
		end
		if state.wheels then
			for _, wheel in state.wheels do
				-- Parked: stop the wheels turning. Nothing is repositioned,
				-- because the hinge is what holds them on now.
				if wheel.axle then
					wheel.axle.AngularVelocity = 0
				end
			end
		end
		return
	end

	if model:GetAttribute("LiftLocked") == true then
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

	--[[
		Climb assist, for off-roaders only.

		A dead-horizontal push cannot get a car up anything steep: it drives
		into the hill rather than over it. So the G-Wagon, the Hummer and the
		Jeep are allowed to tilt their drive axis a little way up the slope
		they are standing on -- enough to take the mountain trail, and only
		ever as much as the ground under them is actually tilted.

		An ordinary car gets none of this on purpose. A non-flattened drive
		axis is exactly what used to fire trucks into the sky, and the drive
		test still asserts they stay down.
	]]
	local driveAxis = flat
	local assist = state.climbAssist or 0
	if assist > 0 and state.groundNormal then
		local normal = state.groundNormal :: Vector3
		-- A flat surface has a vertical normal, so this is zero there and
		-- the assist simply does not engage.
		local tilt = Vector3.new(normal.X, 0, normal.Z).Magnitude
		if tilt > 0.12 then
			local lifted = Vector3.new(flat.X, tilt * assist, flat.Z)
			if lifted.Magnitude > 0.01 then
				driveAxis = lifted.Unit
			end
		end
	end

	--[[
		Off a jump, let it FLY.

		The drive constraint pins the car's velocity to a horizontal line. In
		the air that is exactly wrong: it keeps forcing horizontal speed while
		gravity pulls down, which flattens the arc into a shove off the lip
		and a drop. Switching the constraints off the moment the wheels leave
		the ground lets the car follow a real ballistic curve, which is the
		difference between hitting a jump and falling off a ramp.
	]]
	--[[
		Airborne, from physics rather than from a raycast.

		The first attempt read `state.groundNormal == nil`, which is wrong
		twice over: that probe is paced by DISTANCE so its answer is up to
		four studs stale, and a miss means "the probe did not hit", not "the
		car is flying". It also meant a car on ground the probe happened to
		miss switched its own drive off and coasted to a halt.

		Vertical speed needs no raycast and cannot be stale. A car on the
		ground sits at essentially zero on Y; one that has left a ramp is
		moving up or down hard.
	]]
	local verticalSpeed = chassis.AssemblyLinearVelocity.Y
	local airborne = math.abs(verticalSpeed) > 22
	if airborne then
		drive.Enabled = false
		turn.Enabled = false
	else
		drive.Enabled = true
		turn.Enabled = true
		drive.LineDirection = driveAxis
		drive.LineVelocity = current
	end

	-- The engine rises and falls with road speed.
	local engine = chassis:FindFirstChild("Engine")
	if engine and engine:IsA("Sound") then
		local fraction = math.abs(current) / math.max(topSpeed, 1)
		engine.PlaybackSpeed = 0.45 + fraction * 1.5
		engine.Volume = 0.2 + fraction * 0.4
		if not engine.IsPlaying then
			engine:Play()
		end
	end

	-- Roll the wheels at whatever speed the car is actually doing, by telling
	-- the axle motors how fast to turn. One number each, and the hinge keeps
	-- the wheel attached -- rather than rewriting four CFrames a frame from a
	-- chassis position that is already stale, which is what made them look
	-- like they were coming off.
	if state.wheels then
		local radius = WHEEL_DIAMETER * 0.5
		local spinRate = current / radius
		for _, wheel in state.wheels do
			if wheel.axle then
				wheel.axle.AngularVelocity = spinRate
			end
		end
	end

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
--[[
	Drive a tube.

	A tube has no engine. It goes where it is pushed:

	  - In the river, a FlowZone part carries a direction attribute and the
	    tube is pushed along it. That is what makes the lazy river lazy and
	    still a way to travel.
	  - On snow, gravity does it: the steeper the slope under you, the faster
	    you go, which is what lets you ride the ski run on a tube and shoot
	    off the end of it into the water without ever touching a throttle.

	Steering only points you. Nothing here fights gravity, so the tube still
	falls off a cliff like an object rather than hovering like a vehicle.
]]
-- Declared ahead of driveTube, which uses it: the trick scorer itself needs
-- Util.AngleBetween and PlayerState, so it is defined further down.
local stepTricks: (Model, any, Player?, boolean, number) -> ()

local TUBE_FLOW_SPEED = 46
local TUBE_SLOPE_SPEED = 118

local function driveTube(model: Model, state: any, deltaTime: number)
	local hub = state.chassis :: BasePart
	local seat = state.seat :: VehicleSeat
	local turn = state.turn :: AngularVelocity

	-- Steering works whether or not anybody is aboard; an empty tube simply
	-- is not told to turn.
	turn.AngularVelocity = if seat.Occupant
		then Vector3.new(0, -seat.Steer * 1.9, 0)
		else Vector3.new()

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local occupantCharacter = if seat.Occupant then seat.Occupant.Parent else nil
	params.FilterDescendantsInstances = if occupantCharacter
		then { model, occupantCharacter }
		else { model }

	local push = Vector3.new()

	-- The river first: a current beats a slope.
	local flowHit = workspace:Raycast(hub.Position + Vector3.new(0, 2, 0), Vector3.new(0, -8, 0), params)
	local flowPart = if flowHit then flowHit.Instance else nil
	local onFlow = false
	if flowPart then
		local fx = flowPart:GetAttribute("FlowX")
		local fz = flowPart:GetAttribute("FlowZ")
		if typeof(fx) == "number" and typeof(fz) == "number" then
			onFlow = true
			push = Vector3.new(fx, 0, fz) * TUBE_FLOW_SPEED
		end
	end

	if not onFlow then
		-- Snow: slide downhill, hard. The surface normal gives both the
		-- direction and the steepness in one go.
		local ground = workspace:Raycast(hub.Position, Vector3.new(0, -7, 0), params)
		if ground and ground.Material == Enum.Material.Snow then
			local normal = ground.Normal
			local downhill = Vector3.new(normal.X, 0, normal.Z)
			if downhill.Magnitude > 0.02 then
				-- A flat surface has a vertical normal and so no downhill
				-- component at all, which is exactly right: you stop.
				push = downhill.Unit * (downhill.Magnitude * TUBE_SLOPE_SPEED)
			end
		end
	end

	if push.Magnitude > 0.1 then
		-- An impulse rather than a velocity constraint, so the tube keeps
		-- its own vertical motion and still falls, jumps and lands.
		local current = hub.AssemblyLinearVelocity
		local flat = Vector3.new(current.X, 0, current.Z)
		local wanted = push - flat
		-- Eased, so it accelerates into the current instead of snapping.
		hub.AssemblyLinearVelocity = current + Vector3.new(wanted.X, 0, wanted.Z) * math.min(1, deltaTime * 3.2)
	end

	-- Tricks off the table tops count on a tube too.
	local rider = if seat.Occupant and seat.Occupant.Parent
		then Players:GetPlayerFromCharacter(seat.Occupant.Parent)
		else nil
	local grounded = workspace:Raycast(hub.Position, Vector3.new(0, -6, 0), params) ~= nil
	stepTricks(model, state, rider, grounded, deltaTime)
end

--[[
	Fly a hang glider.

	It trades height for speed the way a wing does: nose down and you gain
	speed and lose altitude, nose up and you convert speed back into a brief
	climb and then run out of it. There is no throttle, which is the whole
	character of the thing.
]]
local GLIDE_MIN_SPEED = 42
local GLIDE_MAX_SPEED = 140
local GLIDE_SINK = 13

local function driveGlider(model: Model, state: any, deltaTime: number)
	local frame = state.chassis :: BasePart
	local seat = state.seat :: VehicleSeat
	local lift = state.velocity :: LinearVelocity
	local attitude = state.orientation :: AlignOrientation

	if not seat.Occupant then
		lift.Enabled = false
		attitude.Enabled = false
		state.airspeed = 0
		return
	end

	lift.Enabled = true
	attitude.Enabled = true

	--[[
		W pushes the nose DOWN, S pulls it up.

		Note the minus sign. A positive rotation about X takes the look
		vector upward in Roblox, so without it W climbed and the glider lost
		speed when you asked it to dive -- which the test caught as "diving
		trades height for speed" failing with the dive SLOWER than level.
	]]
	local pitchInput = seat.Throttle
	local rollInput = seat.Steer

	state.heading = state.heading
		* CFrame.Angles(-pitchInput * 0.9 * deltaTime, -rollInput * 1.25 * deltaTime, 0)

	-- Keep the nose from going fully vertical either way, which would leave
	-- the wing with no sensible forward direction at all.
	local look = state.heading.LookVector
	if look.Y > 0.72 or look.Y < -0.86 then
		state.heading = state.heading * CFrame.Angles(pitchInput * 0.9 * deltaTime, 0, 0)
		look = state.heading.LookVector
	end

	attitude.CFrame = state.heading

	-- Diving builds speed, climbing spends it.
	local gain = -look.Y * 95
	state.airspeed = math.clamp(
		(state.airspeed or GLIDE_MIN_SPEED) + (gain - 16) * deltaTime,
		GLIDE_MIN_SPEED,
		GLIDE_MAX_SPEED
	)

	-- Always sinking a little, so a glide is a glide and not a hover.
	local sink = -GLIDE_SINK * (1 - math.clamp(state.airspeed / GLIDE_MAX_SPEED, 0, 1) * 0.55)
	lift.VectorVelocity = look * state.airspeed + Vector3.new(0, sink, 0)
end

--[[
	Tricks, SSX-style.

	What counts as a trick is measured rather than declared: the server
	watches how long you were off the ground and how far the board turned
	while you were up there, and pays out on the landing. Nothing is reported
	by the client, so there is nothing to lie about -- a trick you did not do
	cannot be claimed, and a trick you did cannot be denied.

	Rotation is accumulated per frame from the board's own facing, so a slow
	720 and a fast 720 score the same, which is as it should be.
]]
local TRICK_MIN_AIRTIME = 0.45
local TRICK_SPIN_POINTS = 0.55 -- per degree turned
local TRICK_AIR_POINTS = 26 -- per second airborne

local TRICK_NAMES = {
	{ spin = 1080, name = "TRIPLE CORK" },
	{ spin = 720, name = "SEVEN-TWENTY" },
	{ spin = 480, name = "FIVE-FORTY" },
	{ spin = 270, name = "THREE-SIXTY" },
	{ spin = 160, name = "ONE-EIGHTY" },
	{ spin = 0, name = "BIG AIR" },
}

local function trickName(spin: number): string
	for _, entry in TRICK_NAMES do
		if spin >= entry.spin then
			return entry.name
		end
	end
	return "BIG AIR"
end

--[[
	Watch a ride for airtime and spin, and pay out when it lands.

	Shared by skis and tubes, because the brief was tricks off the table tops
	and you can take either down the run.
]]
function stepTricks(model, state, rider, grounded, deltaTime)
	local board = state.chassis :: BasePart
	local facing = board.CFrame.LookVector
	local flat = Vector3.new(facing.X, 0, facing.Z)

	if state.lastFacing and flat.Magnitude > 0.01 then
		state.spin = (state.spin or 0) + Util.AngleBetween(state.lastFacing, flat.Unit)
	end
	state.lastFacing = if flat.Magnitude > 0.01 then flat.Unit else state.lastFacing

	if not grounded then
		if not state.airborneSince then
			state.airborneSince = os.clock()
			state.spin = 0
		end
		return
	end

	local launched = state.airborneSince
	state.airborneSince = nil
	if not launched or not rider then
		state.spin = 0
		return
	end

	local airtime = os.clock() - launched
	state.spin = state.spin or 0
	if airtime < TRICK_MIN_AIRTIME then
		-- A bump in the piste is not a trick.
		state.spin = 0
		return
	end

	-- Taken into a local BEFORE the reset. Reading state.spin after zeroing
	-- it meant every trick, however far it turned, came out named "BIG AIR"
	-- while being paid for the spin -- the score was right and the shout was
	-- wrong, which is the kind of thing nobody notices for months.
	local spun = state.spin
	state.spin = 0

	local points = math.floor(airtime * TRICK_AIR_POINTS + spun * TRICK_SPIN_POINTS)
	if points <= 0 then
		return
	end

	local awarded = PlayerState.AwardPoints(rider, points)
	VehicleService.TrickLanded.Fire(rider, trickName(spun), awarded, airtime)

	local _ = deltaTime
end

--[[
	Ski down a mountain.

	Same idea as the tube -- gravity does the work, the slope decides how
	much -- but faster, and it carves: steering turns the board, and the
	board's own facing is what you accelerate along, so you can traverse
	across a slope instead of only straight down it.
]]
local function driveSkis(model: Model, state: any, deltaTime: number)
	local board = state.chassis :: BasePart
	local turn = state.turn :: AngularVelocity
	local upright = state.upright :: AlignOrientation
	local rider = state.rider :: Player?

	-- Nobody aboard: let it lie still rather than skidding off on its own.
	if not rider or not rider.Parent then
		if rider then
			VehicleService.DismountSkis(rider)
		end
		turn.AngularVelocity = Vector3.new()
		return
	end

	local character = rider.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		VehicleService.DismountSkis(rider)
		return
	end

	-- Steering comes off the move keys. There is no seat, so the inputs
	-- arrive as the humanoid's own walk direction.
	local steer = 0
	local wish = humanoid.MoveDirection
	if wish.Magnitude > 0.1 then
		local across = Vector3.new(-board.CFrame.LookVector.Z, 0, board.CFrame.LookVector.X)
		steer = math.clamp(wish:Dot(across) * 1.6, -1, 1)
	end
	turn.AngularVelocity = Vector3.new(0, -steer * (state.carveRate or SKI_CARVE_RATE), 0)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if character then { model, character } else { model }

	local ground = workspace:Raycast(board.Position, Vector3.new(0, -6, 0), params)
	local grounded = ground ~= nil

	if ground and ground.Material == Enum.Material.Snow then
		local normal = ground.Normal
		local downhill = Vector3.new(normal.X, 0, normal.Z)
		if downhill.Magnitude > 0.02 then
			-- Accelerate along the board's own facing, biased downhill, so
			-- carving across the fall line actually works.
			local steepness = downhill.Magnitude
			local heading = board.CFrame.LookVector
			local flatHeading = Vector3.new(heading.X, 0, heading.Z)
			local blend = if flatHeading.Magnitude > 0.01
				then (flatHeading.Unit * 0.55 + downhill.Unit * 0.45).Unit
				else downhill.Unit

			local target = blend * (steepness * (state.slopeSpeed or SKI_SLOPE_SPEED))
			local current = board.AssemblyLinearVelocity
			local wanted = target - Vector3.new(current.X, 0, current.Z)
			board.AssemblyLinearVelocity = current
				+ Vector3.new(wanted.X, 0, wanted.Z) * math.min(1, deltaTime * 2.6)
		end
	end

	-- Hold the board level when it is on the ground, and let it tumble
	-- freely in the air so a trick looks like a trick.
	upright.Enabled = grounded
	if grounded then
		local heading = board.CFrame.LookVector
		local flatHeading = Vector3.new(heading.X, 0, heading.Z)
		if flatHeading.Magnitude > 0.01 then
			upright.CFrame = CFrame.lookAt(Vector3.new(), flatHeading.Unit)
		end
	end

	stepTricks(model, state, rider, grounded, deltaTime)
end

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

	-- Track takeoff grace period so planes sitting on the pad never explode on boarding.
	local now = os.clock()
	if not state.boardedAt then
		state.boardedAt = now
		state.airborne = false
		state.speed = math.max(state.speed or 0, stallSpeed * 1.25)
		-- Gentle climb attitude on takeoff.
		state.heading = CFrame.new() * state.heading.Rotation * CFrame.Angles(math.rad(14), 0, 0)
	end
	if body.Position.Y > 18 then
		state.airborne = true
	end

	-- Maintain smooth cruise speed; W climbs gently and S dives/slows rather than slamming into the ground.
	local cruise = (stallSpeed + topSpeed) * 0.55
	local target = if seat.Throttle ~= 0
		then (state.speed or cruise) + seat.Throttle * 55 * deltaTime
		else (state.speed or cruise) + (cruise - (state.speed or cruise)) * math.min(1, deltaTime * 1.5)
	state.speed = math.clamp(target, stallSpeed, topSpeed)

	local roll = -seat.Steer * rollRate * deltaTime
	local pitch = seat.Throttle * pitchRate * deltaTime * 0.45
	local yaw = -seat.Steer * yawRate * deltaTime

	state.heading = state.heading * CFrame.Angles(pitch, yaw, roll)
	state.orientation.CFrame = state.heading

	local liftBoost = if (not state.airborne) and (now - state.boardedAt < 2.2) then Vector3.new(0, 26, 0) else Vector3.zero
	state.velocity.VectorVelocity = state.heading.LookVector * state.speed + liftBoost

	if state.airborne and body.Position.Y < 6 then
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

	--[[
		Hitting things, and running out.

		Neither of these existed. `armedAt` was written at spawn and never
		read once, and `Lifetime` was in the config with a comment promising
		"it dies on its own after this long, with you on it". So the torpedo
		-- the thing you steer into somebody -- passed straight through them
		and then flew forever, or until it hit a wall and sat there.

		A raycast ahead rather than a Touched connection: the body is driven
		by a velocity constraint at 150 studs a second, which is two and a
		half studs per frame, and contact events on something moving that
		fast are not something to rely on.
	]]
	local now = os.clock()
	if not state.armedAt then
		state.armedAt = now + 1.0
		state.expiresAt = now + (spec.Lifetime or 20)
	end
	if now < state.armedAt then
		return
	end

	if now >= state.expiresAt then
		VehicleService.Explode(model)
		return
	end

	local chassis = state.chassis :: BasePart
	local nose = state.heading.LookVector
	-- Far enough ahead to cover a frame of travel plus the shell itself.
	local reach = runSpeed * math.max(deltaTime, 1 / 60) + 11

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Not itself, and not the person riding it.
	local rider = seat.Occupant
	local riderCharacter = if rider then rider.Parent else nil
	params.FilterDescendantsInstances = if riderCharacter
		then { model, riderCharacter }
		else { model }

	local hit = workspace:Raycast(chassis.Position, nose * reach, params)
	if hit then
		VehicleService.Explode(model)
	end
end

--[[
	Turn a player's turbo on or off.

	Works on whatever they are currently driving; on foot it just makes them
	run faster, so the same key always means "go faster".
]]
--[[
	Who is currently looking down a scope, and how fast they may move.

	Kept here beside SetTurbo because both of them write WalkSpeed, and two
	places writing the same property without knowing about each other is how
	you get a player permanently stuck at sniper pace.
]]
local scoped: { [Player]: boolean? } = {}

function VehicleService.SetScoped(player: Player, on: boolean)
	-- nil rather than false, so the table does not grow an entry for every
	-- player who ever un-scoped.
	scoped[player] = if on then true else nil

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	-- Only touch it on foot: in a seat WalkSpeed is irrelevant anyway.
	if humanoid.SeatPart then
		return
	end
	humanoid.WalkSpeed = if on
		then Config.Turbo.WalkSpeed * Config.Movement.ScopedSpeedFactor
		else Config.Turbo.WalkSpeed
end

function VehicleService.SetTurbo(player: Player, on: boolean)
	local state = PlayerState.Get(player)

	if state.vehicle and state.vehicle.Parent and state.seatRole == "Driver" then
		state.vehicle:SetAttribute("Turbo", on)
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- Sprinting beats being scoped: letting go of the scope should not
		-- leave you stuck at sniper pace, and holding shift should always
		-- make you faster.
		humanoid.WalkSpeed = if on
			then Config.Turbo.SprintWalkSpeed
			elseif scoped[player] then Config.Turbo.WalkSpeed * Config.Movement.ScopedSpeedFactor
			else Config.Turbo.WalkSpeed
	end
end

--[[ The on-screen gas and brake pedals, for players without a keyboard. ]]
function VehicleService.SetPedal(player: Player, value: number)
	local state = PlayerState.Get(player)
	if state.vehicle and state.vehicle.Parent and state.seatRole == "Driver" then
		state.vehicle:SetAttribute("Pedal", math.clamp(value, -1, 1))
	end
end

--[[
	Bail out.

	Press space on a rideable rocket and you are thrown clear, a parachute
	opens, and you drift down instead of making a crater. The descent is a
	LinearVelocity in Line mode along world Y: it pins how fast you fall
	without touching your horizontal movement, so you can still steer where
	you land.
]]
--[[
	Who is already mid-ejection.

	The Parachute guard below is checked BEFORE a task.wait, and the
	parachute is only created after it. Ten Eject calls in a single frame
	therefore all passed the guard, each stacking another 70 studs/sec of
	upward velocity and another LinearVelocity constraint -- a free launch to
	the top of the skybox. The claim has to be staked synchronously, before
	anything yields.
]]
local ejecting: { [Player]: true } = {}

function VehicleService.Eject(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return
	end
	--[[
		Skis are not a seat, so the bail key has to know about them
		separately -- and PlatformStand means you cannot simply jump off.
	]]
	if not humanoid.SeatPart then
		if VehicleService.DismountSkis(player) then
			return
		end
		return
	end
	-- Already under a canopy, or already on the way to one.
	if character:FindFirstChild("Parachute") or ejecting[player] then
		return
	end
	ejecting[player] = true

	humanoid.Sit = false

	-- Thrown clear of whatever you were riding.
	task.wait(0.1)
	if not root.Parent or player.Parent == nil then
		ejecting[player] = nil
		return
	end
	root.AssemblyLinearVelocity = root.AssemblyLinearVelocity + Vector3.new(0, 70, 0)

	local canopy = Instance.new("Model")
	canopy.Name = "Parachute"

	local dome = Util.Part({
		Name = "Canopy",
		Size = Vector3.new(22, 9, 22),
		CFrame = root.CFrame * CFrame.new(0, 13, 0),
		Color = Color3.fromRGB(240, 130, 60),
		Material = Enum.Material.Fabric,
		Anchored = false,
		CanCollide = false,
		Massless = true,
		Parent = canopy,
	})
	local domeMesh = Instance.new("SpecialMesh")
	domeMesh.MeshType = Enum.MeshType.Sphere
	domeMesh.Parent = dome

	-- Lines from the canopy down to the jumper.
	for index = 1, 4 do
		local angle = (index / 4) * math.pi * 2
		local cord = Util.Part({
			Name = "Cord",
			Size = Vector3.new(0.2, 9, 0.2),
			CFrame = root.CFrame * CFrame.new(math.cos(angle) * 5, 7, math.sin(angle) * 5),
			Color = Color3.fromRGB(230, 230, 230),
			Anchored = false,
			CanCollide = false,
			Massless = true,
			Parent = canopy,
		})
		Util.Weld(dome, cord)
	end

	Util.Weld(root, dome)
	canopy.Parent = character

	local anchorPoint = Util.Attachment(root, Vector3.zero, "ChuteRoot")

	local descent = Instance.new("LinearVelocity")
	descent.Name = "ChuteDescent"
	descent.Attachment0 = anchorPoint
	descent.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	descent.RelativeTo = Enum.ActuatorRelativeTo.World
	-- Straight down, gently. Horizontal movement is left alone.
	descent.LineDirection = Vector3.new(0, 1, 0)
	descent.LineVelocity = -24
	descent.ForceLimitsEnabled = false
	descent.MaxForce = math.huge
	descent.MaxAxesForce = Vector3.new(math.huge, math.huge, math.huge)
	descent.Enabled = false
	descent.Parent = root

	Sound.At("ParachuteOpen", root.Position)
	Remotes.Event("Notify"):FireClient(player, "Parachute open — steer with WASD.")

	-- Let the launch carry you upward first, then open.
	task.delay(0.7, function()
		if descent.Parent then
			descent.Enabled = true
		end
	end)

	-- Cut away once you are down, or after long enough that something is wrong.
	task.spawn(function()
		local opened = os.clock()
		while os.clock() - opened < 30 do
			task.wait(0.2)
			if not root.Parent or not canopy.Parent then
				break
			end
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { character }
			local ground = workspace:Raycast(root.Position, Vector3.new(0, -8, 0), params)
			if ground and os.clock() - opened > 1.2 then
				break
			end
		end
		ejecting[player] = nil
		if canopy.Parent then
			canopy:Destroy()
		end
		if descent.Parent then
			descent:Destroy()
		end
		if anchorPoint.Parent then
			anchorPoint:Destroy()
		end
	end)
end

--[[ Hurt a vehicle. At zero health it explodes and takes its riders with it. ]]
function VehicleService.Damage(model: Model, amount: number, attacker: Player?)
	if not model or not model.Parent then
		return
	end
	if not (amount > 0) or amount == math.huge then
		return
	end
	local health = model:GetAttribute("Health")
	if typeof(health) ~= "number" then
		return
	end

	local state = active[model]
	if state and attacker then
		state.lastAttacker = attacker
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
	local blastDamage = 110
	if kind == "Torpedo" then
		local torpedo = Config.Vehicles.Torpedo
		blastRadius = torpedo.BlastRadius or 45
		blastDamage = torpedo.BlastDamage or 200
	end

	--[[
		This used to be a bare Explosion instance and nothing else, which
		meant **every exploding vehicle dealt exactly zero damage**.

		Roblox's Explosion only hurts a Humanoid by breaking its joints, and
		DestroyJointRadiusPercent was set to 0 here to stop characters coming
		apart -- which also switched off the only damage it does. So a torpedo
		ridden straight into somebody, the one thing the torpedo is for, did
		nothing at all to them. Same for a tank going up next to a crowd.

		The visible blast stays; the damage goes through DamageService, which
		is the only thing that knows about teams, shields, point awards and
		the kill feed.
	]]
	local explosion = Instance.new("Explosion")
	explosion.Position = position
	explosion.BlastRadius = blastRadius
	explosion.BlastPressure = 250000
	explosion.DestroyJointRadiusPercent = 0
	explosion.Parent = workspace

	-- Announced rather than applied directly. DamageService already requires
	-- this module, so calling into it from here would be a dependency cycle;
	-- it listens for this instead, and the dependency stays one-way.
	if state.rider then
		VehicleService.DismountSkis(state.rider)
	end

	VehicleService.Wrecked.Fire(position, blastRadius, blastDamage, state.lastAttacker or state.lastDriver)

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
		elseif state.kind == "Tube" then
			driveTube(model, state, deltaTime)
		elseif state.kind == "Glider" then
			driveGlider(model, state, deltaTime)
		elseif state.kind == "Skis" then
			driveSkis(model, state, deltaTime)
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
	for model, state in active do
		if state.rider then
			VehicleService.DismountSkis(state.rider)
		end
		if model.Parent then
			model:Destroy()
		end
	end
	for _, player in Players:GetPlayers() do
		local pState = PlayerState.Get(player)
		if pState.vehicle then
			pState.vehicle = nil
			pState.seatRole = nil
			PlayerState.Changed.Fire(player)
		end
	end
	table.clear(active)
end

Players.PlayerRemoving:Connect(function(player)
	-- Otherwise a player who leaves mid-ejection holds their claim forever,
	-- and these tables hold on to them.
	ejecting[player] = nil
	scoped[player] = nil
end)

RunService.Heartbeat:Connect(step)

return VehicleService
