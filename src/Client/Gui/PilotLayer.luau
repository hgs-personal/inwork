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
local GuiCore = require("./Core")
	local UDIM2_MID = GuiCore.UDIM2_MID
local Camera = require("@game/ReplicatedStorage/Client/Camera")
local YokeIndicator = require("./YokeIndicator")

local V2 = Vector2.new
local V2_MID = V2(0.5, 0.5)
local V3_UP = Vector3.yAxis


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

	self.viewport = scope:Value(workspace.CurrentCamera.ViewportSize)

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
			PilotLayer.panel01(self, scope),
			PilotLayer.panel10(self, scope),
			YokeIndicator.yoke(scope, { 
				yoke = self.yoke,
				viewport = self.viewport,
			}),
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

	local viewport = Camera.currentCamera().ViewportSize
	self.viewport:set(viewport)
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

local KNOB_I = "rbxassetid://87527774386333"
local KNOB_SIZE = V2(55, 35)
local KNOB_X = 45
local KNOB_Y_MIN = -5
local KNOB_Y_MAX = 175
local function throttleKnob(scope, props)
	local position = scope:Computed(function(use, _)
		local throttle = use(props.throttle)
		local y = GuiCore.lerp1(KNOB_Y_MAX, KNOB_Y_MIN, throttle)
		print("gui throttle update:", y, y/props.panelSize.Y)
		return UDim2.new(KNOB_X / props.panelSize.X, 0, y / props.panelSize.Y, 0)
	end)

	return scope:New "ImageLabel" {
		Name = "ThrottleKnob",
		Position = position,
		Size = GuiCore.rescaleV2UDim2(KNOB_SIZE, props.panelSize),
		BackgroundTransparency = 1,
		Image = KNOB_I,

		[CHILDREN] = {}
	}
end

local PANEL_10_I = "rbxassetid://99985828877512"
local PANEL_10_SIZE = V2(100, 200)

function PilotLayer.panel10(self, scope)
	return scope:New "ImageLabel" {
		Name = "PanelMiddleRight",
		AnchorPoint = V2(0, 0),
		Position = UDim2.new(0, 0, 0.5, 0),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Size = GuiCore.rescaleV2UDim2(PANEL_10_SIZE, 1080),
		BackgroundTransparency = 1,
		Image = PANEL_10_I,

		[CHILDREN] = {
			throttleKnob(scope, {
				panelSize = PANEL_10_SIZE,
				throttle = self.throttle,
			})
		}	
	}
end


return PilotLayer
