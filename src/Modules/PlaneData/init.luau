local PlaneData: {[string]: PlaneConfig} = {}

local PlaneTypes = require("./PlaneTypes")
	export type PlaneConfig = PlaneTypes.PlaneConfig

PlaneData.index = {}

PlaneData.index["ModelZ"] = require("@self/ModelZData")

return PlaneData