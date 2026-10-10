--!nonstrict
-- Server-side weapons. The client only SAYS it fired ("from about here, this way"); the server
-- decides everything that matters: whether a shot is allowed (alive, weapon in hand, magazine,
-- fire rate, rate limit, sane numbers), where it starts (the client's origin only if it is near
-- the real head and not behind a wall), the spread of every pellet, the raycasts, the damage,
-- the headshot bonus, and the ammo. A client never sends a weapon name, a damage number, a
-- pellet direction or a target: the weapon comes from the Tool the character is holding and
-- everything else is rolled here.
--
-- Suspicious requests are dropped silently and counted per player in Suspicion.luau (one warn
-- at a threshold; no kicks or bans: a game plugs in its own policy with Suspicion.onFlag).
-- Benign mismatches (empty, reloading, dead, data still loading) are just ignored, they are not
-- counted. Aim flags ("aim", "snap", see AimStats.luau) are counted too, but they never block or
-- change a shot: a skilled player can look like a script, so they are for review only.
--
-- Remotes (ReplicatedStorage.Remotes):
--   Fire       client -> server: (originHint: Vector3, direction: Vector3, shotId: number)
--                shotId must go up on every shot; the newest one seen is echoed in AmmoSync
--   Reload     client -> server: ()
--   AmmoSync   server -> the shooter: (weapon, mag, reserve, reloading, lastShotId), after every
--                ammo change and when a weapon is equipped (mag 0 = a hint to reload)
--   FireFX     server -> other nearby players: (weapon, origin, endPoints, hitFlags)
--   HitConfirm server -> the shooter: (damage, headshot, killed), one per shot that hurt someone
--   Rejected   (made by Suspicion.luau) server -> the shooter, demo only (Config.DEMO_CHEAT_PANEL):
--                (reason, reasonCount, totalCount) for every flag the server counted
--
-- Ammo: the magazine and the reserve of every weapon both live in PlayerData (so they are
-- saved, and a rejoin can't refill anything). A reload moves rounds from the reserve into the
-- magazine; rounds are never created.
--
-- Game hooks (server code only; each returns a function that removes the hook again):
--   WeaponServer.onDamage(fn)  fn(shooter, humanoid, damage, info) -> number?   runs for every victim
--                              of a shot, right before TakeDamage, inside pcall. Return nil to keep the
--                              damage, or a finite number >= 0 to replace it (armour, a damage cap,
--                              0 = absorbed). Hooks run in the order added and each sees the damage the
--                              one before returned. Anything else returned is ignored, and a hook that
--                              errors or returns junk is warned about ONCE. It must NOT yield: the shot
--                              is waiting for the answer. HitConfirm and the saved stats use the final
--                              damage; the round is spent whatever a hook decides.
--   WeaponServer.onKill(fn)    fn(shooter, humanoid, info)   runs once for every humanoid THIS shot took
--                              from above 0 health to 0 (a shotgun blast is one shot: one call). Each
--                              hook runs in its own thread, so it may yield.
--   info = { weapon = Tool name, headshot = a pellet hit the Head, model = the victim's Model }.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local Config = require(Shared:WaitForChild("Config"))
local Weapons = require(Shared:WaitForChild("Weapons"))
local AimStats = require(script.Parent.AimStats)
local PlayerData = require(script.Parent.PlayerData)
local RateLimit = require(script.Parent.RateLimit)
local Suspicion = require(script.Parent.Suspicion)

local WeaponServer = {}

local FIRE_TOLERANCE = 0.2 -- a shot may come 20% of the interval early (or FIRE_JITTER, whichever is longer)
local ORIGIN_SLACK = 6 -- studs the client's muzzle may be from the real head (lag, arm reach)
local FX_RANGE = 450 -- other players farther than this don't get the tracer
local MAX_COORD = 1e5 -- no real position is farther from the origin than this
local MAX_DIRECTION = 1e4 -- the client sends a unit vector; anything longer than this is nonsense
local MAX_SHOT_ID = 2 ^ 31
local POINT_BLANK = 0.25 -- studs: a muzzle this close to (or inside) a hitbox counts as a hit

local remotes = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder")
remotes.Name = "Remotes"
remotes.Parent = ReplicatedStorage
local function remote(name: string): RemoteEvent
	local r = remotes:FindFirstChild(name) or Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = remotes
	return r
end
local fireRemote = remote("Fire")
local reloadRemote = remote("Reload")
local ammoRemote = remote("AmmoSync")
local fxRemote = remote("FireFX")
local hitRemote = remote("HitConfirm")

-- Flood guards only: the real fire-rate rule is the interval check in onFire. Human limit is
-- ~10 shots/s (rifle, 600 rpm); a burst of 14 absorbs a lag spike delivering shots together.
local fireLimit = RateLimit.new(14, 14)
local reloadLimit = RateLimit.new(3, 4)

local rng = Random.new()
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude

-- [Player] = per-player state, never saved (the ammo itself is in PlayerData):
--   reloading    name of the weapon being reloaded, or nil
--   reloadToken  bumped to cancel a reload that is still counting down
--   lastShot     scheduled time of the last accepted shot (ANY weapon: see the fire-rate check)
--   lastInterval seconds between shots of the weapon that fired it
--   lastId       newest shotId seen
--   fastTimes    clocks of the recent too-early events (see noteTooFast)
--   acceptedSinceFast  a shot was accepted after the last too-early event
--   aim          AimStats state: recent headshot ratio and aim snaps
local states = {}

-- The game's hooks (see the header): { fn, warned } in the order they were added.
type HitInfo = { weapon: string, headshot: boolean, model: Model }
local damageHooks, killHooks = {}, {}

local function stateOf(player: Player)
	local s = states[player]
	if not s then
		s = {
			reloading = nil,
			reloadToken = 0,
			lastShot = -math.huge,
			lastInterval = 0,
			lastId = 0,
			fastTimes = {},
			acceptedSinceFast = true,
			aim = AimStats.newState(),
		}
		states[player] = s
	end
	return s
end

-- Tells the shooter the real ammo of one weapon (and which of its shots the server has counted).
local function sendAmmo(player: Player, s, weapon: string)
	if player.Parent ~= Players then
		return
	end
	local data = PlayerData.get(player)
	local mag = if data then data.mags[weapon] else 0
	local reserve = if data then data.reserve[weapon] else 0
	ammoRemote:FireClient(player, weapon, mag, reserve, s.reloading == weapon, s.lastId)
end

-- Mirrors the saved stats to Player attributes so the HUD can read them without a remote.
local function publishStats(player: Player)
	local data = PlayerData.get(player)
	if data then
		player:SetAttribute("Kills", data.stats.kills)
		player:SetAttribute("Shots", data.stats.shots)
		player:SetAttribute("Hits", data.stats.hits)
	end
end

-- The player's character and the name of the weapon in its hand, if it is alive and holds one
-- (a Tool is parented to the character while it is equipped). Else nil.
local function holder(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and Weapons.Defs[child.Name] then
			return character, child.Name
		end
	end
	return nil
end

-- Characters that bullets and the point-blank query must ignore: always the shooter's own;
-- with PVP off, every player's (bullets pass through, only dummies take damage).
local function ignoreList(shooter: Player)
	local list = {}
	if Config.PVP then
		if shooter.Character then
			table.insert(list, shooter.Character)
		end
	else
		for _, p in Players:GetPlayers() do
			if p.Character then
				table.insert(list, p.Character)
			end
		end
	end
	return list
end

-- The Model with a Humanoid that `inst` is, or sits inside (a limb, an accessory handle, ...).
local function humanoidModel(inst: Instance?): (Model?, Humanoid?)
	while inst and inst ~= Workspace do
		if inst:IsA("Model") then
			local humanoid = inst:FindFirstChildOfClass("Humanoid")
			if humanoid then
				return inst, humanoid
			end
		end
		inst = inst.Parent
	end
	return nil, nil
end

-- Two players on the same Team. A player without a team (Neutral) is nobody's team mate.
local function sameTeam(a: Player, b: Player): boolean
	return not a.Neutral and not b.Neutral and a.Team ~= nil and a.Team == b.Team
end

-- May `shooter` damage this model? Players only when PVP is on (never themselves, and not a team
-- mate unless FRIENDLY_FIRE); anything else only if it carries the target tag. Dead targets can't be
-- hurt again. Rays and the point-blank query both come through here.
local function canDamage(shooter: Player, model: Model, humanoid: Humanoid): boolean
	if humanoid.Health <= 0 then
		return false
	end
	local owner = Players:GetPlayerFromCharacter(model)
	if owner then
		return Config.PVP and owner ~= shooter and (Config.FRIENDLY_FIRE or not sameTeam(shooter, owner))
	end
	return CollectionService:HasTag(model, Config.TARGET_TAG)
end

-- True if `point` is inside `part` or within POINT_BLANK of its surface.
local function nearPart(part: BasePart, point: Vector3): boolean
	if part:IsA("Part") and part.Shape == Enum.PartType.Ball then
		return (point - part.Position).Magnitude <= part.Size.X / 2 + POINT_BLANK
	end
	-- Everything else is treated as its bounding box (exact for the Block parts the dummies use).
	local relative = part.CFrame:PointToObjectSpace(point)
	local half = part.Size / 2 + Vector3.one * POINT_BLANK
	return math.abs(relative.X) <= half.X and math.abs(relative.Y) <= half.Y and math.abs(relative.Z) <= half.Z
end

-- The hitbox part of a damageable target the muzzle is pressed into, if any. A ray that starts
-- inside a part never hits that part, so without this a gun jammed into a dummy would shoot
-- straight through it. Bounds query first, then an exact test per part.
local function pointBlankPart(shooter: Player, origin: Vector3): BasePart?
	for _, part in Workspace:GetPartBoundsInRadius(origin, POINT_BLANK, overlapParams) do
		local model, humanoid = humanoidModel(part)
		if humanoid and canDamage(shooter, model, humanoid) and nearPart(part, origin) then
			return part
		end
	end
	return nil
end

-- Rolls every pellet of one trigger pull on the server and works out what each one hits.
-- Returns:
--   ends     Vector3 per pellet: where it stopped
--   hits     boolean per pellet: it landed on something that takes damage
--   victims  { [Humanoid] = { damage = total over all pellets, head = any headshot, model } }
local function castPellets(shooter: Player, weapon, origin: Vector3, aim: Vector3)
	local ends, hits, victims = {}, {}, {}
	local pressedInto = pointBlankPart(shooter, origin) -- muzzle jammed into a hitbox: every pellet hits it
	for i = 1, weapon.pellets do
		local direction = Ballistics.spread(aim, weapon.spread, rng)
		local part, endPoint
		if pressedInto then
			part, endPoint = pressedInto, origin
		else
			local result = Workspace:Raycast(origin, direction * weapon.range, rayParams)
			endPoint = if result then result.Position else origin + direction * weapon.range
			part = if result then result.Instance else nil
		end

		local landed = false
		local model, humanoid = humanoidModel(part)
		if humanoid and canDamage(shooter, model, humanoid) then
			landed = true
			local isHead = part.Name == "Head"
			local victim = victims[humanoid]
			if not victim then
				victim = { damage = 0, head = false, model = model }
				victims[humanoid] = victim
			end
			victim.damage += if isHead then weapon.damage * weapon.headshotMultiplier else weapon.damage
			victim.head = victim.head or isHead
		end
		ends[i] = endPoint
		hits[i] = landed
	end
	return ends, hits, victims
end

local function broadcastFx(shooter: Player, weaponName: string, origin: Vector3, ends, hits)
	for _, other in Players:GetPlayers() do
		if other ~= shooter then
			local root = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
			if root and (root.Position - origin).Magnitude <= FX_RANGE then
				fxRemote:FireClient(other, weaponName, origin, ends, hits)
			end
		end
	end
end

-- Runs the onDamage hooks over one victim's damage, each seeing what the one before returned.
-- A hook is the game's code: an error or a return value that is not a finite number >= 0 is
-- ignored (the damage stays as it was), with one warn per hook so a bad hook can't flood the log.
local function adjustedDamage(shooter: Player, humanoid: Humanoid, damage: number, info: HitInfo): number
	if #damageHooks == 0 then
		return damage
	end
	for _, hook in table.clone(damageHooks) do -- (a hook may remove itself)
		local ok, result = pcall(hook.fn, shooter, humanoid, damage, info)
		local problem = nil
		if not ok then
			problem = "errored: " .. tostring(result)
		elseif result ~= nil then
			if RateLimit.isNumber(result, 0) then
				damage = result
			else
				problem = "returned " .. tostring(result) .. " (want nil or a number >= 0)"
			end
		end
		if problem and not hook.warned then
			hook.warned = true
			warn("[WeaponKit] onDamage hook " .. problem)
		end
	end
	return damage
end

-- A shot that came too early is refused, but one refusal proves nothing: a lag spike delivers
-- several honest shots in the same instant and all but the first look too fast. So refusals with no
-- accepted shot between them are ONE event, and "fast" is reported only when FAST_FLAG_COUNT events
-- fall within FAST_FLAG_WINDOW seconds: a client that keeps firing faster than the rpm.
local function noteTooFast(player: Player, s, now: number)
	if not s.acceptedSinceFast then
		return
	end
	s.acceptedSinceFast = false
	local limits = Config.ANTI_CHEAT
	local times = s.fastTimes
	table.insert(times, now)
	while times[1] and now - times[1] > limits.FAST_FLAG_WINDOW do
		table.remove(times, 1)
	end
	if #times >= limits.FAST_FLAG_COUNT then
		table.clear(times)
		Suspicion.report(
			player,
			"fast",
			string.format("%d too-early shots within %.1f s", limits.FAST_FLAG_COUNT, limits.FAST_FLAG_WINDOW)
		)
	end
end

local function onFire(player: Player, originHint, direction, shotId)
	if not fireLimit:allow(player) then
		Suspicion.report(player, "rate")
		return
	end
	local s = stateOf(player)

	-- Types and numbers first: nothing below may see a NaN, an inf or a wrong type.
	if
		not RateLimit.isVector3(originHint, MAX_COORD)
		or not RateLimit.isVector3(direction, MAX_DIRECTION)
		or not RateLimit.isNumber(shotId, 1, MAX_SHOT_ID)
		or shotId % 1 ~= 0
		or shotId <= s.lastId
		or direction.Magnitude < 1e-3
	then
		Suspicion.report(player, "args")
		return
	end
	s.lastId = shotId

	local data = PlayerData.get(player)
	if not data then
		return -- data still loading
	end
	local character, weaponName = holder(player)
	if not character then
		return -- dead, or no weapon in hand
	end
	local weapon = Weapons.Defs[weaponName]
	if s.reloading or data.mags[weaponName] <= 0 then
		sendAmmo(player, s, weaponName) -- the client is out of step: tell it the real state
		return
	end

	-- One fire timer shared by all weapons, so swapping weapons can't dodge a fire rate: the wait
	-- after a shot is the longer of the old weapon's interval and the new one's (after a shotgun
	-- blast nothing fires until the pump is back; a rifle can't fire a pistol's cadence faster).
	-- A shot may arrive `early` seconds before its slot (network jitter bunches honest shots up). That is a
	-- bounded credit, not a bank: the schedule below moves a full interval per accepted shot whatever the
	-- arrival, so no timing averages more than the rpm. Past the credit the shot is refused.
	local interval = 60 / weapon.rpm
	local wait = math.max(s.lastInterval, interval)
	local early = math.max(wait * FIRE_TOLERANCE, Config.ANTI_CHEAT.FIRE_JITTER)
	local now = os.clock()
	if now - s.lastShot < wait - early then
		noteTooFast(player, s, now)
		sendAmmo(player, s, weaponName) -- the client already showed the shot: give it the real ammo back
		return
	end
	local head = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
	if not head then
		return
	end

	-- Where the bullets start: the client's muzzle if it is near the real head and not behind a
	-- wall from it, otherwise the head itself.
	local headPos = head.Position
	-- Fails closed: a head that is not a real, finite point cannot be measured against, so no shot
	-- is made from it (and no round is spent). Defense in depth: in Studio a client-set NaN CFrame
	-- never reached the server.
	if not RateLimit.isVector3(headPos, MAX_COORD) then
		Suspicion.report(player, "origin", "head position is not a finite number")
		return
	end
	rayParams.FilterDescendantsInstances = ignoreList(player)
	overlapParams.FilterDescendantsInstances = rayParams.FilterDescendantsInstances
	local origin = originHint
	local offset = originHint - headPos
	if not (offset.Magnitude <= ORIGIN_SLACK) then -- (written so that a NaN goes to the fallback too)
		-- A seated shooter (a vehicle) has a muzzle that runs ahead of the head at vehicle speed: the
		-- shot still starts at the head, but that is not worth a flag.
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not (humanoid and humanoid.SeatPart ~= nil) then
			Suspicion.report(player, "origin")
		end
		origin = headPos
	elseif offset.Magnitude > 0.1 and Workspace:Raycast(headPos, offset, rayParams) then
		origin = headPos
	end

	-- The shot is accepted: from here on the server decides.
	-- lastShot is the shot's SCHEDULED time, not its arrival: a shot that came early (jitter
	-- tolerance) borrows that time from the next one, so a client that always fires at the
	-- tolerance edge still averages the real rpm instead of rpm / (1 - FIRE_TOLERANCE).
	s.lastShot = math.max(now, s.lastShot + wait)
	s.lastInterval = interval
	s.acceptedSinceFast = true
	data.mags[weaponName] -= 1
	local ends, hits, victims = castPellets(player, weapon, origin, direction.Unit)

	local total, anyHead, kills = 0, false, 0
	for humanoid, victim in victims do
		local info: HitInfo = { weapon = weaponName, headshot = victim.head, model = victim.model }
		local damage = adjustedDamage(player, humanoid, victim.damage, info)
		local healthBefore = humanoid.Health
		humanoid:TakeDamage(damage)
		total += damage
		anyHead = anyHead or victim.head
		if healthBefore > 0 and humanoid.Health <= 0 then
			kills += 1
			for _, hook in table.clone(killHooks) do
				task.spawn(hook.fn, player, humanoid, info) -- own thread each: a hook may yield or fail
			end
		end
	end
	data.stats.shots += 1
	if next(victims) then
		data.stats.hits += 1 -- one hit per trigger pull, so accuracy stays 0..100%
		data.stats.kills += kills
		hitRemote:FireClient(player, total, anyHead, kills > 0)
	end
	publishStats(player)

	-- Aim flags: counted, never blocking (the shot above already happened as the server rolled it).
	-- The headshot ratio only uses single-pellet weapons: a shotgun blast hits a head by luck.
	local landed = next(victims) ~= nil
	if AimStats.recordShot(s.aim, now, direction.Unit, landed, Config.ANTI_CHEAT) then
		Suspicion.report(player, "snap", "aim jumped between targets and hit")
	end
	if landed and weapon.pellets == 1 then
		local flagged, ratio = AimStats.recordHit(s.aim, anyHead, Config.ANTI_CHEAT)
		if flagged then
			Suspicion.report(player, "aim", string.format("headshot ratio %.2f", ratio))
		end
	end

	sendAmmo(player, s, weaponName) -- mag 0 here is the client's cue to ask for a reload
	broadcastFx(player, weaponName, origin, ends, hits)
end

local function onReload(player: Player)
	if not reloadLimit:allow(player) then
		Suspicion.report(player, "reload")
		return
	end
	local s = stateOf(player)
	local data = PlayerData.get(player)
	if not data then
		return
	end
	local character, weaponName = holder(player)
	if not character then
		return
	end
	local weapon = Weapons.Defs[weaponName]
	-- Nothing to do (already reloading, magazine full, no spare rounds): not an attack, but
	-- re-sync the client in case it is out of step.
	if s.reloading or data.mags[weaponName] >= weapon.magazine or data.reserve[weaponName] <= 0 then
		sendAmmo(player, s, weaponName)
		return
	end

	s.reloading = weaponName
	s.reloadToken += 1
	local token = s.reloadToken
	sendAmmo(player, s, weaponName)
	task.delay(weapon.reloadTime, function()
		if states[player] ~= s or s.reloadToken ~= token or s.reloading ~= weaponName then
			return -- left, respawned, put the weapon away or otherwise cancelled
		end
		s.reloading = nil
		local current = PlayerData.get(player)
		local _, stillHeld = holder(player)
		if current and stillHeld == weaponName then
			-- Rounds move from the saved reserve into the magazine: they are never created.
			-- (Read again now: a crate restock or a second source may have changed it.)
			local moved = math.min(weapon.magazine - current.mags[weaponName], current.reserve[weaponName])
			current.mags[weaponName] += moved
			current.reserve[weaponName] -= moved
		end
		sendAmmo(player, s, weaponName)
	end)
end

-- A new life: any reload from the last life is cancelled and the fire timer starts fresh.
-- Ammo carries over (a respawn is not a free refill).
local function onCharacter(player: Player, character: Model)
	local s = stateOf(player)
	s.reloading = nil
	s.reloadToken += 1
	s.lastShot = -math.huge
	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and Weapons.Defs[child.Name] then
			local data = PlayerData.get(player)
			if data then
				data.loadout = child.Name -- remembered for the next spawn
			end
			sendAmmo(player, s, child.Name) -- the client's ammo label shows this when the weapon comes out
		end
	end)
	character.ChildRemoved:Connect(function(child)
		-- Putting a weapon away cancels its reload (the rounds stay in the reserve).
		if states[player] == s and s.reloading == child.Name and child:IsA("Tool") then
			s.reloading = nil
			s.reloadToken += 1
			sendAmmo(player, s, child.Name)
		end
	end)
end

-- Refills every weapon's reserve to its cap. Server code only: the ammo crate calls this after
-- it has checked distance and cooldown. Returns false if the player's data isn't loaded.
function WeaponServer.restock(player: Player): boolean
	local data = PlayerData.get(player)
	if not data then
		return false
	end
	for name, weapon in Weapons.Defs do
		data.reserve[name] = weapon.reserveMax
	end
	local s = states[player]
	local _, weaponName = holder(player)
	if s and weaponName then
		sendAmmo(player, s, weaponName)
	end
	return true
end

local function addHook(list, fn): () -> ()
	local hook = { fn = fn, warned = false }
	table.insert(list, hook)
	return function()
		local index = table.find(list, hook)
		if index then
			table.remove(list, index)
		end
	end
end

-- See "Game hooks" in the header.
function WeaponServer.onDamage(fn: (Player, Humanoid, number, HitInfo) -> number?): () -> ()
	return addHook(damageHooks, fn)
end

function WeaponServer.onKill(fn: (Player, Humanoid, HitInfo) -> ()): () -> ()
	return addHook(killHooks, fn)
end

function WeaponServer.init()
	fireRemote.OnServerEvent:Connect(onFire)
	reloadRemote.OnServerEvent:Connect(onReload)

	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			onCharacter(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)

	PlayerData.onLoaded(publishStats)
	print("[WeaponKit] WeaponServer ready")
end

return WeaponServer
