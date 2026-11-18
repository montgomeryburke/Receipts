--!strict
--[[
	TeamService — Red Mud versus Blue Mud.

	New players join whichever side is smaller, so the game stays roughly even
	without anybody having to think about it.
]]

local Teams = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local TeamService = {}

local teams: { Team } = {}
local nextTieIndex = 1

function TeamService.Start()
	table.clear(teams)
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

--[[ Put a player on the emptier side, alternating on ties. ]]
function TeamService.Assign(player: Player)
	if #teams == 0 then
		return
	end

	local counts = {}
	local minCount = math.huge
	for index, team in teams do
		local count = #team:GetPlayers()
		counts[index] = count
		if count < minCount then
			minCount = count
		end
	end

	local tied: { number } = {}
	for index, count in counts do
		if count == minCount then
			table.insert(tied, index)
		end
	end

	local chosen = tied[((nextTieIndex - 1) % #tied) + 1]
	nextTieIndex += 1

	player.Team = teams[chosen]
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
