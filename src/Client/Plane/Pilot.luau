local Pilot = {}
Pilot.__index = Pilot

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local PilotLayer = require("@game/ReplicatedStorage/Client/Gui/PilotLayer")
	local pilotLayer
local PlaneReplicator = require("./PlaneReplicator")
local EngineState = require("@game/ReplicatedStorage/Modules/EngineState")

-- CONFIG --
local ARCADE_ROTATION_MODE = true
--

-- CONSTANTS --
local G = workspace.Gravity
local RHO_AIR_NORM = 1
local AOA_MAX_LIFT_W = math.rad(20)
local AOA_OFFS = math.rad(5)

local ARCADE_WINDVANE_K = 4

-- seconds between throttle updates sent to the server while it's changing
local THROTTLE_SEND_INTERVAL = 0.1
--

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local requestEngineRemote = remotes:WaitForChild("RequestEngine")
local setThrottleRemote = remotes:WaitForChild("SetThrottle")


local pilotControlHeartbeat

-- module functions --
function Pilot.init()
	-- get gui objects
	pilotLayer = PilotLayer.mono.get()
end

function Pilot.start()
end
--

function Pilot.newControl(character, humanoid, seat, args)
	local self = setmetatable({}, Pilot)

	-- fetch plane instances
	self.model = seat.Parent
	self.root = assert(self.model.PrimaryPart)
	
	self.onGround = true -- todo: allow this to be set externally
	
	-- configs
	self.coeffWingArea = 0.2
	self.coeffDragZ = 40000 / (150^2)

	-- inputs
	self.throttle = 0
	-- owned by the server, kept in sync from the plane's attribute
	self.engineState = EngineState.OFF :: EngineState.State
	self:loadState()
	self.engineStateConn = self.model:GetAttributeChangedSignal("engineState"):Connect(function()
		local oldState = self.engineState
		self.engineState = self.model:GetAttribute("engineState") or EngineState.OFF
		self:onEngineStateChanged(oldState, self.engineState)
	end)

	-- throttle replication
	self.throttleDirty = false
	self.lastThrottleSend = 0

	local constraintsFolder = self.model:WaitForChild("Constraints")
	self.gearCylinder = constraintsFolder:WaitForChild("GearCylinderRear")
	self.thrustForce = constraintsFolder:WaitForChild("Thrust")
	if ARCADE_ROTATION_MODE then
		self:initRotationArcadeMode(constraintsFolder)
	end
	
	self:initAerodynamics()
	self:initOnGround()
	
	function self:start()
		print("Starting pilot control")
		self.heartbeatConn = RunService.Heartbeat:Connect(function(dt) 
			pilotControlHeartbeat(self, dt)
		end)

		-- PilotHud.show()
	end

	function self:destroy()
		print("Stopping pilot control")
		if self.heartbeatConn then
			self.heartbeatConn:Disconnect()
		end
		self.engineStateConn:Disconnect()

		-- hand effects back to the plane's attributes
		local effects = self:getEffects()
		if effects then
			effects:clearLocalThrottle()
		end

		-- PilotHud.hide()
	end

	return self
end

--[[
	Get the effects object for the plane being piloted, or nil if it hasn't been created yet. Looked up
	each time rather than cached, since the effects object is recreated if the plane streams out and in.
]]
function Pilot:getEffects()
	return PlaneReplicator.get(self.model)
end

--[[
	Load the plane's current engine state and throttle from its attributes, so a pilot picks up where
	the last one left off.
]]
function Pilot:loadState()
	self.engineState = self.model:GetAttribute("engineState") or EngineState.OFF
	self.throttle = self.model:GetAttribute("throttle") or 0
end

--[[
	Ask the server to start or stop the engine. engineState only changes once the server applies it.
]]
function Pilot:requestEngineStart()
	requestEngineRemote:FireServer(self.model, EngineState.REQUEST_START)
end

function Pilot:requestEngineStop()
	requestEngineRemote:FireServer(self.model, EngineState.REQUEST_STOP)
end

function Pilot:toggleEngines()
	if self.engineState == EngineState.STARTING or self.engineState == EngineState.RUNNING then
		self:requestEngineStop()
	else
		self:requestEngineStart()
	end
end

--[[
	Called when the server changes the engine state while piloting.
]]
function Pilot:onEngineStateChanged(oldState: EngineState.State, newState: EngineState.State)
	-- TODO: pilot gui / cockpit feedback
end

function Pilot:setThrottle(throttle)
	throttle = math.clamp(throttle, 0, 1)
	if throttle == self.throttle then
		return
	end
	self.throttle = throttle
	self.throttleDirty = true
end

--[[
	Send the throttle to the server if it changed, at most once per THROTTLE_SEND_INTERVAL.
]]
function Pilot:updateThrottleReplication()
	local now = os.clock()
	if self.throttleDirty and now - self.lastThrottleSend >= THROTTLE_SEND_INTERVAL then
		setThrottleRemote:FireServer(self.model, self.throttle)
		self.throttleDirty = false
		self.lastThrottleSend = now
	end
end

function Pilot:initOnGround(character)
	print("Initiating on ground system")
	self.groundCastParams = RaycastParams.new()
	self.groundCastParams.ExcludeInstances = {character, self.model}
	-- TODO: specifiy collision groups for effects, boxes, etc that should be ignored
	self.wheelPoints = self.model:QueryDescendants("BasePart#WheelPoints")
	print(`wheel points (N={#self.wheelPoints}):`, self.wheelPoints)
end

