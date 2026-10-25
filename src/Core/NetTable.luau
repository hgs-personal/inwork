--!strict
--[[
	Object to replicate flat dictionaries / arrays from server and client. Vice-versa TBD.
	Each NetTable handle exists as a unique id entity.

	A scope has two outbound paths per heartbeat:
		1. the delta packet, built once and shared by every already-synced player.
		2. a full snapshot, built once from the scope's live handles and sent only to the
		   players added since the last heartbeat.
	A joining player is promoted into the delta recipients only after their snapshot goes out,
	so they never receive a change for a table they do not hold yet.
]]
local NetTable = {}

local ExperienceStateRecordingService = game:GetService("ExperienceStateRecordingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

local remotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("NetTable")
local remotePacket = remotes:WaitForChild("Packet") :: RemoteEvent	-- per-heartbeat field deltas.
local remoteSync = remotes:WaitForChild("Sync") :: RemoteEvent		-- full state for a joiner.

-- if a value field is a string and starts with "%" don't assume any special logic.
local fieldEscape = "%"
local fieldSpecialPrefix = "/"
local fieldSubPrefix = "S"
local fieldDelete = "D"

local packetActionNew = "N"
local packetActionRevise = "R"
local packetActionDelete = "D"

-- assigned in the ServerHandle block below, used by Scope:processBroadcasts above it.
local newServerHandle, handleFromData, serializeFull, newItem

-- server scope logic --
local Scope = {}
Scope.__index = Scope

function NetTable.scope()
	local self = setmetatable({}, Scope)

	-- players holding this scope's tables already, and so the delta packet's recipients.
	self.players = {}
	-- players added but not yet sent a snapshot. Promoted into players once they have one.
	self.joining = {}
	-- every live handle in this scope, by id. A snapshot is built from exactly this set.
	self.handles = {}
	self.packet = {}
	self.broadcasts = {}
	self.connection = nil

	return self
end

function Scope:activate()
	self.connection = RunService.Heartbeat:Connect(function()
		self:processBroadcasts()
	end)
	-- per-frame scratch only. players / joining / handles are durable and must survive this.
	table.clear(self.broadcasts)
	table.clear(self.packet)
end

function Scope:destroy()
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
	table.clear(self.players)
	table.clear(self.joining)
	table.clear(self.handles)
	table.clear(self.broadcasts)
	table.clear(self.packet)
end

--[[
	Add a player to this scope. They receive one snapshot of every live table on the next
	heartbeat, and only then start receiving deltas.
]]
function Scope:addPlayer(player: Player)
	if table.find(self.players, player) then
		error(`player {player.Name} is already synced to this scope.`)
	end
	if table.find(self.joining, player) then
		error(`player {player.Name} is already waiting on a snapshot from this scope.`)
	end
	table.insert(self.joining, player)
end

function Scope:removePlayer(player: Player)
	local i = table.find(self.players, player)
	if i then
		table.remove(self.players, i)
		return
	end

	-- a player can leave before their snapshot has gone out
	i = table.find(self.joining, player)
	if i then
		table.remove(self.joining, i)
		return
	end

	error(`player {player.Name} is not in this scope.`)
end

function Scope:broadcastNew(handle: ServerHandle<any>)
	if not handle._inqueue then
		handle._inqueue = packetActionNew
		table.insert(self.broadcasts, handle)
	end
end

function Scope:broadcastRevise(handle: ServerHandle<any>)
	-- a queued New already carries the whole table, so a revise on top of it adds nothing.
	if not handle._inqueue then
		handle._inqueue = packetActionRevise
		table.insert(self.broadcasts, handle)
	end
end

function Scope:broadcastDelete(handle: ServerHandle<any>)
	if handle.online then
		error(`handle {handle.id} is still online. Call handle:setOnline(false) first.`)
	end

	if handle._inqueue == packetActionNew then
		--[[
			The table went online and offline inside one heartbeat, so no client ever saw it
			and a delete would name an id they do not have. Cancel instead. The stale queue
			entry is skipped by processBroadcasts rather than removed from the array.
		]]
		handle._inqueue = false
		handle._serialized = nil
		return
	end

	if not handle._inqueue then
		table.insert(self.broadcasts, handle)
	end
	handle._inqueue = packetActionDelete
end

function Scope:processBroadcasts()
	-- 1. the delta packet, shared by every already-synced player.
	table.clear(self.packet)
	for i = 1, #self.broadcasts do
		local h: ServerHandle<any> = self.broadcasts[i]
		local action = h._inqueue
		if not action then
			-- cancelled by broadcastDelete, or a stale duplicate entry
			continue
		end

		if action == packetActionNew then
			table.insert(self.packet, newItem(h))
		else
			table.insert(self.packet, {h.id, action, h._serialized})
		end

		h._inqueue = false
		h._serialized = nil
	end
	table.clear(self.broadcasts)

	if #self.packet > 0 then
		for _, player in self.players do
			remotePacket:FireClient(player, self.packet)
		end
	end

	-- 2. the snapshot, built once no matter how many players joined this heartbeat.
	if #self.joining > 0 then
		local snapshot = {}
		for _, h in self.handles do
			table.insert(snapshot, newItem(h))
		end

		for _, player in self.joining do
			remoteSync:FireClient(player, snapshot)
			-- promoted last: a joiner must not receive the delta fired above
			table.insert(self.players, player)
		end
		table.clear(self.joining)
	end
end
--

-- Server handle --
local ServerHandle = {}
ServerHandle.__index = ServerHandle

export type ServerHandle<T> = setmetatable<{
	id: string,
	tag: string?,
	data: T,
	scope: any,
	online: boolean,
	_serialized: any,
	_inqueue: boolean | string,
}, {__index: typeof(ServerHandle)}>

do
	function handleFromData(data)
		return getmetatable(data)
	end

	function newServerHandle<T>(scope, data: T, tag: string?): ServerHandle<T>
		if handleFromData(data) then
			error("data already has handle or other metatable.")
		end

		local self: ServerHandle<T> = setmetatable({
			id = tostring(data),
			scope = scope,
			data = data,
			online = false,
			_serialized = nil,
			_inqueue = false,
			tag = tag,
		}, ServerHandle)

		setmetatable(data, self)

		return self
	end

	function ServerHandle.get<T, K>(self: ServerHandle<T>, k: K): index<T, K>
		return (self.data::any)[k]
	end

	function ServerHandle.set<T, K>(self: ServerHandle<T>, k: K, v: index<T, K>)
		(self.data::any)[k] = v
	end

	function ServerHandle:subset(k, h: ServerHandle<any>)
		-- TODO: properly type this ...
		self.data[k] = h.data
	end

	function ServerHandle.subget<T, K>(self: ServerHandle<T>, k: K): ServerHandle<index<T, K>>
		local v = (self.data::any)[k]
		if type(v) == "table" then
			local handle = handleFromData(v)
			if handle then
				return handle
			end
		end
		error(`no valid sub-handle at key {k}`)
	end

	function ServerHandle:subinplace(k)
		-- TODO: properly type this ...
		local v = self.data[k]
		if type(v) == "table" then
			local handle = newServerHandle(self.scope, v)
			return handle
		end
		error(`no valid sub-table at key {k} to create handle with.`)
	end

	--[[
		Register or unregister this handle with its scope. The sole door into replication:
		registry membership and queue state change together, here and nowhere else.

		Going offline does not queue a delete. Telling already-synced players that a table is
		gone is an explicit scope:broadcastDelete call, which must follow setOnline(false).
	]]
	function ServerHandle.setOnline(self: ServerHandle<any>, online: boolean)
		if online == self.online then
			return
		end

		self.online = online
		if online then
			self.scope.handles[self.id] = self
			self.scope:broadcastNew(self)
		else
			self.scope.handles[self.id] = nil
		end
	end

	function ServerHandle:_lazySerialized()
		local serialized = self._serialized
		if not serialized then
			serialized = {}
			self._serialized = serialized
		end
		return serialized
	end

	local function serializeValue(value: any): any
		if type(value) == "string" then
			local first = string.sub(value, 1, 1)
			if first == fieldEscape or first == fieldSpecialPrefix then
				return fieldEscape .. value
			end
			return value
		elseif type(value) == "table" then
			-- a data table's metatable IS its handle, so compare the handle to the class
			local handle = handleFromData(value)
			if not handle or getmetatable(handle) ~= ServerHandle then
				error("a table value must be the data of a NetTable sub-handle.")
			end
			if not handle.online then
				error(`sub-handle {handle.id} is offline, so no client can resolve it.`)
			end
			return fieldSpecialPrefix .. fieldSubPrefix .. handle.id
		end
		return value
	end

	--[[
		Serialize a handle's whole table. Pure: it must not write into _serialized, which is
		the revise accumulator and is dropped after every flush.
	]]
	function serializeFull(h: ServerHandle<any>): {[any]: any}
		local serialized = {}
		for k, v in (h.data :: any) do
			serialized[k] = serializeValue(v)
		end
		return serialized
	end

	--[[
		The single source of truth for a New item's wire shape. Used by both the delta packet
		and the snapshot, so the two paths cannot drift apart.
	]]
	function newItem(h: ServerHandle<any>): {any}
		return {
			h.id,					-- [1]: NetTable id
			packetActionNew,		-- [2]: action
			serializeFull(h),		-- [3]: full table contents
			h.tag,					-- [4]: lookup tag, if the handle has one
		}
	end

	function ServerHandle:_serializeField(key, value)
		local serialized = self:_lazySerialized()
		serialized[key] = serializeValue(value)
	end

	function ServerHandle:_serializeClear(key, value)
		table.clear(self._serialized)
	end
end
--

-- Client handle --
--[[
	Read side of a NetTable. Created and written only by incoming packets; game code reads it
	with get / subget and hears about changes through listen.
]]
local ClientHandle = {}
ClientHandle.__index = ClientHandle

export type ClientHandle<T> = setmetatable<{
	id: string,
	data: T,
	listeners: {(key: any, value: any) -> ()},
}, {__index: typeof(ClientHandle)}>

local clientHandles: {[string]: ClientHandle<any>} = {}
local newClientHandle

do
	function newClientHandle<T>(id: string, data: T): ClientHandle<T>
		if clientHandles[id] then
			error(`client handle {id} already exists.`)
		end
		if handleFromData(data) then
			error("data already has handle or other metatable.")
		end

		local self = setmetatable({
			id = id,
			data = data,
			listeners = {},
		}, ClientHandle)

		setmetatable(data :: any, self)
		clientHandles[id] = self

		return self
	end

	function ClientHandle.get<T, K>(self: ClientHandle<T>, k: K): index<T, K>
		return (self.data::any)[k]
	end

	function ClientHandle.subget<T, K>(self: ClientHandle<T>, k: K): ClientHandle<index<T, K>>
		local v = (self.data::any)[k]
		if type(v) == "table" then
			local handle = handleFromData(v)
			if handle then
				return handle
			end
		end
		error(`no valid sub-handle at key {k}`)
	end

	--[[
		Call back with (key, value) every time a field of this table changes from the server.
		Returns a function that removes the listener.
	]]
	function ClientHandle.listen<T>(self: ClientHandle<T>, callback: (key: any, value: any) -> ()): () -> ()
		table.insert(self.listeners, callback)
		return function()
			local i = table.find(self.listeners, callback)
			if i then
				table.remove(self.listeners, i)
			end
		end
	end

	function ClientHandle:_receiveField(k, v)
		self.data[k] = v
		-- clone so a listener can disconnect itself mid-dispatch
		for _, callback in table.clone(self.listeners) do
			callback(k, v)
		end
	end
end

-- Reverses serializeValue. A sub-table reference must name a table the client already has.
local function deserializeValue(value: any): any
	if type(value) == "string" then
		local first = string.sub(value, 1, 1)
		if first == fieldEscape then
			return string.sub(value, 2)
		elseif first == fieldSpecialPrefix then
			local kind = string.sub(value, 2, 2)
			if kind == fieldSubPrefix then
				local id = string.sub(value, 3)
				local handle = clientHandles[id]
				if not handle then
					error(`sub-table reference to unknown NetTable {id}`)
				end
				return handle.data
			end
			error(`unknown special packet value {value}`)
		end
	end
	return value
end

local function receiveTable(id: string, serialized: {[any]: any})
	local data = {}
	for k, v in serialized do
		data[k] = deserializeValue(v)
	end
	newClientHandle(id, data)
end

local function receiveField(id: string, k: any, v: any)
	local handle = clientHandles[id]
	if not handle then
		error(`field update for unknown NetTable {id}`)
	end
	handle:_receiveField(k, deserializeValue(v))
end

local function receiveDelete(id: string)
	if not clientHandles[id] then
		error(`delete for unknown NetTable {id}`)
	end
	clientHandles[id] = nil
end

--[[
	Apply a full-state snapshot of a scope. Two passes, because the server builds a snapshot by
	iterating a hash map: a table may arrive before the sub-table it references. Creating every
	table empty first means every /S<id> reference resolves in the second pass, whatever order
	the items happen to be in.
]]
local function receiveSync(items: {{any}})
	for _, item in items do
		newClientHandle(item[1] :: string, {})
	end

	for _, item in items do
		local handle = clientHandles[item[1] :: string]
		for k, v in (item[3] :: {[any]: any}) do
			handle.data[k] = deserializeValue(v)
		end
	end
end
--

-- Client module --
local Client = {}

Client.awaitQueue = {}

function Client.init()
	if not RunService:IsClient() then
		error("Can only run NetTable.Client on client.")
	end
	remoteSync.OnClientEvent:Connect(receiveSync)
	-- TODO: connect remotePacket to receiveTable / receiveField / receiveDelete.
end

function Client.find(id: string): ClientHandle<any>?
	return clientHandles[id]
end

--[[
	Get or await recieving a handle with a specific tag.
	Snapshot items carry the tag at [4], so this can now be built. Waiters must only be resumed
	once receiveSync's second pass is done, or they observe an empty table.
]]
function Client.await(tag: string)

end

function Client.get(id: string): ClientHandle<any>
	local handle = clientHandles[id]
	if not handle then
		error(`no NetTable with id {id}`)
	end
	return handle
end
--

-- Server module --
local Server = {}

function Server.init()
	if not RunService:IsServer() then
		error("Can only run NetTable.Client on server.")
	end
end

function Server.handle<T>(scope, data: T): ServerHandle<T>
	return newServerHandle(scope, data)
end
--

NetTable.Client = Client
NetTable.Server = Server

return NetTable
