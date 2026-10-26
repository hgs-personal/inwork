local Session = {}
Session.__index = Session
--[[
	Server-side top level logic and data management for players.

	Has final authority on adding the session relation to Players.
]]

local Log = require("@game/ReplicatedStorage/Core/Util/Log")
	local log = Log.new({tag = script.Name})
local ObjectData = require("@game/ReplicatedStorage/Core/ObjectData")
local NetTable = require("@game/ReplicatedStorage/Core/NetTable")

local NEW_PLAYER_DATA = {
	money = 1000,
}

local function constructNewPlayerDataRecursive(master)
	local output = {}
	for i, v in master do
		if typeof(v) == "table" then
			output[i] = constructNewPlayerDataRecursive(master)
		else
			output[i] = v
		end
	end

	return output
end

local function constructNewPlayerData()
	return constructNewPlayerDataRecursive(NEW_PLAYER_DATA)
end

function Session.new(player: Player)
	local self = setmetatable({}, Session)

	self.player = player
	self.data = constructNewPlayerData()

	-- setup data networking
	self.netScope = NetTable.Server.scope()
	self.netHandle = NetTable.Server.handle(self.netScope, self.data, "sessionData")

	return self
end

function Session:push()
	log:print(`sending session data net table for {self.player.Name}`)
	self.netHandle:setOnline(true)
	self.netScope:addPlayer(self.player)
	self.netScope:activate()
end

--[[
	Tear down this player's replication. The scope and handle exist only for this player, and
	the player is gone by the time this runs, so there is no one left to send the delete to.
]]
function Session:destroy()
	self.netHandle:destroy()
	self.netScope:destroy()
end

function Session.onPlayerAdded(player: Player)
	-- top level server script handles ObjectData creation.
	log:print(`preparing session for {player.Name}`, log.DEV)
	local session = Session.new(player)
	ObjectData.relate(player, "session", session)

	return session
end

function Session.onPlayerRemoving(player: Player)
	-- top level server script handles ObjectData clearing.
	local session = ObjectData.query(player, "session")
	if session then
		-- TODO: handle datastore saving here.
		session:destroy()
	end
end

return Session