local PlaneReplicator = {}
PlaneReplicator.__index = PlaneReplicator

local RunService = game:GetService("RunService")

local Replicator = require("@game/ReplicatedStorage/Core/Replicator")
local ObjectData = require("@game/ReplicatedStorage/Core/ObjectData")
local Propeller = require("@game/ReplicatedStorage/Modules/Propeller")
local EngineState = require("@game/ReplicatedStorage/Modules/EngineState")
local PlaneData = require("@game/ReplicatedStorage/Modules/PlaneData")
local PlaneCrashEffects = require("@game/ReplicatedStorage/Client/Effects/PlaneCrashEffects")

-- CONSTANTS --
local PLANE_TAG = "plane"
local OBJECT_DATA_KEY = "PlaneReplicator"
--

--[[
	Effects for a single plane model. Runs on every client for every plane, piloted or not.

	State is read from the plane's attributes. Engine state is always the server's. Throttle can be
	overridden by the local pilot with setLocalThrottle(), so the pilot sees effects respond without
	network delay. Effects only read state. They never write to the plane's attributes or to the pilot.
]]
function PlaneReplicator.new(model)
	print("[PlaneReplicator] new for plane:", model:GetFullName())
	local self = setmetatable({}, PlaneReplicator)

	self.model = model
	local planeType = assert(self.model:GetAttribute("planeType"), "could not get planeType from model attributes.")
	local planeTypeData = assert(PlaneData.index[planeType], `unrecognized planeType: {planeType}`)
	self.planeData = planeTypeData

	-- copied in from the local pilot. nil when not locally piloted.
	self.localThrottle = nil
	self.lastEngineState = nil

	-- effect components
	self.propellers = {}

	return self
end

function PlaneReplicator:start()
	-- for now, assume engines are homogenous
	local engineData = self.planeData.engines[1]
	for _, propellerModel in self.model:QueryDescendants("Model#Propeller") do
		table.insert(self.propellers, Propeller.replicator(propellerModel, engineData))
	end
	-- TODO: create other effect instances (sounds, particles, trails)

	self.heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		self:update(dt)
	end)

	self:monitorCrashed()
end

--[[
	Use the local pilot's throttle instead of the plane's attribute.
]]
function PlaneReplicator:setLocalThrottle(throttle: number)
	self.localThrottle = throttle
end

--[[
	Go back to reading throttle from the plane's attribute.
]]
function PlaneReplicator:clearLocalThrottle()
	self.localThrottle = nil
end

function PlaneReplicator:readState()
	local root = self.model.PrimaryPart
	local speed = if root then root.AssemblyLinearVelocity.Magnitude else 0

	local engineState = self.model:GetAttribute("engineState") or EngineState.OFF
	-- server set throttle lags the pilot's own input by ping
	local throttle = self.localThrottle or self.model:GetAttribute("throttle") or 0

	return engineState, throttle, speed
end

function PlaneReplicator:update(dt)
	-- parts may not have streamed in yet
	if not self.model.PrimaryPart then
		return
	end

	local engineState, throttle, speed = self:readState()

	if engineState ~= self.lastEngineState then
		-- how long the plane has already been in this state, for joining a sequence partway through
		local stateTime = self.model:GetAttribute("engineStateTime") or workspace:GetServerTimeNow()
		local elapsed = math.max(workspace:GetServerTimeNow() - stateTime, 0)

		self:onEngineStateChanged(self.lastEngineState, engineState, elapsed)
		self.lastEngineState = engineState
	end

	self:updateEngine(dt, throttle)
	self:updateWind(dt, speed)
end

--[[
	Called once whenever the engine state changes, and on the first update with oldState as nil.
	elapsed is how long the plane has already been in newState.
]]
function PlaneReplicator:onEngineStateChanged(oldState, newState, elapsed)
	print("[PlaneReplicator] handling engine state changed for:", self.model:GetFullName(), "oldState:", oldState, "newState:", newState)
	for _, propeller in self.propellers do
		propeller:setEngineState(oldState, newState, elapsed)
	end
end

function PlaneReplicator:updateEngine(dt, throttle)
	for _, propeller in self.propellers do
		propeller:setThrottle(throttle)
		propeller:update(dt)
	end
	-- TODO: engine sound pitch/volume, exhaust particles
end

function PlaneReplicator:monitorCrashed()
	self.model:GetAttributeChangedSignal("crashed"):Connect(function() 
		-- allow for other attribute changes from the server to be recieved
		local crashed = self.model:GetAttribute("crashed")
		if not crashed then
			return
		end

		self:onCrash()
	end)
end

function PlaneReplicator:onCrash()
	task.defer(function()
		local crashTime = self.model:GetAttribute("crashTime")
		local magnitude = self.model:GetAttribute("crashImpact")
		print("detected plane crash. attribute states: crashTime=", crashTime, "magnitude=", magnitude)

		PlaneCrashEffects.spawn({
			positionAtImpact = self.model.PrimaryPart.CFrame.Position
		})
	end)
end

function PlaneReplicator:updateWind(dt, speed)
	-- TODO: wind sound, wingtip trails
end

function PlaneReplicator:destroy()
	if self.heartbeatConn then
		self.heartbeatConn:Disconnect()
	end

	for _, propeller in self.propellers do
		propeller:destroy()
	end
	table.clear(self.propellers)

	-- TODO: destroy other effect instances created in start()
end

--

function PlaneReplicator.get(model)
	return ObjectData.query(model, OBJECT_DATA_KEY)
end

--[[
	Subscribe so every plane model in the game gets effects. Call before Replicator.start().
]]
function PlaneReplicator.init()
	Replicator.subscribeToTag(PLANE_TAG, {
		added = function(model)
			local effects = PlaneReplicator.new(model)
			effects:start()
			return effects
		end,
		removed = function(model)
			PlaneReplicator.get(model):destroy()
		end,
		objectDataKey = OBJECT_DATA_KEY,
	})
end

return PlaneReplicator
