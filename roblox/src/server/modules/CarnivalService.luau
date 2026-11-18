--!strict
--[[
	CarnivalService — the fairground.

	A corner of every map is given over to things that are not trying to kill
	you: a dunk tank, a shooting gallery with ducks that slide back and forth,
	and a high striker with a bell on top.

	All of it scores points, so messing about is not entirely wasted time.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Sound = require(Shared:WaitForChild("Sound"))
local Util = require(Shared:WaitForChild("Util"))
local ArcadeService = require(script.Parent:WaitForChild("ArcadeService"))

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))

local CarnivalService = {}

local container: Folder? = nil
local origin = Vector3.zero

type Duck = {
	part: BasePart,
	centre: Vector3,
	span: number,
	speed: number,
	phase: number,
	downUntil: number,
}

local ducks: { Duck } = {}
local dunkSeat: Seat? = nil
local dunkHome: CFrame = CFrame.identity
local dunkWetUntil = 0
local strikerPuck: BasePart? = nil
local strikerUntil = 0

local rng = Random.new()

local DUNK_POINTS = 60
local DUCK_POINTS = 20
local STRIKER_POINTS = 35

-- ================================================================= HELPERS ==

-- Who last fired the cannon, so a flattened stack has somebody to pay, and
-- when it may be fired again.
local lastCannonFirer: Player? = nil
local nextCannonAt = 0

--[[
	Score a stall, with the stall's own wording as the reason.

	The toast used to be fired here as well, which now means two toasts for
	one prize: the single Scored handler in MatchService announces every
	award. So the message goes in as the REASON instead -- same words on
	screen, one place deciding how a score is announced.
]]
local function award(player: Player?, points: number, message: string)
	if not player then
		return
	end
	PlayerState.AwardPoints(player, points, message)
end

local function sign(parent: Instance, position: Vector3, text: string, colour: Color3)
	local post = Util.Part({
		Name = "SignPost",
		Size = Vector3.new(1, 14, 1),
		CFrame = CFrame.new(position + Vector3.new(0, 7, 0)),
		Color = Color3.fromRGB(120, 90, 60),
		Material = Enum.Material.Wood,
		Parent = parent,
	})

	local board = Util.Part({
		Name = "SignBoard",
		Size = Vector3.new(18, 5, 0.6),
		CFrame = CFrame.new(position + Vector3.new(0, 16, 0)),
		Color = colour,
		Material = Enum.Material.SmoothPlastic,
		Parent = parent,
	})
	Util.Weld(post, board)

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(18, 5)
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 600
	billboard.Parent = board

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(30, 26, 24)
	label.TextScaled = true
	label.Font = Enum.Font.LuckiestGuy
	label.Parent = billboard
end

-- =============================================================== DUNK TANK ==

