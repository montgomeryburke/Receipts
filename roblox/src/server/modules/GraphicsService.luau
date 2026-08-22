--!strict
--[[
	GraphicsService — makes it stop looking like a bin of bricks.

	Roblox's default lighting is flat, shadowless and grey, which is most of
	why a procedurally built map reads as "some blocks". None of this changes
	a single part: it is all lighting, atmosphere and post-processing, so it
	costs nothing to build and can be tuned without touching the game.

	No asset IDs are used anywhere — a wrong one throws at runtime — so this
	works in a place that has never been published.
]]

local Lighting = game:GetService("Lighting")

local GraphicsService = {}

--[[ Remove anything we added last time, so this can be re-run safely. ]]
local function clearPrevious()
	for _, child in Lighting:GetChildren() do
		if child:GetAttribute("ArenaGraphics") then
			child:Destroy()
		end
	end
end

local function tag(instance: Instance): Instance
	instance:SetAttribute("ArenaGraphics", true)
	instance.Parent = Lighting
	return instance
end

function GraphicsService.Start()
	clearPrevious()

	-- Future lighting gives real shadows and light that bounces off surfaces,
	-- which is the single biggest difference between "blocks" and "a place".
	local ok = pcall(function()
		Lighting.Technology = Enum.Technology.Future
	end)
	if not ok then
		Lighting.Technology = Enum.Technology.ShadowMap
	end

	Lighting.Brightness = 2.6
	Lighting.ClockTime = 15.2
	Lighting.GeographicLatitude = 24
	Lighting.ExposureCompensation = 0.18
	Lighting.EnvironmentDiffuseScale = 0.55
	Lighting.EnvironmentSpecularScale = 0.7
	Lighting.GlobalShadows = true
	Lighting.Ambient = Color3.fromRGB(78, 82, 92)
	Lighting.OutdoorAmbient = Color3.fromRGB(104, 112, 128)
	Lighting.ColorShift_Top = Color3.fromRGB(255, 238, 210)
	Lighting.ColorShift_Bottom = Color3.fromRGB(70, 78, 96)
	Lighting.FogEnd = 2200
	Lighting.FogStart = 400
	Lighting.FogColor = Color3.fromRGB(150, 162, 178)

	-- Haze and depth. Distant buildings fade instead of standing there in
	-- full colour, which is most of what sells a big map as big.
	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Density = 0.36
	atmosphere.Offset = 0.15
	atmosphere.Color = Color3.fromRGB(196, 200, 208)
	atmosphere.Decay = Color3.fromRGB(104, 112, 128)
	atmosphere.Glare = 0.28
	atmosphere.Haze = 1.6
	tag(atmosphere)

	-- A proper sky rather than the flat blue void.
	local sky = Instance.new("Sky")
	sky.CelestialBodiesShown = true
	sky.StarCount = 3000
	tag(sky)

	-- Neon tracers, muzzle flashes and the diamond gun all bloom, which is
	-- what makes them read as light rather than as coloured plastic.
	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = 0.55
	bloom.Size = 26
	bloom.Threshold = 1.1
	tag(bloom)

	local sunRays = Instance.new("SunRaysEffect")
	sunRays.Intensity = 0.14
	sunRays.Spread = 0.9
	tag(sunRays)

	-- A gentle warm grade. Everything default-lit in Roblox looks washed out;
	-- a touch of contrast and saturation does more than any amount of
	-- rebuilding the parts would.
	local grade = Instance.new("ColorCorrectionEffect")
	grade.Brightness = 0.02
	grade.Contrast = 0.16
	grade.Saturation = 0.18
	grade.TintColor = Color3.fromRGB(255, 248, 240)
	tag(grade)

	-- Very slight, only on the far distance, so aiming is unaffected.
	local depth = Instance.new("DepthOfFieldEffect")
	depth.FarIntensity = 0.12
	depth.NearIntensity = 0
	depth.FocusDistance = 90
	depth.InFocusRadius = 900
	tag(depth)
end

return GraphicsService
