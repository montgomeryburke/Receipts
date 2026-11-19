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
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

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
		The grade comes from Config now, not from here.

		Every one of these numbers used to be hardcoded in this module,
		which made it the only one in the game that never read Config -- in
		a project whose premise is that Config is the one file you tune. The
		reasoning behind the default lives with the numbers, in
		Config.Look: mid-afternoon rather than golden hour, because a low
		sun on a map of mud and concrete turns the whole thing into one
		brown mass, and because lifted shadow fill is not a preference when
		pitch-black shade is where players disappear.

		A second preset keeps the golden-hour version, for when the point is
		to look at the game rather than play it.
	]]
	local look = Config.CurrentLook()

	Lighting.Brightness = look.Brightness
	Lighting.ClockTime = look.ClockTime
	Lighting.GeographicLatitude = look.GeographicLatitude
	Lighting.ExposureCompensation = look.ExposureCompensation
	Lighting.EnvironmentDiffuseScale = 0.85
	Lighting.EnvironmentSpecularScale = 1.0
	Lighting.GlobalShadows = true
	pcall(function()
		Lighting.ShadowSoftness = look.ShadowSoftness
	end)

	Lighting.Ambient = look.Ambient
	Lighting.OutdoorAmbient = look.OutdoorAmbient
	Lighting.ColorShift_Top = look.ColorShiftTop
	Lighting.ColorShift_Bottom = look.ColorShiftBottom

	-- Atmospheric scattering and distance perspective.
	local atmosphere = Instance.new("Atmosphere")
	-- Enough haze to give the 2000-stud map depth.
	atmosphere.Density = 0.24
	atmosphere.Offset = look.AtmosphereOffset
	atmosphere.Color = look.AtmosphereColor
	atmosphere.Decay = look.AtmosphereDecay
	atmosphere.Glare = look.AtmosphereGlare
	atmosphere.Haze = look.AtmosphereHaze
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

	-- Selective bloom: a high threshold keeps sunlit concrete from clipping
	-- to flat white while neon, headlights and explosions still glow. The
	-- radius is the part that matters -- a large one is what makes a bright
	-- scene look like it is behind greased glass.
	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = look.BloomIntensity
	bloom.Size = look.BloomSize
	bloom.Threshold = look.BloomThreshold
	tag(bloom)

	local sunRays = Instance.new("SunRaysEffect")
	sunRays.Intensity = look.SunRaysIntensity
	sunRays.Spread = look.SunRaysSpread
	tag(sunRays)

	-- The punch lives here rather than in the sun, so colours pop without
	-- blowing out lit concrete or tinting everything one shade.
	local grade = Instance.new("ColorCorrectionEffect")
	grade.Brightness = look.GradeBrightness
	grade.Contrast = look.GradeContrast
	grade.Saturation = look.GradeSaturation
	grade.TintColor = look.GradeTint
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
