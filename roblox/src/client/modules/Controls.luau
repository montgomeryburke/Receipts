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
	ZoomLevels: { number }?,
	AutoAim: boolean,
	CanMegaDetonate: boolean,
	SemiAutoWhenScoped: boolean,
	MountedOnly: boolean,
}

local arsenal: { [string]: ArsenalEntry } = {}
local slotOrder: { [number]: { string } } = {}
local equipped = ""
local firing = false
-- 0 means hipfire; 1 and up index into the weapon's ZoomLevels.
local zoomStage = 0
local defaultFov = 70
local nextLocalFire = 0
local lockedTarget: BasePart? = nil

-- Defined further down, next to the rest of the look handling, but declared
-- here so the per-frame loop above can reach it.
local updateLook: () -> ()

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

	-- Auto-aim is always on for touch players. Aiming precisely with a thumb
	-- on glass is not a fair fight against a mouse.
	if spec and (spec.AutoAim or UserInputService.TouchEnabled) then
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

--[[
	Apply whatever zoom stage we are on.

	Scopes here work the way Halo's sniper did: right click steps *through*
	the magnifications rather than toggling one on and off. The low stages
	are the useful new part — 2x is close enough to line up a headshot across
	a room without losing track of where you are.
]]
local function applyZoom()
	local spec = arsenal[effectiveWeaponName()]
	local levels = spec and spec.ZoomLevels

	if not levels or zoomStage < 1 then
		zoomStage = 0
		TweenService:Create(camera, TweenInfo.new(0.12), { FieldOfView = defaultFov }):Play()
		-- Back over the shoulder.
		player.CameraMode = Enum.CameraMode.Classic
		Hud.SetZoom(0)
		return
	end

	local magnification = levels[math.clamp(zoomStage, 1, #levels)]
	TweenService:Create(camera, TweenInfo.new(0.12), {
		FieldOfView = defaultFov / magnification,
	}):Play()
	-- Down the sight properly. Zoomed out over the shoulder, the character's
	-- own head sits in the middle of the scope and hides what you are
	-- aiming at; first person puts the camera where his eye is.
	player.CameraMode = Enum.CameraMode.LockFirstPerson
	Hud.SetZoom(magnification)
end

--[[ Right click: next magnification, then back out to hipfire. ]]
local function cycleZoom()
	local spec = arsenal[effectiveWeaponName()]
	local levels = spec and spec.ZoomLevels
	if not levels or #levels == 0 then
		-- A gun with a single fixed scope still toggles.
		if spec and spec.ZoomFov then
			zoomStage = if zoomStage == 0 then 1 else 0
			if zoomStage == 1 then
				TweenService:Create(camera, TweenInfo.new(0.12), { FieldOfView = spec.ZoomFov }):Play()
				Hud.SetZoom(math.floor(defaultFov / spec.ZoomFov + 0.5))
			else
				applyZoom()
			end
		end
		return
	end

	zoomStage = (zoomStage + 1) % (#levels + 1)
	applyZoom()
end

local function clearZoom()
	zoomStage = 0
	applyZoom()
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

--[[ Which gun is currently chosen in each slot, for the weapon bar. ]]
local slotChoice: { [number]: string } = {}

local function refreshWeaponBar()
	local names: { [number]: string } = {}
	for slot = 1, 7 do
		local chosen = slotChoice[slot]
		if not chosen then
			local list = slotOrder[slot]
			chosen = list and list[1]
		end
		names[slot] = if chosen and arsenal[chosen] then arsenal[chosen].DisplayName else "—"
	end

	local activeSlot = if arsenal[equipped] then arsenal[equipped].Slot else 0
	Hud.SetLoadout(names, activeSlot)
end

local function equip(name: string)
	if not arsenal[name] or arsenal[name].MountedOnly then
		return
	end
	equipped = name
	slotChoice[arsenal[name].Slot] = name
	-- A fresh gun starts unscoped.
	clearZoom()
	Remotes.Event("EquipWeapon"):FireServer(name)
	-- No toast. The weapon bar shows exactly one gun lit, which is clearer
	-- than a stack of messages naming every gun you just cycled past.
	refreshWeaponBar()
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
	-- Mouse buttons are handled even when Roblox says a GUI consumed the
	-- click. The HUD covers a lot of the screen, and a click landing on a
	-- label rather than the world is not a reason to refuse to shoot — which
	-- is what "left click does nothing" turned out to be.
	local isMouseButton = input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.MouseButton2

	if processed and not isMouseButton then
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
		cycleZoom()
		return
	end

	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		-- Same key whether you are driving or on foot: go faster.
		Remotes.Event("SetTurbo"):FireServer(true)
		Hud.SetTurbo(true)
		return
	end

	if input.KeyCode == Enum.KeyCode.R then
		Remotes.Event("Reload"):FireServer()
	elseif input.KeyCode == Enum.KeyCode.F then
		-- The big one.
		Remotes.Event("MegaDetonate"):FireServer()
	elseif input.KeyCode == Enum.KeyCode.Q then
		Remotes.Event("Melee"):FireServer()
	elseif input.KeyCode == Enum.KeyCode.Space then
		-- Bail out of whatever you are riding. Harmless on foot.
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.SeatPart then
			Remotes.Event("Eject"):FireServer()
		end
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
	elseif input.KeyCode == Enum.KeyCode.Seven then
		selectSlot(7)
	end
end

local function onInputEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	then
		firing = false
	elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		Remotes.Event("SetTurbo"):FireServer(false)
		Hud.SetTurbo(false)
	end
end

--[[ Held triggers keep firing, and the turret keeps following your eyes. ]]
local function onHeartbeat()
	local spec = arsenal[effectiveWeaponName()]

	-- Everything holds down, except a scoped rifle: down the sight it is one
	-- shot at a time, so range still has to be earned.
	local automatic = spec ~= nil and spec.Automatic
	if spec and spec.SemiAutoWhenScoped and zoomStage >= 1 then
		automatic = false
	end
	if firing and automatic then
		tryFire()
	end

	Hud.SetLocked(lockedTarget ~= nil)
	updateLook()

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

-- ============================================================== LOOK & AIM ==

--[[ While the vote panel is up the cursor has to be free to click it. ]]
local mouseFree = false

function Controls.SetMouseFree(free: boolean)
	mouseFree = free
end

--[[
	Pin the cursor to the middle of the screen and turn the character to face
	wherever the camera is looking.

	This is the "the person and the screen should look where the cursor is"
	behaviour: aim is the centre of the screen, your body follows it, and
	there is no loose cursor to drift over a HUD element and eat your clicks.
]]
function updateLook()
	if UserInputService.TouchEnabled then
		return
	end

	if mouseFree then
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
		return
	end

	-- Roblox resets this, so it is re-asserted every frame.
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return
	end
	if humanoid.Health <= 0 then
		return
	end
	-- In a vehicle the seat decides which way you face; do not fight it.
	if humanoid.SeatPart then
		humanoid.AutoRotate = true
		return
	end

	humanoid.AutoRotate = false

	-- Lift the camera above his head and out to the side. The crosshair sits
	-- in the middle of the screen, and from directly behind that put it
	-- squarely on the back of his skull — you could not see what you were
	-- shooting at.
	humanoid.CameraOffset = Vector3.new(1.8, 3.2, 0)

	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then
		return
	end
	root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit)
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

	--[[ Gas and brake, for players with no keyboard. ]]
	local function pedal(text: string, colour: Color3, position: UDim2, value: number)
		local button = Instance.new("TextButton")
		button.Size = UDim2.fromOffset(96, 96)
		button.Position = position
		button.BackgroundColor3 = colour
		button.BackgroundTransparency = 0.25
		button.Text = text
		button.TextColor3 = Color3.new(0, 0, 0)
		button.TextSize = 18
		button.Font = Enum.Font.GothamBold
		button.Parent = gui

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = button

		button.MouseButton1Down:Connect(function()
			Remotes.Event("SetPedal"):FireServer(value)
		end)
		button.MouseButton1Up:Connect(function()
			Remotes.Event("SetPedal"):FireServer(0)
		end)
		return button
	end

	pedal("GAS", Color3.fromRGB(120, 220, 130), UDim2.new(0, 30, 1, -150), 1)
	pedal("BRAKE", Color3.fromRGB(230, 120, 110), UDim2.new(0, 140, 1, -150), -1)

	local turbo = Instance.new("TextButton")
	turbo.Size = UDim2.fromOffset(90, 90)
	turbo.Position = UDim2.new(1, -150, 1, -290)
	turbo.BackgroundColor3 = Color3.fromRGB(255, 200, 80)
	turbo.BackgroundTransparency = 0.25
	turbo.Text = "TURBO"
	turbo.TextColor3 = Color3.new(0, 0, 0)
	turbo.TextSize = 18
	turbo.Font = Enum.Font.GothamBold
	turbo.Parent = gui

	local turboCorner = Instance.new("UICorner")
	turboCorner.CornerRadius = UDim.new(1, 0)
	turboCorner.Parent = turbo

	turbo.MouseButton1Down:Connect(function()
		Remotes.Event("SetTurbo"):FireServer(true)
		Hud.SetTurbo(true)
	end)
	turbo.MouseButton1Up:Connect(function()
		Remotes.Event("SetTurbo"):FireServer(false)
		Hud.SetTurbo(false)
	end)
end

-- ===================================================================== START ==

function Controls.Start()
	defaultFov = camera.FieldOfView

	-- Built straight from Config rather than asked for over the network.
	--
	-- This used to be a RemoteFunction call, and if the server had not
	-- finished starting up yet that call errored — which aborted the rest of
	-- this function, so NO input was ever connected. No firing, no E, no
	-- turbo. Config already lives in ReplicatedStorage and the client has it
	-- the moment it loads, so there is nothing to wait for.
	for name, spec in Config.Weapons do
		arsenal[name] = {
			Slot = spec.Slot,
			Category = spec.Category,
			DisplayName = spec.DisplayName,
			MagSize = spec.MagSize,
			Automatic = spec.Automatic == true,
			ZoomFov = spec.ZoomFov,
			ZoomLevels = spec.ZoomLevels,
			SemiAutoWhenScoped = spec.SemiAutoWhenScoped == true,
			AutoAim = spec.AutoAim == true,
			CanMegaDetonate = spec.CanMegaDetonate == true,
			MountedOnly = spec.MountedOnly == true,
		}
	end
	buildSlotOrder()

	-- Start holding whatever the config says you start with.
	for _, name in Config.StartingLoadout do
		if arsenal[name] then
			equipped = name
			break
		end
	end

	refreshWeaponBar()

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
