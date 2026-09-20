local Pilot = {}
Pilot.__index = Pilot

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local PlaneReplicator = require("./PlaneReplicator")
local EngineState = require("@game/ReplicatedStorage/Modules/EngineState")
local Impact = require("@game/ReplicatedStorage/Modules/Impact")
local PlaneSim = require("@game/ReplicatedStorage/Modules/PlaneSim")
local PilotLayer = require("@game/ReplicatedStorage/Client/Gui/PilotLayer")
	local pilotLayer

-- CONFIG --
local ARCADE_ROTATION_MODE = true
--

-- CONSTANTS --
local G = workspace.Gravity

-- seconds between throttle updates sent to the server while it's changing
local THROTTLE_SEND_INTERVAL = 0.1
--

local remotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Plane")
local requestEngineRemote = remotes:WaitForChild("RequestEngine")
local setThrottleRemote = remotes:WaitForChild("SetThrottle")
local reportImpactRemote = remotes:WaitForChild("ReportImpact")

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
	
	self.sim = PlaneSim.new(self.model, true)
	self.config = self.sim.config

	-- the pilot's own copy of the flight model senses exact physics and gets reliable Touched
	-- events, so it notices an impact well before the server's copy does
	self.impact = Impact.new(self.sim, Impact.CLIENT_OPTIONS)

	-- a flight can end from several directions at once, so teardown has to be idempotent
	self.destroyed = false

	self.onGround = true -- todo: allow this to be set externally
	
	-- configs
	self.coeffWingArea = 0.2
	self.coeffDragZ = 40000 / (150^2)

	-- owned by the server, kept in sync from the plane's attribute
	-- self.engineState = EngineState.OFF :: EngineState.State
	self:loadState()
	self.engineStateConn = self.model:GetAttributeChangedSignal("engineState"):Connect(function()
		local oldState = self.sim.engineState
		local newState = self.model:GetAttribute("engineState") or EngineState.OFF
		PlaneSim.setEngineState(self.sim, newState)
		self:onEngineStateChanged(oldState, self.sim.engineState)
	end)

	-- the server owns the crash. When it says so, this pilot is finished flying, whether or not
	-- the death or the model's destruction has reached this client yet.
	self.crashedConn = self.model:GetAttributeChangedSignal("crashed"):Connect(function()
		if self.model:GetAttribute("crashed") then
			self:destroy()
		end
	end)

	-- throttle replication
	self.throttleDirty = false
	self.lastThrottleSend = 0

	return self
end

function Pilot:activate()
	print("Starting pilot control")
	PlaneSim.activate(self.sim, false)

	-- sitting down does not move the plane, but the sim has not sampled it since it was built
	PlaneSim.resetSensing(self.sim)
	Impact.activate(self.impact)

	self.heartbeatConn = RunService.Heartbeat:Connect(function(dt) 
		self:heartbeatControl(dt)
		PlaneSim.heartbeat(self.sim, dt)
		self:heartbeatCrash(dt)
		-- game UI
		pilotLayer:heartbeat(self.sim.cf, self.sim.v)
	end)

	UserInputService.MouseIconEnabled = false
	pilotLayer.visible:set(true)
end

--[[
	Tell the server where to look. It runs the same detector on its own copy of the plane and
	decides for itself, so nothing is cut here: predicting the crash would mean owning a rollback
	when the server disagrees, and the answer is one ping away.
]]
function Pilot:heartbeatCrash(dt)
	local event = Impact.heartbeat(self.impact, dt)
	if event then
		reportImpactRemote:FireServer(self.model, event.magnitude)
	end
end

--[[
	End this pilot's control of the plane. Reached from getting up, from the plane crashing, and
	from the character dying, in whatever order those arrive, so it has to be safe to call twice.
]]
function Pilot:destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true

	print("Stopping pilot control")
	if self.heartbeatConn then
		self.heartbeatConn:Disconnect()
	end
	self.engineStateConn:Disconnect()
	self.crashedConn:Disconnect()

	-- without this the last frame's thrust and torque stay written on this client forever
	PlaneSim.destroy(self.sim)
	Impact.destroy(self.impact)

	-- hand effects back to the plane's attributes
	local effects = self:getEffects()
	if effects then
		effects:clearLocalThrottle()
	end

	UserInputService.MouseIconEnabled = true
	pilotLayer.visible:set(false)
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
	PlaneSim.setEngineState(self.sim, self.model:GetAttribute("engineState") or EngineState.OFF)
	self.sim.throttle = self.model:GetAttribute("throttle") or 0
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
	if throttle == self.sim.throttle then
		return
	end
	self.sim.throttle = throttle
	pilotLayer.throttle:set(self.sim.throttle)
	self.throttleDirty = true
end

function Pilot:setYoke(yoke: Vector2)
	self.sim.yoke = yoke
	pilotLayer.yoke:set(yoke)
end

--[[
	Send the throttle to the server if it changed, at most once per THROTTLE_SEND_INTERVAL.
]]
function Pilot:updateThrottleReplication()
	local now = os.clock()
	if self.throttleDirty and now - self.lastThrottleSend >= THROTTLE_SEND_INTERVAL then
		setThrottleRemote:FireServer(self.model, self.sim.throttle)
		self.throttleDirty = false
		self.lastThrottleSend = now
	end
end

function Pilot:heartbeatControl(dt)
	-- calculate ground steer input
	local groundSteer = 0
	groundSteer += UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0
	groundSteer += UserInputService:IsKeyDown(Enum.KeyCode.D) and -1 or 0
	self.sim.groundSteer = groundSteer
	
	local throttleMove = 0
	throttleMove += UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0
	throttleMove += UserInputService:IsKeyDown(Enum.KeyCode.S) and -1 or 0
	self:setThrottle(self.sim.throttle + throttleMove * 1 * dt)
	self:updateThrottleReplication()

	local yoke = self:getYokeInput()
	self:setYoke(yoke)

	-- drive this plane's effects from local throttle, skipping the network delay
	local effects = self:getEffects()
	if effects then
		effects:setLocalThrottle(self.sim.throttle)
	end
end

function Pilot:getYokeInput()
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

	return mposFromCenter
end

--

return Pilot