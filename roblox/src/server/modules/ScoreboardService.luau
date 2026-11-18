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
}

--[[
	Everybody's standing, sorted for display.

	Teams first so the two sides read as two sides, then points within a team,
	because points are what decides the round.
]]
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
		})
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

function ScoreboardService.Start()
	Remotes.Event("RequestScoreboard").OnServerEvent:Connect(function(player: Player)
		-- No rate limit beyond the cost of building it: the panel is held
		-- down by hand, and a player spamming Tab only slows themselves.
		local ok, err = pcall(function()
			ScoreboardService.Send(player)
		end)
		if not ok then
			warn(`[Nuclear Mud Arena] Scoreboard failed for {player.Name}: {err}`)
		end
	end)
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
