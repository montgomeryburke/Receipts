--!strict
--[[
	MapService — builds the whole arena out of code.

	Nothing here is hand-modelled, which means you never have to open the
	3D editor to change a map: edit the numbers in Config.Maps and you get a
	different arena.

	The rule every piece obeys: YOU CAN DRIVE ON IT. No stairs anywhere, no
	kerbs to catch a wheel, every roof reachable by ramp, every jump built
	wide enough to hit at speed.
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

local RAMP_THICKNESS = 3
local ROAD_Y = 0.5

--[[
	A sloped slab connecting two points. This one function builds every ramp,
	every jump and every bridge in the game.
]]
local function ramp(from: Vector3, to: Vector3, width: number, color: Color3, parent: Instance): Part
	local delta = to - from
	local length = delta.Magnitude
	if length < 0.1 then
		length = 0.1
	end
	local mid = from + delta * 0.5

	-- CFrame.lookAt points the part's -Z at the target, and Size.Z runs along
	-- that axis, so a part sized (width, thickness, length) becomes the ramp.
	local orientation = CFrame.lookAt(mid, to)

	return Util.Part({
		Name = "Ramp",
		Size = Vector3.new(width, RAMP_THICKNESS, length),
		CFrame = orientation,
		Color = color,
		Material = Enum.Material.Concrete,
		Parent = parent,
	})
end

--[[
	A building you can drive up. It is a solid block with a ramp that
	switchbacks around the outside to a flat roof — so the roof is a
	legitimate fighting position you can arrive at in a truck.
]]
local function building(origin: Vector3, footprint: number, floors: number, color: Color3, parent: Instance)
	local floorHeight = 14
	local height = floors * floorHeight
	local half = footprint * 0.5

	-- The solid mass of the building.
	Util.Part({
		Name = "BuildingCore",
		Size = Vector3.new(footprint, height, footprint),
		CFrame = CFrame.new(origin + Vector3.new(0, height * 0.5, 0)),
		Color = color,
		Material = Enum.Material.Brick,
		Parent = parent,
	})

	-- A lip around the roof so you can take cover up there without rolling off.
	local lipHeight = 4
	for _, side in { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) } do
		Util.Part({
			Name = "RoofLip",
			Size = Vector3.new(
				if side.X ~= 0 then 2 else footprint,
				lipHeight,
				if side.Z ~= 0 then 2 else footprint
			),
			CFrame = CFrame.new(origin + side * half + Vector3.new(0, height + lipHeight * 0.5, 0)),
			Color = color:Lerp(Color3.new(0, 0, 0), 0.25),
			Material = Enum.Material.Brick,
			Parent = parent,
		})
	end

	-- The switchback ramp: one straight run per building side, climbing as it
	-- wraps, with a flat landing at each corner so you do not clip the turn.
	local rampWidth = 16
	local outset = half + rampWidth * 0.5
	local corners = {
		Vector3.new(outset, 0, outset),
		Vector3.new(-outset, 0, outset),
		Vector3.new(-outset, 0, -outset),
		Vector3.new(outset, 0, -outset),
	}

	local runs = floors * 2
	local rise = height / runs
	for index = 0, runs - 1 do
		local fromCorner = corners[(index % 4) + 1]
		local toCorner = corners[((index + 1) % 4) + 1]
		local fromY = index * rise
		local toY = (index + 1) * rise

		ramp(
			origin + fromCorner + Vector3.new(0, fromY, 0),
			origin + toCorner + Vector3.new(0, toY, 0),
			rampWidth,
			color:Lerp(Color3.fromRGB(90, 90, 90), 0.4),
			parent
		)

		-- Flat landing pad at the corner you are turning on.
		Util.Part({
			Name = "RampLanding",
			Size = Vector3.new(rampWidth, RAMP_THICKNESS, rampWidth),
			CFrame = CFrame.new(origin + toCorner + Vector3.new(0, toY, 0)),
			Color = color:Lerp(Color3.fromRGB(90, 90, 90), 0.4),
			Material = Enum.Material.Concrete,
			Parent = parent,
		})
	end

	-- Bridge the top of the ramp onto the roof itself.
	local topCorner = corners[(runs % 4) + 1]
	ramp(
		origin + topCorner + Vector3.new(0, height, 0),
		origin + topCorner * 0.45 + Vector3.new(0, height + RAMP_THICKNESS * 0.5, 0),
		rampWidth,
		color:Lerp(Color3.fromRGB(90, 90, 90), 0.4),
		parent
	)
end

--[[
	A stunt jump: a launch ramp, a gap, and a wide landing ramp angled to
	catch you. Hit it fast enough and you clear the gap; hit it slow and you
	land in the middle, which is funny for everyone else.
]]
local function stuntJump(origin: Vector3, direction: Vector3, scale: number, color: Color3, parent: Instance)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, 1)
	end
	flat = flat.Unit

	local launchLength = 40 * scale
	local launchHeight = 16 * scale
	local gap = 70 * scale
	local width = 26

	-- Up ramp.
	ramp(
		origin,
		origin + flat * launchLength + Vector3.new(0, launchHeight, 0),
		width,
		color,
		parent
	)

	-- A lip at the top so the car actually leaves the ground cleanly.
	-- Built with lookAt so it lines up with the ramp on diagonal jumps too,
	-- instead of sitting across it at an angle.
	local lipCentre = origin + flat * (launchLength + 4) + Vector3.new(0, launchHeight + 1, 0)
	Util.Part({
		Name = "JumpLip",
		Size = Vector3.new(width, RAMP_THICKNESS, 8),
		CFrame = CFrame.lookAt(lipCentre, lipCentre + flat) * CFrame.Angles(math.rad(-18), 0, 0),
		Color = color,
		Material = Enum.Material.DiamondPlate,
		Parent = parent,
	})

	-- Landing ramp on the far side of the gap, sloping down to meet you.
	local landingStart = origin + flat * (launchLength + gap)
	ramp(
		landingStart + Vector3.new(0, launchHeight * 0.75, 0),
		landingStart + flat * (launchLength * 1.4),
		width + 10,
		color,
		parent
	)
