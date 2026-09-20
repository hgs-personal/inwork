--[[
	Plane — the server's authority over one plane model.

	Remotes (declared in default.project.json under Remotes/Plane, connected in initNetworking):

		RequestEngine  client -> server  (model: Instance, request: EngineState.Request)
		SetThrottle    client -> server  (model: Instance, throttle: number)
		ReportImpact   client -> server  (model: Instance, magnitude: number)

	Every handler validates its arguments, resolves the plane through ObjectData, authorizes the
	player against it, and only then acts, returning quietly at the first step that fails.

	State reaches clients on the model's attributes: engineState, engineStateTime, throttle, and
	crashed, crashTime, crashImpact.

	Crashing
	--------
	A crash is detected by Modules/Impact, on the server's own sim, whether or not a client
	reported one. The plane then falls dead-stick for a moment and is destroyed, taking the pilot
	with it. There is no wreck and no recovery.
]]
local Plane = {}
Plane.__index = Plane

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CoreUtil = require("@game/ReplicatedStorage/Core/Util")
local ObjectData = require("@game/ReplicatedStorage/Core/ObjectData")
local Impact = require("@game/ReplicatedStorage/Modules/Impact")
local PlaneSim = require("@game/ReplicatedStorage/Modules/PlaneSim")
local EngineState = require("@game/ReplicatedStorage/Modules/EngineState")
local Propeller = require("@game/ReplicatedStorage/Modules/Propeller")

-- CONSTANTS --
local OBJECT_DATA_KEY = "plane"

-- how long the plane falls dead-stick between the impact and being removed. Long enough to read
-- as a crash, short enough that nobody is waiting on it.
local CRASH_SEQUENCE_DURATION = 2

-- how long a client's impact report stays fresh enough to lower the server's own threshold
local REPORT_CORROBORATE_WINDOW = 1.5
--

function Plane.new(model)
	local self = setmetatable({}, Plane)

	self.model = model
	self.root = assert(model.PrimaryPart)
	self.pilot = nil
	self.sim = nil
	self.impact = nil

	self.crashed = false
	self.destroyed = false
	-- who was flying when it hit. Held separately from pilot, which the seat clears on its own.
	self.crashPlayer = nil

	-- the last unconfirmed client impact report, kept only so an expired one can be logged
	self.reportPlayer = nil
	self.reportExpiresAt = 0

	-- incremented on every engine transition, so a pending delayed transition can tell it was superseded
	self.engineSequenceId = 0

	return self
end

function Plane:init()
	-- init replication state
	self:writeEngineState(EngineState.OFF)
	self.model:SetAttribute("throttle", 0)
	self.model:SetAttribute("crashed", false)
	self.model:SetAttribute("crashTime", 0)
	self.model:SetAttribute("crashImpact", 0)
	--

	-- register so network requests can be routed to this plane by its model
	ObjectData.add(self.model)
	ObjectData.relate(self.model, OBJECT_DATA_KEY, self)

	self:initPiloting()

	-- anything can destroy the model out from under us, and FallenPartsDestroyHeight will if the
	-- plane leaves the world. Route that through the same teardown as a crash.
	self.destroyingConn = self.model.Destroying:Connect(function()
		self:destroy()
	end)

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

	self.impact = Impact.new(self.sim, Impact.SERVER_OPTIONS)
	Impact.activate(self.impact)

	-- the sim batch is connected by PlaneSim.start before any plane is built, so by the time
	-- this runs the sim's sensing is already this frame's
	self.heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		self:heartbeatCrash(dt)
	end)
end

function Plane:initPiloting()
	local pilotSeat = self.model:FindFirstChild("PilotSeat")
	self.occupantConn = pilotSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
		if pilotSeat.Occupant then
			-- setup pilot
			local character = pilotSeat.Occupant.Parent
			local player = game.Players:GetPlayerFromCharacter(character)
			self.pilot = player

			print(`Pilot {player.Name} seated. Granted network ownership.`)
		else
			-- remove pilot
			self.pilot = nil

			print("Pilot left. Released network ownership.")
		end

		self:updateNetworkOwner()
		self:updateSimControl()
	end)
end

--[[
	Who simulates the plane, computed from state rather than set by whoever changed that state.
	Roblox signals are deferred, so the seat's Occupant handler runs after the code that unseated
	the player has already returned. Deriving both of these from pilot and crashed is what stops
	a crashing plane being handed back to the server's flight model on its way out.
]]
function Plane:updateSimControl()
	if self.sim then
		-- flight is client-authoritative, so the server only writes forces when nobody is
		-- flying, and never once the plane is crashed
		self.sim.controlling = (self.pilot == nil) and not self.crashed
	end
end

function Plane:updateNetworkOwner()
	if self.destroyed then
		return
	end
	-- nil means automatic, which is what a plane with no pilot wants
	self.root:SetNetworkOwner(if self.crashed then nil else self.pilot)
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
		if self.engineSequenceId == sequenceId and not self.destroyed then
			self:writeEngineState(nextState)
		end
	end)
end

--[[
	Handle a pilot's start or stop request. Starting can interrupt a spin down, and stopping can
	interrupt a startup.
]]
function Plane:requestEngine(player, request)
	if player ~= self.pilot or self.crashed then
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
	if self.sim then
		self.sim.throttle = throttle
	end
