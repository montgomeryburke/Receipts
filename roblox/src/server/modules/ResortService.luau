--!strict
--[[
	Nuclear Mud Arena — the resort.

	A lazy river, a mountain, a ski run and a chairlift, built into every map
	alongside the city.

	The river is the point of it: it runs right round the outside of the city
	and it MOVES you, so it is a way to get from one fight to another without
	walking, and a place to be ambushed from a sniper tower while you do.
	Sniper towers with ladders sit along it, and one stretch runs through a
	cave where nobody can see you from above.

	The mountain sits in one corner. An off-road trail switchbacks up it for
	the Jeep, the Hummer and the G-Wagon; the far face is a ski run with
	table-top jumps down to the river, so you can come off the mountain on a
	tube and keep going round the river on the same tube. A chairlift runs up
	the side with carriers big enough to drive a car onto.

	It is built from ordinary parts rather than Roblox Terrain. Terrain water
	would give real swimming for free, but it is a separate API with its own
	failure modes, and the whole flow of the river has to be deterministic
	anyway -- the current is explicit FlowZone parts carrying a direction,
	which push tubes and swimmers alike. That is testable from a terminal;
	terrain buoyancy is not.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared:WaitForChild("Util"))

local ResortService = {}

export type ResortBuild = {
	-- Where a tube can be found, on the river and at the mountain top.
	tubePads: { Vector3 },
	-- Where the skis live: the summit.
	skiPads: { Vector3 },
	-- Chairlift boarding points, bottom first.
	liftStations: { Vector3 },
	-- The summit platform, for sniper spawns and the view.
	summit: Vector3,
	-- Sniper tower platforms, so pickups can be put on them.
	towerTops: { Vector3 },
}

local WATER_WIDTH = 46
local BANK = 10
local WALL_HEIGHT = 9
local WATER_LEVEL = 3

--[[
	One straight run of river.

	Floor, two banks, the water itself, and a flow zone. The flow zone is an
	invisible part tagged with the direction of travel; RiverService reads
	those and pushes whatever is inside them, which is what makes the river
	a river rather than a long puddle.
]]
local function riverRun(from: Vector3, to: Vector3, parent: Instance)
	local delta = to - from
	local length = delta.Magnitude
	if length < 1 then
		return
	end

	local middle = from + delta * 0.5
	local facing = CFrame.lookAt(middle, to)
	local direction = delta.Unit

	-- The bed. Slightly sunken, so the water sits in something.
	Util.Part({
		Name = "RiverBed",
		Size = Vector3.new(WATER_WIDTH + BANK * 2, 2, length),
		CFrame = facing,
		Color = Color3.fromRGB(96, 92, 76),
		Material = Enum.Material.Sand,
		Parent = parent,
	})

	-- Walls either side, low enough to shoot over from the water and high
	-- enough that you cannot simply walk out mid-river.
	for _, side in { -1, 1 } do
		Util.Part({
			Name = "RiverWall",
			Size = Vector3.new(BANK, WALL_HEIGHT, length),
			CFrame = facing * CFrame.new(side * (WATER_WIDTH + BANK) * 0.5, WALL_HEIGHT * 0.5, 0),
			Color = Color3.fromRGB(150, 146, 134),
			Material = Enum.Material.Concrete,
			Parent = parent,
		})
	end

	-- The water. Not solid: you ride a tube on it, or swim it on foot.
	Util.Part({
		Name = "RiverWater",
		Size = Vector3.new(WATER_WIDTH, WATER_LEVEL, length),
		CFrame = facing * CFrame.new(0, WATER_LEVEL * 0.5 + 1, 0),
		Color = Color3.fromRGB(70, 160, 200),
		Material = Enum.Material.Water,
		Transparency = 0.35,
		CanCollide = false,
		CanQuery = false,
		Parent = parent,
	})

	-- The current.
	local flow = Util.Part({
		Name = "FlowZone",
		Size = Vector3.new(WATER_WIDTH, 10, length),
		CFrame = facing * CFrame.new(0, 5, 0),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = true,
		Parent = parent,
	})
	flow:SetAttribute("FlowX", direction.X)
	flow:SetAttribute("FlowY", direction.Y)
	flow:SetAttribute("FlowZ", direction.Z)
end

--[[
	A roof over a stretch of river, and rock down both sides.

	Somewhere on the loop you cannot be seen from above or shot from the
	towers, which is the only thing that makes floating the long way round a
	real choice rather than a slow death.
]]
local function cave(from: Vector3, to: Vector3, parent: Instance)
	local delta = to - from
	local length = delta.Magnitude
	local middle = from + delta * 0.5
	local facing = CFrame.lookAt(middle, to)
	local span = WATER_WIDTH + BANK * 2

	Util.Part({
		Name = "CaveRoof",
		Size = Vector3.new(span + 14, 6, length),
		CFrame = facing * CFrame.new(0, 22, 0),
		Color = Color3.fromRGB(78, 72, 66),
		Material = Enum.Material.Rock,
		Parent = parent,
	})

	for _, side in { -1, 1 } do
		Util.Part({
			Name = "CaveWall",
			Size = Vector3.new(8, 20, length),
			CFrame = facing * CFrame.new(side * (span * 0.5 + 3), 12, 0),
			Color = Color3.fromRGB(70, 65, 60),
			Material = Enum.Material.Rock,
			Parent = parent,
		})
	end

	-- A few stalactites, so it reads as a cave and not a concrete underpass.
	for step = 1, 6 do
		local along = -length * 0.5 + (step / 7) * length
		Util.Part({
			Name = "Stalactite",
			Size = Vector3.new(3, 7, 3),
			CFrame = facing
				* CFrame.new(((step % 2) * 2 - 1) * 12, 15, along)
				* CFrame.Angles(0, 0, math.rad(8)),
			Shape = Enum.PartType.Block,
			Color = Color3.fromRGB(88, 82, 74),
			Material = Enum.Material.Rock,
			CanCollide = false,
			Parent = parent,
		})
	end
end

--[[
	A sniper tower: legs, a platform with a lip, and a climbable ladder.

	TrussPart is the ladder, because Roblox lets a Humanoid climb one with no
	code at all. A ladder built out of ordinary parts is just a wall.
]]
local function sniperTower(base: Vector3, height: number, parent: Instance): Vector3
	local platform = base + Vector3.new(0, height, 0)

	for _, corner in {
		Vector2.new(-1, -1), Vector2.new(1, -1),
		Vector2.new(-1, 1), Vector2.new(1, 1),
	} do
		Util.Part({
			Name = "TowerLeg",
			Size = Vector3.new(2.5, height, 2.5),
			CFrame = CFrame.new(base + Vector3.new(corner.X * 9, height * 0.5, corner.Y * 9)),
			Color = Color3.fromRGB(104, 98, 88),
			Material = Enum.Material.Metal,
			Parent = parent,
		})
	end

	Util.Part({
		Name = "TowerPlatform",
		Size = Vector3.new(26, 2, 26),
		CFrame = CFrame.new(platform),
		Color = Color3.fromRGB(128, 122, 110),
		Material = Enum.Material.DiamondPlate,
		Parent = parent,
	})

	-- A lip to crouch behind, open on one side so you can get on from the
	-- ladder without jumping over anything.
	for index, side in { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, -1) } do
		Util.Part({
			Name = "TowerLip",
			Size = Vector3.new(
				if side.X ~= 0 then 2 else 26,
				5,
				if side.Z ~= 0 then 2 else 26
			),
			CFrame = CFrame.new(platform + side * 12 + Vector3.new(0, 3.5, 0)),
			Color = Color3.fromRGB(112, 106, 96),
			Material = Enum.Material.Metal,
			Parent = parent,
		})
		local _ = index
	end

	local ladder = Instance.new("TrussPart")
	ladder.Name = "TowerLadder"
	ladder.Size = Vector3.new(2, height, 2)
	ladder.CFrame = CFrame.new(base + Vector3.new(0, height * 0.5, 13))
	ladder.Anchored = true
	ladder.Color = Color3.fromRGB(150, 140, 60)
	ladder.Parent = parent

	return platform + Vector3.new(0, 2, 0)
