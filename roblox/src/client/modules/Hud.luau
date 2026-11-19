--!strict
--[[
	Hud — everything drawn on top of the game.

	Built in code rather than with GUI objects in the editor, so there is
	nothing to accidentally drag out of place, and changing the layout is a
	matter of editing numbers here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))
local Radar = require(script.Parent:WaitForChild("Radar"))

local player = Players.LocalPlayer

local Hud = {}

-- Low-health warning and the scoreboard, declared up here with the rest of
-- the widgets so every function can reach them.
local lowHealthHolder: Frame? = nil
-- The directional damage arcs: a small ring of reusable blades, lit on the
-- bearing a hit came from.
local hurtHolder: Frame? = nil
local hurtBlades: { Frame } = {}
local nextHurtBlade = 1
local vignetteStrength = 0
local vignettePulse = 0
local scoreboard: Frame? = nil
local scoreboardRows: ScrollingFrame? = nil
local scoreboardTitle: TextLabel? = nil

local screen: ScreenGui
local healthFill: Frame
local healthText: TextLabel
local shieldFill: Frame
local shieldTrack: Frame
local turboText: TextLabel
local statusText: TextLabel
local zoomText: TextLabel
local scope: Frame
local lastMagnification = 0
local hitmarker: Frame
local damageHolder: Frame
local killFeed: Frame
local medalLabel: TextLabel
local weaponBar: Frame
local slotChips: { [number]: TextLabel } = {}

--[[
	How many weapon slots the bar needs.

	Read off Config rather than written down, because it was written down as
	6 while the weapon table had grown a 7th -- so poop and the hunter drone
	had no chip on the bar and picking one up showed nothing at all.
]]
local SLOT_COUNT = (function(): number
	local highest = 1
	for _, spec in Config.Weapons do
		if spec.Slot > highest then
			highest = spec.Slot
		end
	end
	return highest
end)()
local weaponLabel: TextLabel
local ammoLabel: TextLabel
local statsLabel: TextLabel
local clockLabel: TextLabel
local scoreLabel: TextLabel
local crosshair: Frame
local votePanel: Frame
local deathOverlay: Frame
local deathTitle: TextLabel? = nil
local respawnLabel: TextLabel? = nil
local respawnToken = 0
local fightLabel: TextLabel? = nil
local fightCount: TextLabel? = nil
local fightMineBar: Frame? = nil
local fightMineFill: Frame? = nil
local fightTheirsBar: Frame? = nil
local fightTheirsFill: Frame? = nil
local fightToken = 0
local arcadePanel: Frame? = nil
local arcadeList: Frame? = nil
local arcadeOffer: TextLabel? = nil
local arcadeOfferToken = 0
local arcadeChoices: { [string]: TextButton } = {}
local arcadePick: ((string) -> ())? = nil
local wienerOverlay: TextLabel
local toastHolder: Frame
local actionBar: Frame? = nil
local helpPanel: Frame? = nil
local helpBody: ScrollingFrame? = nil
local helpTravel: ScrollingFrame? = nil
local helpSearch: TextBox? = nil
local helpTabButtons: { [string]: TextButton } = {}
local helpTab = "play"
local helpTravelHandler: ((string) -> ())? = nil
local puckLabel: TextLabel? = nil

-- ================================================================ BUILDING ==

local function makeFrame(parent: Instance, props: { [string]: any }): Frame
	local frame = Instance.new("Frame")
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = Color3.fromRGB(20, 22, 26)
	for key, value in props do
		(frame :: any)[key] = value
	end
	frame.Parent = parent
	return frame
end

local function makeLabel(parent: Instance, props: { [string]: any }): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(240, 245, 250)
	label.TextStrokeTransparency = 0.5
	label.TextXAlignment = Enum.TextXAlignment.Left
	for key, value in props do
		(label :: any)[key] = value
	end
	label.Parent = parent
	return label
end

--[[
	A bar with a coloured fill, used for both health and shield.
	Returns the track and the fill, because the shield bar needs to hide the
	whole track when you have no shield at all.
]]
local function makeBar(parent: Instance, position: UDim2, colour: Color3): (Frame, Frame)
	local track = makeFrame(parent, {
		Size = UDim2.fromOffset(280, 18),
		Position = position,
		BackgroundColor3 = Color3.fromRGB(16, 18, 22),
		BackgroundTransparency = 0.25,
	})
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = track

	local fill = makeFrame(track, {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = colour,
	})
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	return track, fill
end

local hudBuilt = false
local hitToken = 0
local medalToken = 0
local wienerToken = 0
local killFeedOrder = 100000

