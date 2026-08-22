--!strict
--[[
	Remotes — the phone lines between the player's computer and the server.

	The server creates them, the client waits for them. Nothing else in the
	game has to think about it: just `Remotes.Get("FireWeapon")`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--[[ Client asks the server to do something. ]]
local EVENT_NAMES = {
	-- Client -> Server
	"FireWeapon",
	"MegaDetonate",
	"EquipWeapon",
	"Reload",
	"RequestVehicle",
	"CastVote",
	"SetAimDirection",
	"SetTurbo",
	"Melee",
	"SetPedal",

	-- Server -> Client
	"HudUpdate",
	"PlayEffect",
	"MatchState",
	"VoteOptions",
	"DeathScreen",
	"Notify",
	"MountedWeaponState",
}

local FUNCTION_NAMES = {
	"GetArsenal",
	"GetPlayerState",
}

local Remotes = {}

local folder: Folder

if RunService:IsServer() then
	local existing = ReplicatedStorage:FindFirstChild("Remotes")
	if existing and existing:IsA("Folder") then
		folder = existing
	else
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end

	for _, name in EVENT_NAMES do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end

	for _, name in FUNCTION_NAMES do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteFunction")
			remote.Name = name
			remote.Parent = folder
		end
	end
else
	folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

--[[ Grab a RemoteEvent by name. Yields on the client until it exists. ]]
function Remotes.Event(name: string): RemoteEvent
	-- No timeout on the client: waiting a moment longer for a remote to
	-- replicate is always better than throwing, because a throw here takes
	-- out whatever was setting up the controls.
	local remote = if RunService:IsServer()
		then folder:FindFirstChild(name)
		else folder:WaitForChild(name)
	assert(remote and remote:IsA("RemoteEvent"), `Remotes: no RemoteEvent named "{name}"`)
	return remote
end

--[[ Grab a RemoteFunction by name. ]]
function Remotes.Function(name: string): RemoteFunction
	local remote = if RunService:IsServer()
		then folder:FindFirstChild(name)
		else folder:WaitForChild(name)
	assert(remote and remote:IsA("RemoteFunction"), `Remotes: no RemoteFunction named "{name}"`)
	return remote
end

return Remotes
