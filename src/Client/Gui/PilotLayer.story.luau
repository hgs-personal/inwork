local Fusion = require("@game/ReplicatedStorage/Core/Fusion")

local PilotLayer = require("./PilotLayer")

return {
	fusion = Fusion,
	story = function(props)
		local scope = props.scope :: Fusion.Scope
		local pilotLayer = PilotLayer.mono.new(scope)
		pilotLayer.visible:set(true)
		scope:Hydrate(props.target)({
			[Fusion.Children] = pilotLayer:mount(scope)
		})
	end,
}