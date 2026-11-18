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
	-- Driving fittings, claimed by the vehicle context rather than by
	-- whichever script connected first.
	"CycleDriveMode",
	"ToggleDiffLock",
	"ToggleWinch",
	"ReelWinch",
	-- The shove-and-boost shared by skis, snowboard, tube and bike.
	"ShoveBoost",
	-- A held tool's second action: lighting a poured gas trail, so far.
	"ToolSecondary",
	"SetPedal",
	"Eject",

	-- Server -> Client
	"HudUpdate",
	"PlayEffect",
	"MatchState",
	"VoteOptions",
	"DeathScreen",
	"Notify",
	"Hitmarker",
	"Medal",
	"KillFeed",
	"PlaySound",
	"MountedWeaponState",
	-- The scoreboard is pulled, not pushed: streaming everyone's score to
	-- everyone continuously costs bandwidth all match for a panel that is on
	-- screen a few seconds at a time.
	-- Cosmetic only: the shooter already drew their own shot locally, this
	-- tells everybody nearby what it looked like. Cheaper than replicating
	-- the parts, and far less laggy than drawing them server-side.
	-- The hockey fight scene: the server starts one, the client mashes, the
	-- server says who won.
	-- Hockey: possession, shooting, and the fight.
	"HockeyShoot",
	"HockeyChallenge",
	"HockeyPunch",
	"HockeyBlock",
	"HockeyScore",
	"FightUpdate",
	"FightStarted",
	"FightResult",
	-- The sub-games: the menu, the walk-in offer, and joining or leaving one.
	-- The client tells the server it has scoped, so the server can slow the
	-- player down. Movement speed is the server's to set.
	"SetScoped",
	"RequestArcadeMenu",
	"ArcadeMenu",
	"ArcadeOffer",
	"ArcadeJoined",
	"ArcadeLeft",
	"JoinArcade",
	"LeaveArcade",
	"ShotFired",
	"ThrowGrenade",
	"RequestScoreboard",
	"Scoreboard",
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
