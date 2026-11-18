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
local Util = require(Shared:WaitForChild("Util"))

local player = Players.LocalPlayer

local Hud = {}

-- Low-health warning and the scoreboard, declared up here with the rest of
-- the widgets so every function can reach them.
local lowHealthHolder: Frame? = nil
local vignetteStrength = 0
local vignettePulse = 0
local scoreboard: Frame? = nil
local scoreboardRows: Frame? = nil
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
local hitmarker: Frame
local damageHolder: Frame
local killFeed: Frame
local medalLabel: TextLabel
local weaponBar: Frame
local slotChips: { [number]: TextLabel } = {}
local weaponLabel: TextLabel
local ammoLabel: TextLabel
local statsLabel: TextLabel
local clockLabel: TextLabel
local scoreLabel: TextLabel
local crosshair: Frame
local votePanel: Frame
local deathOverlay: Frame
local wienerOverlay: TextLabel
local toastHolder: Frame

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

function Hud.Build()
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
	makeLabel(deathOverlay, {
		Size = UDim2.fromScale(1, 1),
		Text = "YOU MELTED",
		TextSize = 64,
		Font = Enum.Font.LuckiestGuy,
		TextXAlignment = Enum.TextXAlignment.Center,
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
			BackgroundTransparency = 0.05,
			ZIndex = 8,
		})
		bar.Name = "ScopeBlind"
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
	weaponBar = makeFrame(screen, {
		Size = UDim2.fromOffset(660, 36),
		Position = UDim2.new(0.5, -330, 1, -64),
		BackgroundTransparency = 1,
	})

	local barLayout = Instance.new("UIListLayout")
	barLayout.FillDirection = Enum.FillDirection.Horizontal
	barLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	barLayout.Padding = UDim.new(0, 6)
	barLayout.Parent = weaponBar

	for slot = 1, 6 do
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
		Text = "PLAYER                                 PTS    KILLS   DEATHS",
		TextSize = 13,
		TextColor3 = Color3.fromRGB(150, 165, 180),
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local rows = makeFrame(board, {
		Size = UDim2.new(1, -24, 1, -84),
		Position = UDim2.fromOffset(12, 72),
		BackgroundTransparency = 1,
	})
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Padding = UDim.new(0, 2)
	rowLayout.Parent = rows

	scoreboard = board
	scoreboardRows = rows

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

	local label = deathOverlay:FindFirstChildOfClass("TextLabel")
	if label then
		label.Text = if killerName then `MELTED BY {string.upper(killerName)}` else "YOU MELTED"
	end

	deathOverlay.Visible = true
	deathOverlay.BackgroundTransparency = 1
	TweenService:Create(deathOverlay, TweenInfo.new(0.25), { BackgroundTransparency = 0.25 }):Play()

	task.delay(duration, function()
		local fade = TweenService:Create(deathOverlay, TweenInfo.new(0.4), { BackgroundTransparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		deathOverlay.Visible = false
	end)
end

function Hud.ShowWiener(teamName: string, duration: number)
	if not wienerOverlay then
		return
	end
	wienerOverlay.Text = `{string.upper(teamName)}\nIS THE WIENER!`
	wienerOverlay.Visible = true
	task.delay(duration, function()
		wienerOverlay.Visible = false
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

	for slot = 1, 6 do
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
function Hud.SetZoom(magnification: number)
	if not zoomText then
		return
	end
	zoomText.Text = if magnification > 0 then `{magnification}×` else ""
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

	hitmarker.Visible = true
	hitmarker.Size = if headshot then UDim2.fromOffset(56, 56) else UDim2.fromOffset(40, 40)
	hitmarker.Position = if headshot
		then UDim2.new(0.5, -28, 0.5, -28)
		else UDim2.new(0.5, -20, 0.5, -20)
	for _, stroke in hitmarker:GetChildren() do
		if stroke:IsA("Frame") then
			stroke.BackgroundColor3 = if headshot
				then Color3.fromRGB(255, 210, 90)
				else Color3.fromRGB(255, 255, 255)
		end
	end

	task.delay(0.12, function()
		if hitmarker then
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
		lines[1]:Destroy()
	end

	local entry = makeLabel(killFeed, {
		Size = UDim2.new(1, 0, 0, 24),
		Text = text,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Right,
		-- Your own kills stand out from everybody else's.
		TextColor3 = if mine then Color3.fromRGB(255, 220, 120) else Color3.fromRGB(205, 215, 225),
	})
	entry.LayoutOrder = math.floor(os.clock() * 100)

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
	medalLabel.Text = text
	medalLabel.TextTransparency = 0
	medalLabel.TextStrokeTransparency = 0.3

	task.delay(1.6, function()
		if not medalLabel then
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
	rows: { { name: string, team: string?, teamColor: Color3?, points: number, kills: number, deaths: number, isYou: boolean? } },
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
		local line = makeLabel(rowHolder, {
			Size = UDim2.new(1, 0, 0, 20),
			Text = string.format(
				"%-30s %6d %7d %8d",
				string.sub(row.name, 1, 30),
				row.points,
				row.kills,
				row.deaths
			),
			TextSize = 15,
			Font = Enum.Font.Code, -- monospaced, or the columns do not line up
			TextColor3 = if row.isYou
				then Color3.fromRGB(255, 240, 150)
				else Color3.fromRGB(215, 225, 235),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		line.LayoutOrder = order
	end
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
