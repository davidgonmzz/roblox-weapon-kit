--!nonstrict
-- DEMO ONLY - delete this file (and its line in Main.server.luau) for production.
--
-- The exploit lab (client/CheatPanel.luau) changes things on the client on purpose: its own
-- WalkSpeed, JumpPower, health. To show that none of it reaches the server, the panel asks this
-- RemoteFunction "what do YOU see for my character?" and prints the answer next to what the
-- client set. It is read-only (it changes nothing), only answers about the caller's own
-- character, and is rate limited. It does not exist at all while Config.DEMO_CHEAT_PANEL is off.
--
--   Remotes.LabQuery:InvokeServer() -> nil, or
--     { health, maxHealth, walkSpeed, useJumpPower, jumpPower, jumpHeight, position: Vector3 }

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("WeaponKitShared")
local Config = require(Shared:WaitForChild("Config"))
local RateLimit = require(script.Parent.RateLimit)
local Remotes = require(script.Parent.Remotes)

local LabQuery = {}

-- The panel asks a few times per test at most.
local queryLimit = RateLimit.new(4, 8)

-- The answer for one player: the server's view of their character, or nil without one.
function LabQuery.snapshot(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		return nil
	end
	return {
		health = humanoid.Health,
		maxHealth = humanoid.MaxHealth,
		walkSpeed = humanoid.WalkSpeed,
		useJumpPower = humanoid.UseJumpPower,
		jumpPower = humanoid.JumpPower,
		jumpHeight = humanoid.JumpHeight,
		position = root.Position,
	}
end

function LabQuery.init()
	if not Config.DEMO_CHEAT_PANEL then
		return
	end
	local query = Remotes.func("LabQuery")
	-- Whatever the caller passes is ignored: there is nothing to parse, so nothing to break.
	query.OnServerInvoke = function(player)
		if not queryLimit:allow(player) then
			return nil
		end
		return LabQuery.snapshot(player)
	end
	print("[WeaponKit] LabQuery ready (demo)")
end

return LabQuery
