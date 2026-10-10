--!nonstrict
-- Server entry point. The order matters: PlayerData first (everything else reads a player's
-- saved ammo through it), the map before anyone can spawn, the weapon remotes before the Tools
-- that use them. Suspicion (the shared flag counter) loads with the first module that needs it.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local server = script.Parent
local starterScripts = StarterPlayer:WaitForChild("StarterPlayerScripts")

-- One-file install: WeaponKit.rbxm is ONE folder holding the three kit folders, dropped where a
-- Script runs (Studio puts it in the Workspace). Every server start moves them where they belong,
-- before any player has joined (a running Script may move its own folder: it keeps running). The
-- moves are not saved, so the place keeps the folder where it was dropped, and that is where
-- Config is edited. Rojo and hand-placed installs already have the folders in place.
local bundle = server.Parent
local bundledShared = bundle:FindFirstChild("WeaponKitShared")
local bundledClient = bundle:FindFirstChild("WeaponKitClient")
if bundle ~= ServerScriptService and bundledShared and bundledClient then
	if ReplicatedStorage:FindFirstChild("WeaponKitShared") then
		warn("[WeaponKit] NOT STARTED: a second copy of the kit is installed, delete " .. bundle:GetFullName())
		return
	end
	bundledShared.Parent = ReplicatedStorage
	bundledClient.Parent = starterScripts -- every player who joins from now on gets it
	for _, player in Players:GetPlayers() do -- (anyone already in, a Studio test for one, gets a copy directly)
		local holder = Instance.new("ScreenGui")
		holder.Name = "WeaponKitClientHolder"
		holder.ResetOnSpawn = false
		bundledClient:Clone().Parent = holder
		holder.Parent = player:FindFirstChildOfClass("PlayerGui")
	end
	server.Parent = ServerScriptService -- (out of the replicated Workspace before anyone joins)
end

-- Install check, before anything else: the kit is three folders and each must sit in its own
-- service. A misplaced folder stops the kit with one clear message instead of a hang deep inside
-- (a Script still runs from the Workspace).
local function placed(name: string, service: Instance, nested: boolean): boolean
	if service:FindFirstChild(name, nested) then
		return true -- (the client folder may sit in a subfolder; the shared one is looked up by name)
	end
	local found = game:FindFirstChild(name, true)
	warn(
		string.format(
			"[WeaponKit] NOT STARTED: move the folder %s into %s (it is %s).",
			name,
			service.Name,
			if found then "at " .. found:GetFullName() else "missing"
		)
	)
	return false
end
local here = server:IsDescendantOf(ServerScriptService)
if not here then
	warn(
		string.format(
			"[WeaponKit] NOT STARTED: move the folder %s into ServerScriptService (it is at %s).",
			server.Name,
			server:GetFullName()
		)
	)
end
local ok = placed("WeaponKitShared", ReplicatedStorage, false)
ok = placed("WeaponKitClient", starterScripts, true) and ok
if not (here and ok) then
	return
end
-- Two copies would both answer every shot (double damage): only the first one runs.
if ServerScriptService:GetAttribute("WeaponKitRunning") then
	warn("[WeaponKit] NOT STARTED: a second copy of the kit is installed, delete " .. server:GetFullName())
	return
end
ServerScriptService:SetAttribute("WeaponKitRunning", true)

print("[WeaponKit] server started")

local Config = require(ReplicatedStorage.WeaponKitShared.Config)
local PlayerData = require(server.PlayerData)
local WeaponServer = require(server.WeaponServer)
local Tools = require(server.Tools)
local Movement = require(server.Movement)

PlayerData.init() -- first: the other modules read a player's data through it
local Range, Dummies
if Config.DEMO_RANGE then
	Range = require(server.Range)
	Dummies = require(server.Dummies)
	Range.build() -- the map, the spawn and the ammo crate (before anyone spawns)
end
WeaponServer.init() -- the Fire / Reload remotes; refuses shots until a player's data is loaded
Tools.init() -- builds the weapon Tools and gives them on every spawn
if Range then
	Dummies.init(Range.TARGETS)
	if #Range.LAB_TARGETS > 0 then
		Dummies.init(Range.LAB_TARGETS) -- the exploit lab's wallbang dummy
	end
end
Movement.init() -- server movement checks: speed, teleport, fly, jump, noclip, fling
-- Demo only: lets the exploit lab ask what the server sees (FindFirstChild: the demo-only modules
-- LabQuery, Range and Dummies may be deleted from a game's copy).
local labQuery = server:FindFirstChild("LabQuery")
if labQuery then
	require(labQuery).init()
end

print("[WeaponKit] ready" .. if Config.DEMO_RANGE then " (demo)" else "")