--[[
	The dunk tank: a seat on a plank over a tank of water, and a target on a
	post beside it. Hit the target and the seat gives way.
]]
local function buildDunkTank(at: Vector3, parent: Instance)
	-- The tank.
	Util.Part({
		Name = "TankWall",
		Size = Vector3.new(26, 14, 1.5),
		CFrame = CFrame.new(at + Vector3.new(0, 7, 13)),
		Color = Color3.fromRGB(150, 160, 170),
		Material = Enum.Material.Glass,
		Transparency = 0.55,
		Parent = parent,
	})
	for _, side in { -1, 1 } do
		Util.Part({
			Name = "TankWall",
			Size = Vector3.new(1.5, 14, 26),
			CFrame = CFrame.new(at + Vector3.new(side * 13, 7, 0)),
			Color = Color3.fromRGB(150, 160, 170),
			Material = Enum.Material.Glass,
			Transparency = 0.55,
			Parent = parent,
		})
	end
	Util.Part({
		Name = "TankWall",
		Size = Vector3.new(26, 14, 1.5),
		CFrame = CFrame.new(at + Vector3.new(0, 7, -13)),
		Color = Color3.fromRGB(150, 160, 170),
		Material = Enum.Material.Glass,
		Transparency = 0.55,
		Parent = parent,
	})

	-- Interior exit ladder so dunked players can climb right back out.
	local ladder = Instance.new("TrussPart")
	ladder.Name = "TankLadder"
	ladder.Size = Vector3.new(2, 15, 2)
	ladder.CFrame = CFrame.new(at + Vector3.new(0, 7.5, -11.2))
	ladder.Anchored = true
	ladder.Color = Color3.fromRGB(220, 185, 60)
	ladder.Material = Enum.Material.Metal
	ladder.Parent = parent

	-- The water. Non-solid, so you fall in rather than onto.
	Util.Part({
		Name = "DunkWater",
		Size = Vector3.new(25, 11, 25),
		CFrame = CFrame.new(at + Vector3.new(0, 5.5, 0)),
		Color = Color3.fromRGB(70, 140, 190),
		Material = Enum.Material.Water,
		Transparency = 0.35,
		CanCollide = false,
		Parent = parent,
	})

	-- The plank and the seat above it.
	local plank = Util.Part({
		Name = "DunkPlank",
		Size = Vector3.new(10, 1, 4),
		CFrame = CFrame.new(at + Vector3.new(0, 18, 0)),
		Color = Color3.fromRGB(150, 110, 70),
		Material = Enum.Material.WoodPlanks,
		Parent = parent,
	})

	local seat = Instance.new("Seat")
	seat.Name = "DunkSeat"
	seat.Size = Vector3.new(5, 1, 5)
	seat.CFrame = CFrame.new(at + Vector3.new(0, 19.5, 0))
	seat.Anchored = true
	seat.Color = Color3.fromRGB(220, 90, 90)
	seat.Material = Enum.Material.SmoothPlastic
	seat.Parent = parent

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Take the hot seat"
	prompt.ObjectText = "Dunk Tank"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 22
	prompt.RequiresLineOfSight = false
	prompt.Parent = seat

	prompt.Triggered:Connect(function(player)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and not humanoid.SeatPart and not seat.Occupant then
			seat:Sit(humanoid)
		end
	end)

	dunkSeat = seat
	dunkHome = seat.CFrame
	local _ = plank

	-- The target, on a post to one side.
	local post = Util.Part({
		Name = "DunkPost",
		Size = Vector3.new(1.2, 20, 1.2),
		CFrame = CFrame.new(at + Vector3.new(18, 10, 0)),
		Color = Color3.fromRGB(110, 82, 54),
		Material = Enum.Material.Wood,
		Parent = parent,
	})

	local target = Util.Part({
		Name = "DunkTarget",
		Size = Vector3.new(7, 7, 0.8),
		CFrame = CFrame.new(at + Vector3.new(18, 20, 0)),
		Color = Color3.fromRGB(240, 240, 235),
		Material = Enum.Material.SmoothPlastic,
		Parent = parent,
	})
	target:SetAttribute("Carnival", "Dunk")
	Util.Weld(post, target)

	local ring = Util.Part({
		Name = "DunkRing",
		Size = Vector3.new(0.3, 4.6, 4.6),
		CFrame = target.CFrame * CFrame.new(0, 0, -0.6) * CFrame.Angles(0, math.rad(90), 0),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(220, 40, 40),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		Parent = parent,
	})
	ring:SetAttribute("Carnival", "Dunk")
	Util.Weld(target, ring)

	sign(parent, at + Vector3.new(0, 0, -20), "DUNK TANK — HIT THE TARGET", Color3.fromRGB(240, 200, 90))
end

--[[ Drop whoever is on the seat into the water. ]]
local function dunk(shooter: Player?)
	local seat = dunkSeat
	if not seat or not seat.Parent then
		return
	end
	if os.clock() < dunkWetUntil then
		return
	end
	dunkWetUntil = os.clock() + 3

	local occupant = seat.Occupant
	if occupant then
		local character = occupant.Parent
		local dunked = if character then Players:GetPlayerFromCharacter(character) else nil
		local weld = seat:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
		occupant.Sit = false

		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local targetPos = seat.Position - Vector3.new(0, 14, 0)
			task.defer(function()
				if root.Parent then
					root.CFrame = CFrame.new(targetPos)
					root.AssemblyLinearVelocity = Vector3.zero
				end
			end)
		end

		if dunked then
			Remotes.Event("Notify"):FireClient(dunked, "SPLASH. You have been dunked.")
		end
		award(shooter, DUNK_POINTS, "DUNKED THEM!")
	else
		award(shooter, math.floor(DUNK_POINTS / 4), "Bullseye — nobody was sitting.")
	end

	-- The splash.
	local splash = Util.Part({
		Name = "Splash",
		Size = Vector3.new(1, 1, 1),
		CFrame = CFrame.new(seat.Position - Vector3.new(0, 12, 0)),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		Parent = workspace,
	})
	local spray = Instance.new("ParticleEmitter")
	spray.Color = ColorSequence.new(Color3.fromRGB(150, 210, 240))
	spray.Size = NumberSequence.new(3, 0)
	spray.Lifetime = NumberRange.new(0.5, 1.2)
	spray.Speed = NumberRange.new(20, 44)
	spray.SpreadAngle = Vector2.new(70, 70)
	spray.Rate = 0
	spray.Parent = splash
	spray:Emit(90)
	Sound.At("Splash", splash.Position)
	Debris:AddItem(splash, 3)
