--!strict
--[[
	Lifetime — the round boundary, for everything that happens later.

	Nearly every system here schedules work for a second or two from now: a
	gas can comes back, a balloon board refills, a bot respawns, a stall
	resets, a mine re-arms, a chain reaction moves to the next can. All of
	it was plain `task.delay`, which has no idea that the arena it belongs
	to might not be there by the time it runs.

	At a round change MatchService tears the whole world down and builds a
	new one, and every callback still pending from the old round then fires
	into it. Some of those are caught by accident: a closure that captured
	its own folder finds the folder destroyed, because Destroy nils Parent
	all the way down, and bails. The dangerous ones are the ones that read
	a MODULE-level handle instead -- FireService's three respawns all check
	`holder`, which by then points at the NEW map's folder and is perfectly
	alive. So a can shot in the last twenty seconds of a round reappeared in
	the next map at the old map's coordinates: floating in the air, buried
	in a building, or standing in the middle of a hockey rink that did not
	exist when it was scheduled. A chain reaction in flight detonated at a
	stale position and hurt whoever was unlucky enough to be standing there.

	None of that is visible at the call site. The call site looks careful --
	it checks a parent -- and the check is simply answering a different
	question from the one that matters.

	A generation number is the whole fix. It costs one integer compare, one
	place moves it on, and anything scheduled through Delay cannot outlive
	its round. The only discipline it asks for is using Delay instead of
	task.delay for work that belongs to the world rather than to a player.

	Player-scoped waits -- a reload finishing, a respawn -- deliberately do
	NOT go through here. A player keeps playing across a round change, so
	their reload should still finish. Those use DelayFor, which checks the
	player is still in the server rather than which round it is.
]]

local Lifetime = {}

local generation = 0

--[[ Which round the world is on. ]]
function Lifetime.Generation(): number
	return generation
end

--[[
	The world is being rebuilt; everything scheduled against the old one is
	now void. Called from exactly one place, which is the point.
]]
function Lifetime.Bump()
	generation += 1
end

--[[ Has the round this token came from been torn down? ]]
function Lifetime.Stale(token: number): boolean
	return token ~= generation
end

--[[
	Run something later, but only if the arena it was scheduled for is still
	standing.

	Returns the generation it was scheduled against, which a caller running
	its own loop can keep and test with Stale.
]]
function Lifetime.Delay(seconds: number, callback: () -> ()): number
	local token = generation
	task.delay(seconds, function()
		if token ~= generation then
			return
		end
		callback()
	end)
	return token
end

--[[
	Run something later for one player, if they are still here.

	Not generation-guarded: a player survives a round change, so work that
	belongs to them should survive it too.
]]
function Lifetime.DelayFor(player: Player, seconds: number, callback: () -> ())
	task.delay(seconds, function()
		if not player.Parent then
			return
		end
		callback()
	end)
end

--[[ For tests. ]]
function Lifetime.ResetForTests()
	generation = 0
end

return Lifetime
