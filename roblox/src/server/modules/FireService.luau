--!strict
--[[
	FireService — gas cans, poured trails, and things burning.

	This is the answer to "we should be able to blow things up and light
	things on fire", and the reason it is a whole service rather than a
	weapon is that the interesting part is not the fire, it is the SETUP.
	A flamethrower is a gun that does damage in a cone. A can of petrol is a
	plan: you pour a trail across the doorway somebody keeps coming through,
	back off, and wait. The pouring is slow and visible and leaves you
	holding something that is not a gun, so laying a trap costs you the
	fight you would otherwise be having -- which is what makes it a choice.

	Three things that make it work rather than just exist:

	- Fire SPREADS between puddles that are close enough. That turns a line
	  of puddles into a fuse, so a trail can be lit from somewhere safe
	  instead of standing in it.
	- Cans explode when shot, and set off other cans near them. So a can is
	  a bomb that anybody can trigger, including the person who placed it.
	- An unlit puddle evaporates. Otherwise twenty players pouring for ten
	  minutes leaves a map permanently ankle-deep in petrol, which is both a
	  performance problem and a worse game.

	Damage goes through DamageService like everything else, so a burning
	death lands in the kill feed, scores for whoever lit it, and counts
	towards a spree exactly as a bullet would.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Sound = require(Shared:WaitForChild("Sound"))
local Util = require(Shared:WaitForChild("Util"))

local BotService = require(script.Parent:WaitForChild("BotService"))
local DamageService = require(script.Parent:WaitForChild("DamageService"))
local MedalService = require(script.Parent:WaitForChild("MedalService"))

local FireService = {}

type Puddle = {
	part: BasePart,
	burning: boolean,
	litAt: number,
	litBy: Player?,
	diesAt: number,
	nextBurnAt: number,
}

type Can = {
	part: BasePart,
	home: Vector3,
	gone: boolean,
}

type Mine = {
	body: BasePart,
	led: BasePart,
	home: Vector3,
	armed: boolean,
}

local puddles: { Puddle } = {}
local cans: { Can } = {}
local mines: { Mine } = {}
local nextBlinkAt = 0
local blinkOn = false
local holder: Model? = nil

-- Who is carrying a can, and how much is left in it.
local fuel: { [Player]: number } = {}
local lastPourAt: { [Player]: number } = {}
local started = false

local probe = RaycastParams.new()
probe.FilterType = Enum.RaycastFilterType.Exclude

--[[ Tell a player what is in their hands, so the action bar can change. ]]
local function pushCarry(player: Player)
	local left = fuel[player]
	Remotes.Event("CarryItem"):FireClient(player, {
		item = if left then "GasCan" else nil,
		fuel = left,
		maxFuel = Config.Fire.CanFuel,
	})
end

--[[ A can standing on the map, waiting to be picked up or shot. ]]
local function spawnCan(at: Vector3, parent: Instance): Can
	local part = Util.Part({
		Name = "GasCan",
		Size = Vector3.new(2.2, 3, 1.6),
		Position = at + Vector3.new(0, 1.5, 0),
		Color = Color3.fromRGB(196, 36, 32),
		Material = Enum.Material.SmoothPlastic,
		Anchored = true,
		Parent = parent,
	})

	local spout = Util.Part({
		Name = "Spout",
		Size = Vector3.new(0.5, 1.1, 0.5),
		Position = at + Vector3.new(0.7, 3.3, 0),
		Color = Color3.fromRGB(232, 194, 44),
		Material = Enum.Material.SmoothPlastic,
		Anchored = true,
		CanCollide = false,
		Parent = parent,
	})
	Util.Weld(part, spout)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Take the gas can"
	prompt.ObjectText = "Gas Can"
	prompt.HoldDuration = 0.25
	prompt.MaxActivationDistance = 10
	prompt.Parent = part

	local record: Can = { part = part, home = at, gone = false }

	prompt.Triggered:Connect(function(player: Player)
		if record.gone or fuel[player] then
			return
		end
		record.gone = true
		fuel[player] = Config.Fire.CanFuel
		pushCarry(player)
		Sound.At("Pickup", part.Position, 0.7)
		part:Destroy()

		-- It comes back, so the map does not run out of them.
		task.delay(Config.Fire.CanRespawnSeconds, function()
			if holder and holder.Parent then
				table.insert(cans, spawnCan(at, holder))
			end
		end)
	end)

	return record
end

--[[
	Launch a fireball into the sky, which explodes again where it lands.

	The second blast is the whole idea: a mine you can see and step round is
	a hazard you learn, and a mine that throws a second explosion somewhere
	unpredictable is a hazard that keeps mattering after you have learned
	it. It also means a mine going off is a thing the whole map notices
	rather than a private accident.
]]
local function launchFireball(from: Vector3, by: Player?)
	local ball = Util.Part({
		Name = "Fireball",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(3.5, 3.5, 3.5),
		CFrame = CFrame.new(from + Vector3.new(0, 4, 0)),
		Color = Color3.fromRGB(255, 110, 20),
		Material = Enum.Material.Neon,
		Anchored = false,
		-- Nothing should be able to shoot it down or stand on it: it is an
		-- event in flight, not an object.
		CanCollide = false,
		CanQuery = false,
		Parent = workspace,
	})

	local fire = Instance.new("Fire")
	fire.Size = 10
	fire.Heat = 20
	fire.Color = Color3.fromRGB(255, 140, 20)
	fire.SecondaryColor = Color3.fromRGB(255, 40, 0)
	fire.Parent = ball

	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 120, 30)
	glow.Range = 28
	glow.Brightness = 4
	glow.Parent = ball

	-- A random direction, so where the second blast lands cannot be learned.
	local angle = math.random() * math.pi * 2
	local across = Config.Fire.FireballSpread * (0.5 + math.random() * 0.5)
	ball.AssemblyLinearVelocity = Vector3.new(
		math.cos(angle) * across,
		Config.Fire.FireballLift,
		math.sin(angle) * across
	)

	--[[
		It comes down on a TIMER, not on contact.

		Touched would be the obvious choice and is wrong here: the ball
		leaves the ground inside a blast that is still expanding, so it
		fires immediately against whatever it was launched from. A flight
		time is both predictable to tune and impossible to trigger early.
	]]
	task.delay(Config.Fire.FireballFlightSeconds, function()
		if not ball.Parent then
			return
		end
		local landed = ball.Position
		ball:Destroy()

		DamageService.Explode(
			landed,
			Config.Fire.FireballBlastRadius,
			Config.Fire.FireballBlastDamage,
			by,
			Config.Fire.CanVehicleMultiplier,
			false,
			"a fireball"
		)

		-- A patch of burning ground where it came down, which is a brief
		-- area to avoid rather than just a noise.
		local scorch = Util.Part({
			Name = "Scorch",
			Size = Vector3.new(10, 0.2, 10),
			CFrame = CFrame.new(landed),
			Color = Color3.fromRGB(26, 22, 18),
			Material = Enum.Material.Ground,
			Anchored = true,
			CanCollide = false,
			CanQuery = false,
			Parent = workspace,
		})
		local groundFire = Instance.new("Fire")
		groundFire.Size = 12
		groundFire.Heat = 15
		groundFire.Parent = scorch
		Debris:AddItem(scorch, Config.Fire.ScorchSeconds)
	end)

	-- A failsafe, in case it leaves the map before the timer comes due.
	Debris:AddItem(ball, Config.Fire.FireballFlightSeconds + 6)
end

--[[
	Set a puddle alight.

	Recursive by design: lighting one lights its neighbours a moment later,
	which is what turns a poured line into a fuse. The delay is what makes
	it readable -- an instant chain would just be a long explosion, and you
	could not watch the fire travel towards somebody.
]]
function FireService.Ignite(puddle: Puddle, by: Player?)
	if puddle.burning or not puddle.part.Parent then
		return
	end
	puddle.burning = true
	puddle.litBy = by
	puddle.litAt = os.clock()
	puddle.diesAt = os.clock() + Config.Fire.BurnSeconds
	puddle.nextBurnAt = 0

	local part = puddle.part
	part.Color = Color3.fromRGB(255, 110, 20)
	part.Material = Enum.Material.Neon

	local fire = Instance.new("Fire")
	fire.Size = 7
	fire.Heat = 15
	fire.Color = Color3.fromRGB(255, 140, 20)
	fire.SecondaryColor = Color3.fromRGB(255, 35, 0)
	fire.Parent = part

	local smoke = Instance.new("Smoke")
	smoke.Size = 4
	smoke.Opacity = 0.45
	smoke.Color = Color3.fromRGB(35, 35, 35)
	smoke.Parent = part

	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 120, 30)
	glow.Range = 18
	glow.Brightness = 2.5
	glow.Parent = part

	Sound.At("Splash", part.Position, 0.5)

	task.delay(Config.Fire.SpreadDelay, function()
		for _, other in puddles do
			if other.burning or not other.part.Parent then
				continue
			end
			if (other.part.Position - part.Position).Magnitude <= Config.Fire.SpreadRadius then
				FireService.Ignite(other, by)
			end
		end
	end)
