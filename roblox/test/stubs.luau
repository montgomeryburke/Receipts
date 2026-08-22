-- Minimal Roblox stand-ins: enough to actually RUN the map generator outside
-- Roblox and see whether it errors and what geometry it produces.

local function approxUnit(x, y, z)
	local m = math.sqrt(x * x + y * y + z * z)
	if m < 1e-9 then return 0, 0, 0, 0 end
	return x / m, y / m, z / m, m
end

-- ------------------------------------------------------------------ Vector3
local V3 = {}
V3.__index = V3
local function v3(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3) end
function V3.__add(a, b) return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
function V3.__sub(a, b) return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
function V3.__unm(a) return v3(-a.X, -a.Y, -a.Z) end
function V3.__mul(a, b)
	if type(a) == "number" then return v3(a * b.X, a * b.Y, a * b.Z) end
	if type(b) == "number" then return v3(a.X * b, a.Y * b, a.Z * b) end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
function V3.__div(a, b) return v3(a.X / b, a.Y / b, a.Z / b) end
function V3.__eq(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
function V3.__tostring(a) return string.format("(%.1f, %.1f, %.1f)", a.X, a.Y, a.Z) end
function V3.__index(self, k)
	if k == "Magnitude" then return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2) end
	if k == "Unit" then
		local x, y, z = approxUnit(self.X, self.Y, self.Z)
		return v3(x, y, z)
	end
	return rawget(V3, k)
end
function V3:Dot(o) return self.X * o.X + self.Y * o.Y + self.Z * o.Z end
function V3:Cross(o)
	return v3(self.Y * o.Z - self.Z * o.Y, self.Z * o.X - self.X * o.Z, self.X * o.Y - self.Y * o.X)
end
function V3:Lerp(o, t) return self + (o - self) * t end
Vector3 = setmetatable({ new = function(x, y, z) return v3(x, y, z) end }, {
	__index = function(_, k)
		if k == "zero" then return v3(0, 0, 0) end
		if k == "one" then return v3(1, 1, 1) end
		return nil
	end,
})
Vector2 = { new = function(x, y) return { X = x, Y = y } end }

-- ------------------------------------------------------------------- CFrame
-- Stored as a position plus three basis vectors (right, up, backward).
-- Roblox's LookVector is -backward.
local CF = {}
local function cf(p, r, u, b) return setmetatable({ p = p, r = r, u = u, b = b }, CF) end

function CF.__index(self, k)
	if k == "Position" or k == "p" then return rawget(self, "p") end
	if k == "LookVector" then return -rawget(self, "b") end
	if k == "RightVector" then return rawget(self, "r") end
	if k == "UpVector" then return rawget(self, "u") end
	if k == "Rotation" then
		return cf(v3(0, 0, 0), rawget(self, "r"), rawget(self, "u"), rawget(self, "b"))
	end
	if k == "X" then return rawget(self, "p").X end
	if k == "Y" then return rawget(self, "p").Y end
	if k == "Z" then return rawget(self, "p").Z end
	return rawget(CF, k)
end

-- Rotate a local vector into world space using the basis.
function CF:VectorToWorld(v)
	return self.r * v.X + self.u * v.Y + self.b * v.Z
end

function CF.__mul(a, b)
	if getmetatable(b) == V3 then
		return a.p + a:VectorToWorld(b)
	end
	-- Compose: b's basis expressed through a's.
	local nr = a:VectorToWorld(b.r)
	local nu = a:VectorToWorld(b.u)
	local nb = a:VectorToWorld(b.b)
	local np = a.p + a:VectorToWorld(b.p)
	return cf(np, nr, nu, nb)
end

function CF.__add(a, v) return cf(a.p + v, a.r, a.u, a.b) end
function CF.__sub(a, v) return cf(a.p - v, a.r, a.u, a.b) end

