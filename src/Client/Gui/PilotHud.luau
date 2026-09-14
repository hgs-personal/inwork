--[[
	Pilot HUD: the throttle bar and yoke cursor shown while piloting.

	Built declaratively with Fusion at client init and driven imperatively by Pilot via
	the exported setters. The layout math (throttle bar size, yoke cursor / line transform,
	opacity) is a faithful port of the previous imperative code; the static STYLE constants
	below are approximations of the old Studio-authored "Main" ScreenGui and are meant to be
	tuned.
]]

local UserInputService = game:GetService("UserInputService")

local Fusion = require("@game/ReplicatedStorage/Core/Fusion")
local Gui = require("@game/ReplicatedStorage/Client/Gui")

local Children = Fusion.Children
local peek = Fusion.peek

-- yoke math constants (ported from the old YokeCursor) --
local V2_MID = Vector2.new(0.5, 0.5)
local OUTPUT_POSITION_MAXIMUM = 0.8 -- scale (between mid point and screen edge)
local OPACITY_MINIMUM = 0.2
local OPACITY_MAXIMUM = 0.8
--

-- STYLE (approximate; tune to taste) --
local STYLE = {
	throttleColor = Color3.fromRGB(80, 220, 120),
	throttleBackColor = Color3.fromRGB(30, 30, 30),
	throttleBackTransparency = 0.4,
	throttleAnchor = Vector2.new(0, 0.5),
	throttlePosition = UDim2.new(0.04, 0, 0.5, 0),
	throttleSize = UDim2.fromScale(0.02, 0.4),

	yokeColor = Color3.fromRGB(255, 255, 255),
	reticleSize = UDim2.fromOffset(28, 28),
	reticleTickSize = UDim2.fromOffset(2, 8),
	lineWidthPx = 2,
}
--

export type YokeInput = { output: Vector2, viewport: Vector2 }

-- Module-level Fusion state, created once in build(). Stashed here so Pilot can drive
-- the HUD after client init without a handle to the build scope.
local throttle: Fusion.Value<number>? = nil
local visible: Fusion.Value<boolean>? = nil
local yoke: Fusion.Value<YokeInput>? = nil

--[[
	A crosshair reticle: a center dot plus four ticks. All parts share the transparency
	binding so the whole cursor fades with yoke deflection, matching the old behaviour.
]]
local function buildReticle(scope: Gui.Scope, transparency: Fusion.UsedAs<number>)
	local function tick(anchor: Vector2, position: UDim2, size: UDim2)
		return scope:New "Frame" {
			BorderSizePixel = 0,
			BackgroundColor3 = STYLE.yokeColor,
			BackgroundTransparency = transparency,
			AnchorPoint = anchor,
			Position = position,
			Size = size,
		}
	end

	local tickV = STYLE.reticleTickSize
	local tickH = UDim2.fromOffset(tickV.Y.Offset, tickV.X.Offset)

	return {
		-- center dot
		tick(V2_MID, UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(3, 3)),
		-- top / bottom / left / right ticks
		tick(Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0), tickV),
		tick(Vector2.new(0.5, 1), UDim2.fromScale(0.5, 1), tickV),
		tick(Vector2.new(0, 0.5), UDim2.fromScale(0, 0.5), tickH),
		tick(Vector2.new(1, 0.5), UDim2.fromScale(1, 0.5), tickH),
	}
end

