--!nonstrict
-- Client side of the weapons: input and instant feedback. The server (server/WeaponServer.luau)
-- validates every shot, rolls its own spread, raycasts and applies damage; this file only
--   * reads input   (hold LMB for full-auto, click for semi/pump, R reload, 1/2/3 switch)
--   * says what it did to the server ("fired from here, this way", with a rising shot id)
--   * draws feedback at once: tracers, muzzle flash, recoil, crosshair bloom
--   * shows the server's answers: ammo (AmmoSync), hit markers (HitConfirm), other players' shots (FireFX)
-- Its fire-rate gate mirrors the server's so a normal player never trips it, but the server
-- decides. The ammo numbers are predicted locally and corrected by every AmmoSync.
--
-- Public functions (used by CheatPanel to build deliberately bad requests):
--   WeaponClient.getAim()       -> muzzle position, aim direction of the weapon in hand (or nil)
--   WeaponClient.nextShotId()   -> the next shot id (they must keep rising)
--   WeaponClient.heldWeapon()   -> name of the weapon in hand, or nil

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local Config = require(Shared:WaitForChild("Config"))
local Weapons = require(Shared:WaitForChild("Weapons"))
local Effects = require(script.Parent.Effects)
local Hud = require(script.Parent.Hud)

local WeaponClient = {}

local RELOAD_KEY = Enum.KeyCode.R
local SLOT_KEYS = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
	Enum.KeyCode.Six,
	Enum.KeyCode.Seven,
	Enum.KeyCode.Eight,
	Enum.KeyCode.Nine,
}
local RELOAD_RETRY = 0.4 -- seconds between two reload requests
local INFLIGHT_TTL = 2 -- seconds after which an unanswered shot stops counting against the ammo label
local HIT_COLOR = Color3.fromRGB(255, 96, 84)
local MISS_COLOR = Color3.fromRGB(255, 235, 160)

local player = Players.LocalPlayer
local rng = Random.new()

local fireRemote, reloadRemote

-- Per weapon: what we believe the server holds. mag is predicted, reserve only changes by AmmoSync.
local states = {} -- [weapon] = { mag, reserve (nil = not known yet), reloading, reloadStart }
for name, def in Weapons.Defs do
	states[name] = { mag = def.magazine, reserve = nil, reloading = false, reloadStart = 0 }
end

local inflight = {} -- shots sent but not yet counted by the server: { id, weapon, t }, oldest first
local sentId = 0 -- shot counter sent with every Fire (the server only accepts a higher one)
local lastShot, lastInterval = -math.huge, 0 -- one fire timer for all weapons, like the server
local lastReloadAsk = -math.huge
local holding = false -- primary button held down

local held, heldName, heldDef -- the Tool in hand, its name, its Weapons.luau entry
local muzzleAttachment -- the "Muzzle" Attachment on the barrel
local heldConnections = {}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

-- Characters the aim ray must not hit: our own, and (PVP off) everybody's, like the server.
local function ignoreList()
	local list = {}
	for _, p in Players:GetPlayers() do
		if p.Character and (not Config.PVP or p == player) then
			table.insert(list, p.Character)
		end
	end
	return list
end

-- True if `inst` is part of something with a Humanoid (a dummy or a player): the impact spark
-- turns red on those.
local function isCharacterPart(inst: Instance?): boolean
	while inst and inst ~= Workspace do
		if inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid") then
			return true
		end
		inst = inst.Parent
	end
	return false
end

local function muzzlePosition(): Vector3?
	if not held then
		return nil
	end
	if not muzzleAttachment then
		muzzleAttachment = held:FindFirstChild("Muzzle", true)
	end
	if muzzleAttachment then
		return muzzleAttachment.WorldPosition
	end
	local handle = held:FindFirstChild("Handle")
	return handle and handle.Position
end

