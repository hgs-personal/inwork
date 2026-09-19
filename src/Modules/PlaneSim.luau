--!strict
--[[
	PlaneSim — the flight model, in one place, running the same way on the server and on a
	client.

	A sim component is a struct plus free functions, not an OOP object, so the whole shape
	is visible in the PlaneSim type below. It owns no Instances: it reads a plane model's
	constraints and writes forces to them.

	Control
	-------
	`controlling` says whether the computer running this sim is the one flying the plane.
	Flight is client-authoritative, so for one plane the two sides disagree:

	- unpiloted plane: the server is controlling, the clients are not.
	- piloted plane: that pilot's client is controlling, the server is not.

	A sim that is not controlling still runs the whole model every heartbeat, so its
	sensing fields (v, vLoc, liftWingNorm, onGround) stay meaningful, but it writes nothing
	to a replicated Instance. That is what keeps the server from fighting a pilot's physics.

	Inputs come from setPrimaryFlightControls and setEngineState. Where they come from is
	the caller's problem: Server/Plane feeds them from the plane's attributes and remotes, a
	pilot client would feed them from the keyboard and mouse.

	Rotation
	--------
	ROTATION_MODE picks between two rotation models, and they are mutually exclusive: each
	writes only its own constraint and zeroes the other's authority so the two cannot fight.

	- "arcade" is what Client/Plane/Pilot does today: the yoke asks an AngularVelocity
	  constraint for a rotation rate directly, and gets it whatever the airspeed.
	- "torque" is the virtual control surface model in heartbeatRotationTorque. The plane is
	  pushed around by moments, so it carries rotational momentum, and it loses control
	  authority as it slows down.

	Both modes need their own constraint on the model, so a plane model needs both.
]]
local PlaneSim = {}

local RunService = game:GetService("RunService")

local SafeDataModel = require("@game/ReplicatedStorage/Core/SafeDataModel")
	local getChild = SafeDataModel.getChild
local EngineState = require("./EngineState")
local PlaneData = require("./PlaneData")

-- CONSTANTS --
local G = workspace.Gravity
local RHO_AIR_NORM = 1
local AOA_MAX_LIFT_W = math.rad(20)
local AOA_OFFS = math.rad(5)

-- "arcade" or "torque". See the Rotation section above.
local ROTATION_MODE = "torque"

local ARCADE_WINDVANE_K = 4
-- finite rather than math.huge, which physics properties do not always accept
local ARCADE_MAX_TORQUE = 9999999
-- yoke deflection of 1 asks for this much angular velocity
local ARCADE_RATE = math.rad(15)
-- speed at which the wind vane term reaches full strength
local ARCADE_WINDVANE_SPEED2 = 100

-- steering angle of the rear gear at full rudder, in degrees
local GROUND_STEER_ANGLE = 30
-- how far below a wheel point counts as touching the ground
local GROUND_CLEARANCE = 3

local LIFT_CLAMP = 1e3
-- ceiling on the torque mode's total moment, so a dive cannot produce an absurd one
local TORQUE_CLAMP = 1e6
--

type PlaneConfig = {
	kWingArea: number,
	kDragZ: number,
	maxThrust: number,

	-- torque rotation mode. All of these are moments per unit of dynamic pressure, so the
	-- actual moment is the coefficient times q.
	kElevator: number,					-- pitch authority per unit of yoke Y
	kAileron: number,					-- roll authority per unit of yoke X
	kRudder: number,					-- yaw authority per unit of rudder
	kRotDamp: Vector3,					-- orientational drag, per axis (pitch, yaw, roll)
	kWeathervane: number,				-- yaw restoring moment per radian of sideslip
}

