--!strict
--[[
	GraphicsService — makes it stop looking like a bin of bricks.

	Configures Future PBR lighting, 2022 surface materials, volumetric clouds,
	realistic river water, atmospheric depth, and balanced filmic post-processing.
	No external asset IDs are used anywhere, so everything works offline or in
	an unpublished Studio place without throwing.
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

	-- Late-afternoon golden hour: lower sun angle casts long architectural
	-- shadows across streets and gives buildings clear lit vs. shaded faces.
	Lighting.Brightness = 2.85
	Lighting.ClockTime = 16.2
	Lighting.GeographicLatitude = 26
	Lighting.ExposureCompensation = 0.0
	Lighting.EnvironmentDiffuseScale = 0.85
	Lighting.EnvironmentSpecularScale = 1.0
	Lighting.GlobalShadows = true
	pcall(function()
		Lighting.ShadowSoftness = 0.22
	end)

	-- Cool shadowed ambient against warm sunlight gives natural sky-fill contrast.
	Lighting.Ambient = Color3.fromRGB(38, 44, 58)
	Lighting.OutdoorAmbient = Color3.fromRGB(76, 86, 108)
	Lighting.ColorShift_Top = Color3.fromRGB(255, 224, 176)
	Lighting.ColorShift_Bottom = Color3.fromRGB(58, 68, 88)

	-- Atmospheric scattering and distance perspective.
	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Density = 0.24
	atmosphere.Offset = 0.2
	atmosphere.Color = Color3.fromRGB(210, 206, 198)
	atmosphere.Decay = Color3.fromRGB(96, 108, 130)
	atmosphere.Glare = 0.34
	atmosphere.Haze = 0.95
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
	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = 0.38
	bloom.Size = 24
	bloom.Threshold = 1.45
	tag(bloom)

	local sunRays = Instance.new("SunRaysEffect")
	sunRays.Intensity = 0.16
	sunRays.Spread = 0.85
	tag(sunRays)

	-- Balanced filmic color grade that keeps material grain and texture detail.
	local grade = Instance.new("ColorCorrectionEffect")
	grade.Brightness = 0.01
	grade.Contrast = 0.12
	grade.Saturation = 0.1
	grade.TintColor = Color3.fromRGB(255, 250, 244)
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
