--!strict
--[[
	Nuclear Mud Arena — the ice rink.

	A full rink with boards, two goals and a puck, dropped into the map
	alongside the city and the resort. You can play actual hockey on it:
	shoot the puck, score goals, and the goals are worth team points like
	anything else.

	You are also still armed. That is the rule for every sport here and it is
	not suspended on the ice -- a hockey game where the other team can shoot
	you is simply a better hockey game. Fights work the way Blades of Steel
	did: hit an opposing player with your stick and it turns into a scrap,
	both of you mashing a key, and the winner can break their stick over the
	loser and keep the splintered half as a weapon.

	The ice itself is a low-friction surface, so skating is a matter of
	momentum rather than walking, and a car driven onto it is a disaster in
	the best way.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Signal = require(Shared:WaitForChild("Signal"))
local Sound = require(Shared:WaitForChild("Sound"))
local Util = require(Shared:WaitForChild("Util"))

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
-- Required, and it was not. TeamService.IndexOf is called when a goal goes
-- in, so without this every single goal threw "attempt to index nil" inside
-- the Heartbeat connection and took the whole hockey step down with it.
local TeamService = require(script.Parent:WaitForChild("TeamService"))
local ArcadeService = require(script.Parent:WaitForChild("ArcadeService"))

local HockeyService = {}

--[[ Fired as (scorer, teamIndex, points) when the puck goes in. ]]
HockeyService.Goal = Signal.new()

--[[ Fired as (winner, loser, brokeStick) when a fight is settled. ]]
HockeyService.FightOver = Signal.new()

--[[
	Who has the puck, and where they may not pick it up again yet.

	Possession is the whole difference between a rink and a rink with a
	puck lying on it: you carry it, you can be checked off it, and you shoot
	it where you are looking. Before this the puck was only ever something to
	shoot at from a distance.
]]
local puckOwner: Player? = nil
local pickupBlockedUntil: { [Player]: number } = {}
local goalLights: { [number]: BasePart } = {}
local penaltyBox = Vector3.new()

local RINK_LENGTH = 300
local RINK_WIDTH = 150
local BOARD_HEIGHT = 11
local CORNER_SEGMENTS = 4

local rink: Model? = nil
local puck: BasePart? = nil
local puckHome = Vector3.new()
local goalZones: { { part: Part, defendingTeam: number } } = {}
local lastGoalAt = 0

type Fight = {
	a: Player,
	b: Player,
	endsAt: number,
	health: { [Player]: number },
	blocking: { [Player]: boolean },
}
local fights: { Fight } = {}
local fightOf: { [Player]: Fight } = {}

-- ================================================================= GEOMETRY ==

--[[
	The boards.

	Straight runs down the sides and ends, with the corners cut across in
	short segments. A rink with square corners reads as a swimming pool.
]]
local function boards(centre: Vector3, parent: Instance)
	local halfLength = RINK_LENGTH * 0.5
	local halfWidth = RINK_WIDTH * 0.5
	local cornerCut = 46

	local function board(from: Vector3, to: Vector3)
		local delta = to - from
		local length = delta.Magnitude
		if length < 1 then
			return
		end
		local middle = from + delta * 0.5
		local facing = CFrame.lookAt(middle, to)

		Util.Part({
			Name = "Boards",
			Size = Vector3.new(3, BOARD_HEIGHT, length),
			CFrame = facing * CFrame.new(0, BOARD_HEIGHT * 0.5, 0),
			Color = Color3.fromRGB(236, 240, 246),
			Material = Enum.Material.SmoothPlastic,
			Parent = parent,
		})

		-- The kick plate along the bottom, in team-neutral yellow, which is
		-- what every rink has and what makes it read as a rink.
		Util.Part({
			Name = "KickPlate",
			Size = Vector3.new(3.4, 2, length),
			CFrame = facing * CFrame.new(0, 1, 0),
			Color = Color3.fromRGB(240, 196, 40),
			Material = Enum.Material.SmoothPlastic,
			Parent = parent,
		})

		-- Glass above it, low enough to shoot over from outside but high
		-- enough to keep the puck in.
		Util.Part({
			Name = "RinkGlass",
			Size = Vector3.new(1.2, 9, length),
			CFrame = facing * CFrame.new(0, BOARD_HEIGHT + 4.5, 0),
			Color = Color3.fromRGB(200, 226, 240),
			Material = Enum.Material.Glass,
			Transparency = 0.72,
			Reflectance = 0.2,
			Parent = parent,
		})
	end

	-- The eight points of a rounded rectangle, walked in order.
	local outline = {
		Vector3.new(-halfWidth, 0, -halfLength + cornerCut),
		Vector3.new(-halfWidth + cornerCut, 0, -halfLength),
		Vector3.new(halfWidth - cornerCut, 0, -halfLength),
		Vector3.new(halfWidth, 0, -halfLength + cornerCut),
		Vector3.new(halfWidth, 0, halfLength - cornerCut),
		Vector3.new(halfWidth - cornerCut, 0, halfLength),
		Vector3.new(-halfWidth + cornerCut, 0, halfLength),
		Vector3.new(-halfWidth, 0, halfLength - cornerCut),
	}

	local cornerArcs = {
		[1] = { pivot = Vector3.new(-halfWidth + cornerCut, 0, -halfLength + cornerCut), a0 = math.pi, a1 = math.pi * 1.5 },
		[3] = { pivot = Vector3.new(halfWidth - cornerCut, 0, -halfLength + cornerCut), a0 = math.pi * 1.5, a1 = math.pi * 2 },
		[5] = { pivot = Vector3.new(halfWidth - cornerCut, 0, halfLength - cornerCut), a0 = 0, a1 = math.pi * 0.5 },
		[7] = { pivot = Vector3.new(-halfWidth + cornerCut, 0, halfLength - cornerCut), a0 = math.pi * 0.5, a1 = math.pi },
	}

	for index = 1, #outline do
		local arc = cornerArcs[index]
		if arc then
			for step = 0, CORNER_SEGMENTS - 1 do
				local angA = arc.a0 + (arc.a1 - arc.a0) * (step / CORNER_SEGMENTS)
				local angB = arc.a0 + (arc.a1 - arc.a0) * ((step + 1) / CORNER_SEGMENTS)
				local a = centre + arc.pivot + Vector3.new(math.cos(angA) * cornerCut, 0, math.sin(angA) * cornerCut)
				local b = centre + arc.pivot + Vector3.new(math.cos(angB) * cornerCut, 0, math.sin(angB) * cornerCut)
				board(a, b)
			end
		else
			local from = centre + outline[index]
			local to = centre + outline[(index % #outline) + 1]
			board(from, to)
		end
	end
end

--[[ A goal: frame, crossbar, netting, and the zone that counts it. ]]
local function goal(centre: Vector3, facingZ: number, defendingTeam: number, parent: Instance)
	local width = 26
	local height = 15
	local depth = 14
	local rawColour = Config.Teams[defendingTeam] and Config.Teams[defendingTeam].Color
	local colour = if typeof(rawColour) == "BrickColor"
		then rawColour.Color
		elseif typeof(rawColour) == "Color3" then rawColour
		else Color3.fromRGB(200, 60, 60)

	-- Posts and crossbar.
	for _, side in { -1, 1 } do
		Util.Part({
			Name = "GoalPost",
			Size = Vector3.new(1.6, height, 1.6),
			CFrame = CFrame.new(centre + Vector3.new(side * width * 0.5, height * 0.5, 0)),
			Color = colour,
			Material = Enum.Material.Metal,
			Parent = parent,
		})
	end
	Util.Part({
		Name = "GoalBar",
		Size = Vector3.new(width + 1.6, 1.6, 1.6),
		CFrame = CFrame.new(centre + Vector3.new(0, height, 0)),
		Color = colour,
		Material = Enum.Material.Metal,
		Parent = parent,
	})

	-- Netting: a back and two sides, thin and see-through.
	Util.Part({
		Name = "GoalNet",
		Size = Vector3.new(width, height, 0.5),
		CFrame = CFrame.new(centre + Vector3.new(0, height * 0.5, facingZ * depth)),
		Color = Color3.fromRGB(230, 235, 240),
		Material = Enum.Material.Fabric,
		Transparency = 0.45,
		Parent = parent,
	})
	for _, side in { -1, 1 } do
		Util.Part({
			Name = "GoalNet",
			Size = Vector3.new(0.5, height, depth),
			CFrame = CFrame.new(centre + Vector3.new(side * width * 0.5, height * 0.5, facingZ * depth * 0.5)),
			Color = Color3.fromRGB(230, 235, 240),
			Material = Enum.Material.Fabric,
			Transparency = 0.45,
			Parent = parent,
		})
	end

	-- The lamp behind the net, which is the whole drama of a goal.
	local lamp = Util.Part({
		Name = "GoalLight",
		Size = Vector3.new(4, 4, 4),
		CFrame = CFrame.new(centre + Vector3.new(0, height + 6, facingZ * (depth + 4))),
		Shape = Enum.PartType.Ball,
		Color = Color3.fromRGB(70, 14, 14),
		Material = Enum.Material.Neon,
		Parent = parent,
	})
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 40, 40)
	glow.Brightness = 0
	glow.Range = 60
	glow.Parent = lamp
	goalLights[defendingTeam] = lamp

	-- The goal line, painted.
	Util.Part({
		Name = "GoalLine",
		Size = Vector3.new(width + 10, 0.2, 1.4),
		CFrame = CFrame.new(centre + Vector3.new(0, 1.1, 0)),
		Color = Color3.fromRGB(210, 50, 50),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		Parent = parent,
	})

	-- And the zone that actually counts it. Not solid, or the puck would
	-- bounce off the thing meant to detect it.
	local zone = Util.Part({
		Name = "GoalZone",
		Size = Vector3.new(width - 2, height - 2, depth),
		CFrame = CFrame.new(centre + Vector3.new(0, height * 0.5, facingZ * depth * 0.5)),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		Parent = parent,
	})
	zone:SetAttribute("DefendingTeam", defendingTeam)
	table.insert(goalZones, { part = zone, defendingTeam = defendingTeam })
end

--[[ The ice, the lines and the face-off circles. ]]
local function surface(centre: Vector3, parent: Instance)
	local ice = Util.Part({
		Name = "Ice",
		Size = Vector3.new(RINK_WIDTH, 2, RINK_LENGTH),
		CFrame = CFrame.new(centre + Vector3.new(0, 0, 0)),
		Color = Color3.fromRGB(240, 248, 255),
		Material = Enum.Material.Ice,
		Reflectance = 0.14,
		-- Properly slippery. Skating here is momentum, not walking, and a
		-- car driven onto it is a disaster in the best way.
		CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.02, 0.2, 1, 1),
		Parent = parent,
	})
	ice:SetAttribute("Ice", true)

	-- Centre red line, two blue lines.
	for _, line in {
		{ at = 0, colour = Color3.fromRGB(210, 50, 50), width = 2.4 },
		{ at = -RINK_LENGTH * 0.2, colour = Color3.fromRGB(50, 90, 210), width = 3 },
		{ at = RINK_LENGTH * 0.2, colour = Color3.fromRGB(50, 90, 210), width = 3 },
	} do
		Util.Part({
			Name = "RinkLine",
			Size = Vector3.new(RINK_WIDTH, 0.2, line.width),
			CFrame = CFrame.new(centre + Vector3.new(0, 1.1, line.at)),
			Color = line.colour,
			Material = Enum.Material.SmoothPlastic,
			CanCollide = false,
			Parent = parent,
		})
	end

	-- Face-off circles, drawn as rings of short arcs.
	for _, spot in {
		Vector3.new(0, 0, 0),
		Vector3.new(-RINK_WIDTH * 0.26, 0, -RINK_LENGTH * 0.3),
		Vector3.new(RINK_WIDTH * 0.26, 0, -RINK_LENGTH * 0.3),
		Vector3.new(-RINK_WIDTH * 0.26, 0, RINK_LENGTH * 0.3),
		Vector3.new(RINK_WIDTH * 0.26, 0, RINK_LENGTH * 0.3),
	} do
		local radius = 15
		for step = 0, 23 do
			local angle = (step / 24) * math.pi * 2
			Util.Part({
				Name = "FaceoffCircle",
				Size = Vector3.new(1.2, 0.2, 4.2),
				CFrame = CFrame.new(
					centre + spot + Vector3.new(math.cos(angle) * radius, 1.1, math.sin(angle) * radius)
				) * CFrame.Angles(0, -angle, 0),
				Color = Color3.fromRGB(210, 50, 50),
				Material = Enum.Material.SmoothPlastic,
				CanCollide = false,
				Parent = parent,
			})
		end
	end
end

--[[ A rack of sticks, so the rink comes with something to play it with. ]]
--[[
	The penalty box: a bench behind the boards with a low wall and a gate
	gap. Losing a fight puts you here for a few seconds, which is the only
	thing in this game that briefly takes you out of it -- and even in the
	box your gun still works, so sitting there is not safe either.
]]
local function penaltyBench(centre: Vector3, parent: Instance)
	local at = centre + Vector3.new(RINK_WIDTH * 0.5 + 9, 0, RINK_LENGTH * 0.16)
	penaltyBox = at + Vector3.new(0, 4, 0)

	Util.Part({
		Name = "PenaltyFloor",
		Size = Vector3.new(16, 1, 34),
		Position = at + Vector3.new(0, 0.5, 0),
		Color = Color3.fromRGB(58, 62, 70),
		Material = Enum.Material.Concrete,
		Anchored = true,
		Parent = parent,
	})

	Util.Part({
		Name = "PenaltyBench",
		Size = Vector3.new(3, 1.6, 28),
		Position = at + Vector3.new(5.5, 1.8, 0),
		Color = Color3.fromRGB(120, 86, 48),
		Material = Enum.Material.WoodPlanks,
		Anchored = true,
		Parent = parent,
	})

	-- Low wall on the rink side, with a gap in the middle for the gate.
	for _, span in { { -11, 10 }, { 11, 10 } } do
		Util.Part({
			Name = "PenaltyWall",
			Size = Vector3.new(1, 7, span[2]),
			Position = at + Vector3.new(-8, 4, span[1]),
			Color = Color3.fromRGB(235, 238, 242),
			Material = Enum.Material.SmoothPlastic,
			Anchored = true,
			Parent = parent,
		})
	end

	Util.Part({
		Name = "PenaltySign",
		Size = Vector3.new(0.4, 3, 12),
		Position = at + Vector3.new(5.5, 8, 0),
		Color = Color3.fromRGB(205, 40, 40),
		Material = Enum.Material.Neon,
		Anchored = true,
		CanCollide = false,
		Parent = parent,
	})
end

local function stickRack(at: Vector3, parent: Instance)
	Util.Part({
		Name = "StickRack",
		Size = Vector3.new(16, 8, 4),
		CFrame = CFrame.new(at + Vector3.new(0, 4, 0)),
		Color = Color3.fromRGB(96, 70, 46),
		Material = Enum.Material.Wood,
		Parent = parent,
	})
	for index = 0, 5 do
		Util.Part({
			Name = "RackStick",
			Size = Vector3.new(0.7, 11, 0.7),
			CFrame = CFrame.new(at + Vector3.new(-6 + index * 2.4, 7, 0))
				* CFrame.Angles(math.rad(12), 0, 0),
			Color = Color3.fromRGB(190, 170, 140),
			Material = Enum.Material.Wood,
			CanCollide = false,
			Parent = parent,
		})
	end
end

-- ===================================================================== PUCK ==

--[[
	Drop a fresh puck at centre ice.

	Deliberately light and very slippery, so a bullet moves it a long way.
	Shooting the puck IS playing hockey here -- there is no stick-handling
	simulation and there does not need to be one.
]]
local function dropPuck()
	if puck then
		puck:Destroy()
	end

	local fresh = Util.Part({
		Name = "Puck",
		Size = Vector3.new(1.2, 3.4, 3.4),
		CFrame = CFrame.new(puckHome),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(22, 22, 26),
		Material = Enum.Material.Rubber,
		Anchored = false,
		CustomPhysicalProperties = PhysicalProperties.new(0.4, 0.03, 0.35, 1, 1),
		Parent = rink,
	})
	-- A cylinder lies on its own X, so turn it flat.
	fresh.CFrame = CFrame.new(puckHome) * CFrame.Angles(0, 0, math.rad(90))
	fresh:SetAttribute("Puck", true)
	puck = fresh
end

--[[
	A bullet hit the puck.

	This is the shot. The puck takes off along the shot's own direction, hard
	enough to cross the rink, which makes a rifle a perfectly good stick.
]]
function HockeyService.RegisterHit(part: BasePart, attacker: Player?, direction: Vector3?): boolean
	if part:GetAttribute("Puck") ~= true then
		return false
	end

	local push = direction or Vector3.new(0, 0, -1)
	local flat = Vector3.new(push.X, 0, push.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end

	part.AssemblyLinearVelocity = flat.Unit * 190 + Vector3.new(0, 14, 0)
	Sound.At("MeleeHit", part.Position, 1.1)

	if attacker then
		-- Credit for touching it last, so a goal has somebody to name.
		part:SetAttribute("LastTouchUserId", attacker.UserId)
	end
	return true
end

--[[
	Carry the puck, and shoot it.

	The puck is pulled toward a point in front of whoever has it rather than
	welded to them, so it can be checked off, shot away, or lost when they
	are knocked down. Welding would make possession absolute, and a puck
	nobody can take off you is not hockey.
]]
local function stepPossession()
	local live = puck
	if not live or not live.Parent then
		return
	end

	local owner = puckOwner
	if owner then
		local character = owner.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
			puckOwner = nil
		else
			local ahead = root.Position
				+ root.CFrame.LookVector * Config.Hockey.CarryDistance
				- Vector3.new(0, 2.2, 0)
			-- Pulled, not placed: it lags a little and can be knocked loose.
			live.AssemblyLinearVelocity = (ahead - live.Position) * 18
			return
		end
	end

	-- Loose: whoever is closest and on the ice picks it up.
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		if now < (pickupBlockedUntil[player] or 0) then
			continue
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
			continue
		end
		-- Not while in a fight: you have dropped your gloves, not picked up
		-- a stick.
		if fightOf[player] then
			continue
		end
		if (root.Position - live.Position).Magnitude <= Config.Hockey.PickupRange then
			puckOwner = player
			live:SetAttribute("LastTouchUserId", player.UserId)
			Sound.At("Pickup", live.Position, 0.7)
			Remotes.Event("HockeyScore"):FireClient(player, { carrying = true })
			return
		end
	end
end

--[[ Shoot the puck where the shooter is looking. ]]
function HockeyService.ShootPuck(player: Player, direction: any)
	if puckOwner ~= player then
		return
	end
	local live = puck
	if not live or not live.Parent then
		return
	end
	local aim = Util.SaneDirection(direction)
	if not aim then
		return
	end

	puckOwner = nil
	-- A moment before you can scoop it straight back up.
	pickupBlockedUntil[player] = os.clock() + 0.6

	local flat = Vector3.new(aim.X, 0, aim.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end
	live.AssemblyLinearVelocity = flat.Unit * Config.Hockey.ShotSpeed + Vector3.new(0, 9, 0)
	live:SetAttribute("LastTouchUserId", player.UserId)
	Sound.At("MeleeHit", live.Position, 1.1)
end

--[[ Who has it, for tests. ]]
function HockeyService.PuckOwner(): Player?
	return puckOwner
end

--[[ Who last touched the puck, if they are still here. ]]
local function lastToucher(): Player?
	if not puck then
		return nil
	end
	local userId = puck:GetAttribute("LastTouchUserId")
	if typeof(userId) ~= "number" then
		return nil
	end
	for _, player in Players:GetPlayers() do
		if player.UserId == userId then
			return player
		end
	end
	return nil
end

--[[ Did the puck cross a goal line? ]]
local function checkGoals()
	local live = puck
	if not live or not live.Parent then
		return
	end

	-- Reset puck if blasted over the boards or out of bounds.
	local distFromHome = live.Position - puckHome
	if live.Position.Y < -20 or math.abs(distFromHome.X) > RINK_WIDTH * 0.65 or math.abs(distFromHome.Z) > RINK_LENGTH * 0.65 then
		dropPuck()
		return
	end

	local now = os.clock()
	if now - lastGoalAt < 3 then
		return
	end

	for _, zone in goalZones do
		local offset = live.Position - zone.part.Position
		local half = zone.part.Size * 0.5
		if math.abs(offset.X) <= half.X
			and math.abs(offset.Y) <= half.Y
			and math.abs(offset.Z) <= half.Z
		then
			lastGoalAt = now

			-- Light the lamp at the end that was scored on.
			local lamp = goalLights[zone.defendingTeam]
			if lamp then
				lamp.Color = Color3.fromRGB(255, 40, 40)
				local glow = lamp:FindFirstChildOfClass("PointLight")
				if glow then
					glow.Brightness = 6
				end
				task.delay(2.5, function()
					if lamp.Parent then
						lamp.Color = Color3.fromRGB(70, 14, 14)
						local dim = lamp:FindFirstChildOfClass("PointLight")
						if dim then
							dim.Brightness = 0
						end
					end
				end)
			end

			local scorer = lastToucher()
			-- The goal belongs to whoever is NOT defending it.
			local scoringTeam = if zone.defendingTeam == 1 then 2 else 1
			local points = Config.Hockey.GoalPoints

			if scorer and TeamService.IndexOf(scorer) == scoringTeam then
				PlayerState.AwardPoints(scorer, points)
			end
			HockeyService.Goal.Fire(scorer, scoringTeam, points)

			Sound.At("RoundEnd", live.Position, 1.2)
			dropPuck()
			puckOwner = nil
			return
		end
	end
end

-- ==================================================================== FIGHTS ==

--[[
	A hockey fight, Blades of Steel style.

	Two opposing players, squared up face to face. Each one has fight health
	and two controls: throw a punch, or raise the guard. A clean punch takes
	a real bite; a punch into a raised guard barely stings. Drop to zero and
	you go down, the winner takes the points, and the winner's stick has a
	good chance of breaking over them -- at which point the splintered half
	becomes a genuinely nasty melee weapon. The loser then serves time in the
	penalty box, because of course they do.

	Note what does NOT happen: nobody's guns are taken away. You can shoot
	your way out of a fight, or shoot two other people having one. That is
	the rule for every sport on this map and a fight is no exception; it just
	means the scrap is a gamble rather than a cutscene.
]]
function HockeyService.StartFight(a: Player, b: Player): boolean
	if fightOf[a] or fightOf[b] then
		return false
	end
	if a == b or (a.Team and b.Team and a.Team == b.Team) then
		return false
	end

	local fight: Fight = {
		a = a,
		b = b,
		endsAt = os.clock() + Config.Hockey.FightSeconds,
		health = { [a] = Config.Hockey.FightHealth, [b] = Config.Hockey.FightHealth },
		blocking = { [a] = false, [b] = false },
	}
	table.insert(fights, fight)
	fightOf[a] = fight
	fightOf[b] = fight

	-- Square them up face to face. A fight is a fight, not a chase, so their
	-- legs come off for the duration -- but nothing takes their gun away.
	local aRoot = a.Character and a.Character:FindFirstChild("HumanoidRootPart")
	local bRoot = b.Character and b.Character:FindFirstChild("HumanoidRootPart")
	if aRoot and bRoot and aRoot:IsA("BasePart") and bRoot:IsA("BasePart") then
		local midpoint = (aRoot.Position + bRoot.Position) * 0.5
		local axis = bRoot.Position - aRoot.Position
		if Util.IsSaneVector(axis) and axis.Magnitude > 0.5 then
			local unit = axis.Unit
			aRoot.CFrame = CFrame.lookAt(midpoint - unit * 3, midpoint + unit * 3)
			bRoot.CFrame = CFrame.lookAt(midpoint + unit * 3, midpoint - unit * 3)
		end
	end

	for _, who in { a, b } do
		local foe = if who == a then b else a
		local humanoid = who.Character and who.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = 0
			humanoid.JumpPower = 0
		end
		Remotes.Event("FightStarted"):FireClient(who, {
			opponent = foe.DisplayName,
			duration = Config.Hockey.FightSeconds,
			health = Config.Hockey.FightHealth,
			maxHealth = Config.Hockey.FightHealth,
		})
	end

	Remotes.Event("KillFeed"):FireAllClients(
		`{a.DisplayName} and {b.DisplayName} are going at it`,
		false
	)
	return true
end

local lastPunchAt: { [Player]: number } = {}

--[[ Give a fighter their legs back once the scrap is over. ]]
local function releaseFighter(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Parent then
		humanoid.WalkSpeed = Config.Turbo.WalkSpeed
		humanoid.JumpPower = Config.Movement.JumpPower
	end
end

--[[ Tell both fighters where the two health bars stand. ]]
local function pushFightState(fight: Fight)
	for _, who in { fight.a, fight.b } do
		if who.Parent then
			local foe = if who == fight.a then fight.b else fight.a
			Remotes.Event("FightUpdate"):FireClient(who, {
				health = fight.health[who] or 0,
				opponentHealth = fight.health[foe] or 0,
				maxHealth = Config.Hockey.FightHealth,
				blocking = fight.blocking[who] == true,
				opponentBlocking = fight.blocking[foe] == true,
			})
		end
	end
end

--[[
	Raise or drop the guard. A raised guard turns a knockout blow into a
	graze, which makes the fight a read rather than a race: whoever only
	hammers the punch key loses to whoever watches and times it.
]]
function HockeyService.Block(player: Player, up: boolean)
	local fight = fightOf[player]
	if not fight then
		return
	end
	fight.blocking[player] = up == true
	pushFightState(fight)
end

--[[
	Throw a punch. Rate-limited by PunchCooldown so a macro gains nothing,
	and throwing drops your own guard -- you cannot hide and hit at once.
]]
function HockeyService.Punch(player: Player)
	local fight = fightOf[player]
	if not fight then
		return
	end

	local now = os.clock()
	if now - (lastPunchAt[player] or 0) < Config.Hockey.PunchCooldown then
		return
	end
	lastPunchAt[player] = now

	local foe = if player == fight.a then fight.b else fight.a
	fight.blocking[player] = false

	local damage = if fight.blocking[foe]
		then Config.Hockey.BlockedDamage
		else math.random(Config.Hockey.PunchDamageMin, Config.Hockey.PunchDamageMax)

	local left = math.max(0, (fight.health[foe] or 0) - damage)
	fight.health[foe] = left
	pushFightState(fight)

	if left <= 0 then
		HockeyService.EndFight(fight, player, foe)
	end
end

--[[
	Close out a fight with a decided winner -- either a knockout or the clock
	running out with one of them ahead.
]]
function HockeyService.EndFight(fight: Fight, winner: Player, loser: Player)
	if not fightOf[winner] and not fightOf[loser] then
		return
	end
	fightOf[fight.a] = nil
	fightOf[fight.b] = nil
	for index, candidate in fights do
		if candidate == fight then
			table.remove(fights, index)
			break
		end
	end

	releaseFighter(winner)
	releaseFighter(loser)

	PlayerState.AwardPoints(winner, Config.Hockey.FightWinPoints)

	-- The loser goes down, then serves time. Not killed -- knocked over and
	-- benched, which is both funnier and leaves them in the game.
	local loserCharacter = loser.Character
	local loserHumanoid = loserCharacter and loserCharacter:FindFirstChildOfClass("Humanoid")
	if loserHumanoid then
		loserHumanoid.PlatformStand = true
		task.delay(Config.Hockey.KnockdownSeconds, function()
			if loserHumanoid and loserHumanoid.Parent then
				loserHumanoid.PlatformStand = false
			end
			local root = loserCharacter and loserCharacter:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and penaltyBox.Magnitude > 0 then
				root.CFrame = CFrame.new(penaltyBox)
			end
		end)
	end

	-- Losing the fight means losing the puck, and you cannot scoop it back up
	-- on your way to the box.
	if puckOwner == loser then
		puckOwner = nil
		pickupBlockedUntil[loser] = os.clock() + Config.Hockey.PenaltySeconds
	end

	-- And the stick may well break. The splintered half is the prize.
	local brokeStick = math.random() < Config.Hockey.StickBreakChance
	if brokeStick then
		local state = PlayerState.Get(winner)
		local spec = Config.Weapons[Config.Hockey.BrokenStickWeapon]
		if spec then
			state.weapons[Config.Hockey.BrokenStickWeapon] = {
				ammo = spec.MagSize,
				reloadingUntil = 0,
				nextFireAt = 0,
			}
			state.equipped = Config.Hockey.BrokenStickWeapon
			PlayerState.Changed.Fire(winner)
		end
	end

	Remotes.Event("FightResult"):FireClient(winner, { won = true, brokeStick = brokeStick })
	Remotes.Event("FightResult"):FireClient(loser, { won = false, brokeStick = false })
	Remotes.Event("KillFeed"):FireAllClients(
		`{winner.DisplayName} won the fight with {loser.DisplayName}`
			.. (if brokeStick then " and broke their stick over them" else ""),
		false
	)

	HockeyService.FightOver.Fire(winner, loser, brokeStick)
end

--[[ The clock ran out. Whoever is still standing taller takes it. ]]
local function settle(fight: Fight)
	local aLeft = fight.health[fight.a] or 0
	local bLeft = fight.health[fight.b] or 0

	if aLeft == bLeft then
		-- A dead heat is a draw: both of them look silly and neither falls.
		fightOf[fight.a] = nil
		fightOf[fight.b] = nil
		for _, who in { fight.a, fight.b } do
			releaseFighter(who)
			if who.Parent then
				Remotes.Event("FightResult"):FireClient(who, { won = false, draw = true })
			end
		end
		return
	end

	if aLeft > bLeft then
		HockeyService.EndFight(fight, fight.a, fight.b)
	else
		HockeyService.EndFight(fight, fight.b, fight.a)
	end
end

--[[ Is this player on the ice? Fights only start on the rink. ]]
function HockeyService.OnIce(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") or not rink then
		return false
	end
	local ice = rink:FindFirstChild("Ice")
	if not ice or not ice:IsA("BasePart") then
		return false
	end
	local offset = root.Position - ice.Position
	return math.abs(offset.X) <= RINK_WIDTH * 0.5
		and math.abs(offset.Z) <= RINK_LENGTH * 0.5
		and offset.Y > -6
		and offset.Y < 30
end

-- ===================================================================== BUILD ==

function HockeyService.Clear()
	for _, fight in fights do
		for _, fighter in { fight.a, fight.b } do
			if fighter.Parent then
				Remotes.Event("FightResult"):FireClient(fighter, { won = false, draw = true, brokeStick = false })
			end
		end
	end
	if rink then
		rink:Destroy()
		rink = nil
	end
	puck = nil
	table.clear(goalZones)
	table.clear(fights)
	table.clear(fightOf)
	table.clear(lastPunchAt)
end

--[[ Put the rink down, off to one side of the city. ]]
function HockeyService.Build(mapSize: number)
	HockeyService.Clear()

	local model = Instance.new("Model")
	model.Name = "HockeyRink"
	rink = model

	-- Opposite the carnival, so the two distractions are not on top of each
	-- other and both are a drive from the middle.
	local centre = Vector3.new(-mapSize * 0.3, 0, mapSize * 0.06)

	surface(centre, model)
	boards(centre, model)

	goal(centre + Vector3.new(0, 0, -RINK_LENGTH * 0.42), -1, 1, model)
	goal(centre + Vector3.new(0, 0, RINK_LENGTH * 0.42), 1, 2, model)

	penaltyBench(centre, model)

	stickRack(centre + Vector3.new(RINK_WIDTH * 0.5 + 14, 0, 0), model)
	stickRack(centre + Vector3.new(-RINK_WIDTH * 0.5 - 14, 0, 0), model)

	model.Parent = workspace

	puckHome = centre + Vector3.new(0, 4, 0)
	dropPuck()

	-- Offer it as a sub-game: walk in and it asks, or pick it from the menu
	-- and you are brought here.
	ArcadeService.Register({
		id = "hockey",
		name = "Ice Hockey",
		objective = "Shoot the puck into their net. Stick to an opponent starts a fight.",
		centre = centre,
		spawns = {
			centre + Vector3.new(-30, 4, -40),
			centre + Vector3.new(30, 4, -40),
			centre + Vector3.new(-30, 4, 40),
			centre + Vector3.new(30, 4, 40),
		},
		perTeam = 4,
		teamed = true,
	})

	return { centre = centre, puckHome = puckHome }
end

--[[ Where the rink sits, so the city is not built on top of it. ]]
function HockeyService.ReservedArea(mapSize: number): { centre: Vector3, radius: number }
	return {
		centre = Vector3.new(-mapSize * 0.3, 0, mapSize * 0.06),
		radius = RINK_LENGTH * 0.5 + 30,
	}
end

local hockeyStarted = false

local function isAlive(p: Player): boolean
	if p.Parent == nil then
		return false
	end
	local char = p.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

function HockeyService.Start()
	if hockeyStarted then
		return
	end
	hockeyStarted = true

	Remotes.Event("HockeyPunch").OnServerEvent:Connect(function(player: Player)
		HockeyService.Punch(player)
	end)

	Remotes.Event("HockeyBlock").OnServerEvent:Connect(function(player: Player, up)
		HockeyService.Block(player, up == true)
	end)

	Remotes.Event("HockeyShoot").OnServerEvent:Connect(function(player: Player, direction)
		HockeyService.ShootPuck(player, direction)
	end)

	RunService.Heartbeat:Connect(function()
		checkGoals()
		stepPossession()

		local now = os.clock()
		for index = #fights, 1, -1 do
			local fight = fights[index]
			local aGone = not isAlive(fight.a)
			local bGone = not isAlive(fight.b)
			if now >= fight.endsAt or aGone or bGone then
				table.remove(fights, index)
				if aGone or bGone then
					fightOf[fight.a] = nil
					fightOf[fight.b] = nil
					for _, fighter in { fight.a, fight.b } do
						releaseFighter(fighter)
						if fighter.Parent then
							Remotes.Event("FightResult"):FireClient(fighter, { won = false, draw = true, brokeStick = false })
						end
					end
				else
					settle(fight)
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		fightOf[player] = nil
		lastPunchAt[player] = nil
	end)
end

--[[ Where the penalty box is, for tests. Zero before the rink is built. ]]
function HockeyService.PenaltyBox(): Vector3
	return penaltyBox
end

--[[ A fighter's remaining fight health, for tests and for the HUD. ]]
function HockeyService.FightHealthOf(player: Player): number?
	local fight = fightOf[player]
	return fight and fight.health[player]
end

--[[ Is this player's guard up right now? ]]
function HockeyService.IsBlocking(player: Player): boolean
	local fight = fightOf[player]
	return fight ~= nil and fight.blocking[player] == true
end

--[[ How many fights are running, for tests. ]]
function HockeyService.FightCount(): number
	return #fights
end

--[[ The puck itself, for tests. ]]
function HockeyService.Puck(): BasePart?
	return puck
end

return HockeyService