type PlaneSim = {
	model: Model,
	root: BasePart,

	config: PlaneConfig,

	kill: boolean,						-- set to false to have sim component dropped on next cycle
	controlling: boolean,				-- true when computer running the code is in control (false for server when being piloted, true for client)
	engineState: EngineState.State,
	onGround: boolean,

	throttle: number,
	yoke: Vector2,
	rudder: number,

	-- sensing, refreshed every heartbeat whether controlling or not
	cf: CFrame,
	v: Vector3,							-- world velocity
	vLoc: Vector3,						-- velocity in the root's object space
	v2: number,							-- speed squared
	omegaLoc: Vector3,					-- angular velocity in the root's object space
	liftWingNorm: number,				-- wing lift in Gs, before gravity is applied
	wheelPoints: {BasePart},
	groundCastParams: RaycastParams,

	-- flight constraints
	thrust: VectorForce,
	angularVelocity: AngularVelocity,
	torque: Torque,

	-- taxi constraints
	gearCylinder: CylindricalConstraint
}

local V2 = Vector2.new
local V3 = Vector3.new

local planeSimTable: {PlaneSim} = {}

function PlaneSim.new(model: Model, controlling): PlaneSim
	local self = {}

	self.model = model
	self.root = assert(model.PrimaryPart, "[PlaneSim] model has no root part.")

	self.kill = false
	self.controlling = controlling
	self.engineState = EngineState.OFF
	self.onGround = true

	self.throttle = 0
	self.yoke = V2(0, 0)
	self.rudder = 0

	-- flight config for this plane type
	local planeType = assert(model:GetAttribute("planeType"), "[PlaneSim] model has no planeType attribute.")
	local planeTypeData = assert(PlaneData.index[planeType], `[PlaneSim] unrecognized planeType: {planeType}`)
	self.config = assert(planeTypeData.flight, `[PlaneSim] planeType {planeType} has no flight config.`)

	-- sensing
	self.cf = self.root.CFrame
	self.v = Vector3.zero
	self.vLoc = Vector3.zero
	self.v2 = 0
	self.omegaLoc = Vector3.zero
	self.liftWingNorm = 0

	-- QueryDescendants is not in the type definitions yet
	self.wheelPoints = (model :: any):QueryDescendants("BasePart#WheelPoints")
	self.groundCastParams = RaycastParams.new()
	self.groundCastParams.FilterType = Enum.RaycastFilterType.Exclude
	self.groundCastParams.FilterDescendantsInstances = { model }

	-- get instances
	local constraints = model:WaitForChild("Constraints")
	self.thrust = getChild(constraints, "Thrust", "VectorForce")
	self.angularVelocity = getChild(constraints, "AngularVelocity", "AngularVelocity")
	self.torque = getChild(constraints, "Torque", "Torque")
	-- the torque mode builds its moment in the root's object space, so a torque authored
	-- relative to anything else would rotate the plane around the wrong axes
	assert(
		self.torque.RelativeTo == Enum.ActuatorRelativeTo.Attachment0,
		`[PlaneSim] {model:GetFullName()} Torque must have RelativeTo = Attachment0.`
	)
	self.gearCylinder = getChild(constraints, "GearCylinderRear", "CylindricalConstraint")

	return self
end

function PlaneSim.activate(self: PlaneSim, multi)
	-- final step
	if multi then
		table.insert(planeSimTable, self)
	end
end

function PlaneSim.destroy(self: PlaneSim)
	self.kill = true

	-- stop applying whatever this sim was applying, rather than leaving the last frame's
	-- force on the plane forever
	if self.controlling then
		self.thrust.Force = Vector3.zero
		self.angularVelocity.MaxTorque = 0
		self.torque.Torque = Vector3.zero
	end
end

--[[
	Set the pilot inputs. throttle is 0..1, yoke is pitch and roll deflection in -1..1, and
	rudder is ground steer in -1..1.
]]
function PlaneSim.setPrimaryFlightControls(self: PlaneSim, throttle: number, yoke: Vector2, rudder: number)
	self.throttle = math.clamp(throttle, 0, 1)
	self.yoke = V2(math.clamp(yoke.X, -1, 1), math.clamp(yoke.Y, -1, 1))
	self.rudder = math.clamp(rudder, -1, 1)
end

--[[
	The engine state is owned by the server. Both sides push it in here rather than the sim
	reading the attribute itself, so the sim has no opinion about where state lives.
]]
function PlaneSim.setEngineState(self: PlaneSim, state: EngineState.State)
	self.engineState = state