end

--[[
	The mountain.

	Stepped rings rather than a smooth cone, because a stack of wide flat
	terraces is something you can drive on, park on and fight over, and a
	smooth slope is something you slide off. The steps are shallow enough
	that a Jeep takes them at speed.
]]
local function mountain(centre: Vector3, radius: number, height: number, parent: Instance)
	local steps = 9
	for ring = 0, steps - 1 do
		local fraction = ring / steps
		local ringRadius = radius * (1 - fraction * 0.82)
		local ringY = height * fraction
		local thickness = height / steps + 2

		Util.Part({
			Name = "MountainStep",
			Size = Vector3.new(ringRadius * 2, thickness, ringRadius * 2),
			CFrame = CFrame.new(centre + Vector3.new(0, ringY + thickness * 0.5, 0))
				-- Each terrace turned a little, so the silhouette is not a
				-- stack of identical squares.
				* CFrame.Angles(0, math.rad(ring * 11), 0),
			Color = Color3.fromRGB(96, 104, 92):Lerp(Color3.fromRGB(235, 240, 248), fraction * 0.8),
			Material = if fraction > 0.55 then Enum.Material.Snow else Enum.Material.Slate,
			Parent = parent,
		})
	end

	-- The summit platform: flat, snowy, and the best view on the map.
	local summitY = height + 2
	Util.Part({
		Name = "Summit",
		Size = Vector3.new(radius * 0.5, 4, radius * 0.5),
		CFrame = CFrame.new(centre + Vector3.new(0, summitY, 0)),
		Color = Color3.fromRGB(240, 246, 252),
		Material = Enum.Material.Snow,
		Parent = parent,
	})

	return centre + Vector3.new(0, summitY + 2, 0)
