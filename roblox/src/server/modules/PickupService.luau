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
local Sound = require(Shared:WaitForChild("Sound"))
local Util = require(Shared:WaitForChild("Util"))

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local VehicleService = require(script.Parent:WaitForChild("VehicleService"))

local PickupService = {}

type Pickup = {
	kind: string,
	-- Only set on weapon crates: which gun this one hands over.
	weapon: string?,
	part: BasePart,
	position: Vector3,
	availableAt: number,
	available: boolean,
}

local pickups: { Pickup } = {}
-- Only the ones counting down to their return. Kept apart from `pickups` so
-- the per-frame loop walks what it has work for rather than the whole map.
local waiting: { Pickup } = {}
local container: Folder?

local function colourFor(kind: string, weapon: string?): Color3
	if kind == "Weapon" and weapon then
		local spec = Config.Weapons[weapon]
		if spec then
			return spec.Color
		end
	end
	if kind == "Multiplier" then
		return Config.Pickups.Multiplier.Color
	end
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

local function labelFor(kind: string, weapon: string?): string
	if kind == "Weapon" and weapon then
		local spec = Config.Weapons[weapon]
		if spec then
			return spec.DisplayName
		end
	end
	if kind == "Multiplier" then
		return Config.Pickups.Multiplier.DisplayName
	end
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
local function grant(player: Player, kind: string, weapon: string?)
	local state = PlayerState.Get(player)
	local now = os.clock()

	if kind == "Burger" then
		state.burgerUntil = math.max(state.burgerUntil, now + Config.Pickups.Burger.Duration)
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
		state.burgerUntil = math.max(state.burgerUntil, now + Config.Pickups.Invincibility.Duration)
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
	elseif kind == "Multiplier" then
		-- Everything you score is worth more for the next minute and a half.
		state.multiplierUntil = now + Config.Pickups.Multiplier.Duration
		state.multiplierAmount = Config.Pickups.Multiplier.Amount
	elseif kind == "Weapon" and weapon then
		-- Picking a gun up puts it straight in your hands.
		local spec = Config.Weapons[weapon]
		if spec and not spec.MountedOnly then
			state.equipped = weapon
			local slot = state.weapons[weapon]
			if not slot then
				slot = { ammo = spec.MagSize, reloadingUntil = 0, nextFireAt = 0 }
				state.weapons[weapon] = slot
			else
				slot.ammo = spec.MagSize
				slot.reloadingUntil = 0
			end
		end
	end

	PlayerState.Changed.Fire(player)

	-- The good ones sound like it.
	local big = kind == "Invincibility" or kind == "Multiplier" or kind == "Weapon"
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		Sound.At(if big then "PickupBig" else "Pickup", root.Position)
	end

	Remotes.Event("Notify"):FireClient(player, `Picked up: {labelFor(kind, weapon)}`)
end

--[[ Build the floating, spinning thing you actually drive into. ]]
local function createPickup(kind: string, position: Vector3, parent: Folder, weapon: string?): Pickup
	local part = Util.Part({
		Name = `Pickup_{kind}`,
		Size = Vector3.new(6, 6, 6),
		CFrame = CFrame.new(position + Vector3.new(0, 4, 0)),
		Color = colourFor(kind, weapon),
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = parent,
	})

	--[[
		The label, close up and not through walls.

		It had neither a draw distance nor occlusion, which on a map this
		size meant about seventy-five pickup names rendering THROUGH
		buildings at any range. Three problems in one: clutter that buries
		whatever you actually need to read, a mild wallhack that maps the
		arena's loot from your spawn, and seventy-five GUIs drawn that
		nobody could act on.

		AlwaysOnTop off is the same judgement the player outlines make with
		their Occluded depth mode: knowing a thing is there is information,
		and information through a wall is a different game. The pickup part
		itself is Neon, so it is not hard to spot once you can see it.
	]]
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(8, 2)
	billboard.StudsOffset = Vector3.new(0, 4, 0)
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = Config.Visuals.PickupLabelDistance
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = labelFor(kind, weapon)
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.3
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = billboard

	local pickup: Pickup = {
		kind = kind,
		weapon = weapon,
		part = part,
		position = position + Vector3.new(0, 4, 0),
		availableAt = 0,
		available = true,
	}

	part.Touched:Connect(function(hit)
		if not pickup.available then
			return
		end
		local player: Player? = nil
		local character = hit:FindFirstAncestorOfClass("Model")
		if character then
			player = Players:GetPlayerFromCharacter(character)
		end
		if not player then
			local vehicle = VehicleService.FromPart(hit)
			if vehicle then
				local seat = vehicle:FindFirstChild("DriverSeat")
				if seat and seat:IsA("Seat") and seat.Occupant and seat.Occupant.Parent then
					player = Players:GetPlayerFromCharacter(seat.Occupant.Parent :: Model)
				end
			end
		end
		if not player then
			return
		end
		local pChar = player.Character
		local pHum = pChar and pChar:FindFirstChildOfClass("Humanoid")
		if not pHum or pHum.Health <= 0 then
			return
		end

		pickup.available = false
		pickup.availableAt = os.clock() + Config.Pickups.RespawnDelay
		part.Transparency = 1
		billboard.Enabled = false
		-- Into the short list the frame loop actually walks.
		if not table.find(waiting, pickup) then
			table.insert(waiting, pickup)
		end

		grant(player, kind, weapon)
	end)

	return pickup
end

--[[ Lay out every pickup the current map asked for. ]]
function PickupService.Build(pads: { { position: Vector3, kind: string, weapon: string? } })
	PickupService.Clear()

	local folder = Instance.new("Folder")
	folder.Name = "Pickups"
	folder.Parent = workspace
	container = folder

	for _, pad in pads do
		table.insert(pickups, createPickup(pad.kind, pad.position, folder, pad.weapon))
	end
end

--[[
	How many pickups the per-frame loop has to look at, for the tests.

	The point of the split is that this is nearly always zero while the map
	holds seventy-odd pickups, so it is the number worth asserting on.
]]
function PickupService.WaitingForTests(): number
	return #waiting
end

function PickupService.AllForTests(): { any }
	return pickups
end

function PickupService.Clear()
	if container then
		container:Destroy()
		container = nil
	end
	table.clear(pickups)
	table.clear(waiting)
end

--[[
	Bring back the ones whose timer is up.

	The spin and the bob used to be here too, one CFrame write per pickup
	per frame: about seventy-five pickups at sixty hertz is four and a half
	thousand property writes a second, every one of them replicated to every
	client, to describe an animation computed from nothing but the clock and
	identical on all of them. It lives on the client now (Props), and what
	is left here is the part that is genuinely state.

	Which also means this loop has nothing to do most of the time, so it
	walks a list of the pickups actually waiting rather than all of them.
	Twenty players picking things up keeps a handful in here; the other
	seventy cost nothing.
]]
local function step()
	if #waiting == 0 then
		return
	end
	local now = os.clock()
	for index = #waiting, 1, -1 do
		local pickup = waiting[index]
		if not pickup.part.Parent then
			table.remove(waiting, index)
		elseif now >= pickup.availableAt then
			table.remove(waiting, index)
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