end

function PlaneSim.heartbeat(self: PlaneSim, dt: number)
	-- When plane is not under control by current computer,
	-- update any sensing logic, but do not make state changes to any replicated instancess.
	PlaneSim.heartbeatSensing(self, dt)

	local aeroForce = PlaneSim.heartbeatAerodynamics(self, dt)
	local engineThrust = PlaneSim.heartbeatEngine(self, dt)

	PlaneSim.heartbeatOnGround(self, dt)

	if not self.controlling then
		return
	end

	self.thrust.Force = engineThrust + aeroForce

	if ROTATION_MODE == "torque" then
		PlaneSim.heartbeatRotationTorque(self, dt)
	else
		PlaneSim.heartbeatRotationArcade(self, dt)
	end

	self.gearCylinder.TargetAngle = self.rudder * GROUND_STEER_ANGLE
end

--[[
	Read the plane's motion into the sensing fields. Everything below reads these rather
	than the root part, so one heartbeat sees one consistent snapshot.
]]
function PlaneSim.heartbeatSensing(self: PlaneSim, dt: number)
	self.cf = self.root.CFrame
	self.v = self.root.AssemblyLinearVelocity
	self.v2 = self.v:Dot(self.v)
	self.vLoc = self.cf:VectorToObjectSpace(self.v)
	self.omegaLoc = self.cf:VectorToObjectSpace(self.root.AssemblyAngularVelocity)
end

--[[
	Wing lift and body drag, in the root's object space. Lift peaks near AOA_MAX_LIFT_W and
	falls off past it rather than growing without bound, which is what makes a stall
	possible.
]]
function PlaneSim.heartbeatAerodynamics(self: PlaneSim, dt: number): Vector3
	local vLoc = self.vLoc

	local aoaWings = math.atan2(-vLoc.Y, -vLoc.Z)
	local liftCoeffWings = math.sin(
		math.clamp(aoaWings + AOA_OFFS, -1.5 * AOA_MAX_LIFT_W, 1.5 * AOA_MAX_LIFT_W) * math.pi / 2 / AOA_MAX_LIFT_W
	)
	local liftWingNorm = liftCoeffWings * 0.5 * self.v2 * RHO_AIR_NORM * self.config.kWingArea

	liftWingNorm = math.clamp(liftWingNorm, -LIFT_CLAMP, LIFT_CLAMP)
	self.liftWingNorm = liftWingNorm

	local dragZ = vLoc.Z ^ 2 * 0.5 * RHO_AIR_NORM * self.config.kDragZ

	return V3(0, liftWingNorm * G, dragZ)
end

function PlaneSim.heartbeatEngine(self: PlaneSim, dt: number): Vector3
	-- thrust only while the engines are actually running
	if self.engineState ~= EngineState.RUNNING then
		return Vector3.zero
	end

	local engineThrust = V3(0, 0, -self.throttle * self.config.maxThrust)
	return engineThrust
end

--[[
	Hysteresis between flying and taxiing. Leaving the ground needs lift and vertical
	speed; returning to it needs a wheel within clearance of something and both of those
	back down. The two thresholds differ so the plane doesn't flicker between the states.
]]
function PlaneSim.heartbeatOnGround(self: PlaneSim, dt: number)
	local mass = self.root.AssemblyMass

	local pointsOnGround = 0
	for _, wheelPoint in self.wheelPoints do
		local groundRay = workspace:Raycast(wheelPoint.Position, V3(0, -GROUND_CLEARANCE, 0), self.groundCastParams)
		if groundRay then
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
end

