local Players = game:GetService("Players")

local NetTable = require("@game/ReplicatedStorage/Core/NetTable")
local Replicator = require("@game/ReplicatedStorage/Core/Replicator")
local Pilot = require("@game/ReplicatedStorage/Client/Plane/Pilot")
local PlaneReplicator = require("@game/ReplicatedStorage/Client/Plane/PlaneReplicator")
local GuiRoot = require("@game/ReplicatedStorage/Client/Gui/Root")
local Test = require("@game/ReplicatedStorage/Core/Test")
local ClientTests = require("@game/ReplicatedStorage/Client/Tests")

-- Constants --
-- run the client test procedures in Client/Tests once startup finishes
local RUN_TESTS = true
--

local player = Players.LocalPlayer


-- seating tracking --
local session = nil

local function onSitDown(character, humanoid, seat)
	print("processing sit down")
	if seat:HasTag("pilotSeat") then
		-- start piloting
		local control = Pilot.newControl(character, humanoid, seat, {})
		control:activate()

		session = {
			humanoid = humanoid,
			seat = seat,
			mode = "pilot",
			control = control
		}
	end
end

--[[
	End whatever the player was doing in a vehicle. Getting up, dying, and the character being
	removed all arrive here, sometimes more than one of them for the same event and in no
	particular order, so both this and the control object's destroy tolerate being called twice.
]]
local function endSession()
	if not session then
		return
	end

	local control = session.control
	session = nil
	if control then
		control:destroy()
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

	NetTable.init()
	Replicator.init()
	PlaneReplicator.init()
	Pilot.init()


	GuiRoot.start()
	-- before Replicator, so tagged objects created by its start can read replicated tables
	NetTable.start()
	Replicator.start()
	--

	-- handle player character events --
	local characterConns = {}

	local function onCharacterAdded(character)
		-- the previous character's signals are dead, but the connections are not
		for _, conn in characterConns do
			conn:Disconnect()
		end
		table.clear(characterConns)

		local humanoid = character:WaitForChild("Humanoid")

		table.insert(characterConns, humanoid.Seated:Connect(function(active, seat)
			if active then
				onSitDown(character, humanoid, seat)
			else
				endSession()
			end
		end))

		-- a humanoid killed while seated is exactly what a crash produces, and Seated is not a
		-- dependable way to hear about it
		table.insert(characterConns, humanoid.Died:Connect(endSession))
	end

	local function onCharacterRemoving(character)
		endSession()
	end

	if player.Character then
		onCharacterAdded(player.Character)
	end

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(onCharacterRemoving)
	--

	if RUN_TESTS then
		Test.run("Client", ClientTests)
	end
end
--

startup()