end

-- ========================================================= SHOOTING GALLERY ==

local function buildGallery(at: Vector3, parent: Instance)
	Util.Part({
		Name = "GalleryBack",
		Size = Vector3.new(60, 20, 1.5),
		CFrame = CFrame.new(at + Vector3.new(0, 10, 8)),
		Color = Color3.fromRGB(180, 90, 70),
		Material = Enum.Material.WoodPlanks,
		Parent = parent,
	})
	Util.Part({
		Name = "GalleryCounter",
		Size = Vector3.new(60, 6, 6),
		CFrame = CFrame.new(at + Vector3.new(0, 3, 0)),
		Color = Color3.fromRGB(150, 120, 80),
		Material = Enum.Material.WoodPlanks,
		Parent = parent,
	})

	for lane = 1, 3 do
		local height = 8 + lane * 3.5
		local duck = Util.Part({
			Name = "Duck",
			Size = Vector3.new(4.5, 4, 2),
			CFrame = CFrame.new(at + Vector3.new(0, height, 5)),
			Color = if lane == 1 then Color3.fromRGB(250, 210, 60)
				elseif lane == 2 then Color3.fromRGB(240, 130, 60)
				else Color3.fromRGB(120, 200, 240),
			Material = Enum.Material.SmoothPlastic,
			Parent = parent,
		})
		duck:SetAttribute("Carnival", "Duck")

		local head = Util.Part({
			Name = "DuckHead",
			Size = Vector3.new(2, 2.2, 2),
			CFrame = duck.CFrame * CFrame.new(1.4, 2.6, 0),
			Color = duck.Color,
			Material = Enum.Material.SmoothPlastic,
			Anchored = false,
			CanCollide = false,
			Massless = true,
			Parent = parent,
		})
		head:SetAttribute("Carnival", "Duck")
		Util.Weld(duck, head)

		table.insert(ducks, {
			part = duck :: BasePart,
			centre = at + Vector3.new(0, height, 5),
			span = 22,
			speed = 0.6 + lane * 0.25,
			phase = rng:NextNumber(0, math.pi * 2),
			downUntil = 0,
		})
	end

	sign(parent, at + Vector3.new(0, 0, -10), "SHOOTING GALLERY", Color3.fromRGB(250, 210, 60))
end

--[[
	Which duck was hit.

	A duck's head is a separate part welded on, so a head shot has to be
	matched back to the body it belongs to — nearest one wins.
]]
local function hitDuck(part: BasePart, shooter: Player?): boolean
	local best: Duck? = nil
	local bestDistance = 12

	for _, duck in ducks do
		if not duck.part.Parent then
			continue
		end
		local distance = (duck.part.Position - part.Position).Magnitude
		if distance < bestDistance then
			best, bestDistance = duck, distance
		end
	end

	if not best or os.clock() < best.downUntil then
		return false
	end

	best.downUntil = os.clock() + 3
	award(shooter, DUCK_POINTS, "Duck down!")
	return true
end

-- ============================================================= HIGH STRIKER ==

local function buildStriker(at: Vector3, parent: Instance)
	Util.Part({
		Name = "StrikerTower",
		Size = Vector3.new(4, 60, 4),
		CFrame = CFrame.new(at + Vector3.new(0, 30, 0)),
		Color = Color3.fromRGB(90, 70, 110),
		Material = Enum.Material.Metal,
		Parent = parent,
	})

	local bell = Util.Part({
		Name = "StrikerBell",
		Size = Vector3.new(7, 6, 7),
		CFrame = CFrame.new(at + Vector3.new(0, 63, 0)),
		Color = Color3.fromRGB(240, 200, 70),
		Material = Enum.Material.Metal,
		Parent = parent,
	})
	local _ = bell

	local pad = Util.Part({
		Name = "StrikerPad",
		Size = Vector3.new(9, 3, 9),
		CFrame = CFrame.new(at + Vector3.new(0, 1.5, 0)),
		Color = Color3.fromRGB(220, 60, 60),
		Material = Enum.Material.SmoothPlastic,
		Parent = parent,
	})
	pad:SetAttribute("Carnival", "Striker")

	strikerPuck = Util.Part({
		Name = "StrikerPuck",
		Size = Vector3.new(6, 2.5, 6),
		CFrame = CFrame.new(at + Vector3.new(0, 4, 0)),
		Color = Color3.fromRGB(250, 250, 250),
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = parent,
	})

	sign(parent, at + Vector3.new(0, 0, -12), "HIGH STRIKER — SHOOT THE PAD", Color3.fromRGB(220, 120, 200))
