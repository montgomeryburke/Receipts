--!strict
--[[
	WildlifeService — everything on the map that is alive and is not a player.

	  Zombies    roam, come for you, and hit you if they reach you.
	  Civilians  wander, and say something regrettable when shot.
	  Targets    stand still with a bullseye on them, for practice.

	All three are worth points, all three come back a few seconds after they
	go down, and all three carry a target ring so you can pick them out.

	Poop is still here too: elephants are gone, but a pile that gets shot
	turns into a tower with a staircase round it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Util = require(Shared:WaitForChild("Util"))

local DamageService = require(script.Parent:WaitForChild("DamageService"))
local PlayerState = require(script.Parent:WaitForChild("PlayerState"))

local WildlifeService = {}

type Dweller = {
	kind: string,
	model: Model,
	root: BasePart,
	position: Vector3,
	facing: Vector3,
	target: Vector3,
	health: number,
	maxHealth: number,
	standHeight: number,
	nextAttackAt: number,
	dead: boolean,
}

local dwellers: { Dweller } = {}
local poopPiles: { BasePart } = {}
local wanderRadius = 300
local rng = Random.new()

-- ================================================================ FURNITURE ==

--[[ The bullseye ring that marks anything worth shooting. ]]
local function addBullseye(attachTo: BasePart, height: number)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Bullseye"
	billboard.Size = UDim2.fromOffset(70, 70)
	billboard.StudsOffset = Vector3.new(0, height, 0)
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 500
	billboard.Parent = attachTo

	-- Concentric rings, red and white, drawn out of nested frames.
	local shades = {
		Color3.fromRGB(220, 40, 40),
		Color3.fromRGB(245, 245, 245),
		Color3.fromRGB(220, 40, 40),
		Color3.fromRGB(245, 245, 245),
	}
	local parent: Instance = billboard
	for index, shade in shades do
		local ring = Instance.new("Frame")
		ring.Size = if index == 1 then UDim2.fromScale(1, 1) else UDim2.fromScale(0.72, 0.72)
		ring.Position = if index == 1 then UDim2.fromScale(0, 0) else UDim2.fromScale(0.14, 0.14)
		ring.BackgroundColor3 = shade
		ring.BorderSizePixel = 0
		ring.Parent = parent

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = ring

		parent = ring
	end
end

--[[ A floating line of speech above someone's head. ]]
local function say(attachTo: BasePart, text: string, colour: Color3, seconds: number)
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(18, 3)
	billboard.StudsOffset = Vector3.new(0, 6, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 400
	billboard.Parent = attachTo

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = colour
	label.TextStrokeTransparency = 0.25
	label.TextScaled = true
	label.Font = Enum.Font.LuckiestGuy
	label.Parent = billboard

	Debris:AddItem(billboard, seconds)
end

--[[ A green cloud, for the obvious reason. ]]
local function fart(position: Vector3)
	local anchor = Util.Part({
		Name = "Fart",
		Size = Vector3.new(0.5, 0.5, 0.5),
		CFrame = CFrame.new(position),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		Parent = workspace,
	})

	local cloud = Instance.new("ParticleEmitter")
	cloud.Color = ColorSequence.new(Color3.fromRGB(150, 200, 90))
	cloud.Size = NumberSequence.new(3, 9)
	cloud.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	cloud.Lifetime = NumberRange.new(0.9, 1.8)
	cloud.Speed = NumberRange.new(4, 11)
	cloud.SpreadAngle = Vector2.new(60, 60)
	cloud.Rate = 0
	cloud.Parent = anchor
	cloud:Emit(40)

	Debris:AddItem(anchor, 3)
end

-- ================================================================= BUILDING ==

--[[ A rough person: torso, head, arms, legs. Colour tells you which kind. ]]
local function buildPerson(position: Vector3, skin: Color3, clothes: Color3, name: string): (Model, BasePart, number)
	local model = Instance.new("Model")
	model.Name = name

	local standHeight = 5.5

	local torso = Util.Part({
		Name = "Torso",
		Size = Vector3.new(2.6, 3.4, 1.5),
		CFrame = CFrame.new(position + Vector3.new(0, standHeight, 0)),
		Color = clothes,
		Material = Enum.Material.Fabric,
		CanCollide = false,
		Parent = model,
	})
	model.PrimaryPart = torso

	local head = Util.Part({
		Name = "Head",
		Size = Vector3.new(1.7, 1.7, 1.7),
		CFrame = torso.CFrame * CFrame.new(0, 2.6, 0),
		Color = skin,
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		Parent = model,
	})
	Util.Weld(torso, head)

	for _, side in { -1, 1 } do
		local arm = Util.Part({
			Name = "Arm",
			Size = Vector3.new(0.9, 3.2, 0.9),
			CFrame = torso.CFrame * CFrame.new(side * 1.75, 0, 0),
			Color = skin,
			Material = Enum.Material.SmoothPlastic,
			CanCollide = false,
			Parent = model,
		})
		Util.Weld(torso, arm)

		local leg = Util.Part({
			Name = "Leg",
			Size = Vector3.new(1.1, 3.4, 1.1),
			CFrame = torso.CFrame * CFrame.new(side * 0.7, -3.4, 0),
			Color = clothes:Lerp(Color3.new(0, 0, 0), 0.4),
			Material = Enum.Material.Fabric,
			CanCollide = false,
			Parent = model,
		})
		Util.Weld(torso, leg)
	end

	model.Parent = workspace
	return model, torso, standHeight
end

local function spawnZombie(position: Vector3)
	local model, torso, standHeight = buildPerson(
		position,
		Color3.fromRGB(126, 158, 110),
		Color3.fromRGB(72, 84, 66),
		"Zombie"
	)
	model:SetAttribute("Dweller", "Zombie")
	addBullseye(torso, 5)

	-- Arms out in front, so it reads as a zombie at a glance.
	for _, arm in model:GetChildren() do
		if arm:IsA("BasePart") and arm.Name == "Arm" then
			arm.CFrame = arm.CFrame * CFrame.new(0, 1.1, -1.5) * CFrame.Angles(math.rad(-75), 0, 0)
		end
	end

	table.insert(dwellers, {
		kind = "Zombie",
		model = model,
		root = torso :: BasePart,
		position = position,
		facing = Vector3.new(0, 0, 1),
		target = position,
		health = Config.Population.ZombieHealth,
		maxHealth = Config.Population.ZombieHealth,
		standHeight = standHeight,
		nextAttackAt = 0,
		dead = false,
	})
end

local function spawnCivilian(position: Vector3)
	local shirts = {
		Color3.fromRGB(220, 90, 90), Color3.fromRGB(90, 140, 220),
		Color3.fromRGB(240, 200, 80), Color3.fromRGB(140, 200, 130),
		Color3.fromRGB(200, 120, 210),
	}
	local model, torso, standHeight = buildPerson(
		position,
		Color3.fromRGB(226, 186, 150),
		shirts[rng:NextInteger(1, #shirts)],
		"Civilian"
	)
	model:SetAttribute("Dweller", "Civilian")
	addBullseye(torso, 5)

	table.insert(dwellers, {
		kind = "Civilian",
		model = model,
		root = torso :: BasePart,
		position = position,
		facing = Vector3.new(0, 0, 1),
		target = position,
		health = Config.Population.CivilianHealth,
		maxHealth = Config.Population.CivilianHealth,
		standHeight = standHeight,
		nextAttackAt = 0,
		dead = false,
	})
end

--[[ A practice target on a post: board, bullseye, and a stand. ]]
local function spawnTarget(position: Vector3)
	local model = Instance.new("Model")
	model.Name = "PracticeTarget"
	model:SetAttribute("Dweller", "Target")

	local post = Util.Part({
		Name = "Post",
		Size = Vector3.new(1.2, 12, 1.2),
		CFrame = CFrame.new(position + Vector3.new(0, 6, 0)),
		Color = Color3.fromRGB(110, 82, 54),
		Material = Enum.Material.Wood,
		Parent = model,
	})

	local board = Util.Part({
		Name = "Board",
		Size = Vector3.new(11, 11, 0.8),
		CFrame = CFrame.new(position + Vector3.new(0, 15, 0))
			* CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0),
		Color = Color3.fromRGB(245, 245, 240),
		Material = Enum.Material.WoodPlanks,
		Parent = model,
	})
	model.PrimaryPart = board
	Util.Weld(post, board)

	-- Painted rings, front and back, so it works from either side.
	for _, facing in { 1, -1 } do
		local radius = 5.0
		for ring = 1, 4 do
			Util.Part({
				Name = "Ring",
				Size = Vector3.new(radius * 2, radius * 2, 0.2),
				CFrame = board.CFrame * CFrame.new(0, 0, facing * (0.45 + ring * 0.01)),
				Shape = Enum.PartType.Cylinder,
				Color = if ring % 2 == 1 then Color3.fromRGB(220, 40, 40) else Color3.fromRGB(250, 250, 250),
				Material = Enum.Material.SmoothPlastic,
				CanCollide = false,
				Parent = model,
			})
			radius *= 0.72
		end
	end

	-- A cylinder lies on its own X, so the rings need standing upright.
	for _, ring in model:GetChildren() do
		if ring:IsA("BasePart") and ring.Name == "Ring" then
			ring.CFrame = ring.CFrame * CFrame.Angles(0, math.rad(90), 0)
			Util.Weld(board, ring)
		end
	end

	model.Parent = workspace

	table.insert(dwellers, {
		kind = "Target",
		model = model,
		root = board :: BasePart,
		position = position,
		facing = Vector3.new(0, 0, 1),
		target = position,
		health = Config.Population.TargetHealth,
		maxHealth = Config.Population.TargetHealth,
		standHeight = 15,
		nextAttackAt = 0,
		dead = false,
	})
end

-- ==================================================================== POOP ==

local function collectPoop(player: Player, pile: BasePart)
	local state = PlayerState.Get(player)
	local slot = state.weapons.Poop
	local spec = Config.Weapons.Poop
	if not slot or not spec then
		return
	end
	slot.ammo = math.min(spec.MagSize, slot.ammo + Config.Wildlife.PoopPerPile)
	PlayerState.Changed.Fire(player)
	Remotes.Event("Notify"):FireClient(player, "Picked up poop — press 7 to throw it")

	local index = table.find(poopPiles, pile)
	if index then
		table.remove(poopPiles, index)
	end
	pile:Destroy()
end

--[[
	Shoot a pile and it grows into a tower with a staircase wrapped round it.

	Which is ridiculous, and also genuinely useful: the top is a good sniping
	platform, and the only way up is the stairs.
]]
local function raisePoopColumn(pile: BasePart)
	local base = pile.Position
	local index = table.find(poopPiles, pile)
	if index then
		table.remove(poopPiles, index)
	end
	pile:Destroy()

	local model = Instance.new("Model")
	model.Name = "PoopColumn"

	local height = 84
	local radius = 7

	local column = Util.Part({
		Name = "Column",
		Size = Vector3.new(radius * 2, height, radius * 2),
		CFrame = CFrame.new(base + Vector3.new(0, height * 0.5, 0)),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(92, 64, 38),
		Material = Enum.Material.Sand,
		Parent = model,
	})
	-- Stand the cylinder upright.
	column.CFrame = CFrame.new(base + Vector3.new(0, height * 0.5, 0)) * CFrame.Angles(0, 0, math.rad(90))

	-- The platform on top.
	Util.Part({
		Name = "Platform",
		Size = Vector3.new(radius * 4, 1.5, radius * 4),
		CFrame = CFrame.new(base + Vector3.new(0, height, 0)),
		Color = Color3.fromRGB(104, 74, 44),
		Material = Enum.Material.Sand,
		Parent = model,
	})
	-- A lip, so you can lie down up there without rolling off.
	for _, side in { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) } do
		Util.Part({
			Name = "Lip",
			Size = Vector3.new(
				if side.X ~= 0 then 1 else radius * 4,
				3,
				if side.Z ~= 0 then 1 else radius * 4
			),
			CFrame = CFrame.new(base + side * radius * 2 + Vector3.new(0, height + 2, 0)),
			Color = Color3.fromRGB(84, 58, 34),
			Material = Enum.Material.Sand,
			Parent = model,
		})
	end

	-- The spiral: one step at a time, round and round.
	local steps = 64
	local turns = 3.5
	for step = 1, steps do
		local fraction = step / steps
		local angle = fraction * turns * math.pi * 2
		local y = fraction * (height - 2)
		local outward = radius + 3.5

		Util.Part({
			Name = "SpiralStep",
			Size = Vector3.new(7, 1, 4.5),
			CFrame = CFrame.new(base + Vector3.new(math.cos(angle) * outward, y, math.sin(angle) * outward))
				* CFrame.Angles(0, -angle + math.pi * 0.5, 0),
			Color = Color3.fromRGB(120, 88, 52),
			Material = Enum.Material.WoodPlanks,
			Parent = model,
		})
	end

	model.Parent = workspace

	for _, player in Players:GetPlayers() do
		Remotes.Event("Notify"):FireClient(player, "A poop tower has risen. There are stairs.")
	end
end

local function dropPoop(position: Vector3)
	if #poopPiles >= Config.Wildlife.MaxPoopPiles then
		local oldest = table.remove(poopPiles, 1)
		if oldest and oldest.Parent then
			oldest:Destroy()
		end
	end

	local pile = Util.Part({
		Name = "PoopPile",
		Size = Vector3.new(6, 4.5, 6),
		CFrame = CFrame.new(position + Vector3.new(0, 2, 0)),
		Shape = Enum.PartType.Ball,
		Color = Color3.fromRGB(92, 64, 38),
		Material = Enum.Material.Sand,
		CanCollide = false,
		Parent = workspace,
	})
	pile:SetAttribute("Poop", true)

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(6, 1.6)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 250
	billboard.Parent = pile

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "POOP"
	label.TextColor3 = Color3.fromRGB(210, 180, 140)
	label.TextStrokeTransparency = 0.3
	label.TextScaled = true
	label.Font = Enum.Font.LuckiestGuy
	label.Parent = billboard

	pile.Touched:Connect(function(hit)
		if not pile.Parent then
			return
		end
		local character = hit:FindFirstAncestorOfClass("Model")
		local player = if character then Players:GetPlayerFromCharacter(character) else nil
		if player then
			collectPoop(player, pile)
		end
	end)

	table.insert(poopPiles, pile)
end

--[[ Scatter some poop about, since there is no elephant leaving it any more. ]]
local function seedPoop()
	for _ = 1, 12 do
		dropPoop(Vector3.new(
			rng:NextNumber(-wanderRadius, wanderRadius),
			2,
			rng:NextNumber(-wanderRadius, wanderRadius)
		))
	end
end

-- ==================================================================== DEATH ==

local function respawnOne(kind: string)
	local where = Vector3.new(
		rng:NextNumber(-wanderRadius, wanderRadius),
		4,
		rng:NextNumber(-wanderRadius, wanderRadius)
	)
	if kind == "Zombie" then
		spawnZombie(where)
	elseif kind == "Civilian" then
		spawnCivilian(where)
	else
		spawnTarget(where)
	end
end

local function kill(dweller: Dweller, attacker: Player?)
	if dweller.dead then
		return
	end
	dweller.dead = true

	local points = if dweller.kind == "Zombie" then Config.Population.ZombiePoints
		elseif dweller.kind == "Civilian" then Config.Population.CivilianPoints
		else Config.Population.TargetPoints

	if attacker then
		local earned = PlayerState.AwardPoints(attacker, points)
		Remotes.Event("Notify"):FireClient(attacker, `+{earned} — {dweller.kind}`)
	end

	-- A burst of whatever colour suits.
	local anchor = Util.Part({
		Name = "Burst",
		Size = Vector3.new(0.5, 0.5, 0.5),
		CFrame = CFrame.new(dweller.root.Position),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		Parent = workspace,
	})
	local burst = Instance.new("ParticleEmitter")
	burst.Color = ColorSequence.new(
		if dweller.kind == "Zombie" then Color3.fromRGB(110, 160, 90) else Color3.fromRGB(220, 60, 60)
	)
	burst.Size = NumberSequence.new(2.5, 0)
	burst.Lifetime = NumberRange.new(0.5, 1.1)
	burst.Speed = NumberRange.new(14, 34)
	burst.SpreadAngle = Vector2.new(180, 180)
	burst.Rate = 0
	burst.Parent = anchor
	burst:Emit(60)
	Debris:AddItem(anchor, 2.5)

	local kind = dweller.kind
	dweller.model:Destroy()
	task.delay(Config.Population.RespawnDelay, function()
		respawnOne(kind)
	end)
end

--[[
	Something was shot. Returns true if this module handled it, so the caller
	knows not to look for a player or a vehicle as well.
]]
function WildlifeService.RegisterHit(part: BasePart, damage: number?, attacker: Player?): boolean
	-- A poop pile that takes a hit grows into a tower.
	if part:GetAttribute("Poop") then
		raisePoopColumn(part)
		return true
	end

	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if model:GetAttribute("Dweller") then
			for _, dweller in dwellers do
				if dweller.model == model and not dweller.dead then
					dweller.health -= (damage or 20)

					if dweller.kind == "Civilian" then
						local line = Config.CivilianLines[rng:NextInteger(1, #Config.CivilianLines)]
						say(dweller.root, line, Color3.fromRGB(255, 240, 200), 3)
						fart(dweller.root.Position - Vector3.new(0, 1.5, 0))
					elseif dweller.kind == "Zombie" then
						say(dweller.root, "RRRAAAGH", Color3.fromRGB(160, 220, 130), 1.5)
					end

					if dweller.health <= 0 then
						kill(dweller, attacker)
					end
					return true
				end
			end
			return true
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return false
end

-- ================================================================= MOVEMENT ==

local function nearestPlayer(from: Vector3): (Player?, Vector3?, number)
	local best: Player? = nil
	local bestPosition: Vector3? = nil
	local bestDistance = math.huge

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
			local distance = (root.Position - from).Magnitude
			if distance < bestDistance then
				best, bestPosition, bestDistance = player, root.Position, distance
			end
		end
	end

	return best, bestPosition, bestDistance
end

local function groundHeight(position: Vector3, ignore: Instance): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignore }
	local hit = workspace:Raycast(position + Vector3.new(0, 200, 0), Vector3.new(0, -600, 0), params)
	return if hit then hit.Position.Y else 0
end

local function stepDweller(dweller: Dweller, deltaTime: number)
	-- Targets do not go anywhere.
	if dweller.kind == "Target" then
		return
	end

	local speed = if dweller.kind == "Zombie"
		then Config.Population.ZombieSpeed
		else Config.Population.CivilianSpeed

	local goal: Vector3
	if dweller.kind == "Zombie" then
		-- Zombies come for whoever is closest.
		local player, position, distance = nearestPlayer(dweller.position)
		if position and distance < 320 then
			goal = position

			-- Close enough to swing.
			if distance <= Config.Population.ZombieReach and player then
				local now = os.clock()
				if now >= dweller.nextAttackAt then
					dweller.nextAttackAt = now + 1.2
					DamageService.ApplyDamage(player, Config.Population.ZombieDamage, nil, "Zombie")
					say(dweller.root, "NOM", Color3.fromRGB(200, 90, 90), 1)
				end
				return
			end
		else
			goal = dweller.target
		end
	else
		goal = dweller.target
	end

	local toGoal = Vector3.new(goal.X - dweller.position.X, 0, goal.Z - dweller.position.Z)
	if toGoal.Magnitude < 12 then
		dweller.target = Vector3.new(
			rng:NextNumber(-wanderRadius, wanderRadius),
			0,
			rng:NextNumber(-wanderRadius, wanderRadius)
		)
		return
	end

	local direction = toGoal.Unit
	dweller.facing = (dweller.facing + (direction - dweller.facing) * math.min(1, deltaTime * 3)).Unit
	dweller.position += dweller.facing * speed * deltaTime
	dweller.position = Vector3.new(
		dweller.position.X,
		groundHeight(dweller.position, dweller.model),
		dweller.position.Z
	)

	-- A little bob, so they look like they are walking rather than sliding.
	local bob = math.abs(math.sin(os.clock() * 7)) * 0.4
	local stand = dweller.position + Vector3.new(0, dweller.standHeight + bob, 0)
	dweller.model:PivotTo(CFrame.lookAt(stand, stand + dweller.facing))
end

local function step(deltaTime: number)
	for index = #dwellers, 1, -1 do
		local dweller = dwellers[index]
		if not dweller.model.Parent then
			table.remove(dwellers, index)
		else
			stepDweller(dweller, deltaTime)
		end
	end
end

-- =================================================================== PUBLIC ==

function WildlifeService.Populate(mapSize: number)
	WildlifeService.Clear()
	wanderRadius = mapSize * 0.4

	local function scatter(): Vector3
		return Vector3.new(
			rng:NextNumber(-wanderRadius, wanderRadius),
			4,
			rng:NextNumber(-wanderRadius, wanderRadius)
		)
	end

	for _ = 1, Config.Population.Zombies do
		spawnZombie(scatter())
	end
	for _ = 1, Config.Population.Civilians do
		spawnCivilian(scatter())
	end
	for _ = 1, Config.Population.Targets do
		spawnTarget(scatter())
	end

	seedPoop()
end

function WildlifeService.Clear()
	for _, dweller in dwellers do
		if dweller.model.Parent then
			dweller.model:Destroy()
		end
	end
	table.clear(dwellers)

	for _, pile in poopPiles do
		if pile.Parent then
			pile:Destroy()
		end
	end
	table.clear(poopPiles)

	for _, child in workspace:GetChildren() do
		if child.Name == "PoopColumn" then
			child:Destroy()
		end
	end
end

--[[ Nothing is rideable any more, but the weapon code still asks. ]]
function WildlifeService.IsRiding(_player: Player): boolean
	return false
end

function WildlifeService.Count(): number
	return #dwellers
end

function WildlifeService.PoopCount(): number
	return #poopPiles
end

--[[ How many of each kind are about, for the tests. ]]
function WildlifeService.CountOf(kind: string): number
	local total = 0
	for _, dweller in dwellers do
		if dweller.kind == kind and not dweller.dead then
			total += 1
		end
	end
	return total
end

RunService.Heartbeat:Connect(step)

return WildlifeService
