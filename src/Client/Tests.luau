--[[
	Client test procedures, run by Client.client.luau after client systems have started.
	Add entries as { name = "...", enabled = true, run = function() ... end }; fail with assert
	or error. Set enabled = false to skip a test.
]]

local Test = require("@game/ReplicatedStorage/Core/Test")

local tests: { Test.TestCase } = {
	{
		name = "runner sanity",
		enabled = true,
		run = function()
			assert(1 + 1 == 2, "arithmetic is broken")
		end,
	},
}

return tests