function Hud.Build()
	if hudBuilt and screen and screen.Parent then
		return
	end
	hudBuilt = true
	screen = Instance.new("ScreenGui")
	screen.Name = "NuclearMudHud"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = player:WaitForChild("PlayerGui")

	-- ---------------------------------------------------------- top centre
	clockLabel = makeLabel(screen, {
		Size = UDim2.fromOffset(360, 40),
		Position = UDim2.new(0.5, -180, 0, 12),
		Text = "WARMUP",
		TextSize = 30,
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	scoreLabel = makeLabel(screen, {
		Size = UDim2.fromOffset(360, 26),
		Position = UDim2.new(0.5, -180, 0, 50),
		Text = "RED 0   —   BLUE 0",
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	-- -------------------------------------------------------- bottom left
	makeLabel(screen, {
		Size = UDim2.fromOffset(120, 18),
		Position = UDim2.new(0, 24, 1, -96),
		Text = "HEALTH",
		TextSize = 13,
		TextColor3 = Color3.fromRGB(170, 180, 190),
	})

	-- The number, sitting right on the bar so it is readable at a glance and
	-- never leaves the screen.
	healthText = makeLabel(screen, {
		Size = UDim2.fromOffset(280, 18),
		Position = UDim2.new(0, 24, 1, -78),
		Text = "100%",
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 3,
	})

	turboText = makeLabel(screen, {
		Size = UDim2.fromOffset(280, 18),
		Position = UDim2.new(0, 24, 1, -116),
		Text = "",
		TextSize = 14,
		TextColor3 = Color3.fromRGB(255, 210, 100),
	})
	local _healthTrack, healthBarFill = makeBar(screen, UDim2.new(0, 24, 1, -78), Color3.fromRGB(230, 70, 60))
	healthFill = healthBarFill

	local shieldBarTrack, shieldBarFill = makeBar(screen, UDim2.new(0, 24, 1, -54), Color3.fromRGB(90, 180, 240))
	shieldTrack = shieldBarTrack
	shieldFill = shieldBarFill

	-- ------------------------------------------------------- bottom right
	weaponLabel = makeLabel(screen, {
		Size = UDim2.fromOffset(340, 30),
		Position = UDim2.new(1, -364, 1, -84),
		Text = "—",
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	ammoLabel = makeLabel(screen, {
		Size = UDim2.fromOffset(340, 26),
		Position = UDim2.new(1, -364, 1, -56),
		Text = "",
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Color3.fromRGB(180, 195, 210),
	})

	-- ----------------------------------------------------------- top left
	statsLabel = makeLabel(screen, {
		Size = UDim2.fromOffset(340, 110),
		Position = UDim2.new(0, 24, 0, 20),
		Text = "",
		TextSize = 17,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	-- ----------------------------------------------------------- crosshair
	crosshair = makeFrame(screen, {
		Size = UDim2.fromOffset(6, 6),
		Position = UDim2.new(0.5, -3, 0.5, -3),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0.2,
	})
	local crosshairCorner = Instance.new("UICorner")
	crosshairCorner.CornerRadius = UDim.new(1, 0)
	crosshairCorner.Parent = crosshair

	-- --------------------------------------------------------- vote panel
	votePanel = makeFrame(screen, {
		Size = UDim2.fromOffset(560, 220),
		Position = UDim2.new(0.5, -280, 0.5, -110),
		BackgroundTransparency = 0.15,
		Visible = false,
	})
	local voteCorner = Instance.new("UICorner")
	voteCorner.CornerRadius = UDim.new(0, 10)
	voteCorner.Parent = votePanel

	makeLabel(votePanel, {
		Size = UDim2.new(1, 0, 0, 40),
		Text = "VOTE FOR THE NEXT MAP",
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	local voteList = Instance.new("Frame")
	voteList.Name = "Options"
	voteList.Size = UDim2.new(1, -40, 1, -60)
	voteList.Position = UDim2.fromOffset(20, 50)
	voteList.BackgroundTransparency = 1
	voteList.Parent = votePanel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 8)
	layout.Parent = voteList

	-- ------------------------------------------------------ death overlay
	deathOverlay = makeFrame(screen, {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(180, 40, 10),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 20,
	})
	deathTitle = makeLabel(deathOverlay, {
		Name = "DeathTitle",
		Size = UDim2.fromScale(1, 1),
		Text = "YOU MELTED",
		TextSize = 64,
		Font = Enum.Font.LuckiestGuy,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 21,
	})

	-- The countdown. A death screen with no clock on it leaves you guessing
	-- whether the game has stopped responding, and the guess is always that
	-- it has.
	respawnLabel = makeLabel(deathOverlay, {
		Name = "RespawnClock",
		Size = UDim2.fromScale(1, 0.2),
		Position = UDim2.fromScale(0, 0.58),
		Text = "",
		TextSize = 34,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.fromRGB(255, 230, 180),
		ZIndex = 21,
	})

	-- ----------------------------------------------------- wiener overlay
	wienerOverlay = makeLabel(screen, {
		Size = UDim2.fromScale(1, 0.3),
		Position = UDim2.fromScale(0, 0.32),
		Text = "",
		TextSize = 72,
		Font = Enum.Font.LuckiestGuy,
		TextColor3 = Color3.fromRGB(255, 200, 120),
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		ZIndex = 22,
	})

	-- The scope. Black surround, a round lens, crosshair and mil-dots — so
	-- zooming in actually looks like looking down a sniper sight rather than
	-- just narrowing the camera.
	scope = makeFrame(screen, {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 8,
	})

	-- Two heavy bars close the view down to a letterbox, and the ring sits
	-- between them, which reads as a scope without needing any image assets.
	for _, side in { -1, 1 } do
		local bar = makeFrame(scope, {
			Size = UDim2.new(0.5, -170, 1, 0),
			Position = if side == -1 then UDim2.fromScale(0, 0) else UDim2.new(0.5, 170, 0, 0),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.02,
			ZIndex = 8,
		})
		bar.Name = "ScopeBlind"
	end
	for _, side in { -1, 1 } do
		local vbar = makeFrame(scope, {
			Size = UDim2.new(0, 340, 0.5, -170),
			Position = if side == -1 then UDim2.new(0.5, -170, 0, 0) else UDim2.new(0.5, -170, 0.5, 170),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.02,
			ZIndex = 8,
		})
		vbar.Name = "ScopeBlindV"
	end

	local lens = makeFrame(scope, {
		Size = UDim2.fromOffset(340, 340),
		Position = UDim2.new(0.5, -170, 0.5, -170),
		BackgroundTransparency = 1,
		ZIndex = 9,
	})
	local lensCorner = Instance.new("UICorner")
	lensCorner.CornerRadius = UDim.new(1, 0)
	lensCorner.Parent = lens

	local ring = Instance.new("UIStroke")
	ring.Color = Color3.new(0, 0, 0)
	ring.Thickness = 10
	ring.Parent = lens

	-- Crosshair.
	for _, vertical in { true, false } do
		local hair = makeFrame(lens, {
			Size = if vertical then UDim2.new(0, 2, 1, 0) else UDim2.new(1, 0, 0, 2),
			Position = if vertical then UDim2.new(0.5, -1, 0, 0) else UDim2.new(0, 0, 0.5, -1),
			BackgroundColor3 = Color3.fromRGB(20, 24, 20),
			BackgroundTransparency = 0.25,
			ZIndex = 10,
		})
		hair.Name = "Hair"
	end

	-- Mil-dots down the vertical, for holding over at range.
	for step = 1, 3 do
		local dot = makeFrame(lens, {
			Size = UDim2.fromOffset(6, 2),
			Position = UDim2.new(0.5, -3, 0.5, step * 26),
			BackgroundColor3 = Color3.fromRGB(20, 24, 20),
			BackgroundTransparency = 0.25,
			ZIndex = 10,
		})
		dot.Name = "MilDot"
	end

	-- Magnification, sitting just under the crosshair where your eye is.
	zoomText = makeLabel(screen, {
		Size = UDim2.fromOffset(120, 22),
		Position = UDim2.new(0.5, -60, 0.5, 18),
		Text = "",
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.fromRGB(255, 220, 120),
	})

	-- The hitmarker: four short strokes around the crosshair, flashed the
	-- instant a shot connects. Hitscan guns give you nothing else to tell
	-- you whether you are aiming anywhere near the target.
	hitmarker = makeFrame(screen, {
		Size = UDim2.fromOffset(40, 40),
		Position = UDim2.new(0.5, -20, 0.5, -20),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 12,
	})
	for _, corner in { Vector2.new(-1, -1), Vector2.new(1, -1), Vector2.new(-1, 1), Vector2.new(1, 1) } do
		local stroke = makeFrame(hitmarker, {
			Size = UDim2.fromOffset(10, 3),
			Position = UDim2.new(0.5, -5 + corner.X * 13, 0.5, -1 + corner.Y * 13),
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BackgroundTransparency = 0.05,
			ZIndex = 12,
		})
		stroke.Rotation = if corner.X * corner.Y > 0 then 45 else -45
	end

	-- Floating damage numbers, stacked up beside the crosshair.
	damageHolder = makeFrame(screen, {
		Name = "DamageNumbers",
		Size = UDim2.fromOffset(160, 150),
		Position = UDim2.new(0.5, 40, 0.5, -40),
		BackgroundTransparency = 1,
		ZIndex = 11,
	})

	-- The kill feed, top right, newest at the top.
	killFeed = makeFrame(screen, {
		Size = UDim2.fromOffset(420, 180),
		Position = UDim2.new(1, -444, 0, 96),
		BackgroundTransparency = 1,
	})
	local feedLayout = Instance.new("UIListLayout")
	feedLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	feedLayout.Padding = UDim.new(0, 4)
	feedLayout.Parent = killFeed

	-- Medals. One big line in the middle, briefly.
	medalLabel = makeLabel(screen, {
		Size = UDim2.new(1, 0, 0, 56),
		Position = UDim2.new(0, 0, 0.32, 0),
		Text = "",
		TextSize = 44,
		Font = Enum.Font.LuckiestGuy,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.fromRGB(255, 220, 120),
		ZIndex = 14,
	})

	-- The weapon bar: one chip per slot, and exactly one of them is lit.
	--
	-- This replaces a toast that fired on every weapon change. Cycling
	-- through a slot popped four toasts that sat on screen together, which
	-- read as four guns being selected at once.
	local barWidth = SLOT_COUNT * 110
	weaponBar = makeFrame(screen, {
		Size = UDim2.fromOffset(barWidth, 36),
		Position = UDim2.new(0.5, -math.floor(barWidth * 0.5), 1, -64),
		BackgroundTransparency = 1,
	})

	local barLayout = Instance.new("UIListLayout")
	barLayout.FillDirection = Enum.FillDirection.Horizontal
	barLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	barLayout.Padding = UDim.new(0, 6)
	barLayout.Parent = weaponBar

	for slot = 1, SLOT_COUNT do
		local chip = makeFrame(weaponBar, {
			Size = UDim2.fromOffset(104, 36),
			BackgroundColor3 = Color3.fromRGB(28, 32, 38),
			BackgroundTransparency = 0.25,
		})
		chip.LayoutOrder = slot

		local chipCorner = Instance.new("UICorner")
		chipCorner.CornerRadius = UDim.new(0, 6)
		chipCorner.Parent = chip

		local stroke = Instance.new("UIStroke")
		stroke.Name = "Highlight"
		stroke.Color = Color3.fromRGB(90, 200, 230)
		stroke.Thickness = 0
		stroke.Parent = chip

		local number = makeLabel(chip, {
			Size = UDim2.fromOffset(18, 36),
			Position = UDim2.fromOffset(8, 0),
			Text = tostring(slot),
			TextSize = 15,
			TextColor3 = Color3.fromRGB(150, 165, 180),
		})
		number.Name = "SlotNumber"

		local name = makeLabel(chip, {
			Size = UDim2.new(1, -30, 1, 0),
			Position = UDim2.fromOffset(28, 0),
			Text = "—",
			TextSize = 12,
			TextColor3 = Color3.fromRGB(200, 212, 222),
		})
		name.Name = "SlotName"
		slotChips[slot] = name
	end

	-- A small line reporting whether the controls actually came up. If input
	-- ever dies again, this says so on screen instead of hiding in Output.
	statusText = makeLabel(screen, {
		Size = UDim2.fromOffset(560, 18),
		Position = UDim2.new(0.5, -280, 1, -22),
		Text = "",
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.fromRGB(150, 165, 175),
	})

	-- ------------------------------------------------------------- toasts
	toastHolder = makeFrame(screen, {
		Size = UDim2.fromOffset(400, 200),
		Position = UDim2.new(0.5, -200, 0, 110),
		BackgroundTransparency = 1,
	})
	local toastLayout = Instance.new("UIListLayout")
	toastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	toastLayout.Padding = UDim.new(0, 6)
	toastLayout.Parent = toastHolder

	-- ------------------------------------------------- low-health vignette
	--
	-- Red creeping in from the edges when you are nearly dead. A number in
	-- the corner is something you have to look at; this you cannot miss, and
	-- it is the single clearest thing Halo did to tell you to break off.
	--
	-- Built from four edge gradients rather than an image, because an image
	-- would need an asset ID, and an asset ID in a place that has never been
	-- published is a thing that can silently fail to load.
	local vignetteHolder = makeFrame(screen, {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 4,
	})
	vignetteHolder.Name = "LowHealth"

	for _, edge in {
		{ size = UDim2.new(1, 0, 0, 150), pos = UDim2.new(0, 0, 0, 0), rot = 90 },
		{ size = UDim2.new(1, 0, 0, 150), pos = UDim2.new(0, 0, 1, -150), rot = 270 },
		{ size = UDim2.new(0, 220, 1, 0), pos = UDim2.new(0, 0, 0, 0), rot = 0 },
		{ size = UDim2.new(0, 220, 1, 0), pos = UDim2.new(1, -220, 0, 0), rot = 180 },
	} do
		local band = makeFrame(vignetteHolder, {
			Size = edge.size,
			Position = edge.pos,
			BackgroundColor3 = Color3.fromRGB(190, 24, 24),
			BackgroundTransparency = 0.25,
		})
		local fade = Instance.new("UIGradient")
		fade.Rotation = edge.rot
		fade.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		fade.Parent = band
	end

	-- --------------------------------------------- directional damage arcs
	--
	-- Which way the shot came from. Without it, being shot in the back and
	-- being shot in the face look exactly the same on screen, and the only
	-- way to find out is to turn around twice and die doing it -- which
	-- reads as the game being unfair rather than as missing information.
	--
	-- Drawn as a thin bar set out from the middle of the screen and rotated
	-- to the bearing, for the same reason the vignette is four gradients:
	-- an image would need an asset ID, and an asset ID in a place that has
	-- never been published can silently fail to load.
	--
	-- Four of them, reused in turn, so three people shooting you from three
	-- sides shows as three arcs rather than one that keeps jumping.
	local hurtRing = makeFrame(screen, {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 5,
	})
	hurtRing.Name = "HurtArcs"
	hurtHolder = hurtRing

	table.clear(hurtBlades)
	for _ = 1, 4 do
		local blade = makeFrame(hurtRing, {
			Size = UDim2.fromOffset(170, 9),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			BackgroundColor3 = Color3.fromRGB(235, 40, 40),
			BackgroundTransparency = 1,
			Visible = false,
			ZIndex = 5,
		})
		blade.Name = "HurtArc"
		-- Faded at both ends so it reads as an arc rather than a domino.
		local taper = Instance.new("UIGradient")
		taper.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		taper.Parent = blade
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(0, 4)
		round.Parent = blade
		table.insert(hurtBlades, blade)
	end

	-- ------------------------------------------------------- the scoreboard
	--
	-- Held down, not toggled, the way Halo's was. In a game scored by points
	-- rather than kills there is no way to tell whether you are winning
	-- without one.
	local board = makeFrame(screen, {
		Size = UDim2.fromOffset(620, 460),
		Position = UDim2.new(0.5, -310, 0.5, -230),
		BackgroundColor3 = Color3.fromRGB(10, 14, 20),
		BackgroundTransparency = 0.12,
		Visible = false,
		ZIndex = 20,
	})
	local border = Instance.new("UIStroke")
	border.Color = Color3.fromRGB(120, 200, 255)
	border.Thickness = 2
	border.Transparency = 0.3
	border.Parent = board

	scoreboardTitle = makeLabel(board, {
		Size = UDim2.new(1, -24, 0, 36),
		Position = UDim2.fromOffset(12, 10),
		Text = "SCOREBOARD",
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	makeLabel(board, {
		Size = UDim2.new(1, -24, 0, 18),
		Position = UDim2.fromOffset(12, 48),
		Text = string.format("%-30s %6s %7s %8s", "PLAYER", "PTS", "KILLS", "DEATHS"),
		TextSize = 15,
		Font = Enum.Font.Code,
		TextColor3 = Color3.fromRGB(150, 165, 180),
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local rows = Instance.new("ScrollingFrame")
	rows.Size = UDim2.new(1, -24, 1, -84)
	rows.Position = UDim2.fromOffset(12, 72)
	rows.BackgroundTransparency = 1
	rows.BorderSizePixel = 0
	rows.ScrollBarThickness = 4
	rows.CanvasSize = UDim2.new(0, 0, 0, 0)
	rows.AutomaticCanvasSize = Enum.AutomaticSize.Y
	rows.Parent = board
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Padding = UDim.new(0, 2)
	rowLayout.Parent = rows

	scoreboard = board
	scoreboardRows = rows

	-- The fight prompt. High on the screen on purpose: your guns still work
	-- during a fight and the middle of the screen is where you aim them.
	fightLabel = makeLabel(screen, {
		Name = "FightLabel",
		Size = UDim2.new(1, 0, 0, 56),
		Position = UDim2.new(0, 0, 0.16, 0),
		Text = "",
		TextSize = 48,
		Font = Enum.Font.LuckiestGuy,
		TextColor3 = Color3.fromRGB(255, 210, 90),
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		ZIndex = 12,
	})
	fightCount = makeLabel(screen, {
		Name = "FightCount",
		Size = UDim2.new(1, 0, 0, 34),
		Position = UDim2.new(0, 0, 0.16, 58),
		Text = "",
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.fromRGB(255, 240, 200),
		Visible = false,
		ZIndex = 12,
	})

	-- Two health bars, Blades of Steel style: yours on the left, theirs on
	-- the right. A raised guard tints the bar, so you can read your
	-- opponent's guard off the HUD and time a punch for when it drops.
	for _, side in {
		{ name = "Mine", x = 0.5 - 0.30, colour = Color3.fromRGB(90, 200, 255) },
		{ name = "Theirs", x = 0.5 + 0.08, colour = Color3.fromRGB(255, 110, 90) },
	} do
		local bar = makeFrame(screen, {
			Name = `Fight{side.name}Bar`,
			Size = UDim2.new(0.22, 0, 0, 18),
			Position = UDim2.new(side.x, 0, 0.16, 96),
			BackgroundColor3 = Color3.fromRGB(16, 18, 22),
			BackgroundTransparency = 0.25,
			Visible = false,
			ZIndex = 12,
		})
		local fill = makeFrame(bar, {
			Name = "Fill",
			Size = UDim2.fromScale(1, 1),
			Position = UDim2.fromScale(0, 0),
			BackgroundColor3 = side.colour,
			BackgroundTransparency = 0,
			Visible = true,
			ZIndex = 13,
		})
		if side.name == "Mine" then
			fightMineBar, fightMineFill = bar, fill
		else
			fightTheirsBar, fightTheirsFill = bar, fill
		end
	end

	--[[
		The context action bar.

		Three or four keys along the bottom, showing only what is live for
		whatever you are doing right now. This exists because the same three
		keys mean different things in a car, on skis, in a fight and on foot,
		and a player cannot be expected to hold that in their head -- the
		game should just tell them.
	]]
	actionBar = makeFrame(screen, {
		Name = "ActionBar",
		Size = UDim2.new(0, 560, 0, 34),
		Position = UDim2.new(0.5, -280, 1, -96),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 9,
	})

	puckLabel = makeLabel(screen, {
		Name = "PuckCarry",
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.new(0, 0, 0.22, 0),
		Text = "",
		TextSize = 20,
		Font = Enum.Font.GothamBlack,
		TextColor3 = Color3.fromRGB(150, 230, 255),
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		ZIndex = 12,
	})

	-- ------------------------------------------------- the help panel
	--
	-- Two tabs because there are two different questions a lost player
	-- asks, and they want different answers: "what do I do" wants reading,
	-- "take me there" wants one click. Putting travel behind the same key
	-- as the instructions means there is exactly one thing to remember.
	do
		local panel = makeFrame(screen, {
			Name = "HelpPanel",
			Size = UDim2.fromOffset(560, 470),
			Position = UDim2.new(0.5, -280, 0.5, -235),
			BackgroundColor3 = Color3.fromRGB(14, 18, 24),
			BackgroundTransparency = 0.06,
			Visible = false,
			ZIndex = 30,
		})
		helpPanel = panel

		makeLabel(panel, {
			Name = "Title",
			Size = UDim2.new(1, -140, 0, 46),
			Position = UDim2.fromOffset(20, 8),
			Text = "WHAT DO I DO?",
			TextSize = 24,
			Font = Enum.Font.GothamBlack,
			TextColor3 = Color3.fromRGB(185, 255, 50),
			ZIndex = 31,
		})

		makeLabel(panel, {
			Name = "CloseHint",
			Size = UDim2.fromOffset(110, 46),
			Position = UDim2.new(1, -124, 0, 8),
			Text = "H  CLOSE",
			TextSize = 14,
			TextColor3 = Color3.fromRGB(150, 160, 175),
			TextXAlignment = Enum.TextXAlignment.Right,
			ZIndex = 31,
		})

		local tabs = { { id = "play", label = "HOW TO PLAY" }, { id = "travel", label = "TAKE ME THERE" } }
		for index, tab in tabs do
			local button = Instance.new("TextButton")
			button.Name = `Tab_{tab.id}`
			button.Size = UDim2.fromOffset(170, 32)
			button.Position = UDim2.fromOffset(20 + (index - 1) * 180, 56)
			button.BackgroundColor3 = Color3.fromRGB(26, 32, 42)
			button.BorderSizePixel = 0
			button.Font = Enum.Font.GothamBold
			button.TextSize = 14
			button.TextColor3 = Color3.fromRGB(226, 232, 240)
			button.Text = tab.label
			button.ZIndex = 31
			button.Parent = panel
			helpTabButtons[tab.id] = button

			local id = tab.id
			button.Activated:Connect(function()
				Hud.SetHelpTab(id)
			end)
		end

		local search = Instance.new("TextBox")
		search.Name = "HelpSearch"
		search.Size = UDim2.new(1, -40, 0, 32)
		search.Position = UDim2.fromOffset(20, 94)
		search.BackgroundColor3 = Color3.fromRGB(26, 32, 42)
		search.BorderSizePixel = 0
		search.Font = Enum.Font.Gotham
		search.TextSize = 14
		search.TextColor3 = Color3.fromRGB(226, 232, 240)
		search.PlaceholderText = "Type a question -- skis, stuck, sniper, fight..."
		search.Text = ""
		search.ClearTextOnFocus = false
		search.ZIndex = 31
		search.Parent = panel
		helpSearch = search
		search:GetPropertyChangedSignal("Text"):Connect(function()
			if helpTab == "play" then
				Hud.FilterHelp(search.Text)
			end
		end)

		local body = Instance.new("ScrollingFrame")
		body.Name = "HelpBody"
		body.Size = UDim2.new(1, -40, 1, -146)
		body.Position = UDim2.fromOffset(20, 136)
		body.BackgroundTransparency = 1
		body.BorderSizePixel = 0
		body.ScrollBarThickness = 6
		body.CanvasSize = UDim2.new()
		body.ZIndex = 31
		body.Parent = panel
		helpBody = body

		local travel = Instance.new("ScrollingFrame")
		travel.Name = "HelpTravel"
		travel.Size = UDim2.new(1, -40, 1, -146)
		travel.Position = UDim2.fromOffset(20, 136)
		travel.BackgroundTransparency = 1
		travel.BorderSizePixel = 0
		travel.ScrollBarThickness = 6
		travel.CanvasSize = UDim2.new()
		travel.Visible = false
		travel.ZIndex = 31
		travel.Parent = panel
		helpTravel = travel
	end

	-- ------------------------------------------------- the sub-game menu
	local panel = makeFrame(screen, {
		Size = UDim2.fromOffset(460, 440),
		Position = UDim2.new(0.5, -230, 0.5, -220),
		BackgroundColor3 = Color3.fromRGB(10, 14, 20),
		BackgroundTransparency = 0.08,
		Visible = false,
		ZIndex = 30,
	})
	local panelEdge = Instance.new("UIStroke")
	panelEdge.Color = Color3.fromRGB(120, 200, 255)
	panelEdge.Thickness = 2
	panelEdge.Transparency = 0.25
	panelEdge.Parent = panel

	makeLabel(panel, {
		Size = UDim2.new(1, -24, 0, 34),
		Position = UDim2.fromOffset(12, 10),
		Text = "PICK A GAME",
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	makeLabel(panel, {
		Size = UDim2.new(1, -24, 0, 18),
		Position = UDim2.fromOffset(12, 44),
		Text = "You are taken straight there. Teams are filled with CPU players.",
		TextSize = 12,
		TextColor3 = Color3.fromRGB(150, 168, 186),
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	local list = makeFrame(panel, {
		Size = UDim2.new(1, -24, 1, -78),
		Position = UDim2.fromOffset(12, 68),
		BackgroundTransparency = 1,
	})
	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 6)
	listLayout.Parent = list

	arcadePanel = panel
	arcadeList = list

	-- The walk-in offer.
	arcadeOffer = makeLabel(screen, {
		Name = "ArcadeOffer",
		Size = UDim2.new(1, 0, 0, 58),
		Position = UDim2.new(0, 0, 0.28, 0),
		Text = "",
		TextSize = 22,
		TextColor3 = Color3.fromRGB(255, 238, 180),
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		ZIndex = 14,
	})

	-- The motion tracker, bottom left above the health bar.
	Radar.Build(screen)

	-- Drive the vignette from the frame loop rather than from health events,
	-- so the pulse is smooth no matter how often damage arrives.
	RunService.RenderStepped:Connect(function(deltaTime: number)
		if not vignetteHolder.Visible then
			return
		end
		vignettePulse += deltaTime * 6
		-- Faster and harder the closer to death you are.
		local beat = 0.5 + 0.5 * math.sin(vignettePulse)
		for _, band in vignetteHolder:GetChildren() do
			if band:IsA("Frame") then
				band.BackgroundTransparency = 0.72 - vignetteStrength * (0.32 + beat * 0.14)
			end
		end
	end)

	lowHealthHolder = vignetteHolder
end

-- ================================================================ UPDATING ==

function Hud.SetHealth(current: number, maximum: number)
	if not healthFill then
		return
	end
	local fraction = if maximum > 0 then math.clamp(current / maximum, 0, 1) else 0
	healthFill.Size = UDim2.fromScale(fraction, 1)

	local percent = math.floor(fraction * 100 + 0.5)
	healthText.Text = `{percent}%`

	-- Green when healthy, amber when hurt, red when about to die.
	healthFill.BackgroundColor3 = if fraction > 0.6
		then Color3.fromRGB(80, 200, 110)
		elseif fraction > 0.3 then Color3.fromRGB(230, 170, 60)
		else Color3.fromRGB(230, 70, 60)

	-- The edge warning comes up below a third of health and gets stronger all
	-- the way down, so "nearly dead" and "one more hit" look different.
	if lowHealthHolder then
		local danger = math.clamp((0.34 - fraction) / 0.34, 0, 1)
		vignetteStrength = danger
		lowHealthHolder.Visible = danger > 0.02 and current > 0
	end
end

--[[ Tell the player their turbo is lit. ]]
function Hud.SetTurbo(on: boolean)
	if not turboText then
		return
	end
	turboText.Text = if on then "TURBO  ▲▲▲" else ""
end

function Hud.SetShield(current: number, maximum: number)
	if not shieldFill then
		return
	end
	local fraction = if maximum > 0 then math.clamp(current / maximum, 0, 1) else 0
	shieldFill.Size = UDim2.fromScale(fraction, 1)
	shieldTrack.Visible = maximum > 0
end

function Hud.SetWeapon(displayName: string, ammo: number, magSize: number, reloading: boolean)
	if not weaponLabel then
		return
	end
	weaponLabel.Text = displayName
	if reloading then
		ammoLabel.Text = "RELOADING…"
		ammoLabel.TextColor3 = Color3.fromRGB(250, 180, 90)
	else
		ammoLabel.Text = `{ammo} / {magSize}`
		ammoLabel.TextColor3 = if ammo == 0
			then Color3.fromRGB(240, 90, 80)
			else Color3.fromRGB(180, 195, 210)
	end
end

function Hud.SetStats(keys: number, carTierName: string, megaCharges: number, kills: number, deaths: number)
	if not statsLabel then
		return
	end
	statsLabel.Text = table.concat({
		`🔑 Keys: {keys}`,
		`🚚 Car: {carTierName}`,
		`💥 Mega charges: {megaCharges}   [F]`,
		`☠️ {kills} kills / {deaths} deaths`,
	}, "\n")
end

function Hud.SetMatch(
	phase: string,
	timeLeft: number,
	scores: { number },
	mapName: string,
	modeName: string?,
	flags: { string }?
)
	if not clockLabel then
		return
	end

	if phase == "Playing" then
		local mode = if modeName then `{modeName} · ` else ""
		clockLabel.Text = `{mode}{mapName}  ·  {Util.FormatClock(timeLeft)}`
	elseif phase == "Voting" then
		clockLabel.Text = `VOTING  ·  {Util.FormatClock(timeLeft)}`
	elseif phase == "Intermission" then
		clockLabel.Text = "ROUND OVER"
	else
		clockLabel.Text = "WAITING FOR PLAYERS"
	end

	-- In Capture the Flag the scoreboard also says where each flag is, which
	-- is the single most useful thing to know at a glance.
	if flags then
		local red = flags[1] or "?"
		local blue = flags[2] or "?"
		scoreLabel.Text = `RED {scores[1] or 0} [{string.upper(red)}]   —   [{string.upper(blue)}] BLUE {scores[2] or 0}`
	else
		scoreLabel.Text = `RED {scores[1] or 0}   —   BLUE {scores[2] or 0}`
	end
end

--[[ Show the map ballot, and call back with whichever one gets clicked. ]]
function Hud.ShowVote(options: { { id: string, name: string } }, onPick: (number) -> ())
	if not votePanel then
		return
	end

	local list = votePanel:FindFirstChild("Options") :: Frame
	for _, child in list:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	for index, option in options do
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(1, 0, 0, 46)
		button.BackgroundColor3 = Color3.fromRGB(38, 44, 52)
		button.BorderSizePixel = 0
		button.Text = `{index}.  {option.name}`
		button.TextColor3 = Color3.fromRGB(235, 242, 248)
		button.TextSize = 20
		button.Font = Enum.Font.GothamBold
		button.Parent = list

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = button

		button.Activated:Connect(function()
			onPick(index)
			for _, sibling in list:GetChildren() do
				if sibling:IsA("TextButton") then
					sibling.BackgroundColor3 = Color3.fromRGB(38, 44, 52)
				end
			end
			button.BackgroundColor3 = Color3.fromRGB(40, 120, 90)
		end)
	end

	votePanel.Visible = true
end

function Hud.HideVote()
	if votePanel then
		votePanel.Visible = false
	end
end

--[[ The lava screen. Fades in red, holds, fades out. ]]
function Hud.ShowDeath(duration: number, killerName: string?)
	if not deathOverlay then
		return
	end

	-- Held directly rather than looked up by class. The overlay has two
	-- TextLabels now, and FindFirstChildOfClass could hand back the
	-- countdown instead -- putting the killer's name in the clock and
	-- leaving the title saying whatever it said last.
	if deathTitle then
		deathTitle.Text = if killerName
			then `MELTED BY {string.upper(killerName)}`
			else "YOU MELTED"
	end

	deathOverlay.Visible = true
	deathOverlay.BackgroundTransparency = 1
	TweenService:Create(deathOverlay, TweenInfo.new(0.25), { BackgroundTransparency = 0.25 }):Play()

	-- Count it down, a tenth of a second at a time. The token guards against
	-- dying again before the last countdown finished, which would otherwise
	-- leave two of them fighting over the same label.
	respawnToken += 1
	local token = respawnToken
	task.spawn(function()
		local endsAt = os.clock() + duration
		while respawnToken == token do
			local left = endsAt - os.clock()
			if left <= 0 then
				break
			end
			if respawnLabel then
				respawnLabel.Text = string.format("RESPAWNING IN %.1f", left)
			end
			task.wait(0.1)
		end
		if respawnToken == token and respawnLabel then
			respawnLabel.Text = "GO"
		end
	end)

	task.delay(duration, function()
		if respawnToken ~= token or not deathOverlay then
			return
		end
		local fade = TweenService:Create(deathOverlay, TweenInfo.new(0.4), { BackgroundTransparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		if respawnToken == token and deathOverlay then
			deathOverlay.Visible = false
		end
	end)
end

function Hud.ShowWiener(teamName: string, duration: number)
	if not wienerOverlay then
		return
	end
	wienerToken += 1
	local token = wienerToken
	wienerOverlay.Text = `{string.upper(teamName)}\nIS THE WIENER!`
	wienerOverlay.Visible = true
	task.delay(duration, function()
		if wienerToken == token and wienerOverlay then
			wienerOverlay.Visible = false
		end
	end)
end

--[[ A short message that slides in and disappears on its own. ]]
function Hud.Toast(message: string)
	if not toastHolder then
		return
	end

	local label = makeLabel(toastHolder, {
		Size = UDim2.fromOffset(400, 28),
		Text = message,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	task.delay(2.5, function()
		local fade = TweenService:Create(label, TweenInfo.new(0.4), { TextTransparency = 1, TextStrokeTransparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		label:Destroy()
	end)
end

--[[
	Fill in the weapon bar and light exactly one chip.

	`names` is the gun currently chosen in each slot; `activeSlot` is the one
	in your hands. Only ever one is highlighted.
]]
function Hud.SetLoadout(names: { [number]: string }, activeSlot: number)
	if not weaponBar then
		return
	end

	for slot = 1, SLOT_COUNT do
		local label = slotChips[slot]
		if label then
			label.Text = names[slot] or "—"
			local active = slot == activeSlot
			label.TextColor3 = if active
				then Color3.fromRGB(255, 255, 255)
				else Color3.fromRGB(150, 162, 172)

			local chip = label.Parent :: Frame
			chip.BackgroundTransparency = if active then 0.05 else 0.45
			local stroke = chip:FindFirstChild("Highlight")
			if stroke and stroke:IsA("UIStroke") then
				stroke.Thickness = if active then 2 else 0
			end
		end
	end
end

--[[ Show the current magnification, and raise the scope with it. ]]
--[[
	Say whether night vision is on.

	Worth a word on screen because it is a toggle you can forget, and a
	green lens with no explanation looks like a graphics fault.
]]
local nightVisionShown = false

function Hud.SetNightVision(on: boolean)
	nightVisionShown = on
	if zoomText and zoomText.Text ~= "" then
		Hud.SetZoom(lastMagnification)
	end
end

function Hud.SetZoom(magnification: number)
	if not zoomText then
		return
	end
	lastMagnification = magnification
	zoomText.Text = if magnification > 0
		then (if nightVisionShown then `{magnification}×  ·  NV` else `{magnification}×`)
		else ""
	if scope then
		scope.Visible = magnification > 0
	end
	if crosshair then
		-- The scope has its own crosshair; two would be confusing.
		crosshair.Visible = magnification <= 0
	end
end

--[[
	Poop, across the screen.

	Blobs rather than a flat colour, so it reads as something thrown at you
	and you can still just about see between them.
]]
function Hud.Splat(duration: number)
	if not screen then
		return
	end

	local splat = makeFrame(screen, {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(74, 52, 30),
		BackgroundTransparency = 0.35,
		ZIndex = 30,
	})

	local blobRng = Random.new()
	for _ = 1, 16 do
		local blob = makeFrame(splat, {
			Size = UDim2.fromOffset(blobRng:NextInteger(70, 240), blobRng:NextInteger(70, 240)),
			Position = UDim2.fromScale(blobRng:NextNumber(-0.05, 0.95), blobRng:NextNumber(-0.05, 0.9)),
			BackgroundColor3 = Color3.fromRGB(
				blobRng:NextInteger(56, 96),
				blobRng:NextInteger(38, 66),
				blobRng:NextInteger(20, 40)
			),
			BackgroundTransparency = blobRng:NextNumber(0, 0.2),
			ZIndex = 31,
		})
		local blobCorner = Instance.new("UICorner")
		blobCorner.CornerRadius = UDim.new(1, 0)
		blobCorner.Parent = blob
	end

	local label = makeLabel(splat, {
		Size = UDim2.new(1, 0, 0, 60),
		Position = UDim2.new(0, 0, 0.5, -30),
		Text = "SPLAT",
		TextSize = 52,
		Font = Enum.Font.LuckiestGuy,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.fromRGB(230, 200, 160),
		ZIndex = 32,
	})
	local _ = label

	task.delay(duration, function()
		local fade = TweenService:Create(splat, TweenInfo.new(0.5), { BackgroundTransparency = 1 })
		fade:Play()
		for _, child in splat:GetChildren() do
			if child:IsA("Frame") then
				TweenService:Create(child, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
			elseif child:IsA("TextLabel") then
				TweenService:Create(child, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			end
		end
		fade.Completed:Wait()
		splat:Destroy()
	end)
end

--[[
	Flash the hitmarker and float the damage number.

	A headshot gets a bigger, hotter marker, because knowing you hit the head
	is most of what makes a headshot satisfying.
]]
function Hud.Hit(damage: number, headshot: boolean)
	if not hitmarker then
		return
	end

	hitToken += 1
	local myHitToken = hitToken
	hitmarker.Visible = true
	local existingScale = hitmarker:FindFirstChildOfClass("UIScale")
	local scale: UIScale
	if existingScale then
		scale = existingScale
	else
		scale = Instance.new("UIScale")
		scale.Parent = hitmarker
	end
	scale.Scale = if headshot then 1.4 else 1.0
	for _, stroke in hitmarker:GetChildren() do
		if stroke:IsA("Frame") then
			stroke.BackgroundColor3 = if headshot
				then Color3.fromRGB(255, 210, 90)
				else Color3.fromRGB(255, 255, 255)
		end
	end

	task.delay(0.12, function()
		if hitToken == myHitToken and hitmarker then
			hitmarker.Visible = false
		end
	end)

	-- The number, drifting up and fading.
	if not damageHolder then
		return
	end
	local number = makeLabel(damageHolder, {
		Size = UDim2.fromOffset(160, 30),
		Position = UDim2.fromOffset(0, 60),
		Text = if headshot then `{damage}  HEAD` else tostring(damage),
		TextSize = if headshot then 28 else 22,
		TextColor3 = if headshot then Color3.fromRGB(255, 210, 90) else Color3.fromRGB(255, 255, 255),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 11,
	})

	local drift = TweenService:Create(number, TweenInfo.new(0.7, Enum.EasingStyle.Quad), {
		Position = UDim2.fromOffset(26, 0),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	drift:Play()
	drift.Completed:Connect(function()
		number:Destroy()
	end)
end

--[[
	Show which way a hit came from.

	`from` is a WORLD position, because the server has no idea which way
	anybody's camera is pointing and should not: that is the one piece of
	state a client genuinely owns. So the bearing is worked out here, as the
	angle between where you are looking and where the shot came from,
	measured flat -- a sniper on a roof reads as a bearing, not as "up",
	because turning to face them is the only useful response either way.

	A hit with no direction -- a zombie, a fall, a fire you are standing in
	-- shows nothing rather than an arbitrary arc. An arrow pointing at
	nothing is worse than no arrow.
]]
function Hud.ShowHurtFrom(from: Vector3?)
	if not from or #hurtBlades == 0 then
		return
	end
	local camera = workspace.CurrentCamera
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not camera or not root or not root:IsA("BasePart") then
		return
	end

	local toward = from - root.Position
	local flat = Vector3.new(toward.X, 0, toward.Z)
	if flat.Magnitude < 1 then
		-- Standing inside it. No direction to point.
		return
	end
	flat = flat.Unit

	local look = camera.CFrame.LookVector
	local facing = Vector3.new(look.X, 0, look.Z)
	if facing.Magnitude < 1e-4 then
		return
	end
	facing = facing.Unit
	local right = Vector3.new(-facing.Z, 0, facing.X)

	-- Bearing in screen terms: 0 is dead ahead, positive is to the right.
	local bearing = math.atan2(flat:Dot(right), flat:Dot(facing))

	local blade = hurtBlades[nextHurtBlade]
	nextHurtBlade = (nextHurtBlade % #hurtBlades) + 1

	-- Out from the middle on that bearing, and turned to lie along the ring.
	local radius = 0.3
	blade.Position = UDim2.fromScale(
		0.5 + math.sin(bearing) * radius,
		0.5 - math.cos(bearing) * radius * 0.78
	)
	blade.Rotation = math.deg(bearing)
	blade.Visible = true
	blade.BackgroundTransparency = 0.1

	local fade = TweenService:Create(
		blade,
		TweenInfo.new(0.75, Enum.EasingStyle.Quad),
		{ BackgroundTransparency = 1 }
	)
	fade:Play()
	fade.Completed:Connect(function()
		-- Only hide it if nothing has reused it in the meantime.
		if blade.BackgroundTransparency >= 1 then
			blade.Visible = false
		end
	end)
end

--[[ For tests: where the floating damage numbers live. ]]
function Hud.DamageNumbersForTests(): Frame?
	return damageHolder
end

--[[ For tests: the arcs, so a test can see which one lit and where. ]]
function Hud.HurtArcsForTests(): { Frame }
	return hurtBlades
end

--[[ One line in the kill feed. ]]
function Hud.KillFeed(text: string, mine: boolean)
	if not killFeed then
		return
	end

	-- Keep the list short; the oldest falls off the bottom.
	local lines = {}
	for _, child in killFeed:GetChildren() do
		if child:IsA("TextLabel") then
			table.insert(lines, child)
		end
	end
	if #lines >= 5 then
		table.sort(lines, function(a, b)
			return a.LayoutOrder > b.LayoutOrder
		end)
		lines[1]:Destroy()
	end

	killFeedOrder -= 1
	local entry = makeLabel(killFeed, {
		Size = UDim2.new(1, 0, 0, 24),
		Text = text,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = if mine then Color3.fromRGB(255, 220, 120) else Color3.fromRGB(205, 215, 225),
	})
	entry.LayoutOrder = killFeedOrder

	task.delay(6, function()
		if entry.Parent then
			local fade = TweenService:Create(entry, TweenInfo.new(0.5), {
				TextTransparency = 1,
				TextStrokeTransparency = 1,
			})
			fade:Play()
			fade.Completed:Wait()
			entry:Destroy()
		end
	end)
end

--[[ A medal, across the middle of the screen. ]]
function Hud.Medal(text: string)
	if not medalLabel then
		return
	end
	medalToken += 1
	local myMedalToken = medalToken
	medalLabel.Text = text
	medalLabel.TextTransparency = 0
	medalLabel.TextStrokeTransparency = 0.3

	task.delay(1.6, function()
		if medalToken ~= myMedalToken or not medalLabel then
			return
		end
		TweenService:Create(medalLabel, TweenInfo.new(0.6), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
	end)
end

--[[ Report control health on screen. Green when fine, red when not. ]]
--[[
	Show or hide the scoreboard.

	Held down rather than toggled, so you can glance at it mid-fight and let
	go, which is how Halo's worked and the reason it never got in the way.
]]
function Hud.ShowScoreboard(visible: boolean)
	if scoreboard then
		scoreboard.Visible = visible
	end
end

--[[
	Fill the scoreboard in.

	`rows` arrives already sorted by the server, which is the only place that
	knows everyone's score. Teams are kept apart and coloured, because in a
	team game the question is not who is top but which half is winning.
]]
function Hud.SetScoreboard(
	rows: {
		{
			name: string,
			team: string?,
			teamColor: Color3?,
			points: number,
			kills: number,
			deaths: number,
			isYou: boolean?,
			isMvp: boolean?,
			bestAt: string?,
		}
	},
	heading: string?
)
	local rowHolder = scoreboardRows
	if not rowHolder then
		return
	end

	for _, old in rowHolder:GetChildren() do
		if not old:IsA("UIListLayout") then
			old:Destroy()
		end
	end

	if scoreboardTitle then
		scoreboardTitle.Text = heading or "SCOREBOARD"
	end

	local lastTeam: string? = nil
	local order = 0

	for _, row in rows do
		-- A heading each time the team changes, so the two sides read as two
		-- sides rather than one long list.
		if row.team and row.team ~= lastTeam then
			lastTeam = row.team
			order += 1
			local header = makeLabel(rowHolder, {
				Size = UDim2.new(1, 0, 0, 22),
				Text = string.upper(row.team),
				TextSize = 16,
				TextColor3 = row.teamColor or Color3.fromRGB(200, 210, 220),
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			header.LayoutOrder = order
		end

		order += 1

		--[[
			The MVP's row says what they are doing it at.

			A number alone does not distinguish a round won at the carnival
			from a round won by shooting people, and those are the two ways
			this game is meant to be winnable. Only the top row carries it:
			a reason beside every name would be a column of noise.
		]]
		local label = string.sub(tostring(row.name or "Player"), 1, 30)
		if row.isMvp then
			local at = if typeof(row.bestAt) == "string" then row.bestAt else nil
			label = if at
				then string.sub(`★ {row.name} ({at})`, 1, 30)
				else string.sub(`★ {row.name}`, 1, 30)
		end

		local line = makeLabel(rowHolder, {
			Size = UDim2.new(1, 0, 0, 20),
			Text = string.format(
				"%-30s %6d %7d %8d",
				label,
				tonumber(row.points) or 0,
				tonumber(row.kills) or 0,
				tonumber(row.deaths) or 0
			),
			TextSize = 15,
			Font = Enum.Font.Code, -- monospaced, or the columns do not line up
			TextColor3 = if row.isMvp
				then Color3.fromRGB(255, 215, 90)
				elseif row.isYou then Color3.fromRGB(255, 240, 150)
				else Color3.fromRGB(215, 225, 235),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		line.LayoutOrder = order
	end
end

--[[
	The fight prompt.

	Blades of Steel: a big instruction and a count, up for a few seconds
	while you mash. It deliberately does NOT cover the middle of the screen,
	because your guns still work during a fight and you may well decide to
	shoot your way out of it instead.
]]
function Hud.ShowFight(opponent: string, duration: number)
	if not fightLabel or not fightCount then
		return
	end
	fightLabel.Text = `FIGHT!  {string.upper(opponent)}`
	fightLabel.Visible = true
	fightCount.Text = "F  PUNCH      Q  BLOCK      MOUSE  STILL SHOOTS"
	fightCount.Visible = true
	if fightMineBar then
		fightMineBar.Visible = true
	end
	if fightTheirsBar then
		fightTheirsBar.Visible = true
	end
	if fightMineFill then
		fightMineFill.Size = UDim2.fromScale(1, 1)
	end
	if fightTheirsFill then
		fightTheirsFill.Size = UDim2.fromScale(1, 1)
	end

	fightToken += 1
	local token = fightToken
	task.delay(duration + 1.6, function()
		-- Only clear it if no later fight has started since.
		if fightToken == token and fightLabel and fightCount then
			fightLabel.Visible = false
			fightCount.Visible = false
			if fightMineBar then
				fightMineBar.Visible = false
			end
			if fightTheirsBar then
				fightTheirsBar.Visible = false
			end
		end
	end)
end

--[[ How the scrap went. ]]
function Hud.FightResult(won: boolean, draw: boolean, brokeStick: boolean)
	if not fightLabel or not fightCount then
		return
	end
	fightLabel.Visible = true
	fightCount.Visible = true
	fightLabel.Text = if draw
		then "A DRAW"
		elseif won then "YOU WON THE FIGHT"
		else "YOU LOST THE FIGHT"
	fightCount.Text = if brokeStick then "YOUR STICK BROKE — USE IT" else ""
	if fightMineBar then
		fightMineBar.Visible = false
	end
	if fightTheirsBar then
		fightTheirsBar.Visible = false
	end
	task.delay(2.0, function()
		if fightLabel then
			fightLabel.Visible = false
		end
		if fightCount then
			fightCount.Visible = false
		end
	end)
end

--[[
	Both fight health bars, and who has their guard up.

	The guard is shown as a tint rather than a separate icon because reading
	your opponent's guard IS the fight: punching into a raised guard is worth
	almost nothing, so the whole skill is waiting for it to drop.
]]
function Hud.FightHealth(mine: number, theirs: number, maximum: number, theyBlock: boolean, iBlock: boolean)
	local span = if maximum > 0 then maximum else 1

	if fightMineFill then
		fightMineFill.Size = UDim2.fromScale(math.clamp(mine / span, 0, 1), 1)
		fightMineFill.BackgroundColor3 = if iBlock
			then Color3.fromRGB(190, 230, 255)
			else Color3.fromRGB(90, 200, 255)
	end
	if fightTheirsFill then
		fightTheirsFill.Size = UDim2.fromScale(math.clamp(theirs / span, 0, 1), 1)
		fightTheirsFill.BackgroundColor3 = if theyBlock
			then Color3.fromRGB(255, 220, 140)
			else Color3.fromRGB(255, 110, 90)
	end
	if fightCount and fightCount.Visible then
		fightCount.Text = if theyBlock
			then "THEIR GUARD IS UP — WAIT FOR IT TO DROP"
			else "F  PUNCH      Q  BLOCK      MOUSE  STILL SHOOTS"
	end
end

--[[
	Which keys are live, and what they do right now.

	Rebuilt rather than updated in place: the number of keys changes between
	contexts, and four labels is cheap next to the bookkeeping of pooling
	them. Controls only calls this when the set actually changes.
]]
function Hud.SetActionBar(entries: { { key: string, label: string } })
	local bar = actionBar
	if not bar then
		return
	end

	for _, child in bar:GetChildren() do
		child:Destroy()
	end

	if #entries == 0 then
		bar.Visible = false
		return
	end
	bar.Visible = true

	local SLOT = 136
	local total = #entries * SLOT
	for index, entry in entries do
		local slot = makeFrame(bar, {
			Name = `Slot{index}`,
			Size = UDim2.fromOffset(SLOT - 8, 28),
			Position = UDim2.new(0.5, -total * 0.5 + (index - 1) * SLOT + 4, 0, 3),
			BackgroundColor3 = Color3.fromRGB(12, 15, 20),
			BackgroundTransparency = 0.25,
			Visible = true,
			ZIndex = 9,
		})

		makeLabel(slot, {
			Name = "Key",
			Size = UDim2.fromOffset(52, 28),
			Position = UDim2.fromOffset(0, 0),
			Text = entry.key,
			TextSize = 15,
			Font = Enum.Font.GothamBlack,
			TextColor3 = Color3.fromRGB(185, 255, 50),
			TextXAlignment = Enum.TextXAlignment.Center,
			ZIndex = 10,
		})

		makeLabel(slot, {
			Name = "Action",
			Size = UDim2.new(1, -56, 0, 28),
			Position = UDim2.fromOffset(54, 0),
			Text = entry.label,
			TextSize = 14,
			TextColor3 = Color3.fromRGB(226, 232, 240),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 10,
		})
	end
end

--[[ For tests: what the strip currently says. ]]
function Hud.ActionBarForTests(): { { key: string, label: string } }
	local out = {}
	local bar = actionBar
	if not bar or not bar.Visible then
		return out
	end
	for _, slot in bar:GetChildren() do
		local key = slot:FindFirstChild("Key")
		local action = slot:FindFirstChild("Action")
		if key and action and key:IsA("TextLabel") and action:IsA("TextLabel") then
			table.insert(out, { key = key.Text, label = action.Text })
		end
	end
	return out
end

--[[
	You have the puck.

	Worth its own line on screen because carrying it changes what left click
	does -- it shoots the puck rather than the gun -- and that is not
	something a player can be expected to infer.
]]
function Hud.SetPuck(carrying: boolean)
	local label = puckLabel
	if not label then
		return
	end
	label.Visible = carrying
	-- F, not the mouse. The mouse is the gun, which is the one rule this
	-- game does not bend -- and a rifle moves the puck perfectly well
	-- anyway, so clicking is never wasted.
	label.Text = "YOU HAVE THE PUCK — F TO SHOOT"
end

function Hud.PuckShownForTests(): boolean
	return puckLabel ~= nil and puckLabel.Visible
end

--[[
	You have the ball.

	Shares the puck's line, because you cannot hold both and two labels in
	the same place would be a bug waiting to look like one.
]]
--[[ You have a bowling ball. Shares the line, as nothing else can be held. ]]
function Hud.SetBowlingBall(carrying: boolean)
	local label = puckLabel
	if not label then
		return
	end
	label.Visible = carrying
	label.Text = "HOLD F TO WIND UP — AIM WHERE YOU LOOK"
end

function Hud.SetBall(carrying: boolean)
	local label = puckLabel
	if not label then
		return
	end
	label.Visible = carrying
	label.Text = "YOU HAVE THE BALL — HOLD F TO WIND UP"
end

-- ==================================================================== HELP ==

--[[
	Does this entry answer that question?

	Deliberately forgiving. Somebody typing into a help box is already
	confused, and a search that only matches exact words punishes them for
	not knowing the vocabulary -- which is the thing they came to find out.
	So it matches on the question text, the answer text and a keyword list
	written to include the words a player would type rather than the words
	the code uses: "stuck" for the winch, "gun" for the weapon list.
]]
local function helpMatches(entry: { question: string, answer: string, keywords: { string } }, query: string): boolean
	local needle = string.lower((string.gsub(query, "^%s*(.-)%s*$", "%1")))
	if needle == "" then
		return true
	end
	if string.find(string.lower(entry.question), needle, 1, true) then
		return true
	end
	if string.find(string.lower(entry.answer), needle, 1, true) then
		return true
	end
	for _, keyword in entry.keywords do
		-- Either direction: "snow" should find "snowboard", and typing
		-- "snowboarding" should still find it.
		if string.find(keyword, needle, 1, true) or string.find(needle, keyword, 1, true) then
			return true
		end
	end
	return false
end

--[[ Which entries answer a query, in Config order. ]]
function Hud.HelpMatches(query: string): { { question: string, answer: string, keywords: { string } } }
	local out = {}
	for _, entry in Config.Help do
		if helpMatches(entry, query) then
			table.insert(out, entry)
		end
	end
	return out
end

--[[ Redraw the how-to list for a query. ]]
function Hud.FilterHelp(query: string)
	local body = helpBody
	if not body then
		return
	end
	for _, old in body:GetChildren() do
		old:Destroy()
	end

	local matches = Hud.HelpMatches(query)
	local y = 0

	if #matches == 0 then
		makeLabel(body, {
			Name = "NoMatch",
			Size = UDim2.new(1, -12, 0, 40),
			Position = UDim2.fromOffset(0, 0),
			Text = `Nothing about "{query}" yet.`,
			TextSize = 14,
			TextColor3 = Color3.fromRGB(150, 160, 175),
			ZIndex = 32,
		})
		body.CanvasSize = UDim2.fromOffset(0, 40)
		return
	end

	for index, entry in matches do
		local question = makeLabel(body, {
			Name = `Q{index}`,
			Size = UDim2.new(1, -12, 0, 24),
			Position = UDim2.fromOffset(0, y),
			Text = entry.question,
			TextSize = 16,
			Font = Enum.Font.GothamBold,
			TextColor3 = Color3.fromRGB(185, 255, 50),
			TextWrapped = true,
			ZIndex = 32,
		})
		local _ = question
		y += 26

		makeLabel(body, {
			Name = `A{index}`,
			Size = UDim2.new(1, -12, 0, 58),
			Position = UDim2.fromOffset(0, y),
			Text = entry.answer,
			TextSize = 14,
			TextColor3 = Color3.fromRGB(214, 222, 232),
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			ZIndex = 32,
		})
		y += 70
	end

	body.CanvasSize = UDim2.fromOffset(0, y)
end

--[[
	The travel list: one row per activity, one click to go.

	This reuses the same join the walk-in prompt and the B menu use, so
	arriving by teleport fills the teams out with bots exactly as walking in
	would. A travel button that dropped you at an empty rink would be a
	worse answer than making you walk.
]]
function Hud.SetTravelList(games: { { id: string, name: string, objective: string, players: number } })
	local list = helpTravel
	if not list then
		return
	end
	for _, old in list:GetChildren() do
		old:Destroy()
	end

	local y = 0
	for _, game in games do
		local row = Instance.new("TextButton")
		row.Name = `Travel_{game.id}`
		row.Size = UDim2.new(1, -12, 0, 52)
		row.Position = UDim2.fromOffset(0, y)
		row.BackgroundColor3 = Color3.fromRGB(26, 32, 42)
		row.BorderSizePixel = 0
		row.Font = Enum.Font.GothamBold
		row.TextSize = 15
		row.TextColor3 = Color3.fromRGB(226, 232, 240)
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.Text = `  {string.upper(game.name)}      {game.players} there`
		row.ZIndex = 32
		row.Parent = list

		local id = game.id
		row.Activated:Connect(function()
			if helpTravelHandler then
				helpTravelHandler(id)
			end
		end)

		y += 58
	end
	list.CanvasSize = UDim2.fromOffset(0, y)
end

--[[ Controls hands us the thing to call when somebody picks a destination. ]]
function Hud.OnTravel(handler: (string) -> ())
	helpTravelHandler = handler
end

function Hud.SetHelpTab(tab: string)
	helpTab = tab
	if helpBody then
		helpBody.Visible = tab == "play"
	end
	if helpTravel then
		helpTravel.Visible = tab == "travel"
	end
	if helpSearch then
		-- The search only applies to the reading tab, so it would be a
		-- dead box on the other one.
		helpSearch.Visible = tab == "play"
	end
	for id, button in helpTabButtons do
		button.BackgroundColor3 = if id == tab
			then Color3.fromRGB(46, 58, 74)
			else Color3.fromRGB(26, 32, 42)
	end
end

function Hud.ShowHelp()
	local panel = helpPanel
	if not panel then
		return
	end
	panel.Visible = true
	Hud.SetHelpTab(helpTab)
	Hud.FilterHelp(if helpSearch then helpSearch.Text else "")
end

function Hud.HideHelp()
	if helpPanel then
		helpPanel.Visible = false
	end
end

function Hud.HelpOpen(): boolean
	return helpPanel ~= nil and helpPanel.Visible
end

--[[ For tests. ]]
function Hud.HelpTabForTests(): string
	return helpTab
end

function Hud.TravelRowsForTests(): { string }
	local out = {}
	local list = helpTravel
	if list then
		for _, row in list:GetChildren() do
			table.insert(out, row.Name)
		end
	end
	return out
end

function Hud.HelpQuestionsForTests(): { string }
	local out = {}
	local body = helpBody
	if body then
		for _, child in body:GetChildren() do
			if string.sub(child.Name, 1, 1) == "Q" then
				table.insert(out, (child :: any).Text)
			end
		end
	end
	return out
end

--[[
	The join-in banner: the name of the game and whose game it is.

	Shown once when you join, not on every respawn, and built on the fly
	rather than living in the HUD so there is nothing left on screen after it
	fades.
]]
function Hud.Intro(title: string, subtitle: string, hold: number)
	local screen = Instance.new("ScreenGui")
	screen.Name = "IntroBanner"
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 50
	screen.Parent = player:WaitForChild("PlayerGui")

	local container = makeFrame(screen, {
		Name = "Band",
		Size = UDim2.new(1, 0, 0, 150),
		Position = UDim2.new(0, 0, 0.33, 0),
		BackgroundColor3 = Color3.fromRGB(15, 18, 12),
		BackgroundTransparency = 1,
		Visible = true,
		ZIndex = 1,
	})

	local titleLabel = makeLabel(container, {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 72),
		Position = UDim2.new(0, 0, 0, 18),
		Text = title,
		TextScaled = true,
		Font = Enum.Font.LuckiestGuy,
		TextColor3 = Color3.fromRGB(185, 255, 50),
		TextStrokeColor3 = Color3.new(0, 0, 0),
		TextStrokeTransparency = 1,
		TextTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = true,
		ZIndex = 2,
	})

	local subLabel = makeLabel(container, {
		Name = "Subtitle",
		Size = UDim2.new(1, 0, 0, 34),
		Position = UDim2.new(0, 0, 0, 96),
		Text = subtitle,
		TextScaled = true,
		Font = Enum.Font.GothamBold,
		TextColor3 = Color3.fromRGB(232, 232, 232),
		TextStrokeColor3 = Color3.new(0, 0, 0),
		TextStrokeTransparency = 1,
		TextTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = true,
		ZIndex = 2,
	})

	local fadeIn = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(container, fadeIn, { BackgroundTransparency = 0.35 }):Play()
	TweenService:Create(titleLabel, fadeIn, { TextTransparency = 0, TextStrokeTransparency = 0.2 }):Play()
	TweenService:Create(subLabel, fadeIn, { TextTransparency = 0, TextStrokeTransparency = 0.3 }):Play()

	task.delay(hold, function()
		if not screen.Parent then
			return
		end
		local fadeOut = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(container, fadeOut, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(titleLabel, fadeOut, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		local last = TweenService:Create(subLabel, fadeOut, { TextTransparency = 1, TextStrokeTransparency = 1 })
		last:Play()
		last.Completed:Connect(function()
			screen:Destroy()
		end)
	end)
end

--[[
	The sub-game menu.

	Press the key, pick a game, get taken there. This exists because a
	2000-stud map hides its own contents: there is a hockey rink, a ski
	mountain, a carnival and a river out there and no way to know it from
	the middle of the city.
]]
function Hud.ShowArcadeMenu(games: { { id: string, name: string, objective: string, players: number } })
	local panel = arcadePanel
	local list = arcadeList
	if not panel or not list then
		return
	end

	for _, old in list:GetChildren() do
		if not old:IsA("UIListLayout") then
			old:Destroy()
		end
	end

	arcadeChoices = {}
	for index, game in games do
		local row = Instance.new("TextButton")
		row.Name = game.id
		row.Size = UDim2.new(1, 0, 0, 56)
		row.BackgroundColor3 = Color3.fromRGB(26, 32, 44)
		row.BackgroundTransparency = 0.1
		row.BorderSizePixel = 0
		row.AutoButtonColor = true
		row.Font = Enum.Font.GothamBold
		row.TextColor3 = Color3.fromRGB(240, 246, 252)
		row.TextSize = 18
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.Text = `  {index}.  {game.name}`
		row.LayoutOrder = index
		row.Parent = list

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = row

        local blurb = makeLabel(row, {
			Size = UDim2.new(1, -24, 0, 18),
			Position = UDim2.fromOffset(22, 32),
			Text = game.objective,
			TextSize = 13,
			TextColor3 = Color3.fromRGB(160, 178, 196),
		})
		blurb.Name = "Blurb"

		arcadeChoices[game.id] = row
	end

	panel.Visible = true
end

--[[ Close the menu. ]]
function Hud.HideArcadeMenu()
	if arcadePanel then
		arcadePanel.Visible = false
	end
end

function Hud.ArcadeMenuOpen(): boolean
	return arcadePanel ~= nil and arcadePanel.Visible
end

--[[ Wire a callback to each row, once the menu has been built. ]]
function Hud.OnArcadePick(callback: (string) -> ())
	arcadePick = callback
	for id, row in arcadeChoices do
		row.Activated:Connect(function()
			if arcadePick then
				arcadePick(id)
			end
		end)
	end
end

--[[
	"You are standing on a basketball court. Want a game?"

	Shown when you walk into a venue, because somebody already standing on
	the court should not have to open a menu to use it.
]]
function Hud.ShowArcadeOffer(name: string, objective: string, acceptKey: string)
	if not arcadeOffer then
		return
	end
	arcadeOffer.Text = `{string.upper(name)}  —  {objective}\nPress {acceptKey} to play`
	arcadeOffer.Visible = true

	arcadeOfferToken += 1
	local token = arcadeOfferToken
	task.delay(9, function()
		if arcadeOfferToken == token and arcadeOffer then
			arcadeOffer.Visible = false
		end
	end)
end

function Hud.HideArcadeOffer()
	if arcadeOffer then
		arcadeOffer.Visible = false
	end
end

--[[ Confirmation that you are in, and what the game wants from you. ]]
function Hud.ShowArcadeJoined(name: string, objective: string)
	Hud.HideArcadeOffer()
	Hud.HideArcadeMenu()
	Hud.Medal(string.upper(name))
	Hud.SetStatus(`{string.upper(name)}  —  {objective}`, true)
end

function Hud.SetStatus(text: string, good: boolean)
	if not statusText then
		return
	end
	statusText.Text = text
	statusText.TextColor3 = if good
		then Color3.fromRGB(120, 190, 140)
		else Color3.fromRGB(240, 120, 110)
end

--[[ The crosshair turns gold when auto-aim has actually locked something. ]]
function Hud.SetLocked(locked: boolean)
	if not crosshair then
		return
	end
	crosshair.BackgroundColor3 = if locked
		then Color3.fromRGB(255, 200, 80)
		else Color3.fromRGB(255, 255, 255)
	crosshair.Size = if locked then UDim2.fromOffset(12, 12) else UDim2.fromOffset(6, 6)
	crosshair.Position = if locked
		then UDim2.new(0.5, -6, 0.5, -6)
		else UDim2.new(0.5, -3, 0.5, -3)
end

return Hud
