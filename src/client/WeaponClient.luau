--!nonstrict
-- Client side of the weapons: input and instant feedback. The server (server/WeaponServer.luau)
-- validates every shot, rolls its own spread, raycasts and applies damage; this file only
--   * reads input   (hold LMB for full-auto, click for semi/pump, R reload, 1/2/3 switch;
--                    gamepad R2 fire, X reload, L1/R1 switch; phone: tap fires, HUD buttons)
--   * says what it did to the server ("fired from here, this way", with a rising shot id)
--   * draws feedback at once: tracers, muzzle flash, recoil, crosshair bloom
--   * shows the server's answers: ammo (AmmoSync), hit markers (HitConfirm), other players' shots (FireFX)
-- Its fire-rate gate mirrors the server's so a normal player never trips it, but the server
-- decides. The ammo numbers are predicted locally and corrected by every AmmoSync.
--
-- Your own GUI or scripts talk to it through shared/ClientApi.luau (signals + equip/reload).
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

local Shared = ReplicatedStorage:WaitForChild("WeaponKitShared")
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local ClientApi = require(Shared:WaitForChild("ClientApi"))
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

local api -- ClientApi's BindableEvents (set in start)
local announcedWeapon -- the last name sent through WeaponChanged

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

-- Characters the aim ray must not hit: the server's own rule (shared/Ballistics).
local function ignoreList()
	return Ballistics.ignoredCharacters(Players:GetPlayers(), player, Config.PVP)
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

-- The Attachment named "Muzzle" (an own gun model may also have a Part called that).
local function findMuzzle(tool: Tool): Attachment?
	for _, item in tool:GetDescendants() do
		if item.Name == "Muzzle" and item:IsA("Attachment") then
			return item
		end
	end
	return nil
end

local function muzzlePosition(): Vector3?
	if not held then
		return nil
	end
	if not muzzleAttachment then
		muzzleAttachment = findMuzzle(held)
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

local function announceWeapon()
	if api and heldName ~= announcedWeapon then
		announcedWeapon = heldName
		api.WeaponChanged:Fire(heldName)
	end
end

local function announceAmmo(name: string)
	local st = states[name]
	if api and st then
		api.AmmoChanged:Fire(name, st.mag, st.reserve, st.reloading)
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
	if api then
		api.Fired:Fire(heldName)
	end
	announceAmmo(heldName)
	if st.mag <= 0 then
		requestReload() -- empty: ask for the reload right away
	end
end

-- quiet: a new tool is about to be announced (onEquipped), so don't report "nothing held" first.
local function clearHeld(quiet: boolean?)
	for _, connection in heldConnections do
		connection:Disconnect()
	end
	table.clear(heldConnections)
	held, heldName, heldDef, muzzleAttachment = nil, nil, nil, nil
	holding = false
	Hud.setWeapon(nil)
	Hud.selectSlot(nil)
	Hud.setReload(nil)
	if not quiet then
		announceWeapon()
	end
end

local function onEquipped(tool: Tool)
	clearHeld(true)
	held, heldName, heldDef = tool, tool.Name, Weapons.Defs[tool.Name]
	muzzleAttachment = findMuzzle(tool)
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
	announceWeapon()
end

local function aliveHumanoid(): Humanoid?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function equipWeapon(name: string)
	local humanoid = aliveHumanoid()
	if not humanoid or heldName == name then
		return
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	local tool = backpack and backpack:FindFirstChild(name)
	if tool and tool:IsA("Tool") then
		humanoid:EquipTool(tool) -- the server sees the equip and remembers it as the loadout
	end
end

local function unequipWeapon()
	local humanoid = aliveHumanoid()
	if humanoid then
		humanoid:UnequipTools()
	end
end

-- 1 / 2 / 3: take that weapon out, or put it away if it is already in hand.
local function toggleWeapon(name: string)
	if heldName == name then
		unequipWeapon()
	else
		equipWeapon(name)
	end
end

-- Gamepad R1 / L1: the next / previous weapon the player has, in Weapons.Order.
local function cycleWeapon(step: number)
	local order = Weapons.Order
	local count = #order
	local backpack = player:FindFirstChildOfClass("Backpack")
	if count == 0 or not backpack then
		return
	end
	local current = (heldName and table.find(order, heldName)) or (if step > 0 then 0 else count + 1)
	for i = 1, count do
		local name = order[(current - 1 + step * i) % count + 1]
		local tool = backpack:FindFirstChild(name)
		if name ~= heldName and tool and tool:IsA("Tool") then
			equipWeapon(name)
			return
		end
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
	local remotes = ReplicatedStorage:WaitForChild("WeaponKitRemotes")
	fireRemote = remotes:WaitForChild("Fire")
	reloadRemote = remotes:WaitForChild("Reload")
	local ammoRemote = remotes:WaitForChild("AmmoSync")
	local fxRemote = remotes:WaitForChild("FireFX")
	local hitRemote = remotes:WaitForChild("HitConfirm")

	Effects.start()
	Hud.start({ toggle = toggleWeapon, reload = requestReload })

	-- Our own weapon bar replaces Roblox's hotbar (which would also react to the number keys).
	-- With Config.HUD off the game's own GUI (or Roblox's hotbar) does the switching.
	if Config.HUD then
		task.spawn(function()
			for _ = 1, 20 do
				if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, false) then
					return
				end
				task.wait(0.5)
			end
		end)
	end

	api = ClientApi._attach({
		equip = equipWeapon,
		unequip = unequipWeapon,
		toggle = toggleWeapon,
		reload = requestReload,
		held = function()
			return heldName
		end,
		ammo = function(name)
			local st = states[name]
			if st then
				return st.mag, st.reserve, st.reloading
			end
			return nil, nil, nil
		end,
	})

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
		-- Gamepad trigger. Roblox may activate the Tool from it as well: the fire timer stops a double shot.
		if input.KeyCode == Enum.KeyCode.ButtonR2 then
			if held then
				holding = true
				fire()
			end
			return
		end
		if not Config.HUD then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonR1 or input.KeyCode == Enum.KeyCode.ButtonL1 then
			cycleWeapon(if input.KeyCode == Enum.KeyCode.ButtonR1 then 1 else -1)
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

	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.ButtonR2 then
			holding = false
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
		announceAmmo(name)
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
			api.Hit:Fire(damage, headshot == true, killed == true)
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
