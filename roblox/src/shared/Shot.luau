--!strict
--[[
	Nuclear Mud Arena — what a shot looks like.

	This used to live on the server only, which made every gun feel broken in
	a way that is hard to name: you pulled the trigger and the flash, the
	bang and the tracer all appeared one network round trip later. On a
	50-150ms connection that is a visible, constant delay on every single
	shot, and no amount of tuning the damage numbers makes a gun with that
	delay feel good.

	So the visuals live here, where both sides can run them:

	  - The SHOOTER'S client runs them the instant the trigger passes the
	    weapon's own cooldown. No waiting for anybody.
	  - The server still runs the raycast, the damage, the points and the
	    kill feed. It is the only thing anybody trusts.
	  - Everybody ELSE hears about the shot over one small remote and runs
	    the same code, which is also cheaper than it was: a replicated part
	    costs more bandwidth than a position and a colour.

	Nothing in here is authoritative. If a client lies about a tracer, a
	tracer appears in the wrong place on that client's screen. That is all it
	can do.
]]

local Debris = game:GetService("Debris")

local Shot = {}

--[[ The bright line the bullet leaves. ]]
function Shot.Tracer(from: Vector3, to: Vector3, color: Color3)
	local delta = to - from
	local length = delta.Magnitude
	if length < 0.5 or length ~= length then
		return
	end

	local tracer = Instance.new("Part")
	tracer.Name = "Tracer"
	tracer.Size = Vector3.new(0.5, 0.5, length)
	tracer.CFrame = CFrame.lookAt(from + delta * 0.5, to)
	tracer.Color = color
	tracer.Material = Enum.Material.Neon
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.CanTouch = false
	tracer.CastShadow = false
	tracer.Transparency = 0.1
	tracer.Parent = workspace

	-- Short. A tracer that hangs for a third of a second reads as a solid
	-- neon rod stuck in the air rather than a bullet going past.
	Debris:AddItem(tracer, 0.12)
end

--[[ The flash at the muzzle, so you can see your own gun going off. ]]
function Shot.MuzzleFlash(position: Vector3, color: Color3)
	local flash = Instance.new("Part")
	flash.Name = "MuzzleFlash"
	flash.Size = Vector3.new(1.6, 1.6, 1.6)
	flash.CFrame = CFrame.new(position)
	flash.Shape = Enum.PartType.Ball
	flash.Color = Color3.fromRGB(255, 232, 160)
	flash.Material = Enum.Material.Neon
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Parent = workspace

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 7
	light.Range = 24
	light.Shadows = false
	light.Parent = flash

	Debris:AddItem(flash, 0.06)
end

--[[ Sparks where the shot lands, so you can tell what you hit. ]]
function Shot.Impact(position: Vector3, normal: Vector3, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Name = "Impact"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position, position + normal)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Parent = workspace

	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new(color)
	sparks.Size = NumberSequence.new(0.5, 0)
	sparks.Lifetime = NumberRange.new(0.08, 0.2)
	sparks.Speed = NumberRange.new(10, 26)
	sparks.SpreadAngle = Vector2.new(50, 50)
	sparks.Rate = 0
	sparks.LightEmission = 1
	sparks.Parent = anchor
	sparks:Emit(9)

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
