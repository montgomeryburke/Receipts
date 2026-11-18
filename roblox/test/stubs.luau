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
-- A BrickColor carries a real Color3 in `.Color`, and game code reads it to
-- tint things by team. Without it every such read came back nil and the
-- failure surfaced somewhere else entirely.
local BRICK_COLORS = {
	["Bright red"] = { 196, 40, 28 },
	["Bright blue"] = { 13, 105, 172 },
	["Bright green"] = { 75, 151, 75 },
	["Bright yellow"] = { 245, 205, 48 },
	["Medium stone grey"] = { 163, 162, 165 },
	["Really black"] = { 17, 17, 17 },
	["Institutional white"] = { 248, 248, 248 },
}

-- A tween's own description. Missing, every call that animated anything
-- threw on TweenInfo.new -- and because those calls sit inside pcall-guarded
-- start-up paths, the failure showed up as an unrelated function not working.
TweenInfo = {
	new = function(time, style, direction, repeatCount, reverses, delayTime)
		return {
			Time = time or 1,
			EasingStyle = style,
			EasingDirection = direction,
			RepeatCount = repeatCount or 0,
			Reverses = reverses or false,
			DelayTime = delayTime or 0,
		}
	end,
}

BrickColor = {
	new = function(name)
		local rgb = BRICK_COLORS[name] or { 163, 162, 165 }
		return { Name = name, Color = Color3.fromRGB(rgb[1], rgb[2], rgb[3]) }
	end,
}
ColorSequence = { new = function(...) return { ... } end }
ColorSequenceKeypoint = { new = function(...) return { ... } end }
NumberSequence = { new = function(...) return { ... } end }
NumberSequenceKeypoint = { new = function(...) return { ... } end }
Ray = { new = function(...) return { ... } end }
Region3 = { new = function(...) return { ... } end }
Rect = { new = function(...) return { ... } end }
NumberRange = { new = function(...) return { ... } end }
-- UDim and UDim2 were hollow: UDim2.new(...) returned an empty table, so a
-- test could not read back where anything had been placed. Every layout bug
-- was invisible by construction. These carry the real fields.
local function udim(scale: number?, offset: number?)
	return { Scale = scale or 0, Offset = offset or 0 }
end

UDim = { new = function(scale, offset) return udim(scale, offset) end }

UDim2 = {
	new = function(xScale, xOffset, yScale, yOffset)
		return { X = udim(xScale, xOffset), Y = udim(yScale, yOffset) }
	end,
	fromScale = function(x, y) return { X = udim(x, 0), Y = udim(y, 0) } end,
	fromOffset = function(x, y) return { X = udim(0, x), Y = udim(0, y) } end,
}
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
-- Roblox's enum items carry a numeric Value as well as a Name, and real code
-- does arithmetic on it: RenderPriority.Camera.Value + 1 is how you bind a
-- step that runs after the engine's own camera update. Returning an item with
-- no Value made that line throw.
local ENUM_VALUES = {
	RenderPriority = {
		First = 0, Input = 100, Camera = 200, Character = 300, Last = 2000,
	},
}

