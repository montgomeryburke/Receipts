--!strict
--[[
	Nuclear Mud Arena — server start-up.

	This is the only Script on the server. Everything else is a module it turns
	on.

	IT IS WRITTEN DEFENSIVELY ON PURPOSE.

	The first version of this file required every module at the top and started
	them in a row. One of those modules asked Roblox for a DataStore while it
	was loading, and Roblox Studio refuses DataStore access in a place that has
	never been published. That refusal killed this script before it reached the
	line that builds the arena — so the game opened to an empty sky and players
	fell forever with no clue why.

	So now: ground exists before anything that can fail is even touched, and
	every subsystem starts inside its own pcall. A broken subsystem costs you
	that subsystem and prints a clear reason. It can never again cost you the
	whole world.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ======================================================= 1. GROUND, ALWAYS ==
--[[
	Built with nothing but Instance.new, before a single require runs, so there
	is no possible failure between opening the place and having a floor.

	It is thrown away the moment the real arena is standing.
]]
local function buildFallbackGround(): Model
	local holder = Instance.new("Model")
	holder.Name = "FallbackGround"

	local floor = Instance.new("Part")
	floor.Name = "Baseplate"
	floor.Size = Vector3.new(2048, 20, 2048)
	floor.CFrame = CFrame.new(0, -10, 0)
	floor.Anchored = true
	floor.Color = Color3.fromRGB(70, 78, 70)
	floor.Material = Enum.Material.Grass
	floor.TopSurface = Enum.SurfaceType.Smooth
	floor.Parent = holder

	local pad = Instance.new("SpawnLocation")
	pad.Name = "FallbackSpawn"
	pad.Size = Vector3.new(24, 1, 24)
	pad.CFrame = CFrame.new(0, 1, 0)
	pad.Anchored = true
	pad.Neutral = true
	pad.Duration = 0
	pad.BrickColor = BrickColor.new("Bright yellow")
	pad.Material = Enum.Material.Neon
	pad.Parent = holder

	holder.Parent = workspace
	return holder
end

local fallbackGround = buildFallbackGround()
print("[Nuclear Mud Arena] Fallback ground placed. You will never fall into the void.")

-- ==================================================== 2. START SUBSYSTEMS ==

local modules = script:WaitForChild("modules")
local Shared = ReplicatedStorage:WaitForChild("Shared")

--[[ Load a module without letting a bad one take the server with it. ]]
local function tryRequire(container: Instance, name: string): any
	local child = container:FindFirstChild(name)
	if not child then
		warn(`[Nuclear Mud Arena] Missing module: {name}`)
		return nil
	end
	local ok, result = pcall(require, child)
	if not ok then
		warn(`[Nuclear Mud Arena] Module "{name}" failed to load: {result}`)
		return nil
	end
	return result
end

--[[ Start one subsystem, reporting rather than exploding. ]]
local function tryStart(name: string, service: any)
	if not service or typeof(service.Start) ~= "function" then
		return
	end
	local ok, err = pcall(service.Start)
	if not ok then
		warn(`[Nuclear Mud Arena] "{name}" failed to start: {err}`)
	end
end

local Config = tryRequire(Shared, "Config")
-- Creating the remotes early matters: the client is already waiting on them.
tryRequire(Shared, "Remotes")

local PlayerState = tryRequire(modules, "PlayerState")
local TeamService = tryRequire(modules, "TeamService")
local WeaponService = tryRequire(modules, "WeaponService")
local MonetizationService = tryRequire(modules, "MonetizationService")
local MatchService = tryRequire(modules, "MatchService")
local GraphicsService = tryRequire(modules, "GraphicsService")

tryStart("GraphicsService", GraphicsService)
tryStart("TeamService", TeamService)
tryStart("WeaponService", WeaponService)
tryStart("MonetizationService", MonetizationService)
tryStart("MatchService", MatchService)

-- ========================================================= 3. THE HUD FEED ==

local Remotes = tryRequire(Shared, "Remotes")

if Remotes and Config and PlayerState then
	--[[
		Everything one player's screen needs to draw itself, built in one place
		so the pushed update and the asked-for update cannot disagree.
	]]
	local function describe(player: Player)
		local state = PlayerState.Get(player)

		-- The gun in their hands might be a mounted one they are sitting behind.
		local equipped = state.equipped
		if state.vehicle and state.vehicle.Parent then
			local mounted = state.vehicle:GetAttribute("MountedWeapon")
			local isGunner = state.seatRole == "Gunner"
			local isPilot = state.seatRole == "Driver"
				and state.vehicle:GetAttribute("VehicleKind") == "Plane"
			if typeof(mounted) == "string" and (isGunner or isPilot) then
				equipped = mounted
			end
		end

		local spec = Config.Weapons[equipped]
		local slot = state.weapons[equipped]

		return {
			shield = state.shield,
			maxShield = state.maxShield,
			keys = state.keys,
			carTier = state.carTier,
			carTierName = Config.CarTiers[math.clamp(state.carTier, 1, #Config.CarTiers)].Name,
			megaCharges = state.megaCharges,
			kills = state.kills,
			deaths = state.deaths,

			equipped = equipped,
			weaponName = if spec then spec.DisplayName else equipped,
			ammo = if slot then slot.ammo else 0,
			magSize = if spec then spec.MagSize else 0,
			reloading = if slot then slot.reloadingUntil > os.clock() else false,
		}
	end

	-- Push a fresh HUD when something actually changes, rather than having
	-- every client ask twenty times a second.
	PlayerState.Changed.Connect(function(player: Player)
		if player and player.Parent then
			Remotes.Event("HudUpdate"):FireClient(player, describe(player))
		end
	end)

	-- Still answer a direct ask, for a client that has just loaded in.
	Remotes.Function("GetPlayerState").OnServerInvoke = function(player)
		return describe(player)
	end
end

-- ================================================= 4. CLEAR THE SCAFFOLDING ==

--[[
	Once the real arena is up, the fallback is just a giant plate in the way.
	If the arena never appears, the fallback stays and the warnings above tell
	you why — which is a bad game, but a visible one.
]]
task.spawn(function()
	for _ = 1, 60 do
		if workspace:FindFirstChild("Arena") then
			fallbackGround:Destroy()
			print("[Nuclear Mud Arena] Arena is up. Fallback ground removed.")

			-- Anyone who spawned on the fallback needs moving onto the map.
			for _, player in Players:GetPlayers() do
				if player.Character then
					player:LoadCharacterAsync()
				end
			end
			return
		end
		task.wait(0.5)
	end
	warn("[Nuclear Mud Arena] No arena appeared after 30s. Keeping fallback ground.")
	warn("[Nuclear Mud Arena] Look for a red error above this line — that is the cause.")
end)

if Config and Config.FreeMode then
	print("[Nuclear Mud Arena] FREE MODE — every weapon and vehicle is unlocked.")
end
print("[Nuclear Mud Arena] Server ready.")
