local Camera = {}

local currentCamera = workspace.CurrentCamera

-- utility and instance accessing --

--[[
	Getter for the current camera to handle any edge cases related to the actual camera instance being destroyed and replaced.
]]
function Camera.currentCamera()
	return currentCamera
end
--

function Camera.init()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function() 
		local newCurrentCamera = workspace.CurrentCamera
		if newCurrentCamera then
			currentCamera = newCurrentCamera
		end
	end)
end

return Camera