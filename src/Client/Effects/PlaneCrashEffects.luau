local PlaneCrashEffects = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Util = require("@game/ReplicatedStorage/Core/Util")
	local Sound = Util.Sound

local assets = ReplicatedStorage.Assets
local crashExplosionTempl = assets.Effects.CrashExplosion
local crashSound = assets.Effects.CrashSoundSimple

type Args = {
	positionAtImpact: Vector3, -- center position of plane recorded for impact
}
function PlaneCrashEffects.spawn(args: Args)
	local explosion = crashExplosionTempl:Clone()
	explosion.CFrame = CFrame.new(args.positionAtImpact)

	local explosionParticle = explosion.Explosion
	local smokeParticle = explosion.Smoke

	explosion.Parent = workspace

	explosionParticle:Emit(100)
	smokeParticle:Emit(50)

	Sound.playEffectSoundPositional(crashSound, args.positionAtImpact)

	Debris:AddItem(explosion, 5)
end

return PlaneCrashEffects