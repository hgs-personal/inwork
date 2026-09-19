--[[
	Pilot Layer: GUI components for pilot gameplay.

	Notes: 
		- top level panels are sized to be pixel perfect at 1080p

	Panel designations:
		- panel01 - bottom center, has most of the indicators
]]
local PilotLayer = {}
PilotLayer.__index = PilotLayer

local UserInputService = game:GetService("UserInputService")

local Fusion = require("@game/ReplicatedStorage/Core/Fusion")
	local CHILDREN = Fusion.Children
	local peek = Fusion.peek
local GuiCore = require("./Core")
	local UDIM2_MID = GuiCore.UDIM2_MID

local V2 = Vector2.new
local V2_MID = V2(0.5, 0.5)

local V3_UP = Vector3.yAxis

-- yoke math constants (ported from the old YokeCursor) --
local OUTPUT_POSITION_MAXIMUM = 0.8 -- scale (between mid point and screen edge)
local OPACITY_MINIMUM = 0.2
local OPACITY_MAXIMUM = 0.8
--

-- STYLE (approximate; tune to taste) --
local STYLE = {
	throttleColor = Color3.fromRGB(80, 220, 120),
	throttleBackColor = Color3.fromRGB(30, 30, 30),
	throttleBackTransparency = 0.4,
	throttleAnchor = V2(0, 0.5),
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

-- --[[
-- 	A crosshair reticle: a center dot plus four ticks. All parts share the transparency
-- 	binding so the whole cursor fades with yoke deflection, matching the old behaviour.
-- ]]
-- local function buildReticle(scope, transparency: Fusion.UsedAs<number>)
-- 	local function tick(anchor: Vector2, position: UDim2, size: UDim2)
-- 		return scope:New "Frame" {
-- 			BorderSizePixel = 0,
-- 			BackgroundColor3 = STYLE.yokeColor,
-- 			BackgroundTransparency = transparency,
-- 			AnchorPoint = anchor,
-- 			Position = position,
-- 			Size = size,
-- 		}
-- 	end

-- 	local tickV = STYLE.reticleTickSize
-- 	local tickH = UDim2.fromOffset(tickV.Y.Offset, tickV.X.Offset)

-- 	return {
-- 		-- center dot
-- 		tick(V2_MID, UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(3, 3)),
-- 		-- top / bottom / left / right ticks
-- 		tick(V2(0.5, 0), UDim2.fromScale(0.5, 0), tickV),
-- 		tick(V2(0.5, 1), UDim2.fromScale(0.5, 1), tickV),
-- 		tick(V2(0, 0.5), UDim2.fromScale(0, 0.5), tickH),
-- 		tick(V2(1, 0.5), UDim2.fromScale(1, 0.5), tickH),
-- 	}
-- end

function PilotLayer._new(scope: Fusion.Scope)
	local self = setmetatable({}, PilotLayer)

	self.mount = PilotLayer.mount

	self.visible = scope:Value(false)
	self.throttle = scope:Value(0)
	self.yoke = scope:Value(Vector2.zero)

	self.speed = scope:Value(0)
	self.altitude = scope:Value(0)
	self.altitudeText6 = scope:Value("000000")

	self.attitude = scope:Value(V2(0, 0))

	return self
end

PilotLayer.mono = GuiCore.mono(PilotLayer)

function PilotLayer.mount(self, scope)
	return scope:New "Frame" {
		Name = "PilotLayer",
		Visible = self.visible,
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		[CHILDREN] = {
			PilotLayer.panel01(self, scope)
		}
	}
end

-- interface to piloting code --
function PilotLayer.heartbeat(self, cf: CFrame, velocity: Vector3)
	local pos = cf.Position
	local speed = velocity.Magnitude
	self.speed:set(speed)
	local alt = pos.Y
	self.altitudeText6:set(string.format("%06d", alt))

	local look = cf.LookVector
	local right = cf.RightVector
	local pitch = math.asin(look.Y)
	print(("pitch: %2.2f"):format(math.deg(pitch)))

	-- use reference up with no roll to get signed roll (TODO: worry about singularities)
	local up0 = look:Cross(V3_UP):Cross(look).Unit
	local roll = math.acos(right:Dot(up0)) - math.pi / 2
	print(("roll : %2.2f"):format(math.deg(roll)))

	self.attitude:set(V2(roll, pitch))
end
--

local NAVBALL_I = "rbxassetid://96341666554381"
local NAVBALL_SIZE = V2(140, 140)

local function navball(scope, props)
	-- note: navball is aligned in Z (pitch), X(roll) order

	local rotation = scope:Computed(function(use, _)
		local roll = use(props.attitude).X
		return math.deg(roll)
	end)

	local posBlack = scope:Computed(function(use, _) 
		local pitch = use(props.attitude).Y
		return UDim2.new(0, 0, pitch / math.pi + 0.5, 0)
	end)

	return scope:New "Frame" {
		Name = "Navball",
		Position = props.Position,
		BackgroundTransparency = 1,
		Size = props.Size,

		[CHILDREN] =	{
			scope:New "ImageLabel" {
				Name = "Overlay",
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 1, 0),
				Image = NAVBALL_I,
				ZIndex = 10,
			},
			scope:New "Frame" {
				Name = "ClippingBox",
				BackgroundTransparency = 1,
				Position = UDim2.new(0.05, 0, 0.05, 0),
				Size = UDim2.new(0.9, 0, 0.9, 0),
				ClipsDescendants = true,
				ZIndex = -10,

				[CHILDREN] = scope:New "Frame" {
					Name = "RotatingBox",
					Size = UDim2.new(1, 0, 1, 0),
					BackgroundTransparency = 1,
					Rotation = rotation,

					[CHILDREN] = {
						scope:New "Frame" {
						Name = "White",
						Size = UDim2.new(1, 0, 2, 0),
						AnchorPoint = V2(0, 1),
						Position = posBlack,
						BackgroundTransparency = 0,
						BackgroundColor3 = Color3.fromRGB(255, 255, 255),
						ZIndex = 0,
						},
						scope:New "Frame" {
							Name = "Black",
							Size = UDim2.new(1, 0, 2, 0),
							Position = posBlack,
							BackgroundTransparency = 0,
							BackgroundColor3 = Color3.fromRGB(0, 0, 0),
							ZIndex = 0,
						}
					}
				}
			}
		}
	}