end

--[[
	The off-road trail: a switchback road cut round the mountain.

	Wide and banked, because the point is to drive a G-Wagon up it under fire
	rather than to thread a needle.
]]
local function offRoadTrail(centre: Vector3, radius: number, height: number, parent: Instance)
	local legs = 10
	local trailWidth = 26

	for leg = 0, legs - 1 do
		local fromAngle = (leg / legs) * math.pi * 2.4
		local toAngle = ((leg + 1) / legs) * math.pi * 2.4
		local fromRadius = radius * (0.95 - (leg / legs) * 0.55)
		local toRadius = radius * (0.95 - ((leg + 1) / legs) * 0.55)

		local from = centre + Vector3.new(
			math.cos(fromAngle) * fromRadius,
			(leg / legs) * height,
			math.sin(fromAngle) * fromRadius
		)
		local to = centre + Vector3.new(
			math.cos(toAngle) * toRadius,
			((leg + 1) / legs) * height,
			math.sin(toAngle) * toRadius
		)

		local delta = to - from
		local length = delta.Magnitude
		Util.Part({
			Name = "TrailSegment",
			Size = Vector3.new(trailWidth, 2.5, length),
			CFrame = CFrame.lookAt(from + delta * 0.5, to),
			Color = Color3.fromRGB(104, 88, 66),
			Material = Enum.Material.Ground,
			Parent = parent,
		})

		-- A landing pad at every corner, or you clip the turn and go over.
		Util.Part({
			Name = "TrailCorner",
			Size = Vector3.new(trailWidth, 2.5, trailWidth),
			CFrame = CFrame.new(to),
			Color = Color3.fromRGB(110, 94, 70),
			Material = Enum.Material.Ground,
			Parent = parent,
		})
	end
end

