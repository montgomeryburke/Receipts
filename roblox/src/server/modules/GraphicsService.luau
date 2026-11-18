--!strict
--[[
	GraphicsService — makes it stop looking like a bin of bricks.

	Configures Future PBR lighting, 2022 surface materials, volumetric clouds,
	realistic river water, atmospheric depth, and crisp post-processing.
	No external asset IDs are used anywhere, so everything works offline or in
	an unpublished Studio place without throwing.

	THIS MODULE OWNS Lighting. Nothing else may write to it.

	Global lighting is a single shared resource with no merge: the last writer
	wins and the loser has no way to know it lost. Two scripts each setting a
	look they are happy with produces a third look neither of them wanted,
	and which one you get depends on service start order -- so it changes
	between runs and cannot be reproduced. A venue that wants its own mood
	uses local SpotLight and PointLight rigs inside itself: the hockey rink's
	stadium lights, the carnival's bulbs, the goal lamps. There is a test
	that fails if any other module writes a Lighting property.
]]

local Lighting = game:GetService("Lighting")
local MaterialService = game:GetService("MaterialService")

local GraphicsService = {}

--[[ Remove previous arena graphics and any default lighting clutter that would stack. ]]
local function clearPrevious()
	for _, child in Lighting:GetChildren() do
		if
			child:GetAttribute("ArenaGraphics")
			or child:IsA("Sky")
			or child:IsA("Atmosphere")
			or child:IsA("PostEffect")
		then
			child:Destroy()
		end
	end

	local terrain = workspace.Terrain
	if terrain then
		for _, child in terrain:GetChildren() do
			if child:GetAttribute("ArenaGraphics") or child:IsA("Clouds") then
				child:Destroy()
			end
		end
	end
end

local function tag(instance: Instance, parent: Instance?): Instance
	instance:SetAttribute("ArenaGraphics", true)
	instance.Parent = parent or Lighting
	return instance
end

function GraphicsService.Start()
	clearPrevious()

	-- Future lighting gives real per-pixel shadows, specular highlights, and
	-- local light pools. Technology is [NotScriptable] in live servers, so both
	-- assignments stay protected in pcall (and Future is also baked in the place).
	local ok = pcall(function()
		Lighting.Technology = Enum.Technology.Future
	end)
	if not ok then
		pcall(function()
			Lighting.Technology = Enum.Technology.ShadowMap
		end)
	end

	-- Enable 2022 PBR material textures (normal, roughness, metalness maps) so
	-- Concrete, Asphalt, Metal, Mud, Snow, Ice, and WoodPlanks catch real light.
	pcall(function()
		(MaterialService :: any).Use2022Materials = true
	end)

	--[[
		Mid-afternoon, not golden hour.

		This used to be a warm 16:20 sunset, which looked handsome in a
		screenshot and was bad to play in: long raking shadows swallowed
		whole streets, and a warm grade on mud-coloured terrain turned the
		map into one brown mass. A competitive shooter wants a readable
		frame first -- a higher sun with a crisp, nearly-hard shadow, cool
		sky fill so shadowed faces stay legible instead of going black, and
		saturation in the grade rather than in the sunlight.
	]]
	Lighting.Brightness = 3.0
	Lighting.ClockTime = 14.5
	Lighting.GeographicLatitude = 38
	Lighting.ExposureCompensation = 0.15
	Lighting.EnvironmentDiffuseScale = 0.85
	Lighting.EnvironmentSpecularScale = 1.0
	Lighting.GlobalShadows = true
	pcall(function()
		-- Sharp enough to read as a shadow edge rather than a smudge.
		Lighting.ShadowSoftness = 0.15
	end)

	-- Shadow fill is lifted deliberately. Pitch-black shade is where players
	-- disappear, and a player you cannot see is not a difficulty setting.
	Lighting.Ambient = Color3.fromRGB(70, 80, 95)
	Lighting.OutdoorAmbient = Color3.fromRGB(110, 125, 145)
	Lighting.ColorShift_Top = Color3.fromRGB(255, 250, 240)
	Lighting.ColorShift_Bottom = Color3.fromRGB(85, 105, 130)

	-- Atmospheric scattering and distance perspective.
	local atmosphere = Instance.new("Atmosphere")
	-- Enough haze to give the 2000-stud map depth, cool rather than dusty so
	-- it reads as distance instead of as fog you are standing in.
	atmosphere.Density = 0.24
	atmosphere.Offset = 0.25
	atmosphere.Color = Color3.fromRGB(195, 220, 255)
	atmosphere.Decay = Color3.fromRGB(120, 145, 185)
	atmosphere.Glare = 0.25
	atmosphere.Haze = 0.8
	tag(atmosphere)

	-- Clear physical sky dome with crisp celestial bodies.
	local sky = Instance.new("Sky")
	sky.CelestialBodiesShown = true
	sky.SunAngularSize = 14
	sky.MoonAngularSize = 9
	sky.StarCount = 3000
	tag(sky)

	-- Volumetric overhead clouds break up the skyline and cast subtle sky variation.
	local terrain = workspace.Terrain
	if terrain then
		local clouds = Instance.new("Clouds")
		clouds.Cover = 0.56
		clouds.Density = 0.68
		clouds.Color = Color3.fromRGB(236, 230, 220)
		tag(clouds, terrain)

		-- Realistic water appearance for Terrain water.
		terrain.WaterWaveSize = 0.18
		terrain.WaterWaveSpeed = 12
		terrain.WaterReflectance = 0.85
		terrain.WaterTransparency = 0.32
		terrain.WaterColor = Color3.fromRGB(36, 108, 128)
	end

	-- Selective bloom: high threshold prevents sunlit concrete from clipping to
	-- flat white while Neon tracers, headlights, and explosions glow vividly.
	-- Tight bloom. A large radius is what makes a bright scene look like it
	-- is behind greased glass; 16 keeps the glow on the thing that is
	-- glowing -- neon scopes, muzzle flashes, headlights, goal lamps.
	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = 0.35
	bloom.Size = 16
	bloom.Threshold = 1.25
	tag(bloom)

	local sunRays = Instance.new("SunRaysEffect")
	sunRays.Intensity = 0.12
	sunRays.Spread = 0.55
	tag(sunRays)

	-- The punch lives here rather than in the sun, so colours pop without
	-- blowing out lit concrete or tinting everything one shade.
	local grade = Instance.new("ColorCorrectionEffect")
	grade.Brightness = 0.03
	grade.Contrast = 0.18
	grade.Saturation = 0.22
	grade.TintColor = Color3.fromRGB(250, 252, 255)
	tag(grade)

	-- Kept disabled by default to avoid wasting a full-screen GPU pass during
	-- hipfire; can be toggled dynamically if a zoomed scope wants shallow DoF.
	local depth = Instance.new("DepthOfFieldEffect")
	depth.Enabled = false
	depth.FarIntensity = 0.14
	depth.NearIntensity = 0
	depth.FocusDistance = 120
	depth.InFocusRadius = 600
	tag(depth)
end

return GraphicsService