-- Where the camera's crosshair points, then aim from the muzzle at that spot so the shot lands
-- under the crosshair even though the gun is off to the side.
local function aimFrom(muzzle: Vector3, range: number): Vector3
	local camera = Workspace.CurrentCamera
	local at = Hud.aimPoint()
	local ray = camera:ViewportPointToRay(at.X, at.Y)
	local cameraDirection = ray.Direction.Unit
	rayParams.FilterDescendantsInstances = ignoreList()
	local hit = Workspace:Raycast(ray.Origin, cameraDirection * range, rayParams)
	local target = if hit then hit.Position else ray.Origin + cameraDirection * range
	local toTarget = target - muzzle
	-- Too close, or behind the muzzle (a wall between camera and character): use the camera's line.
	if toTarget.Magnitude < 0.5 or toTarget:Dot(cameraDirection) <= 0 then
		return cameraDirection
	end
	return toTarget.Unit
end

local function refreshHud()
	if heldName then
		local st = states[heldName]
		Hud.setAmmo(st.mag, st.reserve)
		Hud.setReload(if st.reloading then st.reloadStart else nil)
	end
end

local function requestReload()
	local st = heldName and states[heldName]
	if not st or st.reloading or st.mag >= heldDef.magazine or (st.reserve ~= nil and st.reserve <= 0) then
		return
	end
	if os.clock() - lastReloadAsk < RELOAD_RETRY then
		return
	end
	lastReloadAsk = os.clock()
	reloadRemote:FireServer() -- the server confirms with an AmmoSync (reloading = true)
end

local function fire()
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not held or not humanoid or humanoid.Health <= 0 then
		return
	end
	local st = states[heldName]
	local now = os.clock()
	local def = heldDef
	local interval = 60 / def.rpm
	if st.reloading or now - lastShot < math.max(lastInterval, interval) then
		return
	end
	if st.mag <= 0 then
		requestReload()
		return
	end
	local muzzle = muzzlePosition()
	if not muzzle then
		return
	end

	lastShot = now
	lastInterval = interval
	local direction = aimFrom(muzzle, def.range)
	sentId += 1
	st.mag -= 1
	table.insert(inflight, { id = sentId, weapon = heldName, t = now })
	if #inflight > 64 then
		table.remove(inflight, 1)
	end
	fireRemote:FireServer(muzzle, direction, sentId)

	-- Instant feedback. The server rolls its own spread, so the real pellets differ a little.
	for _ = 1, def.pellets do
		local pellet = Ballistics.spread(direction, def.spread, rng)
		local hit = Workspace:Raycast(muzzle, pellet * def.range, rayParams)
		local endPoint = if hit then hit.Position else muzzle + pellet * def.range
		Effects.tracer(muzzle, endPoint, def.color)
		if hit then
			Effects.impact(endPoint, if isCharacterPart(hit.Instance) then HIT_COLOR else MISS_COLOR)
		end
	end
	Effects.muzzleFlash(muzzle, def.color)
	Effects.kick(def.recoil)
	Hud.bloom()
	refreshHud()
	if st.mag <= 0 then
		requestReload() -- empty: ask for the reload right away
	end
end

local function clearHeld()
	for _, connection in heldConnections do
		connection:Disconnect()
	end
	table.clear(heldConnections)
	held, heldName, heldDef, muzzleAttachment = nil, nil, nil, nil
	holding = false
	Hud.setWeapon(nil)
	Hud.selectSlot(nil)
	Hud.setReload(nil)
end

local function onEquipped(tool: Tool)
	clearHeld()
	held, heldName, heldDef = tool, tool.Name, Weapons.Defs[tool.Name]
	muzzleAttachment = tool:FindFirstChild("Muzzle", true)
	table.insert(
		heldConnections,
		tool.Activated:Connect(function()
			holding = true
			fire() -- semi-auto and pump weapons: exactly one shot per click
		end)
	)
	table.insert(
		heldConnections,
		tool.Deactivated:Connect(function()
			holding = false
		end)
	)
	Hud.setWeapon(heldDef)
	Hud.selectSlot(heldName)
	refreshHud()
end

-- 1 / 2 / 3: take that weapon out, or put it away if it is already in hand.
local function toggleWeapon(name: string)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	if heldName == name then
		humanoid:UnequipTools()
		return
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	local tool = backpack and backpack:FindFirstChild(name)
	if tool and tool:IsA("Tool") then
		humanoid:EquipTool(tool) -- the server sees the equip and remembers it as the loadout
	end
end

