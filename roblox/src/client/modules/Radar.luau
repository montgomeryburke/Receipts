--!strict
--[[
	Nuclear Mud Arena — the motion tracker.

	Halo-style relative radar oriented to camera facing, with elevation shading
	and properly centered sweep rotation.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local player = Players.LocalPlayer

local Radar = {}

local SIZE = 164
local DOT = 10
local MAX_DOTS = 24

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

--[[ Build the dial. Safe to re-call without leaking dots or frames. ]]
function Radar.Build(screen: Instance): Frame
	if holder then
		holder:Destroy()
		holder = nil
	end
	table.clear(dots)
	sweep = nil

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

	-- Full-size pivot wrapper centered on the dial so Rotation pivots cleanly
	-- around (0.5, 0.5) instead of around the line's midpoint.
	local sweepPivot = Instance.new("Frame")
	sweepPivot.Name = "SweepPivot"
	sweepPivot.AnchorPoint = Vector2.new(0.5, 0.5)
	sweepPivot.Position = UDim2.fromScale(0.5, 0.5)
	sweepPivot.Size = UDim2.fromScale(1, 1)
	sweepPivot.BackgroundTransparency = 1
	sweepPivot.BorderSizePixel = 0
	sweepPivot.ZIndex = 2
	sweepPivot.Parent = dial

	local hand = Instance.new("Frame")
	hand.Name = "Sweep"
	hand.AnchorPoint = Vector2.new(0.5, 1)
	hand.Position = UDim2.fromScale(0.5, 0.5)
	hand.Size = UDim2.fromOffset(2, SIZE * 0.5 - 4)
	hand.BackgroundColor3 = Color3.fromRGB(150, 255, 200)
	hand.BackgroundTransparency = 0.55
	hand.BorderSizePixel = 0
	hand.ZIndex = 2
	hand.Parent = sweepPivot
	sweep = sweepPivot

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

	for _ = 1, MAX_DOTS do
		table.insert(dots, makeDot(dial))
	end

	holder = dial
	return dial
end

local function viewerFrame(): (Vector3?, Vector3?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
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
		for _, dot in dots do
			dot.Visible = false
		end
		dial.BackgroundTransparency = 0.7
		return
	end

	dial.BackgroundTransparency = 0.35

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

		local forward = flat:Dot(facing) / RANGE
		local sideways = flat:Dot(right) / RANGE

		dot.Position = UDim2.new(0.5, sideways * radius, 0.5, -forward * radius)

		local friendly = myTeam ~= nil and other.Team == myTeam
		local base = if friendly
			then Color3.fromRGB(255, 212, 64)
			else Color3.fromRGB(235, 60, 50)

		local lift = math.clamp(offset.Y / VERTICAL_RANGE, -1, 1)
		dot.BackgroundColor3 = if lift > 0.08
			then base:Lerp(Color3.new(1, 1, 1), lift * 0.55)
			elseif lift < -0.08 then base:Lerp(Color3.new(0, 0, 0), -lift * 0.5)
			else base

		local nearness = 1 - flat.Magnitude / RANGE
		local pixels = math.floor(DOT * (0.7 + nearness * 0.5) + 0.5)
		dot.Size = UDim2.fromOffset(pixels, pixels)
		dot.Visible = true
	end

	for index = used + 1, MAX_DOTS do
		dots[index].Visible = false
	end
end

function Radar.Start()
	if started then
		return
	end
	started = true

	RunService.RenderStepped:Connect(function(deltaTime: number)
		if not holder then
			return
		end

		sweepAngle = (sweepAngle + deltaTime * 170) % 360
		if sweep then
			sweep.Rotation = sweepAngle
		end

		local now = os.clock()
		if now >= nextRefresh then
			nextRefresh = now + 1 / 15
			refresh()
		end
	end)
end

function Radar.RefreshForTests()
	refresh()
end

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
