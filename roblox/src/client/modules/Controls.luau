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
local Sound = require(Shared:WaitForChild("Sound"))
local Util = require(Shared:WaitForChild("Util"))
local Shot = require(Shared:WaitForChild("Shot"))

local Hud = require(script.Parent:WaitForChild("Hud"))
local Feel = require(script.Parent:WaitForChild("Feel"))

local player = Players.LocalPlayer

local function getCamera(): Camera?
	return workspace.CurrentCamera
end

local Controls = {}
local controlsStarted = false
local inFight = false
local lastAimSentAt = 0
local lastLockCheckAt = 0

type ArsenalEntry = {
	Slot: number,
	Category: string,
	DisplayName: string,
	MagSize: number,
	Cooldown: number,
	Recoil: number,
	Range: number,
	Color: Color3,
	SoundName: string,
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
			local ignoreList: { Instance } = { player.Character :: Instance, character }
			local myHum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if myHum and myHum.SeatPart then
				local veh = myHum.SeatPart:FindFirstAncestorOfClass("Model")
				if veh then
					table.insert(ignoreList, veh)
				end
			end
			local params = Util.RayParams(ignoreList)
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
--[[
	Everything the aim ray must not hit: you, and whatever you are riding.
]]
local function aimIgnoreList(): { Instance }
	local ignore: { Instance } = {}
	local character = player.Character
	if character then
		table.insert(ignore, character)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local seat = humanoid and humanoid.SeatPart
		local ride = seat and seat:FindFirstAncestorOfClass("Model")
		if ride then
			table.insert(ignore, ride)
		end
	end
	return ignore
end

--[[
	What the crosshair is actually sitting on.

	This is the fix for "the aiming isn't lined up with the dot", and the
	cause was geometry rather than tuning. A shot starts at the HEAD but the
	direction used to be the CAMERA's look vector -- and the camera sits
	1.8 studs right and 3.2 up of the head, and a good way behind it. A ray
	from the head along the camera's direction is a parallel line offset by
	those studs, so it never passes through what the crosshair covers. Close
	up the miss is enormous; far away it is a small angle that still reads as
	"my shots go wide".

	So: cast from the CAMERA through the crosshair -- which is exactly the
	camera's own look vector, the crosshair being dead centre -- find what is
	there, and then shoot at THAT from the muzzle. Now the dot is the truth
	at every range, which is what a crosshair is for.
]]
local function crosshairTarget(range: number): Vector3?
	local cam = getCamera()
	if not cam then
		return nil
	end
	local from = cam.CFrame.Position
	local along = cam.CFrame.LookVector
	local hit = workspace:Raycast(from, along * math.max(range, 64), Util.RayParams(aimIgnoreList()))
	return if hit then hit.Position else from + along * math.max(range, 64)
end

local function currentAimDirection(): (Vector3?, Vector3?)
	local origin = shotOrigin()
	if not origin then
		return nil, nil
	end

	local cam = getCamera()
	if not cam then
		return nil, nil
	end

	local spec0 = arsenal[effectiveWeaponName()]
	local aimAt = crosshairTarget(if spec0 then spec0.Range else 600)
	local rawDirection = cam.CFrame.LookVector
	if aimAt then
		local toTarget = aimAt - origin
		if toTarget.Magnitude > 0.5 then
			-- From the muzzle to whatever the dot is on.
			rawDirection = toTarget.Unit
		end
	end
	local spec = arsenal[effectiveWeaponName()]

	if spec and (spec.AutoAim or (UserInputService.TouchEnabled and not UserInputService.MouseEnabled)) then
		local target = findAutoAimTarget(origin, rawDirection)
		lockedTarget = target
		if target then
			local delta = target.Position - origin
			if delta.Magnitude > 0.001 then
				return origin, delta.Unit
			end
		end
	else
		lockedTarget = nil
	end

	return origin, rawDirection
end

-- ==================================================================== FIRING ==

-- Declared up here because onInputBegan reads it, and onInputBegan is
-- defined well above where this used to sit -- which made it a nil global
-- rather than this local, so the "ignore clicks while the cursor is free"
-- guard silently did nothing.
local mouseFree = false

-- The venue currently being offered, if you have walked into one, and the
-- order the menu listed its games in so the number keys can pick from it.
local pendingOffer: string? = nil
local menuOrder: { string } = {}

local nextShotFeedback = 0

-- Counts up while a hockey fight is running, so F throws punches as well as
-- detonating. Zero means no fight.
local inFight = false
local guardUp = false
local heldTool: string? = nil
local inVenue: string? = nil
local carrying = false
local carryingBall = false
local pouring = false
local nextPourAt = 0
local guardKeyDown = false
local reelKeyDown = false
local shownContext: string? = nil

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

	local origin, direction = currentAimDirection()
	if not origin or not direction then
		return
	end

	Remotes.Event("FireWeapon"):FireServer(direction)

	--[[
		Everything you see and hear, now, on this machine.

		Gated on the weapon's REAL cooldown rather than the loose network one
		above. Both sides read the same Config, so this is the same rate the
		server will actually accept shots at -- which means what you see is
		what happened, without waiting to be told.

		Before this, the flash, the bang and the tracer were all built on the
		server and replicated back, so every shot carried a full round trip
		of delay. That is the single biggest reason the guns felt sluggish,
		and it is not something you can tune your way out of.
	]]
	if now < nextShotFeedback then
		return
	end
	nextShotFeedback = now + spec.Cooldown * 0.9

	Feel.Kick(spec.Recoil)
	Sound.Flat(spec.SoundName, 0.65)

	--[[
		A rifle crack on top of the boom.

		What makes a high-powered rifle sound high-powered is the snap, not
		the bass -- the bass alone reads as a thud. Layered rather than
		replaced, because the boom is what carries it across the map and the
		crack is what sells it in your hands.
	]]
	if spec.Category == "Sniper" then
		Sound.Flat("SniperCrack", 0.55)
	end

	local muzzle = origin + direction * 2
	-- Trace it locally too, so the tracer stops at the wall rather than
	-- carrying on through it. This raycast decides nothing: the server does
	-- its own, and the server's is the one that deals damage.
	local ignore: { Instance } = {}
	local character = player.Character
	if character then
		table.insert(ignore, character)
		local hum = character:FindFirstChildOfClass("Humanoid")
		if hum and hum.SeatPart then
			local veh = hum.SeatPart:FindFirstAncestorOfClass("Model")
			if veh then
				table.insert(ignore, veh)
			end
		end
	end
	local look = workspace:Raycast(origin, direction * spec.Range, Util.RayParams(ignore))
	local endPoint = if look then look.Position else origin + direction * spec.Range
	Shot.Full(muzzle, endPoint, spec.Color, if look then look.Normal else nil)
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
	local cam = getCamera()
	local spec = arsenal[effectiveWeaponName()]
	local levels = spec and spec.ZoomLevels

	if zoomStage < 1 or (not levels and not (spec and spec.ZoomFov)) then
		zoomStage = 0
		if cam then
			TweenService:Create(cam, TweenInfo.new(0.12), { FieldOfView = defaultFov }):Play()
		end
		player.CameraMode = Enum.CameraMode.Classic
		Hud.SetZoom(0)
		-- Back to walking pace.
		Remotes.Event("SetScoped"):FireServer(false)
		return
	end

	local targetFov: number
	local magnification: number
	if levels and #levels > 0 then
		magnification = levels[math.clamp(zoomStage, 1, #levels)]
		targetFov = defaultFov / magnification
	else
		targetFov = (spec and spec.ZoomFov) or defaultFov
		magnification = math.floor(defaultFov / math.max(targetFov, 1) + 0.5)
	end

	if cam then
		TweenService:Create(cam, TweenInfo.new(0.12), { FieldOfView = targetFov }):Play()
	end
	player.CameraMode = Enum.CameraMode.LockFirstPerson
	Hud.SetZoom(magnification)
	--[[
		Scoped, you move at a fraction of walking pace.

		Without it a 50x scope is a free sprinting wallhack. With it,
		committing to a shot means committing to standing still, which is the
		trade every shooter with a scope in it makes.
	]]
	Remotes.Event("SetScoped"):FireServer(true)
end

--[[ Right click: next magnification, then back out to hipfire. ]]
local function cycleZoom()
	local spec = arsenal[effectiveWeaponName()]
	local levels = spec and spec.ZoomLevels
	if not levels or #levels == 0 then
		if spec and spec.ZoomFov then
			zoomStage = if zoomStage == 0 then 1 else 0
			applyZoom()
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
	Sound.Flat("WeaponSwitch")
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

--[[
	Open or close the scoreboard.

	Shared by the Tab key and the touch button, because they used to track it
	separately: a Tab press left the button's own flag stale, so on a tablet
	with a keyboard the button then needed two taps to do anything.
]]
local scoreboardOpen = false

local function setScoreboard(visible: boolean)
	scoreboardOpen = visible
	Hud.ShowScoreboard(visible)
	if visible then
		Remotes.Event("RequestScoreboard"):FireServer()
	end
end


-- =================================================================== CONTEXT ==

--[[
	One context at a time, and it owns the contested keys.

	Q, E and F each used to mean three different things depending on which
	script got to the input first: F was the mega-detonate AND the hockey
	punch AND lighting a gas trail; Q was the hockey guard AND the melee AND
	the mud truck's drivetrain; E was the diff lock AND the ski shove AND
	every ProximityPrompt in the game. With a flat if-chain, whichever branch
	came first won, so pressing F in a fight also set off a diamond round and
	pressing Q in a truck also swung a stick.

	So: what you are currently DOING claims those keys. The table below holds
	only the OVERRIDES -- a key a context does not name falls through to the
	ordinary on-foot handling below, which is why reload still works while
	driving and the gun still works in a fight. That fall-through is the
	whole reason this is a small change rather than a rewrite.

	Higher in the list wins. A fight outranks a vehicle because you cannot
	start one while seated, so if both flags are somehow set the fight is the
	stale one to trust least -- and being unable to punch is more confusing
	than being unable to change gear.
]]
local CONTEXT_PRIORITY = { "Fight", "Vehicle", "Riding", "Tool", "Sport" }

-- Which VehicleKind counts as driving, and which counts as riding. Anything
-- unlisted is treated as a vehicle, because a seat you steer is the common
-- case and a wrong guess there is harmless.
local RIDING_KINDS = {
	Tube = true,
	Glider = true,
	Skis = true,
	Snowboard = true,
	Bike = true,
}

local function vehicleModel(): Model?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not seat then
		return nil
	end
	return seat:FindFirstAncestorOfClass("Model")
end

local function contextActive(name: string): boolean
	if name == "Fight" then
		return inFight
	elseif name == "Tool" then
		return heldTool ~= nil
	elseif name == "Sport" then
		return inVenue ~= nil
	end

	local model = vehicleModel()
	if not model then
		return false
	end
	local riding = RIDING_KINDS[tostring(model:GetAttribute("VehicleKind"))] == true
	return if name == "Riding" then riding else not riding
end

local function activeContext(): string
	for _, name in CONTEXT_PRIORITY do
		if contextActive(name) then
			return name
		end
	end
	return "Foot"
end

--[[ Does the thing we are sitting in have this fitting? ]]
local function vehicleHas(attribute: string): boolean
	local model = vehicleModel()
	return model ~= nil and model:GetAttribute(attribute) == true
end

--[[
	The contested keys, per context.

	`down` and `up` are optional; `label` is what the action bar shows, and a
	`when` predicate hides a key the current vehicle has no fitting for --
	there is no point telling somebody in a Jeep about a winch.
]]
type Binding = {
	label: string,
	down: (() -> ())?,
	up: (() -> ())?,
	when: (() -> boolean)?,
}

local CONTEXT_BINDINGS: { [string]: { [Enum.KeyCode]: Binding } } = {
	Fight = {
		[Enum.KeyCode.F] = {
			label = "PUNCH",
			down = function()
				Remotes.Event("HockeyPunch"):FireServer()
			end,
		},
		[Enum.KeyCode.Q] = {
			label = "GUARD",
			down = function()
				if not guardUp then
					guardUp = true
					Remotes.Event("HockeyBlock"):FireServer(true)
				end
			end,
			up = function()
				if guardUp then
					guardUp = false
					Remotes.Event("HockeyBlock"):FireServer(false)
				end
			end,
		},
	},

	Vehicle = {
		[Enum.KeyCode.Q] = {
			label = "4WD",
			when = function()
				return vehicleHas("HasDriveModes")
			end,
			down = function()
				Remotes.Event("CycleDriveMode"):FireServer()
			end,
		},
		[Enum.KeyCode.E] = {
			label = "DIFF LOCK",
			when = function()
				return vehicleHas("HasDiffLock")
			end,
			down = function()
				Remotes.Event("ToggleDiffLock"):FireServer()
			end,
		},
		[Enum.KeyCode.C] = {
			label = "WINCH",
			when = function()
				return vehicleHas("HasWinch")
			end,
			down = function()
				Remotes.Event("ToggleWinch"):FireServer()
			end,
		},
		[Enum.KeyCode.X] = {
			label = "REEL",
			when = function()
				return vehicleHas("HasWinch")
			end,
			-- Held, like a real winch switch. Reeling was originally on R,
			-- which is reload -- so getting unstuck emptied your magazine.
			down = function()
				if not reelKeyDown then
					reelKeyDown = true
					Remotes.Event("ReelWinch"):FireServer(true)
				end
			end,
			up = function()
				if reelKeyDown then
					reelKeyDown = false
					Remotes.Event("ReelWinch"):FireServer(false)
				end
			end,
		},
	},

	--[[
		Playing one of the sub-games, on foot.

		Lowest priority of the lot, so a car or a fight always wins -- being
		on the rink matters less than being in the thing you are driving.

		The ball and puck shot is on F rather than the mouse for the same
		reason as everything else here: the mouse is the gun, always. You can
		shoot the puck with a rifle too, which is the older and better joke,
		but once you are CARRYING it you need a way to let go of it that is
		not "put your gun down".
	]]
	Sport = {
		--[[
			One key for both, chosen by what is in your hands.

			A puck is a flick and a basketball is a wind-up, so the same key
			behaves differently -- but it is the same key, because "the
			thing you do with the thing you are holding" should not be two
			bindings to remember. The action bar says which one is live.
		]]
		[Enum.KeyCode.F] = {
			label = "SHOOT",
			when = function()
				return carrying or carryingBall
			end,
			down = function()
				if carryingBall then
					-- Held: the wind-up starts now and the power is however
					-- long it lasts, timed on the server.
					Remotes.Event("BallCharge"):FireServer(true)
					return
				end
				local _, direction = currentAimDirection()
				if direction then
					Remotes.Event("HockeyShoot"):FireServer(direction)
				end
			end,
			up = function()
				if not carryingBall then
					return
				end
				local _, direction = currentAimDirection()
				Remotes.Event("BallShoot"):FireServer(direction)
			end,
		},
		[Enum.KeyCode.X] = {
			label = "LEAVE",
			down = function()
				Remotes.Event("LeaveArcade"):FireServer()
			end,
		},
	},

	Riding = {
		[Enum.KeyCode.E] = {
			label = "SHOVE",
			down = function()
				Remotes.Event("ShoveBoost"):FireServer()
			end,
		},
	},

	--[[
		Holding something that is not a gun.

		Pouring is on Q rather than the mouse, which is a deliberate
		departure from how a tool like this would normally work. The rule for
		this whole game is that nothing ever takes your gun away -- that is
		what makes a fight on an ice rink a fight rather than a cutscene --
		and a gas can is not an exception just because it is held in the same
		hand. So: the mouse still shoots, Q pours, F lights it.
	]]
	Tool = {
		[Enum.KeyCode.Q] = {
			label = "POUR",
			-- Held. A puddle every fifth of a second, so laying a trail
			-- takes real time and is visible while you do it.
			down = function()
				pouring = true
			end,
			up = function()
				pouring = false
			end,
		},
		[Enum.KeyCode.F] = {
			label = "IGNITE",
			down = function()
				Remotes.Event("ToolSecondary"):FireServer()
			end,
		},
	},
}

-- What the action bar says for keys that are NOT overridden, so the strip
-- reads as a complete set of what is live rather than only the exotic bits.
local BASE_ACTIONS: { [string]: { { key: string, label: string } } } = {
	Foot = {
		{ key = "F", label = "MEGA" },
		{ key = "Q", label = "MELEE" },
		{ key = "G", label = "GRENADE" },
	},
	Fight = {
		{ key = "MOUSE", label = "STILL SHOOTS" },
	},
	Vehicle = {
		{ key = "SHIFT", label = "TURBO" },
		{ key = "SPACE", label = "BAIL" },
	},
	Riding = {
		{ key = "SPACE", label = "BAIL" },
		{ key = "MOUSE", label = "SHOOT" },
	},
	Tool = {
		{ key = "MOUSE", label = "STILL SHOOTS" },
	},
	Sport = {
		{ key = "MOUSE", label = "STILL SHOOTS" },
	},
}

local KEY_LABELS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.Q] = "Q",
	[Enum.KeyCode.E] = "E",
	[Enum.KeyCode.F] = "F",
	[Enum.KeyCode.C] = "C",
	[Enum.KeyCode.X] = "X",
}

--[[
	Push the strip for whatever we are doing now.

	Only on a change: this is called from the heartbeat, and rebuilding four
	labels sixty times a second to say the same thing is exactly the kind of
	cost that adds up across twenty players.
]]
local function refreshActionBar(force: boolean?)
	local context = activeContext()

	local entries: { { key: string, label: string } } = {}
	local bindings = CONTEXT_BINDINGS[context]
	if bindings then
		for code, binding in bindings do
			if not binding.when or binding.when() then
				table.insert(entries, { key = KEY_LABELS[code] or "?", label = binding.label })
			end
		end
	end
	table.sort(entries, function(a, b)
		return a.key < b.key
	end)
	for _, entry in BASE_ACTIONS[context] or {} do
		table.insert(entries, entry)
	end

	-- The signature is the context plus the keys actually offered, so a
	-- winch being hooked up mid-drive still redraws.
	local signature = context
	for _, entry in entries do
		signature ..= "|" .. entry.key .. entry.label
	end
	if not force and signature == shownContext then
		return
	end
	shownContext = signature

	Hud.SetActionBar(entries)
end

--[[
	Run a key through the current context. True means it was handled there
	and the ordinary handling below must not also run.
]]
local function dispatchContext(input: InputObject, began: boolean): boolean
	local bindings = CONTEXT_BINDINGS[activeContext()]
	local binding = bindings and bindings[input.KeyCode]
	if not binding then
		return false
	end
	if binding.when and not binding.when() then
		return false
	end

	local handler = if began then binding.down else binding.up
	if handler then
		handler()
	end
	-- Claimed either way. A context that names a key owns both edges of it,
	-- or releasing Q in a truck would swing a stick on the way up.
	return true
end

-- ===================================================================== INPUT ==

local function onInputBegan(input: InputObject, processed: boolean)
	-- Mouse buttons are handled even when Roblox says a GUI consumed the
	-- click. The HUD covers a lot of the screen, and a click landing on a
	-- label rather than the world is not a reason to refuse to shoot — which
	-- is what "left click does nothing" turned out to be.
	local isMouseButton = input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.MouseButton2

	if (processed and not isMouseButton) or (isMouseButton and mouseFree) then
		return
	end

	-- What you are doing claims its keys first.
	if dispatchContext(input, true) then
		refreshActionBar()
		return
	end

	--[[
		Left click fires. A raw touch does NOT.

		Touch used to be in here with the mouse, which meant any drag on a
		phone screen -- the only way to look around on a phone -- fired the
		gun continuously for as long as your thumb was moving. Touch players
		fire with the FIRE button, which drives the same code directly.
	]]
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
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

	--[[
		The sub-game menu, and the walk-in offer.

		B opens the list from anywhere and takes you straight to whatever you
		pick -- the whole point being that you should not have to walk across
		a 2000-stud map to find out what is in the corner of it. Y accepts an
		offer when you are already standing in a venue.
	]]
	--[[
		H: what do I do, and take me there.

		Deliberately NOT in the context table. Everything in there changes
		meaning depending on what you are doing, and the one key whose job
		is to explain that cannot itself be conditional -- a player who is
		lost enough to need it is exactly the player who should not have to
		work out which mode they are in first.
	]]
	if input.KeyCode == Enum.KeyCode.H then
		if Hud.HelpOpen() then
			Hud.HideHelp()
			Controls.SetMouseFree(false)
		else
			-- Ask for a fresh list on open, so the player counts beside each
			-- activity are current rather than whatever they were last time.
			Remotes.Event("RequestArcadeMenu"):FireServer()
			Hud.ShowHelp()
			Controls.SetMouseFree(true)
		end
		return
	end

	if input.KeyCode == Enum.KeyCode.B then
		if Hud.ArcadeMenuOpen() then
			Hud.HideArcadeMenu()
			Controls.SetMouseFree(false)
		else
			Remotes.Event("RequestArcadeMenu"):FireServer()
			Controls.SetMouseFree(true)
		end
		return
	end

	if input.KeyCode == Enum.KeyCode.Y then
		if pendingOffer then
			Remotes.Event("JoinArcade"):FireServer(pendingOffer)
			pendingOffer = nil
			Hud.HideArcadeOffer()
		end
		return
	end

	-- The number row picks from the open menu rather than switching weapons.
	if Hud.ArcadeMenuOpen() then
		local digits = {
			[Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3,
			[Enum.KeyCode.Four] = 4, [Enum.KeyCode.Five] = 5, [Enum.KeyCode.Six] = 6,
			[Enum.KeyCode.Seven] = 7, [Enum.KeyCode.Eight] = 8, [Enum.KeyCode.Nine] = 9,
		}
		local pick = digits[input.KeyCode]
		if pick and menuOrder[pick] then
			Remotes.Event("JoinArcade"):FireServer(menuOrder[pick])
			Hud.HideArcadeMenu()
			Controls.SetMouseFree(false)
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			Hud.HideArcadeMenu()
			Controls.SetMouseFree(false)
			return
		end
	end

	if Hud.HelpOpen() and input.KeyCode == Enum.KeyCode.Escape then
		Hud.HideHelp()
		Controls.SetMouseFree(false)
		return
	end

	if input.KeyCode == Enum.KeyCode.G then
		-- The grenade key. Throws where you are aiming without changing what
		-- is in your hands, the way Halo's did.
		local _, direction = currentAimDirection()
		if direction then
			Remotes.Event("ThrowGrenade"):FireServer(direction)
			Feel.Kick(1.2)
		end
		return
	end

	if input.KeyCode == Enum.KeyCode.Tab then
		-- Held, not toggled. Ask for fresh numbers at the moment it opens,
		-- rather than streaming a scoreboard to everyone continuously.
		setScoreboard(true)
		return
	end

	if input.KeyCode == Enum.KeyCode.R then
		Remotes.Event("Reload"):FireServer()
	elseif input.KeyCode == Enum.KeyCode.F then
		-- The big one. In a fight the context table takes F for the punch,
		-- and while holding a gas can it takes F to light the trail, so this
		-- only ever runs on foot and empty-handed.
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
	if dispatchContext(input, false) then
		refreshActionBar()
		return
	end

	if input.KeyCode == Enum.KeyCode.Tab then
		setScoreboard(false)
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		firing = false
	elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		Remotes.Event("SetTurbo"):FireServer(false)
		Hud.SetTurbo(false)
	end
end

--[[ Held triggers keep firing, and the turret keeps following your eyes. ]]
local lastBarCheckAt = 0

local function onHeartbeat()
	-- Sitting down, standing up and picking something up all change which
	-- keys are live, and none of them tell us directly. Five times a second
	-- is fast enough to feel immediate and slow enough not to matter.
	local now = os.clock()
	if now - lastBarCheckAt >= 0.2 then
		lastBarCheckAt = now
		refreshActionBar()
	end

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

	-- Pouring, while Q is held and there is something to pour. Paced here
	-- rather than on the keypress because it is a continuous action, and
	-- paced at all because one request per frame is sixty a second for a
	-- thing the server does five times a second.
	if pouring and heldTool then
		local pourNow = os.clock()
		if pourNow >= nextPourAt then
			nextPourAt = pourNow + 0.15
			Remotes.Event("PourGas"):FireServer()
		end
	end

	local now = os.clock()
	if now - lastLockCheckAt >= 0.06 then
		lastLockCheckAt = now
		local spec = arsenal[effectiveWeaponName()]
		local cam = getCamera()
		local origin = shotOrigin()
		if spec and cam and origin and (spec.AutoAim or (UserInputService.TouchEnabled and not UserInputService.MouseEnabled)) then
			lockedTarget = findAutoAimTarget(origin, cam.CFrame.LookVector)
		else
			lockedTarget = nil
		end
	end

	Hud.SetLocked(lockedTarget ~= nil)
	updateLook()

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if (not humanoid or humanoid.Health <= 0) and zoomStage > 0 then
		clearZoom()
	end

	if humanoid and humanoid.SeatPart and humanoid.SeatPart.Name == "GunnerSeat" and now - lastAimSentAt >= 0.05 then
		lastAimSentAt = now
		local cam = getCamera()
		local origin = shotOrigin()
		if origin and cam then
			local aim = cam.CFrame.LookVector
			if lockedTarget and lockedTarget.Parent then
				local delta = lockedTarget.Position - origin
				if delta.Magnitude > 0.001 then
					aim = delta.Unit
				end
			end
			Remotes.Event("SetAimDirection"):FireServer(origin + aim * 300)
		end
	end
end

-- ============================================================== LOOK & AIM ==

--[[ While the vote panel is up the cursor has to be free to click it. ]]

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
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		return
	end

	if mouseFree then
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
		return
	end

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
	if humanoid.SeatPart then
		humanoid.AutoRotate = true
		humanoid.CameraOffset = Vector3.zero
		return
	end

	humanoid.AutoRotate = false
	humanoid.CameraOffset = if zoomStage > 0 then Vector3.zero else Vector3.new(1.8, 3.2, 0)

	local cam = getCamera()
	if not cam then
		return
	end
	local look = cam.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then
		return
	end
	root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit)
end

-- ==================================================================== TOUCH ==

--[[
	On-screen controls for phones and tablets.

	A phone player could fire, mega-detonate, turbo and work the pedals, but
	had no way at all to change weapon, throw a grenade, bail out of a
	vehicle or look at the scoreboard -- there is no number row, no G, no
	space bar and no Tab on a touch screen. Those are not conveniences; a
	player who cannot change weapon is playing a different game.

	Entering a vehicle needs no button: Roblox puts its own tappable prompt
	on screen for a ProximityPrompt on a touch device.
]]
local function roundButton(
	gui: Instance,
	text: string,
	colour: Color3,
	size: number,
	position: UDim2
): TextButton
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(size, size)
	button.Position = position
	button.BackgroundColor3 = colour
	button.BackgroundTransparency = 0.25
	button.Text = text
	-- Dark text on the bright buttons, light on the dark ones, so every
	-- label stays readable in sunlight on a phone.
	local brightness = colour.R * 0.3 + colour.G * 0.6 + colour.B * 0.1
	button.TextColor3 = if brightness > 0.5 then Color3.new(0, 0, 0) else Color3.new(1, 1, 1)
	button.TextSize = if size >= 100 then 22 else 17
	button.Font = Enum.Font.GothamBold
	button.AutoButtonColor = true
	button.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	return button
end

local function buildTouchButton()
	if not UserInputService.TouchEnabled then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "TouchControls"
	gui.ResetOnSpawn = false
	-- Above the HUD on purpose. Without an explicit order the two layers
	-- are drawn in creation order, which is not something to rely on.
	gui.DisplayOrder = 10
	gui.Parent = player:WaitForChild("PlayerGui")

	-- ------------------------------------------------- right hand: shooting
	local fire = roundButton(gui, "FIRE", Color3.fromRGB(200, 60, 50), 110, UDim2.new(1, -140, 1, -180))
	fire.MouseButton1Down:Connect(function()
		firing = true
		tryFire()
	end)
	fire.MouseButton1Up:Connect(function()
		firing = false
	end)

	local mega = roundButton(gui, "MEGA", Color3.fromRGB(90, 200, 220), 90, UDim2.new(1, -250, 1, -160))
	mega.Activated:Connect(function()
		Remotes.Event("MegaDetonate"):FireServer()
	end)

	local nade = roundButton(gui, "NADE", Color3.fromRGB(130, 190, 110), 86, UDim2.new(1, -250, 1, -268))
	nade.Activated:Connect(function()
		local _, direction = currentAimDirection()
		if direction then
			Remotes.Event("ThrowGrenade"):FireServer(direction)
			Feel.Kick(1.2)
		end
	end)

	local swap = roundButton(gui, "GUN ▶", Color3.fromRGB(190, 180, 210), 86, UDim2.new(1, -140, 1, -300))
	swap.Activated:Connect(function()
		-- Step through every weapon in order, so one button reaches all of
		-- them. The number keys cycle within a slot; this cycles the lot.
		local names = {}
		for name in arsenal do
			table.insert(names, name)
		end
		table.sort(names, function(a, b)
			local left, right = arsenal[a], arsenal[b]
			if left.Slot ~= right.Slot then
				return left.Slot < right.Slot
			end
			return a < b
		end)

		-- Skip the ones you cannot hold on foot, or the button would appear
		-- to do nothing on the turret and tank guns.
		local holdable = {}
		for _, name in names do
			if not arsenal[name].MountedOnly then
				table.insert(holdable, name)
			end
		end
		if #holdable == 0 then
			return
		end

		local at = table.find(holdable, equipped)
		local nextName = holdable[if at then (at % #holdable) + 1 else 1]
		equip(nextName)
	end)

	-- -------------------------------------------------- left hand: driving
	local function pedal(text: string, colour: Color3, position: UDim2, value: number)
		local button = roundButton(gui, text, colour, 96, position)
		button.MouseButton1Down:Connect(function()
			Remotes.Event("SetPedal"):FireServer(value)
		end)
		button.MouseButton1Up:Connect(function()
			Remotes.Event("SetPedal"):FireServer(0)
		end)
		return button
	end

	-- Clear of the motion tracker, which owns x 24..188 and the bottom 284
	-- pixels of the left edge. Putting a thumb button on top of the radar
	-- costs you the radar.
	local DIAL_RIGHT = 200

	pedal("GAS", Color3.fromRGB(120, 220, 130), UDim2.new(0, DIAL_RIGHT, 1, -120), 1)
	pedal("BRAKE", Color3.fromRGB(230, 120, 110), UDim2.new(0, DIAL_RIGHT + 110, 1, -120), -1)

	local turbo = roundButton(gui, "TURBO", Color3.fromRGB(255, 200, 80), 90,
		UDim2.new(0, DIAL_RIGHT, 1, -222))
	turbo.MouseButton1Down:Connect(function()
		Remotes.Event("SetTurbo"):FireServer(true)
		Hud.SetTurbo(true)
	end)
	turbo.MouseButton1Up:Connect(function()
		Remotes.Event("SetTurbo"):FireServer(false)
		Hud.SetTurbo(false)
	end)

	-- Bail out of a vehicle or a rocket. Deploys the parachute, same as the
	-- space bar, and is harmless on foot.
	local bail = roundButton(gui, "BAIL", Color3.fromRGB(240, 160, 60), 86,
		UDim2.new(0, DIAL_RIGHT + 104, 1, -220))
	bail.Activated:Connect(function()
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.SeatPart then
			Remotes.Event("Eject"):FireServer()
		end
	end)

	-- Tapped rather than held: holding a button down to read a scoreboard is
	-- fine with a thumb on Tab and miserable with a thumb on glass.
	local scores = roundButton(gui, "SCORE", Color3.fromRGB(120, 150, 200), 78,
		UDim2.new(0.5, -39, 1, -96))
	scores.Activated:Connect(function()
		setScoreboard(not scoreboardOpen)
	end)
end

-- ===================================================================== START ==

function Controls.Start()
	if controlsStarted then
		return
	end
	controlsStarted = true
	local cam = getCamera()
	-- From Config, not from whatever the camera happened to be on. Reading
	-- it off the camera meant the base FOV depended on whether Visuals had
	-- started yet, so the scope sometimes un-zoomed to 70 and sometimes to
	-- 75 -- a difference you feel and cannot explain.
	defaultFov = Config.Visuals.BaseFieldOfView
	if cam then
		cam.FieldOfView = defaultFov
	end

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
			Cooldown = spec.Cooldown,
			Recoil = spec.Recoil or 0.8,
			Range = spec.Range,
			Color = spec.Color,
			SoundName = Sound.ForWeapon(spec),
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
			slotChoice[arsenal[name].Slot] = name
			break
		end
	end

	refreshWeaponBar()

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	UserInputService.WindowFocusReleased:Connect(function()
		firing = false
		Remotes.Event("SetTurbo"):FireServer(false)
		Hud.SetTurbo(false)
	end)
	RunService.Heartbeat:Connect(onHeartbeat)

	buildTouchButton()
end

--[[ What the HUD needs to know about the gun in your hands. ]]
function Controls.EquippedName(): string
	return equipped
end

--[[ Whether the scoreboard is up, for tests. ]]
--[[
	Allow Start() to run again, for tests.

	Start() is idempotent in production on purpose -- it used to be able to
	double-connect every input handler when the retry loop fired. A test that
	needs to bring the controls up as a different kind of device has to be
	able to clear that latch, and doing it through a named function is
	honester than reaching into the module.
]]
--[[ A venue is offering a game; Y accepts it. ]]
function Controls.SetPendingOffer(id: string?)
	pendingOffer = id
end

--[[ Remember the order the menu was listed in, for the number keys. ]]
function Controls.SetMenuOrder(ids: { string })
	menuOrder = ids
end

function Controls.ResetForTests()
	controlsStarted = false
end

--[[
	A fight started or finished. While one is running F throws punches and Q
	is the guard; the mouse still works the gun throughout, which is the
	point of fighting here rather than in a cutscene.
]]
function Controls.SetFighting(fighting: boolean)
	inFight = fighting
	if not fighting and guardUp then
		guardUp = false
		Remotes.Event("HockeyBlock"):FireServer(false)
	end
	refreshActionBar()
end

--[[
	What is in your hands, for the tool context.

	nil means empty-handed, which puts F back on the mega-detonate. Passing a
	name claims F for that tool's second action instead -- lighting a gas
	trail, in the one case that exists so far.
]]
function Controls.SetTool(name: string?)
	heldTool = name
	if not name then
		-- Dropping the can mid-pour must stop the pour, or the request
		-- keeps going out every frame for the rest of the round.
		pouring = false
	end
	refreshActionBar()
end

--[[
	Which sub-game we are in, if any.

	Drives the Sport context, which is what puts LEAVE on the action bar --
	without it the server had a handler for leaving a game that nothing
	could ever trigger, so the only way out was to walk far enough away.
]]
function Controls.SetVenue(id: string?)
	inVenue = id
	if not id then
		carrying = false
		carryingBall = false
	end
	refreshActionBar()
end

--[[ Carrying the puck, which is what makes F worth offering. ]]
function Controls.SetCarrying(on: boolean)
	carrying = on
	refreshActionBar()
end

--[[ Holding the basketball, which makes F a wind-up rather than a flick. ]]
function Controls.SetCarryingBall(on: boolean)
	carryingBall = on
	refreshActionBar()
end

--[[ For tests: which context owns the keys right now. ]]
function Controls.ContextForTests(): string
	return activeContext()
end

--[[
	For tests: redraw the strip now.

	In the game the heartbeat notices a context change within 200ms, which is
	not something a terminal can wait for -- os.clock barely moves across a
	whole suite, so the throttle would never come due.
]]
function Controls.RefreshActionBarForTests()
	refreshActionBar(true)
end

--[[ For tests: is the guard up right now? ]]
function Controls.GuardUpForTests(): boolean
	return guardUp
end

function Controls.ScoreboardOpenForTests(): boolean
	return scoreboardOpen
end

function Controls.EquippedEntry(): ArsenalEntry?
	return arsenal[equipped]
end

return Controls
