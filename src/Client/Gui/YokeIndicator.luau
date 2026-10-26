local YokeIndicator = {}
--[[
	Indicate mouse yoke control for PC users. Is not linearly tied to mouse position though.
	TODO: tie visibility of the yoke indicator to a dominant input mode detector (keyboard / gamepad / touch).
]]

local Fusion = require("@game/ReplicatedStorage/Vendor/Fusion")
	local CHILDREN = Fusion.Children

local YOKE_MAX_Y = 0.8 -- range of screen covered by maximum yoke pull

function YokeIndicator.yoke(scope, props)
	local transparency = scope:Computed(function(use) 
		return 1 - use(props.yoke).Magnitude
	end)

	-- note: yoke input is vector 2 normalized to 0-1 on both axes
	local position = scope:Computed(function(use, _)
		local viewport = use(props.viewport)
		local yoke = use(props.yoke)
		local y = (0.5 + yoke.Y / 2 * YOKE_MAX_Y) * viewport.Y 
		local x = 0.5 * viewport.X + (yoke.X / 2 * YOKE_MAX_Y) * viewport.Y
		return UDim2.new(0, x, 0, y)
	end)

	local linePosition = scope:Computed(function(use, _)
		local viewport = use(props.viewport)
		local positionRead = use(position)
		local x = (0.5 * viewport.X + positionRead.X.Offset) / 2
		local y = (0.5 * viewport.Y + positionRead.Y.Offset) / 2
		return UDim2.new(0, x, 0, y)
	end)

	local lineRotation = scope:Computed(function(use, _)
		local viewport = use(props.viewport)
		local positionRead = use(position)
		return math.deg(math.atan2(
			positionRead.Y.Offset - viewport.Y * 0.5,
			positionRead.X.Offset - viewport.X * 0.5
		))
	end)

	local lineSize = scope:Computed(function(use)
		local viewport = use(props.viewport)
		local positionRead = use(position)
		return UDim2.new(0, math.sqrt((positionRead.X.Offset - viewport.X * 0.5)^2 + (positionRead.Y.Offset - viewport.Y * 0.5)^2), 0, 2)
	end)

	return {
		scope:New "Frame" {
			Name = "YokeCross",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = position,
			Size = UDim2.new(0, 32, 0, 32),
			BackgroundTransparency = 1,
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			[CHILDREN] = {
				scope:New "Frame" {
					Name = "HTick",
					Position = UDim2.new(0, 0, 0, 15),
					Size = UDim2.new(1, 0, 0, 2),
					BackgroundTransparency = transparency,
				},
				scope:New "Frame" {
					Name = "VTick",
					Position = UDim2.new(0, 15, 0, 0),
					Size = UDim2.new(0, 2, 1, 0),
					BackgroundTransparency = transparency,
				}
			}
		},

		scope:New "Frame" {
			Name = "YokeLine",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = linePosition,
			Rotation = lineRotation,
			Size = lineSize,
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BackgroundTransparency = transparency,
		}
	}
end

return YokeIndicator