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

--[[ Safe CFrame.lookAt that avoids collinearity NaN when aiming straight up or down. ]]
function Util.LookAt(position: Vector3, target: Vector3): CFrame
	local delta = target - position
	if delta.Magnitude < 1e-4 then
		return CFrame.new(position)
	end
	local unit = delta.Unit
	local up = if math.abs(unit.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(position, target, up)
end

--[[ Nudge a direction off-course by up to `degrees` in a circular cone. ]]
function Util.ApplySpread(direction: Vector3, degrees: number, rng: Random): Vector3
	if direction.Magnitude < 1e-4 then
		return Vector3.new(0, 0, -1)
	end
	local unit = direction.Unit
	if degrees <= 0 then
		return unit
	end
	local maxRad = math.rad(degrees)
	local angle = rng:NextNumber(0, math.pi * 2)
	local radius = math.sqrt(rng:NextNumber()) * maxRad
	local pitch = math.sin(angle) * radius
	local yaw = math.cos(angle) * radius
	return (Util.LookAt(Vector3.zero, unit) * CFrame.Angles(pitch, yaw, 0)).LookVector
end

--[[ The angle between two directions, in degrees. Used by auto-aim. ]]
--[[
	Is this a Vector3 a server can safely do arithmetic with?

	Every remote handler that takes a direction used to guard with
	`typeof(v) ~= "Vector3"` and `v.Magnitude < 0.001`. Neither one rejects
	NaN, because **every comparison involving NaN is false** -- so
	`Vector3.new(0/0, 0/0, 0/0)` passed both tests, and `.Unit` stayed NaN,
	and the NaN went on into CFrame.lookAt, workspace:Raycast and projectile
	positions. A hostile client could send one from a console.

	A finite check has to be written as its own test, not as a comparison:
	`value ~= value` is the only thing that catches NaN, and infinity has to
	be excluded separately.
]]
local function finite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

function Util.IsSaneVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	if not (finite(vector.X) and finite(vector.Y) and finite(vector.Z)) then
		return false
	end
	-- Nothing legitimate is this far out, and a huge-but-finite vector is
	-- just as good a way to break downstream maths as an infinite one.
	return vector.Magnitude < 1e6
end

--[[
	A direction a server can trust: sane, and long enough to normalise.

	Returns the unit vector, or nil. Returning the normalised value rather
	than a boolean means a caller cannot forget to normalise it afterwards.
]]
function Util.SaneDirection(value: any): Vector3?
	if not Util.IsSaneVector(value) then
		return nil
	end
	local vector = value :: Vector3
	if vector.Magnitude < 0.001 then
		return nil
	end
	return vector.Unit
end

function Util.AngleBetween(a: Vector3, b: Vector3): number
	if not Util.IsSaneVector(a) or not Util.IsSaneVector(b) then
		return 180
	end
	local aMag, bMag = a.Magnitude, b.Magnitude
	if not (aMag > 0 and bMag > 0) then
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
