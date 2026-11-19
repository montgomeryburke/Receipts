--!strict
--[[
	Nuclear Mud Arena — the bots.

	Computer players, so that walking into the rink or up to the ski lift is
	never a disappointment. A venue with nobody in it is worse than no venue
	at all, and on a quiet server that is every venue.

	They are not real Players -- Roblox has no way to fake one -- so they are
	models with a Humanoid, a team number in an attribute, and a brain the
	venue drives. That means every piece of code that asks
	`Players:GetPlayerFromCharacter` gets nil for a bot, which is why hits on
	them are routed through BotService.RegisterHit the same way the zombies
	and the carnival props are.

	They are also shootable, killable, and worth points, because the rule
	here is that you can shoot anybody at any time -- including the goalie.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Signal = require(Shared:WaitForChild("Signal"))
local Sound = require(Shared:WaitForChild("Sound"))
local Util = require(Shared:WaitForChild("Util"))

local Lifetime = require(script.Parent:WaitForChild("Lifetime"))
local PlayerState = require(script.Parent:WaitForChild("PlayerState"))

local BotService = {}

--[[ Fired as (bot, killer) when a bot is killed. ]]
BotService.Killed = Signal.new()

export type Bot = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	name: string,
	team: number,
	-- Which venue owns it, so a venue can clean up only its own.
	venue: string,
	role: string,
	health: number,
	maxHealth: number,
	dead: boolean,
	-- Where the brain currently wants to be.
	goal: Vector3?,
	-- Where a goalie belongs. He tracks sideways from here and never
	-- leaves his line, which is what makes him a goalie rather than a
	-- fifth skater. Also a dummy's post, which it wanders around.
	home: Vector3?,
	-- When a dummy next picks somewhere new to stand.
	nextWanderAt: number?,
	-- Simple combat: bots shoot back.
	nextShotAt: number,
	homeAt: Vector3,
}

local bots: { Bot } = {}

local FIRST_NAMES = {
	"Dale", "Cletus", "Darla", "Roscoe", "Bobbi", "Earl", "Junior", "Maybelle",
	"Tucker", "Shelby", "Gator", "Peaches", "Buford", "Luanne", "Hoyt", "Dixie",
}

local nextBotNumber = 0

local function botName(): string
	nextBotNumber += 1
	local first = FIRST_NAMES[((nextBotNumber - 1) % #FIRST_NAMES) + 1]
	return `{first} (CPU)`
end

--[[
	A body with a Humanoid, so Roblox's own walking does the hard part.

	Using a real Humanoid rather than moving a part by hand means they walk
	round obstacles, climb the stairs, fall off things and ragdoll when they
	die, all for free.
]]
local function buildBody(
	name: string,
	team: number,
	position: Vector3,
	jersey: number?
): (Model, Humanoid, BasePart)
	-- Config.Teams stores a BrickColor, which carries the Color3 in .Color.
	local brick = Config.Teams[team] and Config.Teams[team].Color
	local colour = if brick then brick.Color else Color3.fromRGB(180, 180, 190)

	local model = Instance.new("Model")
	model.Name = name

	local root = Util.Part({
		Name = "HumanoidRootPart",
		Size = Vector3.new(2, 2, 1),
		CFrame = CFrame.new(position + Vector3.new(0, 3, 0)),
		Transparency = 1,
		Anchored = false,
		Parent = model,
	})
	model.PrimaryPart = root

	local torso = Util.Part({
		Name = "Torso",
		Size = Vector3.new(2.6, 3.4, 1.5),
		CFrame = root.CFrame,
		Color = colour,
		Material = Enum.Material.Fabric,
		Anchored = false,
		Parent = model,
	})
	Util.Weld(root, torso)

	local head = Util.Part({
		Name = "Head",
		Size = Vector3.new(1.7, 1.7, 1.7),
		CFrame = torso.CFrame * CFrame.new(0, 2.6, 0),
		Color = Color3.fromRGB(226, 192, 150),
		Material = Enum.Material.SmoothPlastic,
		Anchored = false,
		Parent = model,
	})
	Util.Weld(torso, head)

	--[[
		A number on the back, for the ones that have one.

		Only the goalie does. A squad of identically named CPUs with numbers
		would be a wall of noise; one numbered player among them reads as
		somebody specific, which is the entire point of giving him a number.
	]]
	if jersey then
		local plate = Instance.new("BillboardGui")
		plate.Name = "Jersey"
		plate.Size = UDim2.fromOffset(60, 60)
		plate.StudsOffsetWorldSpace = Vector3.new(0, 0.2, 0.9)
		plate.AlwaysOnTop = false
		plate.MaxDistance = 120
		plate.Parent = torso

		local number = Instance.new("TextLabel")
		number.Size = UDim2.fromScale(1, 1)
		number.BackgroundTransparency = 1
		number.Font = Enum.Font.GothamBlack
		number.TextScaled = true
		number.Text = tostring(jersey)
		number.TextColor3 = Color3.fromRGB(255, 255, 255)
		number.TextStrokeTransparency = 0.2
		number.Parent = plate
	end

	for _, side in { -1, 1 } do
		local arm = Util.Part({
			Name = "Arm",
			Size = Vector3.new(0.9, 3.2, 0.9),
			CFrame = torso.CFrame * CFrame.new(side * 1.75, 0, 0),
			Color = Color3.fromRGB(226, 192, 150),
			Material = Enum.Material.SmoothPlastic,
			Anchored = false,
			Parent = model,
		})
		Util.Weld(torso, arm)

		local leg = Util.Part({
			Name = "Leg",
			Size = Vector3.new(1, 3, 1),
			CFrame = torso.CFrame * CFrame.new(side * 0.7, -3.2, 0),
			Color = Color3.fromRGB(60, 72, 110),
			Material = Enum.Material.Fabric,
			Anchored = false,
			Parent = model,
		})
		Util.Weld(torso, leg)
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.WalkSpeed = Config.Bots.WalkSpeed
	humanoid.MaxHealth = Config.Bots.Health
	humanoid.Health = Config.Bots.Health
	humanoid.Parent = model

	-- A name tag, in team colour, so you can tell friend from foe at a
	-- glance and tell a bot from a player at all.
	local tag = Instance.new("BillboardGui")
	tag.Name = "BotTag"
	tag.Size = UDim2.fromOffset(190, 22)
	tag.StudsOffset = Vector3.new(0, 3.4, 0)
	tag.MaxDistance = 220
	tag.Adornee = head
	tag.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = name
	label.TextColor3 = colour
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = tag

	model.Parent = workspace
	return model, humanoid, root
end

--[[ Put a bot on the field. ]]
function BotService.Spawn(
	venue: string,
	team: number,
	role: string,
	position: Vector3,
	named: string?,
	jersey: number?
): Bot
	-- A named bot keeps its name; everyone else gets the next off the list.
	local name = named or botName()
	local model, humanoid, root = buildBody(name, team, position, jersey)

	model:SetAttribute("Bot", true)
	model:SetAttribute("BotTeam", team)

	local bot: Bot = {
		model = model,
		humanoid = humanoid,
		root = root,
		name = name,
		team = team,
		venue = venue,
		role = role,
		home = if role == "goalie" then position + Vector3.new(0, 3, 0) else nil,
		nextWanderAt = 0,
		health = Config.Bots.Health,
		maxHealth = Config.Bots.Health,
		dead = false,
		goal = nil,
		nextShotAt = 0,
		homeAt = position,
	}
	table.insert(bots, bot)
	return bot
end

--[[ Every bot still standing in a given venue. ]]
function BotService.InVenue(venue: string): { Bot }
	local out: { Bot } = {}
	for _, bot in bots do
		if bot.venue == venue and not bot.dead then
			table.insert(out, bot)
		end
	end
	return out
end

function BotService.Count(): number
	local total = 0
	for _, bot in bots do
		if not bot.dead then
			total += 1
		end
	end
	return total
end

--[[ Clear out a venue's bots, or all of them. ]]
function BotService.Clear(venue: string?)
	for index = #bots, 1, -1 do
		local bot = bots[index]
		if venue == nil or bot.venue == venue then
			if bot.model.Parent then
				bot.model:Destroy()
			end
			table.remove(bots, index)
		end
	end
end

--[[ The bot a part belongs to, if any. ]]
local function botFromPart(part: BasePart): Bot?
	local model = part:FindFirstAncestorOfClass("Model")
	if not model then
		return nil
	end
	for _, bot in bots do
		if bot.model == model then
			return bot
		end
	end
	return nil
end

--[[
	A shot hit a bot.

	Routed the same way the zombies and the fairground props are, because a
	bot is not a Player and so every normal damage path misses it.
]]
function BotService.RegisterHit(part: BasePart, damage: number, attacker: Player?): boolean
	local bot = botFromPart(part)
	if not bot or bot.dead then
		return false
	end

	-- Headshots count on bots too, or sniping them would feel wrong.
	local hit = if part.Name == "Head" then damage * Config.Movement.HeadshotMultiplier else damage
	bot.health -= hit
	bot.humanoid.Health = math.max(0, bot.health)
	Sound.At("Hitmarker", part.Position, 0.6)

	if bot.health > 0 then
		return true
	end

	bot.dead = true
	bot.humanoid.Health = 0

	if attacker then
		PlayerState.AwardPoints(attacker, Config.Bots.Points, "bot down")
	end
	BotService.Killed.Fire(bot, attacker)

	-- Gone after a moment, then back where it started, so a venue stays
	-- populated for whoever is still playing.
	local model = bot.model
	Lifetime.Delay(Config.Bots.RespawnDelay, function()
		if model.Parent then
			model:Destroy()
		end
		-- Only bring it back if its venue is still running.
		local stillWanted = false
		for _, other in bots do
			if other == bot then
				stillWanted = true
				break
			end
		end
		if not stillWanted then
			return
		end

		local fresh, humanoid, root = buildBody(bot.name, bot.team, bot.homeAt)
		fresh:SetAttribute("Bot", true)
		fresh:SetAttribute("BotTeam", bot.team)
		bot.model = fresh
		bot.humanoid = humanoid
		bot.root = root
		bot.health = bot.maxHealth
		bot.dead = false
	end)

	return true
end

--[[ Is this part a bot? Used by the aim assist, which must not lock onto one
     of your own side. ]]
function BotService.TeamOf(part: BasePart): number?
	local bot = botFromPart(part)
	return if bot then bot.team else nil
end

-- =================================================================== BRAINS ==

--[[
	Where the puck is, if there is one.

	Set by HockeyService each time the puck moves, rather than BotService
	reaching into the rink. A goalie needs exactly one fact about hockey and
	this is it: anything more and this module would have to know what a
	face-off is.
]]
BotService.PuckPosition = nil :: Vector3?
--[[
	And how fast it is going.

	A goalie who tracks where the puck IS is unbeatable except by raw speed:
	he is always already there. Playing slightly ahead of it is what makes a
	change of direction work against him, and that needs the velocity, not
	just the position.
]]
BotService.PuckVelocity = nil :: Vector3?

--[[
	Walk somewhere, using the Humanoid's own pathing.

	MoveTo rather than setting a velocity: it steps up kerbs, round walls and
	up the stairs for free, and it looks like walking because it is.
]]
function BotService.WalkTo(bot: Bot, goal: Vector3)
	bot.goal = goal
	if not bot.dead and bot.humanoid.Parent then
		bot.humanoid:MoveTo(goal)
	end
end

--[[
	A handful of wandering targets around a spot.

	Team 0 on purpose: they are nobody's side, so friendly fire never
	refuses a shot at one and the aim assist does not treat them as allies.
	They belong to a pseudo-venue so they can be cleared with everything
	else at the end of a round.
]]
function BotService.SpawnDummies(centre: Vector3, count: number?)
	local wanted = count or Config.Dummies.Count
	for index = 1, wanted do
		local angle = (index / wanted) * math.pi * 2
		local at = centre
			+ Vector3.new(
				math.cos(angle) * Config.Dummies.Radius * 0.6,
				0,
				math.sin(angle) * Config.Dummies.Radius * 0.6
			)
		local bot = BotService.Spawn("dummies", 0, "dummy", at)
		bot.home = centre
	end
end

--[[ The nearest living player not on this bot's team. ]]
function BotService.NearestEnemy(bot: Bot, within: number): (Player?, Vector3?)
	local best: Player? = nil
	local bestPosition: Vector3? = nil
	local bestDistance = within

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
			continue
		end
		-- A bot's team is a number; a player's is a Team object. Compare
		-- through TeamService's index rather than the objects.
		local distance = (root.Position - bot.root.Position).Magnitude
		if distance < bestDistance then
			best, bestPosition, bestDistance = player, root.Position, distance
		end
	end

	return best, bestPosition
end

local lastStep = 0

--[[
	One tick of bot upkeep.

	Deliberately slow -- a few times a second, not sixty. A bot deciding
	where to walk four times a second is indistinguishable from one deciding
	sixty times a second, and twenty bots doing it sixty times a second is
	the sort of thing that quietly eats a server.
]]
local function step()
	local now = os.clock()
	if now - lastStep < Config.Bots.ThinkInterval then
		return
	end
	lastStep = now

	for index = #bots, 1, -1 do
		local bot = bots[index]
		if not bot.model.Parent then
			table.remove(bots, index)
			continue
		end
		if bot.dead then
			continue
		end

		--[[
			A dummy wanders near its post.

			A stationary target teaches you nothing about leading a shot,
			which is the one skill a long scope asks for -- so they drift,
			slowly, and pick a new spot every few seconds.
		]]
		if bot.role == "dummy" then
			local home = bot.home
			if home and now >= (bot.nextWanderAt or 0) then
				bot.nextWanderAt = now + Config.Dummies.WanderSeconds
				local angle = math.random() * math.pi * 2
				local reach = math.random() * Config.Dummies.Radius
				BotService.WalkTo(
					bot,
					home + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)
				)
			end
		end

		--[[
			A goalie does not walk to a goal, he slides along his line.

			Handled before the walking because it is not walking: MoveTo
			would have him leave the crease to meet the puck, which is the
			one thing a goalie must not do. He tracks sideways between his
			posts and stays on his line, so beating him means picking a
			corner rather than waiting for him to wander off.
		]]
		if bot.role == "goalie" then
			-- Tracked every frame in stepGoalies, not here: moving him on
			-- the think interval made him jump across the crease in visible
			-- steps, and a keeper who teleports is worse to watch and worse
			-- to play against than one who slides.
			continue
		end

		-- Keep walking toward whatever the venue last asked for. The venue
		-- brains set the goal; this just makes sure a bot that has stopped
		-- short of it starts again.
		local goal = bot.goal
		if goal then
			local flat = Vector3.new(goal.X - bot.root.Position.X, 0, goal.Z - bot.root.Position.Z)
			if flat.Magnitude > 6 then
				bot.humanoid:MoveTo(goal)
			end
		end
	end
end

--[[
	The goalies, every frame.

	Separate from the thinking loop above, which runs a few times a second
	because a bot deciding where to walk sixty times a second is
	indistinguishable from one deciding four times a second. Tracking a puck
	is not that: at four hertz a keeper jumps across his crease in visible
	steps, and a keeper who teleports is both worse to watch and worse to
	play against than one who slides. There are two of them, so a per-frame
	loop over goalies costs nothing worth measuring.

	He plays slightly AHEAD of the puck rather than on it. Tracking where
	the puck is makes him unbeatable except by raw speed -- he is always
	already there. Leading it is what makes a change of direction work, and
	that is the difference between beating him feeling earned and feeling
	lucky.
]]
local function stepGoalies(deltaTime: number)
	local puck = BotService.PuckPosition
	local drift = BotService.PuckVelocity

	for _, bot in bots do
		if bot.role ~= "goalie" or bot.dead or not bot.model.Parent then
			continue
		end
		local home = bot.home
		if not home then
			continue
		end

		local target = home
		if puck then
			local lead = if drift then drift * Config.Goalie.LeadSeconds else Vector3.zero
			local across = math.clamp(
				(puck.X + lead.X) - home.X,
				-Config.Goalie.SideToSide,
				Config.Goalie.SideToSide
			)
			target = Vector3.new(home.X + across, home.Y, home.Z)
		end

		-- Moved by hand rather than by MoveTo, because the whole point is
		-- that he does not path: MoveTo would have him leave the crease to
		-- meet the puck, which is the one thing a goalie must not do.
		local here = bot.root.Position
		local stride = target - here
		if stride.Magnitude > 0.05 then
			local travel = math.min(stride.Magnitude, Config.Goalie.TrackSpeed * deltaTime)
			bot.root.CFrame = CFrame.new(here + stride.Unit * travel)
		end
	end
end

--[[ The keepers, so the rink can ask whether one is in the way of a shot. ]]
function BotService.Goalies(venue: string?): { Bot }
	local keepers = {}
	for _, bot in bots do
		if bot.role == "goalie" and not bot.dead and bot.model.Parent then
			if venue == nil or bot.venue == venue then
				table.insert(keepers, bot)
			end
		end
	end
	return keepers
end

function BotService.Start()
	RunService.Heartbeat:Connect(step)
	RunService.Heartbeat:Connect(stepGoalies)
end

--[[ One tick, for tests. ]]
--[[ Every bot alive right now, for tests. ]]
function BotService.AllForTests(): { Bot }
	return bots
end

function BotService.StepForTests()
	lastStep = 0
	step()
end

--[[ One frame of goaltending, for tests. ]]
function BotService.StepGoaliesForTests(deltaTime: number?)
	stepGoalies(deltaTime or 1 / 60)
end

return BotService
