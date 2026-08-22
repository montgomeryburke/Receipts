--!strict
--[[
	PickupService — the burgers, the fries, the shields and the ammo crates.

	Each one sits on a pad, spins, and comes back a little while after somebody
	takes it, so there is always a reason to drive across the map.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Util = require(Shared:WaitForChild("Util"))

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))

local PickupService = {}

type Pickup = {
	kind: string,
	part: BasePart,
	position: Vector3,
	availableAt: number,
	available: boolean,
}

local pickups: { Pickup } = {}
local container: Folder?

local function colourFor(kind: string): Color3
	if kind == "Burger" then
		return Config.Pickups.Burger.Color
	elseif kind == "Fries" then
		return Config.Pickups.Fries.Color
	elseif kind == "Shield" then
		return Config.Pickups.Shield.Color
	elseif kind == "Health" then
		return Config.Pickups.Health.Color
	elseif kind == "Invincibility" then
		return Config.Pickups.Invincibility.Color
	elseif kind == "PoopAmmo" then
		return Config.Pickups.PoopAmmo.Color
	elseif kind == "DroneAmmo" then
		return Config.Pickups.DroneAmmo.Color
	end
	return Config.Pickups.Ammo.Color
end

local function labelFor(kind: string): string
	if kind == "Burger" then
		return Config.Pickups.Burger.DisplayName
	elseif kind == "Fries" then
		return Config.Pickups.Fries.DisplayName
	elseif kind == "Shield" then
		return Config.Pickups.Shield.DisplayName
	elseif kind == "Health" then
		return Config.Pickups.Health.DisplayName
	elseif kind == "Invincibility" then
		return Config.Pickups.Invincibility.DisplayName
	elseif kind == "PoopAmmo" then
		return Config.Pickups.PoopAmmo.DisplayName
	elseif kind == "DroneAmmo" then
		return Config.Pickups.DroneAmmo.DisplayName
	end
	return Config.Pickups.Ammo.DisplayName
end

--[[ Hand the pickup's effect to whoever drove into it. ]]
local function grant(player: Player, kind: string)
	local state = PlayerState.Get(player)
	local now = os.clock()

	if kind == "Burger" then
		state.burgerUntil = now + Config.Pickups.Burger.Duration
	elseif kind == "Fries" then
		state.friesUntil = now + Config.Pickups.Fries.Duration
	elseif kind == "Shield" then
		state.maxShield = math.max(state.maxShield, Config.Pickups.Shield.Amount)
		state.shield = state.maxShield
	elseif kind == "Ammo" then
		for name, slot in state.weapons do
			local spec = Config.Weapons[name]
			-- Poop and drones are scavenged, not resupplied by a crate.
			if spec and not spec.AmmoFromPickupsOnly then
				slot.ammo = spec.MagSize
				slot.reloadingUntil = 0
			end
		end
	elseif kind == "Health" then
		-- Straight back to full.
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = humanoid.MaxHealth
		end
	elseif kind == "Invincibility" then
		-- Twenty seconds of nothing being able to touch you.
		state.burgerUntil = now + Config.Pickups.Invincibility.Duration
	elseif kind == "PoopAmmo" then
		local slot = state.weapons.Poop
		local spec = Config.Weapons.Poop
		if slot and spec then
			slot.ammo = math.min(spec.MagSize, slot.ammo + 2)
		end
	elseif kind == "DroneAmmo" then
		local slot = state.weapons.Drone
		local spec = Config.Weapons.Drone
		if slot and spec then
			slot.ammo = math.min(spec.MagSize, slot.ammo + 1)
		end
	end

	PlayerState.Changed.Fire(player)
	Remotes.Event("Notify"):FireClient(player, `Picked up: {labelFor(kind)}`)
end

--[[ Build the floating, spinning thing you actually drive into. ]]
local function createPickup(kind: string, position: Vector3, parent: Folder): Pickup
	local part = Util.Part({
		Name = `Pickup_{kind}`,
		Size = Vector3.new(6, 6, 6),
		CFrame = CFrame.new(position + Vector3.new(0, 4, 0)),
		Color = colourFor(kind),
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = parent,
	})

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(8, 2)
	billboard.StudsOffset = Vector3.new(0, 4, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = labelFor(kind)
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.3
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = billboard

	local pickup: Pickup = {
		kind = kind,
		part = part,
		position = position + Vector3.new(0, 4, 0),
		availableAt = 0,
		available = true,
	}

	part.Touched:Connect(function(hit)
		if not pickup.available then
			return
		end
		local character = hit:FindFirstAncestorOfClass("Model")
		if not character then
			return
		end
		local player = Players:GetPlayerFromCharacter(character)
		if not player then
			return
		end

		pickup.available = false
		pickup.availableAt = os.clock() + Config.Pickups.RespawnDelay
		part.Transparency = 1
		billboard.Enabled = false

		grant(player, kind)
	end)

	return pickup
end

--[[ Lay out every pickup the current map asked for. ]]
function PickupService.Build(pads: { { position: Vector3, kind: string } })
	PickupService.Clear()

	local folder = Instance.new("Folder")
	folder.Name = "Pickups"
	folder.Parent = workspace
	container = folder

	for _, pad in pads do
		table.insert(pickups, createPickup(pad.kind, pad.position, folder))
	end
end

function PickupService.Clear()
	if container then
		container:Destroy()
		container = nil
	end
	table.clear(pickups)
end

--[[ Spin them, bob them, and bring back the ones whose timer is up. ]]
local function step()
	local now = os.clock()
	local spin = CFrame.Angles(0, now * 1.5, 0)
	local bob = math.sin(now * 2) * 0.8

	for _, pickup in pickups do
		if not pickup.part.Parent then
			continue
		end

		pickup.part.CFrame = CFrame.new(pickup.position + Vector3.new(0, bob, 0)) * spin

		if not pickup.available and now >= pickup.availableAt then
			pickup.available = true
			pickup.part.Transparency = 0
			local billboard = pickup.part:FindFirstChildOfClass("BillboardGui")
			if billboard then
				billboard.Enabled = true
			end
		end
	end
end

RunService.Heartbeat:Connect(step)

return PickupService
