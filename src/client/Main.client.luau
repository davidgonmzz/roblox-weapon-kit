--!nonstrict
-- Client entry point: starts the weapon client (input, HUD, effects) and, in the demo build
-- only, the exploit simulator.
print("[WeaponKit] client started")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local WeaponClient = require(script.Parent.WeaponClient)

WeaponClient.start()

-- Demo only. FindFirstChild so deleting CheatPanel.luau for production is enough.
local cheatPanel = script.Parent:FindFirstChild("CheatPanel")
if Config.DEMO_CHEAT_PANEL and cheatPanel then
	require(cheatPanel).start()
end
