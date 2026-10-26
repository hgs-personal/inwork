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

	On the client a handle is also the event surface for its table: listenAll for any field,
	listen for one field, onDestroyed for the table going away. Tables arriving and leaving are
	module-level events, and a tagged table can be awaited by tag.
]]
local NetTable = {}


local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
	local IS_SERVER = RunService:IsServer()

local log = require("./Util/Log").new({tag = "NetTable"})
local Signal = require("./Util/Signal")
local CoreUtil = require("./Util")

--[[
	The client's event shapes, named once so the handle type and the listen signatures below stay
	readable. Keys and values are whatever the server put in the table, hence any.
]]
type FieldSignal = Signal.Signal<any, any>					-- (value, old)
type UpdatedSignal = Signal.Signal<any, any, any>			-- (key, value, old)
type HandleSignal = Signal.Signal<ClientHandle<any>>
type DestroyingSignal = Signal.Signal<>

export type FieldConnection = Signal.Connection<any, any>
export type UpdatedConnection = Signal.Connection<any, any, any>
export type HandleConnection = Signal.Connection<ClientHandle<any>>
export type DestroyingConnection = Signal.Connection<>

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

local nextHandleId = 0

local function newHandleId(): string
	nextHandleId += 1
	return CoreUtil.Encode.intToB64(nextHandleId)
end

-- server scope logic --
local Scope = {}
Scope.__index = Scope

--[[
	Every live scope, so a leaving player can be taken out of all of them. See Server.init: the
	scope itself is the only thing that knows whether it holds a given player.
]]
local scopes: {any} = {}

local function newScope()
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

	table.insert(scopes, self)

	return self
end

--[[
	Start heartbeating. Nothing is cleared here: a handle may legitimately be registered and
	queued before the scope is activated, and throwing that queue away would drop the New for
	a table the server already considers published.
]]
function Scope:activate()
	if self.connection then
		error("scope is already active.")
	end
	self.connection = RunService.Heartbeat:Connect(function()
		self:processBroadcasts()
	end)
end

function Scope:destroy()
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end

	local i = table.find(scopes, self)
	if i then
		table.remove(scopes, i)
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

function Scope:hasPlayer(player: Player): boolean
	return table.find(self.players, player) ~= nil or table.find(self.joining, player) ~= nil
end

--[[
	A New carries the whole table, so it supersedes anything already queued for this handle,
	including a Delete: a table taken down and republished in the same frame must reach the
	client as a table it still holds, not as one that vanished.
]]
function Scope:broadcastNew(handle: ServerHandle<any>)
	if not handle._inqueue then
		table.insert(self.broadcasts, handle)
	end
	handle._inqueue = packetActionNew
end

function Scope:broadcastRevise(handle: ServerHandle<any>)
	-- a queued New already carries the whole table, and a queued Delete makes the revise moot.
	if not handle._inqueue then
		handle._inqueue = packetActionRevise
		table.insert(self.broadcasts, handle)
	end
end

