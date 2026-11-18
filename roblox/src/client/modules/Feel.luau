--!strict
--[[
	Nuclear Mud Arena — how the camera reacts to what you do.

	Shooting in Halo felt like shooting because the camera moved. The rifle
	pushed the view up a little and it settled back; a rocket landing nearby
	rattled everything; a hard landing jolted you. None of it changes where a
	bullet goes, and that is the point — this module never touches aim, only
	the camera, so the game stays as accurate as it was before and simply
	stops feeling like a spreadsheet.

	Everything decays on its own, so a dropped frame or a missed event can
	never leave the camera stuck off-axis.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Feel = {}

-- Degrees of accumulated kick, and how fast it is bleeding off.
local kickPitch = 0
local kickYaw = 0

-- Shake amplitude, in degrees, and its own decay.
local shake = 0

-- How quickly a kick settles back. Smaller is snappier. 0.09 of a second is
-- about where a burst reads as a burst rather than a slow drift upward.
local KICK_RECOVERY = 0.09
local SHAKE_RECOVERY = 0.22

-- Hard ceilings. A minigun held down, or three rockets at once, must never
-- spin the view somewhere a player cannot recover from.
local MAX_KICK = 7
local MAX_SHAKE = 4

local started = false

--[[
	Kick the view, once, for one shot.

	`degrees` comes from the weapon's own Recoil value, so a sniper shoves and
	a minigun buzzes. The sideways component is randomised, which is what
	stops a long burst from walking the camera in a perfectly straight line.
]]
function Feel.Kick(degrees: number)
	if degrees <= 0 then
		return
	end
	kickPitch = math.min(kickPitch + degrees, MAX_KICK)
	kickYaw = math.clamp(kickYaw + (math.random() - 0.5) * degrees * 0.6, -MAX_KICK, MAX_KICK)
end

--[[ Rattle the camera: explosions, taking a hit, a heavy landing. ]]
function Feel.Shake(degrees: number)
	shake = math.min(math.max(shake, degrees), MAX_SHAKE)
end

--[[
	Shake scaled by how far away the bang was.

	A rocket at your feet should be violent and the same rocket across the map
	should do nothing at all, which a flat shake for every explosion gets
	wrong in both directions.
]]
function Feel.ShakeFrom(position: Vector3, degrees: number, falloff: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local distance = (camera.CFrame.Position - position).Magnitude
	local scale = math.clamp(1 - distance / math.max(falloff, 1), 0, 1)
	if scale > 0 then
		Feel.Shake(degrees * scale * scale)
	end
end

--[[
	Start driving the camera.

	This has to run AFTER Roblox's own camera update, or the engine would
	overwrite the offset in the same frame and nothing would move. That is
	what the priority is for.
]]
function Feel.Start()
	if started then
		return
	end
	started = true

	RunService:BindToRenderStep("FeelCamera", Enum.RenderPriority.Camera.Value + 1, function(deltaTime: number)
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end

		-- Exponential decay, framerate-independent: at 30fps and at 240fps
		-- a kick takes the same amount of time to settle.
		local kickFade = math.exp(-deltaTime / KICK_RECOVERY)
		kickPitch *= kickFade
		kickYaw *= kickFade

		local shakeFade = math.exp(-deltaTime / SHAKE_RECOVERY)
		shake *= shakeFade

		-- Below a twentieth of a degree nobody can see it, and leaving it to
		-- decay forever means every frame pays for arithmetic on nothing.
		if kickPitch < 0.05 then kickPitch = 0 end
		if kickYaw > -0.05 and kickYaw < 0.05 then kickYaw = 0 end
		if shake < 0.05 then shake = 0 end

		if kickPitch == 0 and kickYaw == 0 and shake == 0 then
			return
		end

		local rattlePitch = (math.random() - 0.5) * shake
		local rattleYaw = (math.random() - 0.5) * shake
		local rattleRoll = (math.random() - 0.5) * shake * 0.5

		camera.CFrame = camera.CFrame * CFrame.Angles(
			math.rad(kickPitch + rattlePitch),
			math.rad(kickYaw + rattleYaw),
			math.rad(rattleRoll)
		)
	end)
end

--[[ Let go of the camera completely. Used by the tests. ]]
function Feel.Stop()
	if not started then
		return
	end
	started = false
	kickPitch, kickYaw, shake = 0, 0, 0
	RunService:UnbindFromRenderStep("FeelCamera")
end

--[[ What the camera is currently doing, for tests and for the HUD. ]]
function Feel.Debug(): { kick: number, yaw: number, shake: number }
	return { kick = kickPitch, yaw = kickYaw, shake = shake }
end

return Feel