end

local SPEEDOMETER_I = "rbxassetid://124216866063258"
local SPEEDOMETER_SIZE = V2(140, 140)
local SPEEDARROW_I = "rbxassetid://136676062039570"
local SPEEDARROW_SIZE = V2(10, 60)

local function speedometer(scope, props)
	local rotation = scope:Computed(function(use, scope) 
		local s = use(props.speed)
		local r = (s-150) / 100 * 360 / 4
		return r
	end)

	return scope:New "ImageLabel" {
		Name = "Navball",
		Position = props.Position,
		BackgroundTransparency = 1,
		Size = props.Size,
		Image = SPEEDOMETER_I,
		[CHILDREN] = scope:New "ImageLabel" {
			BackgroundTransparency = 1,
			AnchorPoint = V2_MID,
			Position = UDIM2_MID,
			Size = GuiCore.rescaleV2UDim2(SPEEDARROW_SIZE, SPEEDOMETER_SIZE),
			Image = SPEEDARROW_I,
			Rotation = rotation
		}
	}
end

local ALTIMETER_I = "rbxassetid://121371834208372"
local ALTIMETER_SIZE = V2(290, 50)
local function altimeter(scope, props)
	local digitGridX = 72 / ALTIMETER_SIZE.X
	local digitGridW = 20 / ALTIMETER_SIZE.X
	local digitGridS = 25 / ALTIMETER_SIZE.X
	local text = props.altitudeText6
	local digits = {}
	for i = 1, 6 do
		digits[i] = scope:New "TextLabel" {
			BackgroundTransparency = 1,
			TextScaled = true,
			Size = UDim2.new(digitGridW, 0, 0.8, 0),
			Position = UDim2.new(digitGridX + (i - 1) * digitGridS, 0, 0.1, 0),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
			Text = scope:Computed(function(use, _) 
				return use(text):sub(i-7, i-7)
			end),
			TextColor3 = Color3.fromRGB(255, 255, 255),
		}
	end

	return scope:New "ImageLabel" {
		Name = "Altimeter",
		BackgroundTransparency = 1,
		Position = props.Position,
		Size = props.Size,
		Image = ALTIMETER_I,
		[CHILDREN] = digits,
	}
end

local PANEL_01_I = "rbxassetid://140441070169360"
local PANEL_01_SIZE = V2(590, 231)

function PilotLayer.panel01(self, scope)
	return scope:New "ImageLabel" {
		Name = "PanelBottomCenter",
		AnchorPoint = V2(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 0),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Size = GuiCore.rescaleV2UDim2(PANEL_01_SIZE, 1080),
		BackgroundTransparency = 0.5,
		Image = PANEL_01_I,

		[CHILDREN] = {
			scope:New "UISizeConstraint" {
				MinSize = PANEL_01_SIZE / 2,
			},
			navball(scope, {
				Position = GuiCore.rescaleV2UDim2(V2(20, 20), PANEL_01_SIZE),
				Size = GuiCore.rescaleV2UDim2(NAVBALL_SIZE, PANEL_01_SIZE),
				attitude = self.attitude,
			}),
			speedometer(scope, {
				Position = GuiCore.rescaleV2UDim2(V2(20, 20) + NAVBALL_SIZE * Vector2.new(1, 0) + V2(10, 0), PANEL_01_SIZE),
				Size = GuiCore.rescaleV2UDim2(SPEEDOMETER_SIZE, PANEL_01_SIZE),
				speed = self.speed,
			}),
			altimeter(scope, {
				Position = GuiCore.rescaleV2UDim2(V2(20, 20) + Vector2.new(0, 1) * NAVBALL_SIZE + V2(0, 10), PANEL_01_SIZE),
				Size = GuiCore.rescaleV2UDim2(ALTIMETER_SIZE, PANEL_01_SIZE),
				altitudeText6 = self.altitudeText6,
			})
		}
	}
end



return PilotLayer