end

--[[ Pour a puddle in front of whoever is holding the can. ]]
function FireService.Pour(player: Player)
	local left = fuel[player]
	if not left or left <= 0 then
		return
	end

	local now = os.clock()
	if now - (lastPourAt[player] or 0) < Config.Fire.PourInterval then
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return
	end

	-- Where it lands: slightly ahead, then down onto whatever is there.
	probe.FilterDescendantsInstances = { character }
	local from = root.Position + root.CFrame.LookVector * 3.5 + Vector3.new(0, 1, 0)
	local hit = workspace:Raycast(from, Vector3.new(0, -12, 0), probe)
	if not hit then
		return
	end

	lastPourAt[player] = now
	fuel[player] = math.max(0, left - Config.Fire.FuelPerPuddle)
	pushCarry(player)

	local part = Util.Part({
		Name = "GasPuddle",
		Size = Vector3.new(Config.Fire.PuddleSize, 0.12, Config.Fire.PuddleSize),
		Position = hit.Position + Vector3.new(0, 0.08, 0),
		Color = Color3.fromRGB(35, 32, 24),
		Material = Enum.Material.Glass,
		Transparency = 0.2,
		Reflectance = 0.4,
		Anchored = true,
		CanCollide = false,
		-- Invisible to shots. A puddle is ankle-deep: a bullet passing over
		-- it should carry on to whoever is standing behind it.
		CanQuery = false,
		Parent = holder,
	})

	local record: Puddle = {
		part = part,
		burning = false,
		litAt = 0,
		litBy = nil,
		diesAt = 0,
		nextBurnAt = 0,
	}
	table.insert(puddles, record)

	-- Unlit petrol evaporates. Without this, twenty players pouring for ten
	-- minutes leaves the map permanently ankle-deep in it.
	Debris:AddItem(part, Config.Fire.PuddleLifetime)

	-- Poured into something already burning, it catches at once.
	for _, other in puddles do
		if other ~= record and other.burning then
			if (other.part.Position - part.Position).Magnitude <= Config.Fire.SpreadRadius then
				FireService.Ignite(record, other.litBy)
				break
			end
		end
	end

	if fuel[player] == 0 then
		-- Empty. The can goes, and your hands are free again.
		fuel[player] = nil
		pushCarry(player)
		Remotes.Event("Notify"):FireClient(player, "GAS CAN EMPTY")
	end
