--!strict
--[[
	MedalService — one place that decides a moment was worth announcing.

	Medals were already being fired for multikills and sprees, straight out
	of MatchService, which was fine while those were the only two. The moment
	a hockey knockout, a headshot and a chain reaction all want one, the
	question "what does a medal look like" needs a single answer -- otherwise
	each system invents its own wording, its own noise, and its own idea of
	whether a medal is worth points.

	Two rules the catalogue in Config encodes:

	- A medal marks something you DID, not something that happened to you.
	  There is no medal for taking damage, dying well or surviving. Those are
	  not achievements, they are weather.

	- A medal that cannot be earned is worse than a missing one, because it
	  sends players hunting for something that is not there. So the catalogue
	  only lists moments that exist in the game today; Strike arrives with
	  the bowling lanes.

	Points go through PlayerState.AwardPoints like everything else, so a
	medal moves the team score and appears in the end-of-round breakdown
	under its own name rather than being a separate kind of number.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))

local MedalService = {}

-- What each player has been given, so a medal cannot be spammed by a
-- repeating condition. Keyed by player then medal id.
local lastAwardedAt: { [Player]: { [string]: number } } = {}

-- The shortest gap between two of the same medal for the same player. A
-- chain reaction that sets off six cans is one chain reaction, not six.
local REPEAT_GUARD = 1.5

--[[
	Hand out a medal.

	Returns false if it was swallowed, which is the normal case for a
	condition that fires several times for one event -- a shotgun landing
	four pellets on a head is one headshot.
]]
function MedalService.Award(player: Player?, id: string): boolean
	if not player or not player.Parent then
		return false
	end

	local spec = Config.Medals[id]
	if not spec then
		-- A typo in a medal name should not take down whatever was
		-- happening, but it should be loud: an unawarded medal is invisible
		-- otherwise, and this is exactly the sort of thing that goes
		-- unnoticed for a very long time.
		warn(`MedalService: no such medal "{id}"`)
		return false
	end

	local now = os.clock()
	local mine = lastAwardedAt[player]
	if not mine then
		mine = {}
		lastAwardedAt[player] = mine
	end
	if now - (mine[id] or -math.huge) < REPEAT_GUARD then
		return false
	end
	mine[id] = now

	-- Through the one scoring path, so a medal moves the team score and
	-- shows up in the round breakdown under its own name.
	if spec.points > 0 then
		PlayerState.AwardPoints(player, spec.points, string.lower(spec.name))
	end

	Remotes.Event("Medal"):FireClient(player, spec.name)
	Remotes.Event("PlaySound"):FireClient(player, spec.sound)
	return true
end

--[[
	A medal everybody hears about, for the ones that are a spectacle.

	Used for the big ones -- a chain reaction is worth the whole server
	knowing, a headshot is not.
]]
function MedalService.Broadcast(player: Player?, id: string): boolean
	if not MedalService.Award(player, id) then
		return false
	end
	local spec = Config.Medals[id]
	if not spec or not player then
		return false
	end
	for _, other in Players:GetPlayers() do
		if other ~= player then
			Remotes.Event("KillFeed"):FireAllClients(
				`{player.DisplayName}: {spec.name}`,
				false
			)
			break
		end
	end
	return true
end

function MedalService.Start()
	Players.PlayerRemoving:Connect(function(player)
		lastAwardedAt[player] = nil
	end)
end

--[[ For tests. ]]
function MedalService.ResetForTests()
	table.clear(lastAwardedAt)
end

return MedalService
