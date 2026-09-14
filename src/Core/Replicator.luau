local Replicator = {}

local CollectionService = game:GetService("CollectionService")

local ObjectData = require("./ObjectData")

--[[
    added is called for every object with the tag. If objectDataKey is set, whatever added returns is
    related to the object in ObjectData under that key, and unrelated after removed is called.
]]
export type Reciever = {
    added: (any) -> any,
    removed: (any) -> (),
    objectDataKey: string?,
}

local tagRecieverTable = {}

local started = false

local function onAdded(reciever: Reciever, object)
    local data = reciever.added(object)
    if reciever.objectDataKey then
        ObjectData.add(object)
        ObjectData.relate(object, reciever.objectDataKey, data)
    end
end

local function onRemoved(reciever: Reciever, object)
    reciever.removed(object)
    if reciever.objectDataKey and ObjectData.get(object) then
        ObjectData.unrelate(object, reciever.objectDataKey)
        -- drop the object entirely once nothing else is related to it
        if next(ObjectData.get(object)) == nil then
            ObjectData.clear(object)
        end
    end
end

--[[
    Register a reciever to be called for objects with the given tag. Must be called before start().
]]
function Replicator.subscribeToTag(tag: string, reciever: Reciever)
    assert(not started, `Cannot subscribe to tag {tag} after Replicator has started.`)

    local recievers = tagRecieverTable[tag]
    if not recievers then
        recievers = {}
        tagRecieverTable[tag] = recievers
    end
    table.insert(recievers, reciever)
end

function Replicator.init()
end

function Replicator.start()
    -- assume that user code has suscribed as required in init()
    assert(not started, "Replicator has already started.")
    started = true

    for tag, recievers in tagRecieverTable do
        CollectionService:GetInstanceAddedSignal(tag):Connect(function(object)
            for _, reciever in recievers do
                onAdded(reciever, object)
            end
        end)

        CollectionService:GetInstanceRemovedSignal(tag):Connect(function(object)
            for _, reciever in recievers do
                onRemoved(reciever, object)
            end
        end)

        -- catch up on objects that were tagged before start
        for _, object in CollectionService:GetTagged(tag) do
            for _, reciever in recievers do
                onAdded(reciever, object)
            end
        end
    end
end

return Replicator
