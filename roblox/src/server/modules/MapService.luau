--!strict
--[[
	MapService — builds the whole arena out of code.

	Nothing here is hand-modelled, so changing a map means changing numbers in
	Config.Maps rather than opening the 3D editor.

	Two rules every piece obeys:

	  1. YOU CAN DRIVE IT. Doorways are wide and tall enough to take a truck,
	     every roof has a ramp, and no vehicle route has a step in it.
	  2. YOU CAN WALK IT. Buildings are hollow, with hallways and real
	     staircases inside, so a player on foot has somewhere to fight that
	     is not just open mud.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared:WaitForChild("Util"))

local MapService = {}

export type MapBuild = {
	model: Model,
	teamSpawns: { [number]: { Vector3 } },
	vehiclePads: { { position: Vector3, kind: string } },
	pickupPads: { { position: Vector3, kind: string } },
}

local SLAB = 3 -- thickness of floors and ramps
local FLOOR_HEIGHT = 18 -- tall enough to drive a truck through a storey
local DOOR_WIDTH = 22 -- wide enough for a truck
local DOOR_HEIGHT = 14
local WALL_THICKNESS = 2
local STAIR_STEPS = 14

-- ============================================================ BASIC PIECES ==

--[[
	A sloped slab connecting two points. This one function builds every ramp,
	every jump and every bridge in the game.
]]
local function ramp(from: Vector3, to: Vector3, width: number, color: Color3, parent: Instance): Part
	local delta = to - from
	local length = math.max(delta.Magnitude, 0.1)
	local mid = from + delta * 0.5

	-- CFrame.lookAt points the part's -Z at the target and Size.Z runs along
	-- that axis, so a part sized (width, thickness, length) becomes the ramp.
	return Util.Part({
		Name = "Ramp",
		Size = Vector3.new(width, SLAB, length),
		CFrame = CFrame.lookAt(mid, to),
		Color = color,
		Material = Enum.Material.Concrete,
		Parent = parent,
	})
end

--[[
	A staircase. Built from real steps rather than a slope, because indoors
	you want somewhere to fight, not a ski jump — and stairs read as stairs.
	Vehicles use the outside ramp instead.
]]
local function staircase(bottom: Vector3, direction: Vector3, rise: number, width: number, color: Color3, parent: Instance)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	flat = if flat.Magnitude < 0.01 then Vector3.new(0, 0, 1) else flat.Unit

	local stepRise = rise / STAIR_STEPS
	local stepRun = 3.2

	for index = 1, STAIR_STEPS do
		local centre = bottom
			+ flat * (index * stepRun)
			+ Vector3.new(0, index * stepRise - stepRise * 0.5, 0)

		local step = Util.Part({
			Name = "Step",
			Size = Vector3.new(width, stepRise, stepRun),
			CFrame = CFrame.lookAt(centre, centre + flat),
			Color = color,
			Material = Enum.Material.Concrete,
			Parent = parent,
		})
		local _ = step
	end
end

--[[
	A wall with a doorway punched through the middle of it: a panel either
	side and a lintel across the top.
]]
local function wallWithDoor(
	centre: Vector3,
	facing: Vector3,
	length: number,
	height: number,
	color: Color3,
	parent: Instance
)
	local flat = Vector3.new(facing.X, 0, facing.Z)
	flat = if flat.Magnitude < 0.01 then Vector3.new(0, 0, 1) else flat.Unit
	-- The wall runs at right angles to the way it faces.
	local along = Vector3.new(-flat.Z, 0, flat.X)

	local sideLength = math.max((length - DOOR_WIDTH) * 0.5, 0.5)
	local orientation = CFrame.lookAt(centre, centre + flat)

	for _, side in { -1, 1 } do
		local offset = side * (DOOR_WIDTH * 0.5 + sideLength * 0.5)
		local panelCentre = centre + along * offset + Vector3.new(0, height * 0.5, 0)
		Util.Part({
			Name = "Wall",
			Size = Vector3.new(sideLength, height, WALL_THICKNESS),
			CFrame = CFrame.lookAt(panelCentre, panelCentre + flat),
			Color = color,
			Material = Enum.Material.Brick,
			Parent = parent,
		})
	end

	-- Lintel over the door.
	if height > DOOR_HEIGHT then
		local lintelHeight = height - DOOR_HEIGHT
		local lintelCentre = centre + Vector3.new(0, DOOR_HEIGHT + lintelHeight * 0.5, 0)
		Util.Part({
			Name = "Lintel",
			Size = Vector3.new(DOOR_WIDTH, lintelHeight, WALL_THICKNESS),
			CFrame = CFrame.lookAt(lintelCentre, lintelCentre + flat),
			Color = color,
			Material = Enum.Material.Brick,
			Parent = parent,
		})
	end

	local _ = orientation
end

--[[
	One floor slab with a square hole cut in one corner for the stairwell.
	Built from two rectangles, because that is how you make a hole without
	needing modelling tools.
]]
local function floorWithStairwell(centre: Vector3, footprint: number, holeSize: number, color: Color3, parent: Instance)
	local half = footprint * 0.5

	-- The big piece: full width, stopping short of the stairwell strip.
	Util.Part({
		Name = "Floor",
		Size = Vector3.new(footprint, SLAB, footprint - holeSize),
		CFrame = CFrame.new(centre + Vector3.new(0, 0, -holeSize * 0.5)),
		Color = color,
		Material = Enum.Material.Concrete,
		Parent = parent,
	})

	-- The remaining strip, minus the corner that stays open.
	Util.Part({
		Name = "Floor",
		Size = Vector3.new(footprint - holeSize, SLAB, holeSize),
		CFrame = CFrame.new(centre + Vector3.new(-holeSize * 0.5, 0, half - holeSize * 0.5)),
		Color = color,
		Material = Enum.Material.Concrete,
		Parent = parent,
	})
end

-- ================================================================ BUILDINGS ==

--[[
	A building you can drive into, walk through, climb, and fight on top of.

	Ground floor and every floor above it are hollow, with doorways on all
	four sides and a partition down the middle making two hallways. A
	staircase in one corner connects the floors on foot; a switchback ramp
	around the outside gets vehicles to the roof.
]]
local function building(origin: Vector3, footprint: number, floors: number, color: Color3, parent: Instance)
	local half = footprint * 0.5
	local height = floors * FLOOR_HEIGHT
	local holeSize = 24

	-- Ground slab, so the inside is a floor and not open mud.
	Util.Part({
		Name = "Floor",
		Size = Vector3.new(footprint, SLAB, footprint),
		CFrame = CFrame.new(origin + Vector3.new(0, SLAB * 0.5, 0)),
		Color = color:Lerp(Color3.fromRGB(60, 60, 60), 0.3),
		Material = Enum.Material.Concrete,
		Parent = parent,
	})

	for floor = 0, floors - 1 do
		local baseY = floor * FLOOR_HEIGHT + SLAB

		-- Four walls, each with a doorway wide enough to drive through.
		for _, facing in { Vector3.new(0, 0, 1), Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0) } do
			wallWithDoor(
				origin + facing * half + Vector3.new(0, baseY, 0),
				facing,
				footprint,
				FLOOR_HEIGHT,
				color,
				parent
			)
		end

		-- An interior partition, offset from centre, making a long hallway on
		-- one side and rooms on the other. Left open at both ends.
		local partitionLength = footprint * 0.45
		Util.Part({
			Name = "Partition",
			Size = Vector3.new(WALL_THICKNESS, FLOOR_HEIGHT, partitionLength),
			CFrame = CFrame.new(origin + Vector3.new(-footprint * 0.12, baseY + FLOOR_HEIGHT * 0.5, 0)),
			Color = color:Lerp(Color3.fromRGB(230, 230, 230), 0.25),
			Material = Enum.Material.Brick,
			Parent = parent,
		})

		-- The ceiling of this floor is the floor of the next, with a hole in
		-- the corner for the stairs to come up through.
		local ceilingY = baseY + FLOOR_HEIGHT
		floorWithStairwell(
			origin + Vector3.new(0, ceilingY, 0),
			footprint,
			holeSize,
			color:Lerp(Color3.fromRGB(60, 60, 60), 0.3),
			parent
		)

		-- Stairs up through that hole, tucked into the corner it leaves open.
		staircase(
			origin + Vector3.new(half - holeSize * 0.5, baseY, half - holeSize),
			Vector3.new(0, 0, 1),
			FLOOR_HEIGHT,
			holeSize * 0.7,
			color:Lerp(Color3.fromRGB(200, 200, 200), 0.3),
			parent
		)
	end

	-- Roof lip, so the roof is cover rather than a slide.
	local roofY = floors * FLOOR_HEIGHT + SLAB
	for _, side in { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) } do
		Util.Part({
			Name = "RoofLip",
			Size = Vector3.new(
				if side.X ~= 0 then 2 else footprint,
				4,
				if side.Z ~= 0 then 2 else footprint
			),
			CFrame = CFrame.new(origin + side * half + Vector3.new(0, roofY + 2, 0)),
			Color = color:Lerp(Color3.new(0, 0, 0), 0.25),
			Material = Enum.Material.Brick,
			Parent = parent,
		})
	end

	-- The vehicle route: a ramp that switchbacks around the outside, with a
	-- flat landing at every corner so you do not clip the turn.
	local rampWidth = 16
	local outset = half + rampWidth * 0.5
	local corners = {
		Vector3.new(outset, 0, outset),
		Vector3.new(-outset, 0, outset),
		Vector3.new(-outset, 0, -outset),
		Vector3.new(outset, 0, -outset),
	}

	local runs = floors * 2
	local rise = roofY / runs
	local rampColor = color:Lerp(Color3.fromRGB(90, 90, 90), 0.4)

	for index = 0, runs - 1 do
		local fromCorner = corners[(index % 4) + 1]
		local toCorner = corners[((index + 1) % 4) + 1]

		ramp(
			origin + fromCorner + Vector3.new(0, index * rise, 0),
			origin + toCorner + Vector3.new(0, (index + 1) * rise, 0),
			rampWidth,
			rampColor,
			parent
		)

		Util.Part({
			Name = "RampLanding",
			Size = Vector3.new(rampWidth, SLAB, rampWidth),
			CFrame = CFrame.new(origin + toCorner + Vector3.new(0, (index + 1) * rise, 0)),
			Color = rampColor,
			Material = Enum.Material.Concrete,
			Parent = parent,
		})
	end

	-- Bridge the top of the ramp onto the roof.
	local topCorner = corners[(runs % 4) + 1]
	ramp(
		origin + topCorner + Vector3.new(0, roofY, 0),
		origin + topCorner * 0.4 + Vector3.new(0, roofY + SLAB * 0.5, 0),
		rampWidth,
		rampColor,
		parent
	)
