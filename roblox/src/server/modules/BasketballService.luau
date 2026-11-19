--!strict
--[[
	BasketballService — a court, a hoop, and a ball you can shoot while
	being shot at.

	Adapted from the pasted basketball server rather than dropped in beside
	it, for one reason that shapes everything else: the pasted version was a
	self-contained minigame with its own round timer, its own score and its
	own idea of how to shoot. This map already has answers to all three --
	ArcadeService owns venues and staffing, PlayerState owns scoring, and the
	context router owns what a key means. A parallel set of those would be a
	second game living inside the first.

	So what is kept is the part that is actually basketball:

	- A charged shot. Hold to wind up, release to shoot, and the power
	  decides the arc. A tap drops it at your feet and a full charge sails
	  over, which means the shot is a judgement rather than a button.
	- A hoop with a real rim and backboard, so a bad shot can bounce off
	  them. A sensor that only counts a ball falling DOWNWARD through it,
	  because a ball thrown up through the net from underneath is not a
	  basket.
	- Two points, or three from behind the arc, because that distinction is
	  the whole shape of the sport.

	And what is dropped is the 30-second round: a basketball game that locks
	you out when the clock runs down would be the one activity on this map
	you cannot wander into, and the arena round is already the clock.

	The ball is a physical part, not a raycast. It can be shot out of the
	air, run over by a car, and blown up -- which is the entire point of
	putting a basketball court in a shooter.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Signal = require(Shared:WaitForChild("Signal"))
local Sound = require(Shared:WaitForChild("Sound"))
local Util = require(Shared:WaitForChild("Util"))

local ArcadeService = require(script.Parent:WaitForChild("ArcadeService"))
local MedalService = require(script.Parent:WaitForChild("MedalService"))
local PlayerState = require(script.Parent:WaitForChild("PlayerState"))

local BasketballService = {}

--[[ Fired as (player, points, fromThree) when somebody scores. ]]
BasketballService.Scored = Signal.new()

local court: Model? = nil
local ball: BasePart? = nil
local ballHome = Vector3.new()
local hoops: { { sensor: BasePart, at: Vector3 } } = {}

-- Who has the ball, and who may not pick it up yet.
local holder: Player? = nil
local blockedUntil: { [Player]: number } = {}

-- Charging state, server-side so a client cannot claim a full charge it did
-- not wait for.
local chargeStartedAt: { [Player]: number } = {}

local lastBasketAt = 0
local started = false

--[[ Build one hoop: post, backboard, rim, net and the sensor under it. ]]
local function buildHoop(at: Vector3, facing: number, parent: Instance)
	local post = Util.Part({
		Name = "HoopPost",
		Size = Vector3.new(1.4, 14, 1.4),
		Position = at + Vector3.new(0, 7, 0),
		Color = Color3.fromRGB(60, 64, 72),
		Material = Enum.Material.Metal,
		Anchored = true,
		Parent = parent,
	})

	local board = Util.Part({
		Name = "Backboard",
		Size = Vector3.new(12, 7, 0.5),
		Position = at + Vector3.new(0, 15, facing * 1.4),
		Color = Color3.fromRGB(236, 240, 246),
		Material = Enum.Material.Glass,
		Transparency = 0.35,
		Anchored = true,
		Parent = parent,
	})
	local _ = post

	--[[
		The rim, as four blocks in a square rather than a torus.

		Roblox has no ring primitive, and a cylinder would be a solid lid
		the ball could never fall through. Four thin blocks leave a real
		hole in the middle with real edges to rattle off, which is what a
		rim is for.
	]]
	local RIM = 5.2
	for index, offset in {
		Vector3.new(-RIM * 0.5, 0, 0),
		Vector3.new(RIM * 0.5, 0, 0),
		Vector3.new(0, 0, -RIM * 0.5),
		Vector3.new(0, 0, RIM * 0.5),
	} do
		local alongX = index <= 2
		Util.Part({
			Name = "Rim",
			Size = if alongX then Vector3.new(0.4, 0.4, RIM) else Vector3.new(RIM, 0.4, 0.4),
			Position = at + Vector3.new(0, 13, facing * 5.2) + offset,
			Color = Color3.fromRGB(226, 108, 40),
			Material = Enum.Material.Metal,
			Anchored = true,
			Parent = parent,
		})
	end

	local net = Util.Part({
		Name = "Net",
		Size = Vector3.new(RIM, 2.4, RIM),
		Position = at + Vector3.new(0, 11.8, facing * 5.2),
		Color = Color3.fromRGB(250, 250, 250),
		Material = Enum.Material.Fabric,
		Transparency = 0.45,
		Anchored = true,
		CanCollide = false,
		-- A bullet must pass through the net rather than stopping in it.
		CanQuery = false,
		Parent = parent,
	})
	local _ = net

	--[[
		The sensor, below the rim.

		Below rather than inside, and checked for DOWNWARD travel, because a
		ball thrown up through the net from underneath is not a basket --
		and with a sensor in the rim's plane that is exactly what it would
		count as.
	]]
	local sensor = Util.Part({
		Name = "HoopSensor",
		Size = Vector3.new(RIM - 1, 1, RIM - 1),
		Position = at + Vector3.new(0, 10.4, facing * 5.2),
		Transparency = 1,
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		Parent = parent,
	})

	table.insert(hoops, { sensor = sensor, at = at })
	return board
end

--[[ Put the ball back under the hoop. ]]
local function resetBall()
	local live = ball
	if not live or not live.Parent then
		return
	end
	holder = nil
	live.AssemblyLinearVelocity = Vector3.new()
	live.AssemblyAngularVelocity = Vector3.new()
	live.CFrame = CFrame.new(ballHome)
end

--[[ Somebody put it through. ]]
local function basket(scorer: Player?, hoopAt: Vector3)
	local now = os.clock()
	if now - lastBasketAt < 1.5 then
		return
	end
	lastBasketAt = now

	local live = ball
	local from = if live then live.Position else hoopAt

	--[[
		Two, or three from behind the arc.

		Measured from where the ball WAS when it went in rather than from
		where the shooter is standing now, because the shooter has very
		likely been running since -- and the shot was taken from where it
		left their hands, not from wherever they ended up.
	]]
	local flat = Vector3.new(from.X - hoopAt.X, 0, from.Z - hoopAt.Z)
	local fromThree = flat.Magnitude >= Config.Basketball.ThreeLine

	local points = if fromThree
		then Config.Basketball.ThreePoints
		else Config.Basketball.TwoPoints

	Sound.At("Bell", hoopAt + Vector3.new(0, 12, 0), 0.9)
	Sound.Chorus("CrowdVoice", hoopAt, 4, 0.7)

	if scorer and scorer.Parent then
		PlayerState.AwardPoints(scorer, points, if fromThree then "three pointer" else "basket")
		if fromThree then
			MedalService.Award(scorer, "ThreePointer")
		end
		Remotes.Event("KillFeed"):FireAllClients(
			`{scorer.DisplayName} scored {if fromThree then "a three" else "a basket"}`,
			false
		)
	end

	BasketballService.Scored.Fire(scorer, points, fromThree)
	resetBall()
end

--[[
	Pick the ball up by walking into it, and carry it in front of you.

	The same shape as the puck: possession is proximity, not a button, so
	there is nothing to learn. Carrying it is what puts SHOOT on the action
	bar.
]]
local function stepPossession()
	local live = ball
	if not live or not live.Parent then
		return
	end

	local now = os.clock()

	if holder then
		local character = holder.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if
			not holder.Parent
			or not root
			or not root:IsA("BasePart")
			or not humanoid
			or humanoid.Health <= 0
		then
			-- Dropped on death, where they died. A dead player keeping the
			-- ball would park the game until they respawned.
			holder = nil
			return
		end

		local carry = root.Position + root.CFrame.LookVector * Config.Basketball.CarryDistance
		local toward = carry - live.Position
		live.AssemblyLinearVelocity = toward * 18
		return
	end

	for _, player in Players:GetPlayers() do
		if now < (blockedUntil[player] or 0) then
			continue
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if
			not root
			or not root:IsA("BasePart")
			or not humanoid
			or humanoid.Health <= 0
		then
			continue
		end
		if (root.Position - live.Position).Magnitude <= Config.Basketball.PickupRange then
			holder = player
			live:SetAttribute("LastTouchUserId", player.UserId)
			Sound.At("Pickup", live.Position, 0.6)
			Remotes.Event("BallCarry"):FireClient(player, { carrying = true })
			return
		end
	end
end

--[[ Did the ball just fall through a hoop? ]]
local function stepHoops()
	local live = ball
	if not live or not live.Parent then
		return
	end

	-- Only ever on the way DOWN. Up through the net is not a basket.
	if live.AssemblyLinearVelocity.Y >= 0 then
		return
	end

	for _, hoop in hoops do
		local offset = live.Position - hoop.sensor.Position
		local half = hoop.sensor.Size * 0.5
		if
			math.abs(offset.X) <= half.X
			and math.abs(offset.Y) <= half.Y + 1
			and math.abs(offset.Z) <= half.Z
		then
			local userId = live:GetAttribute("LastTouchUserId")
			local scorer: Player? = nil
			if typeof(userId) == "number" then
				scorer = Players:GetPlayerByUserId(userId)
			end
			basket(scorer, hoop.at)
			return
		end
	end
end

--[[
	Start winding up a shot.

	The charge is timed on the SERVER. A client that simply announced "full
	power" would be claiming a wind-up it never waited through, and the
	whole shot is the wind-up.
]]
function BasketballService.StartCharge(player: Player)
	if holder ~= player then
		return
	end
	chargeStartedAt[player] = os.clock()
end

--[[ Let go, and throw it as hard as the wind-up earned. ]]
function BasketballService.Release(player: Player, direction: Vector3?)
	local live = ball
	if holder ~= player or not live or not live.Parent then
		return
	end

	local began = chargeStartedAt[player]
	chargeStartedAt[player] = nil

	local held = if began then os.clock() - began else 0
	local power = math.clamp(held / Config.Basketball.FullChargeSeconds, 0.15, 1)

	local aim = Util.SaneDirection(direction)
	if not aim then
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		aim = if root and root:IsA("BasePart") then root.CFrame.LookVector else Vector3.new(0, 0, -1)
	end

	holder = nil
	-- Cannot immediately scoop up your own shot, or a tap next to the hoop
	-- becomes an infinite dunk.
	blockedUntil[player] = os.clock() + Config.Basketball.ReclaimDelay

	--[[
		The arc.

		Lift is a fixed fraction of the throw rather than a constant,
		because a constant lift makes a soft shot float and a hard one skim.
		Scaling together keeps the shape of the arc the same at every power,
		so aiming is a skill you can actually learn.
	]]
	local speed = Config.Basketball.ThrowSpeed * power
	live.AssemblyLinearVelocity = aim * speed
		+ Vector3.new(0, speed * Config.Basketball.LiftFactor, 0)

	Sound.At("MeleeSwing", live.Position, 0.5)
	Remotes.Event("BallCarry"):FireClient(player, { carrying = false })
end

--[[ A bullet can move the ball, exactly as it can move the puck. ]]
function BasketballService.RegisterHit(part: BasePart, attacker: Player?, direction: Vector3?): boolean
	local live = ball
	if not live or part ~= live then
		return false
	end

	local aim = Util.SaneDirection(direction)
	if aim then
		live.AssemblyLinearVelocity = aim * Config.Basketball.ShotNudge
			+ Vector3.new(0, Config.Basketball.ShotNudge * 0.35, 0)
	end
	if attacker then
		live:SetAttribute("LastTouchUserId", attacker.UserId)
		holder = nil
	end
	return true
end

function BasketballService.Clear()
	if court then
		court:Destroy()
		court = nil
	end
	ball = nil
	holder = nil
	table.clear(hoops)
	table.clear(blockedUntil)
	table.clear(chargeStartedAt)
end

--[[ Where the court will be, so the city leaves room for it. ]]
function BasketballService.ReservedArea(mapSize: number): { centre: Vector3, radius: number }
	return {
		centre = Config.VenueCentre("Basketball", mapSize),
		radius = Config.Venues.Basketball.radius,
	}
end

function BasketballService.Build(mapSize: number)
	BasketballService.Clear()

	local model = Instance.new("Model")
	model.Name = "BasketballCourt"
	court = model

	-- Opposite the carnival and clear of the rink, so the three
	-- distractions are in three different directions.
	local centre = Config.VenueCentre("Basketball", mapSize)

	Util.Part({
		Name = "Court",
		Size = Vector3.new(Config.Basketball.CourtWidth, 1, Config.Basketball.CourtLength),
		Position = centre + Vector3.new(0, 0.5, 0),
		Color = Color3.fromRGB(176, 108, 62),
		Material = Enum.Material.Concrete,
		Anchored = true,
		Parent = model,
	})

	-- The arc, painted on, so a three looks like a three before you take it.
	for _, end_ in { -1, 1 } do
		for step = 0, 16 do
			local angle = (step / 16) * math.pi - math.pi * 0.5
			Util.Part({
				Name = "ThreeLine",
				Size = Vector3.new(1.6, 0.2, 1.6),
				Position = centre
					+ Vector3.new(
						math.cos(angle) * Config.Basketball.ThreeLine,
						1.05,
						end_ * (Config.Basketball.CourtLength * 0.5 - 8)
							- end_ * math.abs(math.sin(angle)) * Config.Basketball.ThreeLine
					),
				Color = Color3.fromRGB(246, 246, 250),
				Material = Enum.Material.SmoothPlastic,
				Anchored = true,
				CanCollide = false,
				CanQuery = false,
				Parent = model,
			})
		end
	end

	local far = Config.Basketball.CourtLength * 0.5 - 6
	buildHoop(centre + Vector3.new(0, 1, -far), 1, model)
	buildHoop(centre + Vector3.new(0, 1, far), -1, model)

	ballHome = centre + Vector3.new(0, 4, 0)
	local live = Util.Part({
		Name = "Basketball",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(2.4, 2.4, 2.4),
		-- CFrame rather than Position: the ball is moved by CFrame
		-- everywhere else (resetting it, putting it back after a basket),
		-- and a part carrying both can disagree with itself.
		CFrame = CFrame.new(ballHome),
		Color = Color3.fromRGB(226, 108, 40),
		Material = Enum.Material.SmoothPlastic,
		Anchored = false,
		-- Bouncy, and light enough that a bullet moves it.
		CustomPhysicalProperties = PhysicalProperties.new(0.6, 0.4, 0.75, 1, 1),
		Parent = model,
	})
	ball = live

	model.Parent = workspace

	ArcadeService.Register({
		id = "basketball",
		name = "Basketball",
		objective = "Hold F to wind up, release to shoot. Three from behind the arc.",
		centre = centre,
		spawns = {
			centre + Vector3.new(-18, 4, 0),
			centre + Vector3.new(18, 4, 0),
			centre + Vector3.new(0, 4, -24),
			centre + Vector3.new(0, 4, 24),
		},
		perTeam = 3,
		teamed = true,
		colour = Color3.fromRGB(226, 108, 40),
	})

	return { centre = centre, ball = live }
end

function BasketballService.Start()
	if started then
		return
	end
	started = true

	Remotes.Event("BallCharge").OnServerEvent:Connect(function(player: Player, on)
		if on == true then
			BasketballService.StartCharge(player)
		else
			BasketballService.Release(player, nil)
		end
	end)

	Remotes.Event("BallShoot").OnServerEvent:Connect(function(player: Player, direction)
		BasketballService.Release(player, if typeof(direction) == "Vector3" then direction else nil)
	end)

	RunService.Heartbeat:Connect(function()
		stepPossession()
		stepHoops()
	end)

	Players.PlayerRemoving:Connect(function(player)
		if holder == player then
			holder = nil
		end
		blockedUntil[player] = nil
		chargeStartedAt[player] = nil
	end)
end

--[[ For tests. ]]
function BasketballService.Ball(): BasePart?
	return ball
end

function BasketballService.Holder(): Player?
	return holder
end

function BasketballService.HoopCount(): number
	return #hoops
end

function BasketballService.StepForTests()
	stepPossession()
	stepHoops()
end

function BasketballService.GiveBallForTests(player: Player)
	holder = player
	local live = ball
	if live then
		live:SetAttribute("LastTouchUserId", player.UserId)
	end
end

return BasketballService
