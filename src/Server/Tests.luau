--[[
	Server test procedures, run by Server.server.luau after server systems have started.
	Add entries as { name = "...", enabled = true, run = function() ... end }; fail with assert
	or error. Set enabled = false to skip a test.
]]

local Test = require("@game/ReplicatedStorage/Core/Test")
local CoreUtil = require("@game/ReplicatedStorage/Core/Util")

local tests: { Test.TestCase } = {
	{
		name = "runner sanity",
		enabled = true,
		run = function()
			assert(1 + 1 == 2, "arithmetic is broken")
		end,
	},
	{
		name = "base 64 round trips",
		enabled = true,
		run = function()
			local encode = CoreUtil.Encode.intToB64
			local decode = CoreUtil.Encode.intFromB64

			-- the digit boundaries, either side of each, plus the top of the safe integer range
			local values = {0, 1, 63, 64, 65, 4095, 4096, 4097, 2 ^ 32, 2 ^ 48, 2 ^ 53 - 1, 2 ^ 53}
			for _, value in values do
				local encoded = encode(value)
				assert(decode(encoded) == value, `{value} round tripped to {decode(encoded)} via {encoded}`)
			end
		end,
	},
	{
		name = "base 64 always encodes to 9 characters",
		enabled = true,
		run = function()
			local encode = CoreUtil.Encode.intToB64

			assert(#encode(0) == 9, `zero encoded to {#encode(0)} characters, expected 9`)
			assert(#encode(1) == 9, `one encoded to {#encode(1)} characters, expected 9`)
			assert(#encode(2 ^ 53) == 9, `2^53 encoded to {#encode(2 ^ 53)} characters, expected 9`)
			-- the padding digit is the zero digit, so small values are leading '!'
			assert(encode(0) == string.rep("!", 9), `zero encoded to {encode(0)}`)
			assert(encode(1) == string.rep("!", 8) .. '"', `one encoded to {encode(1)}`)
		end,
	},
	{
		name = "base 64 digits stay printable",
		enabled = true,
		run = function()
			local encoded = CoreUtil.Encode.intToB64(2 ^ 53)
			for i = 1, #encoded do
				local byte = string.byte(encoded, i)
				-- the digits are '!' (33) through '`' (96)
				assert(byte >= 33 and byte <= 96, `digit {i} is byte {byte}, outside the base 64 digit range`)
			end
		end,
	},
	{
		name = "base 64 encoding sorts like the integers",
		enabled = true,
		run = function()
			local encode = CoreUtil.Encode.intToB64

			-- fixed width plus an ordered digit alphabet means string order matches numeric order
			local values = {0, 1, 63, 64, 4096, 2 ^ 32, 2 ^ 48, 2 ^ 53}
			for i = 2, #values do
				local lower, higher = encode(values[i - 1]), encode(values[i])
				assert(lower < higher, `{values[i - 1]} encoded to {lower}, not below {values[i]} as {higher}`)
			end
		end,
	},
	{
		name = "base 64 decodes short strings",
		enabled = true,
		run = function()
			local decode = CoreUtil.Encode.intFromB64

			-- decoding does not require the 9 character padding the encoder emits
			assert(decode("!") == 0, `"!" decoded to {decode("!")}, expected 0`)
			assert(decode('"') == 1, `the second digit decoded to {decode('"')}, expected 1`)
			assert(decode('"!') == 64, `a two digit string decoded to {decode('"!')}, expected 64`)
		end,
	},
	{
		name = "base 64 rejects bad input",
		enabled = true,
		run = function()
			assert(not pcall(CoreUtil.Encode.intToB64, -1), "negative value was encoded")
			assert(not pcall(CoreUtil.Encode.intToB64, 1.5), "fractional value was encoded")
			assert(not pcall(CoreUtil.Encode.intToB64, 2 ^ 53 + 2), "a value past 2^53 was encoded")
			assert(not pcall(CoreUtil.Encode.intFromB64, ""), "empty string was decoded")
			-- space is byte 32, one below the first digit
			assert(not pcall(CoreUtil.Encode.intFromB64, "! !"), "a character below the digit range was decoded")
			-- 'a' is byte 97, one above the last digit
			assert(not pcall(CoreUtil.Encode.intFromB64, "!a!"), "a character above the digit range was decoded")
		end,
	},
}

return tests
