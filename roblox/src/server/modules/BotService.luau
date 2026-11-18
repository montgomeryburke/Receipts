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
local function buildBody(name: string, team: number, position: Vector3): (Model, Humanoid, BasePart)
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
function BotService.Spawn(venue: string, team: number, role: string, position: Vector3): Bot
	local name = botName()
	local model, humanoid, root = buildBody(name, team, position)

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
		PlayerState.AwardPoints(attacker, Config.Bots.Points)
	end
	BotService.Killed.Fire(bot, attacker)

	-- Gone after a moment, then back where it started, so a venue stays
	-- populated for whoever is still playing.
	local model = bot.model
	task.delay(Config.Bots.RespawnDelay, function()
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

function BotService.Start()
	RunService.Heartbeat:Connect(step)
end

--[[ One tick, for tests. ]]
function BotService.StepForTests()
	lastStep = 0
	step()
end

return BotService
