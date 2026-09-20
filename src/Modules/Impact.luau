--!strict
--[[
	Impact — deciding when a plane has hit something hard enough to be a crash.

	This is the crash rule, not the flight model. PlaneSim senses the motion (dvNet, aNet);
	Impact decides what counts. It is a struct plus free functions like PlaneSim, but unlike
	PlaneSim it owns Instance connections, so it has to be destroyed.

	The signal
	----------
	An impact resolves in a frame or two, so it shows up as an impulse in the plane's velocity.
	dvFast accumulates PlaneSim's gravity-compensated velocity change through a one-pole decay,
	which makes it insensitive to where a collision lands relative to a heartbeat boundary: a
	speed loss spread over three frames sums into roughly the same peak as one delivered in a
	single frame. That peak is in studs/s, and it is close to the speed the airframe had to
	absorb, which is why it is the number the crash event carries.

	Three gates, not one
	--------------------
	- dvFast over the plane type's crashImpactDv: the energy test.
	- aNet over IMPACT_MIN_ACCEL: the rate test, so a long survivable deceleration cannot creep
	  over the accumulated threshold.
	- airframe contact within CONTACT_WINDOW: the corroboration test, and the only one that
	  reliably tells "the wheels slammed down" apart from "a wing hit a hangar". Contact is never
	  a trigger by itself — a wingtip brushing a fence does nothing.

	Two sides, one rule
	-------------------
	The client runs this on its own sim, where sensing is exact and Touched is reliable, so it
	uses the authored threshold and requires contact. The server runs it on a sim that is
	watching replicated physics at replication rate, with no dependable contact, so it uses
	SERVER_OPTIONS: no contact requirement and a lower threshold, because a smoothed signal
	under-reports. A client's report can lower the server's bar further through setCorroborated,
	but never removes it, so the server always decides for itself.
]]
local Impact = {}

local Players = game:GetService("Players")

local CoreUtil = require("@game/ReplicatedStorage/Core/Util")
local PlaneSim = require("./PlaneSim")

-- CONSTANTS --
local G = workspace.Gravity

-- decay time constant of the impulse filter, in seconds. Around five frames at 60Hz.
local IMPACT_TAU = 0.08

-- a firm gear arrival is on the order of 2g; this sits well clear of it
local IMPACT_MIN_ACCEL = 8 * G

-- how recently the airframe must have touched something for a hit to count as corroborated
local CONTACT_WINDOW = 0.2

-- after a crash, so one arrival that bounces or cartwheels reports once
local CRASH_BLACKOUT = 1
-- after activation or a reset, so the plane settles before anything is measured
local RESET_BLACKOUT = 0.5

-- how far a client's report lowers the server's threshold. Below 1 and above 0: corroboration
-- makes the server readier to agree, it never makes the decision for it.
local CORROBORATED_FACTOR = 0.75

local AIRFRAME_TAG = "airframePart"
--

export type ImpactEvent = {
	magnitude: number,					-- speed the airframe absorbed, studs/s
	dvNetLoc: Vector3,					-- which way the energy arrived, in the plane's own axes
	position: Vector3,
	contact: boolean,					-- whether the airframe was touching something
}

export type Options = {
	requireContact: boolean,
	thresholdScale: number,				-- multiplies the plane type's crashImpactDv
}

export type Impact = {
	sim: PlaneSim.PlaneSim,
	model: Model,

	threshold: number,
	requireContact: boolean,

	dvFast: number,						-- filtered velocity change, studs/s
	lastContactTime: number,
	blockedUntil: number,
	corroborateUntil: number,

	airframeParts: {BasePart},
	connections: {RBXScriptConnection},
}

-- the client senses its own physics exactly and its Touched events are reliable
Impact.CLIENT_OPTIONS = {
	requireContact = true,
	thresholdScale = 1,
} :: Options

-- the server watches replicated, smoothed physics, so the same hit reads smaller there
Impact.SERVER_OPTIONS = {
	requireContact = false,
	thresholdScale = 0.6,
} :: Options

function Impact.new(sim: PlaneSim.PlaneSim, options: Options): Impact
	local self = {}

	self.sim = sim
	self.model = sim.model

	self.threshold = sim.config.crashImpactDv * options.thresholdScale
	self.requireContact = options.requireContact

	self.dvFast = 0
	self.lastContactTime = -math.huge
	self.blockedUntil = 0
	self.corroborateUntil = 0

	-- Positive tagging, not "everything except the wheels": a part added to the model later
	-- then defaults to harmless rather than to crash-the-plane. QueryDescendants is not in the
	-- type definitions yet.
	self.airframeParts = (sim.model :: any):QueryDescendants(`BasePart.{AIRFRAME_TAG}`)
	assert(
		#self.airframeParts > 0,
		`[Impact] {sim.model:GetFullName()} has no parts tagged {AIRFRAME_TAG}.`
	)

	self.connections = {}

	return self
end

local function onTouched(self: Impact, otherPart: BasePart)
	if otherPart:IsDescendantOf(self.model) then
		-- the plane's own gear and propellers
		return
	end
	local otherParent = otherPart.Parent
	if otherParent and otherParent:IsA("Model") and Players:GetPlayerFromCharacter(otherParent) then
		-- someone standing on a wing is not terrain
		return
	end

	self.lastContactTime = os.clock()
end

function Impact.activate(self: Impact)
	for _, part in self.airframeParts do
		table.insert(self.connections, part.Touched:Connect(function(otherPart)
			onTouched(self, otherPart)
		end))
	end

	Impact.reset(self)
end

--[[
	Forget everything measured so far and hold off for a moment. Used after anything that moves
	the plane other than physics, which produces a velocity change that is not an impact.
]]
function Impact.reset(self: Impact)
	self.dvFast = 0
	self.lastContactTime = -math.huge
	self.blockedUntil = os.clock() + RESET_BLACKOUT
end

--[[
	A client has reported an impact it detected locally. That lowers the bar the server's own
	measurement has to clear, for the window the report stays fresh, and does nothing else: the
	magnitude the server records is always its own.
]]
function Impact.setCorroborated(self: Impact, duration: number)
	self.corroborateUntil = os.clock() + duration
end

--[[
	Call once per heartbeat, after PlaneSim.heartbeat has refreshed the sim's sensing. Returns an
	event on the frame a crash is detected, and nil on every other frame.
]]
function Impact.heartbeat(self: Impact, dt: number): ImpactEvent?
	local sim = self.sim

	self.dvFast = CoreUtil.Math.lowPassDecay(self.dvFast, dt, IMPACT_TAU) + sim.dvNet.Magnitude

	local now = os.clock()
	if now < self.blockedUntil then
		return nil
	end

	local threshold = self.threshold
	if now < self.corroborateUntil then
		threshold *= CORROBORATED_FACTOR
	end

	if self.dvFast <= threshold then
		return nil
	end
	if sim.aNet.Magnitude <= IMPACT_MIN_ACCEL then
		return nil
	end

	local contact = (now - self.lastContactTime) <= CONTACT_WINDOW
	if self.requireContact and not contact then
		return nil
	end

	self.blockedUntil = now + CRASH_BLACKOUT

	return {
		magnitude = self.dvFast,
		dvNetLoc = sim.dvNetLoc,
		position = sim.cf.Position,
		contact = contact,
	}
end

function Impact.destroy(self: Impact)
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)
end

return Impact