end

-- =================================================================== PIECES ==

--[[
	A barricade: a long, low wall you can crouch behind and shoot over, with
	a sandbag look. Scattered thickly, because open ground is no fun on foot.
]]
local function barricade(origin: Vector3, heading: number, rng: Random, parent: Instance)
	local length = rng:NextNumber(18, 34)
	local height = rng:NextNumber(6, 9)
	local facing = CFrame.Angles(0, heading, 0)

	local wall = Util.Part({
		Name = "Barricade",
		Size = Vector3.new(length, height, 3.5),
		CFrame = CFrame.new(origin + Vector3.new(0, height * 0.5, 0)) * facing,
		Color = Color3.fromRGB(118, 106, 84),
		Material = Enum.Material.Sandstone,
		Parent = parent,
	})
	wall:SetAttribute("Destructible", true)

	-- A stack of sandbags along the top, so it reads as cover rather than
	-- a random slab.
	for bag = 0, 2 do
		local offset = -length * 0.3 + bag * (length * 0.3)
		Util.Part({
			Name = "Sandbag",
			Size = Vector3.new(length * 0.28, 2.4, 4.4),
			CFrame = CFrame.new(origin + Vector3.new(0, height + 1.2, 0)) * facing * CFrame.new(offset, 0, 0),
			Color = Color3.fromRGB(132, 118, 92),
			Material = Enum.Material.Sand,
			Parent = parent,
		})
	end
