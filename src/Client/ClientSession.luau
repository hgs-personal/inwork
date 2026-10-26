local ClientStorageService = game:GetService("ClientStorageService")
local ClientSession = {}
	local Self = ClientSession
--[[
	Client-side view of the local player's own session data, which the server replicates from
	Server/Session as the NetTable tagged "sessionData".

	Session data arrives some time after the client starts, so there is no synchronous way to read
	it during init. Everything that needs it goes through ClientSession.await.
]]

local Signal = require("@game/ReplicatedStorage/Core/Util/Signal")
local Log = require("@game/ReplicatedStorage/Core/Util/Log")
	local log = Log.new({tag = "ClientSession"})
local NetTable = require("@game/ReplicatedStorage/Core/NetTable")
local Client = require("./Client")

local SESSION_TAG = "sessionData"

-- client flow signals
ClientSession.ready = false
ClientSession.signalReady = Signal.new()

-- the handle once it has arrived, nil before that. Prefer await over reading this directly.
local handle

function ClientSession.init()
	log:print("waiting on session data from the server.", Log.STD)

	-- await yields, and init runs inside the client's startup chain, which must not block.
	task.spawn(function()
		handle = NetTable.Client.await(SESSION_TAG)
		ClientSession.handle = handle
		log:printf("session data arrived. money=%s", Log.STD, tostring(handle:get("money")))

		ClientSession.ready = true
		ClientSession.signalReady:fire()
	end)
end

function ClientSession.awaitReady()
	if not Self.ready then
		Self.signalReady:wait()
	end
end

return ClientSession
