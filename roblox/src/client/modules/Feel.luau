--!strict
--[[
	Nuclear Mud Arena — how the camera reacts to what you do.

	Applies framerate-independent Perlin-noise trauma shake and recoil kick to
	the camera AFTER Roblox's camera update, and strips that offset back off
	BEFORE the next frame's camera/aim calculations so visual rattle never
	shifts where bullets go or compounds on Scriptable cameras.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Feel = {}

local kickPitch = 0
local kickYaw = 0
local shake = 0
local elapsed = 0
local lastOffset = CFrame.identity

local KICK_RECOVERY = 0.09
local SHAKE_RECOVERY = 0.24
local SHAKE_FREQUENCY = 22

local MAX_KICK = 7
local MAX_SHAKE = 4

local started = false

function Feel.Kick(degrees: number)
	if not (degrees > 0) or degrees == math.huge then
		return
	end
	kickPitch = math.min(kickPitch + degrees, MAX_KICK)
	kickYaw = math.clamp(kickYaw + (math.random() - 0.5) * degrees * 0.6, -MAX_KICK, MAX_KICK)
end

function Feel.Shake(degrees: number)
	if not (degrees > 0) or degrees == math.huge then
		return
	end
	shake = math.min(math.max(shake, degrees), MAX_SHAKE)
end

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

function Feel.Start()
	if started then
		return
	end
	started = true
	lastOffset = CFrame.identity

	-- Strip the previous frame's visual offset before Roblox's camera controller
	-- and before any Heartbeat aim reads so visual shake never corrupts aim.
	RunService:BindToRenderStep("FeelCameraReset", Enum.RenderPriority.Camera.Value - 1, function()
		if lastOffset == CFrame.identity then
			return
		end
		local camera = Workspace.CurrentCamera
		if camera then
			camera.CFrame = camera.CFrame * lastOffset:Inverse()
		end
		lastOffset = CFrame.identity
	end)

	RunService:BindToRenderStep("FeelCamera", Enum.RenderPriority.Camera.Value + 1, function(deltaTime: number)
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end

		elapsed += deltaTime

		local kickFade = math.exp(-deltaTime / KICK_RECOVERY)
		kickPitch *= kickFade
		kickYaw *= kickFade

		local shakeFade = math.exp(-deltaTime / SHAKE_RECOVERY)
		shake *= shakeFade

		if kickPitch < 0.04 then
			kickPitch = 0
		end
		if kickYaw > -0.04 and kickYaw < 0.04 then
			kickYaw = 0
		end
		if shake < 0.04 then
			shake = 0
		end

		if kickPitch == 0 and kickYaw == 0 and shake == 0 then
			lastOffset = CFrame.identity
			return
		end

		-- Smooth framerate-independent Perlin noise scaled quadratically for
		-- punchy initial trauma that settles organically.
		local trauma = (shake / MAX_SHAKE)
		local amp = MAX_SHAKE * trauma * trauma
		local sample = elapsed * SHAKE_FREQUENCY
		local rattlePitch = math.noise(sample, 1.37) * amp
		local rattleYaw = math.noise(sample, 7.91) * amp
		local rattleRoll = math.noise(sample, 14.53) * amp * 0.6

		local offset = CFrame.Angles(
			math.rad(kickPitch + rattlePitch),
			math.rad(kickYaw + rattleYaw),
			math.rad(rattleRoll)
		)
		camera.CFrame = camera.CFrame * offset
		lastOffset = offset
	end)
end

function Feel.Stop()
	if not started then
		return
	end
	started = false
	if lastOffset ~= CFrame.identity then
		local camera = Workspace.CurrentCamera
		if camera then
			camera.CFrame = camera.CFrame * lastOffset:Inverse()
		end
		lastOffset = CFrame.identity
	end
	kickPitch, kickYaw, shake = 0, 0, 0
	RunService:UnbindFromRenderStep("FeelCameraReset")
	RunService:UnbindFromRenderStep("FeelCamera")
end

function Feel.Debug(): { kick: number, yaw: number, shake: number }
	return { kick = kickPitch, yaw = kickYaw, shake = shake }
end

return Feel
