local Propeller = {}
Propeller.__index = Propeller

local UtilParts = require("@game/ReplicatedStorage/Core/Util").Parts
local EngineState = require("./EngineState")

local CONFIG_RPM_MAX_THROTTLE = 3000
local CONFIG_RPM_IDLE = 120

local RPM_TO_RADPS = 2 * math.pi / 60

local PROP_JOINT_NAME = "PropMotor6D"

local function setupEngineSound(templ: Sound, propellerModel: Model)
    local sound = templ:Clone()
    sound.Playing = false
    sound.Parent = propellerModel.PrimaryPart
    return sound
end

--[[
    Create required welds and rotating Motor6D based on alignment of reference plane root.
]]
function Propeller.modelBuildUp(propellerModel: Model, planeRoot: BasePart, breakableConstraints)
    local propRoot = assert(propellerModel.PrimaryPart, "propeller model has no primary part.")
    local parts = propellerModel:GetChildren()
    UtilParts.makePartsEffectOnly(parts)
    UtilParts.weldPartsSimple(parts, propRoot)
    
    local joint = Instance.new("Motor6D")
    joint.Name = PROP_JOINT_NAME
    joint.Part0 = planeRoot
    joint.C0 = CFrame.new(planeRoot.CFrame:PointToObjectSpace(propRoot.CFrame.Position))
    joint.C1 = propRoot.CFrame:Inverse() * planeRoot.CFrame * joint.C0
    joint.Part1 = propRoot
    joint.Parent = propellerModel
    table.insert(breakableConstraints, joint)
end

--[[
    Client side rotation and noise for a propeller that has already been built up with modelBuildUp.
]]
function Propeller.replicator(propellerModel: Model, engineData)
    local self = setmetatable({}, Propeller)

    self.model = propellerModel
    self.engineState = EngineState.OFF :: EngineState.State
    self.throttle = 0
    self.joint = self.model:WaitForChild(PROP_JOINT_NAME)
    self.engineData = engineData

    -- self.soundStart = nil
    self.soundMid = setupEngineSound(engineData.soundMid, propellerModel)
    self.soundHigh = setupEngineSound(engineData.soundHigh, propellerModel)

    return self
end

--[[
    Follow the server's engine state. Called when the state changes, and once when the effect is created.
    elapsed is how long the plane has already been in this state, so a propeller loaded mid-sequence
    (e.g. streamed in during startup) can join partway rather than start from the beginning.

    off: stopped and silent
    starting: startup sequence (cranking, catching, spooling up to idle), lasts EngineState.START_DURATION
    running: spin and noise follow throttle
    stopping: spinning down after the engine is cut, lasts EngineState.STOP_DURATION
]]
function Propeller:setEngineState(oldState: EngineState.State?, newState: EngineState.State, elapsed: number)
    if newState ~= oldState then
        self.soundHigh.Playing = (newState == EngineState.RUNNING)
        self.soundMid.Playing = (newState == EngineState.RUNNING)
        self:update(0)
    end

    self.engineState = newState
end

--[[
    Throttle target (0 - 1). Only affects rotation and noise while "running".
]]
function Propeller:setThrottle(throttle: number)
    self.throttle = throttle
end

--[[
    Advance the current sequence and apply rotation and noise. Called every frame.
]]
function Propeller:update(dt: number)
    local speed = self.model.PrimaryPart.AssemblyLinearVelocity.Magnitude -- TODO: not this

    if self.engineState == EngineState.RUNNING then
        -- update propeller 3D render
        local rps = (self.throttle * (CONFIG_RPM_MAX_THROTTLE - CONFIG_RPM_IDLE) + CONFIG_RPM_IDLE)* RPM_TO_RADPS
        self.joint.C0 = self.joint.C0 * CFrame.Angles(0, 0, rps * dt)

        -- update engine noises
        self.soundMid.PlaybackSpeed = self.throttle * (self.engineData.soundMidRPMFactorHigh - self.engineData.soundMidRPMFactorLow) + self.engineData.soundMidRPMFactorLow

        local x = ((speed - self.engineData.soundHighThresholdSpeed) / self.engineData.soundHighThresholdBand + 1) / 2
        x = math.clamp(x, 0, 1)
        self.soundHigh.Volume = x
        self.soundMid.Volume = 1 - x
    end
end

--[[
    Stop noise and undo anything applied to the model.

    Nothing to do: the Motor6D and the cloned sounds are parented inside the propeller model, so
    they go when it does. This exists for the day an effect is created outside the model.
]]
function Propeller:destroy()
end

return Propeller