function CF:Inverse()
	-- Transpose of the rotation, applied to the negated position.
	local ir = v3(self.r.X, self.u.X, self.b.X)
	local iu = v3(self.r.Y, self.u.Y, self.b.Y)
	local ib = v3(self.r.Z, self.u.Z, self.b.Z)
	local inv = cf(v3(0, 0, 0), ir, iu, ib)
	local np = inv:VectorToWorld(-self.p)
	return cf(np, ir, iu, ib)
end

function CF:ToObjectSpace(other) return self:Inverse() * other end
function CF:PointToObjectSpace(point) return self:Inverse() * point end
function CF:ToWorldSpace(other) return self * other end

CFrame = {}
function CFrame.new(a, b, c)
	local ident = { v3(1, 0, 0), v3(0, 1, 0), v3(0, 0, 1) }
	if a == nil then return cf(v3(0, 0, 0), ident[1], ident[2], ident[3]) end
	if getmetatable(a) == V3 then
		if getmetatable(b) == V3 then return CFrame.lookAt(a, b) end
		return cf(a, ident[1], ident[2], ident[3])
	end
	return cf(v3(a, b, c), ident[1], ident[2], ident[3])
end

function CFrame.lookAt(from, target, up)
	up = up or v3(0, 1, 0)
	local dir = target - from
	if dir.Magnitude < 1e-6 then dir = v3(0, 0, 1) end
	local back = (-dir).Unit
	local right = up:Cross(back)
	if right.Magnitude < 1e-6 then right = v3(1, 0, 0) else right = right.Unit end
	local realUp = back:Cross(right)
	return cf(from, right, realUp, back)
end

function CFrame.Angles(rx, ry, rz)
	local cx, sx = math.cos(rx), math.sin(rx)
	local cy, sy = math.cos(ry), math.sin(ry)
	local cz, sz = math.cos(rz), math.sin(rz)
	-- Rx * Ry * Rz, column vectors.
	local r = v3(cy * cz, cx * sz + sx * sy * cz, sx * sz - cx * sy * cz)
	local u = v3(-cy * sz, cx * cz - sx * sy * sz, sx * cz + cx * sy * sz)
	local b = v3(sy, -sx * cy, cx * cy)
	return cf(v3(0, 0, 0), r, u, b)
end
CFrame.identity = CFrame.new()

-- ------------------------------------------------------------------- Colour
local C3 = {}
C3.__index = C3
local function c3(r, g, b) return setmetatable({ R = r, G = g, B = b }, C3) end
function C3:Lerp(o, t) return c3(self.R + (o.R - self.R) * t, self.G + (o.G - self.G) * t, self.B + (o.B - self.B) * t) end
Color3 = {
	new = function(r, g, b) return c3(r or 0, g or 0, b or 0) end,
	fromRGB = function(r, g, b) return c3(r / 255, g / 255, b / 255) end,
}
BrickColor = { new = function(name) return { Name = name } end }
ColorSequence = { new = function(...) return { ... } end }
ColorSequenceKeypoint = { new = function(...) return { ... } end }
NumberSequence = { new = function(...) return { ... } end }
NumberRange = { new = function(...) return { ... } end }
UDim = { new = function(...) return { ... } end }
UDim2 = { new = function(...) return {} end, fromScale = function() return {} end, fromOffset = function() return {} end }
PhysicalProperties = { new = function(...) return { ... } end }

-- ------------------------------------------------------------------- Random
local RNG = {}
RNG.__index = RNG
Random = {
	new = function(seed)
		return setmetatable({ s = (seed or 1) % 2147483647 }, RNG)
	end,
}
function RNG:_next()
	self.s = (self.s * 16807) % 2147483647
	return self.s / 2147483647
end
function RNG:NextNumber(a, b)
	if a == nil then return self:_next() end
	return a + self:_next() * (b - a)
end
function RNG:NextInteger(a, b) return math.floor(a + self:_next() * (b - a + 1) - 1e-9) end

-- --------------------------------------------------------------------- Enum
Enum = setmetatable({}, {
	__index = function(t, category)
		local group = setmetatable({}, {
			__index = function(_, item) return { Name = item, EnumType = category } end,
		})
		rawset(t, category, group)
		return group
	end,
})

