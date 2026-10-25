local Log = {}
Log.__index = Log

export type LogConfig = {
	tag: string,
	level: number,		-- cutoff messages below this filter specified
}

Log.SET_LEVEL_GLOBAL = 10

function Log.new(config: LogConfig)
	config.level = config.level or Log.SET_LEVEL_GLOBAL
	local self = setmetatable({
		tag = config.tag,
		level = config.level,
	}, Log)
	return self
end

function Log:print(msg: string, level: number?)
	if level == nil or self.level <= level then
		print(string.format("[%s] %s", self.tag, msg))
	end
end

function Log:warn(msg: string, level: number?)
	if level == nil or self.level <= level then
		warn(string.format("[%s] %s", self.tag, msg))
	end
end

function Log:errorMsg(msg: string): string
	return string.format("[%s] %s", self.tag, msg)
end

-- levels
Log.DEV = 1
Log.STD = 10
Log.CRIT = 20


return Log