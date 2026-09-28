--[[
	NetTable — named, flat Luau tables replicated between the server and every client.

	A NetTable is a one-level table: keys are strings or numbers, values are scalars.
	Dictionaries and arrays both work; nested tables do not and assert. The server owns
	every table. Clients receive mirrors, and may write only to tables the server has
	marked `clientWritable`.

	Server:
		local settings = NetTable.new("settings")
		settings.clientWritable = true
		settings:activate()
		settings:set("maxCargo", 12)

	Client:
		local settings = NetTable.find("settings")
		settings:get("maxCargo")
		settings:onChanged(function(key, value) ... end)

	Because a table arrives some time after the client starts, client code that needs one
	at startup uses NetTable.onAdded rather than NetTable.find.

	A client's writes do not touch its own copy. They are sent to the server, and the
	change arrives back through the normal sync. There is therefore one authority for the
	contents and no way for a rejected write to leave a client disagreeing with the
	server. The cost is a round trip before the client sees its own write.

	`clientWritable` lives on the server's copy only; it is never replicated, and the
	field on a client's mirror is always false.

	Array operations
	----------------
	append / insert / removeAt treat the table as an array and send the operation itself,
	not its consequences. Removing index 3 of a 200-entry array is one small packet rather
	than 198 index writes.

	Locally the operation is still expanded into a changed event per shifted index, so a
	listener keyed on index stays correct and nothing is silently missed. The compaction is
	a wire optimization, not a change in local semantics.

	Remotes (declared in default.project.json under Remotes/NetTable):
		Sync     server -> client   (id: string, change: Change?)
		                            a nil change means the table was destroyed
		Push     client -> server   (id: string, change: Change)
		Request  client -> server   ()  asks for a snapshot of every table

	Every change travels as one Change on one remote, so writes and array operations keep
	their order relative to each other. A Change is one of:
		{ kind = "write",    set = {[any]: any}?, removed = {any}? }
		{ kind = "insert",   index = number, value = any }
		{ kind = "removeAt", index = number }
		{ kind = "append",   value = any }

	"append" is client -> server only: the server resolves it against its own array length
	and replicates the result as an "insert", so a client whose mirror is short still
	appends to the real end.
]]

local NetTable = {}
NetTable.__index = NetTable

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

local remotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("NetTable")
local syncRemote = remotes:WaitForChild("Sync")
local pushRemote = remotes:WaitForChild("Push")
local requestRemote = remotes:WaitForChild("Request")

--{scope -> {[id] -> table}}
local tables = {}

local addedListeners = {}
local removedListeners = {}

local started = false

-- shared --

local function isValidKey(key): boolean
	local keyType = typeof(key)
	return keyType == "string" or keyType == "number"
end

local function isValidValue(value): boolean
	return value ~= nil and typeof(value) ~= "table"
end

local function isValidIndex(index): boolean
	return typeof(index) == "number" and index == math.floor(index) and index >= 1
end

local function construct(scope: string, id: any)
	local self = setmetatable({}, NetTable)
	self.id = id
	self.data = {}
	-- server only. Clients never read this, and it is not replicated.
	self.clientWritable = false
	self.changedListeners = {}
	return self
end

--[[
	Call every listener in a set with the table. Cloned so a listener that disconnects
	itself does not mutate the array being iterated.
]]
local function announce(listeners, netTable)
	for _, listener in table.clone(listeners) do
		listener(netTable)
	end
end

--[[
	Write a change into a table's own data and tell its listeners. Used by the server when
	it makes a change and by the client when one arrives. Keys whose value is unchanged
	are skipped, so a duplicate sync fires nothing.

	An insert or removeAt reports a changed event for every index it shifted, since those
	indices really do hold different values afterwards.
]]
local function applyChange(self, change)
	-- cloned so a listener that disconnects itself does not mutate the array being iterated
	local listeners = table.clone(self.changedListeners)

	local function fire(key, value)
		for _, listener in listeners do
			listener(key, value)
		end
	end

	if change.kind == "write" then
		if change.set then
			for key, value in change.set do
				if self.data[key] ~= value then
					self.data[key] = value
					fire(key, value)
				end
			end
		end

		if change.removed then
			for _, key in change.removed do
				if self.data[key] ~= nil then
					self.data[key] = nil
					fire(key, nil)
				end
			end
		end
	elseif change.kind == "insert" then
		table.insert(self.data, change.index, change.value)

		for index = change.index, #self.data do
			fire(index, self.data[index])
		end
	elseif change.kind == "removeAt" then
		local previousLength = #self.data
		table.remove(self.data, change.index)

		for index = change.index, #self.data do
			fire(index, self.data[index])
		end
		-- the array is one shorter, so the old last index now holds nothing
		fire(previousLength, nil)
	else
		error(`Unknown NetTable change kind "{tostring(change.kind)}".`)
	end
