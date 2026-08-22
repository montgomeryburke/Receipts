--!strict
--[[
	FlagService — Capture the Flag.

	One flag per team, on a stand at their end of the map. Touch the enemy's
	to pick it up, carry it back to your own stand, and score.

	Halo's rules, which are what make it a game rather than a footrace:
	  * you cannot score unless your own flag is sitting on its stand
	  * dying drops the flag where you fell
	  * a dropped flag goes home on its own after a while
	  * your own dropped flag goes straight home if you touch it
	  * carrying slows you down, so a runner can be caught
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Signal = require(Shared:WaitForChild("Signal"))
local Util = require(Shared:WaitForChild("Util"))

local DamageService = require(script.Parent:WaitForChild("DamageService"))
local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local TeamService = require(script.Parent:WaitForChild("TeamService"))

local FlagService = {}

type Flag = {
	teamIndex: number,
	model: Model,
	pole: BasePart,
	home: Vector3,
	state: string, -- "Home" | "Carried" | "Dropped"
	carrier: Player?,
	droppedAt: number,
	colour: BrickColor,
}

local flags: { [number]: Flag } = {}
local stands: { [number]: BasePart } = {}
local container: Folder? = nil
local active = false

--[[ Fired as (player, teamIndex, points) when somebody scores. ]]
FlagService.Captured = Signal.new()

-- ================================================================ BUILDING ==

local function buildStand(position: Vector3, colour: BrickColor, parent: Instance): BasePart
	local base = Util.Part({
		Name = "FlagStand",
		Size = Vector3.new(16, 1.5, 16),
		CFrame = CFrame.new(position),
		Color = colour.Color,
		Material = Enum.Material.Neon,
		Parent = parent,
	})

	-- A ring of posts, so the stand reads from a distance.
	for index = 1, 8 do
		local angle = (index / 8) * math.pi * 2
		Util.Part({
			Name = "StandPost",
			Size = Vector3.new(0.8, 6, 0.8),
			CFrame = CFrame.new(position + Vector3.new(math.cos(angle) * 7, 3, math.sin(angle) * 7)),
			Color = colour.Color,
			Material = Enum.Material.Metal,
			Parent = parent,
		})
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(16, 4)
	billboard.StudsOffset = Vector3.new(0, 14, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 2000
	billboard.Parent = base

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "BASE"
	label.TextColor3 = colour.Color
	label.TextStrokeTransparency = 0.2
	label.TextScaled = true
	label.Font = Enum.Font.LuckiestGuy
	label.Parent = billboard

	return base
end

local function buildFlag(teamIndex: number, home: Vector3, colour: BrickColor, parent: Instance): Flag
	local model = Instance.new("Model")
	model.Name = `Flag_{teamIndex}`

	local pole = Util.Part({
		Name = "Pole",
		Size = Vector3.new(0.7, 14, 0.7),
		CFrame = CFrame.new(home + Vector3.new(0, 8, 0)),
		Color = Color3.fromRGB(210, 210, 215),
		Material = Enum.Material.Metal,
		CanCollide = false,
		Parent = model,
	})
	model.PrimaryPart = pole

	local cloth = Util.Part({
		Name = "Cloth",
		Size = Vector3.new(0.3, 5, 8),
		CFrame = pole.CFrame * CFrame.new(0, 4, -4),
		Color = colour.Color,
		Material = Enum.Material.Fabric,
		CanCollide = false,
		Parent = model,
	})
	Util.Weld(pole, cloth)

	local glow = Instance.new("PointLight")
	glow.Color = colour.Color
	glow.Brightness = 3
	glow.Range = 30
	glow.Parent = pole

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(12, 3)
	billboard.StudsOffset = Vector3.new(0, 9, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 3000
	billboard.Parent = pole

	local label = Instance.new("TextLabel")
	label.Name = "FlagLabel"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "FLAG"
	label.TextColor3 = colour.Color
	label.TextStrokeTransparency = 0.2
	label.TextScaled = true
	label.Font = Enum.Font.LuckiestGuy
	label.Parent = billboard

	model.Parent = parent

	return {
		teamIndex = teamIndex,
		model = model,
		pole = pole,
		home = home,
		state = "Home",
		carrier = nil,
		droppedAt = 0,
		colour = colour,
	}
end

-- ================================================================== HELPERS ==

local function announce(message: string)
	for _, player in Players:GetPlayers() do
		Remotes.Event("Notify"):FireClient(player, message)
	end
end

local function setLabel(flag: Flag, text: string)
	local label = flag.pole:FindFirstChild("BillboardGui")
	if not label then
		for _, child in flag.pole:GetChildren() do
			if child:IsA("BillboardGui") then
				label = child
				break
			end
		end
	end
	if label then
		local text_ = label:FindFirstChild("FlagLabel")
		if text_ and text_:IsA("TextLabel") then
			text_.Text = text
		end
	end
end

--[[ Put a flag back on its stand. ]]
local function sendHome(flag: Flag, quiet: boolean?)
	flag.state = "Home"
	flag.carrier = nil
	flag.model:PivotTo(CFrame.new(flag.home + Vector3.new(0, 8, 0)))
	setLabel(flag, "FLAG")
	if not quiet then
		local team = TeamService.Get(flag.teamIndex)
		announce(`{if team then team.Name else "A"} flag returned.`)
	end
end

--[[ Drop it where the carrier fell. ]]
local function drop(flag: Flag, position: Vector3)
	flag.state = "Dropped"
	flag.carrier = nil
	flag.droppedAt = os.clock()
	flag.model:PivotTo(CFrame.new(position + Vector3.new(0, 6, 0)))
	setLabel(flag, "DROPPED")

	local team = TeamService.Get(flag.teamIndex)
	announce(`{if team then team.Name else "A"} flag dropped!`)
end

--[[ Slow the carrier down, or put them back to normal. ]]
local function setCarrierSpeed(player: Player, carrying: boolean)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	humanoid.WalkSpeed = if carrying
		then Config.Turbo.WalkSpeed * Config.CTF.CarrierSpeedFactor
		else Config.Turbo.WalkSpeed
end

local function pickUp(flag: Flag, player: Player)
	flag.state = "Carried"
	flag.carrier = player
	setLabel(flag, "TAKEN")
	setCarrierSpeed(player, true)

	PlayerState.AwardPoints(player, Config.CTF.FlagTakenPoints)
	local team = TeamService.Get(flag.teamIndex)
	announce(`{player.DisplayName} has the {if team then team.Name else ""} flag!`)
end

--[[ Somebody made it home with the other team's flag. ]]
local function capture(flag: Flag, player: Player, scorerIndex: number)
	local earned = PlayerState.AwardPoints(player, Config.CTF.CapturePoints)
	FlagService.Captured.Fire(player, scorerIndex, earned)

	announce(`{player.DisplayName} CAPTURED THE FLAG! +{earned}`)
	setCarrierSpeed(player, false)
	sendHome(flag, true)
end

-- ================================================================== TOUCHING ==

--[[
	Work out what touching a flag means for this player.

	Their own flag: if it is lying on the ground, they send it home. If it is
	on its stand and they are carrying the enemy's, that is a capture.
	The enemy's flag: they pick it up.
]]
local function onFlagTouched(flag: Flag, player: Player)
	if not active then
		return
	end

	local playerTeam = TeamService.IndexOf(player)

	if flag.teamIndex == playerTeam then
		if flag.state == "Dropped" then
			PlayerState.AwardPoints(player, Config.CTF.FlagReturnPoints)
			sendHome(flag)
		end
		return
	end

	-- The enemy's flag.
	if flag.state == "Home" or flag.state == "Dropped" then
		pickUp(flag, player)
	end
end

--[[ Reaching your own stand while carrying theirs. ]]
local function onStandTouched(teamIndex: number, player: Player)
	if not active then
		return
	end
	if TeamService.IndexOf(player) ~= teamIndex then
		return
	end

	-- Are they carrying anything?
	local carried: Flag? = nil
	for _, flag in flags do
		if flag.carrier == player then
			carried = flag
		end
	end
	if not carried then
		return
	end

	-- Halo's rule: your own flag has to be home for a capture to count.
	local ownFlag = flags[teamIndex]
	if Config.CTF.RequireOwnFlagHome and ownFlag and ownFlag.state ~= "Home" then
		Remotes.Event("Notify"):FireClient(player, "Your own flag is not home — you cannot score yet!")
		return
	end

	capture(carried, player, teamIndex)
end

local function bindTouch(part: BasePart, handler: (Player) -> ())
	part.Touched:Connect(function(hit)
		local character = hit:FindFirstAncestorOfClass("Model")
		if not character then
			return
		end
		local player = Players:GetPlayerFromCharacter(character)
		if player then
			handler(player)
		end
	end)
end

-- =================================================================== PUBLIC ==

--[[ Build the flags and stands for a Capture the Flag round. ]]
function FlagService.Setup(build: any, teamColours: { BrickColor })
	FlagService.Clear()

	local folder = Instance.new("Folder")
	folder.Name = "CaptureTheFlag"
	folder.Parent = workspace
	container = folder

	for teamIndex = 1, 2 do
		local spawns = build.teamSpawns[teamIndex]
		if not spawns or #spawns == 0 then
			continue
		end

		-- Behind the middle of that team's spawn line.
		local middle = spawns[math.max(1, math.floor(#spawns / 2))]
		local home = Vector3.new(middle.X, 1, middle.Z * 1.04)
		local colour = teamColours[teamIndex] or BrickColor.new("Medium stone grey")

		local stand = buildStand(home, colour, folder)
		stands[teamIndex] = stand
		bindTouch(stand, function(player)
			onStandTouched(teamIndex, player)
		end)

		local flag = buildFlag(teamIndex, home, colour, folder)
		flags[teamIndex] = flag
		bindTouch(flag.pole, function(player)
			onFlagTouched(flag, player)
		end)
	end

	active = true
end

function FlagService.Clear()
	active = false
	if container then
		container:Destroy()
		container = nil
	end
	table.clear(flags)
	table.clear(stands)
end

--[[ Is a Capture the Flag round running? ]]
function FlagService.IsActive(): boolean
	return active
end

--[[ Flag state for the scoreboard: "Home", "Carried" or "Dropped". ]]
function FlagService.StateOf(teamIndex: number): string
	local flag = flags[teamIndex]
	return if flag then flag.state else "None"
end

--[[ Carried flags follow their carrier; dropped ones eventually go home. ]]
local function step()
	if not active then
		return
	end
	local now = os.clock()

	for _, flag in flags do
		if flag.state == "Carried" then
			local carrier = flag.carrier
			local character = carrier and carrier.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				-- Held up and slightly behind, so it is obvious who has it.
				flag.model:PivotTo(root.CFrame * CFrame.new(0, 6, 1.6))
			else
				-- Carrier vanished without dying properly.
				sendHome(flag)
			end
		elseif flag.state == "Dropped" then
			if now - flag.droppedAt >= Config.CTF.DroppedReturnDelay then
				sendHome(flag)
			end
		end
	end
end

function FlagService.Start()
	-- Dying drops whatever you were carrying, right where you fell.
	DamageService.Killed.Connect(function(victim: Player, _killer: Player?, _cause: string)
		for _, flag in flags do
			if flag.carrier == victim then
				local character = victim.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local where = if root and root:IsA("BasePart") then root.Position else flag.home
				setCarrierSpeed(victim, false)
				drop(flag, where)
			end
		end
	end)

	RunService.Heartbeat:Connect(step)
end

return FlagService
