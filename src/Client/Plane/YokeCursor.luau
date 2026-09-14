local YokeCursor = {}
YokeCursor.__index = YokeCursor

local UserInputService = game:GetService("UserInputService")

local gui: {
	pilotFrame: typeof(game.StarterGui.Main.Pilot)
}

local V2_MID = Vector2.new(0.5, 0.5)

local OUTPUT_POSITION_MAXIMUM = 0.8 -- scale (between mid point and screen edge)
local OPACITY_MINIMUM = 0.2
local OPACITY_MAXIMUM = 0.8

function YokeCursor.new()
	local self = setmetatable({}, YokeCursor)
	
	self.camera = workspace.CurrentCamera
	self.yokeLine = gui.pilotFrame:WaitForChild("YokeLine")
	self.yokeCursor = gui.pilotFrame:WaitForChild("YokeCursor")
	self.lines = self.yokeCursor:GetChildren()
	table.insert(self.lines, self.yokeLine)

	return self
end

function YokeCursor:show()
	UserInputService.MouseIconEnabled = false
	self.yokeLine.Visible = true
	self.yokeCursor.Visible = true
end

function YokeCursor:hide()
	UserInputService.MouseIconEnabled = true
	self.yokeLine.Visible = false
	self.yokeCursor.Visible = false
end

function YokeCursor:update(yokeOutput: Vector2, viewportSize)
	local position = yokeOutput / 2 * OUTPUT_POSITION_MAXIMUM + V2_MID
	self.yokeCursor.Position = UDim2.fromScale(position.X, position.Y)

	local linePosition = (position + V2_MID)/2
	local lineAngle = math.deg(math.atan2(-yokeOutput.X * viewportSize.X, yokeOutput.Y * viewportSize.Y))
	self.yokeLine.Position = UDim2.fromScale(linePosition.X, linePosition.Y)
	self.yokeLine.Rotation = lineAngle

	local length = ((position - V2_MID) * viewportSize).Magnitude
	self.yokeLine.Size = UDim2.new(0, 2, 0, length)

	local magnitude = yokeOutput.Magnitude
	local opacity = math.clamp(magnitude * (OPACITY_MAXIMUM - OPACITY_MINIMUM) + OPACITY_MINIMUM, OPACITY_MINIMUM, OPACITY_MAXIMUM)
	local transparency = 1 - opacity
	for i = 1, #self.lines do
		self.lines[i].BackgroundTransparency = transparency
	end
end

function YokeCursor:destroy()
	self:hide()
end

function YokeCursor.guiInit(pilotFrame)
	gui = {
		pilotFrame = pilotFrame
	}

	-- force yoke to be hidden at startup
	YokeCursor.new():destroy()
end

return YokeCursor