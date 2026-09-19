local ModelZData = {}

local PlaneAssets = game.ReplicatedStorage.Assets.SmallPropPlane

--[[
	Flight model tuning, read by Modules/PlaneSim. These were per-pilot constants inside
	Client/Plane/Pilot; they are per-plane-type values, so they live here.
]]
ModelZData.flight = {
	kWingArea = 0.2,
	kDragZ = 40000 / (150^2),
	maxThrust = 20000,

	--[[
		Rotation, for PlaneSim's torque mode. Every one of these is a moment per unit of
		dynamic pressure q, so the moment a surface actually makes is the coefficient times
		q. At 150 studs/s, q is about 11250.

		FIRST PASS, NOT TUNED. They were picked to be in a plausible ratio to each other,
		not measured against this airframe's mass and inertia. Fly it and scale them.
	]]
	kElevator = 3,
	kAileron = 4,
	kRudder = 2,
	kRotDamp = Vector3.new(2, 2, 1.5),
	kWeathervane = 6,
}

ModelZData.engines = {
	[1] = {
		soundStart = PlaneAssets.EngineStart,

		soundMid = PlaneAssets.EngineMid,
		soundMidRPMFactorLow = 0.8,
		soundMidRPMFactorHigh = 1.5,

		soundHigh = PlaneAssets.EngineHigh,
		soundHighRPMFactorLow = 0.8,
		soundHighRPMFactorHigh = 1.5,

		soundHighThresholdSpeed = 100, -- speed center of fade between mid and high prop sounds
		soundHighThresholdBand = 30, -- width of fade
	}
}

return ModelZData