end

--[[
	Boost arrows: chevrons painted on the run-up to a jump. Drive over them
	and the vehicle is flung forward, which is what turns a ramp into real
	air rather than a gentle hop.
]]
local function boostArrows(origin: Vector3, direction: Vector3, parent: Instance)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	flat = if flat.Magnitude < 0.01 then Vector3.new(0, 0, 1) else flat.Unit

	-- Two chevrons, close in. Four spread over sixty studs was a long enough
	-- run-up to arrive at the ramp far too fast.
	for step = 1, 2 do
		local centre = origin - flat * (step * 11)
		-- Each chevron is two angled bars meeting at a point.
		for _, side in { -1, 1 } do
			local bar = Util.Part({
				Name = "BoostPad",
				Size = Vector3.new(3, 0.6, 9),
				CFrame = CFrame.lookAt(centre + Vector3.new(0, 1.1, 0), centre + flat)
					* CFrame.new(side * 4, 0, 0)
					* CFrame.Angles(0, side * math.rad(28), 0),
				Color = Color3.fromRGB(255, 190, 40),
				Material = Enum.Material.Neon,
				CanCollide = false,
				Parent = parent,
			})
			bar:SetAttribute("Boost", true)
		end
	end
end

--[[ A stunt jump: launch ramp, a real gap, and a landing ramp to catch you. ]]
local function stuntJump(origin: Vector3, direction: Vector3, scale: number, color: Color3, parent: Instance)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	flat = if flat.Magnitude < 0.01 then Vector3.new(0, 0, 1) else flat.Unit

	local launchLength = 40 * scale
	local launchHeight = 16 * scale
	local gap = 70 * scale
	local width = 26

	-- Chevrons on the run-up.
	boostArrows(origin, flat, parent)

	ramp(origin, origin + flat * launchLength + Vector3.new(0, launchHeight, 0), width, color, parent)

	-- A kicker at the top so the car leaves the ground cleanly.
	local lipCentre = origin + flat * (launchLength + 4) + Vector3.new(0, launchHeight + 1, 0)
	Util.Part({
		Name = "JumpLip",
		Size = Vector3.new(width, SLAB, 8),
		CFrame = CFrame.lookAt(lipCentre, lipCentre + flat) * CFrame.Angles(math.rad(-18), 0, 0),
		Color = color,
		Material = Enum.Material.DiamondPlate,
		Parent = parent,
	})

	local landingStart = origin + flat * (launchLength + gap)
	ramp(
		landingStart + Vector3.new(0, launchHeight * 0.75, 0),
		landingStart + flat * (launchLength * 1.4),
		width + 10,
		color,
		parent
	)