end

--[[
	Apply a change locally and replicate it, or send it to the server to do so. The single
	place that decides which side a write happens on.
]]
local function submit(self, change)
	if IS_SERVER then
		applyChange(self, change)
		syncRemote:FireAllClients(self.id, change)
	else
		pushRemote:FireServer(self.id, change)
	end
end

-- class --

--[[
	Create a table under a unique id. Server only: clients get their copies through
	replication. Call activate() to publish it.
]]
function NetTable.new(scope: string, id: string)
	assert(IS_SERVER, "NetTable.new is server only; clients receive tables through replication.")

	return construct(scope, id)
end

--[[
	Publish the table: register it for lookup and replicate it to every client.
]]
function NetTable:activate()
	local scopeTable = tables[self.scope]
	if scopeTable and scopeTable[self.id] then
		error(`[NetTable:activate] NetTable {self.scope}/{self.id} already activated.`)
	end
	
	-- lazy build scope container
	if not scopeTable then
		scopeTable = {}
		tables[self.scope] = scopeTable
	end

	scopeTable[self.id] = self
	syncRemote:FireAllClients(self.scope, self.id, { kind = "write", set = self.data })

	announce(addedListeners, self)
end

--[[
	Unpublish the table and drop it from every client.
]]
function NetTable:destroy()
	local scopeTable = tables[self.scope]
	if scopeTable then
		scopeTable[self.id] = nil
	end

	table.clear(self.changedListeners)

	if IS_SERVER then
		syncRemote:FireAllClients(self.scope, self.id, nil)
	end

	announce(removedListeners, self)
end

function NetTable:get(key)
	return self.data[key]
end

--[[
	The array length of the table. Meaningless for a dictionary.
]]
function NetTable:length(): number
	return #self.data
end

--[[
	A copy of the whole table, safe to hold and mutate.
]]
function NetTable:snapshot()
	return table.clone(self.data)
end

--[[
	Set one key. Use remove() to clear one; nil is not a value.
]]
function NetTable:set(key, value)
	assert(isValidKey(key), `NetTable key must be a string or number, got {typeof(key)}.`)
	assert(value ~= nil, `Use NetTable:remove("{key}") to clear a key.`)
	assert(isValidValue(value), `NetTable values must be scalars, got {typeof(value)} for key "{key}".`)

	self:setMany({ [key] = value })
end

--[[
	Set several keys as one replicated change.
]]
function NetTable:setMany(values)
	for key, value in values do
		assert(isValidKey(key), `NetTable key must be a string or number, got {typeof(key)}.`)
		assert(isValidValue(value), `NetTable values must be scalars, got {typeof(value)} for key "{key}".`)
	end

	submit(self, { kind = "write", set = values })
end

--[[
	Clear one key. For arrays this leaves a hole; use removeAt to close it.
]]
function NetTable:remove(key)
	assert(isValidKey(key), `NetTable key must be a string or number, got {typeof(key)}.`)

	submit(self, { kind = "write", removed = { key } })
end

-- array operations --

