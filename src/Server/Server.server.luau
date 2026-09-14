local Plane = require("@game/ServerScriptService/Server/Plane")

Plane.initNetworking()

local modelZ = workspace:WaitForChild("ModelZ")
-- clients give effects to every model with this tag. Can be removed once planes are tagged in Studio.
modelZ:AddTag("plane")

local plane = Plane.new(modelZ)
plane:init()
plane:writeEngineState("running")
