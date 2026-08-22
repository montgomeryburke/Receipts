--!strict
--[[
	Util — small helpers used all over the place. Nothing clever, just the
	boring code written once instead of forty times.
]]

local Util = {}

--[[
	Make a part in one call instead of eight lines.
	Anchored and collidable by default, because that is what map pieces want.
]]
function Util.Part(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.SmoothPlastic
	for key, value in props do
		if key ~= "Parent" then
			(part :: any)[key] = value
		end
	end
	-- Parent last so the part is fully built before it hits the world.
	if props.Parent then
		part.Parent = props.Parent
	end
	return part
end

--[[ Glue two parts together so they move as one lump. ]]
function Util.Weld(a: BasePart, b: BasePart): WeldConstraint
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = a
	weld.Part1 = b
	weld.Parent = a
	return weld
end

--[[ An attachment at a spot on a part, in that part's own local space. ]]
function Util.Attachment(parent: BasePart, offset: Vector3, name: string?): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name or "Attachment"
	attachment.Position = offset
	attachment.Parent = parent
	return attachment
end

--[[ Raycast settings that ignore a list of things (usually you and your car). ]]
function Util.RayParams(ignore: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	return params
end

--[[ Nudge a direction off-course by up to `degrees`, for gun spread. ]]
function Util.ApplySpread(direction: Vector3, degrees: number, rng: Random): Vector3
	if degrees <= 0 then
		return direction.Unit
	end
	local radians = math.rad(degrees)
	local yaw = rng:NextNumber(-radians, radians)
	local pitch = rng:NextNumber(-radians, radians)
	return (CFrame.new(Vector3.zero, direction) * CFrame.Angles(pitch, yaw, 0)).LookVector
end

--[[ The angle between two directions, in degrees. Used by auto-aim. ]]
function Util.AngleBetween(a: Vector3, b: Vector3): number
	local aMag, bMag = a.Magnitude, b.Magnitude
	if aMag == 0 or bMag == 0 then
		return 180
	end
	local dot = math.clamp(a.Unit:Dot(b.Unit), -1, 1)
	return math.deg(math.acos(dot))
end

--[[ The Humanoid and root part of whatever a raycast hit, if it was a player. ]]
function Util.HumanoidFromHit(hit: BasePart?): (Humanoid?, Model?)
	if not hit then
		return nil, nil
	end
	local model = hit:FindFirstAncestorOfClass("Model")
	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return humanoid, model
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil
end

--[[ Clean something up after a delay without leaking a thread if it dies first. ]]
function Util.DestroyAfter(instance: Instance, seconds: number)
	task.delay(seconds, function()
		if instance and instance.Parent then
			instance:Destroy()
		end
	end)
end

--[[ A flat random point inside a square centred on the origin. ]]
function Util.RandomFlatPoint(halfSize: number, rng: Random): Vector3
	return Vector3.new(rng:NextNumber(-halfSize, halfSize), 0, rng:NextNumber(-halfSize, halfSize))
end

--[[ Seconds as M:SS, for the round clock. ]]
function Util.FormatClock(seconds: number): string
	local whole = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", whole // 60, whole % 60)
end

return Util