function Pilot:updateOnGround()
	-- conditions to enter "on ground"
		-- check that lift force is low enough
		-- check ground clearance to any wheel
	-- conditions to exit "on ground
		-- check that lift force is high enough
	
	local mass = self.root.AssemblyMass
	
	-- check wheel clearances
	local pointsOnGround = 0
	for _, wheelPoint in self.wheelPoints do
		local groundRay = workspace:Raycast(wheelPoint.Position, Vector3.new(0, -3, 0), self.groundCastParams)
		if groundRay and groundRay.Instance then
			pointsOnGround += 1
		end
	end
	
	if self.onGround then
		local liftCond = math.abs(self.liftWingNorm) > mass * 0.9
		local vYCond = math.abs(self.v.Y) > 0.1
		self.onGround = not (liftCond and vYCond)
	else
		local liftCond = math.abs(self.liftWingNorm) < mass
		local vYCond = math.abs(self.v.Y) < 0.1
		self.onGround = pointsOnGround > 0 and liftCond and vYCond
	end
	
	--[[
		print("=on ground stat=")
		print(`wheel points on ground: {pointsOnGround}`)
		print(`on ground: {self.onGround}`)
	]]
end

function Pilot:initAerodynamics()
	--self.v = Vector3.zero
	self.cf = self.root.CFrame
	self.liftWingNorm = 0
end

function Pilot:updateAerodynamics(dt)
	self.v = self.root.AssemblyLinearVelocity
	self.cf = self.root.CFrame
	self.v2 = math.abs(self.v:Dot(self.v))
	
	local vLoc = self.cf:VectorToObjectSpace(self.v)
	self.vLoc = vLoc
	
	local aoaWings = math.atan2(-vLoc.Y, -vLoc.Z)
	local liftCoeffWings = math.sin(math.clamp(aoaWings + AOA_OFFS, -1.5*AOA_MAX_LIFT_W, 1.5*AOA_MAX_LIFT_W) * math.pi / 2 / AOA_MAX_LIFT_W)
	local liftWingNorm = liftCoeffWings * 0.5 * self.v2 * RHO_AIR_NORM * self.coeffWingArea
	
	liftWingNorm = math.clamp(liftWingNorm, -1e3, 1e3)
	self.liftWingNorm = liftWingNorm
	
	local dragZ = vLoc.Z^2 * 0.5 * RHO_AIR_NORM * self.coeffDragZ
	
	--print("=aero stat=")
	--print(`aoa w: {math.deg(aoaWings)}`)
	--print(`lift w (Gs): {liftWingNorm}`)
	--print(`v/s {self.v.Y}`)
	
	return Vector3.new(0, liftWingNorm * G, dragZ)
end

function Pilot:initRotationArcadeMode(constraintsFolder)
	self.angularVelocityMover = constraintsFolder:WaitForChild("AngularVelocity")
end

function Pilot:updateRotationArcadeMode(dt)
	local camera = workspace.CurrentCamera
	local viewportSize = camera.ViewportSize
	local mpos = UserInputService:GetMouseLocation()
	local mposFromCenter = (mpos - viewportSize / 2) / viewportSize.Y * 2
	
	-- apply kind of a "deadzone"
	local mag = mposFromCenter.Magnitude
	if 0.1 > mag and mag > 0.0001 then
		mag = (mag / 0.1) ^ 3 * 0.1
		mposFromCenter = mposFromCenter.Unit * mag
	end
	
	-- wind vane
	local windVaneAngle = math.atan2(self.vLoc.X, -self.vLoc.Z)
	local windVaneCoeff = math.clamp(self.v2 / 100, 0, 1)
	
	self.angularVelocityMover.MaxTorque = if self.onGround then 0 else 9999999
	self.angularVelocityMover.AngularVelocity = Vector3.new(-mposFromCenter.Y, -windVaneAngle * windVaneCoeff * ARCADE_WINDVANE_K, -mposFromCenter.X) * math.rad(15)

	-- PilotHud.setYoke(mposFromCenter, viewportSize)
end

function pilotControlHeartbeat(self, dt)
	local linearForce = Vector3.zero
	
	-- calculate ground steer input
	local groundSteer = 0
	groundSteer += UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0
	groundSteer += UserInputService:IsKeyDown(Enum.KeyCode.D) and -1 or 0
	
	local throttleMove = 0
	throttleMove += UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0
	throttleMove += UserInputService:IsKeyDown(Enum.KeyCode.S) and -1 or 0
	
	-- apply throttle
	self:setThrottle(self.throttle + throttleMove * 1 * dt)
	self:updateThrottleReplication()

	-- drive this plane's effects from local throttle, skipping the network delay
	local effects = self:getEffects()
	if effects then
		effects:setLocalThrottle(self.throttle)
	end

	-- update throttle gui
	-- PilotHud.setThrottle(self.throttle)
	
	-- apply ground steer
	self.gearCylinder.TargetAngle = groundSteer * 30
	
	-- apply thrust, only while engines are running
	if self.engineState == EngineState.RUNNING then
		linearForce += Vector3.new(0, 0, -20000 * self.throttle)
	end
	
	local wingForce = self:updateAerodynamics(dt)
	linearForce += wingForce
	
	self:updateOnGround()
	
	-- apply forces
	self.thrustForce.Force = linearForce
	
	-- DEV related
	if ARCADE_ROTATION_MODE then
		self:updateRotationArcadeMode(dt)
	end

	-- game UI
	pilotLayer:heartbeat(self.cf, self.v)
end


--

return Pilot