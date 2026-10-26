--[[
	Core / common / utility types for the GUI code
]]
local GuiCore = {}

local Fusion = require("@game/ReplicatedStorage/Vendor/Fusion")

-- re-exports --
GuiCore.Fusion = Fusion
--

-- core and utility types --

export type TopGui = {
	mount: (Fusion.Scope)
}

export type TopGuiModule = {
	new: (Fusion.Scope)
}

--

-- module interface functions --
--[[
	Wrap constructor in singleton getter for widely accessed components that are built in the primary Root path.
]]
function GuiCore.mono(module)
	local returnObject = nil

	return {
		new = function(...)
			if returnObject then
				error("[GuiCore] mono gui object has been constructed already.")
			end
			returnObject = module._new(...)
			return returnObject
		end,
		get = function()
			if not returnObject then
				error("[GuiCore] mono gui object has not been constructed yet.")
			end
			return returnObject
		end
	}
end
--

-- helpers --

GuiCore.UDIM2_FULL = UDim2.new(1, 0, 1, 0)
GuiCore.UDIM2_MID = UDim2.new(0.5, 0, 0.5, 0)

--[[
	Normalize UDIM scale values to a single reference size.
	Most appropriate when object uses XX or YY size constraint and for easy data entry from SVG data.
]]
function GuiCore.rescaleUDim2(input: UDim2, ref: number)
	return UDim2.new(
		input.X.Scale / ref,
		input.X.Offset,
		input.Y.Scale / ref,
		input.Y.Offset
	)
end

--[[
	Normalize and convert V2 to UDim2 by either a 2 axis, or single axis reference scale.
	Single axis maintains proportions if using XX or YY size constraints. Best for top level containers.
	Two axis maintains proportions if parent maintains proportions. Best for children of proportion controlled containers.
]]
function GuiCore.rescaleV2UDim2(input: Vector2, ref: Vector2 | number)
	input /= ref
	return UDim2.fromScale(input.X, input.Y)
end

--[[
	Lerp scalar float. t=0 -> a, t=1-> b
]]
function GuiCore.lerp1(a, b, t)
	return t * (b - a) + a
end
--

return GuiCore