function Scope:broadcastDelete(handle: ServerHandle<any>)
	--[[
		A New still sitting in the queue means no client ever heard about this table, so there is
		nothing to tell them about: cancel the entry outright rather than send a delete they
		cannot resolve. The stale queue entry is left in place, because processBroadcasts skips
		a handle whose _inqueue has been cleared.
	]]
	if handle._inqueue == packetActionNew then
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
	--[[
		1. the delta packet, shared by every already-synced player.

		The queue is drained whether or not anyone is listening. _inqueue is what makes a second
		broadcast for the same handle a no-op within one frame, so leaving it set on a heartbeat
		with no recipients would silently stop that handle from ever broadcasting again.
	]]
	local hasPlayers = #self.players > 0
	table.clear(self.packet)

	for i = 1, #self.broadcasts do
		local h: ServerHandle<any> = self.broadcasts[i]
		local action = h._inqueue
		if not action then
			-- a duplicate entry already drained this frame, or one broadcastDelete cancelled
			continue
		end

		if hasPlayers then
			if action == packetActionNew then
				table.insert(self.packet, newItem(h))
			elseif action == packetActionDelete then
				table.insert(self.packet, {h.id, action})
			else
				table.insert(self.packet, {h.id, action, h._serialized})
			end
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
		-- an empty scope still sends an empty snapshot, because promotion into players is what
		-- the snapshot going out means. Skipping it would leave the joiner stuck in joining.
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
			id = newHandleId(),
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
	function newItem(h: ServerHandle<any>): {[any]: any}
		return {
			h.id,					-- [1]: NetTable id
			packetActionNew,		-- [2]: action
			serializeFull(h),		-- [3]: full table contents
			h.tag,					-- [4]: lookup tag<optional>
		}
	end

	function ServerHandle._lazySerialized(self: ServerHandle<any>): {[any]: any}
		local serialized = self._serialized
		if not serialized then
			serialized = {}
			self._serialized = serialized
		end
		return serialized
	end

	function ServerHandle._serializeField(self: ServerHandle<any>, key: any, value: any)
		self:_lazySerialized()[key] = serializeValue(value)
	end

	--[[
		A removal cannot travel as a nil, because a nil in the accumulator is indistinguishable
		from a key that was never written. It travels as the "/D" sentinel instead, which
		deserializeValue turns back into nil.
	]]
	function ServerHandle._serializeRemove(self: ServerHandle<any>, key: any)
		self:_lazySerialized()[key] = fieldSpecialPrefix .. fieldDelete
	end

	--[[
		Write a field and queue the revise. An offline handle writes locally and queues nothing:
		no client holds the table, and going online serializes the whole table again, so there is
		nothing for a delta to add.
	]]
	local function setField(h: ServerHandle<any>, k: any, v: any)
		(h.data :: any)[k] = v
		if h.online then
			h:_serializeField(k, v)
			h.scope:broadcastRevise(h)
		end
	end

	function ServerHandle.set<T, K>(self: ServerHandle<T>, k: K, v: index<T, K>)
		setField(self :: any, k, v)
	end

	-- Clear a field. Leaves a hole when the table is being used as an array.
	function ServerHandle.remove(self: ServerHandle<any>, k: any)
		(self.data :: any)[k] = nil
		if self.online then
			self:_serializeRemove(k)
			self.scope:broadcastRevise(self)
		end
	end

	function ServerHandle.subset(self: ServerHandle<any>, k: any, h: ServerHandle<any>)
		setField(self, k, h.data)
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

	function ServerHandle.subinplace(self: ServerHandle<any>, k: any)
		-- TODO: properly type this ...
		local v = (self.data :: any)[k]
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
		gone is an explicit scope:broadcastDelete call, which must follow setOnline(false) —
		or just use destroy, which does both in the right order.
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

	--[[
		Take the table down for good: out of the scope's registry, a delete to everyone holding
		it, and the data table detached so the same table cannot silently be re-handled later.
	]]
	function ServerHandle.destroy(self: ServerHandle<any>)
		local wasOnline = self.online
		self:setOnline(false)
		if wasOnline then
			self.scope:broadcastDelete(self)
		end
		setmetatable(self.data :: any, nil)
	end
end
--

-- Client handle --
--[[
	Read side of a NetTable. Created and written only by incoming packets; game code reads it
	with get / subget and hears about changes through listen / listenAll.
]]
local ClientHandle = {}
ClientHandle.__index = ClientHandle

export type ClientHandle<T> = setmetatable<{
	id: string,
	data: T,
	tag: string?,
	-- every field change, as (key, value, old)
	updated: UpdatedSignal,
	-- fires once, with no arguments, when the server deletes this table
	destroying: DestroyingSignal,
	-- per-field signals, created on first listen so an unwatched handle costs one empty table
	fields: {[any]: FieldSignal},
}, {__index: typeof(ClientHandle)}>

local clientHandles: {[string]: ClientHandle<any>} = {}
local taggedHandles: {[string]: ClientHandle<any>} = {}
local tagSignals: {[string]: HandleSignal} = {}
local addedSignal: HandleSignal = Signal.new()
local removedSignal: HandleSignal = Signal.new()
local newClientHandle

