--!nonstrict
-- Client entry point: starts the weapon client (input, HUD, effects) and, in the demo place
-- only, the exploit simulator.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Two installed copies would both fire every shot: only the first one runs (the server prints
-- which folder to delete).
local playerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
if playerScripts:GetAttribute("WeaponKitRunning") then
	return
end
playerScripts:SetAttribute("WeaponKitRunning", true)

print("[WeaponKit] client started")

local Config = require(ReplicatedStorage:WaitForChild("WeaponKitShared"):WaitForChild("Config"))
local WeaponClient = require(script.Parent.WeaponClient)

WeaponClient.start()

-- Demo only. FindFirstChild so deleting CheatPanel.luau is enough to drop it from a game.
local cheatPanel = script.Parent:FindFirstChild("CheatPanel")
if Config.DEMO_CHEAT_PANEL and cheatPanel then
	require(cheatPanel).start()
end
