--!strict
local CoreUtil = {}

-- Child modules, required explicitly --
CoreUtil.Signal = require("@self/Signal")
--

-- Roblox instance manipulation --
CoreUtil.Inst = {}
function CoreUtil.Inst.destroyArray(array: {Instance})
	for i = 1, #array do
		local instance = array[i]
		if instance.Parent ~= nil then
			instance:Destroy()
		end
	end
end
--

-- Roblox part manipulation --
CoreUtil.Parts = {}

function CoreUtil.Parts.weldPartsSimple(parts: {Instance}, to: BasePart)
	for _, part in parts do
		if part:IsA("BasePart") and part ~= to then
			local w = Instance.new("Weld")
			w.Part0 = to
			w.Part1 = part
			w.C0 = to.CFrame:ToObjectSpace(part.CFrame)
			w.Parent = part
		end
	end
end

function CoreUtil.Parts.weldModelSimple(model: Model, to: BasePart)
	CoreUtil.Parts.weldPartsSimple(model:GetChildren(), to)
end

function CoreUtil.Parts.makePartsEffectOnly(parts: {Instance} | Model)
	local list: {Instance} = if typeof(parts) == "Instance" then parts:GetDescendants() else parts

	for _, part in list do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.Massless = true
			-- handle can query, can touch seperately?
		end
	end
end
--

-- Sounds --
CoreUtil.Sound = {}

function CoreUtil.Sound.playEffectSoundPositional(sound: Sound, at: Vector3)
	local clone = sound:Clone()
	local part = Instance.new("Part")
	part.Name = "EffectSoundPart"
	part.CFrame = CFrame.new(at)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.AudioCanCollide = false
	part.Transparency = 1
	part.Parent = workspace
	clone.Parent = part

	clone.PlayOnRemove = true
	part:Destroy()
end

--

-- Argument validation, for remote handlers and anywhere else the input is untrusted --
CoreUtil.Validate = {}

--[[
	True only for a real, finite number. Rejects the wrong type, NaN (which fails x == x) and
	both infinities, so a caller can use the value in arithmetic without checking it again.
]]
function CoreUtil.Validate.isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
--

-- Math --
CoreUtil.Math = {}

--[[
	One pole of exponential decay over dt seconds, with a time constant of tau. Framerate
	independent, unlike multiplying by a fixed per-frame factor: the same wall-clock interval
	decays by the same amount whether it arrived as one long frame or ten short ones.
]]
function CoreUtil.Math.lowPassDecay(value: number, dt: number, tau: number): number
	return value * math.exp(-dt / tau)
end
--

-- Compact integer <-> string encoding --
CoreUtil.Encode = {}

local BASE94_FIRST = 33		-- '!', the first printable non-space ASCII character
local BASE94_DIGITS = 94	-- through '~' at 126, so every digit survives a log line intact

--[[
	Write a non-negative integer in base 94 over printable ASCII, most significant digit first.
	Base 94 is the widest alphabet that stays printable, which keeps an encoded value a quarter
	the length of its decimal form without making it unreadable in output: one character below 94,
	two below 8836, three below 830,584.

	Exact up to 2^53, the point where a Luau number stops representing every integer.
]]
function CoreUtil.Encode.toBase94(value: number): string
	if value < 0 or value ~= math.floor(value) then
		error(`base 94 encoding needs a non-negative integer, got {value}`)
	end

	local digits: {string} = {}
	repeat
		-- built least significant first, so the loop below reverses it
		table.insert(digits, string.char(BASE94_FIRST + value % BASE94_DIGITS))
		value = math.floor(value / BASE94_DIGITS)
	until value == 0

	local reversed: {string} = table.create(#digits)
	for i = #digits, 1, -1 do
		table.insert(reversed, digits[i])
	end
	return table.concat(reversed)
end

-- Reverses toBase94. Errors on anything that is not a run of base 94 digits.
function CoreUtil.Encode.fromBase94(encoded: string): number
	if #encoded == 0 then
		error("base 94 decoding needs at least one digit.")
	end

	local value = 0
	for i = 1, #encoded do
		local digit = string.byte(encoded, i) - BASE94_FIRST
		if digit < 0 or digit >= BASE94_DIGITS then
			error(`{string.sub(encoded, i, i)} is not a base 94 digit.`)
		end
		value = value * BASE94_DIGITS + digit
	end
	return value
end
--

-- Collections --
function CoreUtil.mergeArray(into, from)
	for i = 1, #from do
		table.insert(into, from[i])
	end
end
--

return CoreUtil