--[[
	Add a value to the end of the array.
]]
function NetTable:append(value)
	assert(isValidValue(value), `NetTable values must be scalars, got {typeof(value)}.`)

	if IS_SERVER then
		submit(self, { kind = "insert", index = #self.data + 1, value = value })
	else
		-- the client does not pick the index. Its mirror may be shorter than the server's
		-- array, and an index resolved here would land in the wrong slot.
		submit(self, { kind = "append", value = value })
	end
end

--[[
	Insert a value at an index, shifting everything at and above it up. One network send
	regardless of how much it shifts.
]]
function NetTable:insert(index: number, value)
	assert(isValidIndex(index), `NetTable index must be a positive integer, got {tostring(index)}.`)
	assert(index <= #self.data + 1, `NetTable index {index} is past the end of an array of {#self.data}.`)
	assert(isValidValue(value), `NetTable values must be scalars, got {typeof(value)}.`)

	submit(self, { kind = "insert", index = index, value = value })
end

--[[
	Remove the value at an index, shifting everything above it down. One network send
	regardless of how much it shifts.
]]
function NetTable:removeAt(index: number)
	assert(isValidIndex(index), `NetTable index must be a positive integer, got {tostring(index)}.`)
	assert(index <= #self.data, `NetTable index {index} is past the end of an array of {#self.data}.`)

	submit(self, { kind = "removeAt", index = index })
end

--[[
	Call callback(key, value) whenever a key changes, with value nil when it is removed.
	Returns a function that disconnects the listener.
]]
function NetTable:onChanged(callback)
	table.insert(self.changedListeners, callback)

	return function()
		local index = table.find(self.changedListeners, callback)
		if index then
			table.remove(self.changedListeners, index)
		end
	end
end

-- system --

--[[
	The table under this name, or nil if it does not exist yet. On the client that
	includes tables that exist on the server but have not replicated yet, so startup code
	uses onAdded instead.
]]
function NetTable.find(name: string)
	return tables[name]
end

--[[
	Call callback(netTable) for every table, including ones that already exist. Returns a
	function that disconnects the listener.
]]
function NetTable.onAdded(callback)
	table.insert(addedListeners, callback)

	for _, netTable in table.clone(tables) do
		callback(netTable)
	end

	return function()
		local index = table.find(addedListeners, callback)
		if index then
			table.remove(addedListeners, index)
		end
	end
end

--[[
	Call callback(netTable) when a table is destroyed. Returns a function that
	disconnects the listener.
]]
function NetTable.onRemoved(callback)
	table.insert(removedListeners, callback)

	return function()
		local index = table.find(removedListeners, callback)
		if index then
			table.remove(removedListeners, index)
		end
	end
end

local function onSync(name, change)
	local netTable = tables[name]

	-- no change is the server saying the table is gone
	if change == nil then
		if netTable then
			netTable:destroy()
		end
		return
	end

	if netTable then
		applyChange(netTable, change)
		return
	end

	netTable = construct(name)
	tables[name] = netTable
	applyChange(netTable, change)

	announce(addedListeners, netTable)
end

--[[
	Whether a change from a client is well formed. Shape only; whether it may be applied to
	a particular table is checked separately.
]]
local function isValidChange(change): boolean
	if typeof(change) ~= "table" then
		return false
	end

	if change.kind == "write" then
		if change.set ~= nil then
			if typeof(change.set) ~= "table" then
				return false
			end
			for key, value in change.set do
				if not isValidKey(key) or not isValidValue(value) then
					return false
				end
			end
		end

		if change.removed ~= nil then
			if typeof(change.removed) ~= "table" then
				return false
			end
			for _, key in change.removed do
				if not isValidKey(key) then
					return false
				end
			end
		end

		return true
	elseif change.kind == "insert" then
		return isValidIndex(change.index) and isValidValue(change.value)
	elseif change.kind == "append" then
		return isValidValue(change.value)
	elseif change.kind == "removeAt" then
		return isValidIndex(change.index)
	end

	return false
end

local function onPush(player, name, change)
	-- validate
	if typeof(name) ~= "string" or not isValidChange(change) then
		return
	end

	-- resolve
	local netTable = tables[name]
	if not netTable then
		return
	end

	-- authorize
	if not netTable.clientWritable then
		return
	end

	-- an index past the end would shift the array somewhere the client did not intend, so
	-- it is rejected rather than clamped
	if change.kind == "insert" and change.index > #netTable.data + 1 then
		return
	end
	if change.kind == "removeAt" and change.index > #netTable.data then
		return
	end

	-- append is resolved against the server's array, never the client's mirror, and is
	-- replicated as an ordinary insert
	if change.kind == "append" then
		change = { kind = "insert", index = #netTable.data + 1, value = change.value }
	end

	-- act
	applyChange(netTable, change)
	syncRemote:FireAllClients(name, change)
end

function NetTable.init()
end

function NetTable.start()
	assert(not started, "NetTable has already started.")
	started = true

	if IS_SERVER then
		pushRemote.OnServerEvent:Connect(onPush)

		requestRemote.OnServerEvent:Connect(function(player)
			for name, netTable in tables do
				syncRemote:FireClient(player, name, { kind = "write", set = netTable.data })
			end
		end)
	else
		syncRemote.OnClientEvent:Connect(onSync)
		-- tables that already exist were replicated before this client could listen
		requestRemote:FireServer()
	end
end

return NetTable