local function watchCharacter(character: Model)
	clearHeld() -- new life: forget the old tool (its ChildRemoved may never fire)
	table.clear(inflight)
	local function consider(child: Instance)
		if child:IsA("Tool") and Weapons.Defs[child.Name] then
			onEquipped(child)
		end
	end
	character.ChildAdded:Connect(consider)
	character.ChildRemoved:Connect(function(child)
		if child == held then
			clearHeld()
		end
	end)
	for _, child in character:GetChildren() do
		consider(child)
	end
end

function WeaponClient.getAim(): (Vector3?, Vector3?)
	if not heldDef then
		return nil, nil
	end
	local muzzle = muzzlePosition()
	if not muzzle then
		return nil, nil
	end
	return muzzle, aimFrom(muzzle, heldDef.range)
end

function WeaponClient.nextShotId(): number
	sentId += 1
	return sentId
end

function WeaponClient.heldWeapon(): string?
	return heldName
end

function WeaponClient.start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	fireRemote = remotes:WaitForChild("Fire")
	reloadRemote = remotes:WaitForChild("Reload")
	local ammoRemote = remotes:WaitForChild("AmmoSync")
	local fxRemote = remotes:WaitForChild("FireFX")
	local hitRemote = remotes:WaitForChild("HitConfirm")

	Effects.start()
	Hud.start()

	-- Our own weapon bar replaces Roblox's hotbar (which would also react to the number keys).
	task.spawn(function()
		for _ = 1, 20 do
			if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, false) then
				return
			end
			task.wait(0.5)
		end
	end)

	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		watchCharacter(player.Character)
	end

	-- Hold-to-fire: the Activated event gives the first shot, this loop the rest.
	RunService.Heartbeat:Connect(function()
		if holding and heldDef and heldDef.mode == "auto" then
			fire()
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == RELOAD_KEY or input.KeyCode == Enum.KeyCode.ButtonX then
			requestReload()
			return
		end
		for index, key in SLOT_KEYS do
			if input.KeyCode == key then
				local name = Weapons.Order[index]
				if name then
					toggleWeapon(name)
				end
				return
			end
		end
	end)

	-- The server's word on ammo. Shots still travelling to it (sent but not yet counted) are
	-- subtracted, so the label doesn't jump back up between your clicks.
	ammoRemote.OnClientEvent:Connect(function(name, mag, reserve, isReloading, lastId)
		local st = if type(name) == "string" then states[name] else nil
		if not st or type(mag) ~= "number" or type(lastId) ~= "number" then
			return
		end
		local now = os.clock()
		while inflight[1] and (inflight[1].id <= lastId or now - inflight[1].t > INFLIGHT_TTL) do
			table.remove(inflight, 1)
		end
		local pending = 0
		for _, shot in inflight do
			if shot.weapon == name then
				pending += 1
			end
		end
		st.mag = math.max(0, mag - pending)
		st.reserve = reserve
		if isReloading and not st.reloading then
			st.reloadStart = now
		end
		st.reloading = isReloading == true
		if name == heldName then
			refreshHud()
			if st.mag <= 0 and not st.reloading then
				requestReload() -- magazine empty: the hint to reload
			end
		end
	end)

	-- The server confirmed that one of OUR shots hurt someone.
	hitRemote.OnClientEvent:Connect(function(damage, headshot, killed)
		if type(damage) == "number" then
			Hud.hitMarker(damage, headshot == true, killed == true)
		end
	end)

	-- Someone else's shot (never your own: the server doesn't echo it back).
	fxRemote.OnClientEvent:Connect(function(weaponName, origin, ends, hits)
		local def = if type(weaponName) == "string" then Weapons.Defs[weaponName] else nil
		if not def or typeof(origin) ~= "Vector3" or type(ends) ~= "table" or type(hits) ~= "table" then
			return
		end
		Effects.muzzleFlash(origin, def.color)
		for i = 1, math.min(#ends, 16) do
			local endPoint = ends[i]
			if typeof(endPoint) == "Vector3" then
				Effects.tracer(origin, endPoint, def.color)
				if (endPoint - origin).Magnitude < def.range - 0.5 then -- ended on something, not at max range
					Effects.impact(endPoint, if hits[i] then HIT_COLOR else MISS_COLOR)
				end
			end
		end
	end)
end

return WeaponClient