end

--[[ Roads. They give the map a shape you can learn and drive along fast. ]]
local function streets(size: number, parent: Instance)
	local half = size * 0.5
	local spacing = 190
	local roadWidth = 44
	local roadColor = Color3.fromRGB(58, 58, 62)

	local lanes = math.floor(size / spacing)
	local start = -(lanes - 1) * spacing * 0.5

	for index = 0, lanes - 1 do
		local offset = start + index * spacing

		-- One road running each way, crossing at the junctions.
		Util.Part({
			Name = "Street",
			Size = Vector3.new(roadWidth, 1, size),
			CFrame = CFrame.new(offset, 0.6, 0),
			Color = roadColor,
			Material = Enum.Material.Asphalt,
			Parent = parent,
		})
		Util.Part({
			Name = "Street",
			Size = Vector3.new(size, 1, roadWidth),
			CFrame = CFrame.new(0, 0.6, offset),
			Color = roadColor,
			Material = Enum.Material.Asphalt,
			Parent = parent,
		})

		-- Centre lines, so the roads read as roads at speed.
		Util.Part({
			Name = "Line",
			Size = Vector3.new(1.5, 1, size),
			CFrame = CFrame.new(offset, 1.15, 0),
			Color = Color3.fromRGB(210, 190, 90),
			Material = Enum.Material.SmoothPlastic,
			CanCollide = false,
			Parent = parent,
		})
		Util.Part({
			Name = "Line",
			Size = Vector3.new(size, 1, 1.5),
			CFrame = CFrame.new(0, 1.15, offset),
			Color = Color3.fromRGB(210, 190, 90),
			Material = Enum.Material.SmoothPlastic,
			CanCollide = false,
			Parent = parent,
		})
	end

	local _ = half
end

