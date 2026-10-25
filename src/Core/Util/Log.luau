local Log = {}
Log.__index = Log

export type Log = setmetatable<{
	tag: string,
	level: number
}, typeof({__index = Log})>

export type LogConfig = {
	tag: string,
	level: number?,		-- cutoff messages below this filter specified
}

Log.SET_LEVEL_GLOBAL = 0

function Log.new(config: LogConfig): Log
	config.level = config.level or Log.SET_LEVEL_GLOBAL
	local self = setmetatable({
		tag = config.tag,
		level = config.level,
	}, Log)
	return self
end

function Log.print(self: Log, msg: string, level: number?)
	if level == nil or self.level <= level then
		print(string.format("[%s] %s", self.tag, msg))
	end
end

function Log.printf(self: Log, fmt: string, level: number?, ...: any)
	if level == nil or self.level <= level then
		self:print(string.format(fmt, ...), level)
	end
end

function Log.warn(self: Log, msg: string, level: number?)
	if level == nil or self.level <= level then
		warn(string.format("[%s] %s", self.tag, msg))
	end
end

function Log.errorMsg(self: Log, msg: string): string
	return string.format("[%s] %s", self.tag, msg)
end

-- levels
Log.DEV = 1
Log.STD = 10
Log.CRIT = 20


return table.freeze(Log)