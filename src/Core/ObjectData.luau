local ObjectData = {}

local objectDataTable = {}

--[[
    Add object into the relationship table for use with rest of the module.
]]
function ObjectData.add(object)
    if not objectDataTable[object] then
        objectDataTable[object] = {}
    end
    return objectDataTable[object]
end

--[[
    Remove the object and all of its relationships from the table.
]]
function ObjectData.clear(object)
    objectDataTable[object] = nil
end

function ObjectData.get(object)
    return objectDataTable[object]
end

--[[
    Add a relationship from the given object to (and not backwards) to the related data using a named key.
]]
function ObjectData.relate(object, key, data)
    local relationships = objectDataTable[object]
    assert(relationships, `Object {object} has not been added to ObjectData.`)
    relationships[key] = data
end

--[[
    Remove the relationship under the named key from the given object.
]]
function ObjectData.unrelate(object, key)
    local relationships = objectDataTable[object]
    assert(relationships, `Object {object} has not been added to ObjectData.`)
    relationships[key] = nil
end

--[[
    Get the data related to the object under the named key, or nil if there is none.
]]
function ObjectData.query(object, key)
    local relationships = objectDataTable[object]
    return relationships and relationships[key]
end

return ObjectData
