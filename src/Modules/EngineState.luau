--[[
    Engine states shared by the server, which owns the sequence, and clients, which read it from the
    plane's "engineState" attribute. "engineStateTime" holds the server time the current state began.

    off -> starting -> running -> stopping -> off
]]
local EngineState = {}

export type State = "off" | "starting" | "running" | "stopping"

EngineState.OFF = "off"
EngineState.STARTING = "starting"
EngineState.RUNNING = "running"
EngineState.STOPPING = "stopping"

-- requests a pilot can send to the server
export type Request = "start" | "stop"

EngineState.REQUEST_START = "start"
EngineState.REQUEST_STOP = "stop"

-- seconds each intermediate state lasts before moving on
EngineState.START_DURATION = 6
EngineState.STOP_DURATION = 4

return EngineState