end

--[[ A patch of mud. Slows wheels down and takes craters when things explode. ]]
local function mudPatch(origin: Vector3, size: number, parent: Instance)
	Util.Part({
		Name = "Mud",
		Size = Vector3.new(size, 2, size),
		CFrame = CFrame.new(origin + Vector3.new(0, ROAD_Y, 0)),
		Color = Color3.fromRGB(86, 64, 42),
		Material = Enum.Material.Mud,
		Parent = parent,
	})
end

--[[ Low cover you can shoot over and ram through. ]]
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
	-- Tagged so explosions know they are allowed to blow this up.
	block:SetAttribute("Destructible", true)
end

--[[
	Build one map and hand back everywhere the rest of the game needs to know
	about: team spawns, vehicle pads and pickup pads.
]]
function MapService.Build(mapConfig: any): MapBuild
	MapService.Clear()

	local model = Instance.new("Model")
	model.Name = "Arena"

	local size = mapConfig.Size
	local half = size * 0.5
	-- Same seed every time, so a map always looks the way players remember it.
	local rng = Random.new(#mapConfig.Id * 7919)

	-- The floor. One big slab, perfectly flat, so nothing snags a wheel.
	Util.Part({
		Name = "Ground",
		Size = Vector3.new(size, 4, size),
		CFrame = CFrame.new(0, -2, 0),
		Color = mapConfig.Theme,
		Material = Enum.Material.Ground,
		Parent = model,
	})

	-- Walls, so nobody drives off the edge of the world.
	local wallHeight = 120
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

	-- Mud. The southern-mudding half of the game.
	local mudCount = math.floor(mapConfig.MudFraction * 26)
	for _ = 1, mudCount do
		mudPatch(Util.RandomFlatPoint(half * 0.85, rng), rng:NextNumber(50, 130), model)
	end

	-- Buildings, spaced out on a loose grid so their ramps never overlap.
	local buildingCount = mapConfig.Buildings
	local placed: { Vector3 } = {}
	local attempts = 0
	while #placed < buildingCount and attempts < buildingCount * 30 do
		attempts += 1
		local spot = Util.RandomFlatPoint(half * 0.72, rng)
		local footprint = rng:NextNumber(45, 85)
		local clear = true
		for _, other in placed do
			if (other - spot).Magnitude < 150 then
				clear = false
				break
			end
		end
		if clear then
			table.insert(placed, spot)
			building(spot, footprint, rng:NextInteger(2, 5), mapConfig.Theme, model)
		end
	end

	-- Sky bridges between nearby roofs, so the rooftops are a connected level
	-- rather than a set of islands.
	for index = 1, #placed - 1 do
		local a, b = placed[index], placed[index + 1]
		if (a - b).Magnitude < 260 then
			local bridgeY = 40
			ramp(
				a + Vector3.new(0, bridgeY, 0),
				b + Vector3.new(0, bridgeY, 0),
				14,
				Color3.fromRGB(120, 116, 108),
				model
			)
		end
	end

	-- Stunt jumps.
	for _ = 1, mapConfig.Jumps do
		local spot = Util.RandomFlatPoint(half * 0.8, rng)
		local heading = CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0).LookVector
		stuntJump(spot, heading, rng:NextNumber(0.8, 2.2), Color3.fromRGB(150, 120, 60), model)
	end

	-- Standalone ramps that just launch you somewhere useful.
	for _ = 1, mapConfig.Ramps do
		local spot = Util.RandomFlatPoint(half * 0.85, rng)
		local heading = CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0).LookVector
		ramp(spot, spot + heading * rng:NextNumber(30, 60) + Vector3.new(0, rng:NextNumber(8, 22), 0), 18, Color3.fromRGB(130, 110, 70), model)
	end

	-- Cover.
	for _ = 1, 30 do
		cover(Util.RandomFlatPoint(half * 0.88, rng), rng, mapConfig.Theme, model)
	end

	-- Team spawns: opposite ends of the map, spread along a line.
	local teamSpawns: { [number]: { Vector3 } } = { {}, {} }
	for teamIndex = 1, 2 do
		local zSign = if teamIndex == 1 then -1 else 1
		for slot = 1, 10 do
			local x = -half * 0.5 + (slot - 1) * (half / 9)
			table.insert(teamSpawns[teamIndex], Vector3.new(x, 6, zSign * half * 0.86))
		end
	end

	-- Vehicle pads. The big toys sit here and come back after they are wrecked.
	local vehiclePads = {}
	local vehicleKinds = { "TurretTruck", "Tank", "Plane", "Torpedo", "TurretTruck", "Plane" }
	for index, kind in vehicleKinds do
		local angle = (index / #vehicleKinds) * math.pi * 2
		local radius = half * 0.55
		local position = Vector3.new(math.cos(angle) * radius, 4, math.sin(angle) * radius)
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

	-- Pickup pads.
	local pickupPads = {}
	local pickupKinds = { "Burger", "Fries", "Shield", "Ammo", "Burger", "Fries", "Shield", "Ammo" }
	for index, kind in pickupKinds do
		local angle = (index / #pickupKinds) * math.pi * 2 + 0.4
		local radius = half * 0.3
		table.insert(pickupPads, {
			position = Vector3.new(math.cos(angle) * radius, 4, math.sin(angle) * radius),
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

--[[ Tear the current arena down before building the next one. ]]
function MapService.Clear()
	local existing = workspace:FindFirstChild("Arena")
	if existing then
		existing:Destroy()
	end
end

return MapService
