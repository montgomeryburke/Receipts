--!strict
--[[
	Nuclear Mud Arena — what a shot looks like.

	Draws crisp, fading ballistic tracers, animated muzzle flashes, and
	gravity-affected impact sparks oriented along the true surface normal.
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local Shot = {}

local function effectsFolder(): Instance
	local existing = workspace:FindFirstChild("ShotEffects")
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "ShotEffects"
	folder.Parent = workspace
	return folder
end

local function safeLookAt(position: Vector3, target: Vector3): CFrame
	local dir = target - position
	if dir.Magnitude < 1e-4 then
		return CFrame.new(position)
	end
	local unit = dir.Unit
	local up = if math.abs(unit.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(position, target, up)
end

--[[ The bright ballistic streak the bullet leaves, fading out smoothly. ]]
function Shot.Tracer(from: Vector3, to: Vector3, color: Color3)
	local delta = to - from
	local length = delta.Magnitude
	if length < 0.5 or length ~= length then
		return
	end

	local tracer = Instance.new("Part")
	tracer.Name = "Tracer"
	tracer.Size = Vector3.new(0.18, 0.18, length)
	tracer.CFrame = safeLookAt(from + delta * 0.5, to)
	tracer.Color = color
	tracer.Material = Enum.Material.Neon
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.CanTouch = false
	tracer.CastShadow = false
	tracer.Transparency = 0.08
	tracer.Parent = effectsFolder()

	TweenService:Create(tracer, TweenInfo.new(0.11, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Transparency = 1,
		Size = Vector3.new(0.04, 0.04, length),
	}):Play()

	Debris:AddItem(tracer, 0.13)
end

--[[ The flash at the muzzle, shrinking and dimming rapidly. ]]
function Shot.MuzzleFlash(position: Vector3, color: Color3)
	local flash = Instance.new("Part")
	flash.Name = "MuzzleFlash"
	flash.Size = Vector3.new(1.3, 1.3, 1.3)
	flash.CFrame = CFrame.new(position)
	flash.Shape = Enum.PartType.Ball
	flash.Color = Color3.fromRGB(255, 236, 176)
	flash.Material = Enum.Material.Neon
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Transparency = 0.15
	flash.Parent = effectsFolder()

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 5.5
	light.Range = 22
	light.Shadows = false
	light.Parent = flash

	TweenService:Create(flash, TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.25, 0.25, 0.25),
		Transparency = 1,
	}):Play()
	TweenService:Create(light, TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = 0,
	}):Play()

	Debris:AddItem(flash, 0.08)
end

--[[ Sparks bursting outward along the surface normal with realistic gravity arc. ]]
function Shot.Impact(position: Vector3, normal: Vector3, color: Color3)
	local n = if normal.Magnitude > 1e-4 then normal.Unit else Vector3.yAxis
	local anchor = Instance.new("Part")
	anchor.Name = "Impact"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = safeLookAt(position, position + n)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Parent = effectsFolder()

	local sparks = Instance.new("ParticleEmitter")
	sparks.EmissionDirection = Enum.NormalId.Front
	sparks.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 248, 220)),
		ColorSequenceKeypoint.new(0.4, color),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 110, 30)),
	})
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparks.Lifetime = NumberRange.new(0.1, 0.26)
	sparks.Speed = NumberRange.new(14, 34)
	sparks.SpreadAngle = Vector2.new(42, 42)
	sparks.Acceleration = Vector3.new(0, -45, 0)
	sparks.Drag = 4
	sparks.Rate = 0
	sparks.LightEmission = 1
	sparks.Parent = anchor
	sparks:Emit(10)

	local flash = Instance.new("PointLight")
	flash.Color = color
	flash.Brightness = 3.5
	flash.Range = 12
	flash.Shadows = false
	flash.Parent = anchor
	TweenService:Create(flash, TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = 0,
	}):Play()

	Debris:AddItem(anchor, 0.4)
end

--[[ All three at once, which is what a shot normally wants. ]]
function Shot.Full(origin: Vector3, endPoint: Vector3, color: Color3, normal: Vector3?)
	Shot.MuzzleFlash(origin, color)
	Shot.Tracer(origin, endPoint, color)
	if normal then
		Shot.Impact(endPoint, normal, color)
	end
end

return Shot
