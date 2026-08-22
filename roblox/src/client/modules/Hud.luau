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

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared:WaitForChild("Util"))

local player = Players.LocalPlayer

local Hud = {}

local screen: ScreenGui
local healthFill: Frame
local shieldFill: Frame
local shieldTrack: Frame
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
end

-- ================================================================ UPDATING ==

function Hud.SetHealth(current: number, maximum: number)
	if not healthFill then
		return
	end
	local fraction = if maximum > 0 then math.clamp(current / maximum, 0, 1) else 0
	healthFill.Size = UDim2.fromScale(fraction, 1)
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

function Hud.SetMatch(phase: string, timeLeft: number, scores: { number }, mapName: string)
	if not clockLabel then
		return
	end

	if phase == "Playing" then
		clockLabel.Text = `{mapName}  ·  {Util.FormatClock(timeLeft)}`
	elseif phase == "Voting" then
		clockLabel.Text = `VOTING  ·  {Util.FormatClock(timeLeft)}`
	elseif phase == "Intermission" then
		clockLabel.Text = "ROUND OVER"
	else
		clockLabel.Text = "WAITING FOR PLAYERS"
	end

	scoreLabel.Text = `RED {scores[1] or 0}   —   BLUE {scores[2] or 0}`
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
