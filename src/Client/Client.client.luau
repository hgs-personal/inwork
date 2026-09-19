local Players = game:GetService("Players")

local Replicator = require("@game/ReplicatedStorage/Core/Replicator")
local Pilot = require("@game/ReplicatedStorage/Client/Plane/Pilot")
local PlaneReplicator = require("@game/ReplicatedStorage/Client/Plane/PlaneReplicator")
local GuiRoot = require("@game/ReplicatedStorage/Client/Gui/Root")

local player = Players.LocalPlayer


-- seating tracking --
local session = nil

local function onSitDown(character, humanoid, seat)
	print("processing sit down")
	if seat:HasTag("pilotSeat") then
		-- start piloting
		local control = Pilot.newControl(character, humanoid, seat, {})
		control:start()

		session = {
			humanoid = humanoid,
			seat = seat,
			mode = "pilot",
			control = control
		}
	end
end

local function onGetup(character, humanoid, seat)
	print("processing get up")
	if session then
		local control = session.control
		if control then
			control:destroy()
		end
		session = nil
	end
end
--

-- Client startup entry point --

--[[
	Build up the GUI instance tree with Fusion. Every registered GUI module is built
	exactly once here at client init (see Client/Gui).
]]


local function startup()
	-- init client systems --
	GuiRoot.init()
	
	Replicator.init()
	PlaneReplicator.init()
	Pilot.init()
	

	GuiRoot.start()
	--

	-- handle player character events --
	local function onCharacterAdded(character)
		local humanoid = character:WaitForChild("Humanoid")

		humanoid.Seated:Connect(function(active, seat)
			if active then
				onSitDown(character, humanoid, seat)
			else
				onGetup(character, humanoid, seat)
			end
		end)

	end

	local function onCharacterRemoving(character)
		-- TODO: assuming if character is removed, unseating logic was already processed.
		-- This may not be the case ?...
	end

	if player.Character then
		onCharacterAdded(player.Character)
	end

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(onCharacterRemoving)
	--

	
end
--

startup()