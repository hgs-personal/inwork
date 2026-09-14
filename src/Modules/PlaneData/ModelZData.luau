local ModelZData = {}

local PlaneAssets = game.ReplicatedStorage.Assets.SmallPropPlane

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