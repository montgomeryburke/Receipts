--!strict
--[[
	Signal — a tiny "tell me when this happens" helper.

	Roblox has BindableEvents for this, but they copy every argument they pass
	and lose the difference between nil and nothing. Inside one script that is
	pure downside, so server code uses this instead.
]]

export type Callback = (...any) -> ()

export type Signal = {
	--[[ Listen. Returns a function you call to stop listening. ]]
	Connect: (callback: Callback) -> () -> (),
	--[[ Announce, telling every listener in its own thread. ]]
	Fire: (...any) -> (),
	DisconnectAll: () -> (),
}

local Signal = {}

function Signal.new(): Signal
	local callbacks: { Callback } = {}

	local function Connect(callback: Callback): () -> ()
		table.insert(callbacks, callback)
		return function()
			local index = table.find(callbacks, callback)
			if index then
				table.remove(callbacks, index)
			end
		end
	end

	-- Cloned before iterating so a listener that disconnects itself mid-fire
	-- cannot shuffle the list out from under us. Each listener gets its own
	-- thread, so one erroring listener does not stop the rest being told.
	local function Fire(...: any)
		for _, callback in table.clone(callbacks) do
			task.spawn(callback, ...)
		end
	end

	local function DisconnectAll()
		table.clear(callbacks)
	end

	return {
		Connect = Connect,
		Fire = Fire,
		DisconnectAll = DisconnectAll,
	}
end

return Signal
