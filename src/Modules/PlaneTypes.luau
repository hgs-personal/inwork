export type EngineConfig = {
	soundStart: Sound,

	soundMid: Sound,
	soundMidRPMFactorLow: number,
	soundMidRPMFactorHigh: number,

	soundHigh: Sound,
	soundHighRPMFactorLow: number,
	soundHighRPMFactorHigh: number,

	soundHighThresholdSpeed: number, -- speed center of fade between mid and high prop sounds
	soundHighThresholdBand: number, -- width of fade
	}

export type PlaneConfig = {
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

	gearSteerAngle: number,

	-- structural limits. See Modules/Impact.
	crashImpactDv: number,				-- speed the airframe absorbs in one impact before it is a crash

	engines: {EngineConfig}
}

return {}