local function mudPatch(origin: Vector3, size: number, parent: Instance)
	Util.Part({
		Name = "Mud",
		Size = Vector3.new(size, 2, size),
		CFrame = CFrame.new(origin + Vector3.new(0, 0.5, 0)),
		Color = Color3.fromRGB(86, 64, 42),
		Material = Enum.Material.Mud,
		Parent = parent,
	})
end

local function cover(origin: Vector3, rng: Random, color: Color3, parent: Instance)
	local block = Util.Part({
		Name = "Cover",
		Size = Vector3.new(rng:NextNumber(8, 20), rng:NextNumber(6, 12), rng:NextNumber(8, 20)),
		CFrame = CFrame.new(origin) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0),
		Color = color:Lerp(Color3.fromRGB(60, 60, 60), rng:NextNumber(0, 0.5)),
		Material = Enum.Material.Concrete,
		Parent = parent,
	})
	block.CFrame = block.CFrame + Vector3.new(0, block.Size.Y * 0.5, 0)
	block:SetAttribute("Destructible", true)
end

--[[
	A real SpawnLocation for a team.

	Using Roblox's own spawn system rather than teleporting people around is
	what stops anybody ever appearing in mid-air: the engine will not place a
	character until it has one of these to place them on.
]]
local function teamSpawn(position: Vector3, teamColor: BrickColor, parent: Instance)
	local pad = Instance.new("SpawnLocation")
	pad.Name = "TeamSpawn"
	pad.Size = Vector3.new(14, 1, 14)
	pad.CFrame = CFrame.new(position)
	pad.Anchored = true
	pad.CanCollide = true
	pad.TeamColor = teamColor
	pad.Neutral = false
	pad.BrickColor = teamColor
	pad.Material = Enum.Material.Neon
	pad.Duration = 0
	pad.Parent = parent
	return pad
end

-- ==================================================================== BUILD ==

