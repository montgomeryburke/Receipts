--!strict
--[[
	WeaponService — pulling the trigger.

	The client says "I am firing this gun in this direction". The server checks
	that it is allowed, then decides what got hit. The client never gets to say
	who it hit, which is the whole reason the game cannot be cheated by editing
	your own copy of it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Sound = require(Shared:WaitForChild("Sound"))
local Util = require(Shared:WaitForChild("Util"))

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local DamageService = require(script.Parent:WaitForChild("DamageService"))
local ProjectileService = require(script.Parent:WaitForChild("ProjectileService"))
local VehicleService = require(script.Parent:WaitForChild("VehicleService"))
local WildlifeService = require(script.Parent:WaitForChild("WildlifeService"))
local CarnivalService = require(script.Parent:WaitForChild("CarnivalService"))
local FireService = require(script.Parent:WaitForChild("FireService"))
local BasketballService = require(script.Parent:WaitForChild("BasketballService"))
local MedalService = require(script.Parent:WaitForChild("MedalService"))
local HockeyService = require(script.Parent:WaitForChild("HockeyService"))

local WeaponService = {}

-- How far from a player's own body a shot is allowed to claim to start.
-- Generous enough for lag and long gun barrels, tight enough to stop somebody
-- firing from the other side of the map.
local MAX_ORIGIN_DRIFT = 30

local rng = Random.new()

--[[
	Draw the shot.

	The old version of this was a 0.22-stud line at 35% transparency lasting
	0.08 seconds — technically a tracer, practically invisible. Hitscan guns
	therefore looked like they were doing nothing at all, while the vehicle
	guns, which fire visible projectiles, looked fine. This is deliberately
	loud: a thick bright beam, a muzzle flash and a spark where it lands.
]]
--[[
	Tell everybody except the shooter what a shot looked like.

	The shooter's own client already drew it, the instant they pulled the
	trigger -- which is the whole point. Doing the visuals server-side meant
	the flash, the bang and the tracer all arrived one network round trip
	after the trigger, a constant 50-150ms delay on every shot that no amount
	of damage tuning can make feel good.

	Only players near enough to see it are told. Nobody watches a tracer from
	the other end of a 1500-stud map, and a minigun firing 22 times a second
	does not need to tell all twenty of them.
]]
local SHOT_AUDIBLE_RANGE = 420

local function broadcastShot(
	shooter: Player,
	origin: Vector3,
	endPoint: Vector3,
	spec: Config.WeaponSpec,
	normal: Vector3?
)
	local payload = {
		origin = origin,
		endPoint = endPoint,
		color = spec.Color,
		normal = normal,
		sound = Sound.ForWeapon(spec),
	}

	for _, other in Players:GetPlayers() do
		if other == shooter then
			continue
		end
		local character = other.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			if (root.Position - origin).Magnitude <= SHOT_AUDIBLE_RANGE then
				Remotes.Event("ShotFired"):FireClient(other, payload)
			end
		end
	end
end

local function updateHeldWeapon(player: Player)
	local character = player.Character
	if not character then
		return
	end

	local existing = character:FindFirstChild("HeldWeapon")
	if existing then
		existing:Destroy()
	end

	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") then
		return
	end

	local state = PlayerState.Get(player)
	local spec = Config.Weapons[state.equipped]
	if not spec then
		return
	end

	local model = Instance.new("Model")
	model.Name = "HeldWeapon"

	-- Longer barrel for the long guns, stubby for sidearms.
	local length = if spec.Category == "Sniper" then 5.5
		elseif spec.Category == "Automatic" then 4.2
		elseif spec.Category == "Shotgun" then 4.0
		elseif spec.Category == "Explosive" then 3.6
		else 2.2

	local body = Util.Part({
		Name = "Barrel",
		Size = Vector3.new(0.4, 0.5, length),
		CFrame = hand.CFrame * CFrame.new(0, -0.4, -length * 0.4),
		Color = spec.Color,
		Material = Enum.Material.Metal,
		Anchored = false,
		CanCollide = false,
		Massless = true,
		Parent = model,
	})

	local grip = Util.Part({
		Name = "Grip",
		Size = Vector3.new(0.35, 0.9, 0.5),
		CFrame = body.CFrame * CFrame.new(0, -0.5, length * 0.3),
		Color = Color3.fromRGB(48, 42, 38),
		Material = Enum.Material.Wood,
		Anchored = false,
		CanCollide = false,
		Massless = true,
		Parent = model,
	})
	Util.Weld(body, grip)

	if spec.Category == "Sniper" then
		local scope = Util.Part({
			Name = "Scope",
			Size = Vector3.new(0.3, 0.3, 1.4),
			CFrame = body.CFrame * CFrame.new(0, 0.45, 0.4),
			Color = Color3.fromRGB(24, 24, 26),
			Material = Enum.Material.Metal,
			Anchored = false,
			CanCollide = false,
			Massless = true,
			Parent = model,
		})
		Util.Weld(body, scope)
	end

	Util.Weld(hand, body)
	model.Parent = character
end

WeaponService.UpdateHeldWeapon = updateHeldWeapon

--[[ Everything a shot from this player should pass straight through. ]]
local function ignoreListFor(player: Player): { Instance }
	local ignore: { Instance } = {}
	if player.Character then
		table.insert(ignore, player.Character)
	end
	local state = PlayerState.Get(player)
	if state.vehicle and state.vehicle.Parent then
		table.insert(ignore, state.vehicle)
	end
	return ignore
end

--[[ One hitscan pellet: cast, damage whatever it found, draw the line. ]]
local function fireHitscanRay(player: Player, spec: Config.WeaponSpec, origin: Vector3, direction: Vector3)
	local params = Util.RayParams(ignoreListFor(player))
	local result = workspace:Raycast(origin, direction * spec.Range, params)

	local endPoint = if result then result.Position else origin + direction * spec.Range
	broadcastShot(
		player,
		origin + direction * 2,
		endPoint,
		spec,
		if result then result.Normal else nil
	)

	if not result then
		return
	end

	-- Shooting a giant animal does not hurt it, but it does annoy it.
	-- Fairground props first: they are neither people nor vehicles.
	if CarnivalService.RegisterHit(result.Instance, player, direction) then
		return
	end

	-- The puck. Shooting it is how you play hockey here -- a rifle makes a
	-- perfectly good stick and there is no stick-handling simulation to get
	-- in the way of it.
	if HockeyService.RegisterHit(result.Instance, player, direction) then
		return
	end

	-- The basketball. A rifle makes a perfectly good pass.
	if BasketballService.RegisterHit(result.Instance, player, direction) then
		return
	end

	-- A gas can. Shootable by every weapon in the game, including by
	-- accident, which is most of the fun of it.
	if FireService.RegisterHit(result.Instance, player) then
		return
	end

	if WildlifeService.RegisterHit(result.Instance, spec.Damage, player) then
		return
	end

	local humanoid, character = Util.HumanoidFromHit(result.Instance)
	if humanoid and character then
		local victim = Players:GetPlayerFromCharacter(character)
		if victim and victim ~= player then
			-- Headshots hurt more, because they should.
			local damage = spec.Damage
			local headshot = result.Instance.Name == "Head"
			if headshot then
				damage *= Config.Movement.HeadshotMultiplier
			end
			--[[
				A stick to the body on the ice starts a scrap.

				Blades of Steel: you catch somebody with the stick, it turns
				into a fight, and the winner may break the stick over them.
				It only triggers on the rink -- a stick swung in the street
				is just a stick -- and the damage still lands either way.
			]]
			-- Compared by identity against the config entries, because this
			-- function is handed the spec rather than the weapon's name.
			local isStick = spec == Config.Weapons[Config.Hockey.StickWeapon]
				or spec == Config.Weapons[Config.Hockey.BrokenStickWeapon]
			if isStick
				and HockeyService.OnIce(player)
				and HockeyService.OnIce(victim)
			then
				HockeyService.StartFight(player, victim)
			end

			if DamageService.ApplyDamage(victim, damage, player, spec.DisplayName) then
				-- Tell the shooter they connected. Without this, hitscan guns
				-- give you nothing at all to tell you whether you are aiming
				-- anywhere near the target.
				Remotes.Event("Hitmarker"):FireClient(player, {
					damage = math.floor(damage),
					headshot = headshot,
					position = result.Position,
				})

				--[[
					The medal is for a headshot KILL, not a headshot.

					Awarded here rather than from the death handler because
					this is the only place that knows WHERE the shot landed
					-- by the time a death is reported, the part that was hit
					is long gone. Checked after the damage, so grazing
					somebody's head for the last of their shield does not
					count.
				]]
				if headshot and humanoid.Health <= 0 then
					MedalService.Award(player, "Headshot")
				end
			end
			return
		end
	end

	local vehicle = VehicleService.FromPart(result.Instance)
	if vehicle then
		VehicleService.Damage(vehicle, spec.Damage * (spec.VehicleDamageMultiplier or 1), player)
	end

	-- Some guns go bang on impact even when they hit a wall.
	if (spec.BlastRadius or 0) > 0 then
		DamageService.Explode(
			result.Position,
			spec.BlastRadius or 0,
			spec.BlastDamage or 0,
			player,
			spec.VehicleDamageMultiplier
		)
	end
end

--[[
	Where a player's shots come from.

	On foot that is their head. In a gunner seat it is the muzzle on the end of
	the vehicle's barrel, so the 50 cal fires from the 50 cal and not from the
	gunner's forehead.
]]
local function muzzleFor(player: Player): Vector3?
	local state = PlayerState.Get(player)

	if state.vehicle and state.vehicle.Parent then
		local isMountedUser = state.seatRole == "Gunner"
			or (state.seatRole == "Driver" and state.vehicle:GetAttribute("VehicleKind") == "Plane")
		if isMountedUser then
			local barrel = state.vehicle:FindFirstChild("Barrel", true)
			if barrel and barrel:IsA("BasePart") then
				local muzzle = barrel:FindFirstChild("Muzzle")
				if muzzle and muzzle:IsA("Attachment") then
					return muzzle.WorldPosition
				end
				return barrel.Position
			end
		end
	end

	local character = player.Character
	if not character then
		return nil
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position
	end
	return nil
end

--[[ Which gun this player is actually holding right now. ]]
local function equippedWeaponName(player: Player): string
	local state = PlayerState.Get(player)

	-- The `.Parent` checks matter: a vehicle destroyed under a seated player
	-- leaves state.vehicle pointing at it. Without them the player keeps the
	-- tank cannon after the tank is gone, and muzzleFor -- which does check
	-- Parent -- falls back to their head, so they walk around firing a tank
	-- cannon out of their face.
	if state.vehicle and state.vehicle.Parent and state.seatRole == "Gunner" then
		local mounted = state.vehicle:GetAttribute("MountedWeapon")
		if typeof(mounted) == "string" and Config.Weapons[mounted] then
			return mounted
		end
	end
	-- A plane's pilot has the wing guns.
	if state.vehicle and state.vehicle.Parent and state.seatRole == "Driver" then
		local kind = state.vehicle:GetAttribute("VehicleKind")
		if kind == "Plane" then
			local mounted = state.vehicle:GetAttribute("MountedWeapon")
			if typeof(mounted) == "string" and Config.Weapons[mounted] then
				return mounted
			end
		end
	end

	return state.equipped
end

--[[ Start a reload if the magazine is empty and one is not already running. ]]
local function beginReload(player: Player, weaponName: string)
	local state = PlayerState.Get(player)
	local slot = state.weapons[weaponName]
	local spec = Config.Weapons[weaponName]
	if not slot or not spec then
		return
	end
	if slot.reloadingUntil > os.clock() or slot.ammo >= spec.MagSize then
		return
	end
	if Config.InfiniteAmmo then
		return
	end
	-- Poop and drones do not reload. What you scavenged is what you have.
	if spec.AmmoFromPickupsOnly then
		return
	end

	local expectedUntil = os.clock() + spec.ReloadTime
	slot.reloadingUntil = expectedUntil
	PlayerState.Changed.Fire(player)

	task.delay(spec.ReloadTime, function()
		if not player.Parent then
			return
		end
		local current = PlayerState.Get(player)
		local currentSlot = current.weapons[weaponName]
		if currentSlot and currentSlot.reloadingUntil == expectedUntil then
			currentSlot.ammo = spec.MagSize
			currentSlot.reloadingUntil = 0
			PlayerState.Changed.Fire(player)
		end
	end)
end

--[[
	The trigger. Everything the client asked for is treated as a request, not
	an instruction — the checks below are what actually decide.
]]
--[[
	Fire one named weapon.

	Split out from the fire handler so the dedicated grenade key can throw a
	grenade without the player having to switch weapons for it -- which is
	how Halo's grenade button worked, and the reason you could throw one
	mid-fight without giving up your rifle.
]]
local function fireWeapon(player: Player, weaponName: string, requestedDirection: any)
	-- NaN slips past a magnitude check, because every comparison involving
	-- NaN is false. Util.SaneDirection is the only guard here that actually
	-- rejects it, and it hands back the normalised vector so nothing
	-- downstream has to remember to do that.
	local direction = Util.SaneDirection(requestedDirection)
	if not direction then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local spec = Config.Weapons[weaponName]
	if not spec then
		return
	end

	--[[
		There is no state in this game that takes your guns away.

		This used to check WildlifeService.IsRiding, left over from when you
		could ride a giant animal and the animal was the weapon. The animals
		became zombies and the function has returned false ever since, so it
		was a gate that did nothing -- but it was also a gate pointing the
		wrong way. The game is a shooter with sports scattered through it:
		tubing the lazy river, skiing the mountain, flying a glider, playing
		hockey. You are armed in all of them, always, and nothing new should
		ever be allowed to quietly change that. Config.WeaponsAlwaysAvailable
		says so and a test enforces it.
	]]

	local state = PlayerState.Get(player)
	local slot = state.weapons[weaponName]
	if not slot then
		return
	end

	local now = os.clock()
	if now < slot.nextFireAt then
		return
	end
	if now < slot.reloadingUntil then
		return
	end
	if not Config.InfiniteAmmo and slot.ammo <= 0 then
		beginReload(player, weaponName)
		return
	end

	local origin = muzzleFor(player)
	if not origin then
		return
	end

	-- A mounted gun cannot be carried around on foot, and a wrecked vehicle
	-- is not a vehicle.
	if spec.MountedOnly and not (state.vehicle and state.vehicle.Parent) then
		return
	end

	--[[
		Is the client shooting roughly where it is looking?

		Config.Combat.AutoAimServerToleranceDegrees has claimed since it was
		written that "the server re-checks aim against this wider cone before
		trusting a shot". It did not. Nothing checked the direction against
		the character at all, so a hostile client could send a vector
		pointing straight at somebody behind them and the server would
		happily trace it -- a silent 360-degree aimbot, needing no more than
		one line in a console.

		The cone is deliberately generous. It has to cover the client's own
		auto-aim snap, the gunner seats, and a few frames of latency between
		the client aiming and the server looking. It is not there to make
		aiming hard; it is there to make "behind me" impossible.
	]]
	local aimReference: Vector3? = nil
	if state.vehicle and state.vehicle.Parent and spec.MountedOnly then
		local barrel = state.vehicle:FindFirstChild("Barrel", true)
		if barrel and barrel:IsA("BasePart") then
			aimReference = barrel.CFrame.LookVector
		end
	end
	if not aimReference and humanoid.RootPart then
		local head = character and character:FindFirstChild("Head")
		aimReference = if head and head:IsA("BasePart")
			then head.CFrame.LookVector
			else humanoid.RootPart.CFrame.LookVector
	end

	if aimReference and aimReference.Magnitude > 0.001 then
		local tolerance = Config.Combat.AutoAimServerToleranceDegrees
		if Util.AngleBetween(aimReference, direction) > tolerance * 3.4 then
			return
		end
	end

	if spec.AmmoFromPickupsOnly and slot.ammo <= 0 then
		return
	end

	slot.nextFireAt = now + spec.Cooldown
	if (not Config.InfiniteAmmo) or spec.AmmoFromPickupsOnly then
		slot.ammo = math.max(0, slot.ammo - 1)
	end

	-- Fries give you three barrels for a while; normally this is just one.
	local barrels = PlayerState.BarrelCount(player)
	local barrelSpread = Config.Pickups.Fries.SpreadDegrees

	for barrel = 1, barrels do
		local barrelDirection = direction
		if barrels > 1 then
			local offset = (barrel - (barrels + 1) * 0.5) * barrelSpread
			barrelDirection = (Util.LookAt(Vector3.zero, direction) * CFrame.Angles(0, math.rad(offset), 0)).LookVector
		end

		if spec.Kind == "Hitscan" then
			for _ = 1, (spec.Pellets or 1) do
				fireHitscanRay(player, spec, origin, Util.ApplySpread(barrelDirection, spec.Spread, rng))
			end
		elseif spec.Kind == "Arcing" then
			-- Lobbed, so aim a little above where you pointed.
			local lobbed = (barrelDirection + Vector3.new(0, 0.35, 0)).Unit
			ProjectileService.Spawn(player, weaponName, origin, lobbed, ignoreListFor(player))
		else
			ProjectileService.Spawn(
				player,
				weaponName,
				origin,
				Util.ApplySpread(barrelDirection, spec.Spread, rng),
				ignoreListFor(player)
			)
		end
	end

	if not Config.InfiniteAmmo and slot.ammo <= 0 then
		beginReload(player, weaponName)
	end

	PlayerState.Changed.Fire(player)
end

local function handleFire(player: Player, requestedDirection: any)
	fireWeapon(player, equippedWeaponName(player), requestedDirection)
end

--[[
	The dedicated grenade key.

	Throws without changing what is in your hands, and shares the grenade's
	own cooldown with the slot, so holding the key cannot out-throw equipping
	the grenade and spamming fire.
]]
local function handleThrowGrenade(player: Player, requestedDirection: any)
	local weaponName = Config.GrenadeKeyWeapon

	-- A dedicated key has to work whatever is in your loadout. Picking up a
	-- weapon can take the grenade's slot, and a grenade button that silently
	-- stops working is worse than not having one.
	local state = PlayerState.Get(player)
	if not state.weapons[weaponName] then
		local spec = Config.Weapons[weaponName]
		if not spec then
			return
		end
		state.weapons[weaponName] = {
			ammo = spec.MagSize,
			reloadingUntil = 0,
			nextFireAt = 0,
		}
	end

	fireWeapon(player, weaponName, requestedDirection)
end

--[[ Swap guns. In free mode every gun in the config is yours from the start. ]]
local function handleEquip(player: Player, weaponName: any)
	if typeof(weaponName) ~= "string" then
		return
	end
	local spec = Config.Weapons[weaponName]
	if not spec or spec.MountedOnly then
		return
	end

	local state = PlayerState.Get(player)
	state.equipped = weaponName
	updateHeldWeapon(player)
	PlayerState.Changed.Fire(player)
end

--[[ The F key. Costs a charge, and only if something was actually in the air. ]]
local function handleMegaDetonate(player: Player)
	local state = PlayerState.Get(player)
	if state.megaCharges <= 0 then
		return
	end
	if not ProjectileService.HasLiveDiamond(player) then
		return
	end

	if ProjectileService.MegaDetonate(player) then
		state.megaCharges -= 1
		PlayerState.Changed.Fire(player)
	end
end

--[[
	Melee, on Q.

	Halo's close-range rhythm: shoot the shields off, then finish with a hit.
	Catch somebody facing away and it kills outright, which is what makes
	circling behind people worth the risk.
]]
local function handleMelee(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	-- You cannot punch from the driver's seat of a tank.
	if humanoid.SeatPart then
		return
	end

	local state = PlayerState.Get(player)
	local now = os.clock()
	if now < state.nextMeleeAt then
		return
	end
	state.nextMeleeAt = now + Config.Melee.Cooldown

	Sound.At("MeleeSwing", root.Position)

	local facing = root.CFrame.LookVector
	local best: Player? = nil
	local bestDistance = Config.Melee.Range

	for _, other in Players:GetPlayers() do
		if other == player then
			continue
		end
		if other.Team and player.Team and other.Team == player.Team then
			continue
		end
		local otherCharacter = other.Character
		local otherRoot = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
		if not otherRoot or not otherRoot:IsA("BasePart") then
			continue
		end

		-- Dead men cannot be knifed again.
		local otherHumanoid = otherCharacter and otherCharacter:FindFirstChildOfClass("Humanoid")
		if not otherHumanoid or otherHumanoid.Health <= 0 then
			continue
		end

		local toTarget = otherRoot.Position - root.Position
		local distance = toTarget.Magnitude
		-- Has to be in front of you, not merely nearby.
		if distance <= bestDistance and Util.AngleBetween(facing, toTarget) < 70 then
			-- And you have to be able to reach them. Distance and a cone
			-- alone let you knife somebody through a solid wall, which at
			-- nine studs of range happens constantly in a city map full of
			-- two-stud partitions.
			local blocked = workspace:Raycast(
				root.Position,
				toTarget,
				Util.RayParams({ character, otherCharacter })
			)
			if not blocked then
				best = other
				bestDistance = distance
			end
		end
	end

	if not best then
		return
	end

	local victimCharacter = best.Character
	local victimRoot = victimCharacter and victimCharacter:FindFirstChild("HumanoidRootPart")
	local damage = Config.Melee.Damage

	if victimRoot and victimRoot:IsA("BasePart") then
		-- Both facing the same way means you are behind them.
		local alignment = Util.AngleBetween(facing, victimRoot.CFrame.LookVector)
		if alignment < Config.Melee.BackstabArc then
			damage *= Config.Melee.BackstabMultiplier
		end
	end

	Sound.At("MeleeHit", root.Position)
	if DamageService.ApplyDamage(best, damage, player, "Melee") then
		Remotes.Event("Hitmarker"):FireClient(player, {
			damage = math.floor(damage),
			headshot = damage > Config.Melee.Damage,
			position = root.Position,
		})
	end
end

--[[ Gunners tell the server where they are looking; the turret follows. ]]
local function handleAim(player: Player, worldTarget: any)
	-- A NaN here reached HingeConstraint.TargetAngle, which is a poisoned
	-- turret that no longer responds to anything.
	if not Util.IsSaneVector(worldTarget) then
		return
	end
	local state = PlayerState.Get(player)
	if state.vehicle and state.vehicle.Parent and state.seatRole == "Gunner" then
		VehicleService.AimTurret(state.vehicle, worldTarget)
	end
end

function WeaponService.Start()
	-- Everyone spawns holding something.
	local function armOnSpawn(player: Player)
		player.CharacterAdded:Connect(function()
			task.wait(0.5)
			updateHeldWeapon(player)
		end)
		if player.Character then
			task.spawn(function()
				task.wait(0.5)
				updateHeldWeapon(player)
			end)
		end
	end

	Players.PlayerAdded:Connect(armOnSpawn)
	for _, player in Players:GetPlayers() do
		armOnSpawn(player)
	end

	Remotes.Event("FireWeapon").OnServerEvent:Connect(function(player, direction)
		handleFire(player, direction)
	end)

	Remotes.Event("SetScoped").OnServerEvent:Connect(function(player, on)
		VehicleService.SetScoped(player, on == true)
	end)

	Remotes.Event("ThrowGrenade").OnServerEvent:Connect(function(player, direction)
		handleThrowGrenade(player, direction)
	end)

	Remotes.Event("EquipWeapon").OnServerEvent:Connect(function(player, weaponName)
		handleEquip(player, weaponName)
	end)

	Remotes.Event("Reload").OnServerEvent:Connect(function(player)
		beginReload(player, equippedWeaponName(player))
	end)

	Remotes.Event("MegaDetonate").OnServerEvent:Connect(function(player)
		handleMegaDetonate(player)
	end)

	Remotes.Event("SetAimDirection").OnServerEvent:Connect(function(player, worldTarget)
		handleAim(player, worldTarget)
	end)

	Remotes.Event("SetTurbo").OnServerEvent:Connect(function(player, on)
		VehicleService.SetTurbo(player, on == true)
	end)

	Remotes.Event("Melee").OnServerEvent:Connect(function(player)
		handleMelee(player)
	end)

	Remotes.Event("Eject").OnServerEvent:Connect(function(player)
		task.spawn(VehicleService.Eject, player)
	end)

	Remotes.Event("SetPedal").OnServerEvent:Connect(function(player, value)
		if typeof(value) == "number" and value == value and math.abs(value) < math.huge then
			VehicleService.SetPedal(player, value)
		end
	end)

	--[[
		The off-road fittings.

		Each one checks the vehicle actually has the fitting rather than
		trusting the client to only send what it was offered: the action bar
		hides a key the vehicle has no fitting for, but a hidden key is a
		presentation choice, not a permission.
	]]
	Remotes.Event("CycleDriveMode").OnServerEvent:Connect(function(player)
		VehicleService.CycleDriveMode(player)
	end)

	Remotes.Event("ToggleDiffLock").OnServerEvent:Connect(function(player)
		VehicleService.ToggleDiffLock(player)
	end)

	Remotes.Event("ToggleWinch").OnServerEvent:Connect(function(player)
		VehicleService.ToggleWinch(player)
	end)

	Remotes.Event("ReelWinch").OnServerEvent:Connect(function(player, on)
		VehicleService.ReelWinch(player, on == true)
	end)

	Remotes.Event("ShoveBoost").OnServerEvent:Connect(function(player)
		VehicleService.ShoveBoost(player)
	end)

	-- The client asks once at join for the full gun list, so the weapon wheel
	-- can build itself without every gun being hard-coded twice.
	Remotes.Function("GetArsenal").OnServerInvoke = function(_player)
		-- Mounted guns are included but flagged. The client needs to know how
		-- the 50 cal behaves while you are sitting behind it, even though it
		-- must never appear in the weapon wheel.
		local arsenal = {}
		for name, spec in Config.Weapons do
			arsenal[name] = {
				Slot = spec.Slot,
				Category = spec.Category,
				DisplayName = spec.DisplayName,
				MagSize = spec.MagSize,
				Automatic = spec.Automatic == true,
				ZoomFov = spec.ZoomFov,
				AutoAim = spec.AutoAim == true,
				CanMegaDetonate = spec.CanMegaDetonate == true,
				MountedOnly = spec.MountedOnly == true,
			}
		end
		return arsenal
	end
end

--[[ What a player currently has in their hands, for tests. ]]
function WeaponService.EquippedForTests(player: Player): string
	return equippedWeaponName(player)
end

--[[ Unused for now, but kept so the origin check has a home when we tighten it. ]]
function WeaponService.MaxOriginDrift(): number
	return MAX_ORIGIN_DRIFT
end

return WeaponService
