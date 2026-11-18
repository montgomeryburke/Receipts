--!strict
--[[
	Nuclear Mud Arena — the sub-games.

	The game is a shooter with sports scattered through it, and the problem
	with scattering sports through a 2000-stud map is that nobody finds them.
	This is the fix, and it works two ways on purpose:

	  1. Press the menu key anywhere and pick a game. You are taken straight
	     there. Nobody should have to walk across a map to find out what is
	     in the corner of it.
	  2. Walk into a venue and it asks whether you want to play. If you say
	     yes you are put on a side and the game starts.

	Either way the roster is filled out with bots up to full teams, so a game
	is never short. Real players take the empty slots first and bots only
	make up the difference -- which is what "computer players play when there
	aren't other online people" has to mean in practice.

	And you keep your guns the whole time. That is the rule.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Signal = require(Shared:WaitForChild("Signal"))
local Sound = require(Shared:WaitForChild("Sound"))

local BotService = require(script.Parent:WaitForChild("BotService"))
local TeamService = require(script.Parent:WaitForChild("TeamService"))

local ArcadeService = {}

--[[ Fired as (player, gameId) when somebody joins a sub-game. ]]
ArcadeService.Joined = Signal.new()

export type VenueInfo = {
	id: string,
	name: string,
	-- One line, shown on screen when you join. This is the whole of the
	-- game's instructions and it has to fit on one line.
	objective: string,
	-- Where the game is played, set when the map is built.
	centre: Vector3,
	-- Where a joining player is put down.
	spawns: { Vector3 },
	-- How many on each side for a full game.
	perTeam: number,
	-- Does it have sides at all? Bowling does not.
	teamed: boolean,
}

local venues: { [string]: VenueInfo } = {}
local order: { string } = {}

-- Who is in which game, and which side they are on.
local membership: { [Player]: { venue: string, team: number } } = {}

-- Which venues have been filled out with bots.
local staffed: { [string]: boolean } = {}

--[[
	Declare a venue.

	Called by whichever service builds the place, so the geometry and the
	game rules stay together and this module never has to know what a rink
	looks like.
]]
function ArcadeService.Register(info: VenueInfo)
	if not venues[info.id] then
		table.insert(order, info.id)
	end
	venues[info.id] = info
end

function ArcadeService.Clear()
	table.clear(venues)
	table.clear(order)
	table.clear(membership)
	table.clear(staffed)
	BotService.Clear(nil)
end

--[[ The list a player sees in the menu. ]]
function ArcadeService.Menu(): { { id: string, name: string, objective: string, players: number } }
	local out = {}
	for _, id in order do
		local info = venues[id]
		if not info then
			continue
		end
		local count = 0
		for _, where in membership do
			if where.venue == id then
				count += 1
			end
		end
		table.insert(out, {
			id = id,
			name = info.name,
			objective = info.objective,
			players = count,
		})
	end
	return out
end

--[[
	How many real players are on each side of a venue right now.
]]
local function humanCount(venueId: string): { [number]: number }
	local counts = { [1] = 0, [2] = 0 }
	for player, where in membership do
		if where.venue == venueId and player.Parent then
			counts[where.team] = (counts[where.team] or 0) + 1
		end
	end
	return counts
end

--[[
	Fill a venue out to full teams with bots.

	Real players first: bots only ever make up the difference, and they are
	topped up again whenever somebody joins or leaves, so a game is always
	full and never over-full.
]]
function ArcadeService.Staff(venueId: string)
	local info = venues[venueId]
	if not info then
		return
	end

	local humans = humanCount(venueId)
	BotService.Clear(venueId)

	if not info.teamed then
		-- A solo game: a couple of others milling about, for company and for
		-- something to shoot at.
		for index = 1, math.max(0, info.perTeam - (humans[1] + humans[2])) do
			local spot = info.spawns[((index - 1) % #info.spawns) + 1]
			BotService.Spawn(venueId, 1, "bystander", spot)
		end
		staffed[venueId] = true
		return
	end

	for team = 1, 2 do
		local wanted = info.perTeam - (humans[team] or 0)
		for index = 1, math.max(0, wanted) do
			-- Spread them along the venue's spawn points rather than
			-- stacking them all on one.
			local base = info.spawns[((index + team) % #info.spawns) + 1]
			local spot = base + Vector3.new(
				(index - 1) * 8 - 12,
				0,
				if team == 1 then -14 else 14
			)
			BotService.Spawn(venueId, team, "player", spot)
		end
	end
	staffed[venueId] = true
end

--[[ Put a player into a game. ]]
function ArcadeService.Join(player: Player, venueId: string): boolean
	local info = venues[venueId]
	if not info then
		return false
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end

	-- The smaller side, so joining never makes a game more lopsided. On an
	-- empty venue this puts you opposite the bots rather than among them.
	local humans = humanCount(venueId)
	local side = if (humans[1] or 0) <= (humans[2] or 0) then 1 else 2
	if not info.teamed then
		side = TeamService.IndexOf(player)
	end

	membership[player] = { venue = venueId, team = side }

	-- Stood on the venue's own spawn rather than wherever you pressed the
	-- key, because the point of the menu is not having to walk.
	local spot = info.spawns[math.random(1, math.max(1, #info.spawns))]
	root.CFrame = CFrame.new(spot + Vector3.new(0, 6, 0))

	ArcadeService.Staff(venueId)

	Remotes.Event("ArcadeJoined"):FireClient(player, {
		id = info.id,
		name = info.name,
		objective = info.objective,
		team = side,
	})
	Remotes.Event("PlaySound"):FireClient(player, "Medal")

	ArcadeService.Joined.Fire(player, venueId)
	return true
end

--[[ Take a player out of whatever game they were in. ]]
function ArcadeService.Leave(player: Player)
	local where = membership[player]
	if not where then
		return
	end
	membership[player] = nil
	-- Re-staff, so the side they left does not play a man down.
	ArcadeService.Staff(where.venue)
	Remotes.Event("ArcadeLeft"):FireClient(player, { id = where.venue })
end

--[[ Which game a player is in, if any. ]]
function ArcadeService.VenueOf(player: Player): string?
	local where = membership[player]
	return if where then where.venue else nil
end

--[[ Which side a player is on inside their sub-game. ]]
function ArcadeService.SideOf(player: Player): number?
	local where = membership[player]
	return if where then where.team else nil
end

--[[
	Offer a game to anybody who wanders into a venue.

	Checked a few times a second rather than with a Touched event on a huge
	invisible part, because a trigger volume the size of a rink fires
	constantly for every bullet, every car and every bot that crosses it.
]]
local lastSweep = 0
local offered: { [Player]: { [string]: number } } = {}

local function sweep()
	local now = os.clock()
	if now - lastSweep < 0.4 then
		return
	end
	lastSweep = now

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
			continue
		end

		local here = root.Position
		local inside: string? = nil
		for _, id in order do
			local info = venues[id]
			if info and (Vector3.new(here.X, 0, here.Z) - Vector3.new(info.centre.X, 0, info.centre.Z)).Magnitude
				< Config.Arcade.OfferRadius
			then
				inside = id
				break
			end
		end

		-- Walked out of everything: drop out of whatever they were in.
		if not inside then
			if membership[player] then
				ArcadeService.Leave(player)
			end
			continue
		end

		-- Already playing this one, nothing to ask.
		if membership[player] and membership[player].venue == inside then
			continue
		end

		-- Ask, but not over and over.
		local seen = offered[player]
		if not seen then
			seen = {}
			offered[player] = seen
		end
		if now - (seen[inside] or 0) < Config.Arcade.ReofferSeconds then
			continue
		end
		seen[inside] = now

		local info = venues[inside]
		if info then
			Remotes.Event("ArcadeOffer"):FireClient(player, {
				id = info.id,
				name = info.name,
				objective = info.objective,
			})
		end
	end
end

function ArcadeService.Start()
	Remotes.Event("RequestArcadeMenu").OnServerEvent:Connect(function(player: Player)
		Remotes.Event("ArcadeMenu"):FireClient(player, { games = ArcadeService.Menu() })
	end)

	Remotes.Event("JoinArcade").OnServerEvent:Connect(function(player: Player, venueId: any)
		if typeof(venueId) ~= "string" then
			return
		end
		ArcadeService.Join(player, venueId)
	end)

	Remotes.Event("LeaveArcade").OnServerEvent:Connect(function(player: Player)
		ArcadeService.Leave(player)
	end)

	RunService.Heartbeat:Connect(sweep)

	Players.PlayerRemoving:Connect(function(player)
		local where = membership[player]
		membership[player] = nil
		offered[player] = nil
		if where then
			ArcadeService.Staff(where.venue)
		end
	end)

	local _ = Sound
end

--[[ Run one offer sweep, for tests. ]]
function ArcadeService.SweepForTests()
	lastSweep = 0
	sweep()
end

return ArcadeService
