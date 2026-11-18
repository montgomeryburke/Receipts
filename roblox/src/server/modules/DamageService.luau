--!strict
--[[
	DamageService — the single place where anybody loses health.

	Every gun, every explosion and every crash goes through ApplyDamage, which
	means the rules about shields, spawn protection and invincibility burgers
	only have to be written once and cannot drift apart.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Signal = require(Shared:WaitForChild("Signal"))
local Sound = require(Shared:WaitForChild("Sound"))
local Util = require(Shared:WaitForChild("Util"))

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local VehicleService = require(script.Parent:WaitForChild("VehicleService"))

local DamageService = {}

--[[ Fired as (victim, killer|nil, cause) whenever somebody dies. ]]
DamageService.Killed = Signal.new()

--[[
	Fired as (position, radius, attacker) for a mega-detonation only.

	Announced rather than acted on, so that the things which care about huge
	explosions — the giant animals, which shrug off everything smaller — can
	listen without this module having to know they exist.
]]
DamageService.MegaBlast = Signal.new()

--[[
	Hurt a player.

	Shields soak damage first and health takes the remainder, so a full shield
	is worth exactly its number in extra health. Returns true if this hit
	actually landed, which callers use to decide whether to show a hitmarker.
]]
function DamageService.ApplyDamage(
	victim: Player,
	amount: number,
	attacker: Player?,
	cause: string?
): boolean
	if amount <= 0 then
		return false
	end

	local character = victim.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	-- Freshly spawned, or chewing an invincibility burger.
	if PlayerState.IsInvincible(victim) then
		return false
	end

	-- Friendly fire is off. Shooting your own team does nothing.
	if attacker and attacker ~= victim and attacker.Team and victim.Team and attacker.Team == victim.Team then
		return false
	end

	local state = PlayerState.Get(victim)
	state.lastDamagedAt = os.clock()

	-- Shields first.
	local remaining = amount
	if state.shield > 0 then
		local absorbed = math.min(state.shield, remaining)
		state.shield -= absorbed
		remaining -= absorbed

		-- The moment the shield gives out is the moment that matters, so it
		-- gets its own noise.
		if state.shield <= 0 then
			local root = character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				Sound.At("ShieldBreak", root.Position)
			end
		end
	end

	if remaining > 0 then
		humanoid:TakeDamage(remaining)
	end

	PlayerState.Changed.Fire(victim)

	if humanoid.Health <= 0 then
		local root = character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			Sound.At("Death", root.Position)
		end
		DamageService.HandleDeath(victim, attacker, cause or "Unknown")
	end

	return true
end

--[[ Book-keeping for a death: keys to the killer, a tally for both. ]]
function DamageService.HandleDeath(victim: Player, killer: Player?, cause: string)
	local victimState = PlayerState.Get(victim)
	victimState.deaths += 1

	if killer and killer ~= victim then
		local killerState = PlayerState.Get(killer)
		killerState.kills += 1
		-- Keys are the progression: every kill moves you toward a faster car.
		PlayerState.AwardKeys(killer, 1)
	end

	DamageService.Killed.Fire(victim, killer, cause)
end

--[[
	An explosion. Everything within the radius takes damage on a slide from
	full at the centre to nothing at the edge, and vehicles take their own
	multiplier on top.
]]
function DamageService.Explode(
	position: Vector3,
	radius: number,
	maxDamage: number,
	attacker: Player?,
	vehicleMultiplier: number?,
	isMega: boolean?
)
	if isMega then
		DamageService.MegaBlast.Fire(position, radius, attacker)
	end

	-- Big blasts get the deeper boom.
	Sound.At(if radius > 60 then "ExplosionBig" else "Explosion", position)

	-- The visible bang. BlastPressure does the ragdoll-throwing; the numbers
	-- below do the actual damage, so nobody dies to physics alone.
	local explosion = Instance.new("Explosion")
	explosion.Position = position
	explosion.BlastRadius = radius
	explosion.BlastPressure = 180000
	explosion.DestroyJointRadiusPercent = 0
	explosion.ExplosionType = Enum.ExplosionType.NoCraters
	explosion.Parent = workspace

	-- Players in range.
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local distance = (root.Position - position).Magnitude
			if distance <= radius then
				local falloff = 1 - (distance / radius)
				DamageService.ApplyDamage(player, maxDamage * falloff, attacker, "Explosion")
			end
		end
	end

	-- Vehicles in range.
	local seen: { [Model]: boolean } = {}
	local parts = workspace:GetPartBoundsInRadius(position, radius)
	for _, part in parts do
		local vehicle = VehicleService.FromPart(part)
		if vehicle and not seen[vehicle] then
			seen[vehicle] = true
			local primary = vehicle.PrimaryPart
			if primary then
				local distance = (primary.Position - position).Magnitude
				local falloff = math.max(0, 1 - (distance / radius))
				VehicleService.Damage(vehicle, maxDamage * falloff * (vehicleMultiplier or 1), attacker)
			end
		end
	end

	-- Blow apart any cover the map marked as breakable.
	for _, part in parts do
		if part:GetAttribute("Destructible") then
			part:Destroy()
		end
	end
end

--[[
	Carve a crater into the mud. Purely cosmetic, but it is the thing that
	makes a mega-detonation feel like it mattered.
]]
--[[
	A wrecked vehicle's blast.

	VehicleService announces these rather than applying them, because it
	already requires this module and the reverse would be a cycle.

	Before this listener existed, every exploding vehicle dealt exactly zero
	damage. Roblox's Explosion only hurts a Humanoid by breaking its joints,
	and the vehicle blast set DestroyJointRadiusPercent to 0 to stop
	characters coming apart -- which switched off the only damage it did. So
	riding a torpedo straight into somebody, the entire purpose of the
	torpedo, did nothing to them whatsoever.
]]
VehicleService.Wrecked.Connect(function(
	position: Vector3,
	radius: number,
	damage: number,
	lastDriver: Player?
)
	DamageService.Explode(position, radius, damage, lastDriver, 1.4, false)
end)

function DamageService.Crater(position: Vector3, radius: number)
	local crater = Util.Part({
		Name = "Crater",
		Size = Vector3.new(radius * 2, Config.Mega.CraterDepth, radius * 2),
		CFrame = CFrame.new(position - Vector3.new(0, Config.Mega.CraterDepth * 0.4, 0)),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(52, 38, 24),
		Material = Enum.Material.Mud,
		CanCollide = false,
		Parent = workspace:FindFirstChild("Arena") or workspace,
	})
	-- A cylinder lies on its own X axis, so stand it upright to be a hole.
	crater.CFrame = CFrame.new(position - Vector3.new(0, Config.Mega.CraterDepth * 0.4, 0))
		* CFrame.Angles(0, 0, math.rad(90))
	-- Craters fade rather than piling up forever and eating the frame rate.
	Util.DestroyAfter(crater, 45)
end

-- Shields tick back up for everybody, once per frame.
RunService.Heartbeat:Connect(function(deltaTime)
	PlayerState.RegenerateShields(deltaTime)
end)

return DamageService
