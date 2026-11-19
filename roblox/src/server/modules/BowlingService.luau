--!strict
--[[
	BowlingService — two lanes, ten pins, and a ball you can shoot.

	Adapted from the pasted bowling server, with one deliberate departure:
	the paste kept a ten-frame scorecard with strike and spare carry-over,
	and this does not.

	Ten frames is a ten-minute commitment, and this map's round is already
	the clock. A player who walks onto a lane mid-round and gets locked into
	a game longer than the round itself is a player who cannot be shot at,
	which is the one thing no activity here is allowed to be. So scoring is
	per ball: points for pins, a bonus for a strike, a smaller one for
	clearing the rest with the second ball. Walk on, roll, walk off -- the
	arena round decides who won.

	What is kept is everything that makes bowling feel like bowling:

	- An OILED lane. Low friction is why a bowling ball slides and hooks
	  rather than rolling to a stop, and it is most of the feel of the
	  sport.
	- Real gutters either side, so a bad line is punished by the geometry
	  rather than by a rule.
	- Ten pins in a 1-2-3-4 triangle, unanchored and top-heavy, so they fall
	  into each other. A pin that only falls when hit directly turns a
	  strike into ten separate shots.

	The pins are physical and the ball is physical, which means both can be
	shot, run over by a car, or caught in a blast. A grenade down the lane
	is a legitimate strike and nobody is going to tell you otherwise.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Signal = require(Shared:WaitForChild("Signal"))
local Sound = require(Shared:WaitForChild("Sound"))
local Util = require(Shared:WaitForChild("Util"))

local ArcadeService = require(script.Parent:WaitForChild("ArcadeService"))
local MedalService = require(script.Parent:WaitForChild("MedalService"))
local PlayerState = require(script.Parent:WaitForChild("PlayerState"))

local BowlingService = {}

--[[ Fired as (player, pins, isStrike) each time a roll settles. ]]
BowlingService.Rolled = Signal.new()

type Pin = {
	part: BasePart,
	home: CFrame,
	down: boolean,
}

type Lane = {
	id: number,
	pins: { Pin },
	ball: BasePart,
	ballHome: Vector3,
	foul: Vector3,
	-- Who rolled, and whether this is their second ball at the same rack.
	roller: Player?,
	secondBall: boolean,
	settleAt: number,
	rolling: boolean,
}

local alley: Model? = nil
local lanes: { Lane } = {}
local holder: { [Player]: number } = {}
local chargeStartedAt: { [Player]: number } = {}
local started = false

--[[
	Is this pin down?

	By TILT, not by height. A pin shunted along the deck without toppling
	is still standing, and a pin that fell into the gutter has not been
	knocked over by the ball either -- but tilt catches both the ones that
	matter and misses neither.
]]
local function isDown(pin: Pin): boolean
	local part = pin.part
	if not part.Parent then
		return true
	end
	-- The pin's own up axis against the world's. Upright is 1, flat is 0.
	local upright = part.CFrame.UpVector:Dot(Vector3.new(0, 1, 0))
	if upright < Config.Bowling.DownTilt then
		return true
	end
	-- Or knocked clean off the deck.
	return (part.Position - pin.home.Position).Magnitude > Config.Bowling.DownDistance
end

local function standingCount(lane: Lane): number
	local up = 0
	for _, pin in lane.pins do
		if not isDown(pin) then
			up += 1
		end
	end
	return up
end

--[[ Put all ten back up. ]]
local function resetRack(lane: Lane)
	for _, pin in lane.pins do
		local part = pin.part
		if part.Parent then
			part.CFrame = pin.home
			part.AssemblyLinearVelocity = Vector3.new()
			part.AssemblyAngularVelocity = Vector3.new()
		end
		pin.down = false
	end
end

local function resetBall(lane: Lane)
	lane.ball.AssemblyLinearVelocity = Vector3.new()
	lane.ball.AssemblyAngularVelocity = Vector3.new()
	lane.ball.CFrame = CFrame.new(lane.ballHome)
end

--[[
	The roll has stopped mattering: count what fell and pay for it.

	Called once per roll, a fixed time after the ball leaves the hand,
	rather than when the ball stops moving. A ball that rolls into the
	gutter and sits there never stops, and a ball that strikes dead centre
	stops almost at once -- waiting for stillness would mean a different
	delay for every roll and no delay at all for the worst ones.
]]
local function settle(lane: Lane)
	lane.rolling = false

	local knocked = #lane.pins - standingCount(lane)
	local roller = lane.roller

	if knocked > 0 then
		-- One crash, loud, built from several voices so it reads as a
		-- clatter of ten rather than one thing falling over.
		Sound.Chorus("PinCrash", lane.pins[1].part.Position, math.min(knocked, 6), 0.8)
	end

	local isStrike = knocked == #lane.pins and not lane.secondBall
	local isSpare = knocked == #lane.pins and lane.secondBall

	if roller and roller.Parent then
		local points = knocked * Config.Bowling.PointsPerPin
		local reason = "pins"
		if isStrike then
			points += Config.Bowling.StrikeBonus
			reason = "strike"
		elseif isSpare then
			points += Config.Bowling.SpareBonus
			reason = "spare"
		end

		if points > 0 then
			PlayerState.AwardPoints(roller, points, reason)
		end
		if isStrike then
			MedalService.Broadcast(roller, "Strike")
		end
	end

	BowlingService.Rolled.Fire(roller, knocked, isStrike)

	--[[
		A fresh rack, or a second ball at what is left.

		Standing pins stay standing for the second ball, which is the only
		part of real bowling's structure worth keeping: the second ball at a
		gap is a different and harder shot than the first at a full rack.
	]]
	if knocked == #lane.pins or lane.secondBall then
		resetRack(lane)
		lane.secondBall = false
	else
		lane.secondBall = true
	end

	lane.roller = nil
	resetBall(lane)
end

--[[ Build one lane: approach, oiled boards, gutters, deck and ten pins. ]]
local function buildLane(index: number, at: Vector3, parent: Instance): Lane
	local length = Config.Bowling.LaneLength
	local width = Config.Bowling.LaneWidth

	--[[
		The oil.

		Friction near zero is why a bowling ball slides and hooks instead of
		rolling to a stop in six feet, and it is most of what the sport
		feels like. Elasticity stays low so the ball does not bounce down
		the lane like a basketball.
	]]
	Util.Part({
		Name = "BowlingLane",
		Size = Vector3.new(width, 1, length),
		CFrame = CFrame.new(at + Vector3.new(0, 0.5, 0)),
		Color = Color3.fromRGB(206, 170, 112),
		Material = Enum.Material.WoodPlanks,
		Reflectance = 0.12,
		Anchored = true,
		CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.02, 0.1, 1, 1),
		Parent = parent,
	})

	-- Gutters, so a bad line is punished by the geometry rather than a rule.
	for _, side in { -1, 1 } do
		Util.Part({
			Name = "Gutter",
			Size = Vector3.new(4, 1.6, length),
			CFrame = CFrame.new(at + Vector3.new(side * (width * 0.5 + 2), 0.2, 0)),
			Color = Color3.fromRGB(44, 48, 56),
			Material = Enum.Material.Metal,
			Anchored = true,
			Parent = parent,
		})
	end

	-- The pit at the far end, so pins and balls stop somewhere.
	Util.Part({
		Name = "BowlingBackstop",
		Size = Vector3.new(width + 10, 10, 2),
		CFrame = CFrame.new(at + Vector3.new(0, 5, -length * 0.5 - 1)),
		Color = Color3.fromRGB(32, 34, 40),
		Material = Enum.Material.Fabric,
		Anchored = true,
		Parent = parent,
	})

	--[[
		Ten pins, 1-2-3-4 back from the headpin.

		Unanchored and deliberately top-heavy: the centre of mass sits above
		the middle, so a pin clipped at the base topples into its
		neighbours. A pin that only falls when hit directly would turn a
		strike into ten separate shots, which is not bowling.
	]]
	local pins: { Pin } = {}
	local deck = at + Vector3.new(0, 1, -length * 0.5 + 14)
	local spacing = Config.Bowling.PinSpacing
	for row = 0, 3 do
		for seat = 0, row do
			local offset = Vector3.new(
				(seat - row * 0.5) * spacing,
				Config.Bowling.PinHeight * 0.5,
				-row * spacing * 0.87
			)
			local part = Util.Part({
				Name = "Pin",
				Size = Vector3.new(1.3, Config.Bowling.PinHeight, 1.3),
				CFrame = CFrame.new(deck + offset),
				Color = Color3.fromRGB(248, 248, 250),
				Material = Enum.Material.SmoothPlastic,
				Anchored = false,
				CustomPhysicalProperties = PhysicalProperties.new(0.35, 0.3, 0.45, 1, 1),
				Parent = parent,
			})

			local stripe = Util.Part({
				Name = "PinStripe",
				Size = Vector3.new(1.35, 0.5, 1.35),
				CFrame = part.CFrame * CFrame.new(0, 1, 0),
				Color = Color3.fromRGB(214, 48, 48),
				Material = Enum.Material.SmoothPlastic,
				Anchored = false,
				Massless = true,
				CanCollide = false,
				Parent = parent,
			})
			Util.Weld(part, stripe)

			table.insert(pins, { part = part, home = part.CFrame, down = false })
		end
	end

	local ballHome = at + Vector3.new(0, 3, length * 0.5 - 8)
	local ball = Util.Part({
		Name = "BowlingBall",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(3.2, 3.2, 3.2),
		CFrame = CFrame.new(ballHome),
		Color = Color3.fromRGB(28, 32, 48),
		Material = Enum.Material.Marble,
		Reflectance = 0.2,
		Anchored = false,
		-- Heavy, and it does not bounce.
		CustomPhysicalProperties = PhysicalProperties.new(3.2, 0.1, 0.05, 2, 1),
		Parent = parent,
	})

	return {
		id = index,
		pins = pins,
		ball = ball,
		ballHome = ballHome,
		foul = at + Vector3.new(0, 1, length * 0.5 - 4),
		roller = nil,
		secondBall = false,
		settleAt = 0,
		rolling = false,
	}
end

--[[ Which lane is this player standing at, if any? ]]
local function laneNear(player: Player): Lane?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local best: Lane? = nil
	local bestDistance = Config.Bowling.PickupRange
	for _, lane in lanes do
		local distance = (lane.ball.Position - root.Position).Magnitude
		if distance < bestDistance then
			bestDistance = distance
			best = lane
		end
	end
	return best
end

--[[ Walk to the ball and it is yours. ]]
local function stepPossession()
	for _, lane in lanes do
		if lane.rolling or lane.roller then
			continue
		end
		for _, player in Players:GetPlayers() do
			if holder[player] then
				continue
			end
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health <= 0 then
				continue
			end
			if laneNear(player) == lane then
				holder[player] = lane.id
				Sound.At("Pickup", lane.ball.Position, 0.6)
				Remotes.Event("BallCarry"):FireClient(player, { carrying = true, bowling = true })
				break
			end
		end
	end
end

--[[ Rolls in flight, waiting to be counted. ]]
local function stepSettling()
	local now = os.clock()
	for _, lane in lanes do
		if lane.rolling and now >= lane.settleAt then
			settle(lane)
		end
	end
end

function BowlingService.StartCharge(player: Player)
	if not holder[player] then
		return
	end
	chargeStartedAt[player] = os.clock()
end

--[[ Let go. Power from the wind-up, line from where you are looking. ]]
function BowlingService.Roll(player: Player, direction: Vector3?)
	local laneId = holder[player]
	if not laneId then
		return
	end
	local lane = lanes[laneId]
	if not lane or lane.rolling then
		return
	end

	local began = chargeStartedAt[player]
	chargeStartedAt[player] = nil
	holder[player] = nil

	local held = if began then os.clock() - began else 0
	local power = math.clamp(held / Config.Bowling.FullChargeSeconds, 0.2, 1)

	local aim = Util.SaneDirection(direction)
	if not aim then
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		aim = if root and root:IsA("BasePart")
			then root.CFrame.LookVector
			else (lane.pins[1].part.Position - lane.ballHome).Unit
	end

	-- Flattened: a bowling ball goes down the lane, not into the air. The
	-- whole shot is the line and the speed.
	local flat = Vector3.new(aim.X, 0, aim.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end

	lane.roller = player
	lane.rolling = true
	lane.settleAt = os.clock() + Config.Bowling.SettleSeconds

	lane.ball.CFrame = CFrame.new(lane.ballHome)
	lane.ball.AssemblyLinearVelocity = flat.Unit * (Config.Bowling.RollSpeed * power)

	Sound.At("MeleeSwing", lane.ball.Position, 0.4)
	Remotes.Event("BallCarry"):FireClient(player, { carrying = false, bowling = true })
end

--[[ A bullet can shove a ball or a pin. Both are fair game. ]]
function BowlingService.RegisterHit(part: BasePart, attacker: Player?, direction: Vector3?): boolean
	local aim = Util.SaneDirection(direction)

	for _, lane in lanes do
		if part == lane.ball then
			if aim then
				lane.ball.AssemblyLinearVelocity = aim * Config.Bowling.RollSpeed * 0.7
				-- Shooting the ball down the lane counts as your roll, so a
				-- strike by rifle is a strike.
				if attacker and not lane.rolling then
					lane.roller = attacker
					lane.rolling = true
					lane.settleAt = os.clock() + Config.Bowling.SettleSeconds
				end
			end
			return true
		end
		for _, pin in lane.pins do
			if part == pin.part then
				if aim then
					pin.part.AssemblyLinearVelocity = aim * 40 + Vector3.new(0, 12, 0)
				end
				return true
			end
		end
	end
	return false
end

function BowlingService.Clear()
	if alley then
		alley:Destroy()
		alley = nil
	end
	table.clear(lanes)
	table.clear(holder)
	table.clear(chargeStartedAt)
end

function BowlingService.Build(mapSize: number)
	BowlingService.Clear()

	local model = Instance.new("Model")
	model.Name = "BowlingAlley"
	alley = model

	local centre = Vector3.new(-mapSize * 0.26, 0, -mapSize * 0.24)

	Util.Part({
		Name = "AlleyFloor",
		Size = Vector3.new(80, 1, Config.Bowling.LaneLength + 40),
		CFrame = CFrame.new(centre + Vector3.new(0, 0.2, 0)),
		Color = Color3.fromRGB(58, 48, 44),
		Material = Enum.Material.Concrete,
		Anchored = true,
		Parent = model,
	})

	for index = 1, Config.Bowling.Lanes do
		local offset = (index - (Config.Bowling.Lanes + 1) * 0.5) * (Config.Bowling.LaneWidth + 10)
		table.insert(lanes, buildLane(index, centre + Vector3.new(offset, 0, 0), model))
	end

	model.Parent = workspace

	ArcadeService.Register({
		id = "bowling",
		name = "Bowling",
		objective = "Walk to a ball, hold F to wind up, release to roll. Ten pins.",
		centre = centre,
		spawns = {
			centre + Vector3.new(-14, 4, Config.Bowling.LaneLength * 0.5 - 6),
			centre + Vector3.new(14, 4, Config.Bowling.LaneLength * 0.5 - 6),
		},
		perTeam = 2,
		teamed = false,
		colour = Color3.fromRGB(248, 248, 250),
	})

	return { centre = centre, lanes = #lanes }
end

function BowlingService.Start()
	if started then
		return
	end
	started = true

	Remotes.Event("RollBall").OnServerEvent:Connect(function(player: Player, direction)
		BowlingService.Roll(player, if typeof(direction) == "Vector3" then direction else nil)
	end)

	RunService.Heartbeat:Connect(function()
		stepPossession()
		stepSettling()
	end)

	Players.PlayerRemoving:Connect(function(player)
		holder[player] = nil
		chargeStartedAt[player] = nil
		for _, lane in lanes do
			if lane.roller == player then
				lane.roller = nil
			end
		end
	end)
end

--[[ For tests. ]]
function BowlingService.LaneCount(): number
	return #lanes
end

function BowlingService.PinCount(laneId: number): number
	local lane = lanes[laneId]
	return if lane then #lane.pins else 0
end

function BowlingService.StandingCount(laneId: number): number
	local lane = lanes[laneId]
	return if lane then standingCount(lane) else 0
end

function BowlingService.LaneForTests(laneId: number): Lane?
	return lanes[laneId]
end

function BowlingService.HolderLane(player: Player): number?
	return holder[player]
end

function BowlingService.GiveBallForTests(player: Player, laneId: number)
	holder[player] = laneId
end

function BowlingService.StepForTests()
	stepPossession()
	stepSettling()
end

return BowlingService