-- ------------------------------------------------------------------ typeof
-- Roblox's `typeof` reports "Vector3", "CFrame", "Instance" and so on, and
-- game code guards on exactly those strings. Plain Luau would call every one
-- of these stand-ins a "table", so a guard like
--     if typeof(direction) ~= "Vector3" then return end
-- would reject perfectly good input and the test would quietly pass over a
-- code path it never actually ran.
__STUB_TYPEOF = true
local rawTypeof = typeof
local metatableNames = { [V3] = "Vector3", [CF] = "CFrame", [C3] = "Color3" }

function typeof(value)
	if type(value) == "table" then
		local mt = getmetatable(value)
		local named = mt and metatableNames[mt]
		if named then return named end
		if rawget(value, "_class") then return "Instance" end
	end
	return rawTypeof(value)
end

-- ----------------------------------------------------------------- Instance
STATS = { created = 0, byClass = {}, parts = {} }

local Inst = {}
Inst.__index = function(self, k)
	-- Properties win over class methods, so a harness can override
	-- WaitForChild the way a real instance's own children would.
	local props = rawget(self, "_props")
	if props and props[k] ~= nil then return props[k] end

	-- Position and Orientation are derived from CFrame on a real BasePart.
	-- Without this, code as ordinary as `head.Position` reads nil and the
	-- whole path silently bails — which is exactly how a working feature
	-- can look broken in a test.
	if k == "Position" and props and props.CFrame then
		return props.CFrame.Position
	end
	if k == "CFrame" and props and props.Position then
		return CFrame.new(props.Position)
	end

	return rawget(Inst, k)
end
Inst.__newindex = function(self, k, v)
	if k == "Parent" then
		local old = rawget(self, "_parent")
		if old then
			for i, c in old._children do
				if c == self then table.remove(old._children, i) break end
			end
		end
		rawset(self, "_parent", v)
		-- Readable as well as writable. Without this, code that checks
		-- `instance.Parent` to see whether something still exists sees nil
		-- for everything, and silently skips it.
		rawget(self, "_props").Parent = v
		if v and v._children then table.insert(v._children, self) end
		return
	end
	self._props[k] = v
end

local function newInstance(class)
	STATS.created += 1
	STATS.byClass[class] = (STATS.byClass[class] or 0) + 1
	local self = setmetatable({
		_class = class,
		_children = {},
		_parent = nil,
		_attrs = {},
		_props = { Name = class },
	}, Inst)
	if class == "Part" or class == "SpawnLocation" or class == "Seat" or class == "VehicleSeat" then
		table.insert(STATS.parts, self)
	end
	return self
end

function Inst:IsA(c) return self._class == c or (c == "BasePart" and (self._class == "Part" or self._class == "SpawnLocation")) end
function Inst:Destroy() self.Parent = nil end
function Inst:SetAttribute(k, v) self._attrs[k] = v end
function Inst:GetAttribute(k) return self._attrs[k] end
function Inst:FindFirstChild(n)
	for _, c in self._children do if c._props.Name == n then return c end end
	return nil
end
function Inst:FindFirstChildOfClass(c)
	for _, ch in self._children do if ch._class == c then return ch end end
	return nil
end
function Inst:WaitForChild(n) return self:FindFirstChild(n) or newInstance("Folder") end
function Inst:GetChildren() return self._children end
function Inst:PivotTo(cf)
	local primary = self._props.PrimaryPart
	if primary then primary._props.CFrame = cf end
	self._props.CFrame = cf
end
function Inst:GetPivot()
	local primary = self._props.PrimaryPart
	return (primary and primary._props.CFrame) or self._props.CFrame or CFrame.new()
end
function Inst:GetDescendants()
	local out = {}
	local function walk(node)
		for _, c in node._children do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end

Instance = { new = function(class) return newInstance(class) end }

workspace = newInstance("Workspace")
game = {
	GetService = function(_, name)
		local svc = newInstance(name)
		return svc
	end,
}

task = {
	delay = function() end,
	spawn = function(fn, ...) end,
	wait = function() end,
}