do
	function newClientHandle<T>(id: string, data: T, tag: string?): ClientHandle<T>
		if clientHandles[id] then
			error(`client handle {id} already exists.`)
		end
		if handleFromData(data) then
			error("data already has handle or other metatable.")
		end
		if tag and taggedHandles[tag] then
			error(`a live NetTable already holds the tag {tag}.`)
		end

		-- annotated locals rather than a bare Signal.new() in the literal, so each signal's
		-- argument pack is pinned here instead of left to inference through setmetatable.
		local updated: UpdatedSignal = Signal.new()
		local destroying: DestroyingSignal = Signal.new()
		local fields: {[any]: FieldSignal} = {}

		local self = setmetatable({
			id = id,
			data = data,
			tag = tag,
			updated = updated,
			destroying = destroying,
			fields = fields,
		}, ClientHandle)

		setmetatable(data :: any, self)
		clientHandles[id] = self
		if tag then
			taggedHandles[tag] = self
		end

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
		Call back with (value, old) every time one field changes from the server. A removed field
		arrives as a nil value.

		A table's initial contents do not arrive this way: a handle is fully populated before
		anything can hold it, so read those with get and treat a field event as strictly "this
		changed since you last looked".
	]]
	function ClientHandle.listen<T>(
		self: ClientHandle<T>,
		key: any,
		callback: (value: any, old: any) -> ()
	): FieldConnection
		local signal = self.fields[key]
		if not signal then
			local created: FieldSignal = Signal.new()
			self.fields[key] = created
			signal = created
		end
		return signal:connect(callback)
	end

	-- Call back with (key, value, old) for any field of this table changing.
	function ClientHandle.listenAll<T>(
		self: ClientHandle<T>,
		callback: (key: any, value: any, old: any) -> ()
	): UpdatedConnection
		return self.updated:connect(callback)
	end

	-- Call back once when the server deletes this table. See Client.onRemoved for all tables.
	function ClientHandle.onDestroyed<T>(self: ClientHandle<T>, callback: () -> ()): DestroyingConnection
		return self.destroying:once(callback)
	end

	function ClientHandle._receiveField(self: ClientHandle<any>, k: any, v: any)
		local data = self.data :: any
		local old = data[k]
		if old == v then
			-- a snapshot racing a live delta is the normal way to see this, and firing the field
			-- twice for one server-side write would be a lie about what changed.
			return
		end
		data[k] = v

		local signal = self.fields[k]
		if signal then
			signal:fire(v, old)
		end
		self.updated:fire(k, v, old)
	end

	--[[
		Drop every listener once the removal has been announced. The data table keeps its
		metatable: a listener is free to yield, and detaching here would leave it resuming with a
		data table whose handle has vanished.
	]]
	function ClientHandle._destroy(self: ClientHandle<any>)
		self.destroying:disconnectAll()
		self.updated:disconnectAll()
		for _, signal in self.fields do
			signal:disconnectAll()
		end
		table.clear(self.fields)
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
			elseif kind == fieldDelete then
				return nil
			end
			error(`unknown special packet value {value}`)
		end
	end
	return value
end

local function tagSignal(tag: string): HandleSignal
	local signal = tagSignals[tag]
	if not signal then
		local created: HandleSignal = Signal.new()
		tagSignals[tag] = created
		signal = created
	end
	return signal
end

--[[
	Create, fill and announce every New item in a batch, in three passes over the batch.

	Both the snapshot and the delta packet are built by iterating a set, so a table can be listed
	before the sub-table it references. Creating every table empty first means every /S<id>
	resolves in the fill pass, whatever order the items happen to be in. Announcing last matters
	for the same reason: an await waiter resumed mid-fill would observe a half-built table.
]]
local function applyNewItems(items: {{[any]: any}})
	local created: {ClientHandle<any>} = {}
	local contents: {{[any]: any}} = {}

	for _, item in items do
		if item[2] == packetActionNew then
			table.insert(created, newClientHandle(item[1] :: string, {}, item[4]))
			table.insert(contents, item[3] :: {[any]: any})
		end
	end

	for i, handle in created do
		local data = handle.data :: any
		for k, v in contents[i] do
			data[k] = deserializeValue(v)
		end
	end

	for _, handle in created do
		log:printf("client: received table. id=%s, tag=%s", log.DEV, handle.id, handle.tag or "NONE")

		local signal = if handle.tag then tagSignals[handle.tag] else nil
		if signal then
			signal:fire(handle)
		end
		addedSignal:fire(handle)
	end
