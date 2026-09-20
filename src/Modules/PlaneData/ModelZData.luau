--!strict
local PlaneTypes = require("@game/ReplicatedStorage/Modules/PlaneTypes")
	type PlaneConfig = PlaneTypes.PlaneConfig

local PlaneAssets = game.ReplicatedStorage.Assets.SmallPropPlane

--[[
	Flight model tuning, read by Modules/PlaneSim. These were per-pilot constants inside
	Client/Plane/Pilot; they are per-plane-type values, so they live here.
]]
local ModelZData: PlaneConfig = {
	-- flight force parameters
	kWingArea = 0.1,
	kDragZ = 40000 / (150^2),
	maxThrust = 13000,

	-- flight torque parameters
	kElevator = 5,
	kAileron = 2,
	kRudder = 2,
	kRotDamp = Vector3.new(20, 5, 10),
	kWeathervane = 8,

	-- ground handling parameters
	gearSteerAngle = 30,

	-- structural limits
	crashImpactDv = 70,

	-- engines
	engines = {
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
}

return ModelZData