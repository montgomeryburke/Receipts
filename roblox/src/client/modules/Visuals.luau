--!strict
--[[
	Visuals — the two things that decide how readable a fight is.

	Both of these belong on the client because both are about what one pair
	of eyes can see, not about the world:

	1. Field of view. A wider lens means more of the map on screen and a
	   stronger sense of speed, which is most of why modern shooters feel
	   quick. It lives here and in Config rather than being set wherever
	   somebody thought of it, because the scope code tweens BACK to it --
	   two scripts disagreeing about the base FOV shows up as a scope that
	   un-zooms to the wrong place.

	2. Outlines on other players. On a 2000-stud map of mud, concrete and
	   brown terrain, a player standing still against a wall is genuinely
	   hard to see, and losing a fight because you never saw someone is not
	   difficulty, it is noise. An outline fixes that without a wallhack:
	   Occluded depth mode means it only draws when they are already in your
	   line of sight.

	Enemies and team-mates get DIFFERENT colours rather than one outline for
	everyone. Knowing somebody is there is half the information; knowing
	whether to shoot them is the other half, and the motion tracker already
	makes that distinction, so the two readouts agree.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Visuals = {}

local player = Players.LocalPlayer
local OUTLINE_NAME = "ArenaOutline"

local started = false
local nightVision: ColorCorrectionEffect? = nil
local nightVisionOn = false

--[[ Is this player on my side? Teamless players count as enemies. ]]
local function isFriendly(other: Player): boolean
	local mine = player.Team
	return mine ~= nil and other.Team == mine
end

--[[
	Put an outline on somebody else's character.

	Rebuilt rather than recoloured when it already exists, because the one
	case that matters -- somebody switching teams, or you switching teams --
	changes the colour, and a stale red outline on a team-mate is worse than
	no outline at all.
]]
local function markCharacter(other: Player, character: Model)
	if other == player then
		return
	end

	local existing = character:FindFirstChild(OUTLINE_NAME)
	if existing then
		existing:Destroy()
	end

	local friendly = isFriendly(other)

	local highlight = Instance.new("Highlight")
	highlight.Name = OUTLINE_NAME
	-- No fill: a tinted body hides the actual character, including which way
	-- they are facing and what they are holding.
	highlight.FillTransparency = 1
	highlight.OutlineColor = if friendly
		then Config.Visuals.FriendlyOutline
		else Config.Visuals.EnemyOutline
	highlight.OutlineTransparency = Config.Visuals.OutlineTransparency
	-- Only when they are already visible. Anything else is a wallhack.
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = character
end

--[[ Re-colour everyone, for when teams change under us. ]]
function Visuals.Refresh()
	for _, other in Players:GetPlayers() do
		local character = other.Character
		if character then
			markCharacter(other, character)
		end
	end
end

local function follow(other: Player)
	if other.Character then
		markCharacter(other, other.Character)
	end
	other.CharacterAdded:Connect(function(character)
		markCharacter(other, character)
	end)
	-- Somebody switching sides has to change colour, or you spend the round
	-- shooting at the wrong outline.
	other:GetPropertyChangedSignal("Team"):Connect(function()
		local character = other.Character
		if character then
			markCharacter(other, character)
		end
	end)
end

function Visuals.Start()
	if started then
		return
	end
	started = true

	local camera = workspace.CurrentCamera
	if camera then
		camera.FieldOfView = Config.Visuals.BaseFieldOfView
	end

	for _, other in Players:GetPlayers() do
		follow(other)
	end
	Players.PlayerAdded:Connect(follow)

	-- My own team changing flips every outline in the game at once.
	player:GetPropertyChangedSignal("Team"):Connect(Visuals.Refresh)
end

--[[
	Night vision, for down the scope.

	The effect hangs on the CAMERA, not on Lighting. That is not a dodge
	around GraphicsService owning Lighting -- it is where it belongs: a
	camera effect applies to one viewer by construction, so it cannot leak
	onto anybody else's screen and two scripts cannot fight over it. Night
	vision appearing for everyone because one player scoped in would be a
	strange bug to chase.

	Built on first use rather than at start-up, because most players never
	pick up a long scope and an unused effect is still a full-screen pass.
]]
function Visuals.SetNightVision(on: boolean)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	if on and not nightVision then
		local effect = Instance.new("ColorCorrectionEffect")
		effect.Name = "NightVision"
		effect.Brightness = Config.Visuals.NightVisionBrightness
		effect.Contrast = Config.Visuals.NightVisionContrast
		effect.TintColor = Config.Visuals.NightVisionTint
		effect.Parent = camera
		nightVision = effect
	end

	nightVisionOn = on
	if nightVision then
		nightVision.Enabled = on
	end
end

function Visuals.NightVisionOn(): boolean
	return nightVisionOn
end

--[[ For tests. ]]
function Visuals.ResetForTests()
	started = false
	if nightVision then
		nightVision:Destroy()
		nightVision = nil
	end
	nightVisionOn = false
end

function Visuals.OutlineOf(other: Player): Highlight?
	local character = other.Character
	local found = character and character:FindFirstChild(OUTLINE_NAME)
	return if found and found:IsA("Highlight") then found else nil
end

return Visuals
