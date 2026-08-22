--!strict
--[[
	Controls — mouse, keyboard and touch.

	Nothing here decides what happens; it only decides what to *ask* for. Every
	shot is a request the server checks, which is what stops somebody editing
	their own copy of the game and giving themselves infinite damage.

	  Left mouse   fire (hold, for automatic guns)
	  Right mouse  zoom, on guns that have a scope
	  R            reload
	  F            MEGA-DETONATE a diamond bullet that is still in the air
	  1 – 6        weapon slots; press again to cycle within a slot
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Util = require(Shared:WaitForChild("Util"))

local Hud = require(script.Parent:WaitForChild("Hud"))

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local Controls = {}

type ArsenalEntry = {
	Slot: number,
	Category: string,
	DisplayName: string,
	MagSize: number,
	Automatic: boolean,
	ZoomFov: number?,
	AutoAim: boolean,
	CanMegaDetonate: boolean,
	MountedOnly: boolean,
}

local arsenal: { [string]: ArsenalEntry } = {}
local slotOrder: { [number]: { string } } = {}
local equipped = ""
local firing = false
local zoomed = false
local defaultFov = 70
local nextLocalFire = 0
local lockedTarget: BasePart? = nil

--[[
	The gun that is actually in play right now.

	Sitting behind a turret, or flying a plane, replaces whatever you were
	carrying — so hold-to-fire and auto-aim have to follow the mounted gun's
	rules, not your pistol's.
]]
local function effectiveWeaponName(): string
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not seat then
		return equipped
	end

	local vehicle = seat:FindFirstAncestorOfClass("Model")
	if not vehicle then
		return equipped
	end

	local mounted = vehicle:GetAttribute("MountedWeapon")
	if typeof(mounted) ~= "string" or not arsenal[mounted] then
		return equipped
	end

	local isGunner = seat.Name == "GunnerSeat"
	local isPilot = seat.Name == "DriverSeat" and vehicle:GetAttribute("VehicleKind") == "Plane"
	if isGunner or isPilot then
		return mounted
	end
	return equipped
end

-- ============================================================ TARGET FINDING ==

--[[ Where this player's shots physically leave from. ]]
local function shotOrigin(): Vector3?
	local character = player.Character
	if not character then
		return nil
	end

	-- In a gunner seat the shot comes out of the vehicle's barrel.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.SeatPart then
		local vehicle = humanoid.SeatPart:FindFirstAncestorOfClass("Model")
		if vehicle then
			local barrel = vehicle:FindFirstChild("Barrel", true)
			if barrel and barrel:IsA("BasePart") then
				local muzzle = barrel:FindFirstChild("Muzzle")
				if muzzle and muzzle:IsA("Attachment") then
					return muzzle.WorldPosition
				end
				return barrel.Position
			end
		end
	end

	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position
	end
	return nil
end

--[[
	Auto-aim.

	Finds the enemy closest to the middle of your screen, as long as they are
	inside the cone and close enough. It nudges your aim onto them — it does
	not shoot for you, and it will never pick a team-mate.
]]
local function findAutoAimTarget(origin: Vector3, aimDirection: Vector3): BasePart?
	local best: BasePart? = nil
	local bestAngle = Config.Combat.AutoAimConeDegrees

	for _, other in Players:GetPlayers() do
		if other == player then
			continue
		end
		-- Never lock onto your own side.
		if other.Team and player.Team and other.Team == player.Team then
			continue
		end

		local character = other.Character
		if not character then
			continue
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			continue
		end
		local torso = character:FindFirstChild("HumanoidRootPart")
		if not torso or not torso:IsA("BasePart") then
			continue
		end

		local toTarget = torso.Position - origin
		if toTarget.Magnitude > Config.Combat.AutoAimRange then
			continue
		end

		local angle = Util.AngleBetween(aimDirection, toTarget)
		if angle < bestAngle then
			-- Only lock on if we can actually see them.
			local params = Util.RayParams({ player.Character :: Instance, character })
			local blocked = workspace:Raycast(origin, toTarget, params)
			if not blocked then
				best = torso
				bestAngle = angle
			end
		end
	end

	return best
end

--[[ The direction to actually send to the server this frame. ]]
local function currentAimDirection(): (Vector3?, Vector3?)
	local origin = shotOrigin()
	if not origin then
		return nil, nil
	end

	local rawDirection = camera.CFrame.LookVector
	local spec = arsenal[effectiveWeaponName()]

	if spec and spec.AutoAim then
		local target = findAutoAimTarget(origin, rawDirection)
		lockedTarget = target
		if target then
			return origin, (target.Position - origin).Unit
		end
	else
		lockedTarget = nil
	end

	return origin, rawDirection
end

-- ==================================================================== FIRING ==

local function tryFire()
	local spec = arsenal[effectiveWeaponName()]
	if not spec then
		return
	end

	local now = os.clock()
	if now < nextLocalFire then
		return
	end
	-- A local cooldown only stops us spamming the network; the server keeps
	-- its own, and the server's is the one that counts.
	nextLocalFire = now + 0.03

	local _origin, direction = currentAimDirection()
	if not direction then
		return
	end

	Remotes.Event("FireWeapon"):FireServer(direction)
end

-- ==================================================================== ZOOMING ==

local function setZoom(on: boolean)
	local spec = arsenal[effectiveWeaponName()]
	local fov = spec and spec.ZoomFov

	if on and fov then
		zoomed = true
		TweenService:Create(camera, TweenInfo.new(0.15), { FieldOfView = fov }):Play()
	elseif zoomed then
		zoomed = false
		TweenService:Create(camera, TweenInfo.new(0.15), { FieldOfView = defaultFov }):Play()
	end
end

-- ================================================================== EQUIPPING ==

--[[ Group the arsenal by slot so number keys can cycle through each group. ]]
local function buildSlotOrder()
	slotOrder = {}
	local names = {}
	for name in arsenal do
		table.insert(names, name)
	end
	-- Sorted so the cycle order is the same every time you play.
	table.sort(names)

	for _, name in names do
		-- Turret and wing guns come with the vehicle, not the wheel.
		if arsenal[name].MountedOnly then
			continue
		end
		local slot = arsenal[name].Slot
		if not slotOrder[slot] then
			slotOrder[slot] = {}
		end
		table.insert(slotOrder[slot], name)
	end
end

local function equip(name: string)
	if not arsenal[name] or arsenal[name].MountedOnly then
		return
	end
	equipped = name
	setZoom(false)
	Remotes.Event("EquipWeapon"):FireServer(name)
	Hud.Toast(arsenal[name].DisplayName)
end

--[[ Press 2 once for the rifle, again for the SMG, again for the minigun. ]]
local function selectSlot(slot: number)
	local names = slotOrder[slot]
	if not names or #names == 0 then
		return
	end

	local currentIndex = table.find(names, equipped)
	local nextIndex = if currentIndex then (currentIndex % #names) + 1 else 1
	equip(names[nextIndex])
end

-- ===================================================================== INPUT ==

local function onInputBegan(input: InputObject, processed: boolean)
	if processed then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	then
		firing = true
		tryFire()
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		setZoom(true)
		return
	end

	if input.KeyCode == Enum.KeyCode.R then
		Remotes.Event("Reload"):FireServer()
	elseif input.KeyCode == Enum.KeyCode.F then
		-- The big one.
		Remotes.Event("MegaDetonate"):FireServer()
	elseif input.KeyCode == Enum.KeyCode.One then
		selectSlot(1)
	elseif input.KeyCode == Enum.KeyCode.Two then
		selectSlot(2)
	elseif input.KeyCode == Enum.KeyCode.Three then
		selectSlot(3)
	elseif input.KeyCode == Enum.KeyCode.Four then
		selectSlot(4)
	elseif input.KeyCode == Enum.KeyCode.Five then
		selectSlot(5)
	elseif input.KeyCode == Enum.KeyCode.Six then
		selectSlot(6)
	end
end

local function onInputEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	then
		firing = false
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		setZoom(false)
	end
end

--[[ Held triggers keep firing, and the turret keeps following your eyes. ]]
local function onHeartbeat()
	local spec = arsenal[effectiveWeaponName()]

	if firing and spec and spec.Automatic then
		tryFire()
	end

	Hud.SetLocked(lockedTarget ~= nil)

	-- If we are working a mounted gun, tell the server where to point it.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.SeatPart and humanoid.SeatPart.Name == "GunnerSeat" then
		local origin = shotOrigin()
		if origin then
			local aim = camera.CFrame.LookVector
			if lockedTarget then
				aim = (lockedTarget.Position - origin).Unit
			end
			Remotes.Event("SetAimDirection"):FireServer(origin + aim * 300)
		end
	end
end

-- ==================================================================== TOUCH ==

--[[ A fire button for phones, since a lot of Roblox is played on one. ]]
local function buildTouchButton()
	if not UserInputService.TouchEnabled then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "TouchControls"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local fire = Instance.new("TextButton")
	fire.Size = UDim2.fromOffset(110, 110)
	fire.Position = UDim2.new(1, -140, 1, -180)
	fire.BackgroundColor3 = Color3.fromRGB(200, 60, 50)
	fire.BackgroundTransparency = 0.25
	fire.Text = "FIRE"
	fire.TextColor3 = Color3.new(1, 1, 1)
	fire.TextSize = 22
	fire.Font = Enum.Font.GothamBold
	fire.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = fire

	fire.MouseButton1Down:Connect(function()
		firing = true
		tryFire()
	end)
	fire.MouseButton1Up:Connect(function()
		firing = false
	end)

	local mega = Instance.new("TextButton")
	mega.Size = UDim2.fromOffset(90, 90)
	mega.Position = UDim2.new(1, -250, 1, -160)
	mega.BackgroundColor3 = Color3.fromRGB(90, 200, 220)
	mega.BackgroundTransparency = 0.25
	mega.Text = "MEGA"
	mega.TextColor3 = Color3.new(0, 0, 0)
	mega.TextSize = 18
	mega.Font = Enum.Font.GothamBold
	mega.Parent = gui

	local megaCorner = Instance.new("UICorner")
	megaCorner.CornerRadius = UDim.new(1, 0)
	megaCorner.Parent = mega

	mega.Activated:Connect(function()
		Remotes.Event("MegaDetonate"):FireServer()
	end)
end

-- ===================================================================== START ==

function Controls.Start()
	defaultFov = camera.FieldOfView

	local fetched = Remotes.Function("GetArsenal"):InvokeServer()
	if typeof(fetched) == "table" then
		arsenal = fetched :: any
	end
	buildSlotOrder()

	-- Start holding whatever the config says you start with.
	for _, name in Config.StartingLoadout do
		if arsenal[name] then
			equipped = name
			break
		end
	end

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	RunService.Heartbeat:Connect(onHeartbeat)

	buildTouchButton()
end

--[[ What the HUD needs to know about the gun in your hands. ]]
function Controls.EquippedName(): string
	return equipped
end

function Controls.EquippedEntry(): ArsenalEntry?
	return arsenal[equipped]
end

return Controls
