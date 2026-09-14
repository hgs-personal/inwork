local CoreUtil = {}

-- Roblox part manipulation --
CoreUtil.Parts = {}

function CoreUtil.Parts.weldPartsSimple(parts, to)
    for _, part in parts do
        if part:IsA("BasePart") and part ~= to then
            local w = Instance.new("Weld")
            w.Part0 = to
            w.Part1 = part
            w.C0 = to.CFrame:ToObjectSpace(part.CFrame)
            w.Parent = part
        end
    end
end

function CoreUtil.Parts.weldModelSimple(model: Model, to: BasePart)
    CoreUtil.Parts.weldPartsSimple(model:GetChildren(), to)
end

function CoreUtil.Parts.makePartsEffectOnly(parts: {Instance} | Model)
    if typeof(parts) == "Instance" and parts:IsA("Model") then
        parts = parts:GetDescendants()
    end

    for _, part in parts do
        part.CanCollide = false
        part.Massless = true
        -- handle can query, can touch seperately?
    end
end
--

return CoreUtil