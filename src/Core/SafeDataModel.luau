local SafeDataModel = {}

function SafeDataModel.getChild(instance, name: string, className: string)
	local child = assert(instance:FindFirstChild(name), `{instance:GetFullName()} does not have child \"{name}\"`)
	assert(child:IsA(className))
	return child
end

return SafeDataModel