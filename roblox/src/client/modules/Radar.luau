--!strict
--[[
	Nuclear Mud Arena — the motion tracker.

	Halo's radar is the single most recognisable thing on its HUD, and it
	changes how the game is played rather than just how it looks: you push
	into a building because the tracker is empty, you back out because two
	red dots appeared behind you. Without one, a twenty-player map with this
	many corners is all ambushes.

	It works the way Halo's did:

	  - You are the centre, and the sweep is oriented to where you are
	    FACING, not to north. Turn around and the dots swing round with you.
	  - Enemies are red, team-mates are the softer team colour.
	  - A dot above you sits on a lighter ring, below you on a darker one,
	    because a map with roofs and basements is unreadable flat.

	All of it is read straight off the replicated characters, so the server
	does no work and sends no extra traffic for it.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local player = Players.LocalPlayer

local Radar = {}

local SIZE = 164 -- pixels across
local DOT = 10
local MAX_DOTS = 24 -- the dot pool; a 20-player server cannot exceed this

-- How far the tracker sees. Halo's was deliberately short: far enough to
-- stop you being walked up on, short enough that it never replaced looking.
local RANGE = Config.Radar and Config.Radar.Range or 170
local VERTICAL_RANGE = Config.Radar and Config.Radar.VerticalRange or 60

local holder: Frame? = nil
local dots: { Frame } = {}
local sweep: Frame? = nil
local sweepAngle = 0
local nextRefresh = 0
local started = false

local function makeDot(parent: Instance): Frame
	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(DOT, DOT)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.BorderSizePixel = 0
	dot.Visible = false
	dot.ZIndex = 3
	dot.Parent = parent

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = dot

	local edge = Instance.new("UIStroke")
	edge.Color = Color3.fromRGB(10, 14, 18)
	edge.Thickness = 1.4
	edge.Parent = dot

	return dot
end

--[[ Build the dial. Call once, from the HUD. ]]
function Radar.Build(screen: Instance): Frame
	local dial = Instance.new("Frame")
	dial.Name = "MotionTracker"
	dial.Size = UDim2.fromOffset(SIZE, SIZE)
	dial.Position = UDim2.new(0, 24, 1, -(SIZE + 120))
	dial.BackgroundColor3 = Color3.fromRGB(8, 20, 16)
	dial.BackgroundTransparency = 0.35
	dial.BorderSizePixel = 0
	dial.Parent = screen

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = dial

	local rim = Instance.new("UIStroke")
	rim.Color = Color3.fromRGB(110, 220, 170)
	rim.Thickness = 2
	rim.Transparency = 0.25
	rim.Parent = dial

	-- Range rings, so a dot's distance is readable rather than guessed.
	for _, fraction in { 0.33, 0.66 } do
		local ring = Instance.new("Frame")
		ring.AnchorPoint = Vector2.new(0.5, 0.5)
		ring.Position = UDim2.fromScale(0.5, 0.5)
		ring.Size = UDim2.fromScale(fraction, fraction)
		ring.BackgroundTransparency = 1
		ring.BorderSizePixel = 0
		ring.Parent = dial

		local ringRound = Instance.new("UICorner")
		ringRound.CornerRadius = UDim.new(1, 0)
		ringRound.Parent = ring

		local ringEdge = Instance.new("UIStroke")
		ringEdge.Color = Color3.fromRGB(110, 220, 170)
		ringEdge.Thickness = 1
		ringEdge.Transparency = 0.72
		ringEdge.Parent = ring
	end

	-- The sweep, which is what makes it read as a live instrument rather
	-- than a picture of one.
	local hand = Instance.new("Frame")
	hand.Name = "Sweep"
	hand.AnchorPoint = Vector2.new(0.5, 1)
	hand.Position = UDim2.fromScale(0.5, 0.5)
	hand.Size = UDim2.fromOffset(2, SIZE * 0.5 - 4)
	hand.BackgroundColor3 = Color3.fromRGB(150, 255, 200)
	hand.BackgroundTransparency = 0.55
	hand.BorderSizePixel = 0
	hand.ZIndex = 2
	hand.Parent = dial
	sweep = hand

	-- You, at the centre, pointing up the way you are facing.
	local you = Instance.new("Frame")
	you.AnchorPoint = Vector2.new(0.5, 0.5)
	you.Position = UDim2.fromScale(0.5, 0.5)
	you.Size = UDim2.fromOffset(6, 6)
	you.BackgroundColor3 = Color3.fromRGB(240, 250, 255)
	you.BorderSizePixel = 0
	you.ZIndex = 4
	you.Parent = dial

	local youRound = Instance.new("UICorner")
	youRound.CornerRadius = UDim.new(1, 0)
	youRound.Parent = you

	-- A fixed pool. Creating and destroying frames every refresh is the one
	-- thing that would make a radar cost more than it is worth.
	for _ = 1, MAX_DOTS do
		table.insert(dots, makeDot(dial))
	end

	holder = dial
	return dial
end

--[[
	Where the local player is and which way they are looking.

	Facing comes from the CAMERA, not the character: on foot the body turns
	to follow the camera anyway, and in a vehicle the body faces wherever
	the seat points while the player is looking somewhere else entirely.
]]
local function viewerFrame(): (Vector3?, Vector3?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil, nil
	end

	local camera = Workspace.CurrentCamera
	local look = if camera then camera.CFrame.LookVector else root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.001 then
		flat = Vector3.new(0, 0, -1)
	end

	return root.Position, flat.Unit
end

local function refresh()
	local dial = holder
	if not dial then
		return
	end

	local from, facing = viewerFrame()
	if not from or not facing then
		-- Dead or still loading: blank it rather than freezing the last frame.
		for _, dot in dots do
			dot.Visible = false
		end
		dial.BackgroundTransparency = 0.7
		return
	end

	dial.BackgroundTransparency = 0.35

	-- Facing is the dial's "up", so the sideways axis is facing turned 90
	-- degrees about Y.
	local right = Vector3.new(-facing.Z, 0, facing.X)
	local radius = SIZE * 0.5 - DOT * 0.75
	local myTeam = player.Team
	local used = 0

	for _, other in Players:GetPlayers() do
		if other == player or used >= MAX_DOTS then
			continue
		end

		local character = other.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
			continue
		end

		local offset = root.Position - from
		local flat = Vector3.new(offset.X, 0, offset.Z)
		if flat.Magnitude > RANGE or math.abs(offset.Y) > VERTICAL_RANGE then
			continue
		end

		used += 1
		local dot = dots[used]

		-- Project into the dial's own axes.
		local forward = flat:Dot(facing) / RANGE
		local sideways = flat:Dot(right) / RANGE

		-- Screen Y grows downward, so forward is negative.
		dot.Position = UDim2.new(0.5, sideways * radius, 0.5, -forward * radius)

		-- Enemies red, team-mates yellow -- fixed colours, NOT the team's own.
		-- Tinting allies with the team colour looks tidier and is useless in
		-- practice: on the Red team every dot on the dial comes out red and
		-- the tracker stops answering the only question it is for. Halo used
		-- red and yellow for this reason whichever side you were on.
		local friendly = myTeam ~= nil and other.Team == myTeam
		local base = if friendly
			then Color3.fromRGB(255, 212, 64)
			else Color3.fromRGB(235, 60, 50)

		-- Lighter when they are above you, darker when below. Guessing at an
		-- elevation on a map with roofs and basements is most of what makes a
		-- flat radar useless.
		local lift = math.clamp(offset.Y / VERTICAL_RANGE, -1, 1)
		dot.BackgroundColor3 = if lift > 0.08
			then base:Lerp(Color3.new(1, 1, 1), lift * 0.55)
			elseif lift < -0.08 then base:Lerp(Color3.new(0, 0, 0), -lift * 0.5)
			else base

		-- Nearer reads bigger, which is the cheapest possible depth cue.
		local nearness = 1 - flat.Magnitude / RANGE
		local pixels = math.floor(DOT * (0.7 + nearness * 0.5) + 0.5)
		dot.Size = UDim2.fromOffset(pixels, pixels)
		dot.Visible = true
	end

	for index = used + 1, MAX_DOTS do
		dots[index].Visible = false
	end
end

--[[ Start sweeping. ]]
function Radar.Start()
	if started then
		return
	end
	started = true

	RunService.RenderStepped:Connect(function(deltaTime: number)
		if not holder then
			return
		end

		-- The sweep runs every frame, because it is the only part anyone
		-- would notice stuttering.
		sweepAngle = (sweepAngle + deltaTime * 170) % 360
		if sweep then
			sweep.Rotation = sweepAngle
		end

		-- The dots do not. Fifteen times a second is faster than anybody
		-- reacts, and it keeps a twenty-player scan off the frame budget.
		local now = os.clock()
		if now >= nextRefresh then
			nextRefresh = now + 1 / 15
			refresh()
		end
	end)
end

--[[
	Run one refresh now, for tests.

	The real one is driven from the render loop at 15 Hz, which a headless
	test has no way to wait for.
]]
function Radar.RefreshForTests()
	refresh()
end

--[[
	What the visible dots currently say, for tests.

	Returned in pixels from the centre and as colours, because those are the
	two things that have to be right: a contact behind you plotting behind
	you, and an enemy reading as an enemy.
]]
function Radar.ContactsForTests(): { { offsetX: number, offsetY: number, color: Color3 } }
	local out = {}
	for _, dot in dots do
		if dot.Visible then
			table.insert(out, {
				offsetX = dot.Position.X.Offset,
				offsetY = dot.Position.Y.Offset,
				color = dot.BackgroundColor3,
			})
		end
	end
	return out
end

--[[ Current dot count, for tests. ]]
function Radar.VisibleContacts(): number
	local total = 0
	for _, dot in dots do
		if dot.Visible then
			total += 1
		end
	end
	return total
end

return Radar
