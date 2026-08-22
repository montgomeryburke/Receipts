--!strict
--[[
	ProjectileService — everything that leaves a barrel and travels.

	Projectiles are simulated by the server, one raycast per frame along the
	path they just covered. That is deliberate: it means the server decides
	every hit, so nobody can fake a kill by editing their own game.

	The star of the show is the nuclear diamond bullet. It does not stop when
	it hits something — it detonates, keeps going, and detonates again at the
	next thing, up to Pierces times. Press F while it is still in the air and
	the next blast is ten times the size.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Util = require(Shared:WaitForChild("Util"))

local DamageService = require(script.Parent:WaitForChild("DamageService"))
local VehicleService = require(script.Parent:WaitForChild("VehicleService"))
local WildlifeService = require(script.Parent:WaitForChild("WildlifeService"))
local CarnivalService = require(script.Parent:WaitForChild("CarnivalService"))

local ProjectileService = {}

local GRAVITY = Vector3.new(0, -75, 0)
local MAX_LIFETIME = 12

type Projectile = {
	owner: Player,
	weaponName: string,
	spec: Config.WeaponSpec,
	part: BasePart,
	position: Vector3,
	velocity: Vector3,
	piercesLeft: number,
	bornAt: number,
	-- Grenades only.
	fuseAt: number?,
	-- Drones only: who it is chasing.
	target: BasePart?,
	stuck: boolean,
	dead: boolean,
	-- Everything this projectile is not allowed to hit (the shooter, their car).
	ignore: { Instance },
}

local live: { Projectile } = {}

--[[ A small glowing part so players can actually see what is flying at them. ]]
local function makeVisual(spec: Config.WeaponSpec, position: Vector3, isDiamond: boolean): BasePart
	local part = Util.Part({
		Name = "Projectile",
		Size = if isDiamond then Vector3.new(1.4, 1.4, 2.6) else Vector3.new(0.5, 0.5, 1.8),
		CFrame = CFrame.new(position),
		Color = spec.Color,
		Material = if isDiamond then Enum.Material.Neon else Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Anchored = true,
		Parent = workspace,
	})

	if isDiamond then
		local light = Instance.new("PointLight")
		light.Color = spec.Color
		light.Range = 18
		light.Brightness = 3
		light.Parent = part
	end

	local trail = Instance.new("Trail")
	local a0 = Util.Attachment(part, Vector3.new(0, 0, 0.6), "TrailA")
	local a1 = Util.Attachment(part, Vector3.new(0, 0, -0.6), "TrailB")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.35
	trail.Color = ColorSequence.new(spec.Color)
	trail.WidthScale = NumberSequence.new(1, 0)
	trail.Parent = part

	return part
end

--[[ Stop simulating a projectile and clean its part up. ]]
local function retire(projectile: Projectile)
	if projectile.dead then
		return
	end
	projectile.dead = true
	if projectile.part and projectile.part.Parent then
		-- A moment of grace so the trail can finish drawing.
		projectile.part.Transparency = 1
		Debris:AddItem(projectile.part, 0.4)
	end
end

--[[
	Set one off. `scale` is 1 for a normal blast and 10 for a mega-detonation.
]]
local function detonate(projectile: Projectile, position: Vector3, scale: number)
	local spec = projectile.spec
	local radius = (spec.BlastRadius or 0) * scale
	local damage = (spec.BlastDamage or 0) * scale

	if radius > 0 then
		DamageService.Explode(
			position, radius, damage,
			projectile.owner, spec.VehicleDamageMultiplier,
			-- Only a mega-detonation counts as one, and only that is big
			-- enough to put a giant animal down.
			scale > 1
		)
		-- A big enough blast leaves a mark in the mud.
		if scale > 1 then
			DamageService.Crater(position, radius * 0.5)
		end
	end
end

--[[ Direct damage to whatever the projectile physically ran into. ]]
local function applyDirectHit(projectile: Projectile, hitPart: BasePart)
	local spec = projectile.spec

	-- Giant animals shrug off anything that is not a mega-detonation.
	-- Fairground props first: they are neither people nor vehicles.
	if CarnivalService.RegisterHit(hitPart, projectile.owner) then
		return
	end

	if WildlifeService.RegisterHit(hitPart, spec.Damage, projectile.owner) then
		return
	end

	local humanoid, character = Util.HumanoidFromHit(hitPart)
	if humanoid and character then
		local victim = Players:GetPlayerFromCharacter(character)
		if victim and victim ~= projectile.owner then
			DamageService.ApplyDamage(victim, spec.Damage, projectile.owner, spec.DisplayName)

			-- Poop does barely any damage; the point is that they cannot see.
			if spec.Splat then
				Remotes.Event("PlayEffect"):FireClient(victim, {
					effect = "Splat",
					duration = Config.Wildlife.SplatDuration,
				})
				Remotes.Event("Notify"):FireClient(projectile.owner, "Direct hit. Disgusting.")
			end
			return
		end
	end

	local vehicle = VehicleService.FromPart(hitPart)
	if vehicle then
		VehicleService.Damage(
			vehicle,
			spec.Damage * (spec.VehicleDamageMultiplier or 1),
			projectile.owner
		)
	end
end

--[[
	Advance one projectile by one frame.

	The loop inside handles piercing: after a diamond bullet punches through
	something it still has travel left this frame, so we keep casting from the
	far side of what it just went through until it either runs out of pierces
	or runs out of frame.
]]
local function stepProjectile(projectile: Projectile, deltaTime: number)
	local spec = projectile.spec
	local kind = spec.Kind

	if projectile.stuck then
		return
	end

	-- Grenades and anything else lobbed feel gravity.
	if kind == "Arcing" then
		projectile.velocity += GRAVITY * deltaTime
	end

	-- A drone steers itself. It does not fall, and it does not give up.
	if kind == "Homing" then
		local target = projectile.target
		if target and target.Parent then
			local toTarget = target.Position - projectile.position
			if toTarget.Magnitude > 0.1 then
				local wanted = toTarget.Unit * projectile.velocity.Magnitude
				-- Turn toward the target at a limited rate, so it arcs round
				-- rather than snapping onto them instantly.
				local turnRate = (spec.HomingTurnRate or 3) * deltaTime
				projectile.velocity = (projectile.velocity + (wanted - projectile.velocity) * math.min(1, turnRate)).Unit
					* projectile.velocity.Magnitude
			end
		end
	end

	local remainingTravel = projectile.velocity * deltaTime
	local params = Util.RayParams(projectile.ignore)

	-- Up to a handful of casts per frame, one per thing pierced.
	for _ = 1, 10 do
		local distance = remainingTravel.Magnitude
		if distance < 0.001 then
			break
		end

		local result = workspace:Raycast(projectile.position, remainingTravel, params)
		if not result then
			projectile.position += remainingTravel
			break
		end

		local hitPoint = result.Position
		applyDirectHit(projectile, result.Instance)

		if kind == "Rocket" or kind == "Homing" then
			detonate(projectile, hitPoint, 1)
			retire(projectile)
			return
		end

		if kind == "Arcing" then
			if spec.Sticky then
				-- Sticky bombs stop dead where they land and wait for the fuse.
				projectile.stuck = true
				projectile.position = hitPoint + result.Normal * 0.5
				projectile.part.CFrame = CFrame.new(projectile.position)
				return
			end
			-- Ordinary grenades bounce, losing most of their energy.
			projectile.position = hitPoint + result.Normal * 0.4
			projectile.velocity = (projectile.velocity - 2 * projectile.velocity:Dot(result.Normal) * result.Normal) * 0.4
			return
		end

		-- Bullets. Diamond rounds detonate at every surface they punch through.
		if (spec.BlastRadius or 0) > 0 then
			detonate(projectile, hitPoint, 1)
		end

		if projectile.piercesLeft <= 0 then
			retire(projectile)
			return
		end

		projectile.piercesLeft -= 1

		-- Step out the far side of what we just pierced and carry on with
		-- whatever distance was left over this frame.
		local travelled = (hitPoint - projectile.position).Magnitude
		local direction = remainingTravel.Unit
		projectile.position = hitPoint + direction * 0.6
		remainingTravel = direction * math.max(0, distance - travelled - 0.6)
	end

	-- Point the visible part along the direction of travel.
	if projectile.velocity.Magnitude > 0.01 then
		projectile.part.CFrame = CFrame.lookAt(projectile.position, projectile.position + projectile.velocity)
	else
		projectile.part.CFrame = CFrame.new(projectile.position)
	end
end

--[[ Every live projectile gets a frame. ]]
local function step(deltaTime: number)
	local now = os.clock()

	for index = #live, 1, -1 do
		local projectile = live[index]

		if projectile.dead then
			table.remove(live, index)
			continue
		end

		-- Grenade fuses run whether the grenade is moving or wedged in a wall.
		if projectile.fuseAt and now >= projectile.fuseAt then
			detonate(projectile, projectile.position, 1)
			retire(projectile)
			table.remove(live, index)
			continue
		end

		if now - projectile.bornAt > MAX_LIFETIME then
			retire(projectile)
			table.remove(live, index)
			continue
		end

		stepProjectile(projectile, deltaTime)
	end
end

--[[
	Fire one projectile. Returns it so the caller can hold on to a diamond
	round for a possible mega-detonation.
]]
function ProjectileService.Spawn(
	owner: Player,
	weaponName: string,
	origin: Vector3,
	direction: Vector3,
	ignore: { Instance }
)
	local spec = Config.Weapons[weaponName]
	if not spec then
		return
	end

	local speed = spec.Speed or 300
	local isDiamond = spec.CanMegaDetonate == true

	--[[
		A drone locks on at launch: the enemy nearest to where you aimed.
		After that it is on its own — it will follow them round corners until
		it catches them or its battery dies.
	]]
	local lockedTarget: BasePart? = nil
	if spec.Kind == "Homing" then
		local bestAngle = 50
		for _, other in Players:GetPlayers() do
			if other == owner then
				continue
			end
			if other.Team and owner.Team and other.Team == owner.Team then
				continue
			end
			local character = other.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
				local toTarget = root.Position - origin
				if toTarget.Magnitude <= spec.Range then
					local angle = Util.AngleBetween(direction, toTarget)
					if angle < bestAngle then
						bestAngle = angle
						lockedTarget = root
					end
				end
			end
		end

		if lockedTarget then
			Remotes.Event("Notify"):FireClient(owner, "Drone locked on.")
		else
			Remotes.Event("Notify"):FireClient(owner, "Drone launched — no lock.")
		end
	end

	local projectile: Projectile = {
		owner = owner,
		weaponName = weaponName,
		spec = spec,
		part = makeVisual(spec, origin, isDiamond),
		position = origin,
		velocity = direction.Unit * speed,
		piercesLeft = spec.Pierces or 0,
		bornAt = os.clock(),
		fuseAt = if spec.Kind == "Homing"
			then os.clock() + (spec.HomingLifetime or 12)
			elseif spec.FuseTime and spec.FuseTime > 0 then os.clock() + spec.FuseTime
			else nil,
		target = lockedTarget,
		stuck = false,
		dead = false,
		ignore = ignore,
	}

	table.insert(live, projectile)
end

--[[
	The F key. Finds this player's newest diamond round still in the air and
	sets it off ten times harder wherever it happens to be.

	Returns true if something actually went bang, so the caller knows whether
	to spend one of the player's charges.
]]
function ProjectileService.MegaDetonate(player: Player): boolean
	for index = #live, 1, -1 do
		local projectile = live[index]
		if projectile.owner == player
			and not projectile.dead
			and projectile.spec.CanMegaDetonate
		then
			detonate(projectile, projectile.position, Config.Mega.Multiplier)
			retire(projectile)
			table.remove(live, index)
			return true
		end
	end
	return false
end

--[[ Does this player have anything in the air worth detonating? ]]
function ProjectileService.HasLiveDiamond(player: Player): boolean
	for _, projectile in live do
		if projectile.owner == player and not projectile.dead and projectile.spec.CanMegaDetonate then
			return true
		end
	end
	return false
end

--[[ Wipe everything in flight, between rounds. ]]
function ProjectileService.ClearAll()
	for _, projectile in live do
		retire(projectile)
	end
	table.clear(live)
end

RunService.Heartbeat:Connect(step)

return ProjectileService
