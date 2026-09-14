local Gui = {}

local Fusion = require("@game/ReplicatedStorage/Core/Fusion")

export type Scope = Fusion.Scope<typeof(Fusion)>

--[[
	Context handed to each GUI module's build(). scope is the shared, session-lifetime
	Fusion scope; player is the local player.
]]
export type ScreenContext = {
	scope: Scope,
	player: Player,
}

--[[
	A top-level GUI module. build() returns a GuiObject that the manager parents into
	either the primary ScreenGui (layer == nil) or a dedicated ScreenGui named `layer`.
	Modules are brought in by explicit require + Gui.register, never by folder scanning.
]]
export type Screen = {
	name: string,
	order: number?,
	layer: string?,
	build: (scope: Scope, ctx: ScreenContext) -> Instance,
}

-- CONFIG --
-- Default sort key for screens that don't declare `order`.
local DEFAULT_ORDER = 1000
--

local registry: {Screen} = {}
local started = false

-- populated in Gui.start()
local scope: Scope
local playerGui: PlayerGui
local primaryGui: ScreenGui
local layers: {[string]: ScreenGui} = {}

--[[
	Register a top-level GUI module. Must be called before start(). Mirrors the
	Replicator.subscribeToTag(...) -> start() idiom used elsewhere in the codebase.
]]
function Gui.register(screen: Screen)
	assert(not started, `Cannot register GUI module {screen.name} after Gui has started.`)
	table.insert(registry, screen)
end

--[[
	The explicit manifest of top-level GUI modules. Add a line here to load a new
	interface -- there is no location-based / folder-scanning loader by design.
]]
local function registerModules()
	Gui.register(require("@game/ReplicatedStorage/Client/Gui/PilotHud"))
	-- Gui.register(require("@game/ReplicatedStorage/Client/Gui/SomeNextGui"))
end

local function makeScreenGui(name: string): ScreenGui
	return scope:New "ScreenGui" {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	}
end

--[[
	Get-or-create a dedicated ScreenGui layer for screens that opt out of the primary GUI.
]]
local function getLayer(name: string): ScreenGui
	local existing = layers[name]
	if existing then
		return existing
	end
	local created = makeScreenGui(name)
	layers[name] = created
	return created
end

--[[
	Build every registered GUI module exactly once and parent it under PlayerGui.
]]
function Gui.start(player: Player)
	assert(not started, "Gui has already started.")

	registerModules()
	started = true

	scope = Fusion.scoped(Fusion)
	playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	primaryGui = makeScreenGui("Main")

	-- deterministic build / z-order
	table.sort(registry, function(a, b)
		return (a.order or DEFAULT_ORDER) < (b.order or DEFAULT_ORDER)
	end)

	local ctx: ScreenContext = {
		scope = scope,
		player = player,
	}

	for _, screen in registry do
		local target = if screen.layer then getLayer(screen.layer) else primaryGui
		local object = screen.build(scope, ctx)
		object.Parent = target
	end
end

return Gui
