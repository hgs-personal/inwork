--[[
	Client test procedures, run by Client.client.luau after client systems have started.
	Add entries as { name = "...", enabled = true, run = function() ... end }; fail with assert
	or error. Set enabled = false to skip a test.
]]

local Test = require("@game/ReplicatedStorage/Core/Test")
local Signal = require("@game/ReplicatedStorage/Core/Util/Signal")

local tests: { Test.TestCase } = {
	{
		name = "runner sanity",
		enabled = true,
		run = function()
			assert(1 + 1 == 2, "arithmetic is broken")
		end,
	},
	{
		name = "signal delivers fire arguments",
		enabled = true,
		run = function()
			local signal = Signal.new()
			local gotA, gotB
			signal:connect(function(a, b)
				gotA, gotB = a, b
			end)

			signal:fire("cargo", 3)
			assert(gotA == "cargo" and gotB == 3, `listener got {tostring(gotA)}, {tostring(gotB)}`)
		end,
	},
	{
		name = "signal disconnect stops delivery",
		enabled = true,
		run = function()
			local signal = Signal.new()
			local calls = 0
			local connection = signal:connect(function()
				calls += 1
			end)

			signal:fire()
			connection:disconnect()
			signal:fire()
			assert(calls == 1, `listener ran {calls} times, expected 1`)
			assert(not connection.connected, "connection still reports itself connected")
		end,
	},
	{
		name = "signal listener can disconnect itself mid-dispatch",
		enabled = true,
		run = function()
			local signal = Signal.new()
			local calls = 0
			local connection
			connection = signal:connect(function()
				calls += 1
				connection:disconnect()
			end)

			signal:fire()
			signal:fire()
			assert(calls == 1, `self-disconnecting listener ran {calls} times, expected 1`)
		end,
	},
	{
		name = "signal skips listeners connected during a dispatch",
		enabled = true,
		run = function()
			local signal = Signal.new()
			local lateCalls = 0
			local connection = signal:connect(function()
				signal:connect(function()
					lateCalls += 1
				end)
			end)

			signal:fire()
			connection:disconnect()
			assert(lateCalls == 0, "a listener connected mid-dispatch was called by that dispatch")

			-- but it is a normal listener from the next fire onwards
			signal:fire()
			assert(lateCalls == 1, `late listener ran {lateCalls} times on the next fire, expected 1`)
		end,
	},
	{
		name = "signal once runs exactly one time",
		enabled = true,
		run = function()
			local signal = Signal.new()
			local calls = 0
			signal:once(function()
				calls += 1
			end)

			signal:fire()
			signal:fire()
			assert(calls == 1, `once listener ran {calls} times, expected 1`)
		end,
	},
	{
		name = "signal wait resumes with the fire arguments",
		enabled = true,
		run = function()
			local signal = Signal.new()
			task.defer(function()
				signal:fire("ready", 7)
			end)

			local a, b = signal:wait()
			assert(a == "ready" and b == 7, `wait resumed with {tostring(a)}, {tostring(b)}`)
		end,
	},
}

return tests