--[[
	A table-top jump: up a kicker, across a flat deck, off the far lip.

	The flat top is what makes it a table top rather than a ramp, and it is
	what gives you time in the air to actually do something -- which is the
	whole point of putting them down a ski run.
]]
local function tableTop(centre: Vector3, heading: Vector3, scale: number, parent: Instance)
	local flat = Vector3.new(heading.X, 0, heading.Z)
	flat = if flat.Magnitude < 0.01 then Vector3.new(0, 0, 1) else flat.Unit
	local lift = 9 * scale
	local deck = 20 * scale
	local width = 34

	local facing = CFrame.lookAt(centre, centre + flat)

	-- The run-up kicker.
	Util.Part({
		Name = "JumpKicker",
		Size = Vector3.new(width, 2.5, 22 * scale),
		CFrame = facing
			* CFrame.new(0, lift * 0.5, -(deck * 0.5 + 11 * scale))
			* CFrame.Angles(math.rad(-16), 0, 0),
		Color = Color3.fromRGB(236, 242, 250),
		Material = Enum.Material.Snow,
		Parent = parent,
	})

	-- The deck.
	Util.Part({
		Name = "JumpDeck",
		Size = Vector3.new(width, 2.5, deck),
		CFrame = facing * CFrame.new(0, lift, 0),
		Color = Color3.fromRGB(240, 246, 252),
		Material = Enum.Material.Snow,
		Parent = parent,
	})

	-- The lip you leave from.
	local lip = Util.Part({
		Name = "JumpLip",
		Size = Vector3.new(width, 2.5, 12 * scale),
		CFrame = facing
			* CFrame.new(0, lift + 1.6, deck * 0.5 + 6 * scale)
			* CFrame.Angles(math.rad(13), 0, 0),
		Color = Color3.fromRGB(246, 250, 255),
		Material = Enum.Material.Snow,
		Parent = parent,
	})
	-- Tagged so the trick scorer knows you left a jump rather than tripped
	-- off a kerb.
	lip:SetAttribute("TrickLaunch", true)
end

--[[
	The ski run.

	One long piste from the summit down to the river, with table tops spaced
	along it. Long on purpose: the brief was that you should be able to find
	a fight while you are on the way down, and a short run is a cutscene.

	It finishes level with the water, so a tube coming off the bottom carries
	straight into the river and keeps going.
]]
local function skiRun(
	summit: Vector3,
	finish: Vector3,
	parent: Instance
): { Vector3 }
	local segments = 9
	local jumps: { Vector3 } = {}
	local width = 70

	local previous = summit
	for step = 1, segments do
		local fraction = step / segments
		-- Eased, so it is steep at the top and runs out flat at the bottom.
		local eased = 1 - (1 - fraction) * (1 - fraction)
		local here = Vector3.new(
			summit.X + (finish.X - summit.X) * fraction,
			summit.Y + (finish.Y - summit.Y) * eased,
			summit.Z + (finish.Z - summit.Z) * fraction
		)

		local delta = here - previous
		local length = delta.Magnitude
		if length > 1 then
			Util.Part({
				Name = "Piste",
				Size = Vector3.new(width, 3, length),
				CFrame = CFrame.lookAt(previous + delta * 0.5, here),
				Color = Color3.fromRGB(242, 248, 254),
				Material = Enum.Material.Snow,
				Parent = parent,
			})

			-- Edges, so you can lean on them instead of falling off the side
			-- of the mountain every time somebody shoots at you.
			for _, side in { -1, 1 } do
				local across = Vector3.new(-delta.Unit.Z, 0, delta.Unit.X)
				Util.Part({
					Name = "PisteEdge",
					Size = Vector3.new(5, 7, length),
					CFrame = CFrame.lookAt(previous + delta * 0.5, here)
						* CFrame.new(side * (width * 0.5 + 2), 2, 0),
					Color = Color3.fromRGB(224, 232, 242),
					Material = Enum.Material.Snow,
					Parent = parent,
				})
				local _ = across
			end

			-- A table top on most segments, bigger lower down where you have
			-- the speed to clear them.
			if step >= 2 and step <= segments - 1 then
				local jumpAt = previous + delta * 0.55
				tableTop(jumpAt, delta.Unit, 0.8 + fraction * 0.9, parent)
				table.insert(jumps, jumpAt)
			end
		end

		previous = here
	end

	return jumps
