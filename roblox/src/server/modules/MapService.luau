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
local ResortService = require(script.Parent:WaitForChild("ResortService"))

local MapService = {}

export type MapBuild = {
	model: Model,
	teamSpawns: { [number]: { Vector3 } },
	vehiclePads: { { position: Vector3, kind: string } },
	pickupPads: { { position: Vector3, kind: string, weapon: string? } },
	resort: ResortService.ResortBuild,
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
--[[
	A hollow building you can fight through.

	`vehicleRamp` decides whether it gets the switchback ramp around the
	outside. A tower with one needs a whole city block to itself; without it
	the footprint is all the room it takes, which is what makes it possible
	to put two low buildings in a block and get a dense street rather than
	a handful of islands.
]]
local function building(
	origin: Vector3,
	footprint: number,
	floors: number,
	color: Color3,
	parent: Instance,
	vehicleRamp: boolean?
)
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

	if vehicleRamp == false then
		return roofY
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

	return roofY
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

--[[
	The street grid.

	Roads are laid first and everything else is fitted into the blocks they
	leave, which is the whole difference between a city and a field with
	buildings dropped on it. Returns the grid offsets so the rest of the
	build can line up with them.
]]
local ROAD_WIDTH = 40

local function streets(size: number, pitch: number, offsets: { number }, parent: Instance)
	local roadColor = Color3.fromRGB(56, 56, 60)
	local kerbColor = Color3.fromRGB(150, 148, 142)

	for _, offset in offsets do
		-- The carriageway, both ways.
		for _, alongZ in { true, false } do
			Util.Part({
				Name = "Street",
				Size = if alongZ
					then Vector3.new(ROAD_WIDTH, 1, size)
					else Vector3.new(size, 1, ROAD_WIDTH),
				CFrame = if alongZ then CFrame.new(offset, 0.6, 0) else CFrame.new(0, 0.6, offset),
				Color = roadColor,
				Material = Enum.Material.Asphalt,
				Parent = parent,
			})

			-- Centre line, so the road reads as a road at speed.
			Util.Part({
				Name = "Line",
				Size = if alongZ then Vector3.new(1.6, 1, size) else Vector3.new(size, 1, 1.6),
				CFrame = if alongZ then CFrame.new(offset, 1.15, 0) else CFrame.new(0, 1.15, offset),
				Color = Color3.fromRGB(214, 194, 92),
				Material = Enum.Material.SmoothPlastic,
				CanCollide = false,
				Parent = parent,
			})

			-- Kerbs down both sides. Low enough to drive over, high enough
			-- to see, which is what makes the road feel like a road.
			for _, side in { -1, 1 } do
				local edge = offset + side * (ROAD_WIDTH * 0.5 + 2)
				Util.Part({
					Name = "Kerb",
					Size = if alongZ then Vector3.new(4, 1.6, size) else Vector3.new(size, 1.6, 4),
					CFrame = if alongZ then CFrame.new(edge, 1, 0) else CFrame.new(0, 1, edge),
					Color = kerbColor,
					Material = Enum.Material.Concrete,
					Parent = parent,
				})
			end
		end
	end

	-- Zebra crossings, at the interior intersections only and three stripes
	-- wide. It is the detail that stops a grid of grey strips reading as a
	-- car park, but five stripes on every junction of a large map is well
	-- over a thousand parts of paint for no extra legibility.
	for xi = 2, #offsets - 1 do
		for zi = 2, #offsets - 1 do
			local x, z = offsets[xi], offsets[zi]
			for _, axis in { true, false } do
				for stripe = -1, 1 do
					local slide = stripe * 7
					local reach = ROAD_WIDTH * 0.5 + 4
					Util.Part({
						Name = "Crossing",
						Size = if axis
							then Vector3.new(4, 1, reach)
							else Vector3.new(reach, 1, 4),
						CFrame = if axis
							then CFrame.new(x + slide, 1.15, z + (ROAD_WIDTH * 0.5 + reach * 0.5))
							else CFrame.new(x + (ROAD_WIDTH * 0.5 + reach * 0.5), 1.15, z + slide),
						Color = Color3.fromRGB(225, 225, 220),
						Material = Enum.Material.SmoothPlastic,
						CanCollide = false,
						Parent = parent,
					})
				end
			end
		end
	end

	-- Street lights, at every other junction and two to a junction. These
	-- carry a real PointLight, which is most of what makes a street look
	-- built rather than drawn -- and also the most expensive thing here, so
	-- there are tens of them rather than hundreds.
	for xi = 1, #offsets, 2 do
		for zi = 1, #offsets, 2 do
			local x, z = offsets[xi], offsets[zi]
			for _, corner in { Vector2.new(-1, -1), Vector2.new(1, 1) } do
				local base = Vector3.new(
					x + corner.X * (ROAD_WIDTH * 0.5 + 6),
					0,
					z + corner.Y * (ROAD_WIDTH * 0.5 + 6)
				)

				local post = Util.Part({
					Name = "LampPost",
					Size = Vector3.new(1, 26, 1),
					CFrame = CFrame.new(base + Vector3.new(0, 13, 0)),
					Color = Color3.fromRGB(70, 72, 76),
					Material = Enum.Material.Metal,
					Parent = parent,
				})

				local head = Util.Part({
					Name = "Lamp",
					Size = Vector3.new(3.5, 1.2, 3.5),
					CFrame = CFrame.new(base + Vector3.new(0, 26, 0)),
					Color = Color3.fromRGB(255, 240, 200),
					Material = Enum.Material.Neon,
					CanCollide = false,
					Parent = parent,
				})
				Util.Weld(post, head)

				local glow = Instance.new("PointLight")
				glow.Color = Color3.fromRGB(255, 236, 190)
				glow.Brightness = 1.8
				glow.Range = 52
				glow.Parent = head
			end
		end
	end
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

	-- ---------------------------------------------------------- the city grid
	--
	-- Roads first, then everything else fitted into the blocks they leave.
	-- Doing it the other way round is what produced the old maps, where
	-- buildings sat in the middle of the road and the streets led nowhere.
	-- The ring outside the city is where the resort lives now -- the lazy
	-- river runs right round it and the mountain sits in one corner -- so it
	-- has to be wide enough for a river channel and a mountain base, not
	-- just a flanking lane.
	local gridHalf = half - 250
	local blocksPerSide = math.max(3, math.floor((gridHalf * 2) / 172 + 0.5))
	local pitch = (gridHalf * 2) / blocksPerSide

	local offsets: { number } = {}
	for index = 0, blocksPerSide do
		table.insert(offsets, -gridHalf + pitch * index)
	end

	streets(size, pitch, offsets, model)

	-- The resort: the lazy river right round the city, the mountain in one
	-- corner, the ski run between them, the chairlift up the side. Built
	-- before the blocks are handed out so its footprint is known when the
	-- city is laid down.
	local resort = ResortService.Build(size, model)
	local resortReserved = ResortService.ReservedAreas(size)

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

	-- One block per square of the grid. The usable half-extent is what is
	-- left after the two half-roads either side and a strip of pavement, so
	-- by construction nothing placed inside a block can reach the asphalt.
	type Block = { center: Vector3, extent: number, role: string, roof: number }
	local blockExtent = pitch * 0.5 - ROAD_WIDTH * 0.5 - 7
	local blocks: { Block } = {}
	for xi = 1, blocksPerSide do
		for zi = 1, blocksPerSide do
			table.insert(blocks, {
				center = Vector3.new(
					(offsets[xi] + offsets[xi + 1]) * 0.5,
					0,
					(offsets[zi] + offsets[zi + 1]) * 0.5
				),
				extent = blockExtent,
				role = "yard",
				roof = 0,
			})
		end
	end

	-- Reservations, decided before anything is built.
	--
	--   the carnival      CarnivalService builds its own ground at 0.3 * size
	--   the spawn rows    both teams need to get out of their base without
	--                     being funnelled through a doorway
	local carnival = Vector3.new(size * 0.3, 0, 0)

	--[[ Is this block inside something the resort already owns? ]]
	local function insideResort(flat: Vector3): boolean
		for _, area in resortReserved do
			if (flat - Vector3.new(area.centre.X, 0, area.centre.Z)).Magnitude < area.radius then
				return true
			end
		end
		return false
	end
	local spawnReach = gridHalf - pitch * 0.9
	local available: { Block } = {}
	for _, block in blocks do
		local flat = Vector3.new(block.center.X, 0, block.center.Z)
		if (flat - carnival).Magnitude < 145 or insideResort(flat) then
			block.role = "reserved"
		elseif math.abs(block.center.Z) > spawnReach and math.abs(block.center.X) < half * 0.45 then
			block.role = "plaza" -- kept open: this is a team's way out of its base
		else
			table.insert(available, block)
		end
	end

	-- Shuffled with the map's own seed, so a given map always looks the same
	-- but no two maps share a skyline.
	for index = #available, 2, -1 do
		local swap = rng:NextInteger(1, index)
		available[index], available[swap] = available[swap], available[index]
	end

	-- How the blocks get used.
	--
	-- A tower needs a whole block, because its vehicle ramp wraps the
	-- outside. A row block holds two low buildings you enter on foot, which
	-- is how the map reaches the configured building count without either
	-- shrinking the blocks until trucks cannot turn or thinning the city out
	-- into islands. Whatever is left over is open ground, and the map needs
	-- that just as much: a city of nothing but buildings has no firefights
	-- in it, only corridors.
	local towerTarget = math.min(
		math.ceil(mapConfig.Buildings * 0.55),
		math.max(1, #available - 4)
	)
	local rowTarget = math.min(
		math.ceil((mapConfig.Buildings - towerTarget) / 2),
		math.max(0, #available - towerTarget - 3)
	)

	for index, block in available do
		if index <= towerTarget then
			block.role = "tower"
		elseif index <= towerTarget + rowTarget then
			block.role = "row"
		elseif index <= towerTarget + rowTarget + 3 then
			block.role = "plaza"
		else
			block.role = "yard"
		end
	end

	-- --------------------------------------------------------- fill the blocks
	local towers: { Block } = {}
	for _, block in blocks do
		if block.role == "tower" then
			-- A building plus its outside vehicle ramp has to fit the block.
			local footprint = math.clamp(
				rng:NextNumber(50, 88),
				34, -- below this the 22-stud doorway stops fitting
				(block.extent - 26) * 2
			)
			local floors = rng:NextInteger(2, 5)
			local spot = block.center + Vector3.new(
				rng:NextNumber(-6, 6),
				0,
				rng:NextNumber(-6, 6)
			)
			block.roof = building(spot, footprint, floors, mapConfig.Theme, model)
			block.center = spot
			table.insert(towers, block)
		elseif block.role == "row" then
			-- Two low buildings sharing a block, with a gap between them you
			-- can run down but not drive through. No outside ramp, so the
			-- roof is a foot-only sniper spot reached by the inside stairs.
			local footprint = math.min(48, block.extent - 10)
			local shift = block.extent - footprint * 0.5 - 2
			local alongX = rng:NextNumber() < 0.5
			for _, side in { -1, 1 } do
				local spot = block.center + if alongX
					then Vector3.new(side * shift * 0.5, 0, 0)
					else Vector3.new(0, 0, side * shift * 0.5)
				local roof = building(spot, footprint, rng:NextInteger(2, 3), mapConfig.Theme, model, false)
				table.insert(towers, {
					center = spot,
					extent = footprint * 0.5,
					role = "row",
					roof = roof,
				})
			end
		elseif block.role == "plaza" then
			-- Paved, open, and worth crossing: cover to fight around and a
			-- pickup in the middle.
			Util.Part({
				Name = "Plaza",
				Size = Vector3.new(block.extent * 2, 1, block.extent * 2),
				CFrame = CFrame.new(block.center + Vector3.new(0, 0.6, 0)),
				Color = Color3.fromRGB(128, 126, 120),
				Material = Enum.Material.Pavement,
				Parent = model,
			})
			local room = math.max(4, block.extent - 14)
			for _ = 1, 4 do
				cover(block.center + Vector3.new(
					rng:NextNumber(-room, room),
					0,
					rng:NextNumber(-room, room)
				), rng, mapConfig.Theme, model)
			end
		elseif block.role == "yard" then
			-- Mud and barricades. Open ground to fight across, which a city
			-- made only of buildings never gives you.
			if rng:NextNumber() < mapConfig.MudFraction then
				mudPatch(block.center, block.extent * rng:NextNumber(1.1, 1.7), model)
			end
			-- Pulled well inside the block: a barricade is up to 30 studs
			-- across, and one hanging over the kerb is an obstacle in the
			-- road rather than cover beside it.
			local room = math.max(4, block.extent - 30)
			for _ = 1, rng:NextInteger(3, 6) do
				barricade(
					block.center + Vector3.new(
						rng:NextNumber(-room, room),
						0,
						rng:NextNumber(-room, room)
					),
					rng:NextNumber(0, math.pi * 2),
					rng,
					model
				)
			end
		end
	end

	-- Sky bridges between neighbouring rooftops, so the roofs are a second
	-- level you can cross rather than a set of islands. Only between blocks
	-- that are actually adjacent, and drawn at the lower of the two roofs.
	local bridgeSpan = pitch * 1.35
	local bridged = 0
	for i = 1, #towers do
		for j = i + 1, #towers do
			local a, b = towers[i], towers[j]
			local gap = (a.center - b.center).Magnitude
			if gap < bridgeSpan and bridged < #towers then
				local deck = math.min(a.roof, b.roof)
				ramp(
					Vector3.new(a.center.X, deck, a.center.Z),
					Vector3.new(b.center.X, deck, b.center.Z),
					14,
					Color3.fromRGB(120, 116, 108),
					model
				)
				bridged += 1
				break
			end
		end
	end

	-- -------------------------------------------------------- street furniture
	--
	-- Jumps and ramps go ON the roads, pointed along them, because a jump you
	-- cannot reach at speed is just scenery.
	--[[
		Keep an along-the-street coordinate clear of the CROSSING streets.

		A point on the x = 200 road is still in the middle of a junction if
		its z happens to land on the z = 200 road, and that is how street
		furniture ends up blocking a road it was never placed on.
	]]
	local function clearOfJunctions(along: number): number
		local nearest = offsets[1]
		for _, lane in offsets do
			if math.abs(along - lane) < math.abs(along - nearest) then
				nearest = lane
			end
		end
		local gap = ROAD_WIDTH * 0.5 + 26
		local delta = along - nearest
		if math.abs(delta) < gap then
			return nearest + (if delta < 0 then -gap else gap)
		end
		return along
	end

	local function randomStreet(): (Vector3, Vector3)
		local lane = offsets[rng:NextInteger(1, #offsets)]
		local along = clearOfJunctions(rng:NextNumber(-gridHalf * 0.85, gridHalf * 0.85))
		if rng:NextNumber() < 0.5 then
			return Vector3.new(lane, 0, along), Vector3.new(0, 0, if along < 0 then 1 else -1)
		end
		return Vector3.new(along, 0, lane), Vector3.new(if along < 0 then 1 else -1, 0, 0)
	end

	for _ = 1, mapConfig.Jumps do
		local spot, heading = randomStreet()
		stuntJump(spot, heading, rng:NextNumber(0.8, 2.2), Color3.fromRGB(150, 120, 60), model)
	end

	for _ = 1, mapConfig.Ramps do
		local spot, heading = randomStreet()
		ramp(
			spot,
			spot + heading * rng:NextNumber(30, 60) + Vector3.new(0, rng:NextNumber(8, 22), 0),
			18,
			Color3.fromRGB(130, 110, 70),
			model
		)
	end

	-- Cover on the pavements, where you actually need it: crossing a street
	-- is the most exposed thing you do.
	for _ = 1, 26 do
		local spot, heading = randomStreet()
		-- Across the street, not along it: heading runs with the road, so
		-- swapping its components gives the pavement direction.
		local side = (if rng:NextNumber() < 0.5 then -1 else 1) * (ROAD_WIDTH * 0.5 + 18)
		cover(spot + Vector3.new(heading.Z, 0, heading.X) * side, rng, mapConfig.Theme, model)
	end

	-- The open ring outside the grid, so the map edge is not a dead zone.
	--
	-- A SQUARE ring, hugging the four edges. A circle of this radius looks
	-- right on paper and then cuts straight back through the city at the
	-- diagonals, dropping barricades in the middle of interior roads.
	local ringInset = ROAD_WIDTH * 0.5 + 24
	for _ = 1, 20 do
		local along = clearOfJunctions(rng:NextNumber(-gridHalf, gridHalf))
		local out = (if rng:NextNumber() < 0.5 then -1 else 1) * (gridHalf + ringInset)
		local spot = if rng:NextNumber() < 0.5
			then Vector3.new(along, 0, out)
			else Vector3.new(out, 0, along)
		barricade(spot, rng:NextNumber(0, math.pi * 2), rng, model)
	end

	-- Team spawns at opposite ends, out in the open ring, with real
	-- SpawnLocations on them.
	local teamSpawns: { [number]: { Vector3 } } = { {}, {} }
	for teamIndex = 1, 2 do
		local zSign = if teamIndex == 1 then -1 else 1
		local colour = teamColors[teamIndex] or BrickColor.new("Medium stone grey")
		for slot = 1, 6 do
			local x = -half * 0.35 + (slot - 1) * (half * 0.7 / 5)
			local position = Vector3.new(x, 4, zSign * (half - 24))
			table.insert(teamSpawns[teamIndex], position)
			teamSpawn(position, colour, model)
		end
	end

	-- --------------------------------------------------------------- the pads
	--
	-- Intersections, which is where you look for a vehicle in a city.
	local intersections: { Vector3 } = {}
	for _, x in offsets do
		for _, z in offsets do
			table.insert(intersections, Vector3.new(x, 4, z))
		end
	end
	for index = #intersections, 2, -1 do
		local swap = rng:NextInteger(1, index)
		intersections[index], intersections[swap] = intersections[swap], intersections[index]
	end

	local nextIntersection = 0
	local function takeIntersection(): Vector3
		nextIntersection += 1
		local spot = intersections[((nextIntersection - 1) % #intersections) + 1]
		-- Nudge repeats apart once the list wraps.
		local lap = math.floor((nextIntersection - 1) / #intersections)
		if lap == 0 then
			return spot
		end
		return spot + Vector3.new(
			rng:NextNumber(-ROAD_WIDTH * 0.4, ROAD_WIDTH * 0.4),
			0,
			rng:NextNumber(-ROAD_WIDTH * 0.4, ROAD_WIDTH * 0.4)
		)
	end

	-- One tank, one plane, one torpedo and two turret trucks, always. They
	-- respawn on these same pads a while after they are wrecked.
	local vehiclePads = {}
	local bigVehicles = {
		"Tank", "Plane", "TurretTruck", "TurretTruck",
		-- Rideable rockets, several of them, because they are the best thing
		-- on the map and one was never enough.
		"Torpedo", "Torpedo", "Torpedo", "Torpedo",
	}
	for _, kind in bigVehicles do
		local position = takeIntersection()
		table.insert(vehiclePads, { position = position, kind = kind })

		Util.Part({
			Name = "VehiclePad",
			Size = Vector3.new(34, 1, 34),
			CFrame = CFrame.new(position - Vector3.new(0, 3, 0)),
			Color = Color3.fromRGB(70, 90, 110),
			Material = Enum.Material.DiamondPlate,
			Parent = model,
		})
	end

	local pickupPads: { { position: Vector3, kind: string, weapon: string? } } = {}
	for _, kind in { "Burger", "Fries", "Shield", "Ammo", "Burger", "Fries", "Shield", "Ammo" } do
		table.insert(pickupPads, { position = takeIntersection(), kind = kind })
	end

	-- Guns, everywhere. Walk over one and it is in your hands.
	local scattered = {
		"RPG", "LandMine", "ClusterBomb", "Grenade", "StickyGrenade",
		"Drone", "Minigun", "AntiMaterial", "AutoShotgun", "Revolver",
		"MachineGun", "Sniper", "DiamondGun", "Deagle", "SMG", "Shotgun",
	}
	for index = 1, 34 do
		local spot = randomStreet()
		table.insert(pickupPads, {
			position = spot + Vector3.new(0, 4, 0),
			kind = "Weapon",
			weapon = scattered[((index - 1) % #scattered) + 1],
		})
	end

	-- Ammo, and the point multiplier, scattered just as freely.
	for _ = 1, 16 do
		table.insert(pickupPads, { position = randomStreet() + Vector3.new(0, 4, 0), kind = "Ammo" })
	end
	for _ = 1, 5 do
		table.insert(pickupPads, { position = takeIntersection(), kind = "Multiplier" })
	end

	-- The hidden ones. These go INSIDE buildings rather than out on the pads,
	-- so they are a reward for going in and looking rather than something you
	-- trip over crossing the map.
	local hiddenKinds = { "Health", "Invincibility", "DroneAmmo", "Health", "Invincibility", "DroneAmmo" }
	for index, tower in towers do
		table.insert(pickupPads, {
			-- Ground floor, tucked into a corner of the interior.
			position = tower.center + Vector3.new(rng:NextNumber(-14, 14), 6, rng:NextNumber(-14, 14)),
			kind = hiddenKinds[((index - 1) % #hiddenKinds) + 1],
		})
	end

	-- Resort gear, on the pads the resort picked out: tubes at the summit, at
	-- the foot of the ski run and round the river, and gliders at the top.
	for _, at in resort.tubePads do
		table.insert(vehiclePads, { position = at, kind = "Tube" })
	end
	for index, at in resort.skiPads do
		-- A glider beside the skis at the summit; the lower station gets one
		-- too, so being shot down is not the end of flying for the round.
		table.insert(vehiclePads, {
			position = at + Vector3.new(0, 2, 0),
			kind = if index == 1 then "Glider" else "Tube",
		})
	end

	-- Gear on the sniper towers, because climbing one should be worth it.
	for index, top in resort.towerTops do
		table.insert(pickupPads, {
			position = top + Vector3.new(0, 2, 0),
			kind = "Weapon",
			weapon = if index % 2 == 0 then "AntiMaterial" else "Sniper",
		})
	end

	-- And something at the summit, which is the longest climb on the map.
	table.insert(pickupPads, { position = resort.summit + Vector3.new(0, 3, -14), kind = "Multiplier" })

	model.Parent = workspace
	return {
		model = model,
		teamSpawns = teamSpawns,
		vehiclePads = vehiclePads,
		pickupPads = pickupPads,
		resort = resort,
	}
end

function MapService.Clear()
	local existing = workspace:FindFirstChild("Arena")
	if existing then
		existing:Destroy()
	end
end

return MapService
