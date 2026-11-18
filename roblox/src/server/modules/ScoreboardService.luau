--!strict
--[[
	Nuclear Mud Arena — the scoreboard.

	In a game scored by points rather than kills there is no way to tell
	whether you are winning without one of these. It answers a request rather
	than broadcasting: the panel is on screen a few seconds at a time, and
	streaming every player's score to every player for a whole match is
	bandwidth spent on a window nobody is looking at.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local TeamService = require(script.Parent:WaitForChild("TeamService"))

local ScoreboardService = {}

type Row = {
	name: string,
	team: string?,
	teamColor: Color3?,
	teamIndex: number,
	points: number,
	kills: number,
	deaths: number,
	isYou: boolean?,
	-- Top scorer in the server, either side. Exactly one row, or none.
	isMvp: boolean?,
	-- The activity they scored most of it doing.
	bestAt: string?,
}

--[[
	Everybody's standing, sorted for display.

	Teams first so the two sides read as two sides, then points within a team,
	because points are what decides the round.
]]
--[[
	What this player scored most of their points doing.

	Returned as the activity's own wording -- "hockey goal", "won the
	fight", a trick name -- because that is the interesting half of a score.
	A round won at the carnival and a round won by shooting people produce
	the same number and are not the same round.
]]
function ScoreboardService.BestAt(player: Player): string?
	local state = PlayerState.Get(player)
	local bestReason: string? = nil
	local bestPoints = 0
	for reason, points in state.scoredBy do
		-- Ties break on the name so the answer is stable between openings
		-- rather than following table order.
		if points > bestPoints or (points == bestPoints and bestReason and reason < bestReason) then
			bestPoints = points
			bestReason = reason
		end
	end
	return bestReason
end

function ScoreboardService.Build(viewer: Player?): { Row }
	local rows: { Row } = {}

	for _, player in Players:GetPlayers() do
		local state = PlayerState.Get(player)
		local team = player.Team
		table.insert(rows, {
			name = player.DisplayName,
			team = if team then team.Name else nil,
			teamColor = if team then team.TeamColor.Color else nil,
			teamIndex = TeamService.IndexOf(player),
			points = state.points,
			kills = state.kills,
			deaths = state.deaths,
			isYou = player == viewer,
			isMvp = false,
			bestAt = ScoreboardService.BestAt(player),
		})
	end

	--[[
		The MVP: most points in the server, either side.

		Marked on the row rather than announced separately so the panel and
		the end-of-round shout cannot disagree about who it was. Nobody is
		MVP on zero -- at the start of a round that would crown whoever
		happens to sort first, which is worse than crowning nobody.
	]]
	local best: Row? = nil
	for _, row in rows do
		if row.points > 0 and (best == nil or row.points > best.points) then
			best = row
		end
	end
	if best then
		best.isMvp = true
	end

	table.sort(rows, function(a, b)
		if a.teamIndex ~= b.teamIndex then
			return a.teamIndex < b.teamIndex
		end
		if a.points ~= b.points then
			return a.points > b.points
		end
		-- A stable tie-break, so rows do not jump around between openings.
		return a.name < b.name
	end)

	return rows
end

--[[ A one-line summary for the panel's heading. ]]
function ScoreboardService.Heading(rows: { Row }): string
	local totals = {}
	for _, row in rows do
		local key = row.team or "Unteamed"
		totals[key] = (totals[key] or 0) + row.points
	end

	local parts = {}
	for name, points in totals do
		table.insert(parts, `{string.upper(name)} {points}`)
	end
	table.sort(parts)

	if #parts == 0 then
		return "SCOREBOARD"
	end
	return table.concat(parts, "   ·   ")
end

function ScoreboardService.Send(player: Player)
	local rows = ScoreboardService.Build(player)
	Remotes.Event("Scoreboard"):FireClient(player, {
		rows = rows,
		heading = ScoreboardService.Heading(rows),
	})
end

--[[
	When each player may next ask for a scoreboard.

	The first version of this had a comment claiming a player spamming the
	request "only slows themselves". That was wrong: the work happens on the
	SERVER, and it is a full walk of the player list, a sort and a table
	serialised per event. A loop firing the remote every frame is twenty
	players' worth of lag caused by one of them.

	Twice a second is far more often than a human opens a panel, and the
	client only asks when the key goes down anyway.
]]
local nextAllowedAt: { [Player]: number } = {}
local MIN_INTERVAL = 0.5

function ScoreboardService.Start()
	Remotes.Event("RequestScoreboard").OnServerEvent:Connect(function(player: Player)
		local now = os.clock()
		if now < (nextAllowedAt[player] or 0) then
			return
		end
		nextAllowedAt[player] = now + MIN_INTERVAL

		local ok, err = pcall(function()
			ScoreboardService.Send(player)
		end)
		if not ok then
			warn(`[Nuclear Mud Arena] Scoreboard failed for {player.Name}: {err}`)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		nextAllowedAt[player] = nil
	end)
end

--[[
	Who was the best, and at what.

	Read from the same Build the panel uses, so the shout at the whistle and
	the row with the marker on it can never name different people.
]]
function ScoreboardService.Mvp(): (string?, number, string?)
	for _, row in ScoreboardService.Build(nil) do
		if row.isMvp then
			return row.name, row.points, row.bestAt
		end
	end
	return nil, 0, nil
end

--[[ Send it to everyone, unasked. Used at the end of a round. ]]
function ScoreboardService.PushAll()
	for _, player in Players:GetPlayers() do
		pcall(function()
			ScoreboardService.Send(player)
		end)
	end
end

return ScoreboardService
