--!strict
--[[
	Props — the things in the world that move purely for the look of them.

	A pickup floats and turns on the spot. That animation was being written
	on the SERVER, one CFrame per pickup per frame: roughly seventy-five
	pickups at sixty hertz is four and a half thousand property writes a
	second, and a CFrame write on a part in workspace is replicated to every
	client. Twenty players, and the server spent a measurable slice of every
	frame telling twenty machines about a spin that is identical on all of
	them, computed from nothing but the clock.

	So it belongs here, for the same reason night vision belongs on the
	camera: it is per-viewer by construction. Every client can work out
	`CFrame.Angles(0, clock * 1.5, 0)` for itself, nobody needs to be told,
	and a pickup that turns a frame out of step with somebody else's screen
	is a difference no player can observe.

	What stays on the server is the part that is actually state: whether a
	pickup has respawned yet, and who touched it. Those are decisions, and
	decisions are not cosmetic.

	The home position is read from the part once, when it appears, rather
	than tracked every frame -- the server places it and never moves it
	again, so the first reading is the only one needed and the spin is
	applied around it.
]]

local RunService = game:GetService("RunService")

local Props = {}

local SPIN_RATE = 1.5
local BOB_RATE = 2
local BOB_HEIGHT = 0.8

local started = false

-- Each pickup and the spot the server put it, so the animation has
-- something to turn around that does not drift.
local spinning: { [BasePart]: Vector3 } = {}

local function watch(thing: Instance)
	if thing:IsA("BasePart") and string.sub(thing.Name, 1, 7) == "Pickup_" then
		spinning[thing] = thing.CFrame.Position
	end
end

local function forget(thing: Instance)
	if thing:IsA("BasePart") then
		spinning[thing] = nil
	end
end

--[[ Follow one folder of pickups: whatever is in it, and whatever arrives. ]]
local function follow(folder: Instance)
	table.clear(spinning)
	for _, child in folder:GetChildren() do
		watch(child)
	end
	folder.ChildAdded:Connect(watch)
	folder.ChildRemoved:Connect(forget)
end

function Props.Start()
	if started then
		return
	end
	started = true

	-- The folder is rebuilt from scratch at every round change, so this
	-- watches for its replacement rather than binding to one instance.
	local existing = workspace:FindFirstChild("Pickups")
	if existing then
		follow(existing)
	end
	workspace.ChildAdded:Connect(function(child: Instance)
		if child.Name == "Pickups" then
			follow(child)
		end
	end)
	workspace.ChildRemoved:Connect(function(child: Instance)
		if child.Name == "Pickups" then
			table.clear(spinning)
		end
	end)

	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		-- One rotation and one height for the whole set: they all turn
		-- together, which is what made the server's per-part write so
		-- obviously wasteful in the first place.
		local spin = CFrame.Angles(0, now * SPIN_RATE, 0)
		local bob = math.sin(now * BOB_RATE) * BOB_HEIGHT

		for part, home in spinning do
			if part.Parent then
				part.CFrame = CFrame.new(home + Vector3.new(0, bob, 0)) * spin
			else
				spinning[part] = nil
			end
		end
	end)
end

--[[ For tests: how many props are being animated. ]]
function Props.CountForTests(): number
	local total = 0
	for _ in spinning do
		total += 1
	end
	return total
end

--[[ For tests. ]]
function Props.ResetForTests()
	started = false
	table.clear(spinning)
end

return Props