end

--[[
	The chairlift.

	Towers, a cable, and carriers wide enough to drive a car onto -- the
	brief asked for that specifically, and it is the thing that makes the
	mountain worth having: you can take a G-Wagon up and bring it down the
	ski run.

	The carriers themselves are built and moved by LiftService; this lays
	down the structure and hands back the two stations.
]]
local function chairlift(bottom: Vector3, top: Vector3, parent: Instance): { Vector3 }
	local delta = top - bottom
	local towers = 6

	for index = 0, towers do
		local fraction = index / towers
		local footBase = bottom + delta * fraction
		-- Towers stand on the ground, so only the cable follows the climb.
		local towerHeight = 34 + fraction * 10
		Util.Part({
			Name = "LiftTower",
			Size = Vector3.new(4, towerHeight, 4),
			CFrame = CFrame.new(footBase + Vector3.new(0, towerHeight * 0.5, 0)),
			Color = Color3.fromRGB(96, 100, 108),
			Material = Enum.Material.Metal,
			Parent = parent,
		})

		-- The arm the cable hangs from.
		Util.Part({
			Name = "LiftArm",
			Size = Vector3.new(16, 2, 2),
			CFrame = CFrame.new(footBase + Vector3.new(0, towerHeight, 0)),
			Color = Color3.fromRGB(110, 114, 122),
			Material = Enum.Material.Metal,
			CanCollide = false,
			Parent = parent,
		})
	end

	-- The cable, in one run per span so it follows the slope.
	for index = 0, towers - 1 do
		local a = bottom + delta * (index / towers) + Vector3.new(0, 34 + (index / towers) * 10, 0)
		local b = bottom + delta * ((index + 1) / towers)
			+ Vector3.new(0, 34 + ((index + 1) / towers) * 10, 0)
		local span = b - a
		Util.Part({
			Name = "LiftCable",
			Size = Vector3.new(0.7, 0.7, span.Magnitude),
			CFrame = CFrame.lookAt(a + span * 0.5, b),
			Color = Color3.fromRGB(40, 42, 46),
			Material = Enum.Material.Metal,
			CanCollide = false,
			Parent = parent,
		})
	end

	-- Boarding decks at both ends, flat and wide enough to drive onto.
	local stations: { Vector3 } = {}
	for _, at in { bottom, top } do
		Util.Part({
			Name = "LiftStation",
			Size = Vector3.new(48, 3, 48),
			CFrame = CFrame.new(at + Vector3.new(0, 1.5, 0)),
			Color = Color3.fromRGB(122, 118, 110),
			Material = Enum.Material.DiamondPlate,
			Parent = parent,
		})
		table.insert(stations, at + Vector3.new(0, 4, 0))
	end

	return stations
end

-- ==================================================================== BUILD ==