local PilotHud = {
	name = "Pilot",
	order = 100,
	-- layer = nil -> lives in the primary "Main" ScreenGui

	build = function(scope: Gui.Scope, _ctx: Gui.ScreenContext): Instance
		local camera = workspace.CurrentCamera

		throttle = scope:Value(0)
		visible = scope:Value(false)
		yoke = scope:Value({
			output = Vector2.zero,
			viewport = camera and camera.ViewportSize or Vector2.one,
		} :: YokeInput)

		-- derived yoke geometry (ported from YokeCursor:update) --
		local cursorPosition = scope:Computed(function(use)
			local input = use(yoke :: Fusion.Value<YokeInput>)
			local position = input.output / 2 * OUTPUT_POSITION_MAXIMUM + V2_MID
			return UDim2.fromScale(position.X, position.Y)
		end)

		local linePosition = scope:Computed(function(use)
			local input = use(yoke :: Fusion.Value<YokeInput>)
			local position = input.output / 2 * OUTPUT_POSITION_MAXIMUM + V2_MID
			local linePos = (position + V2_MID) / 2
			return UDim2.fromScale(linePos.X, linePos.Y)
		end)

		local lineRotation = scope:Computed(function(use)
			local input = use(yoke :: Fusion.Value<YokeInput>)
			return math.deg(math.atan2(-input.output.X * input.viewport.X, input.output.Y * input.viewport.Y))
		end)

		local lineSize = scope:Computed(function(use)
			local input = use(yoke :: Fusion.Value<YokeInput>)
			local position = input.output / 2 * OUTPUT_POSITION_MAXIMUM + V2_MID
			local length = ((position - V2_MID) * input.viewport).Magnitude
			return UDim2.new(0, STYLE.lineWidthPx, 0, length)
		end)

		local yokeTransparency = scope:Computed(function(use)
			local input = use(yoke :: Fusion.Value<YokeInput>)
			local magnitude = input.output.Magnitude
			local opacity = math.clamp(
				magnitude * (OPACITY_MAXIMUM - OPACITY_MINIMUM) + OPACITY_MINIMUM,
				OPACITY_MINIMUM,
				OPACITY_MAXIMUM
			)
			return 1 - opacity
		end)
		--

		local throttleSize = scope:Computed(function(use)
			return UDim2.new(1, 0, use(throttle :: Fusion.Value<number>), 0)
		end)

		return scope:New "Frame" {
			Name = "Pilot",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Visible = visible,

			[Children] = {
				-- throttle bar (back track + fill that grows upward) --
				scope:New "Frame" {
					Name = "ThrottleBack",
					BorderSizePixel = 0,
					BackgroundColor3 = STYLE.throttleBackColor,
					BackgroundTransparency = STYLE.throttleBackTransparency,
					AnchorPoint = STYLE.throttleAnchor,
					Position = STYLE.throttlePosition,
					Size = STYLE.throttleSize,

					[Children] = {
						scope:New "Frame" {
							Name = "ThrottleTop",
							BorderSizePixel = 0,
							BackgroundColor3 = STYLE.throttleColor,
							AnchorPoint = Vector2.new(0.5, 1),
							Position = UDim2.fromScale(0.5, 1),
							Size = throttleSize,
						},
					},
				},

				-- yoke line: from near-center out toward the cursor --
				scope:New "Frame" {
					Name = "YokeLine",
					BorderSizePixel = 0,
					BackgroundColor3 = STYLE.yokeColor,
					BackgroundTransparency = yokeTransparency,
					AnchorPoint = V2_MID,
					Position = linePosition,
					Rotation = lineRotation,
					Size = lineSize,
				},

				-- yoke cursor reticle --
				scope:New "Frame" {
					Name = "YokeCursor",
					BackgroundTransparency = 1,
					AnchorPoint = V2_MID,
					Position = cursorPosition,
					Size = STYLE.reticleSize,

					[Children] = buildReticle(scope, yokeTransparency),
				},
			},
		}
	end,
}

--[[
	Show the HUD and hide the OS mouse icon (ported from YokeCursor:show).
]]
function PilotHud.show()
	if visible then
		visible:set(true)
	end
	UserInputService.MouseIconEnabled = false
end

--[[
	Hide the HUD and restore the OS mouse icon (ported from YokeCursor:hide/destroy).
]]
function PilotHud.hide()
	if visible then
		visible:set(false)
	end
	UserInputService.MouseIconEnabled = true
end

function PilotHud.setThrottle(value: number)
	if throttle and peek(throttle) ~= value then
		throttle:set(value)
	end
end

--[[
	Update the yoke cursor from the pilot's per-frame yoke output and the current viewport.
]]
function PilotHud.setYoke(output: Vector2, viewport: Vector2)
	if yoke then
		yoke:set({ output = output, viewport = viewport })
	end
end

return PilotHud
