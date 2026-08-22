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
local Util = require(Shared:WaitForChild("Util"))

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

local function award(player: Player?, points: number, message: string)
	if not player then
		return
	end
	local earned = PlayerState.AwardPoints(player, points)
	Remotes.Event("Notify"):FireClient(player, `{message} +{earned}`)
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
		if humanoid and humanoid.Health > 0 and not humanoid.SeatPart then
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
		Size = Vector3.new(4.6, 4.6, 0.3),
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
		occupant.Sit = false

		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			root.CFrame = CFrame.new(seat.Position - Vector3.new(0, 14, 0))
			root.AssemblyLinearVelocity = Vector3.zero
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
	award(shooter, STRIKER_POINTS, "DING! Bell rung.")
end

-- ================================================================== PUBLIC ==

--[[ Something was shot. Returns true if it was a carnival prop. ]]
function CarnivalService.RegisterHit(part: BasePart, attacker: Player?): boolean
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
end

function CarnivalService.Clear()
	if container then
		container:Destroy()
		container = nil
	end
	table.clear(ducks)
	dunkSeat = nil
	strikerPuck = nil
end

--[[ Ducks slide back and forth; a shot one lies down for a moment. ]]
local function step()
	if not container then
		return
	end
	local now = os.clock()

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
		local climbed = if remaining > 0 then (1 - remaining / 2.5) * 56 else 0
		puck.CFrame = CFrame.new(puck.Position.X, origin.Y + 4 + climbed, puck.Position.Z)
	end
end

RunService.Heartbeat:Connect(step)

return CarnivalService