function MapService.Build(mapConfig: any, teamColors: { BrickColor }): MapBuild
	MapService.Clear()

	local model = Instance.new("Model")
	model.Name = "Arena"

	local size = mapConfig.Size
	local half = size * 0.5
	-- The same seed every time, so a map looks the way players remember it.
	local rng = Random.new(#mapConfig.Id * 7919)

	-- The floor. One flat slab, so nothing snags a wheel.
	Util.Part({
		Name = "Ground",
		Size = Vector3.new(size, 4, size),
		CFrame = CFrame.new(0, -2, 0),
		Color = mapConfig.Theme,
		Material = Enum.Material.Ground,
		Parent = model,
	})

	streets(size, model)

	-- Walls, so nobody drives off the edge of the world.
	local wallHeight = 160
	for _, side in { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) } do
		Util.Part({
			Name = "Boundary",
			Size = Vector3.new(
				if side.X ~= 0 then 8 else size + 16,
				wallHeight,
				if side.Z ~= 0 then 8 else size + 16
			),
			CFrame = CFrame.new(side * (half + 4) + Vector3.new(0, wallHeight * 0.5, 0)),
			Color = Color3.fromRGB(52, 52, 58),
			Material = Enum.Material.Metal,
			Transparency = 0.55,
			Parent = model,
		})
	end

	for _ = 1, math.floor(mapConfig.MudFraction * 26) do
		mudPatch(Util.RandomFlatPoint(half * 0.85, rng), rng:NextNumber(50, 130), model)
	end

	-- Buildings, spaced so their outside ramps never overlap.
	local placed: { Vector3 } = {}
	local attempts = 0
	while #placed < mapConfig.Buildings and attempts < mapConfig.Buildings * 30 do
		attempts += 1
		local spot = Util.RandomFlatPoint(half * 0.72, rng)
		local clear = true
		for _, other in placed do
			if (other - spot).Magnitude < 165 then
				clear = false
				break
			end
		end
		if clear then
			table.insert(placed, spot)
			building(spot, rng:NextNumber(50, 88), rng:NextInteger(2, 5), mapConfig.Theme, model)
		end
	end

	-- Sky bridges, so the rooftops are one connected level instead of islands.
	for index = 1, #placed - 1 do
		local a, b = placed[index], placed[index + 1]
		if (a - b).Magnitude < 280 then
			ramp(
				a + Vector3.new(0, 44, 0),
				b + Vector3.new(0, 44, 0),
				14,
				Color3.fromRGB(120, 116, 108),
				model
			)
		end
	end

	for _ = 1, mapConfig.Jumps do
		local heading = CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0).LookVector
		stuntJump(Util.RandomFlatPoint(half * 0.8, rng), heading, rng:NextNumber(0.8, 2.2), Color3.fromRGB(150, 120, 60), model)
	end

	for _ = 1, mapConfig.Ramps do
		local spot = Util.RandomFlatPoint(half * 0.85, rng)
		local heading = CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0).LookVector
		ramp(spot, spot + heading * rng:NextNumber(30, 60) + Vector3.new(0, rng:NextNumber(8, 22), 0), 18, Color3.fromRGB(130, 110, 70), model)
	end

	for _ = 1, 30 do
		cover(Util.RandomFlatPoint(half * 0.88, rng), rng, mapConfig.Theme, model)
	end

	-- Barricades, thickly. Somewhere to break line of sight is the difference
	-- between a firefight and being shot from across an empty field.
	for _ = 1, 70 do
		barricade(
			Util.RandomFlatPoint(half * 0.9, rng),
			rng:NextNumber(0, math.pi * 2),
			rng,
			model
		)
	end

	-- Team spawns at opposite ends, with real SpawnLocations on them.
	local teamSpawns: { [number]: { Vector3 } } = { {}, {} }
	for teamIndex = 1, 2 do
		local zSign = if teamIndex == 1 then -1 else 1
		local colour = teamColors[teamIndex] or BrickColor.new("Medium stone grey")
		for slot = 1, 6 do
			local x = -half * 0.35 + (slot - 1) * (half * 0.7 / 5)
			local position = Vector3.new(x, 4, zSign * half * 0.86)
			table.insert(teamSpawns[teamIndex], position)
			teamSpawn(position, colour, model)
		end
	end

	-- One tank, one plane, one torpedo and two turret trucks, always. They
	-- respawn on these same pads a while after they are wrecked.
	local vehiclePads = {}
	local bigVehicles = { "Tank", "Plane", "Torpedo", "TurretTruck", "TurretTruck" }
	for index, kind in bigVehicles do
		local angle = (index / #bigVehicles) * math.pi * 2
		-- Pulled in towards the middle so they are a short drive apart rather
		-- than a long walk.
		local position = Vector3.new(math.cos(angle) * half * 0.38, 4, math.sin(angle) * half * 0.38)
		table.insert(vehiclePads, { position = position, kind = kind })

		Util.Part({
			Name = "VehiclePad",
			Size = Vector3.new(40, 1, 40),
			CFrame = CFrame.new(position - Vector3.new(0, 3, 0)),
			Color = Color3.fromRGB(70, 90, 110),
			Material = Enum.Material.DiamondPlate,
			Parent = model,
		})
	end

	local pickupPads = {}
	local pickupKinds = { "Burger", "Fries", "Shield", "Ammo", "Burger", "Fries", "Shield", "Ammo" }
	for index, kind in pickupKinds do
		local angle = (index / #pickupKinds) * math.pi * 2 + 0.4
		table.insert(pickupPads, {
			position = Vector3.new(math.cos(angle) * half * 0.3, 4, math.sin(angle) * half * 0.3),
			kind = kind,
		})
	end

	-- The hidden ones. These go INSIDE buildings rather than out on the pads,
	-- so they are a reward for going in and looking rather than something you
	-- trip over crossing the map.
	local hiddenKinds = { "Health", "Invincibility", "DroneAmmo", "Health", "Invincibility", "DroneAmmo" }
	for index, spot in placed do
		local kind = hiddenKinds[((index - 1) % #hiddenKinds) + 1]
		table.insert(pickupPads, {
			-- Ground floor, tucked into a corner of the interior.
			position = spot + Vector3.new(rng:NextNumber(-14, 14), 6, rng:NextNumber(-14, 14)),
			kind = kind,
		})
	end

	model.Parent = workspace
	return {
		model = model,
		teamSpawns = teamSpawns,
		vehiclePads = vehiclePads,
		pickupPads = pickupPads,
	}
end

function MapService.Clear()
	local existing = workspace:FindFirstChild("Arena")
	if existing then
		existing:Destroy()
	end
end

return MapService
