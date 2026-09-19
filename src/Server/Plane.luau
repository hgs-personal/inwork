local Plane = {}
Plane.__index = Plane

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ObjectData = require("@game/ReplicatedStorage/Core/ObjectData")
local PlaneSim = require("@game/ReplicatedStorage/Modules/PlaneSim")
local EngineState = require("@game/ReplicatedStorage/Modules/EngineState")
local Propeller = require("@game/ReplicatedStorage/Modules/Propeller")

-- CONSTANTS --
local OBJECT_DATA_KEY = "plane"
--

function Plane.new(model)
	local self = setmetatable({}, Plane)

	self.model = model
	self.root = assert(model.PrimaryPart)
	self.pilot = nil
	self.sim = nil

	-- incremented on every engine transition, so a pending delayed transition can tell it was superseded
	self.engineSequenceId = 0

	return self
end

function Plane:init()
	-- init replication state
	self:writeEngineState(EngineState.OFF)
	self.model:SetAttribute("throttle", 0)
	--

	-- register so network requests can be routed to this plane by its model
	ObjectData.add(self.model)
	ObjectData.relate(self.model, OBJECT_DATA_KEY, self)

	self:initPiloting()

	-- build static welds
	for _, part in self.model:GetChildren() do
		if part:IsA("BasePart") then
			local weld = Instance.new("Weld")
			weld.Part0 = self.root
			weld.Part1 = part
			weld.C0 = self.root.CFrame:Inverse() * part.CFrame
			weld.Parent = self.root
			part.Anchored = false
		end
	end

	-- build up sub-assemblies
	---- propellers
	local propellerModels = self.model:WaitForChild("Propellers"):GetChildren()
	for _, propellerModel in propellerModels do
		Propeller.modelBuildUp(propellerModel, self.root)
	end
	---
	--

	-- the server flies every plane that has no pilot. A pilot takes control in initPiloting.
	self.sim = PlaneSim.new(self.model, true)
	PlaneSim.setEngineState(self.sim, self:getEngineState())
	PlaneSim.activate(self.sim, true)
end

function Plane:initPiloting()
	local pilotSeat = self.model:FindFirstChild("PilotSeat")
	pilotSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
		if pilotSeat.Occupant then
			-- setup pilot

			local character = pilotSeat.Occupant.Parent
			local humanoid = character.Humanoid
			local player = game.Players:GetPlayerFromCharacter(character)
			self.pilot = player
			self.root:SetNetworkOwner(player)

			-- flight is client-authoritative, so the server stops writing forces and only
			-- senses while this plane is piloted
			self:setSimControlling(false)

			print(`Pilot {player.Name} seated. Granted network ownership.`)
		else
			-- remove pilot
			self.pilot = nil
			self.root:SetNetworkOwner(nil)

			self:setSimControlling(true)

			print("Pilot left. Released network ownership.")
		end
	end)
end

--[[
	Hand the flight model to the pilot's client, or take it back. The server keeps running
	the sim either way; controlling only decides whether it writes forces. Nothing is
	written on the way out, since the server clearing a constraint the pilot is driving
	would replicate over the pilot's own value.
]]
function Plane:setSimControlling(controlling: boolean)
	if self.sim then
		self.sim.controlling = controlling
	end
end

function Plane:getEngineState(): EngineState.State
	return self.model:GetAttribute("engineState")
end

function Plane:writeEngineState(state: EngineState.State)
	self.model:SetAttribute("engineState", state)
	self.model:SetAttribute("engineStateTime", workspace:GetServerTimeNow())

	-- the sim never reads attributes itself, so push the new state into it
	if self.sim then
		PlaneSim.setEngineState(self.sim, state)
	end
end

--[[
	Enter an intermediate state, then move to nextState after duration unless another transition
	happens first.
]]
function Plane:beginEngineTransition(state: EngineState.State, nextState: EngineState.State, duration: number)
	self.engineSequenceId += 1
	local sequenceId = self.engineSequenceId

	self:writeEngineState(state)

	task.delay(duration, function()
		if self.engineSequenceId == sequenceId then
			self:writeEngineState(nextState)
		end
	end)
end

--[[
	Handle a pilot's start or stop request. Starting can interrupt a spin down, and stopping can
	interrupt a startup.
]]
function Plane:requestEngine(player, request)
	if player ~= self.pilot then
		return
	end

	local state = self:getEngineState()
	if request == EngineState.REQUEST_START then
		if state == EngineState.OFF or state == EngineState.STOPPING then
			self:beginEngineTransition(EngineState.STARTING, EngineState.RUNNING, EngineState.START_DURATION)
		end
	elseif request == EngineState.REQUEST_STOP then
		if state == EngineState.STARTING or state == EngineState.RUNNING then
			self:beginEngineTransition(EngineState.STOPPING, EngineState.OFF, EngineState.STOP_DURATION)
		end
	end
end

function Plane:setThrottle(throttle)
	throttle = math.clamp(throttle, 0, 1)
	self.model:SetAttribute("throttle", throttle)

	-- yoke and rudder are zero because nothing on the server steers a plane yet. When an
	-- autopilot or a taxi director exists, it feeds them here.
	PlaneSim.setPrimaryFlightControls(self.sim, throttle, Vector2.zero, 0)
end

function Plane:pilotSetThrottle(player, throttle)
	-- throttle ~= throttle rejects NaN
	if player ~= self.pilot or typeof(throttle) ~= "number" or throttle ~= throttle then
		return
	end
	self:setThrottle(throttle)
end

--

function Plane.get(model)
	return ObjectData.query(model, OBJECT_DATA_KEY)
end

--[[
	Connect plane remotes. Requests name the plane model they're for, and are routed to that plane's
	object through ObjectData. Call once on server startup.
]]
function Plane.initNetworking()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")

	remotes:WaitForChild("RequestEngine").OnServerEvent:Connect(function(player, model, request)
		local plane = Plane.get(model)
		if plane then
			plane:requestEngine(player, request)
		end
	end)

	remotes:WaitForChild("SetThrottle").OnServerEvent:Connect(function(player, model, throttle)
		local plane = Plane.get(model)
		if plane then
			plane:pilotSetThrottle(player, throttle)
		end
	end)
end

return Plane
