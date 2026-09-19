local NetTable = require("@game/ReplicatedStorage/Core/NetTable")
local PlaneSim = require("@game/ReplicatedStorage/Modules/PlaneSim")
local Plane = require("@game/ServerScriptService/Server/Plane")

NetTable.init()
NetTable.start()

PlaneSim.init()
-- the server batch updates every plane's sim. A client simulates only the one it is flying.
PlaneSim.start(true)

Plane.initNetworking()

local modelZ = workspace:WaitForChild("ModelZ")
-- clients give effects to every model with this tag. Can be removed once planes are tagged in Studio.
modelZ:AddTag("plane")

local plane = Plane.new(modelZ)
plane:init()
plane:writeEngineState("running")
