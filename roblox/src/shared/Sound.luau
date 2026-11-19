--!strict
--[[
	Sound — one place that plays everything.

	Two ways to use it:
	  Sound.At(name, position)   a noise somewhere in the world, heard louder
	                             the closer you are to it
	  Sound.Flat(name)           a noise in your ears, for the player it
	                             happened to — hitmarkers, medals, pickups

	Every asset is an rbxasset:// file built into the Roblox client, so none of
	them can fail to load the way a numeric asset ID can. The variety comes
	from pitching the same handful of files differently.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Sound = {}

local rng = Random.new()

-- Beyond this, you cannot hear it at all.
local WORLD_RANGE = 420

--[[ Build a Sound from a config entry, without playing it. ]]
local function build(name: string): Instance?
	local spec = Config.Sounds[name]
	if not spec then
		-- A typo in a sound name should not take down whatever was happening.
		warn(`Sound: no such sound "{name}"`)
		return nil
	end

	local sound = Instance.new("Sound")
	sound.Name = `Sound_{name}`
	sound.SoundId = spec.Asset
	sound.Volume = spec.Volume
	sound.PlaybackSpeed = rng:NextNumber(spec.Pitch[1], spec.Pitch[2] or spec.Pitch[1])
	sound.Looped = spec.Looped == true
	sound.RollOffMaxDistance = WORLD_RANGE
	sound.RollOffMinDistance = 12
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	return sound
end

--[[
	A noise at a place in the world.

	The Sound hangs on a tiny invisible anchor part, because a Sound only
	plays positionally when it has a part to play from, and the anchor is
	cleaned up a few seconds later.
]]
function Sound.At(name: string, position: Vector3, volumeScale: number?)
	local sound = build(name)
	if not sound then
		return
	end
	local real = sound :: Sound

	if volumeScale then
		real.Volume *= volumeScale
	end

	local anchor = Instance.new("Part")
	anchor.Name = "SoundAnchor"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Parent = workspace

	real.Parent = anchor
	real:Play()

	Debris:AddItem(anchor, 6)
end

--[[
	The same noise several times at once, at spread pitches.

	This is how you make a crowd out of a groan, or a clatter out of one
	collide: a single file played once is one voice, and several of the same
	file at different pitches is a mass of them. The alternative was a
	numeric asset ID for a real crowd recording, which can fail to load in
	an unpublished place -- and a goal horn that sometimes does not exist is
	worse than one made of a bass note.

	The voices are staggered by a few milliseconds as well as detuned,
	because perfectly simultaneous copies phase into one louder copy rather
	than into a crowd.
]]
function Sound.Chorus(name: string, position: Vector3, voices: number, volumeScale: number?)
	local count = math.clamp(voices, 1, 8)
	for index = 1, count do
		local delay = (index - 1) * 0.035
		if delay <= 0 then
			Sound.At(name, position, volumeScale)
		else
			task.delay(delay, function()
				Sound.At(name, position, volumeScale)
			end)
		end
	end
end

--[[
	A noise in one player's ears, with no position at all.

	Client only — on the server there is nobody to hear it.
]]
function Sound.Flat(name: string, volumeScale: number?)
	if not RunService:IsClient() then
		return
	end
	local sound = build(name)
	if not sound then
		return
	end
	local real = sound :: Sound

	if volumeScale then
		real.Volume *= volumeScale
	end
	real.RollOffMaxDistance = 1
	real.Parent = SoundService
	real:Play()

	Debris:AddItem(real, 6)
end

--[[
	A looping sound attached to something that moves — an engine, mostly.

	Returns the Sound so the caller can change its pitch as the thing speeds
	up, or stop it when the thing is switched off.
]]
function Sound.Attach(name: string, to: BasePart): Sound?
	local sound = build(name)
	if not sound then
		return nil
	end
	local real = sound :: Sound
	real.Parent = to
	return real
end

--[[ Which gunshot a weapon should make, from its category. ]]
function Sound.ForWeapon(spec: Config.WeaponSpec): string
	if spec.CanMegaDetonate then
		return "ShotDiamond"
	end
	local category = spec.Category
	if category == "Sniper" then
		return "ShotSniper"
	elseif category == "Shotgun" then
		return "ShotShotgun"
	elseif category == "Explosive" then
		return "ShotLaunch"
	elseif category == "Sidearm" then
		return "ShotLight"
	elseif category == "Utility" then
		return "ShotLaunch"
	end
	return "ShotHeavy"
end

return Sound
