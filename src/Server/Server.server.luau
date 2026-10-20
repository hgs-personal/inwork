local ServerStorage = game:GetService("ServerStorage")

local NetTable = require("@game/ReplicatedStorage/Core/NetTable")
local PlaneSim = require("@game/ReplicatedStorage/Modules/PlaneSim")
local Plane = require("@game/ServerScriptService/Server/Plane")
local Test = require("@game/ReplicatedStorage/Core/Test")
local ServerTests = require("@game/ServerScriptService/Server/Tests")

-- CONSTANTS --
-- run the server test procedures in Server/Tests once startup finishes
local RUN_TESTS = true
-- how long after a plane is destroyed before another appears. Placeholder, see spawnPlane.
local PLANE_RESPAWN_DELAY = 5
--

NetTable.init()
NetTable.start()

PlaneSim.init()
-- the server batch updates every plane's sim. A client simulates only the one it is flying.
PlaneSim.start(true)

Plane.initNetworking()

local modelZ = workspace:WaitForChild("ModelZ")

--[[
	Placeholder for Server/PlaneSpawner. Planes are destroyed when they crash, and there is
	exactly one authored plane in the place, so without this the first crash ends flying for the
	session. The template is taken before Plane:init welds and unanchors the model, so every
	respawn starts from the authored state.
]]
local planeTemplate = modelZ:Clone()
planeTemplate.Parent = ServerStorage

local function buildPlane(model)
	-- clients give effects to every model with this tag. Can be removed once planes are tagged in Studio.
	model:AddTag("plane")

	local plane = Plane.new(model)
	plane:init()
	plane:writeEngineState("running")

	model.Destroying:Once(function()
		task.delay(PLANE_RESPAWN_DELAY, function()
			local respawned = planeTemplate:Clone()
			respawned.Parent = workspace
			buildPlane(respawned)
		end)
	end)
end

buildPlane(modelZ)

if RUN_TESTS then
	Test.run("Server", ServerTests)
end