end

--[[ Light whatever is within reach. ]]
function FireService.Light(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	local lit = 0
	for _, puddle in puddles do
		if puddle.burning or not puddle.part.Parent then
			continue
		end
		if (puddle.part.Position - root.Position).Magnitude <= Config.Fire.LightRange then
			FireService.Ignite(puddle, player)
			lit += 1
		end
	end

	if lit == 0 then
		Remotes.Event("Notify"):FireClient(player, "NOTHING TO LIGHT HERE")
	end
end

--[[
	A can goes up, and takes its neighbours with it.

	Staggered rather than simultaneous, so a row of cans reads as a chain
	rather than as one big bang -- and so the second one can catch somebody
	running away from the first.
]]
function FireService.Detonate(can: Can, by: Player?, depth: number?)
	if can.gone or not can.part.Parent then
		return
	end
	can.gone = true

	local at = can.part.Position
	can.part:Destroy()

	DamageService.Explode(
		at,
		Config.Fire.CanBlastRadius,
		Config.Fire.CanBlastDamage,
		by,
		Config.Fire.CanVehicleMultiplier,
		false,
		"a gas can"
	)

	-- Anything poured nearby catches.
	for _, puddle in puddles do
		if not puddle.burning and puddle.part.Parent then
			if (puddle.part.Position - at).Magnitude <= Config.Fire.CanBlastRadius then
				FireService.Ignite(puddle, by)
			end
		end
	end

	--[[
		A chain reaction is a PLAN, so it is worth announcing.

		Awarded on the second can rather than the first: one can going off
		is a shot, two is a chain. The medal's own repeat guard collapses a
		six-can cluster into one award, which is right -- a chain reaction
		that sets off six cans is one chain reaction, not five.
	]]
	if (depth or 0) >= 1 then
		MedalService.Broadcast(by, "ChainReaction")
	end

	-- And so does the next can along, up to a depth limit so a cluster
	-- cannot recurse forever.
	local level = (depth or 0) + 1
	if level <= Config.Fire.MaxChainDepth then
		for _, other in cans do
			if other.gone or not other.part.Parent then
				continue
			end
			if (other.part.Position - at).Magnitude <= Config.Fire.CanChainRadius then
				local victim = other
				task.delay(Config.Fire.ChainDelay, function()
					FireService.Detonate(victim, by, level)
				end)
			end
		end
	end

	-- It comes back, in its original spot.
	task.delay(Config.Fire.CanRespawnSeconds, function()
		if holder and holder.Parent then
			table.insert(cans, spawnCan(can.home, holder))
		end
	end)
end

--[[
	Was that shot at a gas can? Returns true if it was dealt with here.

	Hooked into the same chain the fairground props use, which is what makes
	a can shootable by every weapon in the game -- including by accident,
	which is most of the fun of it.
]]
function FireService.RegisterHit(part: BasePart, attacker: Player?): boolean
	for _, can in cans do
		if can.part == part and not can.gone then
			FireService.Detonate(can, attacker)
			return true
		end
	end
	return false
end

--[[ A mine goes off. ]]
function FireService.Detonate_Mine(mine: Mine, by: Player?)
	if not mine.armed or not mine.body.Parent then
		return
	end
	mine.armed = false

	local at = mine.body.Position
	mine.body:Destroy()
	if mine.led.Parent then
		mine.led:Destroy()
	end

	DamageService.Explode(
		at,
		Config.Fire.MineBlastRadius,
		Config.Fire.MineBlastDamage,
		by,
		Config.Fire.CanVehicleMultiplier,
		false,
		"a land mine"
	)

	-- Anything poured nearby goes up with it.
	for _, puddle in puddles do
		if not puddle.burning and puddle.part.Parent then
			if (puddle.part.Position - at).Magnitude <= Config.Fire.MineBlastRadius then
				FireService.Ignite(puddle, by)
			end
		end
	end

	launchFireball(at, by)

	-- And it comes back, because a minefield that empties out stops being
	-- a thing you have to think about.
	task.delay(Config.Fire.MineRespawnSeconds, function()
		if holder and holder.Parent then
			FireService.PlaceMine(mine.home)
		end
	end)
end

--[[
	Arm a mine at a spot.

	The blinking light is the entire reason this is fair. A mine you cannot
	see is a random death; a mine with a red light on it is a thing you
	drove over anyway, which is a different feeling and a better one.
]]
function FireService.PlaceMine(at: Vector3): Mine?
	if not holder then
		return nil
	end

	local body = Util.Part({
		Name = "LandMine",
		Shape = Enum.PartType.Cylinder,
		-- A cylinder lies on its side by default, so it is rotated flat.
		Size = Vector3.new(0.45, 2.6, 2.6),
		CFrame = CFrame.new(at + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(55, 65, 50),
		Material = Enum.Material.Metal,
		Anchored = true,
		Parent = holder,
	})

	local led = Util.Part({
		Name = "MineLED",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(0.5, 0.5, 0.5),
		CFrame = CFrame.new(at + Vector3.new(0, 0.7, 0)),
		Color = Color3.fromRGB(255, 30, 30),
		Material = Enum.Material.Neon,
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		Parent = holder,
	})

	local mine: Mine = { body = body, led = led, home = at, armed = true }
	table.insert(mines, mine)

	body.Touched:Connect(function(hit: BasePart)
		--[[
			Anchored things do not set it off.

			The ground the mine is sitting on touches it constantly, and so
			does every wall and kerb beside it. Only something that MOVED
			into it counts, which is exactly the set of things that should
			trigger a mine: people and vehicles.
		]]
		if hit.Anchored then
			return
		end
		FireService.Detonate_Mine(mine, Players:GetPlayerFromCharacter(hit.Parent))
	end)

	return mine
end

--[[ Standing in fire hurts, repeatedly, until you move. ]]
local function burnStep()
	local now = os.clock()

	--[[
		Blink every armed mine, from the one loop that already runs.

		The obvious implementation is a while-loop per mine in its own
		thread, which is what the pasted script did. Twenty mines is then
		twenty threads waking twice a second forever, to toggle a colour.
		One shared flip costs nothing and looks identical.
	]]
	if now >= nextBlinkAt then
		nextBlinkAt = now + Config.Fire.MineBlinkSeconds
		blinkOn = not blinkOn
		local shade = if blinkOn then Color3.fromRGB(255, 30, 30) else Color3.fromRGB(80, 10, 10)
		for index = #mines, 1, -1 do
			local mine = mines[index]
			if not mine.body.Parent then
				table.remove(mines, index)
			elseif mine.armed and mine.led.Parent then
				mine.led.Color = shade
			end
		end
	end

	--[[
		Charged once per character per TICK, across every puddle.

		This used to be per-puddle, and the arithmetic gave the game away:
		standing where four puddles overlapped did four times the damage in
		Config, because each one charged you separately. That made pouring a
		PILE strictly better than pouring a trail -- five puddles underfoot
		was an instant-kill tile -- which is the opposite of the point. The
		plan is supposed to be a line across a doorway, not a heap.

		So being in fire is being in fire, however much petrol went into it.
		Credit for the kill goes to whoever lit the puddle that reached them
		first, which is the only one of the candidates that is not arbitrary.
	]]
	local burnedThisTick: { [Instance]: boolean } = {}

	for index = #puddles, 1, -1 do
		local puddle = puddles[index]

		if not puddle.part.Parent then
			table.remove(puddles, index)
			continue
		end

		if not puddle.burning then
			continue
		end

		if now >= puddle.diesAt then
			puddle.part:Destroy()
			table.remove(puddles, index)
			continue
		end

		if now < puddle.nextBurnAt then
			continue
		end
		puddle.nextBurnAt = now + Config.Fire.BurnInterval

		--[[
			Everyone standing in it.

			A ragdoll has a dozen parts and all of them are inside the
			radius, so charging per-part would burn a player twelve times as
			fast as the number in Config claims.
		]]
		for _, part in workspace:GetPartBoundsInRadius(
			puddle.part.Position + Vector3.new(0, 1.5, 0),
			Config.Fire.BurnRadius
		) do
			local humanoid, character = Util.HumanoidFromHit(part)
			if not humanoid or not character or humanoid.Health <= 0 then
				continue
			end
			if burnedThisTick[character] then
				continue
			end
			burnedThisTick[character] = true

			local victim = Players:GetPlayerFromCharacter(character)
			if victim then
				-- Through DamageService, so a burning death reaches the
				-- kill feed and scores for whoever lit the fire rather
				-- than vanishing as an unattributed TakeDamage.
				DamageService.ApplyDamage(
					victim,
					Config.Fire.BurnDamage,
					puddle.litBy,
					"burned alive"
				)
			else
				-- Bots and wildlife are not Players, so they take the
				-- same route a bullet takes to reach them.
				BotService.RegisterHit(part, Config.Fire.BurnDamage, puddle.litBy)
			end
		end
	end
end

--[[ Scatter cans around the map. Called once the map exists. ]]
function FireService.Build(mapSize: number)
	FireService.Clear()

	local model = Instance.new("Model")
	-- Cans and mines both live here, so the name is the category rather
	-- than one of its members.
	model.Name = "Hazards"
	holder = model

	--[[
		Where they go.

		On a ring rather than at random, because a can that spawns inside a
		building is a can nobody finds, and a can in the open where two
		routes cross is one that gets used -- and shot.

		In CLUSTERS, because a lone can is only a pickup. Three together,
		within the chain radius of each other, is a bomb: shooting one takes
		the others, which is worth doing on purpose and worth not parking
		next to.
	]]
	local radius = mapSize * Config.Fire.CanRingFactor
	for cluster = 1, Config.Fire.CanClusters do
		local angle = (cluster / Config.Fire.CanClusters) * math.pi * 2
		local hub = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)

		for index = 1, Config.Fire.CansPerCluster do
			-- Spaced around the hub rather than stacked, so all three are
			-- reachable, shootable, and inside each other's chain radius.
			local spin = (index / Config.Fire.CansPerCluster) * math.pi * 2
			local offset = Vector3.new(
				math.cos(spin) * Config.Fire.ClusterSpread,
				0,
				math.sin(spin) * Config.Fire.ClusterSpread
			)
			table.insert(cans, spawnCan(hub + offset, model))
		end
	end

	--[[
		Mines on a wider ring than the cans.

		Further out on purpose: a mine near a spawn is a death you had no
		part in, and the point of them is the moment you decide to drive
		over one anyway.
	]]
	local mineRadius = mapSize * Config.Fire.MineRingFactor
	for index = 1, Config.Fire.Mines do
		-- Offset half a step from the can ring so a mine and a can cluster
		-- are never in the same place, which would be one hazard wearing
		-- another's warning light.
		local angle = ((index - 0.5) / Config.Fire.Mines) * math.pi * 2
		FireService.PlaceMine(
			Vector3.new(math.cos(angle) * mineRadius, 0, math.sin(angle) * mineRadius)
		)
	end

	model.Parent = workspace
	return model
end

function FireService.Clear()
	for _, puddle in puddles do
		if puddle.part.Parent then
			puddle.part:Destroy()
		end
	end
	table.clear(puddles)
	table.clear(cans)
	table.clear(mines)
	table.clear(fuel)
	table.clear(lastPourAt)
	if holder then
		holder:Destroy()
		holder = nil
	end
end

function FireService.Start()
	if started then
		return
	end
	started = true

	Remotes.Event("PourGas").OnServerEvent:Connect(function(player: Player)
		FireService.Pour(player)
	end)

	-- The tool context's second action. F lights the trail, which is the
	-- same key the mega-detonate uses when your hands are empty.
	Remotes.Event("ToolSecondary").OnServerEvent:Connect(function(player: Player)
		FireService.Light(player)
	end)

	RunService.Heartbeat:Connect(burnStep)

	Players.PlayerRemoving:Connect(function(player)
		fuel[player] = nil
		lastPourAt[player] = nil
	end)
end

--[[ For tests. ]]
function FireService.PuddleCount(): number
	return #puddles
end

function FireService.BurningCount(): number
	local count = 0
	for _, puddle in puddles do
		if puddle.burning then
			count += 1
		end
	end
	return count
end

function FireService.MineCount(): number
	local count = 0
	for _, mine in mines do
		if mine.armed then
			count += 1
		end
	end
	return count
end

function FireService.MinesForTests(): { any }
	return mines
end

function FireService.CanCount(): number
	local count = 0
	for _, can in cans do
		if not can.gone then
			count += 1
		end
	end
	return count
end

function FireService.FuelOf(player: Player): number?
	return fuel[player]
end

function FireService.GiveCan(player: Player)
	fuel[player] = Config.Fire.CanFuel
	pushCarry(player)
end

function FireService.CansForTests(): { Can }
	return cans
end

function FireService.StepForTests()
	burnStep()
end

return FireService