--[[
	Build the whole resort for a map of this size.

	Laid out in the open ring around the city: the river runs right round it,
	the mountain sits in one corner, and the ski run comes down the mountain
	straight into the river so a tube carries on without stopping.

	MapService reserves the corner the mountain lands on, the same way it
	reserves the carnival, so no building is ever put inside it.
]]
function ResortService.Build(mapSize: number, parent: Instance): ResortBuild
	local half = mapSize * 0.5
	-- The river sits in the middle of the ring, clear of both the city and
	-- the boundary wall.
	local ringRadius = half - 118

	-- Four corners of the loop, rounded off by cutting the corners.
	local cut = ringRadius * 0.42
	local loop: { Vector3 } = {
		Vector3.new(-ringRadius + cut, 0, -ringRadius),
		Vector3.new(ringRadius - cut, 0, -ringRadius),
		Vector3.new(ringRadius, 0, -ringRadius + cut),
		Vector3.new(ringRadius, 0, ringRadius - cut),
		Vector3.new(ringRadius - cut, 0, ringRadius),
		Vector3.new(-ringRadius + cut, 0, ringRadius),
		Vector3.new(-ringRadius, 0, ringRadius - cut),
		Vector3.new(-ringRadius, 0, -ringRadius + cut),
	}

	for index = 1, #loop do
		local from = loop[index]
		local to = loop[(index % #loop) + 1]
		riverRun(from, to, parent)
	end

	-- One stretch runs through a cave: the only part of the loop that cannot
	-- be seen into from above or shot at from the towers.
	cave(loop[6], loop[7], parent)

	-- Sniper towers overlooking the water, pulled in off the bank so they
	-- cover the river rather than stand in it.
	local towerTops: { Vector3 } = {}
	for _, at in {
		Vector3.new(-ringRadius + 60, 0, -ringRadius + 62),
		Vector3.new(ringRadius - 62, 0, -ringRadius + 60),
		Vector3.new(ringRadius - 60, 0, ringRadius - 62),
	} do
		table.insert(towerTops, sniperTower(at, 46 + (#towerTops * 8), parent))
	end

	-- The mountain, in the corner the towers leave free.
	local mountainCentre = Vector3.new(-ringRadius * 0.74, 0, ringRadius * 0.74)
	local mountainRadius = math.min(220, ringRadius * 0.62)
	local mountainHeight = 170
	local summit = mountain(mountainCentre, mountainRadius, mountainHeight, parent)
	offRoadTrail(mountainCentre, mountainRadius, mountainHeight, parent)

	-- The ski run comes off the summit and finishes in the water, so you can
	-- ride a tube off the mountain and straight into the river.
	local riverEntry = Vector3.new(-ringRadius, WATER_LEVEL, 0)
	local jumps = skiRun(summit, riverEntry, parent)

	-- The chairlift runs up the other side, with decks you can drive onto.
	local liftBottom = mountainCentre + Vector3.new(mountainRadius * 1.05, 0, -mountainRadius * 0.5)
	local liftStations = chairlift(liftBottom, summit + Vector3.new(0, -2, 0), parent)

	-- Tubes: at the summit, at the bottom of the ski run, and a couple round
	-- the loop so the river is usable without climbing anything.
	local tubePads: { Vector3 } = {
		summit + Vector3.new(14, 4, 0),
		riverEntry + Vector3.new(0, 8, 40),
		Vector3.new(0, 8, -ringRadius),
		Vector3.new(ringRadius, 8, 0),
		Vector3.new(0, 8, ringRadius),
	}

	-- Skis live at the top, next to the tubes.
	local skiPads: { Vector3 } = {
		summit + Vector3.new(-14, 4, 0),
		summit + Vector3.new(-14, 4, 16),
		liftStations[2] + Vector3.new(0, 0, 14),
	}

	local _ = jumps

	return {
		tubePads = tubePads,
		skiPads = skiPads,
		liftStations = liftStations,
		summit = summit,
		towerTops = towerTops,
	}
end

--[[
	Where the mountain lands, so MapService can keep buildings out of it.

	Returned rather than hardcoded in both places, because the two drifting
	apart is how you end up with a tower block inside a mountain.
]]
function ResortService.ReservedAreas(mapSize: number): { { centre: Vector3, radius: number } }
	local half = mapSize * 0.5
	local ringRadius = half - 118
	local mountainRadius = math.min(220, ringRadius * 0.62)

	return {
		{
			centre = Vector3.new(-ringRadius * 0.74, 0, ringRadius * 0.74),
			radius = mountainRadius + 40,
		},
		-- The ski run's landing, which crosses from the mountain to the water.
		{
			centre = Vector3.new(-ringRadius * 0.86, 0, ringRadius * 0.34),
			radius = 110,
		},
	}
end

return ResortService