end


local function receiveDelete(id: string)
	local handle = clientHandles[id]
	if not handle then
		error(`delete for unknown NetTable {id}`)
	end

	-- unregistered before anything is told, so a listener that looks the table up sees it gone
	clientHandles[id] = nil
	if handle.tag then
		taggedHandles[handle.tag] = nil
	end

	handle.destroying:fire()
	removedSignal:fire(handle)
	handle:_destroy()
end

-- Apply a full-state snapshot of a scope.
local function receiveSync(items: {{[any]: any}})
	log:printf("client: receiving sync of %d tables.", log.STD, #items)
	applyNewItems(items)
end

--[[
	Apply one heartbeat's deltas. New items go first and as one batch, so a revise or a sub-table
	reference later in the same packet can resolve against a table the packet itself introduces.
]]
local function receivePacket(items: {{[any]: any}})
	applyNewItems(items)

	for _, item in items do
		local action = item[2]
		if action == packetActionRevise then
			local id = item[1] :: string
			local handle = clientHandles[id]
			if not handle then
				error(`revise for unknown NetTable {id}`)
			end
			for k, v in (item[3] :: {[any]: any}) do
				handle:_receiveField(k, deserializeValue(v))
			end
		elseif action == packetActionDelete then
			receiveDelete(item[1] :: string)
		end
	end
end
--

-- Client module --
local Client = {}

function Client.init()
	if not RunService:IsClient() then
		error("Can only run NetTable.Client on client.")
	end
	log:print("client: initializing. listening for sync and packet events.", log.STD)

	remoteSync.OnClientEvent:Connect(receiveSync)
	remotePacket.OnClientEvent:Connect(receivePacket)
end

function Client.find(id: string): ClientHandle<any>?
	return clientHandles[id]
end

function Client.get(id: string): ClientHandle<any>
	local handle = clientHandles[id]
	if not handle then
		error(`no NetTable with id {id}`)
	end
	return handle
end

function Client.findTag(tag: string): ClientHandle<any>?
	return taggedHandles[tag]
end

--[[
	Get the handle holding a tag, yielding until it arrives if it is not here yet. A tag is held
	by at most one live table, so this resolves to exactly one handle.
]]
function Client.await(tag: string): ClientHandle<any>
	local handle = taggedHandles[tag]
	if handle then
		return handle
	end

	return tagSignal(tag):wait()
end

--[[
	Call back with the handle each time a table claiming this tag arrives. Does not replay a
	table that is already here — use await or findTag for that.
]]
function Client.onTag(tag: string, callback: (handle: ClientHandle<any>) -> ()): HandleConnection
	return tagSignal(tag):connect(callback)
end

-- Call back with the handle for every table arriving, tagged or not. Fully populated already.
function Client.onAdded(callback: (handle: ClientHandle<any>) -> ()): HandleConnection
	return addedSignal:connect(callback)
end

--[[
	Call back with the handle for every table the server deletes. The handle is already out of
	find / findTag by then, and its own listeners are dropped once every callback here has been
	dispatched, so a reference kept past the callback is a snapshot that will never update again.
]]
function Client.onRemoved(callback: (handle: ClientHandle<any>) -> ()): HandleConnection
	return removedSignal:connect(callback)
end
--

-- Server module --
local Server = {}

function Server.init()
	if not IS_SERVER then
		error("Can only run NetTable.Server on server.")
	end

	--[[
		A leaving player has to come out of every scope holding them. Left in, the scope keeps
		firing remotes at a player who is gone, and a rejoin in the same session hits the
		"already synced" error in addPlayer.
	]]
	Players.PlayerRemoving:Connect(function(player)
		for _, scope in scopes do
			if scope:hasPlayer(player) then
				scope:removePlayer(player)
			end
		end
	end)
end

function Server.scope()
	if not IS_SERVER then
		error("Can not create Server scopes on client.")
	end
	return newScope()
end

Server.handle = newServerHandle
--

NetTable.Client = Client
NetTable.Server = Server

return NetTable
