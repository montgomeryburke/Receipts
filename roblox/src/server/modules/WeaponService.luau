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
local Util = require(Shared:WaitForChild("Util"))

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local DamageService = require(script.Parent:WaitForChild("DamageService"))
local ProjectileService = require(script.Parent:WaitForChild("ProjectileService"))
local VehicleService = require(script.Parent:WaitForChild("VehicleService"))

local WeaponService = {}

-- How far from a player's own body a shot is allowed to claim to start.
-- Generous enough for lag and long gun barrels, tight enough to stop somebody
-- firing from the other side of the map.
local MAX_ORIGIN_DRIFT = 30

local rng = Random.new()

--[[ Draw a quick line where a hitscan shot went, so shooting looks like shooting. ]]
local function drawTracer(from: Vector3, to: Vector3, color: Color3)
	local delta = to - from
	local length = delta.Magnitude
	if length < 0.5 then
		return
	end

	local tracer = Util.Part({
		Name = "Tracer",
		Size = Vector3.new(0.22, 0.22, length),
		CFrame = CFrame.lookAt(from + delta * 0.5, to),
		Color = color,
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Transparency = 0.35,
		Parent = workspace,
	})
	Debris:AddItem(tracer, 0.08)
end

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
	drawTracer(origin, endPoint, spec.Color)

	if not result then
		return
	end

	local humanoid, character = Util.HumanoidFromHit(result.Instance)
	if humanoid and character then
		local victim = Players:GetPlayerFromCharacter(character)
		if victim and victim ~= player then
			-- Headshots hurt more, because they should.
			local damage = spec.Damage
			if result.Instance.Name == "Head" then
				damage *= 1.8
			end
			DamageService.ApplyDamage(victim, damage, player, spec.DisplayName)
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
		local barrel = state.vehicle:FindFirstChild("Barrel", true)
		if barrel and barrel:IsA("BasePart") then
			local muzzle = barrel:FindFirstChild("Muzzle")
			if muzzle and muzzle:IsA("Attachment") then
				return muzzle.WorldPosition
			end
			return barrel.Position
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

	-- Sitting on a mounted gun overrides whatever you were carrying.
	if state.vehicle and state.seatRole == "Gunner" then
		local mounted = state.vehicle:GetAttribute("MountedWeapon")
		if typeof(mounted) == "string" and Config.Weapons[mounted] then
			return mounted
		end
	end
	-- A plane's pilot has the wing guns.
	if state.vehicle and state.seatRole == "Driver" then
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
	-- Poop and drones do not reload. What you scavenged is what you have.
	if spec.AmmoFromPickupsOnly then
		return
	end

	slot.reloadingUntil = os.clock() + spec.ReloadTime
	PlayerState.Changed.Fire(player)

	task.delay(spec.ReloadTime, function()
		local current = PlayerState.Get(player)
		local currentSlot = current.weapons[weaponName]
		if currentSlot then
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
local function handleFire(player: Player, requestedDirection: any)
	if typeof(requestedDirection) ~= "Vector3" then
		return
	end
	if requestedDirection.Magnitude < 0.001 then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local weaponName = equippedWeaponName(player)
	local spec = Config.Weapons[weaponName]
	if not spec then
		return
	end

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
	if slot.ammo <= 0 then
		beginReload(player, weaponName)
		return
	end

	local origin = muzzleFor(player)
	if not origin then
		return
	end

	-- A mounted gun cannot be carried around on foot.
	if spec.MountedOnly and not state.vehicle then
		return
	end

	slot.nextFireAt = now + spec.Cooldown
	slot.ammo -= 1

	local direction = requestedDirection.Unit

	-- Fries give you three barrels for a while; normally this is just one.
	local barrels = PlayerState.BarrelCount(player)
	local barrelSpread = Config.Pickups.Fries.SpreadDegrees

	for barrel = 1, barrels do
		local barrelDirection = direction
		if barrels > 1 then
			-- Fan the extra barrels out evenly either side of where you aimed.
			local offset = (barrel - (barrels + 1) * 0.5) * barrelSpread
			barrelDirection = (CFrame.new(Vector3.zero, direction) * CFrame.Angles(0, math.rad(offset), 0)).LookVector
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

	if slot.ammo <= 0 then
		beginReload(player, weaponName)
	end

	PlayerState.Changed.Fire(player)
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
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	local state = PlayerState.Get(player)
	local now = os.clock()
	if now < state.nextMeleeAt then
		return
	end
	state.nextMeleeAt = now + Config.Melee.Cooldown

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

		local toTarget = otherRoot.Position - root.Position
		local distance = toTarget.Magnitude
		-- Has to be in front of you, not merely nearby.
		if distance <= bestDistance and Util.AngleBetween(facing, toTarget) < 70 then
			best = other
			bestDistance = distance
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

	DamageService.ApplyDamage(best, damage, player, "Melee")
end

--[[ Gunners tell the server where they are looking; the turret follows. ]]
local function handleAim(player: Player, worldTarget: any)
	if typeof(worldTarget) ~= "Vector3" then
		return
	end
	local state = PlayerState.Get(player)
	if state.vehicle and state.vehicle.Parent and state.seatRole == "Gunner" then
		VehicleService.AimTurret(state.vehicle, worldTarget)
	end
end

function WeaponService.Start()
	Remotes.Event("FireWeapon").OnServerEvent:Connect(function(player, direction)
		handleFire(player, direction)
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

	Remotes.Event("SetPedal").OnServerEvent:Connect(function(player, value)
		if typeof(value) == "number" then
			VehicleService.SetPedal(player, value)
		end
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

--[[ Unused for now, but kept so the origin check has a home when we tighten it. ]]
function WeaponService.MaxOriginDrift(): number
	return MAX_ORIGIN_DRIFT
end

return WeaponService
