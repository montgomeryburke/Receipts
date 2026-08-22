--!strict
--[[
	EffectService — the silly half of the game.

	Lava death screens, a donkey, a sparkle-farting unicorn, a cat telling you
	to hang in there, and the WIENER celebration when a team wins.

	Everything here is deliberately visual only. Roblox audio IDs cannot be
	guessed — a wrong one throws a real error at runtime — so the guide shows
	you where to drop sounds in from the Toolbox instead of me inventing IDs
	that would break your game.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Util = require(Shared:WaitForChild("Util"))

local EffectService = {}

local rng = Random.new()

--[[ A burst of coloured particles at a spot in the world. ]]
local function burst(position: Vector3, colour: Color3, count: number, spread: number)
	local anchor = Util.Part({
		Name = "EffectAnchor",
		Size = Vector3.new(0.2, 0.2, 0.2),
		CFrame = CFrame.new(position),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Parent = workspace,
	})

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(colour)
	emitter.Size = NumberSequence.new(2.5, 0)
	emitter.Lifetime = NumberRange.new(0.6, 1.4)
	emitter.Speed = NumberRange.new(spread * 0.5, spread)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0
	emitter.Parent = anchor
	emitter:Emit(count)

	Debris:AddItem(anchor, 3)
end

--[[
	The donkey. A stubby grey thing that appears where you died, brays
	silently, and wanders off.
]]
local function spawnDonkey(position: Vector3)
	local model = Instance.new("Model")
	model.Name = "Donkey"

	local body = Util.Part({
		Name = "Body",
		Size = Vector3.new(3, 3, 6),
		CFrame = CFrame.new(position + Vector3.new(0, 4, 0)),
		Color = Color3.fromRGB(120, 116, 110),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		Parent = model,
	})
	model.PrimaryPart = body

	local head = Util.Part({
		Name = "Head",
		Size = Vector3.new(2, 2.5, 2.5),
		CFrame = body.CFrame * CFrame.new(0, 2, -3.5),
		Color = Color3.fromRGB(130, 126, 120),
		CanCollide = false,
		Parent = model,
	})
	Util.Weld(body, head)

	for _, ear in { -0.7, 0.7 } do
		local earPart = Util.Part({
			Name = "Ear",
			Size = Vector3.new(0.5, 2, 0.5),
			CFrame = head.CFrame * CFrame.new(ear, 2, 0),
			Color = Color3.fromRGB(110, 106, 100),
			CanCollide = false,
			Parent = model,
		})
		Util.Weld(head, earPart)
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(10, 3)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "HEE-HAW"
	label.TextColor3 = Color3.fromRGB(255, 240, 200)
	label.TextStrokeTransparency = 0.2
	label.TextScaled = true
	label.Font = Enum.Font.LuckiestGuy
	label.Parent = billboard

	model.Parent = workspace
	Debris:AddItem(model, 6)
end

--[[ The unicorn. It sparkles, and it farts sparkles. ]]
local function spawnUnicorn(position: Vector3)
	local model = Instance.new("Model")
	model.Name = "SparkleUnicorn"

	local body = Util.Part({
		Name = "Body",
		Size = Vector3.new(3, 3, 6),
		CFrame = CFrame.new(position + Vector3.new(0, 4, 0)),
		Color = Color3.fromRGB(255, 235, 250),
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = model,
	})
	model.PrimaryPart = body

	local horn = Util.Part({
		Name = "Horn",
		Size = Vector3.new(0.6, 3, 0.6),
		CFrame = body.CFrame * CFrame.new(0, 3, -3),
		Color = Color3.fromRGB(255, 200, 90),
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = model,
	})
	Util.Weld(body, horn)

	-- The important part.
	local rear = Util.Attachment(body, Vector3.new(0, 0, 3.2), "Rear")
	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 120, 220)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(140, 220, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 240, 140)),
	})
	sparkles.Size = NumberSequence.new(1.6, 0)
	sparkles.Lifetime = NumberRange.new(0.8, 1.6)
	sparkles.Speed = NumberRange.new(12, 22)
	sparkles.SpreadAngle = Vector2.new(35, 35)
	sparkles.Rate = 90
	sparkles.Parent = rear

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(12, 3)
	billboard.StudsOffset = Vector3.new(0, 6, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = body

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "PBBBT!"
	label.TextColor3 = Color3.fromRGB(255, 170, 240)
	label.TextStrokeTransparency = 0.2
	label.TextScaled = true
	label.Font = Enum.Font.LuckiestGuy
	label.Parent = billboard

	model.Parent = workspace
	Debris:AddItem(model, 6)
end

--[[ Hang in there. ]]
local function spawnCat(position: Vector3)
	local sign = Util.Part({
		Name = "HangInThereCat",
		Size = Vector3.new(10, 10, 0.4),
		CFrame = CFrame.new(position + Vector3.new(0, 9, 0)),
		Color = Color3.fromRGB(250, 240, 220),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		Parent = workspace,
	})

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(14, 6)
	billboard.AlwaysOnTop = true
	billboard.Parent = sign

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "HANG IN THERE\nMEOW"
	label.TextColor3 = Color3.fromRGB(60, 50, 40)
	label.TextScaled = true
	label.Font = Enum.Font.LuckiestGuy
	label.Parent = billboard

	Debris:AddItem(sign, 6)
end

--[[ Roll the dice on a gag when somebody dies. ]]
function EffectService.PlayDeathGag(position: Vector3)
	if rng:NextNumber() > Config.Effects.GagChance then
		return
	end

	local gag = Config.Effects.Gags[rng:NextInteger(1, #Config.Effects.Gags)]
	if gag == "Donkey" then
		spawnDonkey(position)
	elseif gag == "Unicorn" then
		spawnUnicorn(position)
	else
		spawnCat(position)
	end

	burst(position, Color3.fromRGB(255, 200, 120), 40, 20)
end

--[[ Tell one player's screen to go lava-red because they just died. ]]
function EffectService.ShowDeathScreen(player: Player, killerName: string?)
	Remotes.Event("DeathScreen"):FireClient(player, {
		duration = Config.Effects.DeathScreenDuration,
		killer = killerName,
	})
end

--[[
	WIENER. The winning team gets hot dogs raining out of the sky and a very
	large word across everybody's screen.
]]
function EffectService.CelebrateWinner(teamName: string)
	for _, player in Players:GetPlayers() do
		Remotes.Event("PlayEffect"):FireClient(player, {
			effect = "Wiener",
			team = teamName,
			duration = Config.Effects.WienerDuration,
		})
	end

	-- Actual hot dogs, falling on the arena.
	task.spawn(function()
		local deadline = os.clock() + Config.Effects.WienerDuration
		while os.clock() < deadline do
			local drop = Util.Part({
				Name = "HotDog",
				Size = Vector3.new(2, 2, 7),
				CFrame = CFrame.new(rng:NextNumber(-260, 260), 220, rng:NextNumber(-260, 260))
					* CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), rng:NextNumber(0, 6)),
				Color = Color3.fromRGB(220, 150, 90),
				Material = Enum.Material.SmoothPlastic,
				Anchored = false,
				CanCollide = false,
				Parent = workspace,
			})

			local bun = Util.Part({
				Name = "Bun",
				Size = Vector3.new(2.6, 1.2, 7.4),
				CFrame = drop.CFrame * CFrame.new(0, -0.9, 0),
				Color = Color3.fromRGB(240, 205, 140),
				Anchored = false,
				CanCollide = false,
				Massless = true,
				Parent = workspace,
			})
			Util.Weld(drop, bun)

			Debris:AddItem(drop, 8)
			Debris:AddItem(bun, 8)
			task.wait(0.08)
		end
	end)
end

return EffectService