-- Enum items must be CACHED, not built fresh on every index.
--
-- Roblox enum items are singletons, and real code compares them by identity:
--     if input.KeyCode == Enum.KeyCode.G then
-- Handing back a new table each time made every one of those comparisons
-- false forever, so no keyboard or mouse handling in this game was testable
-- at all -- a test could fire an input event and the code under test would
-- simply ignore it, which looks exactly like a passing no-op.
Enum = setmetatable({}, {
	__index = function(t, category)
		local items = {}
		local group = setmetatable({}, {
			__index = function(_, item)
				local existing = items[item]
				if existing then
					return existing
				end
				local known = ENUM_VALUES[category]
				local made = {
					Name = item,
					EnumType = category,
					Value = (known and known[item]) or 0,
				}
				items[item] = made
				return made
			end,
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
-- Tests that exercise team assignment register their players here.
PLAYERS_FOR_TEAMS = {}

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
		-- Roblox locks Parent once an instance is destroyed. Allowing a
		-- destroyed instance back into the world let a test resurrect
		-- something the real engine would refuse, and hid stale-reference
		-- bugs where code hangs on to a thing after cleaning it up.
		if rawget(self, "_destroyed") and v ~= nil then
			error(
				`The Parent property of {tostring(rawget(self, "_props").Name or rawget(self, "_class"))}`
					.. " is locked, current parent: NULL",
				2
			)
		end
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

-- A Humanoid needs the methods game code actually calls on it, or damage
-- silently blows up inside the test rather than being measured.
local function fitOutHumanoid(inst)
	local props = rawget(inst, "_props")
	props.Health = props.Health or 100
	props.MaxHealth = props.MaxHealth or 100
	props.WalkSpeed = props.WalkSpeed or 16
	props.TakeDamage = function(self, amount)
		local p = rawget(self, "_props")
		p.Health = math.max(0, p.Health - amount)
	end
	props.MoveTo = function() end
	props.Move = function() end
end

--[[
	A signal, for harnesses that do not load serverstubs.

	The instance stand-ins below hand out signals for things like
	ProximityPrompt.Triggered. They used to write `SIGNAL and SIGNAL() or nil`,
	and SIGNAL is defined in serverstubs -- so in the map harness, which
	loads only this file, every one of those came out nil and any builder
	that wired up a prompt threw. Silently, because nil is a perfectly good
	value right up until something calls :Connect on it.
]]
local function localSignal()
	local handlers = {}
	local function disconnect(fn)
		for index, candidate in handlers do
			if candidate == fn then
				table.remove(handlers, index)
				return
			end
		end
	end
	return {
		Connect = function(_, fn)
			table.insert(handlers, fn)
			-- A real Disconnect, not a no-op. Code that connects, acts and
			-- disconnects was being left connected here, so anything that
			-- unsubscribes to avoid double work looked correct while doing
			-- the work twice.
			return {
				Disconnect = function()
					disconnect(fn)
				end,
			}
		end,
		-- What Destroy calls on every signal an instance owns.
		DisconnectAll = function()
			table.clear(handlers)
		end,
		Wait = function() end,
		_handlers = handlers,
		_fire = function(...)
			for _, fn in handlers do fn(...) end
		end,
	}
end

local function anySignal()
	-- Prefer the shared one when it exists, so a test that inspects
	-- SIGNAL-made signals still sees the same shape.
	if SIGNAL then
		return SIGNAL()
	end
	return localSignal()
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
	if class == "Part" or class == "SpawnLocation" or class == "Seat" or class == "VehicleSeat"
		or class == "TrussPart" or class == "WedgePart" or class == "MeshPart"
	then
		table.insert(STATS.parts, self)
		-- A part at rest reads as zero velocity, not nil. Leaving these out
		-- made any code that asks how fast something is moving throw, which
		-- is a crash in the harness for code that is perfectly correct.
		local partProps = rawget(self, "_props")
		partProps.AssemblyLinearVelocity = Vector3.new()
		if class == "VehicleSeat" then
			-- Roblox gives a VehicleSeat both stepped and analog inputs, and
			-- the analog pair is what smooth steering reads. Missing, every
			-- read of them came back nil and the drive loop threw.
			partProps.Throttle = 0
			partProps.Steer = 0
			partProps.ThrottleFloat = 0
			partProps.SteerFloat = 0
		end
		partProps.AssemblyAngularVelocity = Vector3.new()
		partProps.Velocity = Vector3.new()
	end
	if class == "Humanoid" then
		fitOutHumanoid(self)
	end

	-- Small no-op methods that game code calls on visual instances. Missing
	-- ones abort whatever thread they are in, which hides real behaviour
	-- behind an error that has nothing to do with the thing being tested.
	local props = rawget(self, "_props")

	--[[
		Every instance can be watched for a property change.

		This existed only in the server stand-ins, so anything on the client
		that watches a property -- a player's Team changing, a seat's
		occupant changing -- threw the moment it started. Inside a pcall
		that reads as a feature quietly declining to work, which is the
		worst way for a harness to fail.

		The SAME signal comes back for the same property, as in Roblox. A
		fresh one per call means the module that connects and the test that
		fires are holding two unrelated signals, and the wiring reads dead.
	]]
	local changedSignals = {}
	props.GetPropertyChangedSignal = function(_, property)
		local existing = changedSignals[property]
		if existing then
			return existing
		end
		local made = anySignal()
		changedSignals[property] = made
		return made
	end
	if class == "Team" then
		props.GetPlayers = function(self)
			local out = {}
			-- Whoever currently points at this team.
			for _, p in (PLAYERS_FOR_TEAMS or {}) do
				if rawget(p, "_props").Team == self then table.insert(out, p) end
			end
			return out
		end
	elseif class == "ParticleEmitter" then
		props.Emit = function() end
	elseif class == "Sound" then
		props.Play = function() end
		props.Stop = function() end
	elseif class == "Explosion" then
		props.Hit = anySignal()
	elseif class == "ProximityPrompt" then
		-- Prompts carry their own signals; without Triggered, every builder
		-- that wires one up throws while laying out the map.
		props.Triggered = anySignal()
		props.PromptShown = anySignal()
		props.PromptHidden = anySignal()
	elseif class == "TextButton" or class == "ImageButton" then
		-- Buttons carry their own click signals, so a test can tap one and
		-- see what happens rather than only that it was created.
		props.Activated = anySignal()
		props.MouseButton1Click = anySignal()
		props.MouseButton1Down = anySignal()
		props.MouseButton1Up = anySignal()
	end

	return self
end

function Inst:IsA(c) return self._class == c or (c == "BasePart" and (self._class == "Part" or self._class == "SpawnLocation")) end
--[[
	Destroy, recursively, the way Roblox does.

	The stand-in used to only unparent the instance itself, leaving every
	descendant still pointing at it. That matters because a great deal of
	this code guards on `thing.Parent` to ask "does this still exist?" --
	a delayed callback checking `humanoid.Parent` before touching it, a
	respawn timer checking its own part. With a shallow Destroy those guards
	all answered "yes, still here" after the parent model was destroyed, so
	a whole class of lifetime bug was invisible from a terminal.

	The child list is snapshotted before the loop, because each child's own
	Destroy removes it from that list.
]]
function Inst:Destroy()
	-- Idempotent. Destroying something twice is not an error in Roblox, and
	-- the second call must not walk a child list that is already gone.
	if rawget(self, "_destroyed") then
		return
	end
	rawset(self, "_destroyed", true)

	self.Parent = nil

	-- Snapshotted, because each child's own Destroy removes it from here.
	for _, child in table.clone(self._children) do
		child:Destroy()
	end

	--[[
		Drop every listener this instance owned.

		Roblox disconnects an instance's connections when it is destroyed. A
		destroyed part whose Touched handler still fires is worse than a
		missing feature: it makes a test pass that the real game would fail,
		which is the one outcome a harness must never produce. The signals
		already live in _props, so they are found rather than tracked.
	]]
	for _, value in rawget(self, "_props") do
		if type(value) == "table" and type(rawget(value, "DisconnectAll")) == "function" then
			value.DisconnectAll()
		end
	end
end

--[[ Empty an instance without destroying it. Snapshot, for the same reason. ]]
function Inst:ClearAllChildren()
	for _, child in table.clone(self._children) do
		child:Destroy()
	end
end
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
-- Walks the real parent chain. A stub that always returned nil made every
-- "which model does this part belong to" lookup fail silently.
function Inst:FindFirstAncestorOfClass(class)
	local node = rawget(self, "_parent")
	while node do
		if rawget(node, "_class") == class then return node end
		node = rawget(node, "_parent")
	end
	return nil
end
function Inst:FindFirstAncestor(name)
	local node = rawget(self, "_parent")
	while node do
		if rawget(node, "_props").Name == name then return node end
		node = rawget(node, "_parent")
	end
	return nil
end
--[[
	A COPY of the children, which is what Roblox returns.

	Handing back the live array meant the extremely ordinary
	`for _, child in parent:GetChildren() do child:Destroy() end` removed
	items from the table it was walking, so it cleared roughly every other
	child and left the rest behind. Correct code looked broken, and the
	stand-in was the thing that was wrong.
]]
function Inst:GetChildren()
	return table.clone(self._children)
end
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