--[[
	Torque rotation: virtual ailerons, elevators and a rudder.

	Each surface's deflection is tied straight to its input, so a yoke of 0.5 is half
	deflection and produces half the moment. That part is cartoony on purpose — no surface
	travel curves, no control blowback, and no coupling between axes.

	What is not cartoony is where the strength comes from. A control surface makes its
	moment out of the air flowing over it, so every term below scales with dynamic pressure
	q = 1/2 rho v^2. The consequences are the ones that make an aircraft feel like one: full
	deflection does almost nothing at taxi speed, authority climbs with the square of
	airspeed, and a plane that stalls or slows to nothing stops answering the controls.

	Three moments are summed, all of them proportional to q:

	- control, linear in aileron / elevator / rudder deflection.
	- orientational drag, opposing the current rotation on each axis. This is what damps
	  the plane out instead of letting a pulse of elevator leave it tumbling forever, and
	  it is what makes the rates settle rather than integrate. Being proportional to q, it
	  also fades with airspeed, so the plane feels loose when slow.
	- weathervane, a restoring moment proportional to sideslip that pulls the nose back
	  towards the relative wind. Without it the plane happily flies sideways, since nothing
	  else here supplies directional stability.

	The model requires a `Torque` constraint on the plane, with RelativeTo = Attachment0 so
	the vector below is read in the root's object space. Control torque is cut on the ground
	so the gear steers instead, matching the arcade mode.
]]
function PlaneSim.heartbeatRotationTorque(self: PlaneSim, dt: number)
	local config = self.config
	local q = 0.5 * RHO_AIR_NORM * self.v2

	-- the arcade mode drives the other constraint; make sure it is not also pulling
	self.angularVelocity.MaxTorque = 0

	local controlMoment = Vector3.zero
	if not self.onGround then
		-- sign convention matches the arcade mode, so the controls feel the same way round
		controlMoment = V3(
			-self.yoke.Y * config.kElevator,
			self.rudder * config.kRudder,
			-self.yoke.X * config.kAileron
		)
	end

	-- opposes whatever rotation the plane currently has, per axis
	local dampingMoment = -self.omegaLoc * config.kRotDamp

	-- sideslip: positive when the relative wind comes from the right
	local sideslip = math.atan2(self.vLoc.X, -self.vLoc.Z)
	local weathervaneMoment = V3(0, -sideslip * config.kWeathervane, 0)

	local moment = (controlMoment + dampingMoment + weathervaneMoment) * q

	if moment.Magnitude > TORQUE_CLAMP then
		moment = moment.Unit * TORQUE_CLAMP
	end

	self.torque.Torque = moment
end

--[[
	Arcade rotation: the yoke asks for an angular velocity directly. The wind vane term
	yaws the nose towards the direction of travel, and fades in with speed so a parked
	plane isn't dragged around. Torque is cut on the ground so the gear steers instead.
]]
function PlaneSim.heartbeatRotationArcade(self: PlaneSim, dt: number)
	-- the torque mode drives the other constraint; make sure it is not also pushing
	self.torque.Torque = Vector3.zero

	local windVaneAngle = math.atan2(self.vLoc.X, -self.vLoc.Z)
	local windVaneCoeff = math.clamp(self.v2 / ARCADE_WINDVANE_SPEED2, 0, 1)

	self.angularVelocity.MaxTorque = if self.onGround then 0 else ARCADE_MAX_TORQUE
	self.angularVelocity.AngularVelocity = V3(
		-self.yoke.Y,
		-windVaneAngle * windVaneCoeff * ARCADE_WINDVANE_K,
		-self.yoke.X
	) * ARCADE_RATE
end

-- system functions --
function PlaneSim.init()
end

function PlaneSim.systemHeartbeat(dt)
	for i = 1, #planeSimTable do
		local sim = planeSimTable[i]
		PlaneSim.heartbeat(sim, dt)
	end

	for i = #planeSimTable, 1, -1 do
		local sim = planeSimTable[i]
		if sim.kill then
			planeSimTable[i] = planeSimTable[#planeSimTable]
			planeSimTable[#planeSimTable] = nil
		end
	end
end

function PlaneSim.start(multi)
	-- ATM, plane sim entities are only batch updated on the server, client should only
	-- be simulating 1 plane at a time.
	if multi then
		RunService.Heartbeat:Connect(PlaneSim.systemHeartbeat)
	end
end
--

return PlaneSim
