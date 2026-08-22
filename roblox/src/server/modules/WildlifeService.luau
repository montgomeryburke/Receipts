--!strict
--[[
	WildlifeService — the giant animals.

	King Kong sized cats, elephants, dogs, fish and gorillas wander the map.
	Bullets do not kill them; each species has its own way of shrugging a hit
	off. Only a diamond bullet's mega-detonation puts one down, and when it
	goes it bursts into a red cloud and something *different* turns up
	elsewhere a few seconds later.

	You can climb on one and ride it. You cannot use a gun while you do — the
	animal is the weapon, and it flattens whatever it runs over.

	The animals are anchored and moved by script rather than being physics
	objects. A forty-stud ragdoll shouldering its way through a firefight
	would fling everybody into orbit, and an anchored one cannot wedge itself
	in a doorway and stay there for the rest of the round.
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

type Species = typeof(Config.Beasts[1])

type Beast = {
	model: Model,
	body: BasePart,
	head: BasePart?,
	seat: VehicleSeat,
	species: Species,
	position: Vector3,
	facing: Vector3,
	target: Vector3,
	standHeight: number,
	-- "Wander" normally; a species-specific reaction when shot.
	mood: string,
	moodUntil: number,
	nextPoopAt: number,
	lastTrampleAt: number,
}

local beasts: { Beast } = {}
local poopPiles: { BasePart } = {}
local wanderRadius = 300
local rng = Random.new()

local S = Config.Beast.Scale

-- ================================================================= BUILDING ==

local function limb(parent: Instance, anchorTo: BasePart, size: Vector3, offset: CFrame, colour: Color3, name: string): BasePart
	local part = Util.Part({
		Name = name,
		Size = size,
		CFrame = anchorTo.CFrame * offset,
		Color = colour,
		Material = Enum.Material.SmoothPlastic,
		-- Players and bullets pass through the body: it is a moving landmark
		-- with a temper, not a wall to get pinned against.
		CanCollide = false,
		Parent = parent,
	})
	Util.Weld(anchorTo, part)
	return part
end

--[[ Four legs, a body, a head. The shape that covers cat, dog and elephant. ]]
local function buildQuadruped(
	species: Species,
	position: Vector3,
	bodySize: Vector3,
	legLength: number,
	headSize: number,
	extras: string
): (Model, BasePart, BasePart, number)
	local model = Instance.new("Model")
	model.Name = species.Name

	local standHeight = legLength + bodySize.Y * 0.5
	local colour = species.Colour

	local body = Util.Part({
		Name = "Body",
		Size = bodySize,
		CFrame = CFrame.new(position + Vector3.new(0, standHeight, 0)),
		Color = colour,
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		Parent = model,
	})
	model.PrimaryPart = body

	local head = limb(
		model, body,
		Vector3.new(headSize, headSize, headSize),
		CFrame.new(0, bodySize.Y * 0.35, -bodySize.Z * 0.55 - headSize * 0.4),
		colour:Lerp(Color3.new(1, 1, 1), 0.08),
		"Head"
	)

	-- Legs.
	for _, corner in {
		Vector3.new(-1, 0, -1), Vector3.new(1, 0, -1),
		Vector3.new(-1, 0, 1), Vector3.new(1, 0, 1),
	} do
		limb(
			model, body,
			Vector3.new(bodySize.X * 0.22, legLength, bodySize.X * 0.22),
			CFrame.new(
				corner.X * bodySize.X * 0.34,
				-bodySize.Y * 0.5 - legLength * 0.5,
				corner.Z * bodySize.Z * 0.32
			),
			colour:Lerp(Color3.new(0, 0, 0), 0.12),
			"Leg"
		)
	end

	if extras == "Cat" then
		-- Pointed ears and a long tail.
		for _, side in { -1, 1 } do
			limb(model, head, Vector3.new(headSize * 0.18, headSize * 0.45, headSize * 0.18),
				CFrame.new(side * headSize * 0.28, headSize * 0.6, 0), colour, "Ear")
		end
		-- Annotated, because `body` is a Part and each tail segment comes
		-- back as a BasePart.
		local previous: BasePart = body
		for segment = 1, 6 do
			previous = limb(model, previous,
				Vector3.new(headSize * 0.2, headSize * 0.2, bodySize.Z * 0.18),
				CFrame.new(0, bodySize.Y * 0.3, bodySize.Z * 0.35 + segment * bodySize.Z * 0.12),
				colour, "Tail")
		end
		-- Whiskers, because it should read as a cat from a distance.
		for _, side in { -1, 1 } do
			limb(model, head, Vector3.new(headSize * 0.9, 0.5 * S, 0.5 * S),
				CFrame.new(side * headSize * 0.5, -headSize * 0.1, -headSize * 0.45),
				Color3.fromRGB(240, 240, 235), "Whisker")
		end
	elseif extras == "Dog" then
		-- Floppy ears, a snout and a stubby tail.
		for _, side in { -1, 1 } do
			limb(model, head, Vector3.new(headSize * 0.16, headSize * 0.55, headSize * 0.4),
				CFrame.new(side * headSize * 0.5, headSize * 0.15, 0),
				colour:Lerp(Color3.new(0, 0, 0), 0.2), "Ear")
		end
		limb(model, head, Vector3.new(headSize * 0.45, headSize * 0.4, headSize * 0.6),
			CFrame.new(0, -headSize * 0.15, -headSize * 0.7),
			colour:Lerp(Color3.new(0, 0, 0), 0.15), "Snout")
		limb(model, body, Vector3.new(headSize * 0.25, headSize * 0.25, bodySize.Z * 0.3),
			CFrame.new(0, bodySize.Y * 0.35, bodySize.Z * 0.6), colour, "Tail")
	elseif extras == "Elephant" then
		-- Trunk, ears, tusks.
		local previous = head
		for segment = 1, 5 do
			local thickness = headSize * (0.34 - segment * 0.04)
			previous = limb(model, previous, Vector3.new(thickness, thickness, headSize * 0.3),
				CFrame.new(0, -headSize * 0.3, -headSize * 0.35), colour, "Trunk")
		end
		for _, side in { -1, 1 } do
			limb(model, head, Vector3.new(headSize * 0.1, headSize * 0.8, headSize * 0.8),
				CFrame.new(side * headSize * 0.55, headSize * 0.1, headSize * 0.1),
				colour:Lerp(Color3.new(1, 1, 1), 0.12), "Ear")
			limb(model, head, Vector3.new(headSize * 0.12, headSize * 0.12, headSize * 0.75),
				CFrame.new(side * headSize * 0.25, -headSize * 0.35, -headSize * 0.5),
				Color3.fromRGB(240, 235, 215), "Tusk")
		end
	end

	model.Parent = workspace
	return model, body, head, standHeight
end

--[[ A fish. No legs, so on land it can only flop, which is the joke. ]]
local function buildFish(species: Species, position: Vector3): (Model, BasePart, BasePart, number)
	local model = Instance.new("Model")
	model.Name = species.Name

	local bodySize = Vector3.new(16 * S, 20 * S, 42 * S)
	local standHeight = bodySize.Y * 0.5

	local body = Util.Part({
		Name = "Body",
		Size = bodySize,
		CFrame = CFrame.new(position + Vector3.new(0, standHeight, 0)),
		Color = species.Colour,
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		Parent = model,
	})
	model.PrimaryPart = body

	local head = limb(model, body, Vector3.new(bodySize.X * 0.8, bodySize.Y * 0.8, bodySize.Z * 0.25),
		CFrame.new(0, 0, -bodySize.Z * 0.55), species.Colour:Lerp(Color3.new(1, 1, 1), 0.1), "Head")

	-- Eyes, enormous and unblinking.
	for _, side in { -1, 1 } do
		limb(model, head, Vector3.new(bodySize.X * 0.3, bodySize.X * 0.3, bodySize.X * 0.3),
			CFrame.new(side * bodySize.X * 0.35, bodySize.Y * 0.2, -bodySize.Z * 0.05),
			Color3.fromRGB(250, 250, 250), "Eye")
	end

	-- Tail fin and side fins.
	limb(model, body, Vector3.new(bodySize.X * 0.25, bodySize.Y * 1.3, bodySize.Z * 0.3),
		CFrame.new(0, 0, bodySize.Z * 0.62), species.Colour:Lerp(Color3.new(0, 0, 0), 0.15), "TailFin")
	for _, side in { -1, 1 } do
		limb(model, body, Vector3.new(bodySize.X * 0.7, bodySize.Y * 0.12, bodySize.Z * 0.28),
			CFrame.new(side * bodySize.X * 0.55, -bodySize.Y * 0.15, 0),
			species.Colour:Lerp(Color3.new(0, 0, 0), 0.15), "Fin")
	end
	limb(model, body, Vector3.new(bodySize.X * 0.15, bodySize.Y * 0.5, bodySize.Z * 0.4),
		CFrame.new(0, bodySize.Y * 0.6, 0), species.Colour:Lerp(Color3.new(0, 0, 0), 0.2), "DorsalFin")

	model.Parent = workspace
	return model, body, head, standHeight
end

--[[ A gorilla: upright, huge arms, small legs. ]]
local function buildGorilla(species: Species, position: Vector3): (Model, BasePart, BasePart, number)
	local model = Instance.new("Model")
	model.Name = species.Name

	local torsoSize = Vector3.new(22 * S, 26 * S, 16 * S)
	local legLength = 12 * S
	local standHeight = legLength + torsoSize.Y * 0.5

	local body = Util.Part({
		Name = "Body",
		Size = torsoSize,
		CFrame = CFrame.new(position + Vector3.new(0, standHeight, 0)),
		Color = species.Colour,
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		Parent = model,
	})
	model.PrimaryPart = body

	local head = limb(model, body, Vector3.new(12 * S, 11 * S, 12 * S),
		CFrame.new(0, torsoSize.Y * 0.62, -1 * S), species.Colour:Lerp(Color3.new(1, 1, 1), 0.1), "Head")
	limb(model, head, Vector3.new(8 * S, 5 * S, 3 * S),
		CFrame.new(0, -2 * S, -6 * S), Color3.fromRGB(48, 44, 44), "Muzzle")

	-- Arms down to the floor, as they should be.
	for _, side in { -1, 1 } do
		limb(model, body, Vector3.new(7 * S, 26 * S, 7 * S),
			CFrame.new(side * torsoSize.X * 0.62, -torsoSize.Y * 0.15, 0),
			species.Colour:Lerp(Color3.new(0, 0, 0), 0.1), "Arm")
		limb(model, body, Vector3.new(8 * S, legLength, 8 * S),
			CFrame.new(side * torsoSize.X * 0.28, -torsoSize.Y * 0.5 - legLength * 0.5, 0),
			species.Colour:Lerp(Color3.new(0, 0, 0), 0.15), "Leg")
	end

	model.Parent = workspace
	return model, body, head, standHeight
end

--[[ Build whichever species this is. ]]
local function buildSpecies(species: Species, position: Vector3): (Model, BasePart, BasePart?, number)
	if species.Id == "Fish" then
		return buildFish(species, position)
	elseif species.Id == "Gorilla" then
		return buildGorilla(species, position)
	elseif species.Id == "Cat" then
		return buildQuadruped(species, position, Vector3.new(16 * S, 14 * S, 34 * S), 13 * S, 13 * S, "Cat")
	elseif species.Id == "Dog" then
		return buildQuadruped(species, position, Vector3.new(15 * S, 15 * S, 30 * S), 14 * S, 13 * S, "Dog")
	end
	return buildQuadruped(species, position, Vector3.new(22 * S, 20 * S, 40 * S), 18 * S, 16 * S, "Elephant")
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

	for lump = 1, 2 do
		local extra = Util.Part({
			Name = "Lump",
			Size = Vector3.new(5 - lump, 3.5, 5 - lump),
			CFrame = pile.CFrame * CFrame.new(rng:NextNumber(-2, 2), lump * 2, rng:NextNumber(-2, 2)),
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
	Debris:AddItem(pile, Config.Wildlife.PoopLifetime)
end

-- ================================================================== SPAWNING ==

local function pickTarget(): Vector3
	return Vector3.new(
		rng:NextNumber(-wanderRadius, wanderRadius),
		0,
		rng:NextNumber(-wanderRadius, wanderRadius)
	)
end

--[[ Sit a beast on whatever the ground turns out to be beneath it. ]]
local function groundHeight(position: Vector3, ignore: Instance): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignore }
	local hit = workspace:Raycast(position + Vector3.new(0, 200, 0), Vector3.new(0, -600, 0), params)
	return if hit then hit.Position.Y else 0
end

local function spawnBeast(species: Species, position: Vector3)
	local model, body, head, standHeight = buildSpecies(species, position)

	model:SetAttribute("IsBeast", true)
	model:SetAttribute("Species", species.Id)

	-- A saddle on its back, with a prompt to climb aboard.
	local seat = Instance.new("VehicleSeat")
	seat.Name = "BeastSeat"
	seat.Size = Vector3.new(8, 1, 10)
	seat.CFrame = body.CFrame * CFrame.new(0, body.Size.Y * 0.5 + 1, 0)
	seat.Anchored = false
	seat.Massless = true
	seat.MaxSpeed = 0
	seat.Torque = 0
	seat.TurnSpeed = 0
	seat.Color = Color3.fromRGB(90, 60, 40)
	seat.Parent = model
	Util.Weld(body, seat)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Ride it"
	prompt.ObjectText = species.Name
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 40
	prompt.RequiresLineOfSight = false
	prompt.Parent = seat

	prompt.Triggered:Connect(function(player)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and not humanoid.SeatPart then
			seat:Sit(humanoid)
		end
	end)

	-- Riding one takes your guns away and gives you the animal instead.
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = seat.Occupant
		if occupant then
			local character = occupant.Parent
			local player = if character then Players:GetPlayerFromCharacter(character) else nil
			if player then
				local state = PlayerState.Get(player)
				state.vehicle = model
				state.seatRole = "Beast"
				PlayerState.Changed.Fire(player)
				Remotes.Event("Notify"):FireClient(
					player,
					`Riding the {species.Name}. No guns — run them over instead.`
				)
			end
			return
		end
		for _, player in Players:GetPlayers() do
			local state = PlayerState.Get(player)
			if state.vehicle == model and state.seatRole == "Beast" then
				state.vehicle = nil
				state.seatRole = nil
				PlayerState.Changed.Fire(player)
			end
		end
	end)

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(20, 4)
	billboard.StudsOffset = Vector3.new(0, body.Size.Y * 0.9, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 1500
	billboard.Parent = body

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = species.Name
	label.TextColor3 = Color3.fromRGB(255, 220, 180)
	label.TextStrokeTransparency = 0.25
	label.TextScaled = true
	label.Font = Enum.Font.LuckiestGuy
	label.Parent = billboard

	table.insert(beasts, {
		model = model,
		body = body,
		head = head,
		seat = seat,
		species = species,
		position = position,
		facing = Vector3.new(0, 0, 1),
		target = pickTarget(),
		standHeight = standHeight,
		mood = "Wander",
		moodUntil = 0,
		nextPoopAt = os.clock() + rng:NextNumber(3, Config.Wildlife.PoopInterval),
		lastTrampleAt = 0,
	})
end

--[[ Come back somewhere else, as something else. ]]
local function respawnAsDifferent(previous: Species)
	local choices = {}
	for _, species in Config.Beasts do
		if species.Id ~= previous.Id then
			table.insert(choices, species)
		end
	end
	if #choices == 0 then
		return
	end

	local next_ = choices[rng:NextInteger(1, #choices)]
	local where = pickTarget()
	spawnBeast(next_, Vector3.new(where.X, groundHeight(where, workspace), where.Z))

	for _, player in Players:GetPlayers() do
		Remotes.Event("Notify"):FireClient(player, `A {next_.Name} has appeared somewhere.`)
	end
end

-- ==================================================================== DEATH ==

--[[ The red cloud. Only a mega-detonation gets one of these. ]]
local function burst(beast: Beast)
	local position = beast.body.Position

	local anchor = Util.Part({
		Name = "RedCloud",
		Size = Vector3.new(1, 1, 1),
		CFrame = CFrame.new(position),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		Parent = workspace,
	})

	local cloud = Instance.new("ParticleEmitter")
	cloud.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(220, 30, 30)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(90, 0, 0)),
	})
	cloud.Size = NumberSequence.new(40, 90)
	cloud.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	cloud.Lifetime = NumberRange.new(1.4, 2.6)
	cloud.Speed = NumberRange.new(18, 46)
	cloud.SpreadAngle = Vector2.new(180, 180)
	cloud.Rate = 0
	cloud.Parent = anchor
	cloud:Emit(220)

	Debris:AddItem(anchor, 4)

	local species = beast.species
	beast.model:Destroy()

	task.delay(Config.Beast.RespawnDelay, function()
		respawnAsDifferent(species)
	end)
end

--[[
	A mega-detonation went off. Anything caught in it bursts.

	Ordinary bullets and grenades do nothing at all — this is the only thing
	that kills a giant animal.
]]
local function onMegaBlast(position: Vector3, radius: number, attacker: Player?)
	for index = #beasts, 1, -1 do
		local beast = beasts[index]
		-- A little wider than the blast itself, because the animals are
		-- enormous and being clipped by the edge should still count. Not
		-- much wider: at 2.5x a single shot cleared half the map.
		if beast.model.Parent and (beast.body.Position - position).Magnitude <= radius * 1.25 then
			table.remove(beasts, index)
			if attacker then
				Remotes.Event("Notify"):FireClient(attacker, `You vaporised the {beast.species.Name}.`)
			end
			burst(beast)
		end
	end
end

-- ================================================================ REACTIONS ==

--[[
	Somebody shot it. Bullets cannot kill it, but they do annoy it, and each
	species is annoyed in its own way.
]]
function WildlifeService.RegisterHit(part: BasePart)
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if model:GetAttribute("IsBeast") then
			for _, beast in beasts do
				if beast.model == model and beast.mood == "Wander" then
					beast.mood = beast.species.Reaction
					beast.moodUntil = os.clock() + Config.Beast.ReactionDuration
				end
			end
			return true
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return false
end

--[[ Play out whatever this species does when it has been shot. ]]
local function playReaction(beast: Beast, deltaTime: number)
	local now = os.clock()
	local head = beast.head
	local wobble = math.sin(now * 9)

	if beast.mood == "Lick" then
		-- Sits and washes the sore bit.
		if head then
			head.CFrame = beast.body.CFrame
				* CFrame.new(0, -beast.body.Size.Y * 0.1, -beast.body.Size.Z * 0.5)
				* CFrame.Angles(math.rad(55 + wobble * 8), 0, 0)
		end
	elseif beast.mood == "ChestBeat" then
		-- Rears up and hammers its chest.
		beast.model:PivotTo(
			CFrame.new(beast.position + Vector3.new(0, beast.standHeight + math.abs(wobble) * 6, 0))
				* CFrame.Angles(0, math.atan2(beast.facing.X, beast.facing.Z), 0)
		)
		return
	elseif beast.mood == "Shake" then
		-- Shakes itself off, nose to tail.
		beast.model:PivotTo(
			CFrame.new(beast.position + Vector3.new(0, beast.standHeight, 0))
				* CFrame.Angles(0, math.atan2(beast.facing.X, beast.facing.Z), math.rad(wobble * 14))
		)
		return
	elseif beast.mood == "Flop" then
		-- A fish on dry land, having a very bad time.
		beast.model:PivotTo(
			CFrame.new(beast.position + Vector3.new(0, beast.standHeight + math.abs(wobble) * 10, 0))
				* CFrame.Angles(math.rad(wobble * 25), math.atan2(beast.facing.X, beast.facing.Z), math.rad(wobble * 40))
		)
		return
	elseif beast.mood == "Poop" then
		-- Startled, and the result is immediate.
		if now >= beast.nextPoopAt then
			beast.nextPoopAt = now + 1.2
			dropPoop(beast.position - beast.facing * 30 * S * 0.4)
		end
	end

	local _ = deltaTime
end

-- ================================================================== MOVEMENT ==

--[[ Flatten anybody in front of a moving animal. ]]
local function trample(beast: Beast, speed: number)
	if speed < 6 then
		return
	end
	local now = os.clock()
	if now - beast.lastTrampleAt < 0.5 then
		return
	end

	local nose = beast.position + beast.facing * (beast.body.Size.Z * 0.5)
	local rider: Player? = nil
	local occupant = beast.seat.Occupant
	if occupant and occupant.Parent then
		rider = Players:GetPlayerFromCharacter(occupant.Parent)
	end

	for _, player in Players:GetPlayers() do
		if player == rider then
			continue
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			if (root.Position - nose).Magnitude <= Config.Beast.TrampleRadius * S * 0.5 then
				beast.lastTrampleAt = now
				DamageService.ApplyDamage(player, beast.species.TrampleDamage, rider, "Trampled")
				-- And sent flying.
				root.AssemblyLinearVelocity = beast.facing * 90 + Vector3.new(0, 60, 0)
			end
		end
	end
end

local function stepBeast(beast: Beast, deltaTime: number)
	local now = os.clock()

	-- A reaction stops it in its tracks until it wears off.
	if beast.mood ~= "Wander" then
		if now >= beast.moodUntil then
			beast.mood = "Wander"
		else
			playReaction(beast, deltaTime)
			return
		end
	end

	local occupant = beast.seat.Occupant
	local speed = beast.species.Speed
	local throttle, steer = 0, 0

	if occupant then
		-- Being ridden: the player drives.
		speed = beast.species.RideSpeed
		throttle = beast.seat.Throttle
		steer = beast.seat.Steer

		local pedal = beast.model:GetAttribute("Pedal")
		if typeof(pedal) == "number" and math.abs(pedal) > 0.01 then
			throttle = math.clamp(pedal, -1, 1)
		end

		if math.abs(steer) > 0.01 then
			local turn = -steer * 1.6 * deltaTime
			beast.facing = (CFrame.Angles(0, turn, 0) * beast.facing).Unit
		end
	else
		-- Left to itself: wander.
		throttle = 1
		local toTarget = beast.target - beast.position
		toTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
		if toTarget.Magnitude < 40 then
			beast.target = pickTarget()
			return
		end
		local direction = toTarget.Unit
		beast.facing = (beast.facing + (direction - beast.facing) * math.min(1, deltaTime * 1.5)).Unit
	end

	local travelled = speed * throttle * deltaTime
	beast.position += beast.facing * travelled
	beast.position = Vector3.new(
		beast.position.X,
		groundHeight(beast.position, beast.model),
		beast.position.Z
	)

	-- A fish cannot walk, so it hops along instead.
	local bounce = 0
	if beast.species.Id == "Fish" and math.abs(throttle) > 0.01 then
		bounce = math.abs(math.sin(now * 6)) * 14
	end

	local stand = beast.position + Vector3.new(0, beast.standHeight + bounce, 0)
	beast.model:PivotTo(CFrame.lookAt(stand, stand + beast.facing))

	trample(beast, math.abs(speed * throttle))

	-- Elephants poop as they go, ridden or not.
	if beast.species.Id == "Elephant" and now >= beast.nextPoopAt then
		beast.nextPoopAt = now + Config.Wildlife.PoopInterval * rng:NextNumber(0.7, 1.4)
		dropPoop(beast.position - beast.facing * 30 * S * 0.4)
	end
end

local function step(deltaTime: number)
	for index = #beasts, 1, -1 do
		local beast = beasts[index]
		if not beast.model.Parent then
			table.remove(beasts, index)
		else
			stepBeast(beast, deltaTime)
		end
	end
end

-- =================================================================== PUBLIC ==

--[[ Put the animals on the current map. ]]
function WildlifeService.Populate(mapSize: number)
	WildlifeService.Clear()
	wanderRadius = mapSize * 0.4

	-- Always different species to begin with, so no two look the same.
	local pool = table.clone(Config.Beasts)
	for _ = 1, math.min(Config.Beast.Count, #pool) do
		local pick = rng:NextInteger(1, #pool)
		local species = pool[pick]
		table.remove(pool, pick)

		local where = pickTarget()
		spawnBeast(species, Vector3.new(where.X, groundHeight(where, workspace), where.Z))
	end
end

function WildlifeService.Clear()
	for _, beast in beasts do
		if beast.model.Parent then
			beast.model:Destroy()
		end
	end
	table.clear(beasts)

	for _, pile in poopPiles do
		if pile.Parent then
			pile:Destroy()
		end
	end
	table.clear(poopPiles)
end

--[[ Is this player currently riding an animal? Guns are off if so. ]]
function WildlifeService.IsRiding(player: Player): boolean
	local state = PlayerState.Get(player)
	return state.seatRole == "Beast"
end

function WildlifeService.Count(): number
	return #beasts
end

function WildlifeService.PoopCount(): number
	return #poopPiles
end

--[[ The species currently walking about, for the tests. ]]
function WildlifeService.SpeciesPresent(): { string }
	local names = {}
	for _, beast in beasts do
		table.insert(names, beast.species.Id)
	end
	return names
end

DamageService.MegaBlast.Connect(onMegaBlast)
RunService.Heartbeat:Connect(step)

return WildlifeService
