local Root = {}

local Fusion = require("@game/ReplicatedStorage/Core/Fusion")
-- top gui modules
local PilotLayer = require("./PilotLayer")

local started = false
local playerGui: PlayerGui

local state

local function mountScreenGui(name: string, scope: Fusion.Scope, props, topGuis)
	-- default to ignore inset if nil
	if props.ignoreInset ~= false then
		props.ignoreInset = true
	end

	-- note: TopGui instances should name themselves. Fusion's dictionary -> instance naming seems unreliable sometimes.1
	local children = {}
	for _, topGui in topGuis do
		table.insert(children, topGui:mount(scope))
	end

	return scope:New "ScreenGui" {
		Parent = playerGui,
		Name = name,
		DisplayOrder = props.Order or 0,
		Enabled = true,
		IgnoreGuiInset = false,
		[Fusion.Children] = children,
	}
end

function Root.init()
	state = {}
	state.scope = Fusion.scoped(Fusion)
	state.pilotLayer = PilotLayer.mono.new(state.scope)
end

--[[
	Build every registered GUI module exactly once and parent it under PlayerGui.
]]
function Root.start()
	assert(not started, "Gui has already started.")
	started = true

	local player = game:GetService("Players").LocalPlayer
	playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	local scope = state.scope

	-- mounting
	mountScreenGui("Primary", scope, 
	{
		displayOrder = 100,
	}, 
	{
		state.pilotLayer
	})
end

return Root
