--!strict
--[[
	TeamService — Red Mud versus Blue Mud.

	New players join whichever side is smaller, so the game stays roughly even
	without anybody having to think about it.
]]

local Players = game:GetService("Players")
local Teams = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local TeamService = {}

local teams: { Team } = {}

function TeamService.Start()
	for _, spec in Config.Teams do
		local existing = Teams:FindFirstChild(spec.Name)
		local team: Team
		if existing and existing:IsA("Team") then
			team = existing
		else
			team = Instance.new("Team")
			team.Name = spec.Name
			team.Parent = Teams
		end
		team.TeamColor = spec.Color
		team.AutoAssignable = false
		table.insert(teams, team)
	end
end

--[[ Put a player on the emptier side. ]]
function TeamService.Assign(player: Player)
	if #teams == 0 then
		return
	end

	local counts = {}
	for index, team in teams do
		counts[index] = #team:GetPlayers()
	end

	local smallest = 1
	for index = 2, #teams do
		if counts[index] < counts[smallest] then
			smallest = index
		end
	end

	player.Team = teams[smallest]
	player.Neutral = false
end

--[[ Which of the two teams a player is on, as a 1 or a 2. ]]
function TeamService.IndexOf(player: Player): number
	for index, team in teams do
		if player.Team == team then
			return index
		end
	end
	return 1
end

function TeamService.Get(index: number): Team?
	return teams[index]
end

function TeamService.All(): { Team }
	return teams
end

return TeamService
