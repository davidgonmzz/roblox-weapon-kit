--!nonstrict
-- Player save data. One ProfileStore profile per player holds everything that is saved
-- (magazine and spare ammo per weapon, last equipped weapon, lifetime stats); WeaponServer reads and writes
-- these tables directly, so every change is saved (autosave, on leave, on shutdown).
-- ProfileStore (third_party/ProfileStore, Apache-2.0) locks a profile to ONE server at a time,
-- so joining two servers can't duplicate ammo.
--
--   PlayerData.get(player)            -> the data table, or nil while it is still loading:
--                                        every action must refuse when this is nil
--   PlayerData.waitFor(player, t?)    -> yields until loaded; nil if the player left or t seconds passed
--   PlayerData.onLoaded(fn)           -> fn(player) runs once a player's data is ready
--                                        (also called right away for players already loaded)
--
-- Unpublished place in Studio: ProfileStore switches to a mock store by itself. Everything
-- works, but nothing is kept after the session (init() prints a line when that is the case).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Weapons = require(Shared:WaitForChild("Weapons"))
local ProfileStore = require(script.Parent.Vendor.ProfileStore)

local PlayerData = {}

local CURRENT_SCHEMA = 1
local DEFAULT_LOADOUT = "Pistol"
local MAX_COUNT = 2 ^ 40 -- sanity bound for saved counters (saved numbers are plain doubles)
local KICK_MESSAGE = "Data failed to load, please rejoin"

-- Starting ammo comes from Weapons.luau, so a weapon added later gets its ammo in old saves
-- too (ProfileStore's :Reconcile() copies missing keys in).
local function startingAmmo(field: string)
	local ammo = {}
	for name, def in Weapons.Defs do
		ammo[name] = def[field]
	end
	return ammo
end

-- The shape of a brand-new profile.
-- mags     = { [weaponName] = rounds in the magazine }, 0..magazine. Saved too, so leaving and
--            rejoining can't refill the guns for free.
-- reserve  = { [weaponName] = spare rounds }, 0..reserveMax
-- loadout  = the weapon equipped last (given back on the next spawn)
-- stats    = lifetime counters shown on the HUD
local TEMPLATE = {
	schema = CURRENT_SCHEMA,
	mags = startingAmmo("magazine"),
	reserve = startingAmmo("startReserve"),
	loadout = DEFAULT_LOADOUT,
	stats = { kills = 0, shots = 0, hits = 0 },
}

local store = ProfileStore.New(Config.DATASTORE_NAME, TEMPLATE)

local profiles = {} -- [Player] = Profile, only while its session is active
local loading = {} -- [Player] = true while the profile is being fetched
local loadedCallbacks = {} -- fn(player), see onLoaded

-- A non-negative whole number (rounded down), or `fallback` if it isn't a usable number.
local function count(value: any, fallback: number): number
	if type(value) == "number" and value >= 0 and value < MAX_COUNT then
		return math.floor(value)
	end
	return fallback
end

-- parent[key] as a table (replaced by an empty one if it is missing or something else).
local function section(parent, key: string)
	if type(parent[key]) ~= "table" then
		parent[key] = {}
	end
	return parent[key]
end

-- Makes loaded data safe to use: corrupt or outdated entries are fixed or dropped, so the rest
-- of the code can index data.reserve[weapon] without checking it.
local function sanitize(data)
	-- Ammo, magazine and reserve alike: unknown weapon (removed in an update) -> dropped;
	-- missing or broken -> the starting amount; anything above the weapon's cap -> clamped.
	local mags, reserve = section(data, "mags"), section(data, "reserve")
	for _, tbl in { mags, reserve } do
		for name in tbl do
			if type(name) ~= "string" or not Weapons.Defs[name] then
				tbl[name] = nil
			end
		end
	end
	for name, def in Weapons.Defs do
		mags[name] = math.clamp(count(mags[name], def.magazine), 0, def.magazine)
		reserve[name] = math.clamp(count(reserve[name], def.startReserve), 0, def.reserveMax)
	end

	if type(data.loadout) ~= "string" or not Weapons.Defs[data.loadout] then
		data.loadout = DEFAULT_LOADOUT
	end

	local stats = section(data, "stats")
	stats.kills = count(stats.kills, 0)
	stats.shots = count(stats.shots, 0)
	stats.hits = count(stats.hits, 0)
end

-- Upgrades older saves one version at a time. When the data shape changes: bump CURRENT_SCHEMA,
-- update TEMPLATE, and add a step here, e.g.
--   if version < 2 then
--       (change the shape of `data`)
--       version = 2
--   end
local function migrate(data)
	local version = if type(data.schema) == "number" then data.schema else 0
	if version >= CURRENT_SCHEMA then
		return -- up to date (or saved by a newer build: leave it alone)
	end
	-- (no steps yet: schema 1 is the first version)
	data.schema = CURRENT_SCHEMA
end

local function loadPlayer(player: Player)
	if profiles[player] or loading[player] then
		return
	end
	loading[player] = true
	local profile = store:StartSessionAsync("Player_" .. player.UserId, {
		Cancel = function()
			return player.Parent ~= Players -- left while we were still trying
		end,
	})
	loading[player] = nil

	if profile == nil then
		if player.Parent == Players then
			player:Kick(KICK_MESSAGE)
		end
		return
	end
	if player.Parent ~= Players then
		profile:EndSession() -- left during the load
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()
	local ok, err = pcall(function()
		migrate(profile.Data)
		sanitize(profile.Data)
	end)
	if not ok then
		warn("[WeaponKit] PlayerData: could not prepare data for " .. player.Name .. ": " .. tostring(err))
		profile:EndSession()
		player:Kick(KICK_MESSAGE)
		return
	end

	profile.OnSessionEnd:Connect(function()
		-- Ended by someone else (the profile was taken over, or the server is closing); a normal
		-- leave clears profiles[player] first.
		if profiles[player] == profile then
			profiles[player] = nil
			if player.Parent == Players then
				player:Kick(KICK_MESSAGE)
			end
		end
	end)
	profiles[player] = profile
	for _, fn in loadedCallbacks do
		task.spawn(fn, player) -- own thread each: one failing listener can't block the others
	end
end

local function unloadPlayer(player: Player)
	local profile = profiles[player]
	profiles[player] = nil
	if profile then
		profile:EndSession()
	end
end

function PlayerData.get(player: Player)
	local profile = profiles[player]
	return profile and profile.Data
end

function PlayerData.waitFor(player: Player, timeout: number?)
	local deadline = if timeout then os.clock() + timeout else math.huge
	while profiles[player] == nil do
		if player.Parent ~= Players or os.clock() >= deadline then
			return nil
		end
		task.wait(0.1)
	end
	return profiles[player].Data
end

function PlayerData.onLoaded(fn: (Player) -> ())
	table.insert(loadedCallbacks, fn)
	for player in profiles do
		task.spawn(fn, player)
	end
end

function PlayerData.init()
	Players.PlayerAdded:Connect(loadPlayer)
	Players.PlayerRemoving:Connect(unloadPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end

	-- ProfileStore decides about the mock store asynchronously (it test-writes a key in Studio).
	task.spawn(function()
		while ProfileStore.DataStoreState == "NotReady" do
			task.wait()
		end
		if ProfileStore.DataStoreState ~= "Access" then
			print("[WeaponKit] PlayerData: mock store (unpublished place, nothing persists)")
		end
	end)
end

return PlayerData
