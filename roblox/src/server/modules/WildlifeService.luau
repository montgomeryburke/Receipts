--!strict
--[[
	WildlifeService — the elephant.

	It walks the map on its own, minds its own business, and leaves a great
	deal of poop behind it. The poop is the point: walk over a pile to pick it
	up, then throw it at people.

	The elephant is anchored and moved by script rather than being a physics
	object. That is deliberate — a two-tonne ragdoll wandering into a firefight
	would fling players across the map, and an anchored one cannot be shoved
	into a wall and get stuck there.
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

local WildlifeService = {}

local LEG_HEIGHT = 11
local BODY_HEIGHT = 12

type Elephant = {
	model: Model,
	root: BasePart,
	position: Vector3,
	facing: Vector3,
	target: Vector3,
	nextPoopAt: number,
}

local elephants: { Elephant } = {}
local poopPiles: { BasePart } = {}
local wanderRadius = 300
local rng = Random.new()

-- ================================================================ BUILDING ==

local function grey(shade: number): Color3
	return Color3.fromRGB(120 + shade, 116 + shade, 112 + shade)
end

--[[ Assemble an elephant out of boxes. It reads as one from twenty studs. ]]
local function buildElephant(position: Vector3): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "Elephant"

	local body = Util.Part({
		Name = "Body",
		Size = Vector3.new(14, BODY_HEIGHT, 26),
		CFrame = CFrame.new(position + Vector3.new(0, LEG_HEIGHT + BODY_HEIGHT * 0.5, 0)),
		Color = grey(0),
		Material = Enum.Material.SmoothPlastic,
		-- Players and bullets pass through: it is scenery with a schedule,
		-- not an obstacle to get wedged against.
		CanCollide = false,
		Parent = model,
	})
	model.PrimaryPart = body

	local head = Util.Part({
		Name = "Head",
		Size = Vector3.new(10, 10, 10),
		CFrame = body.CFrame * CFrame.new(0, 2, -16),
		Color = grey(8),
		CanCollide = false,
		Parent = model,
	})
	Util.Weld(body, head)

	-- Trunk, in tapering segments so it hangs.
	local previous = head
	for segment = 1, 5 do
		local thickness = 4.2 - segment * 0.5
		local piece = Util.Part({
			Name = "Trunk",
			Size = Vector3.new(thickness, thickness, 4),
			CFrame = head.CFrame * CFrame.new(0, -4 - segment * 2.2, -4 - segment * 0.9),
			Color = grey(6),
			CanCollide = false,
			Parent = model,
		})
		Util.Weld(previous, piece)
		previous = piece
	end

	-- Ears.
	for _, side in { -1, 1 } do
		local ear = Util.Part({
			Name = "Ear",
			Size = Vector3.new(1, 9, 9),
			CFrame = head.CFrame * CFrame.new(side * 5.5, 1, 1),
			Color = grey(14),
			CanCollide = false,
			Parent = model,
		})
		Util.Weld(head, ear)
	end

	-- Tusks.
	for _, side in { -1, 1 } do
		local tusk = Util.Part({
			Name = "Tusk",
			Size = Vector3.new(1.4, 1.4, 8),
			CFrame = head.CFrame * CFrame.new(side * 3, -4, -5),
			Color = Color3.fromRGB(240, 235, 215),
			CanCollide = false,
			Parent = model,
		})
		Util.Weld(head, tusk)
	end

	-- Legs.
	for _, corner in {
		Vector3.new(-5, 0, -9),
		Vector3.new(5, 0, -9),
		Vector3.new(-5, 0, 9),
		Vector3.new(5, 0, 9),
	} do
		local leg = Util.Part({
			Name = "Leg",
			Size = Vector3.new(4.5, LEG_HEIGHT, 4.5),
			CFrame = body.CFrame * CFrame.new(corner.X, -BODY_HEIGHT * 0.5 - LEG_HEIGHT * 0.5, corner.Z),
			Color = grey(-6),
			CanCollide = false,
			Parent = model,
		})
		Util.Weld(body, leg)
	end

	local tail = Util.Part({
		Name = "Tail",
		Size = Vector3.new(1.2, 1.2, 7),
		CFrame = body.CFrame * CFrame.new(0, 3, 15),
		Color = grey(-4),
		CanCollide = false,
		Parent = model,
	})
	Util.Weld(body, tail)

	model.Parent = workspace
	return model, body
end

-- ==================================================================== POOP ==

--[[ Give whoever walked into it something to throw. ]]
local function collectPoop(player: Player, pile: BasePart)
	local state = PlayerState.Get(player)
	local slot = state.weapons.Poop
	local spec = Config.Weapons.Poop
	if not slot or not spec then
		return
	end

	slot.ammo = math.min(spec.MagSize, slot.ammo + Config.Wildlife.PoopPerPile)
	PlayerState.Changed.Fire(player)
	Remotes.Event("Notify"):FireClient(player, `Picked up poop — press 7 to throw it`)

	local index = table.find(poopPiles, pile)
	if index then
		table.remove(poopPiles, index)
	end
	pile:Destroy()
end

--[[ Drop a pile. Three lumps, so it reads as what it is. ]]
local function dropPoop(position: Vector3)
	-- Keep a lid on how much is lying around.
	if #poopPiles >= Config.Wildlife.MaxPoopPiles then
		local oldest = table.remove(poopPiles, 1)
		if oldest and oldest.Parent then
			oldest:Destroy()
		end
	end

	local pile = Util.Part({
		Name = "PoopPile",
		Size = Vector3.new(4, 3, 4),
		CFrame = CFrame.new(position + Vector3.new(0, 1.5, 0)),
		Shape = Enum.PartType.Ball,
		Color = Color3.fromRGB(92, 64, 38),
		Material = Enum.Material.Sand,
		CanCollide = false,
		Parent = workspace,
	})

	for lump = 1, 2 do
		local extra = Util.Part({
			Name = "Lump",
			Size = Vector3.new(3.2 - lump * 0.6, 2.4, 3.2 - lump * 0.6),
			CFrame = pile.CFrame * CFrame.new(rng:NextNumber(-1.5, 1.5), lump * 1.3, rng:NextNumber(-1.5, 1.5)),
			Shape = Enum.PartType.Ball,
			Color = Color3.fromRGB(84, 58, 34),
			Material = Enum.Material.Sand,
			CanCollide = false,
			Parent = pile,
		})
		Util.Weld(pile, extra)
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(6, 1.6)
	billboard.StudsOffset = Vector3.new(0, 3.5, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 220
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
	Debris:AddItem(pile, Config.Wildlife.PoopLifetime)
end

-- ================================================================ WANDERING ==

local function pickTarget(): Vector3
	return Vector3.new(
		rng:NextNumber(-wanderRadius, wanderRadius),
		0,
		rng:NextNumber(-wanderRadius, wanderRadius)
	)
end

--[[ Walk one elephant a frame's worth, and drop poop when it is due. ]]
local function stepElephant(elephant: Elephant, deltaTime: number)
	if not elephant.model.Parent then
		return
	end

	local toTarget = elephant.target - elephant.position
	toTarget = Vector3.new(toTarget.X, 0, toTarget.Z)

	if toTarget.Magnitude < 25 then
		elephant.target = pickTarget()
		return
	end

	local direction = toTarget.Unit
	-- Ease the turn, so it swings round rather than pivoting on the spot.
	elephant.facing = (elephant.facing + (direction - elephant.facing) * math.min(1, deltaTime * 2)).Unit
	elephant.position += elephant.facing * Config.Wildlife.ElephantSpeed * deltaTime

	-- Sit it on whatever the ground turns out to be.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { elephant.model }
	local ground = workspace:Raycast(
		elephant.position + Vector3.new(0, 120, 0),
		Vector3.new(0, -400, 0),
		params
	)
	local groundY = if ground then ground.Position.Y else 0
	elephant.position = Vector3.new(elephant.position.X, groundY, elephant.position.Z)

	local stand = elephant.position + Vector3.new(0, LEG_HEIGHT + BODY_HEIGHT * 0.5, 0)
	elephant.model:PivotTo(CFrame.lookAt(stand, stand + elephant.facing))

	if os.clock() >= elephant.nextPoopAt then
		elephant.nextPoopAt = os.clock() + Config.Wildlife.PoopInterval * rng:NextNumber(0.7, 1.4)
		-- Out the back, where you would expect.
		dropPoop(elephant.position - elephant.facing * 16)
	end
end

local function step(deltaTime: number)
	for index = #elephants, 1, -1 do
		local elephant = elephants[index]
		if not elephant.model.Parent then
			table.remove(elephants, index)
		else
			stepElephant(elephant, deltaTime)
		end
	end
end

-- =================================================================== PUBLIC ==

--[[ Put elephants on the current map. ]]
function WildlifeService.Populate(mapSize: number)
	WildlifeService.Clear()
	wanderRadius = mapSize * 0.4

	for _ = 1, Config.Wildlife.ElephantCount do
		local start = pickTarget()
		local model, root = buildElephant(start)
		table.insert(elephants, {
			model = model,
			root = root,
			position = start,
			facing = Vector3.new(0, 0, 1),
			target = pickTarget(),
			nextPoopAt = os.clock() + rng:NextNumber(2, Config.Wildlife.PoopInterval),
		})
	end
end

function WildlifeService.Clear()
	for _, elephant in elephants do
		if elephant.model.Parent then
			elephant.model:Destroy()
		end
	end
	table.clear(elephants)

	for _, pile in poopPiles do
		if pile.Parent then
			pile:Destroy()
		end
	end
	table.clear(poopPiles)
end

--[[ How many elephants are currently walking about. Used by the tests. ]]
function WildlifeService.Count(): number
	return #elephants
end

function WildlifeService.PoopCount(): number
	return #poopPiles
end

RunService.Heartbeat:Connect(step)

return WildlifeService