end

function Plane:pilotSetThrottle(player, throttle)
	if player ~= self.pilot or self.crashed or not CoreUtil.Validate.isFiniteNumber(throttle) then
		return
	end
	self:setThrottle(throttle)
end

--[[
	A pilot's client detected an impact on its own copy of the flight model. The client senses
	exact physics and reliable contact, so it gets there first; the server sees the same hit late
	and smoothed by replication, and can read it as smaller than it was.

	So the report is a hint about timing, never evidence of damage. All it does is lower the bar
	the server's own measurement has to clear, for as long as it stays fresh. The magnitude that
	ends up on the model is always the one the server measured.
]]
function Plane:reportImpact(player, magnitude)
	if player ~= self.pilot or self.crashed or not self.impact then
		return
	end
	if not CoreUtil.Validate.isFiniteNumber(magnitude) then
		return
	end

	Impact.setCorroborated(self.impact, REPORT_CORROBORATE_WINDOW)
	self.reportPlayer = player
	self.reportExpiresAt = os.clock() + REPORT_CORROBORATE_WINDOW
end

function Plane:heartbeatCrash(dt)
	if self.destroyed or self.crashed or not self.impact then
		return
	end

	local event = Impact.heartbeat(self.impact, dt)
	if event then
		self:crash(event.magnitude)
		return
	end

	-- a report the server never agreed with is the interesting case: either the thresholds are
	-- wrong for replicated physics, or a client is claiming crashes that did not happen
	if self.reportPlayer and os.clock() > self.reportExpiresAt then
		warn(`[Plane] unconfirmed impact report from {self.reportPlayer.Name} on {self.model:GetFullName()}`)
		self.reportPlayer = nil
	end
end

--[[
	The plane has hit something hard enough to be finished. Cut the engine, take physics back from
	the pilot's client, and let it fall for CRASH_SEQUENCE_DURATION before it is removed. Nothing
	writes forces during the sequence, so the plane arrives wherever its momentum takes it.
]]
function Plane:crash(magnitude)
	if self.crashed or self.destroyed then
		return
	end
	self.crashed = true
	-- captured now, because the seat clears self.pilot the moment anything disturbs it
	self.crashPlayer = self.pilot

	print(`[Plane] crashed {self.model:GetFullName()} impact {math.round(magnitude)}`)

	-- state first, so clients can start the sequence as early as possible
	self.model:SetAttribute("crashImpact", magnitude)
	self.model:SetAttribute("crashTime", workspace:GetServerTimeNow())
	self.model:SetAttribute("crashed", true)

	-- bump the sequence id so a start or stop already in flight cannot bring the engine back
	self.engineSequenceId += 1
	self:writeEngineState(EngineState.OFF)
	self:setThrottle(0)

	self:updateNetworkOwner()
	self:updateSimControl()
	-- a client's constraint writes never replicate, so only the server writing zeros makes the
	-- pilot's last frame of thrust and torque go away for everyone else
	PlaneSim.zeroForces(self.sim)

	-- one arrival that bounces or cartwheels is one crash
	Impact.destroy(self.impact)
	self.impact = nil

	task.delay(CRASH_SEQUENCE_DURATION, function()
		self:destroy()
	end)
end

--[[
	Remove the plane from the game, and the pilot with it. Safe to call twice, and safe to call
	from the model's own Destroying signal, which is how a plane destroyed by anything other than
	a crash gets cleaned up.
]]
function Plane:destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true

	-- kill the pilot before the model goes, so the death is not racing a destroyed seat weld
	local player = self.crashPlayer or self.pilot
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid.Health = 0
	end
	self.pilot = nil
	self.crashPlayer = nil

	if self.sim then
		PlaneSim.destroy(self.sim)
		self.sim = nil
	end
	if self.impact then
		Impact.destroy(self.impact)
		self.impact = nil
	end

	self.heartbeatConn:Disconnect()
	self.occupantConn:Disconnect()
	self.destroyingConn:Disconnect()

	ObjectData.unrelate(self.model, OBJECT_DATA_KEY)
	-- drop the object entirely once nothing else is related to it
	if next(ObjectData.get(self.model)) == nil then
		ObjectData.clear(self.model)
	end

	-- untagging it is what tears the plane down on every client, through Core/Replicator
	if self.model.Parent then
		self.model:Destroy()
	end
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
	local remotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Plane")

	--[[
		Validate the model, resolve the plane, then hand off. Authorization is the method's own
		job, since only the plane knows who is flying it.
	]]
	local function route(methodName: string)
		return function(player, model, argument)
			if typeof(model) ~= "Instance" then
				return
			end
			local plane = Plane.get(model)
			if not plane then
				return
			end
			plane[methodName](plane, player, argument)
		end
	end

	remotes:WaitForChild("RequestEngine").OnServerEvent:Connect(route("requestEngine"))
	remotes:WaitForChild("SetThrottle").OnServerEvent:Connect(route("pilotSetThrottle"))
	remotes:WaitForChild("ReportImpact").OnServerEvent:Connect(route("reportImpact"))
end

return Plane