end

local function ringBell(shooter: Player?)
	if os.clock() < strikerUntil then
		return
	end
	strikerUntil = os.clock() + 2.5
	local puck = strikerPuck
	if puck then
		Sound.At("Bell", puck.Position + Vector3.new(0, 60, 0))
	end
	award(shooter, STRIKER_POINTS, "DING! Bell rung.")
end

-- ================================================================== PUBLIC ==

--[[ Something was shot. Returns true if it was a carnival prop. ]]
--[[
	Balloon pop.

	A wall of balloons on a board. Pop one and it is gone, with the whole
	board refilling once it is cleared -- so there is always something to
	shoot and never a wall of nothing.
]]
local balloonBoard: { BasePart } = {}
local balloonHome: Vector3 = Vector3.new()

local BALLOON_COLOURS = {
	Color3.fromRGB(230, 60, 60),
	Color3.fromRGB(60, 140, 230),
	Color3.fromRGB(240, 200, 60),
	Color3.fromRGB(110, 210, 110),
	Color3.fromRGB(200, 110, 220),
}

local function fillBalloons(parent: Instance)
	for column = 0, 7 do
		for row = 0, 3 do
			local balloon = Util.Part({
				Name = "Balloon",
				Size = Vector3.new(4, 5, 4),
				CFrame = CFrame.new(balloonHome + Vector3.new(
					-21 + column * 6,
					6 + row * 6,
					0
				)),
				Shape = Enum.PartType.Ball,
				Color = BALLOON_COLOURS[((column + row) % #BALLOON_COLOURS) + 1],
				Material = Enum.Material.SmoothPlastic,
				Parent = parent,
			})
			balloon:SetAttribute("Carnival", "Balloon")
			table.insert(balloonBoard, balloon)
		end
	end
end

local function buildBalloonPop(at: Vector3, parent: Instance)
	balloonHome = at
	table.clear(balloonBoard)

	Util.Part({
		Name = "BalloonBoard",
		Size = Vector3.new(50, 32, 2),
		CFrame = CFrame.new(at + Vector3.new(0, 16, 2)),
		Color = Color3.fromRGB(96, 70, 46),
		Material = Enum.Material.Wood,
		Parent = parent,
	})
	fillBalloons(parent)
	sign(parent, at + Vector3.new(0, 1, 10), "BALLOON POP", Color3.fromRGB(230, 90, 90))
end

local function popBalloon(part: BasePart, shooter: Player?): boolean
	if not part.Parent then
		return false
	end
	Sound.At("Hitmarker", part.Position, 0.9)
	part:Destroy()

	local index = table.find(balloonBoard, part)
	if index then
		table.remove(balloonBoard, index)
	end
	award(shooter, Config.Carnival.BalloonPoints, "POP!")

	-- Board cleared: a bonus, and a fresh wall.
	if #balloonBoard == 0 and container then
		award(shooter, Config.Carnival.BalloonClearBonus, "FULL BOARD CLEARED!")
		local parent = container
		task.delay(1.6, function()
			if parent.Parent then
				fillBalloons(parent)
			end
		end)
	end
	return true
end

--[[
	Milk bottles.

	Three stacks of bottles. Knock every bottle in a stack off its shelf and
	the stack pays out -- which means a shot that scatters two at once is
	worth more than two careful shots, and that is the whole game.
]]
local bottleStacks: { { bottles: { BasePart }, shelf: Vector3, cleared: boolean } } = {}

local function stackBottles(stack: { bottles: { BasePart }, shelf: Vector3, cleared: boolean }, parent: Instance)
	table.clear(stack.bottles)
	stack.cleared = false
	-- Three on the bottom, two, then one: a pyramid, like a real stall.
	local rows = { 3, 2, 1 }
	for row, count in rows do
		for index = 1, count do
			local bottle = Util.Part({
				Name = "MilkBottle",
				Size = Vector3.new(2.4, 5, 2.4),
				CFrame = CFrame.new(stack.shelf + Vector3.new(
					-(count - 1) * 1.8 + (index - 1) * 3.6,
					2.5 + (row - 1) * 5,
					0
				)),
				Shape = Enum.PartType.Cylinder,
				Color = Color3.fromRGB(240, 245, 250),
				Material = Enum.Material.Glass,
				Anchored = false,
				Parent = parent,
			})
			-- A cylinder lies on its own X, so stand it upright.
			bottle.CFrame = CFrame.new(bottle.Position) * CFrame.Angles(0, 0, math.rad(90))
			bottle:SetAttribute("Carnival", "Bottle")
			table.insert(stack.bottles, bottle)
		end
	end
end

local function buildMilkBottles(at: Vector3, parent: Instance)
	table.clear(bottleStacks)
	for index = -1, 1 do
		local shelfAt = at + Vector3.new(index * 22, 8, 0)
		Util.Part({
			Name = "BottleShelf",
			Size = Vector3.new(18, 1.6, 8),
			CFrame = CFrame.new(shelfAt - Vector3.new(0, 0.8, 0)),
			Color = Color3.fromRGB(104, 76, 50),
			Material = Enum.Material.Wood,
			Parent = parent,
		})
		-- The legs, so the shelf is not floating.
		for _, side in { -1, 1 } do
			Util.Part({
				Name = "ShelfLeg",
				Size = Vector3.new(1.4, 7.4, 1.4),
				CFrame = CFrame.new(shelfAt + Vector3.new(side * 7.5, -5.2, 0)),
				Color = Color3.fromRGB(88, 64, 42),
				Material = Enum.Material.Wood,
				Parent = parent,
			})
		end

		local stack = { bottles = {}, shelf = shelfAt, cleared = false }
		stackBottles(stack, parent)
		table.insert(bottleStacks, stack)
	end
	sign(parent, at + Vector3.new(0, 1, 12), "MILK BOTTLES", Color3.fromRGB(240, 240, 250))
end

--[[ A bottle took a hit: shove it, and pay out if its stack is swept. ]]
local function knockBottle(part: BasePart, shooter: Player?, direction: Vector3?): boolean
	local push = direction or Vector3.new(0, 0, -1)
	local flat = Vector3.new(push.X, 0, push.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end
	part.AssemblyLinearVelocity = flat.Unit * 70 + Vector3.new(0, 26, 0)
	Sound.At("Hitmarker", part.Position, 0.8)
	award(shooter, Config.Carnival.BottlePoints, "BOTTLE")

	for _, stack in bottleStacks do
		if stack.cleared then
			continue
		end
		local standing = 0
		for _, bottle in stack.bottles do
			-- Still on the shelf if it has not dropped below it.
			if bottle.Parent and bottle.Position.Y > stack.shelf.Y - 1 then
				standing += 1
			end
		end
		if standing == 0 then
			stack.cleared = true
			award(shooter, Config.Carnival.BottleStackBonus, "STACK CLEARED!")
			Sound.At("RoundEnd", stack.shelf, 0.9)

			local parent = container
			task.delay(Config.Carnival.ResetSeconds, function()
				if parent and parent.Parent then
					for _, old in stack.bottles do
						if old.Parent then
							old:Destroy()
						end
					end
					stackBottles(stack, parent)
				end
			end)
		end
	end
	return true
end

--[[
	Whack-a-mole, played with a gun.

	Heads pop up out of holes for a moment and drop back. Shoot one while it
	is up and it counts; the holes are on their own timers so the pattern is
	never the same twice.
]]
type Mole = { head: Part, home: Vector3, upUntil: number, nextUpAt: number, up: boolean }
local moles: { Mole } = {}

local function buildMoles(at: Vector3, parent: Instance)
	table.clear(moles)

	Util.Part({
		Name = "MoleTable",
		Size = Vector3.new(36, 3, 24),
		CFrame = CFrame.new(at + Vector3.new(0, 8, 0)),
		Color = Color3.fromRGB(70, 110, 72),
		Material = Enum.Material.Grass,
		Parent = parent,
	})

	for column = -1, 1 do
		for row = -1, 1 do
			local holeAt = at + Vector3.new(column * 11, 9.5, row * 7)
			Util.Part({
				Name = "MoleHole",
				Size = Vector3.new(5.6, 0.6, 5.6),
				CFrame = CFrame.new(holeAt),
				Shape = Enum.PartType.Cylinder,
				Color = Color3.fromRGB(44, 34, 26),
				Material = Enum.Material.Ground,
				CanCollide = false,
				Parent = parent,
			})

			local head = Util.Part({
				Name = "Mole",
				Size = Vector3.new(4.4, 4.4, 4.4),
				-- Starts sunk into the table, so it has somewhere to rise from.
				CFrame = CFrame.new(holeAt - Vector3.new(0, 4.5, 0)),
				Shape = Enum.PartType.Ball,
				Color = Color3.fromRGB(128, 94, 62),
				Material = Enum.Material.Fabric,
				Parent = parent,
			})
			head:SetAttribute("Carnival", "Mole")

			table.insert(moles, {
				head = head,
				home = holeAt,
				upUntil = 0,
				nextUpAt = os.clock() + math.random() * 3,
				up = false,
			})
		end
	end
	sign(parent, at + Vector3.new(0, 1, 16), "WHACK-A-MOLE", Color3.fromRGB(150, 220, 150))
end

local function whackMole(part: BasePart, shooter: Player?): boolean
	for _, mole in moles do
		if mole.head == part then
			if not mole.up then
				-- Shooting a sunk mole is shooting the table.
				return true
			end
			mole.up = false
			mole.upUntil = 0
			mole.nextUpAt = os.clock() + Config.Carnival.MoleDownSeconds
			mole.head.CFrame = CFrame.new(mole.home - Vector3.new(0, 4.5, 0))
			Sound.At("Hitmarker", part.Position, 1)
			award(shooter, Config.Carnival.MolePoints, "WHACK!")
			return true
		end
	end
	return false
end

--[[
	The cannon range.

	A cannon you aim and fire at stacks of crates, and the whole stack is
	real physics -- so a shot into the base brings the lot down and a shot
	at the top knocks one crate off. Clearing a stack pays out.

	This is the knock-them-over game, and the reason it works is that none
	of it is scripted: the cannonball is a heavy ball, the crates are
	unanchored boxes, and Roblox does the rest.
]]
type CrateStack = { crates: { BasePart }, base: Vector3, cleared: boolean }
local crateStacks: { CrateStack } = {}
local cannonBarrel: BasePart? = nil

local function stackCrates(stack: CrateStack, parent: Instance)
	table.clear(stack.crates)
	stack.cleared = false
	-- A tower four high, two wide at the bottom, one at the top.
	local layout = { 3, 3, 2, 1 }
	for level, count in layout do
		for index = 1, count do
			local crate = Util.Part({
				Name = "Crate",
				Size = Vector3.new(6, 6, 6),
				CFrame = CFrame.new(stack.base + Vector3.new(
					-(count - 1) * 3.2 + (index - 1) * 6.4,
					3 + (level - 1) * 6.2,
					0
				)),
				Color = Color3.fromRGB(150, 110, 66),
				Material = Enum.Material.WoodPlanks,
				Anchored = false,
				Parent = parent,
			})
			crate:SetAttribute("Carnival", "Crate")
			crate:SetAttribute("Destructible", true)
			table.insert(stack.crates, crate)
		end
	end
end

local function buildCannonRange(at: Vector3, parent: Instance)
	table.clear(crateStacks)

	-- The cannon itself: a carriage, a barrel, and a prompt to fire it.
	Util.Part({
		Name = "CannonCarriage",
		Size = Vector3.new(10, 5, 14),
		CFrame = CFrame.new(at + Vector3.new(0, 3, 0)),
		Color = Color3.fromRGB(70, 54, 40),
		Material = Enum.Material.Wood,
		Parent = parent,
	})

	local barrel = Util.Part({
		Name = "CannonBarrel",
		Size = Vector3.new(5, 5, 18),
		CFrame = CFrame.new(at + Vector3.new(0, 8, -6)) * CFrame.Angles(math.rad(-16), 0, 0),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(44, 46, 52),
		Material = Enum.Material.Metal,
		Parent = parent,
	})
	-- A cylinder points along its own X, so turn it to face down the range.
	barrel.CFrame = CFrame.new(at + Vector3.new(0, 8, -6))
		* CFrame.Angles(0, math.rad(90), 0)
		* CFrame.Angles(0, 0, math.rad(16))
	barrel:SetAttribute("Carnival", "Cannon")
	cannonBarrel = barrel

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CannonPrompt"
	prompt.ActionText = "Fire the cannon"
	prompt.ObjectText = "Cannon"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 18
	prompt.RequiresLineOfSight = false
	prompt.Parent = barrel
	prompt.Triggered:Connect(function(player)
		CarnivalService.FireCannon(player)
	end)

	-- Three stacks down the range, further away for more points.
	for index = 1, 3 do
		local stack: CrateStack = {
			crates = {},
			base = at + Vector3.new((index - 2) * 30, 1, -70 - index * 24),
			cleared = false,
		}
		stackCrates(stack, parent)
		table.insert(crateStacks, stack)
	end

	sign(parent, at + Vector3.new(0, 1, 12), "CANNON RANGE", Color3.fromRGB(255, 180, 90))
end

--[[ Fire a cannonball down the range. Heavy, slow, and entirely physics. ]]
function CarnivalService.FireCannon(player: Player?)
	local barrel = cannonBarrel
	if not barrel or not barrel.Parent or not container then
		return
	end

	local now = os.clock()
	if now < nextCannonAt then
		return
	end
	nextCannonAt = now + Config.Carnival.CannonCooldown

	-- Down the range, which is the barrel's own forward.
	local muzzle = barrel.Position + Vector3.new(0, 2, -12)
	local ball = Util.Part({
		Name = "Cannonball",
		Size = Vector3.new(5, 5, 5),
		CFrame = CFrame.new(muzzle),
		Shape = Enum.PartType.Ball,
		Color = Color3.fromRGB(30, 30, 34),
		Material = Enum.Material.Metal,
		Anchored = false,
		-- Heavy, so it goes through a stack rather than bouncing off it.
		CustomPhysicalProperties = PhysicalProperties.new(6, 0.4, 0.2, 1, 1),
		Parent = container,
	})
	ball.AssemblyLinearVelocity = Vector3.new(0, 42, -1) * 2 + Vector3.new(0, 0, -150)
	Sound.At("ExplosionBig", muzzle, 0.7)
	Util.DestroyAfter(ball, 12)

	if player then
		lastCannonFirer = player
	end
end

--[[ Did a stack get swept? Checked after anything disturbs the crates. ]]
local function checkCrateStacks()
	for _, stack in crateStacks do
		if stack.cleared then
			continue
		end
		local standing = 0
		for _, crate in stack.crates do
			if crate.Parent and crate.Position.Y > stack.base.Y + 1 then
				standing += 1
			end
		end
		if standing == 0 then
			stack.cleared = true
			award(lastCannonFirer, Config.Carnival.CrateStackBonus, "STACK FLATTENED!")
			Sound.At("RoundEnd", stack.base, 1)

			local parent = container
			task.delay(Config.Carnival.ResetSeconds, function()
				if parent and parent.Parent then
					for _, old in stack.crates do
						if old.Parent then
							old:Destroy()
						end
					end
					stackCrates(stack, parent)
				end
			end)
		end
	end
end

function CarnivalService.RegisterHit(part: BasePart, attacker: Player?, direction: Vector3?): boolean
	local game_ = part:GetAttribute("Carnival")
	if game_ == "Dunk" then
		dunk(attacker)
		return true
	elseif game_ == "Duck" then
		hitDuck(part, attacker)
		return true
	elseif game_ == "Striker" then
		ringBell(attacker)
		return true
	elseif game_ == "Balloon" then
		return popBalloon(part, attacker)
	elseif game_ == "Bottle" then
		return knockBottle(part, attacker, direction)
	elseif game_ == "Mole" then
		return whackMole(part, attacker)
	elseif game_ == "Crate" then
		-- A bullet nudges a crate; the cannon is what flattens a stack.
		local push = direction or Vector3.new(0, 0, -1)
		part.AssemblyLinearVelocity = push * 40 + Vector3.new(0, 18, 0)
		if attacker then
			lastCannonFirer = attacker
		end
		award(attacker, Config.Carnival.CratePoints, "CRATE")
		return true
	elseif game_ == "Cannon" then
		CarnivalService.FireCannon(attacker)
		return true
	end
	return false
end

--[[ Put the fairground up, off to one side of the arena. ]]
function CarnivalService.Build(mapSize: number)
	CarnivalService.Clear()

	local folder = Instance.new("Folder")
	folder.Name = "Carnival"
	folder.Parent = workspace
	container = folder

	-- Off to one side, clear of the bases at either end.
	origin = Vector3.new(mapSize * 0.3, 0, 0)

	Util.Part({
		Name = "CarnivalGround",
		Size = Vector3.new(160, 1, 130),
		CFrame = CFrame.new(origin + Vector3.new(0, 0.6, 0)),
		Color = Color3.fromRGB(140, 120, 96),
		Material = Enum.Material.Sand,
		Parent = folder,
	})

	buildDunkTank(origin + Vector3.new(-45, 1, 0), folder)
	buildGallery(origin + Vector3.new(30, 1, -30), folder)
	buildStriker(origin + Vector3.new(35, 1, 35), folder)
	buildBalloonPop(origin + Vector3.new(-10, 1, -48), folder)
	buildMilkBottles(origin + Vector3.new(62, 1, -6), folder)
	buildMoles(origin + Vector3.new(-62, 1, 42), folder)
	buildCannonRange(origin + Vector3.new(0, 1, 56), folder)

	-- Overhead warm fairground festoon string lights for Future-lighting ambience.
	for idx, lightPos in {
		origin + Vector3.new(-20, 26, -15),
		origin + Vector3.new(10, 26, 0),
		origin + Vector3.new(32, 26, 15),
	} do
		local bulb = Util.Part({
			Name = "FairgroundBulb",
			Size = Vector3.new(1.8, 1.8, 1.8),
			CFrame = CFrame.new(lightPos),
			Shape = Enum.PartType.Ball,
			Color = if idx % 2 == 1 then Color3.fromRGB(255, 220, 130) else Color3.fromRGB(255, 160, 110),
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
		local glow = Instance.new("PointLight")
		glow.Color = bulb.Color
		glow.Brightness = 3.2
		glow.Range = 55
		glow.Shadows = true
		glow.Parent = bulb
	end

	-- Offered as a sub-game, so "fair games" is something you can pick from
	-- a menu rather than something you have to stumble across.
	ArcadeService.Register({
		id = "carnival",
		name = "Fair Games",
		objective = "Dunk tank, duck shoot and the high striker. All of it scores.",
		centre = Vector3.new(mapSize * 0.3, 0, 0),
		spawns = {
			Vector3.new(mapSize * 0.3 - 40, 6, 0),
			Vector3.new(mapSize * 0.3 + 40, 6, 0),
			Vector3.new(mapSize * 0.3, 6, 40),
		},
		perTeam = 2,
		teamed = false,
	})
end

function CarnivalService.Clear()
	if container then
		container:Destroy()
		container = nil
	end
	table.clear(ducks)
	dunkSeat = nil
	strikerPuck = nil
	dunkWetUntil = 0
	strikerUntil = 0
end

--[[ Ducks slide back and forth; a shot one lies down for a moment. ]]
local function step()
	if not container then
		return
	end
	local now = os.clock()

	--[[
		The moles, rising and dropping on their own timers.

		Each hole runs independently, so the pattern is never the same twice
		-- which is the only thing that makes a grid of nine holes a game
		rather than a shooting drill.
	]]
	for _, mole in moles do
		if not mole.head.Parent then
			continue
		end
		if mole.up then
			if now >= mole.upUntil then
				mole.up = false
				mole.nextUpAt = now + Config.Carnival.MoleDownSeconds * (0.6 + math.random())
				mole.head.CFrame = CFrame.new(mole.home - Vector3.new(0, 4.5, 0))
			end
		elseif now >= mole.nextUpAt then
			mole.up = true
			mole.upUntil = now + Config.Carnival.MoleUpSeconds
			mole.head.CFrame = CFrame.new(mole.home + Vector3.new(0, 1.6, 0))
		end
	end

	-- Has a crate stack been flattened? Checked here rather than on every
	-- bullet, because a stack comes down over a second or two of physics
	-- and the shot that started it has long since been resolved.
	checkCrateStacks()

	--[[
		The moles, rising and dropping on their own timers.

		Each hole runs independently, so the pattern is never the same twice
		-- which is the only thing that makes a grid of nine holes a game
		rather than a shooting drill.
	]]
	for _, mole in moles do
		if not mole.head.Parent then
			continue
		end
		if mole.up then
			if now >= mole.upUntil then
				mole.up = false
				mole.nextUpAt = now + Config.Carnival.MoleDownSeconds * (0.6 + math.random())
				mole.head.CFrame = CFrame.new(mole.home - Vector3.new(0, 4.5, 0))
			end
		elseif now >= mole.nextUpAt then
			mole.up = true
			mole.upUntil = now + Config.Carnival.MoleUpSeconds
			mole.head.CFrame = CFrame.new(mole.home + Vector3.new(0, 1.6, 0))
		end
	end

	-- Has a crate stack been flattened? Checked here rather than on every
	-- bullet, because a stack comes down over a second or two of physics
	-- and the shot that started it has long since been resolved.
	checkCrateStacks()

	for _, duck in ducks do
		if not duck.part.Parent then
			continue
		end
		if now < duck.downUntil then
			-- Tipped over backwards.
			duck.part.CFrame = CFrame.new(duck.centre) * CFrame.Angles(math.rad(-80), 0, 0)
		else
			local slide = math.sin(now * duck.speed + duck.phase) * duck.span
			duck.part.CFrame = CFrame.new(duck.centre + Vector3.new(slide, 0, 0))
		end
	end

	-- The puck sits at the bottom, then rides up the tower when the bell is
	-- rung and slides back down afterwards.
	local puck = strikerPuck
	if puck and puck.Parent then
		local remaining = strikerUntil - now
		local climbed = 0
		if remaining > 0 then
			local elapsed = 2.5 - remaining
			if elapsed < 0.45 then
				local t = elapsed / 0.45
				climbed = (1 - (1 - t) * (1 - t)) * 56
			else
				local t = (elapsed - 0.45) / 2.05
				climbed = (1 - t * t) * 56
			end
		end
		puck.CFrame = CFrame.new(puck.Position.X, origin.Y + 5 + climbed, puck.Position.Z)
	end
end

RunService.Heartbeat:Connect(step)

return CarnivalService
