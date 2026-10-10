
---------------------------------------------------------------- INTEGRATION: the kit next to admin systems and game scripts
-- Everything a game developer does AROUND the kit, in the same mocked world as the other files: admin
-- commands that teleport / fling / seat players, scripts that push players with movers, conveyors,
-- WalkSpeed changes, teams and armour hooks, runtime-added weapons, and the save layer failing.
-- Server writes (PivotTo, MoveTo, serverSet) fire the mock's property signals, a client move (a plain
-- field change) never does: that is what was measured in Studio. The trust tests run twice, with the
-- signals delivered immediately and deferred (Workspace.SignalBehavior): the kit must not depend on
-- a handler running inside the write.
-- Everything this file changes (Config switches, mock handlers, runtime weapons, players) is put back at
-- the end, so the fuzz test after it sees the world the older tests left.
do
	local Suspicion = require_(server.Suspicion)
	local savedRay, savedBlock, savedBounds, savedWait = rayHandler, blockHandler, Workspace.GetPartBoundsInRadius, task.wait
	local savedPlayers = table.clone(Players.list)
	local savedWorkspaceChildren = #Workspace.children
	local savedConfig = {
		PVP = Config.PVP, FRIENDLY_FIRE = Config.FRIENDLY_FIRE, MOVEMENT_ACTION = L.MOVEMENT_ACTION,
		TRUST_SERVER_MOVES = L.TRUST_SERVER_MOVES, EXEMPT_GROUP = L.EXEMPT_GROUP,
	}
	local made = {} -- every player this file makes, taken out again at the end
	local ids = {} -- last shot id per shooter
	local errorsAtStart = #taskErrors
	Workspace.GetPartBoundsInRadius = realPartBounds

	local function track(p) table.insert(made, p); return p end
	local function lastFor(remote, player)
		for i = #remote.fired, 1, -1 do
			if remote.fired[i].player == player then return remote.fired[i].args end
		end
		return nil
	end
	local function countFor(remote, player)
		local n = 0
		for _, f in remote.fired do if f.player == player then n += 1 end end
		return n
	end
	local function boxPart(parent, name, center, size)
		local part = new("Part", name)
		part.Position = center
		part.Size = size
		part.CFrame = { Position = center, PointToObjectSpace = function(_, point) return point - center end }
		part.Parent = parent
		return part
	end
	local function rayHits(part, at) rayHandler = function() return { Position = at or vec(0, 3, -10), Instance = part } end end
	local function rayMisses() rayHandler = function() return nil end end
	-- A shooter with a character (head at `headPos`) and one weapon in hand; save data loaded.
	local function shooter(name, id, headPos, tool)
		local p = track(makePlayer(name, id))
		p.Neutral = true
		Players.PlayerAdded:fire(p)
		local c = makeCharacter(p, headPos or vec(0, 5, 0))
		c.Parent = Workspace -- (a real character lives in the Workspace: the point-blank query looks there)
		local t = new("Tool", tool or "Pistol")
		t.Parent = c
		return p, c, t
	end
	-- One honest shot `gap` seconds after the last thing that happened; the muzzle is the head unless given.
	local function shoot(p, hint, dir, gap)
		advance(gap or 1)
		ids[p] = (ids[p] or 0) + 1
		fire(p, hint or (p.Character.Head and p.Character.Head.Position) or vec(0, 5, 0), dir or vec(0, 0, -1), ids[p])
	end
	local function dummyOf(name) -- a tagged dummy with the usual Head / Torso
		return makeDummy(name)
	end
	local function warnsAbout(text)
		local n = 0
		for _, w in warns do if w:find(text, 1, true) then n += 1 end end
		return n
	end

	-------------------------------------------------------------------------------------- combat
	section("Integration / combat: PVP on - another player is hit, the shooter never, a dead player never")
	do
		Config.PVP = true
		local a, ca = shooter("IA", 401)
		local b, cb = shooter("IB", 402, vec(0, 5, -10))
		local dataA = PlayerData.get(a)
		check(dataA ~= nil, "a player who joins later gets save data")
		rayCalls = {}
		rayHits(cb.Head)
		shoot(a)
		eq(cb.Humanoid.Health, 60, "PVP on: a pistol headshot (40) takes the other player from 100 to 60")
		local h = lastFor(hitR, a)
		check(h and h[1] == 40 and h[2] == true and h[3] == false, "PVP on: HitConfirm says 40, headshot, no kill")
		local filter = rayCalls[#rayCalls].filter
		check(table.find(filter, ca) ~= nil and table.find(filter, cb) == nil, "PVP on: only the shooter's own character is ignored by the ray")

		local magBefore, confirmsBefore = dataA.mags.Pistol, countFor(hitR, a)
		rayHits(ca.Head)
		shoot(a)
		eq(ca.Humanoid.Health, 100, "PVP on: the shooter's own body is never hurt")
		eq(countFor(hitR, a), confirmsBefore, "PVP on: no HitConfirm for hitting yourself")
		eq(dataA.mags.Pistol, magBefore - 1, "PVP on: the round is spent anyway")

		cb.Humanoid.Health = 0
		rayHits(cb.Head)
		shoot(a)
		eq(cb.Humanoid.Health, 0, "PVP on: a dead player takes no further damage")
		eq(countFor(hitR, a), confirmsBefore, "PVP on: no HitConfirm for a dead player")

		Config.PVP = false
		cb.Humanoid.Health = 100
		rayHits(cb.Head)
		shoot(a)
		eq(cb.Humanoid.Health, 100, "PVP off: players are not hit at all")
	end

	section("Integration / combat: FRIENDLY_FIRE - team mates, other teams, Neutral players")
	do
		Config.PVP = true
		Config.FRIENDLY_FIRE = false
		local red, blue = new("Team", "Red"), new("Team", "Blue")
		local s, cs = shooter("TS", 410)
		s.Team = red; s.Neutral = false
		local mate, cm = shooter("TM", 411, vec(0, 5, -10)); mate.Team = red; mate.Neutral = false
		local foe, cf = shooter("TF", 412, vec(0, 5, -12)); foe.Team = blue; foe.Neutral = false
		local loner, cl = shooter("TL", 413, vec(0, 5, -14)) -- Neutral
		local function damageTo(who, c) -- one headshot by `who` on c; returns the health lost
			c.Humanoid.Health = 100
			rayHits(c.Head)
			shoot(who)
			return 100 - c.Humanoid.Health
		end
		eq(damageTo(s, cm), 0, "FRIENDLY_FIRE off: a team mate takes no damage")
		local confirms = countFor(hitR, s)
		eq(damageTo(s, cf), 40, "FRIENDLY_FIRE off: a player on another team is hit")
		eq(countFor(hitR, s), confirms + 1, "...and the shooter is told")
		eq(damageTo(s, cl), 40, "FRIENDLY_FIRE off: a Neutral player can always be hit")
		eq(damageTo(s, cs), 0, "FRIENDLY_FIRE off: still never yourself")

		local neutralShooter, cn = shooter("TN", 414)
		eq(damageTo(neutralShooter, cm), 40, "FRIENDLY_FIRE off: a Neutral shooter hits a player on a team")
		eq(damageTo(neutralShooter, cl), 40, "FRIENDLY_FIRE off: two Neutral players can hit each other (both have no Team)")

		Config.FRIENDLY_FIRE = true
		eq(damageTo(s, cm), 40, "FRIENDLY_FIRE on: team mates hurt each other")
		eq(damageTo(s, cs), 0, "FRIENDLY_FIRE on: yourself is still never hurt")
		Config.FRIENDLY_FIRE = false

		-- the point-blank query goes through the same rule: a muzzle pressed into a team mate
		local gun, cg = shooter("TG", 415, vec(0, 5, 0), "Shotgun")
		gun.Team = red; gun.Neutral = false
		local torso = boxPart(cm, "Torso", vec(0, 5, -3), vec(4, 4, 2))
		cm.Humanoid.Health = 100
		rayMisses()
		shoot(gun, vec(0, 5, -3))
		eq(cm.Humanoid.Health, 100, "FRIENDLY_FIRE off: a muzzle pressed into a team mate hurts nobody")
		Config.FRIENDLY_FIRE = true
		cm.Humanoid.Health = 100
		shoot(gun, vec(0, 5, -3))
		eq(cm.Humanoid.Health, 12, "FRIENDLY_FIRE on: all 8 shotgun pellets hit the team mate the muzzle is inside (88)")
		Config.FRIENDLY_FIRE = false
		Config.PVP = false
		torso.Parent = nil
	end

	section("Integration / combat: WeaponServer.onDamage - halve, zero, raise, chain, bad returns, errors")
	do
		Config.PVP = false
		local a = shooter("HA", 420)
		local dataA = PlayerData.get(a)
		local m, hum, head, torso = dummyOf("HookDummy")
		rayHits(torso)
		local seen, ret = {}, nil
		local remove = WeaponServer.onDamage(function(who, humanoid, damage, info)
			table.insert(seen, { who, humanoid, damage, info })
			return ret
		end)
		local function shotAt(h)
			hum.Health = 100
			if dataA.mags.Pistol < 3 then dataA.mags.Pistol = 15 end -- (this section fires a lot)
			local mag, confirms, hits = dataA.mags.Pistol, countFor(hitR, a), dataA.stats.hits
			rayHits(h)
			shoot(a)
			return 100 - hum.Health, mag - dataA.mags.Pistol, lastFor(hitR, a), dataA.stats.hits - hits, countFor(hitR, a) - confirms
		end

		local lost, spent, hit = shotAt(torso)
		eq(lost, 20, "onDamage returning nil keeps the damage")
		local call = seen[#seen]
		check(call[1] == a and call[2] == hum and call[3] == 20, "the hook gets (shooter, humanoid, damage)")
		check(call[4].weapon == "Pistol" and call[4].headshot == false and call[4].model == m, "...and info { weapon, headshot, model }")
		lost = shotAt(head)
		eq(seen[#seen][3], 40, "the hook sees the damage after the headshot multiplier")
		eq(seen[#seen][4].headshot, true, "...and info.headshot is true for a headshot")

		ret = 10
		lost, spent, hit = shotAt(torso)
		eq(lost, 10, "onDamage returning half: the humanoid takes the new damage")
		eq(hit[1], 10, "HitConfirm carries the final damage")
		eq(spent, 1, "the round is spent")
		ret = 0
		local hitsDelta, confirmsDelta
		lost, spent, hit, hitsDelta, confirmsDelta = shotAt(torso)
		eq(lost, 0, "onDamage returning 0: no damage (shield / absorbed)")
		eq(spent, 1, "...the round is still spent")
		eq(hit[1], 0, "...HitConfirm says 0")
		eq(hitsDelta, 1, "...it still counts as a hit in the stats (the bullet landed)")
		ret = 55
		lost = shotAt(torso)
		eq(lost, 55, "onDamage may raise damage too")

		-- anything that is not nil or a finite number >= 0 is ignored; one warn for the hook, not one per shot
		local warnsBefore = warnsAbout("onDamage hook")
		for _, junk in { 0 / 0, -5, "x", math.huge, -math.huge, true, {} } do
			ret = junk
			lost = shotAt(torso)
			eq(lost, 20, "junk return " .. tostring(typeof(junk) == "table" and "{}" or junk) .. " is ignored: full damage")
		end
		eq(warnsAbout("onDamage hook") - warnsBefore, 1, "...and the hook is warned about exactly once for 7 bad shots")
		ret = nil

		-- hooks chain in the order they were added, each seeing the one before's result
		local removeSecond = WeaponServer.onDamage(function(_, _, damage) return damage + 1 end)
		ret = 10
		lost = shotAt(torso)
		eq(lost, 11, "two hooks chain: 20 -> 10 -> 11")
		removeSecond()
		lost = shotAt(torso)
		eq(lost, 10, "a removed hook is not called any more")
		remove()
		ret = 0
		lost = shotAt(torso)
		eq(lost, 20, "after the first hook is removed too: full damage again")

		-- a hook that errors does not break the shot
		local errorsBefore = #taskErrors
		local warnsBeforeError = warnsAbout("onDamage hook")
		local removeBad = WeaponServer.onDamage(function() error("kaboom") end)
		lost, spent, hit = shotAt(torso)
		eq(lost, 20, "an erroring hook: the shot still does its damage")
		eq(spent, 1, "...the ammo is still spent")
		check(hit ~= nil and hit[1] == 20, "...and HitConfirm is still sent")
		shotAt(torso)
		eq(warnsAbout("onDamage hook") - warnsBeforeError, 1, "...with one warn for two errors")
		check(warns[#warns]:find("kaboom") ~= nil, "...that names the error")
		eq(#taskErrors, errorsBefore, "...and no thread error")
		removeBad()

		-- a hook that removes itself while it runs
		local selfRemove
		selfRemove = WeaponServer.onDamage(function() selfRemove(); return 1 end)
		eq((shotAt(torso)), 1, "a hook may remove itself while it runs")
		eq((shotAt(torso)), 20, "...and it is gone afterwards")
	end

	section("Integration / combat: WeaponServer.onKill - exactly once per kill, never for a corpse")
	do
		Config.PVP = false
		local a, ca, pistol = shooter("KA", 425)
		local dataA = PlayerData.get(a)
		local m, hum, head, torso = dummyOf("KillDummy")
		rayHits(torso)
		local kills = {}
		local removeKill = WeaponServer.onKill(function(who, humanoid, info) table.insert(kills, { who, humanoid, info }) end)

		hum.Health = 100
		shoot(a)
		eq(#kills, 0, "a shot that does not kill raises no onKill")
		hum.Health = 20
		shoot(a)
		eq(#kills, 1, "the killing shot raises onKill once")
		check(kills[1][1] == a and kills[1][2] == hum, "onKill gets (shooter, humanoid, info)")
		check(kills[1][3].weapon == "Pistol" and kills[1][3].headshot == false and kills[1][3].model == m, "...info { weapon, headshot, model }")
		check(lastFor(hitR, a)[3] == true, "HitConfirm says killed")
		eq(dataA.stats.kills, 1, "the kill is counted in the stats")
		local magBefore = dataA.mags.Pistol
		shoot(a)
		shoot(a)
		eq(#kills, 1, "shooting a corpse again raises nothing")
		eq(dataA.mags.Pistol, magBefore - 2, "...but the rounds are spent")

		-- a headshot kill says headshot
		hum.Health = 30
		rayHits(head)
		shoot(a)
		eq(#kills, 2, "a headshot kill raises onKill")
		eq(kills[2][3].headshot, true, "...with info.headshot")

		-- an armour hook that stops the kill: no kill
		local removeArmour = WeaponServer.onDamage(function(_, _, damage) return damage / 4 end)
		hum.Health = 20
		rayHits(torso)
		shoot(a)
		eq(#kills, 2, "damage reduced by an onDamage hook so the target lives: no onKill")
		removeArmour()
		local removeBoost = WeaponServer.onDamage(function(_, _, damage) return damage * 10 end)
		hum.Health = 100
		shoot(a)
		eq(#kills, 3, "damage raised by an onDamage hook until the target dies: onKill")
		removeBoost()

		-- a shotgun blast is ONE shot: 8 pellets, one kill event
		pistol.Parent = nil
		local shotgun = new("Tool", "Shotgun"); shotgun.Parent = ca
		hum.Health = 50
		rayHits(torso)
		shoot(a)
		eq(#kills, 4, "an 8-pellet shotgun kill raises onKill exactly once")
		eq(dataA.stats.kills, 4, "...and the stats count one kill per target")
		shoot(a)
		eq(#kills, 4, "a second blast into the corpse raises nothing")

		-- one blast, two victims: one event each
		local m2, hum2, head2, torso2 = dummyOf("KillDummy2")
		hum.Health, hum2.Health = 40, 40
		local flip = 0
		rayHandler = function()
			flip += 1
			return { Position = vec(0, 3, -10), Instance = if flip % 2 == 0 then torso else torso2 }
		end
		shoot(a)
		eq(#kills, 6, "one blast that kills two dummies raises onKill twice (once each)")
		check(kills[5][2] ~= kills[6][2], "...for two different humanoids")
		check(lastFor(hitR, a)[3] == true, "...HitConfirm says killed")

		-- two hooks both fire; a failing hook does not stop the other; a yielding hook does not block the shot
		local second = 0
		local removeSecond = WeaponServer.onKill(function() second += 1 end)
		local removeFail = WeaponServer.onKill(function() error("hook bug") end)
		local removeYield = WeaponServer.onKill(function() coroutine.yield() end)
		local errorsBefore = #taskErrors
		hum.Health = 20
		rayHits(torso)
		pistol.Parent = ca; shotgun.Parent = nil
		shoot(a)
		eq(#kills, 7, "the first hook still ran")
		eq(second, 1, "a second hook runs too")
		eq(#taskErrors, errorsBefore + 1, "a hook that errors fails in its own thread only")
		taskErrors[#taskErrors] = nil
		check(lastFor(hitR, a)[3] == true, "a hook that yields does not hold up HitConfirm")
		removeSecond(); removeFail(); removeYield()
		removeKill()
		hum.Health = 20
		shoot(a)
		eq(#kills, 7, "a removed onKill hook is not called")
	end

	section("Integration / combat: point-blank - a muzzle inside a target hits it; a wall in between does not")
	do
		Config.PVP = false
		local a, ca = shooter("PA", 430, vec(0, 5, 0), "Shotgun")
		local dataA = PlayerData.get(a)
		local m, hum, head, torso = dummyOf("BlankDummy")
		head.Position, head.Size = vec(0, 8, -3), vec(2, 1, 1)
		head.CFrame = { Position = head.Position, PointToObjectSpace = function(_, p) return p - head.Position end }
		torso.Position, torso.Size = vec(0, 5, -3), vec(4, 4, 2)
		torso.CFrame = { Position = torso.Position, PointToObjectSpace = function(_, p) return p - torso.Position end }
		rayCalls = {}
		rayMisses()
		shoot(a, vec(0, 5, -3))
		eq(hum.Health, 12, "muzzle inside a tagged dummy: all 8 pellets hit it (88)")
		eq(#rayCalls, 1, "...no pellet needed a ray (only the one wall check on the way to the muzzle)")
		check(lastFor(hitR, a)[1] == 88 and lastFor(hitR, a)[2] == false, "...HitConfirm 88, body")

		-- inside the Head part: headshot damage on every pellet
		hum.Health = 200
		shoot(a, vec(0, 8, -3))
		eq(hum.Health, 200 - 8 * 11 * 1.5, "muzzle inside the Head part: every pellet is a headshot (132)")
		eq(lastFor(hitR, a)[2], true, "...HitConfirm says headshot")

		-- 0.2 studs outside the surface still counts (POINT_BLANK 0.25), 1 stud outside does not
		hum.Health = 100
		shoot(a, vec(0, 5, -1.8)) -- the torso's near face is at z = -2; the muzzle is 0.2 in front of it
		eq(hum.Health, 12, "muzzle 0.2 studs in front of the surface counts")
		hum.Health = 100
		shoot(a, vec(0, 5, -1))
		eq(hum.Health, 100, "muzzle 1 stud in front of the surface falls back to the rays (which miss here)")

		-- the muzzle hint is inside the dummy but a wall sits between the head and the muzzle: the shot starts at the head
		local wall = new("Part", "Wall")
		local tags = Suspicion.total(a)
		rayCalls = {}
		rayHandler = function(origin, dir)
			if dir.Magnitude < 50 then return { Position = vec(0, 5, -1), Instance = wall } end -- head -> muzzle: blocked
			return nil
		end
		hum.Health = 100
		shoot(a, vec(0, 5, -3))
		eq(hum.Health, 100, "muzzle inside a dummy but a wall in between: no point-blank hit")
		local pelletRay = rayCalls[#rayCalls]
		check(pelletRay.origin.X == 0 and pelletRay.origin.Y == 5 and pelletRay.origin.Z == 0, "...the pellets start at the head instead")
		eq(Suspicion.total(a), tags, "...and nobody is flagged for it (the hint was within reach)")
		eq(dataA.mags.Shotgun, 1, "(bookkeeping) 5 of the 6 shotgun rounds are gone: nothing above was free")

		-- a ball-shaped hitbox is a sphere, not its bounding box
		m.Parent = nil
		local m3, hum3, head3, torso3 = dummyOf("BallDummy")
		torso3.Position, torso3.Size, torso3.Shape = vec(0, 5, -3), vec(4, 4, 4), Enum.PartType.Ball
		torso3.CFrame = { Position = torso3.Position, PointToObjectSpace = function(_, p) return p - torso3.Position end }
		dataA.mags.Shotgun = 6
		rayMisses()
		shoot(a, vec(0, 5, -3))
		eq(hum3.Health, 12, "muzzle inside a ball-shaped part: all 8 pellets hit")
		hum3.Health = 100
		shoot(a, vec(1.9, 6.9, -3)) -- inside the ball's bounding box, outside the ball itself
		eq(hum3.Health, 100, "muzzle in the corner of the ball's bounding box (outside the sphere): no point-blank hit")
		m3.Parent = nil
	end

	section("Integration / combat: a weapon added at runtime (SMG) fires, reloads and restocks")
	do
		Config.PVP = false
		Weapons.Defs.Smg = {
			name = "SMG", slot = 4, mode = "auto", damage = 9, headshotMultiplier = 1.8, pellets = 1, rpm = 900,
			magazine = 35, reserveMax = 210, startReserve = 140, reloadTime = 2, range = 250, spread = 1.6,
			recoil = 0.6, color = {},
		}
		local a = shooter("SA", 435, vec(0, 5, 0), "Smg")
		local dataA = PlayerData.get(a)
		eq(dataA.mags.Smg, 35, "a player joining after the weapon was added gets a full SMG magazine")
		eq(dataA.reserve.Smg, 140, "...and its start reserve")
		local sync = lastFor(ammoR, a)
		check(sync and sync[1] == "Smg" and sync[2] == 35 and sync[3] == 140 and sync[4] == false, "equipping the new weapon syncs its ammo")
		local m, hum, head, torso = dummyOf("SmgDummy")
		rayHits(torso)
		shoot(a)
		eq(hum.Health, 91, "the SMG hits for its own damage (9)")
		for _ = 1, 3 do shoot(a, nil, nil, 0.07) end -- 900 rpm = one round every 0.0667 s
		eq(dataA.mags.Smg, 31, "four SMG rounds fired at 900 rpm are all accepted")
		for _ = 1, 3 do shoot(a, nil, nil, 0.03) end
		eq(dataA.mags.Smg, 29, "three rounds 0.03 s apart: the jitter credit (0.1 s) lets 2 through, the 3rd is too fast")
		eq(Suspicion.total(a), 0, "...and one refusal is not reported")
		advance(0.5)
		reloadR.OnServerEvent:fire(a)
		check(lastFor(ammoR, a)[4] == true, "the SMG reloads (reloading flag)")
		advance(2.1)
		eq(dataA.mags.Smg, 35, "...the magazine is refilled after its reloadTime")
		eq(dataA.reserve.Smg, 134, "...from the reserve (140 - 6)")
		WeaponServer.restock(a)
		eq(dataA.reserve.Smg, 210, "the ammo crate restocks the new weapon to its cap")
		Weapons.Defs.Smg = nil
	end

	section("Integration / combat: fire rate - rapid fire is capped at the rpm and reported when sustained")
	do
		Config.PVP = false
		rayMisses()
		Weapons.Defs.Mg = {
			name = "MG", slot = 7, mode = "auto", damage = 1, headshotMultiplier = 1, pellets = 1, rpm = 600,
			magazine = 2000, reserveMax = 0, startReserve = 0, reloadTime = 1, range = 100, spread = 0, recoil = 0, color = {},
		}
		local id = 470
		-- A cheater firing `factor` times the rpm for `seconds`, perfectly evenly (the best a script can do).
		local function rapid(factor, seconds)
			id += 1
			local p = shooter("FR" .. id, id, vec(0, 5, 0), "Mg")
			local data = PlayerData.get(p)
			local gap = 0.1 / factor
			local sent, reportedAt = math.floor(seconds / gap), nil
			for k = 1, sent do
				shoot(p, nil, nil, if k == 1 then 1 else gap)
				if not reportedAt and (select(2, Suspicion.total(p))).fast then reportedAt = (k - 1) * gap end
			end
			return 2000 - data.mags.Mg, sent, reportedAt
		end
		for _, factor in { 1.1, 1.25, 1.5, 2, 5, 20 } do
			local accepted, sent, reportedAt = rapid(factor, 3)
			-- the exact cap: 1 + (span + jitter credit) / interval, span = time from the first to the last shot
			local cap = math.floor(1 + ((sent - 1) * 0.1 / factor + 0.1) / 0.1)
			check(accepted <= cap, string.format("%.2fx the rpm for 3 s: %d of %d shots accepted (cap %d = the rpm + the one-off jitter credit)", factor, accepted, sent, cap))
			if factor >= 1.25 then
				check(reportedAt ~= nil and reportedAt <= 2, string.format("...and reported 'fast' within 2 s (at %s s)", if reportedAt then string.format("%.2f", reportedAt) else "never"))
			end
		end
		-- the credit is a one-off, not a bank: after 10 s of silence a burst still gets only 1 + credit
		local p = shooter("FRBank", 490, vec(0, 5, 0), "Mg")
		local data = PlayerData.get(p)
		shoot(p)
		advance(10)
		for _ = 1, 10 do shoot(p, nil, nil, 0) end
		eq(2000 - data.mags.Mg, 1 + 2, "10 s of silence banks nothing: a burst of 10 gets 2 shots (1 + the 0.1 s credit)")
		eq(Suspicion.total(p), 0, "...and one burst is not reported (it looks like a lag spike)")
		-- the harshest honest pattern: delays alternate +57 / -40 ms (the whole jitter range) for 30 s
		local h = shooter("FRJitter", 491, vec(0, 5, 0), "Mg")
		local hd = PlayerData.get(h)
		local lastArrival = 0
		for k = 1, 300 do
			local arrival = (k - 1) * 0.1 + (if k % 2 == 0 then 0.057 else -0.04)
			shoot(h, nil, nil, if k == 1 then 1 else arrival - lastArrival)
			lastArrival = arrival
		end
		eq(2000 - hd.mags.Mg, 300, "honest fire at the rpm with the full +-40 ms + frame jitter range, alternating: all 300 accepted")
		eq(Suspicion.total(h), 0, "...and nothing reported")
		Weapons.Defs.Mg = nil
	end

	section("Integration / combat: extreme weapon definitions (30 rpm with a 1-round magazine, 12 pellets)")
	do
		Config.PVP = false
		Weapons.Defs.Slow = {
			name = "SLOW", slot = 5, mode = "semi", damage = 50, headshotMultiplier = 3, pellets = 1, rpm = 30,
			magazine = 1, reserveMax = 3, startReserve = 2, reloadTime = 0.5, range = 100, spread = 0, recoil = 0, color = {},
		}
		Weapons.Defs.Spray = {
			name = "SPRAY", slot = 6, mode = "auto", damage = 5, headshotMultiplier = 2, pellets = 12, rpm = 120,
			magazine = 3, reserveMax = 9, startReserve = 6, reloadTime = 1, range = 80, spread = 8, recoil = 1, color = {},
		}
		local s = shooter("XS", 440, vec(0, 5, 0), "Slow")
		local dataS = PlayerData.get(s)
		local m, hum, head, torso = dummyOf("SlowDummy")
		rayHits(torso)
		eq(dataS.mags.Slow, 1, "a 1-round magazine")
		shoot(s)
		eq(hum.Health, 50, "the 1-round weapon fires its round")
		eq(dataS.mags.Slow, 0, "...and the magazine is empty")
		local sus = Suspicion.total(s)
		shoot(s, nil, nil, 0.1)
		eq(Suspicion.total(s), sus, "firing on an empty magazine is not suspicious")
		check(lastFor(ammoR, s)[2] == 0, "...the client is told the real (empty) magazine")
		reloadR.OnServerEvent:fire(s)
		advance(0.6)
		eq(dataS.mags.Slow, 1, "a reload fills the 1-round magazine")
		eq(dataS.reserve.Slow, 1, "...from the reserve")
		shoot(s, nil, nil, 0.8) -- 1.5 s after the first shot; 30 rpm = 2 s, 80% = 1.6 s
		eq(dataS.mags.Slow, 1, "30 rpm: a shot 1.5 s after the last is too fast")
		eq(Suspicion.total(s), sus, "...refused quietly (one refusal is not reported)")
		shoot(s, nil, nil, 0.3)
		eq(dataS.mags.Slow, 0, "30 rpm: a shot 1.8 s after the last is accepted")

		local sp = shooter("XP", 441, vec(0, 5, 0), "Spray")
		local dataP = PlayerData.get(sp)
		local m2, hum2, head2, torso2 = dummyOf("SprayDummy")
		rayHits(torso2)
		rayCalls = {}
		shoot(sp)
		eq(#rayCalls, 12, "12 pellets: 12 rays")
		eq(hum2.Health, 40, "12 pellets x 5 damage = 60 off a 100 health dummy")
		eq(lastFor(hitR, sp)[1], 60, "...HitConfirm 60 (one hit per trigger pull)")
		eq(dataP.mags.Spray, 2, "...one round spent for the whole blast")
		Weapons.Defs.Slow = nil
		Weapons.Defs.Spray = nil
	end

	section("Integration / combat: tagged NPC is hit, untagged NPC is not; accessory Handle is body damage")
	do
		Config.PVP = true
		local a = shooter("NA", 445)
		local dataA = PlayerData.get(a)
		local m, hum, head, torso = dummyOf("TaggedNpc")
		local npc = new("Model", "UntaggedNpc")
		local nh = child(npc, new("Humanoid")); nh.Health = 100; nh.MaxHealth = 100
		local nhead = child(npc, new("Part", "Head"))
		child(npc, new("Part", "Torso"))
		npc.Parent = Workspace
		rayHits(torso)
		shoot(a)
		eq(hum.Health, 80, "a tagged NPC takes damage")
		rayHits(nhead)
		local confirms = countFor(hitR, a)
		shoot(a)
		eq(nh.Health, 100, "an untagged NPC (a Humanoid without the target tag) takes none")
		eq(countFor(hitR, a), confirms, "...and the shooter is not told of a hit")

		local b, cb = shooter("NB", 446, vec(0, 5, -10))
		local hat = new("Accessory", "Hat")
		local handle = child(hat, new("Part", "Handle"))
		hat.Parent = cb
		rayHits(handle)
		shoot(a)
		eq(cb.Humanoid.Health, 80, "a hit on an accessory Handle is body damage (20), not a headshot (40)")
		eq(lastFor(hitR, a)[2], false, "...HitConfirm says no headshot")
		rayHits(cb.Head)
		shoot(a)
		eq(cb.Humanoid.Health, 40, "(control) the Head itself is a headshot")
		Config.PVP = false
	end

	section("Integration / combat: seated shooters, a NaN head, and a muzzle far from the head")
	do
		Config.PVP = false
		local a, ca = shooter("SE", 450)
		local dataA = PlayerData.get(a)
		local m, hum, head, torso = dummyOf("SeatDummy")
		rayHits(torso)
		rayCalls = {}
		local flagsBefore = Suspicion.total(a)
		ca.Humanoid.SeatPart = {}
		shoot(a, vec(0, 5, -60)) -- the vehicle's muzzle ran 60 studs ahead
		eq(Suspicion.total(a), flagsBefore, "seated: a muzzle 60 studs from the head raises no 'origin' flag")
		local ray = rayCalls[#rayCalls]
		check(ray.origin.X == 0 and ray.origin.Y == 5 and ray.origin.Z == 0, "...the shot still starts at the head")
		eq(hum.Health, 80, "...and still hits")

		ca.Humanoid.SeatPart = nil
		rayCalls = {}
		shoot(a, vec(0, 5, -60))
		eq(Suspicion.total(a), flagsBefore + 1, "not seated: the same muzzle IS flagged")
		eq(lastFor(rejR, a)[1], "origin", "...as 'origin'")
		ray = rayCalls[#rayCalls]
		check(ray.origin.X == 0 and ray.origin.Z == 0, "...and the shot starts at the head too")

		-- The muzzle is used up to ORIGIN_SLACK (8) from the head; a moving shooter's muzzle may also run
		-- ahead along its velocity (the server's view of the head lags). Further out the shot starts at
		-- the head, and only past ORIGIN_FLAG_DISTANCE (16) is it flagged.
		rayMisses() -- (no wall between head and muzzle)
		dataA.mags.Pistol = 15 -- (13 shots below)
		local function originShot(hint, velocity)
			ca.HumanoidRootPart.AssemblyLinearVelocity = velocity or vec(0, 0, 0)
			local before = Suspicion.total(a)
			rayCalls = {}
			shoot(a, hint)
			local o = rayCalls[#rayCalls].origin
			return Suspicion.total(a) - before, if o.X == 0 and o.Y == 5 and o.Z == 0 then "head" else "muzzle"
		end
		local function expect(hint, velocity, flags, from, label)
			local n, at = originShot(hint, velocity)
			eq(n .. " " .. at, flags .. " " .. from, label)
		end
		local run, back, fast = vec(0, 0, -16), vec(0, 0, 16), vec(0, 0, -1000)
		expect(vec(0, 5, -7.5), nil, 0, "muzzle", "standing: a muzzle 7.5 studs from the head is used (long gun, tall avatar)")
		expect(vec(0, 5, -8.5), nil, 0, "head", "standing: 8.5 studs starts at the head, no flag (could be lag)")
		expect(vec(0, 5, -15.5), nil, 0, "head", "standing: 15.5 studs, still no flag")
		expect(vec(0, 5, -16.5), nil, 1, "head", "standing: 16.5 studs IS flagged")
		expect(vec(0, 5, -15), run, 0, "muzzle", "running 16 studs/s: 15 studs ahead along the run is used (8 + 0.5 s lead)")
		expect(vec(0, 5, 9), run, 0, "head", "...9 studs BEHIND the run starts at the head")
		expect(vec(0, 5, 17), run, 1, "head", "...17 behind is flagged")
		expect(vec(17, 5, 0), run, 1, "head", "...17 to the side is flagged")
		expect(vec(0, 5, -9), back, 0, "head", "running the other way: 9 studs ahead of the HEAD is behind the run")
		expect(vec(0, 5, -33), fast, 0, "muzzle", "a huge velocity leads at most 50 studs/s x 0.5 s: 33 ahead is used")
		expect(vec(0, 5, -42), fast, 1, "head", "...42 ahead is flagged (25 + 16)")
		expect(vec(0, 5, -7), vec(0 / 0, 0, 0), 0, "muzzle", "a NaN velocity gives no lead and no error: 7 studs is used")
		expect(vec(0, 5, -17), vec(0 / 0, 0, 0), 1, "head", "...17 studs is flagged")
		ca.HumanoidRootPart.AssemblyLinearVelocity = vec(0, 0, 0)
		rayHits(torso)
		dataA.mags.Pistol = 15

		-- a head position that is not a number: no shot at all (fail closed)
		local mag, health, flags = dataA.mags.Pistol, hum.Health, Suspicion.total(a)
		local realHead = ca.Head.Position
		for label, bad in { NaN = vec(0 / 0, 0 / 0, 0 / 0), inf = vec(math.huge, 5, 0), partlyNaN = vec(0, 0 / 0, 0) } do
			ca.Head.Position = bad
			shoot(a, vec(0, 5, -1))
			eq(dataA.mags.Pistol, mag, "head position " .. label .. ": no round is spent")
			eq(hum.Health, health, "head position " .. label .. ": no damage")
		end
		eq(Suspicion.total(a), flags + 3, "...each refused shot is flagged")
		eq(lastFor(rejR, a)[1], "origin", "...as 'origin'")
		ca.Head.Position = realHead
		shoot(a, vec(0, 5, -1))
		eq(dataA.mags.Pistol, mag - 1, "(control) with the head back where it was, the same request is a normal shot")
	end

	section("Integration / combat: refusals - no save data, no weapon, no head, aim snaps, a player who left")
	do
		Config.PVP = false
		local m, hum, head, torso = dummyOf("RefuseDummy")
		rayHits(torso)
		-- save data that never loaded
		local noData = track(makePlayer("RN", 460))
		noData.Neutral = true
		fakeStore.intercept = function(key) if key == "Player_460" then return true, nil end return false end
		Players.PlayerAdded:fire(noData)
		fakeStore.intercept = nil
		local cn = makeCharacter(noData, vec(0, 5, 0))
		cn.Parent = Workspace
		local tool = new("Tool", "Pistol"); tool.Parent = cn
		eq(PlayerData.get(noData), nil, "(setup) this player's save data never loaded")
		local ammoSent = #ammoR.fired
		shoot(noData)
		reloadR.OnServerEvent:fire(noData)
		eq(hum.Health, 100, "no save data: a shot does nothing")
		eq(#ammoR.fired, ammoSent, "...a reload does nothing")
		eq(WeaponServer.restock(noData), false, "...and the ammo crate cannot restock him")
		eq(Suspicion.total(noData), 0, "...and none of it is suspicious")

		-- no weapon in hand
		local unarmed, cu, toolU = shooter("RU", 461)
		local dataU = PlayerData.get(unarmed)
		toolU.Parent = nil
		ammoSent = #ammoR.fired
		shoot(unarmed)
		reloadR.OnServerEvent:fire(unarmed)
		eq(hum.Health, 100, "nothing in hand: a shot does nothing")
		eq(#ammoR.fired, ammoSent, "...a reload does nothing")
		eq(dataU.mags.Pistol, 15, "...and no round is spent")

		-- neither a Head nor a HumanoidRootPart
		local headless, ch = shooter("RH", 462)
		local dataH = PlayerData.get(headless)
		ch.Head.Parent = nil
		ch.HumanoidRootPart.Parent = nil
		shoot(headless)
		eq(hum.Health, 100, "a character with no Head and no root part cannot shoot")
		eq(dataH.mags.Pistol, 15, "...and no round is spent")

		-- aim snaps: the aim jumps 40 degrees between shots 0.25 s apart and every shot hits
		local snapper = shooter("RS", 463)
		local function dirAt(deg) local r = math.rad(deg); return vec(math.sin(r), 0, -math.cos(r)) end
		for i = 1, 6 do shoot(snapper, nil, dirAt(if i % 2 == 0 then 40 else 0), 0.25) end
		check(select(2, Suspicion.total(snapper)).snap ~= nil, "aim snapping between targets and hitting is counted as 'snap'")
		check(hum.Health < 100, "...but the shots were never blocked (the dummy was hit)")

		-- a player who leaves while his reload is running
		local leaver = shooter("RL", 464)
		shoot(leaver)
		reloadR.OnServerEvent:fire(leaver)
		local syncs = countFor(ammoR, leaver)
		leaver.Parent = nil
		advance(3)
		eq(countFor(ammoR, leaver), syncs, "nothing is sent to a player who left while his reload finished")
		leaver.Parent = Players
	end

	-------------------------------------------------------------------------------------- movement
	-- A flat world: the ground at y = 0 (a Part, so the kit can ask what it stands on), extra floor
	-- strips with their own parts (conveyors), no walls.
	local ground = new("Part", "IntGround"); ground.Anchored = true; ground.Parent = Workspace
	local floors = {}
	rayMisses()
	blockHandler = function(cframe, size, dir)
		local bottom = cframe.Position.Y - size.Y / 2 + dir.Y
		if dir.X == 0 and dir.Z == 0 and dir.Y < 0 and bottom <= 0 then
			local x, part = cframe.Position.X, ground
			for _, f in floors do
				if x >= f.minX and x <= f.maxX then part = f.part end
			end
			return { Position = vec(x, 0, cframe.Position.Z), Instance = part }
		end
		return nil
	end
	Workspace.GetPartBoundsInRadius = function() return {} end
	Config.PVP = false

	local nextId = 500
	local function setPos(hrp, x, y, z) -- "the client" moves its own character: no signal
		local v = vec(x, y, z)
		hrp.Position = v
		hrp.CFrame = CFrame.new(x, y, z)
	end
	local function buildCharacter(p, name, opt)
		local c = new("Model", name .. "Char"); c.Parent = Workspace
		local hum = child(c, new("Humanoid"))
		hum.Health = 100; hum.MaxHealth = 100; hum.WalkSpeed = 16; hum.JumpPower = 50; hum.JumpHeight = 7.2
		hum.UseJumpPower = true; hum.RigType = Enum.HumanoidRigType.R15; hum.HipHeight = opt.hip or 2
		local hrp = child(c, new("Part", "HumanoidRootPart"))
		hrp.Size = opt.size or vec(2, 2, 1); hrp.Anchored = false; hrp.CollisionGroup = "Default"
		hrp.AssemblyLinearVelocity = vec(0, 0, 0); hrp.AssemblyAngularVelocity = vec(0, 0, 0)
		setPos(hrp, 0, hrp.Size.Y / 2 + hum.HipHeight, 0)
		if opt.beforeSpawn then opt.beforeSpawn(c, hrp) end
		p.Character = c
		p.CharacterAdded:fire(c)
		return c, hum, hrp
	end
	-- A joined player with a character standing at the origin. opt: hip, size, rank (GetRankInGroup), beforeSpawn.
	local function mover(name, opt)
		opt = opt or {}
		nextId += 1
		local p = track(makePlayer(name, nextId))
		p.Neutral = true
		if opt.rank then p.GetRankInGroup = opt.rank end
		Players.PlayerAdded:fire(p)
		local c, hum, hrp = buildCharacter(p, name, opt)
		return p, c, hum, hrp
	end
	local function frames(seconds, perFrame)
		for _ = 1, math.floor(seconds * 60 + 0.5) do
			advance(1 / 60)
			if perFrame then perFrame(1 / 60) end
			flushSignals() -- deferred signals run before the frame's Heartbeat
			serverWriting = true -- (anything the kit writes during its own step is a server write)
			RunService.Heartbeat:fire()
			serverWriting = false
		end
	end
	local function flags(p, reason)
		local total, reasons = Suspicion.total(p)
		if reason then return reasons[reason] or 0 end
		return total
	end
	local function walk(hrp, speed)
		return function(dt) setPos(hrp, hrp.Position.X + speed * dt, hrp.Position.Y, hrp.Position.Z) end
	end
	local function settle(p, c, hum, hrp) frames(2.5) end -- past the spawn grace
	-- A mover the way a game script makes one that really pushes: a constraint mover enabled, with an
	-- Attachment0 in the root (a VectorForce also gets a force); a Body mover with a non-zero force.
	-- `into` is where the mover itself goes (default: the root).
	local function pushingMover(class, root, into)
		local mv = new(class)
		if class == "BodyVelocity" or class == "BodyPosition" then
			mv.MaxForce = vec(4000, 4000, 4000)
			if class == "BodyVelocity" then mv.Velocity = vec(80, 0, 0) end
		elseif class == "RocketPropulsion" then
			mv.MaxThrust = 4000; mv.MaxSpeed = 80
		elseif class == "BodyForce" or class == "BodyThrust" then
			mv.Force = vec(0, 500, 0)
		else
			local att = new("Attachment"); att.Parent = root
			mv.Attachment0 = att; mv.Enabled = true
			-- the defaults a new instance has in Studio (read there 2026-10-10)
			if class == "VectorForce" then
				mv.Force = vec(1000, 0, 0)
			elseif class == "LineForce" then
				mv.Magnitude = 1000
				local far = new("Attachment"); far.Parent = Workspace
				mv.Attachment1 = far
			elseif class == "LinearVelocity" then
				mv.ForceLimitsEnabled = true; mv.ForceLimitMode = Enum.ForceLimitMode.Magnitude; mv.MaxForce = 1000
				mv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector; mv.RelativeTo = Enum.ActuatorRelativeTo.World
				mv.VectorVelocity = vec(80, 0, 0) -- (a dash: the default is 0, 0, 0)
			elseif class == "AlignPosition" then
				mv.RigidityEnabled = false; mv.ForceLimitMode = Enum.ForceLimitMode.Magnitude; mv.MaxForce = 10000
				mv.MaxVelocity = math.huge
			end
		end
		mv.Parent = into or root
		return mv
	end

	local function trustSuite(mode, deferred)
		deferSignals = deferred
		local m = mode .. ": "
		section("Integration / movement (" .. mode .. " signals): server moves are trusted, client moves are not")

		-- an admin :bring / a script PivotTo, 8 studs and 500 studs
		local p, c, h, r = mover("T1" .. mode)
		settle(p, c, h, r)
		frames(1, walk(r, 16))
		c:PivotTo(CFrame.new(r.Position.X + 8, 3, 0))
		frames(2, walk(r, 16))
		eq(flags(p), 0, m .. "a server PivotTo of 8 studs is not flagged")
		eq(c.pivots, 1, m .. "...and the kit did not move him back")
		local before = r.Position.X
		c:PivotTo(CFrame.new(before + 500, 3, 0))
		frames(2, walk(r, 16))
		eq(flags(p), 0, m .. "a server PivotTo of 500 studs is not flagged")
		eq(c.pivots, 2, m .. "...and nobody was moved back")
		local newHome = r.Position.X
		setPos(r, newHome + 120, 3, 0) -- now a CLIENT teleport
		frames(0.5)
		check(flags(p, "teleport") >= 1, m .. "after the server move, a client teleport is still flagged")
		check(r.Position.X > newHome - 40 and r.Position.X < newHome + 40, m .. "...and he is put back near the NEW baseline (x " .. string.format("%.0f", r.Position.X) .. " vs " .. string.format("%.0f", newHome) .. "), not the old one")

		-- Model:MoveTo, root.CFrame = ..., moving a body part: all server writes
		local pm, cm, hm, rm = mover("T2" .. mode)
		settle(pm, cm, hm, rm)
		frames(1, walk(rm, 16))
		cm:MoveTo(vec(rm.Position.X + 300, 3, 0))
		frames(2, walk(rm, 16))
		eq(flags(pm), 0, m .. "Model:MoveTo of 300 studs is not flagged")
		eq(cm.pivots, 1, m .. "...and nobody was moved back")
		local pr, cr, hr, rr = mover("T3" .. mode)
		settle(pr, cr, hr, rr)
		serverSet(rr, "CFrame", CFrame.new(rr.Position.X + 400, 3, 40))
		frames(2, walk(rr, 16))
		eq(flags(pr), 0, m .. "root.CFrame = ... from a server script is not flagged")
		eq(cr.pivots or 0, 0, m .. "...and nobody was moved back")

		-- a client teleport (no signal) is flagged and put back
		local pc, cc, hc, rc = mover("T4" .. mode)
		settle(pc, cc, hc, rc)
		frames(1, walk(rc, 16))
		local home = rc.Position.X
		setPos(rc, home + 700, 3, 0)
		local guard = 0
		while (cc.pivots or 0) == 0 and guard < 60 do frames(1 / 60); guard += 1 end -- (until the kit has seen it)
		check(flags(pc, "teleport") >= 1, m .. "a client teleport is flagged")
		check((cc.pivots or 0) >= 1 and rc.Position.X < home + 100, m .. "...and he is put back")

		-- the kit's OWN rubber-band must never earn the grace a server move gets
		local flagsAfterFirst = flags(pc, "teleport")
		frames(0.75) -- 0.75 s after the snap: the hold (0.6 s) is over; a trusted snap would still be inside its grace
		local home2 = rc.Position.X
		setPos(rc, home2 + 700, 3, 0)
		frames(0.4)
		check(flags(pc, "teleport") > flagsAfterFirst, m .. "the cheater is caught again right after the hold: the kit's own snap is not a trusted server move")
		check((cc.pivots or 0) >= 2, m .. "...and put back again")

		-- a server velocity write: knockback / launch pad / admin fling
		local pv, cv, hv, rv = mover("T5" .. mode)
		settle(pv, cv, hv, rv)
		frames(1, walk(rv, 16))
		serverSet(rv, "AssemblyLinearVelocity", vec(80, 20, 0))
		frames(0.9, walk(rv, 80))
		eq(flags(pv), 0, m .. "a server velocity write (launch pad): 80 studs/s for 0.9 s is not flagged")
		frames(0.8, walk(rv, 80))
		check(flags(pv) >= 1, m .. "...but the same speed once SERVER_PUSH_TIME is over (and he stands) IS flagged (" .. flags(pv) .. ")")
		check((cv.pivots or 0) >= 1, m .. "...and he is put back")

		local pa, ca, ha, ra = mover("T6" .. mode)
		settle(pa, ca, ha, ra)
		serverSet(ra, "AssemblyAngularVelocity", vec(0, 3000, 0)) -- an admin :fling spin
		frames(0.6)
		eq(flags(pa), 0, m .. "a server angular-velocity write (admin fling spin) is not flagged as 'fling'")
		serverSet(ra, "AssemblyAngularVelocity", vec(0, 0, 0))
		frames(1.5)
		eq(flags(pa), 0, m .. "...and neither is the spin stopping again")
		ra.AssemblyAngularVelocity = vec(0, 3000, 0) -- the same spin made by the CLIENT: a plain field change
		frames(0.5)
		check(flags(pa, "fling") >= 1, m .. "a client-made spin is still flagged 'fling'")
		eq(ra.AssemblyAngularVelocity.Magnitude, 0, m .. "...and the snap zeroes it")
		deferSignals = false
		flushSignals()
	end
	trustSuite("immediate", false)
	trustSuite("deferred", true)

	section("Integration / movement: TRUST_SERVER_MOVES = false - only the explicit API tells the checks")
	do
		L.TRUST_SERVER_MOVES = false
		local p, c, h, r = mover("NT1")
		settle(p, c, h, r)
		frames(1, walk(r, 16))
		c:PivotTo(CFrame.new(r.Position.X + 300, 3, 0))
		frames(0.5)
		check(flags(p, "teleport") >= 1, "trust off: a plain server PivotTo is flagged like any teleport")
		local p2, c2, h2, r2 = mover("NT2")
		settle(p2, c2, h2, r2)
		eq(Movement.allowTeleport(p2, CFrame.new(300, 3, 0)), true, "trust off: Movement.allowTeleport still works")
		frames(2, walk(r2, 16))
		eq(flags(p2), 0, "...and is not flagged")
		serverSet(r2, "AssemblyLinearVelocity", vec(80, 0, 0))
		frames(0.9, walk(r2, 80))
		check(flags(p2) >= 1, "trust off: a server velocity write earns no grace")
		local p3, c3, h3, r3 = mover("NT3")
		settle(p3, c3, h3, r3)
		pushingMover("BodyVelocity", r3)
		frames(1.5, walk(r3, 80))
		check(flags(p3) >= 1, "trust off: a server mover does not switch the checks off")
		L.TRUST_SERVER_MOVES = savedConfig.TRUST_SERVER_MOVES
	end

	section("Integration / movement: server-made movers - a speed is allowed, a force switches the checks off")
	do
		-- BodyVelocity / RocketPropulsion / LinearVelocity drive at 80 studs/s here (pushingMover); the others push
		-- with a force the kit cannot turn into a speed
		local SPEED_MOVERS = { BodyVelocity = true, RocketPropulsion = true, LinearVelocity = true }
		local classes = { "BodyVelocity", "BodyPosition", "BodyForce", "BodyThrust", "RocketPropulsion", "LinearVelocity", "VectorForce", "AlignPosition", "LineForce" }
		for _, class in classes do
			local p, c, h, r = mover("M" .. class)
			settle(p, c, h, r)
			frames(1, walk(r, 16))
			local mv = pushingMover(class, r)
			frames(2, walk(r, 80))
			eq(flags(p), 0, class .. " in the character: 80 studs/s for 2 s is not flagged")
			eq(c.pivots or 0, 0, class .. ": nobody is moved back")
			mv.Parent = nil
			frames(0.8, walk(r, 80))
			eq(flags(p), 0, class .. " removed: " .. (if SPEED_MOVERS[class] then "its push carries on" else "RELEASE_GRACE covers") .. " the next 0.8 s")
			frames(1.2, walk(r, 80))
			check(flags(p) >= 1, class .. ": after that the same speed is flagged")
		end

		-- two movers: judged again only after the last one is gone
		local p, c, h, r = mover("MTwo")
		settle(p, c, h, r)
		local a, b = pushingMover("LinearVelocity", r), pushingMover("AlignPosition", r, c)
		a.Parent = nil
		frames(2, walk(r, 80))
		eq(flags(p), 0, "two movers, one removed: still not judged")
		b.Parent = nil
		frames(2.5, walk(r, 80))
		check(flags(p) >= 1, "...judged once the last one is gone and the grace ran out")

		-- a mover inside a Tool that is equipped later
		local pt, ct, ht, rt = mover("MTool")
		settle(pt, ct, ht, rt)
		local tool = new("Tool", "Jetpack"); local handle = new("Part", "Handle"); handle.Parent = tool
		pushingMover("BodyForce", rt, handle)
		tool.Parent = ct
		frames(2, walk(rt, 80))
		eq(flags(pt), 0, "a mover inside an equipped Tool counts (the whole subtree is noticed)")
		tool.Parent = nil
		frames(2.5, walk(rt, 80))
		check(flags(pt) >= 1, "...and the Tool going away takes it with it")

		-- a mover already in the character at spawn
		local ps, cs, hs, rs = mover("MSpawn", { beforeSpawn = function(c, hrp) pushingMover("LinearVelocity", hrp) end })
		settle(ps, cs, hs, rs)
		frames(2, walk(rs, 80))
		eq(flags(ps), 0, "a mover that is already in the character at spawn counts")

		-- movers that do not move the character's position do not count
		local pg, cg, hg, rg = mover("MGyro")
		settle(pg, cg, hg, rg)
		local gyro = new("BodyGyro"); gyro.Parent = rg
		frames(1.5, walk(rg, 80))
		check(flags(pg) >= 1, "a BodyGyro (it only turns) does not switch the checks off")

		-- a mover that lives for 0.1 s between two samples: its displacement is covered
		local pq, cq, hq, rq = mover("MQuick")
		settle(pq, cq, hq, rq)
		local quick = pushingMover("BodyVelocity", rq)
		quick.Velocity = vec(200, 0, 0)
		frames(0.1, walk(rq, 200))
		quick.Parent = nil
		frames(0.3, walk(rq, 16))
		eq(flags(pq), 0, "a knockback BodyVelocity that came and went within one sample interval leaves no flag")

		-- movers that push nothing must NOT switch the checks off (left in a character, they would for good)
		local idle = {
			{ "LinearVelocity Enabled = false", function(r) local m = pushingMover("LinearVelocity", r); m.Enabled = false end },
			{ "LinearVelocity without an Attachment0", function(r) local m = pushingMover("LinearVelocity", r); m.Attachment0 = nil end },
			{ "AlignPosition on an attachment outside the character", function(r)
				local m = pushingMover("AlignPosition", r)
				local elsewhere = new("Part", "Elsewhere"); elsewhere.Parent = Workspace
				m.Attachment0.Parent = elsewhere
			end },
			{ "VectorForce with a zero Force", function(r) local m = pushingMover("VectorForce", r); m.Force = vec(0, 0, 0) end },
			{ "BodyVelocity with a zero MaxForce", function(r) local m = pushingMover("BodyVelocity", r); m.MaxForce = vec(0, 0, 0) end },
			{ "BodyForce with a zero Force", function(r) local m = pushingMover("BodyForce", r); m.Force = vec(0, 0, 0) end },
			{ "RocketPropulsion with MaxThrust 0", function(r) local m = pushingMover("RocketPropulsion", r); m.MaxThrust = 0 end },
			{ "BodyVelocity parented to the Model (not a part)", function(r) pushingMover("BodyVelocity", r, r.Parent) end },
			{ "LinearVelocity with MaxForce 0", function(r) local m = pushingMover("LinearVelocity", r); m.MaxForce = 0 end },
			{ "AlignPosition with MaxForce 0", function(r) local m = pushingMover("AlignPosition", r); m.MaxForce = 0 end },
			{ "LineForce with Magnitude 0", function(r) local m = pushingMover("LineForce", r); m.Magnitude = 0 end },
			{ "LineForce without an Attachment1", function(r) local m = pushingMover("LineForce", r); m.Attachment1 = nil end },
		}
		-- ...while these still push (and are not judged)
		local pushing = {
			{ "LinearVelocity without force limits, MaxForce 0", function(r)
				local m = pushingMover("LinearVelocity", r); m.ForceLimitsEnabled = false; m.MaxForce = 0
			end },
			{ "LinearVelocity, per-axis limit, MaxForce 0", function(r)
				local m = pushingMover("LinearVelocity", r); m.ForceLimitMode = Enum.ForceLimitMode.PerAxis; m.MaxForce = 0
			end },
			{ "rigid AlignPosition, MaxForce 0", function(r)
				local m = pushingMover("AlignPosition", r); m.RigidityEnabled = true; m.MaxForce = 0
			end },
			{ "LineForce pulling (negative Magnitude)", function(r) local m = pushingMover("LineForce", r); m.Magnitude = -500 end },
		}
		for i, case in pushing do
			local pi, ci, hi, ri = mover("MPush" .. i)
			settle(pi, ci, hi, ri)
			case[2](ri)
			frames(1.5, walk(ri, 80))
			eq(flags(pi), 0, "a pushing mover counts: " .. case[1])
		end
		for i, case in idle do
			local pi, ci, hi, ri = mover("MIdle" .. i)
			settle(pi, ci, hi, ri)
			case[2](ri)
			frames(1.5, walk(ri, 80))
			check(flags(pi) >= 1, "an idle mover does not switch the checks off: " .. case[1])
		end

		-- a mover switched off (not removed): RELEASE_GRACE, then judged again
		local po, co, ho, ro = mover("MOff")
		settle(po, co, ho, ro)
		local lv = pushingMover("LinearVelocity", ro)
		frames(2, walk(ro, 80))
		eq(flags(po), 0, "an enabled LinearVelocity: 80 studs/s is not flagged")
		lv.Enabled = false
		frames(0.8, walk(ro, 80))
		eq(flags(po), 0, "...switched off: its push carries on for the next 0.8 s")
		frames(1.2, walk(ro, 80))
		check(flags(po) >= 1, "...then the same speed is flagged although the mover is still in the character")
	end

	section("Integration / movement: only ISOLATED server writes are trusted (a script writing every frame is not)")
	do
		-- a server "face the target" loop rewrites the root's CFrame every frame where the client put it,
		-- while the client speed-hacks: before the fix every write re-anchored the checks (never flagged)
		local p, c, h, r = mover("BFace")
		settle(p, c, h, r)
		local warnsBefore = warnsAbout("not trusted")
		frames(3, function(dt)
			setPos(r, r.Position.X + 80 * dt, 3, 0)
			serverSet(r, "CFrame", CFrame.new(r.Position.X, 3, 0))
		end)
		check(flags(p) >= 1, "a server script writing the root every frame does not hide a speed hack (" .. flags(p) .. " flags)")
		eq(warnsAbout("not trusted") - warnsBefore, 1, "...and the developer is warned once")
		check(warnsAbout("allowTeleport") >= 1, "...with what to use instead")

		-- the same with velocity written every frame (a server "push" loop)
		local pv, cv, hv, rv = mover("BPush")
		settle(pv, cv, hv, rv)
		local k = 0
		frames(3, function(dt)
			k += 1
			setPos(rv, rv.Position.X + 80 * dt, 3, 0)
			serverSet(rv, "AssemblyLinearVelocity", vec(1 + k % 2, 0, 0))
		end)
		check(flags(pv) >= 1, "a server script writing velocity every frame does not hide a speed hack either")

		-- the grace the burst's first writes gave is taken back: a teleport right after is caught fast
		local pg, cg, hg, rg = mover("BRevoke")
		settle(pg, cg, hg, rg)
		local n = 0
		frames(0.1, function()
			n += 1
			serverSet(rg, "CFrame", CFrame.new(rg.Position.X, 3, 0))
			if n == 3 then setPos(rg, rg.Position.X + 120, 3, 0) end -- (the client, right after)
		end)
		frames(0.6)
		check(flags(pg, "teleport") >= 1, "a client teleport 3 frames into a write burst is flagged within 0.7 s (the burst gave no time off)")

		-- isolated writes stay trusted; distrust ends after SERVER_WRITE_DISTRUST; allowTeleport always works
		local pi, ci, hi, ri = mover("BIso")
		settle(pi, ci, hi, ri)
		ci:PivotTo(CFrame.new(200, 3, 0)); frames(0.6)
		ci:PivotTo(CFrame.new(400, 3, 0)); frames(2)
		eq(flags(pi), 0, "two server moves 0.6 s apart are both trusted")
		frames(0.1, function() serverSet(ri, "CFrame", CFrame.new(ri.Position.X, 3, 0)) end) -- a burst
		frames(1)
		eq(Movement.allowTeleport(pi, CFrame.new(900, 3, 0)), true, "during the distrust...")
		frames(2)
		eq(flags(pi), 0, "...Movement.allowTeleport still works")
		frames(5)
		ci:PivotTo(CFrame.new(1300, 3, 0)); frames(2)
		eq(flags(pi), 0, "after SERVER_WRITE_DISTRUST an isolated server move is trusted again")
		eq(ci.pivots, 4, "...and nobody was moved back (3 game moves + allowTeleport)")

		-- writes to an anchored root (a cutscene) or a seated character (a ride) are not counted
		local pa, ca, ha, ra = mover("BCut")
		settle(pa, ca, ha, ra)
		ra.Anchored = true
		frames(1, function() serverSet(ra, "CFrame", CFrame.new(ra.Position.X + 1, 3, 0)) end)
		ra.Anchored = false
		frames(1.5)
		ca:PivotTo(CFrame.new(ra.Position.X + 300, 3, 0)); frames(2, walk(ra, 16))
		eq(flags(pa), 0, "a cutscene moving an anchored root every frame does not make the next server move untrusted")
		local seat = new("Part", "Seat"); seat.Parent = Workspace
		ha.SeatPart = seat
		frames(1, function() serverSet(ra, "CFrame", CFrame.new(ra.Position.X + 1, 3, 0)) end)
		ha.SeatPart = nil
		frames(1.5)
		ca:PivotTo(CFrame.new(ra.Position.X + 300, 3, 0)); frames(2, walk(ra, 16))
		eq(flags(pa), 0, "a ride moving a seated character every frame does not either")
	end

	section("Integration / movement: a server move in the same frame as the sample is never undone")
	do
		-- A game Heartbeat handler that runs BEFORE the kit's and moves the player; with deferred signals its
		-- CFrame signal reaches the kit only after the kit sampled the moved character. The kit must judge
		-- one frame later, when the signal has arrived, and keep the game's move.
		deferSignals = true
		local p, c, h, r = mover("Race")
		settle(p, c, h, r)
		local moveNow, justMoved, races = false, false, 0
		local function game()
			if moveNow then
				moveNow = false
				c:PivotTo(CFrame.new(r.Position.X + 40, 3, 0))
				justMoved = true
			end
		end
		table.insert(RunService.Heartbeat.handlers, 1, game)
		local savedBlock = blockHandler
		blockHandler = function(cframe, size, dir, params)
			if justMoved and params.FilterDescendantsInstances[1] == c then races += 1 end
			return savedBlock(cframe, size, dir, params)
		end
		for _ = 1, 12 do -- 12 phases of the 12-frame sample cycle: one of them lands on the sample frame
			moveNow = true
			frames(1 / 60)
			justMoved = false
			frames(2, walk(r, 16)) -- (121 frames per round: the move shifts one frame against the cycle)
		end
		table.remove(RunService.Heartbeat.handlers, table.find(RunService.Heartbeat.handlers, game))
		blockHandler = savedBlock
		check(races >= 1, "the kit sampled a character in the very frame a game script moved it (" .. races .. "x)")
		eq(flags(p), 0, "...and flagged nothing")
		eq(c.pivots, 12, "...and never moved him back (12 game moves, 0 snaps)")
		deferSignals = false
		flushSignals()
	end

	section("Integration / movement: server moves and pushes are an allowance, never time off")
	do
		-- (each was a hole while server moves earned a grace: 1-1.5 s unjudged, and the spot accepted as clean)
		local function every(period, fn) -- calls fn every `period` seconds of a frames() run
			local t = 0
			return function(dt)
				t += dt
				if t >= period then t -= period; fn() end
			end
		end
		local function both(a, b) return function(dt) a(dt); b(dt) end end
		local function throw(r, v, y0) -- an honest body thrown up at v from height y0, landing on the floor (y 3)
			local t = 0
			return function(dt)
				t += dt
				setPos(r, r.Position.X, math.max(3, y0 + v * t - 98.1 * t * t), 0)
			end
		end

		do -- a server move is not time off: a speed hack right after it is judged
			local p, c, h, r = mover("A1")
			settle(p, c, h, r)
			c:PivotTo(CFrame.new(r.Position.X + 40, 3, 0))
			frames(1.2, walk(r, 80))
			check(flags(p) >= 1, "a speed hack right after a server move is caught within 1.2 s (" .. flags(p) .. " flags)")
		end

		do -- the spot is not laundered: a client teleport, then a server turn (same place) 3 frames later,
			-- 12 tries, one per phase of the sample cycle: every one is flagged and put back
			local p, c, h, r = mover("A2")
			settle(p, c, h, r)
			local home = r.Position.X
			for _ = 1, 12 do
				setPos(r, r.Position.X + 60, 3, 0) -- the client
				frames(3 / 60)
				serverSet(r, "CFrame", CFrame.new(r.Position.X, 3, 0)) -- the game turns him where he stands
				frames(1.5 + 1 / 60)
			end
			eq(flags(p, "teleport"), 12, "a server turn right after a client teleport does not make the spot clean (12 of 12 phases flagged)")
			check(math.abs(r.Position.X - home) < 5, "...and he ends where he started (x " .. string.format("%.0f", r.Position.X - home) .. " from home)")
		end

		do -- a SLOW face-the-target loop (under 2 writes/s, trusted every time) hides neither a speed hack nor a hover
			local p, c, h, r = mover("A3")
			settle(p, c, h, r)
			frames(4, both(walk(r, 60), every(0.55, function() serverSet(r, "CFrame", CFrame.new(r.Position.X, 3, 0)) end)))
			check(flags(p) >= 1, "a server script turning the player every 0.55 s does not hide a speed hack (" .. flags(p) .. " flags)")
			local p2, c2, h2, r2 = mover("A4")
			settle(p2, c2, h2, r2)
			frames(4, both(function() setPos(r2, r2.Position.X, 9, 0) end, every(0.55, function() serverSet(r2, "CFrame", CFrame.new(r2.Position.X, 9, 0)) end)))
			check(flags(p2, "fly") >= 1, "...nor a hover 6 studs up (" .. flags(p2, "fly") .. " fly flags)")
		end

		do -- a dash the player sets off himself (server CFrame +8 every 0.55 s) does not cover a speed hack in between
			local p, c, h, r = mover("A5")
			settle(p, c, h, r)
			frames(4, both(walk(r, 60), every(0.55, function() serverSet(r, "CFrame", CFrame.new(r.Position.X + 8, 3, 0)) end)))
			check(flags(p) >= 1, "a self-triggered server dash every 0.55 s does not hide a speed hack (" .. flags(p) .. " flags)")
			local p2, c2, h2, r2 = mover("A5b")
			settle(p2, c2, h2, r2)
			frames(4, both(walk(r2, 16), every(0.55, function() serverSet(r2, "CFrame", CFrame.new(r2.Position.X + 8, 3, 0)) end)))
			eq(flags(p2), 0, "...while an honest walker using the same dash is never flagged")
			eq(c2.pivots or 0, 0, "...nor moved back")
		end

		do -- a push allows what it gave, no more
			local p, c, h, r = mover("A6")
			settle(p, c, h, r)
			serverSet(r, "AssemblyLinearVelocity", vec(30, 0, 0))
			frames(0.9, walk(r, 120))
			check(flags(p) >= 1, "a 30 studs/s knockback does not cover running at 120 (" .. flags(p) .. " flags)")
		end

		do -- launch pad straight up at 100: the honest throw is clean, hanging at its top is not
			local p, c, h, r = mover("A7")
			settle(p, c, h, r)
			serverSet(r, "AssemblyLinearVelocity", vec(0, 100, 0))
			frames(2, throw(r, 100, 3))
			eq(flags(p), 0, "a launch pad (100 studs/s up): the honest 25-stud throw and landing are clean")
			frames(1.5)
			serverSet(r, "AssemblyLinearVelocity", vec(0, 100, 0))
			frames(0.5, throw(r, 100, 3))
			local top = r.Position.Y
			frames(2, function() setPos(r, r.Position.X, top, 0) end)
			check(flags(p, "fly") >= 1, "...but hanging at the top of it is flagged fly (" .. flags(p, "fly") .. ")")
			frames(3, function() setPos(r, r.Position.X, 3, 0) end) -- (back down)
			serverSet(r, "AssemblyLinearVelocity", vec(0, 100, 0))
			local t = 0
			frames(0.4, function(dt) t += dt; setPos(r, r.Position.X, 3 + 200 * t, 0) end) -- 80 studs up at 200 studs/s
			check(flags(p, "jump") >= 1, "...and rising twice as fast as the pad throws is flagged jump (" .. flags(p, "jump") .. ")")
		end

		do -- a mover that lifts at 20 studs/s: an honest climb and fall are clean, climbing at 60 is not
			local function lifter(r, vy)
				local mv = pushingMover("LinearVelocity", r)
				mv.VectorVelocity = vec(0, vy, 0)
				return mv
			end
			local p, c, h, r = mover("A8")
			settle(p, c, h, r)
			local lift = lifter(r, 20)
			frames(2, function(dt) setPos(r, r.Position.X, r.Position.Y + 20 * dt, 0) end)
			lift.Parent = nil
			frames(3, throw(r, 20, r.Position.Y))
			eq(flags(p), 0, "a LinearVelocity lifting at 20 studs/s: the honest 40-stud climb, release and fall are clean")
			local p2, c2, h2, r2 = mover("A9")
			settle(p2, c2, h2, r2)
			lifter(r2, 20)
			frames(1.5, function(dt) setPos(r2, r2.Position.X, r2.Position.Y + 60 * dt, 0) end)
			check(flags(p2) >= 1, "...but climbing at 60 with it is flagged (" .. flags(p2) .. ")")
		end

		do -- a dash mover at 80 does not cover running at 200
			local p, c, h, r = mover("A10")
			settle(p, c, h, r)
			pushingMover("LinearVelocity", r)
			frames(1, walk(r, 200))
			check(flags(p) >= 1, "a LinearVelocity dash at 80 does not cover running at 200 (" .. flags(p) .. " flags)")
		end

		do -- getting out of a seat: the seat's speed carries on, nothing else does
			local ride = new("Part", "Ride"); ride.Parent = Workspace
			ride.AssemblyLinearVelocity = vec(60, 0, 0)
			local p, c, h, r = mover("A11")
			settle(p, c, h, r)
			h.SeatPart = ride
			frames(1, walk(r, 60))
			h.SeatPart = nil
			frames(0.5, walk(r, 60))
			frames(1.5)
			eq(flags(p), 0, "jumping off a ride at 60 studs/s: carried on for a moment, not flagged")
			local chair = new("Part", "Chair"); chair.Parent = Workspace
			local p2, c2, h2, r2 = mover("A12")
			settle(p2, c2, h2, r2)
			h2.SeatPart = chair
			frames(1)
			h2.SeatPart = nil
			frames(0.9, walk(r2, 80))
			check(flags(p2) >= 1, "getting off a chair is not time off: a speed hack right after is caught within 0.9 s")
		end

		do -- an anchored root let go: a hold while the client catches up, then judged
			local p, c, h, r = mover("A13")
			settle(p, c, h, r)
			r.Anchored = true
			frames(1)
			r.Anchored = false
			frames(1 / 60)
			setPos(r, r.Position.X + 100, 3, 0)
			frames(1)
			check(flags(p, "teleport") >= 1, "a teleport right after being unfrozen is caught within 1 s")
		end
	end

	section("Integration / movement: a grace or exemption given right after the sample wins")
	do
		-- The client dashes, the kit samples it in that frame and flags it, and a game Heartbeat handler that
		-- runs AFTER the kit's (the RemoteEvent that starts the dash) gives a grace or exempts the player in
		-- the same frame. The flag is judged one frame later and must honour it: no flag, no snap.
		local function run(name, excuse)
			local p, c, h, r = mover(name)
			settle(p, c, h, r)
			local dashed, sampled = false, false
			local savedBlock = blockHandler
			blockHandler = function(cframe, size, dir, params)
				if dashed and params.FilterDescendantsInstances[1] == c then sampled = true end
				return savedBlock(cframe, size, dir, params)
			end
			local excused = false
			local function game()
				if sampled and not excused then
					excused = true
					if excuse then excuse(p) end
				end
			end
			table.insert(RunService.Heartbeat.handlers, game)
			local pivotsBefore = c.pivots or 0
			frames(1 / 60, function()
				setPos(r, r.Position.X + 60, 3, 0) -- (the client)
				dashed = true
			end)
			frames(1, walk(r, 16))
			table.remove(RunService.Heartbeat.handlers, table.find(RunService.Heartbeat.handlers, game))
			blockHandler = savedBlock
			Movement.exempt(p, false)
			return excused, flags(p), (c.pivots or 0) - pivotsBefore
		end
		local sampled, n, snaps = run("GraceRaceControl", nil)
		check(sampled and n >= 1 and snaps >= 1, "(control) the 60-stud dash is sampled, flagged and snapped back (" .. n .. " flags, " .. snaps .. " snaps)")
		sampled, n, snaps = run("GraceRace", function(p) Movement.grace(p, 2) end)
		check(sampled, "the grace came in the frame of the flagged sample")
		eq(n + snaps, 0, "Movement.grace given right after the sample: no flag, no snap")
		sampled, n, snaps = run("ExemptRace", function(p) Movement.exempt(p, true) end)
		eq(n + snaps, 0, "Movement.exempt right after the sample: no flag, no snap")
	end


	section("Integration / movement: moving ground - conveyors and platforms (pure maths)")
	do
		local function newState() return Movement.newState(vec(0, 3, 0), 0) end
		local function sample(t, x, over)
			local s = { time = t, position = vec(x, 3, 0), walkSpeed = 16, jumpHeight = 7.2, gravity = 196.2, ping = 0.05,
				grounded = true, climbing = false, swimming = false, seated = false, angularSpeed = 0, linearSpeed = 0 }
			if over then for k, v in over do s[k] = v end end
			return s
		end
		local function run(state, samples)
			for _, s in samples do
				local v = Movement.evaluate(state, s, L)
				if #v > 0 then return v[1].reason end
			end
			return ""
		end
		-- a player moving `speed` studs/s over the ground for `seconds`, on a floor that moves `floorSpeed`
		local function belt(speed, floorSpeed, seconds)
			local out = {}
			for i = 1, seconds * 5 do
				table.insert(out, sample(i * 0.2, speed * i * 0.2, { groundSpeed = floorSpeed }))
			end
			return out
		end
		eq(run(newState(), belt(46, 30, 6)), "", "walking 16 on a 30 studs/s conveyor (46 over the ground) is clean")
		eq(run(newState(), belt(46, 0, 6)), "speed", "the same 46 studs/s on still ground is flagged speed")
		eq(run(newState(), belt(16, 0, 6)), "", "(control) plain walking on still ground is clean")
		eq(run(newState(), belt(400, 1e6, 3)), "teleport", "a belt claiming 1,000,000 studs/s is capped at GROUND_SPEED_CAP (" .. L.GROUND_SPEED_CAP .. "): 400 studs/s is still flagged")
		eq(run(newState(), belt(166, 1e6, 6)), "", "...166 studs/s (the cap + a walk) is the most a capped belt can excuse")
		eq(run(newState(), belt(190, 1e6, 6)), "speed", "...190 studs/s on it is flagged")
		eq(run(newState(), belt(400, math.huge, 3)), "teleport", "an infinite ground speed is capped too")
		eq(run(newState(), belt(46, 0 / 0, 3)), "speed", "a NaN ground speed excuses nothing")
		eq(run(newState(), belt(46, -30, 3)), "speed", "a negative ground speed excuses nothing")
		eq(run(newState(), belt(46, nil, 3)), "speed", "no ground speed at all excuses nothing")

		-- jumping off a moving floor: the floor's speed keeps carrying the player through the air
		local function jumpOffBelt(withBelt)
			local out = {}
			for i = 1, 10 do table.insert(out, sample(i * 0.2, 76 * i * 0.2, { groundSpeed = if withBelt then 60 else 0 })) end
			for j = 1, 2 do -- 0.5 s in the air
				local air = 0.2 * j
				table.insert(out, sample(2 + air, 76 * (2 + air), { grounded = false, groundSpeed = 0, position = vec(76 * (2 + air), 3 + 50 * air - 98.1 * air * air, 0) }))
			end
			table.insert(out, sample(2.6, 76 * 2.6, { groundSpeed = if withBelt then 60 else 0 }))
			return out
		end
		eq(run(newState(), jumpOffBelt(true)), "", "jumping off a 60 studs/s belt: the belt's speed still carries him through the air")
		eq(run(newState(), jumpOffBelt(false)), "speed", "(control) the same motion with no moving floor under him is flagged")
	end

	section("Integration / movement: conveyors and platforms in the live world")
	do
		local function addFloor(minX, maxX, speed, props)
			local part = new("Part", "Floor")
			part.Anchored = true
			part.AssemblyLinearVelocity = vec(speed, 0, 0)
			if props then for k, v in props do part[k] = v end end
			part.Parent = Workspace
			table.insert(floors, { minX = minX, maxX = maxX, part = part })
			return part
		end
		local function onFloor(name, x)
			local p, c, h, r = mover(name)
			settle(p, c, h, r)
			Movement.allowTeleport(p, CFrame.new(x, 3, 0))
			frames(1.7)
			return p, c, h, r
		end
		addFloor(200, 900, 30)
		local p, c, h, r = onFloor("CV1", 210)
		frames(5, walk(r, 46))
		eq(flags(p), 0, "walking on a 30 studs/s conveyor (46 over the ground for 5 s) is not flagged")
		eq(c.pivots, 1, "...and nobody was moved back")
		local p2, c2, h2, r2 = mover("CV2")
		settle(p2, c2, h2, r2)
		frames(2, walk(r2, 46))
		check(flags(p2, "speed") >= 1, "the same 46 studs/s on still ground IS flagged speed (" .. flags(p2, "speed") .. ")")
		addFloor(1000, 1100, 30)
		local p3, c3, h3, r3 = onFloor("CV3", 1060)
		frames(2, function(dt) -- 46 studs/s on the belt, 16 once he is over its edge at x = 1100
			setPos(r3, r3.Position.X + (if r3.Position.X < 1100 then 46 else 16) * dt, 3, 0)
		end)
		check(r3.Position.X > 1110, "(the walk did cross the edge: x = " .. string.format("%.0f", r3.Position.X) .. ")")
		eq(flags(p3), 0, "walking off the end of a conveyor is not flagged")

		addFloor(2000, 5000, 1000)
		local p4, c4, h4, r4 = onFloor("CV4", 2010)
		frames(2, walk(r4, 400))
		check(flags(p4) >= 1, "a belt at 1000 studs/s excuses only GROUND_SPEED_CAP: 400 studs/s on it is flagged")

		-- who owns the part decides whether its speed can be believed
		addFloor(10000, 11000, 0 / 0) -- a floor whose speed is not a number
		local pn, cn, hn, rn = onFloor("CV7", 10010)
		frames(2, walk(rn, 46))
		check(flags(pn) >= 1, "a floor whose velocity is NaN excuses nothing")

		addFloor(6000, 7000, 40, { Anchored = false })
		local p5, c5, h5, r5 = onFloor("CV5", 6010)
		floors[#floors].part.owner = p5 -- the player's own client simulates this part
		frames(2, walk(r5, 56))
		check(flags(p5) >= 1, "an unanchored part the player's client owns: its speed is not believed")
		addFloor(8000, 9000, 40, { Anchored = false })
		local p6, c6, h6, r6 = onFloor("CV6", 8010)
		frames(2, walk(r6, 56))
		eq(flags(p6), 0, "an unanchored part the server owns (SetNetworkOwner(nil)) counts")
		table.clear(floors)
	end

	section("Integration / movement: server WalkSpeed, JumpPower and JumpHeight changes are followed")
	do
		local function jump(r, v0, seconds)
			local t0 = 0
			frames(seconds, function(dt) t0 += dt; setPos(r, r.Position.X, math.max(3, 3 + v0 * t0 - 98.1 * t0 * t0), 0) end)
		end
		local p, c, h, r = mover("WS1")
		settle(p, c, h, r)
		frames(2, walk(r, 16))
		h.WalkSpeed = 50 -- an admin :speed command, set on the server
		frames(3, walk(r, 50))
		eq(flags(p), 0, "server WalkSpeed raised 16 -> 50 in the middle of a walk: 50 studs/s is not flagged")
		local pc, cc, hc, rc = mover("WS2")
		settle(pc, cc, hc, rc)
		frames(2, walk(rc, 50))
		check(flags(pc, "speed") >= 1, "(control) the client alone claiming WalkSpeed 50: flagged")

		local pj, cj, hj, rj = mover("JH1")
		settle(pj, cj, hj, rj)
		hj.UseJumpPower = false
		hj.JumpHeight = 30 -- raised on the server
		jump(rj, math.sqrt(2 * 196.2 * 30), 2.6)
		eq(flags(pj), 0, "server JumpHeight raised to 30: a 30-stud jump is not flagged")
		local pk, ck, hk, rk = mover("JH2")
		settle(pk, ck, hk, rk)
		jump(rk, math.sqrt(2 * 196.2 * 30), 2.6)
		check(flags(pk, "jump") >= 1, "(control) the same jump with the server's JumpPower left at 50: flagged jump")
		local pp, cp, hp, rp = mover("JH3")
		settle(pp, cp, hp, rp)
		hp.JumpPower = 120 -- JumpPower raised on the server: 36.7 studs
		jump(rp, 120, 3.2)
		eq(flags(pp), 0, "server JumpPower raised to 120: that jump is not flagged")
	end

	section("Integration / movement: exempt players (API, attribute, UserId, group rank) are never judged")
	do
		local function hackFor(p, c, h, r)
			setPos(r, r.Position.X + 600, 3, 0) -- a teleport
			frames(0.5)
			frames(1.5, walk(r, 90)) -- a speed hack
			frames(2.5, function() setPos(r, r.Position.X, 40, 0) end) -- a hover
			frames(0.6, function() r.AssemblyAngularVelocity = vec(0, 3000, 0) end) -- a spin
		end
		-- by API
		local p, c, h, r = mover("EX1")
		settle(p, c, h, r)
		Movement.exempt(p, true)
		hackFor(p, c, h, r)
		eq(flags(p), 0, "Movement.exempt(player, true): teleport, speed, fly and fling are all ignored")
		eq(c.pivots or 0, 0, "...and nobody is moved back")
		-- ... even after a respawn
		local c2, h2, r2 = buildCharacter(p, "EX1b", {})
		p.CharacterRemoving:fire(c)
		frames(2.5)
		hackFor(p, c2, h2, r2)
		eq(flags(p), 0, "an API exemption survives a respawn")
		-- un-exempt: judged again (after the release grace)
		Movement.exempt(p, false)
		frames(1.5)
		setPos(r2, r2.Position.X + 600, 3, 0)
		frames(0.5)
		check(flags(p, "teleport") >= 1, "Movement.exempt(player, false): judged again (a teleport is flagged)")
		check((c2.pivots or 0) >= 1, "...and put back")

		-- taken off the list in the middle of a (client-side) speed hack: a release grace first
		local ph, ch, hh, rh = mover("EX11")
		settle(ph, ch, hh, rh)
		Movement.exempt(ph, true)
		frames(1, walk(rh, 90))
		Movement.exempt(ph, false)
		frames(0.8, walk(rh, 90))
		eq(flags(ph), 0, "no longer exempt but still at 90 studs/s: RELEASE_GRACE (1 s) before he is judged")
		frames(1.5, walk(rh, 90))
		check(flags(ph) >= 1, "...and then the same speed is flagged")

		-- by attribute: set by server code; only the value true counts
		local pa, ca, ha, ra = mover("EX2")
		settle(pa, ca, ha, ra)
		pa:SetAttribute("WeaponKitExempt", "yes")
		setPos(ra, ra.Position.X + 600, 3, 0)
		frames(0.5)
		check(flags(pa, "teleport") >= 1, "the attribute must be exactly true: \"yes\" does not exempt")
		local pb, cb, hb, rb = mover("EX3")
		settle(pb, cb, hb, rb)
		pb:SetAttribute("WeaponKitExempt", true)
		hackFor(pb, cb, hb, rb)
		eq(flags(pb), 0, "Player attribute WeaponKitExempt = true: never flagged")
		pb:SetAttribute("WeaponKitExempt", nil)
		frames(1.5)
		setPos(rb, rb.Position.X + 600, 3, 0)
		frames(0.5)
		check(flags(pb, "teleport") >= 1, "...and judged again once the attribute is cleared")

		-- by UserId list (read every sample: ids can be added while the game runs)
		local pu, cu, hu, ru = mover("EX4")
		settle(pu, cu, hu, ru)
		table.insert(L.EXEMPT_USER_IDS, pu.UserId)
		hackFor(pu, cu, hu, ru)
		eq(flags(pu), 0, "EXEMPT_USER_IDS: a listed UserId is never flagged")
		table.remove(L.EXEMPT_USER_IDS, table.find(L.EXEMPT_USER_IDS, pu.UserId))
		frames(1.5)
		setPos(ru, ru.Position.X + 600, 3, 0)
		frames(0.5)
		check(flags(pu, "teleport") >= 1, "...and judged again once it is taken off the list")

		-- by group rank, asked once at join
		L.EXEMPT_GROUP = { id = 4242, minRank = 200 }
		local asked = {}
		local function rankOf(rank) return function(_, groupId) table.insert(asked, groupId); return rank end end
		local pg, cg, hg, rg = mover("EX5", { rank = rankOf(255) })
		settle(pg, cg, hg, rg)
		hackFor(pg, cg, hg, rg)
		eq(flags(pg), 0, "EXEMPT_GROUP: rank 255 >= minRank 200 is never flagged")
		eq(asked[1], 4242, "...the rank was asked for the configured group")
		local pl, cl, hl, rl = mover("EX6", { rank = rankOf(100) })
		settle(pl, cl, hl, rl)
		setPos(rl, rl.Position.X + 600, 3, 0)
		frames(0.5)
		check(flags(pl, "teleport") >= 1, "EXEMPT_GROUP: rank 100 < minRank 200 is judged")
		eq(#asked, 2, "...one lookup per player, cached (not once per sample)")
		local tries = 0
		local pr, cr, hr, rr = mover("EX7", { rank = function() tries += 1; if tries < 3 then error("HTTP 503") end; return 255 end })
		settle(pr, cr, hr, rr)
		hackFor(pr, cr, hr, rr)
		eq(tries, 3, "a rank lookup that fails twice is tried again")
		eq(flags(pr), 0, "...and the third answer exempts him")
		local failures = 0
		local warnsBefore = #warns
		local pf, cf, hf, rf = mover("EX8", { rank = function() failures += 1; error("HTTP 503") end })
		settle(pf, cf, hf, rf)
		setPos(rf, rf.Position.X + 600, 3, 0)
		frames(0.5)
		eq(failures, 3, "a rank lookup that always fails is tried 3 times")
		check(flags(pf, "teleport") >= 1, "...and then he is simply judged (fails safe)")
		check(#warns == warnsBefore + 1 and warns[#warns]:find("EX8") ~= nil, "...with one warn naming him")
		local pw, cw, hw, rw
		do
			nextId += 1
			pw = track(makePlayer("EX9", nextId))
			pw.Neutral = true
			pw.GetRankInGroup = function() pw.Parent = nil; return 255 end -- he leaves while the lookup runs
			Players.PlayerAdded:fire(pw)
			pw.Parent = Players
			cw, hw, rw = buildCharacter(pw, "EX9", {})
		end
		settle(pw, cw, hw, rw)
		setPos(rw, rw.Position.X + 600, 3, 0)
		frames(0.5)
		check(flags(pw, "teleport") >= 1, "a lookup that comes back after the player left caches nothing")
		L.EXEMPT_GROUP = { id = 0, minRank = 255 }
		asked = {}
		local po, co, ho, ro = mover("EX10", { rank = rankOf(255) })
		settle(po, co, ho, ro)
		setPos(ro, ro.Position.X + 600, 3, 0)
		frames(0.5)
		eq(#asked, 0, "EXEMPT_GROUP id 0 = off: the rank is never asked")
		check(flags(po, "teleport") >= 1, "...and a rank-255 player is judged")
		L.EXEMPT_GROUP = savedConfig.EXEMPT_GROUP
	end

	section("Integration / movement: the default movement action (log vs snap) follows DEMO_CHEAT_PANEL")
	do
		local PRE = "local script, os, typeof, require, game, task, Enum, Instance, Vector3, Random, RaycastParams, OverlapParams, warn, Color3, CFrame, Region3 = ...; "
		local function configWith(name, demo, action)
			local text = SOURCES["shared/Config"]
			assert(type(text) == "string", "the Config source text is needed to build a variant")
			local variant = text:gsub("DEMO_CHEAT_PANEL = %a+,", "DEMO_CHEAT_PANEL = " .. tostring(demo) .. ",", 1)
			if action then variant = variant:gsub('MOVEMENT_ACTION = "auto",', 'MOVEMENT_ACTION = "' .. action .. '",', 1) end
			local key = "shared/" .. name
			SOURCES[key] = variant
			if SOURCES_FN then SOURCES_FN[key] = assert(loadstring(PRE .. variant, key)) end -- (the coverage build runs functions)
			local mod = child(shared, module(name, key))
			local cfg = require_(mod)
			mod.Parent = nil
			return cfg.ANTI_CHEAT.MOVEMENT_ACTION
		end
		eq(L.MOVEMENT_ACTION, "snap", "the shipped Config (demo panel on) resolves to snap")
		eq(configWith("CfgA", true), "snap", "DEMO_CHEAT_PANEL on, default action: snap (the lab shows the rubber-band)")
		eq(configWith("CfgB", false), "log", "DEMO_CHEAT_PANEL off, default action: log (a live game reads the counts first)")
		eq(configWith("CfgC", false, "snap"), "snap", "an explicit \"snap\" wins even with the demo panel off")
		eq(configWith("CfgD", true, "log"), "log", "an explicit \"log\" wins even with the demo panel on")

		-- The demo switch: only the Workspace attribute WeaponKitDemo = true (set in the demo place)
		-- turns the range, the lab and the snap default on. A game the kit is dropped into has none.
		local function demoConfig(name, value)
			local saved = Workspace.attrs.WeaponKitDemo
			Workspace.attrs.WeaponKitDemo = value
			local mod = child(shared, module(name, "shared/Config"))
			local cfg = require_(mod)
			mod.Parent = nil
			Workspace.attrs.WeaponKitDemo = saved
			return cfg
		end
		local plain = demoConfig("CfgNoAttr", nil)
		eq(plain.DEMO_RANGE, false, "demo switch: no WeaponKitDemo attribute -> no range (the dev's map is left alone)")
		eq(plain.DEMO_CHEAT_PANEL, false, "demo switch: no WeaponKitDemo attribute -> no exploit lab")
		eq(plain.ANTI_CHEAT.MOVEMENT_ACTION, "log", "demo switch: no WeaponKitDemo attribute -> movement checks only log")
		local text = demoConfig("CfgTextAttr", "true")
		eq(text.DEMO_RANGE, false, "demo switch: a string \"true\" is not the switch (only a ticked boolean)")
		local demo = demoConfig("CfgDemoAttr", true)
		eq(demo.DEMO_RANGE and demo.DEMO_CHEAT_PANEL, true, "demo switch: WeaponKitDemo = true -> range + lab on")
		eq(demo.ANTI_CHEAT.MOVEMENT_ACTION, "snap", "demo switch: WeaponKitDemo = true -> snap")

		-- Movement.init says so once, in log mode only. Loaded against its own Players / RunService so it
		-- cannot disturb the instance the other tests drive.
		local function isolatedMovement(name)
			local players2 = new("Players", "Players")
			players2.list = {}
			players2.PlayerAdded = newSignal()
			players2.PlayerRemoving = newSignal()
			function players2.GetPlayers(self) return self.list end
			local services = { Players = players2, ReplicatedStorage = ReplicatedStorage, Workspace = Workspace, RunService = { Heartbeat = newSignal() } }
			local mod = child(server, module(name, "server/Movement"))
			mod.gameOverride = { GetService = function(_, n) return assert(services[n], "service " .. n) end }
			return mod
		end
		local function initPrints(name, action)
			L.MOVEMENT_ACTION = action
			local printed, realPrint = {}, print
			print = function(...) table.insert(printed, table.concat({ ... }, " ")) end
			local ok, err = pcall(function() require_(isolatedMovement(name)).init() end)
			print = realPrint
			L.MOVEMENT_ACTION = savedConfig.MOVEMENT_ACTION
			assert(ok, err)
			return printed
		end
		local logLines = initPrints("MovementLog", "log")
		eq(#logLines, 2, "log mode: Movement.init prints two lines")
		eq(logLines[1], '[WeaponKit] Movement: log mode - nobody is moved back. Watch the Suspicion counts, then set ANTI_CHEAT.MOVEMENT_ACTION = "snap"', "log mode: the first line explains it")
		eq(logLines[2], "[WeaponKit] Movement ready (log)", "...then the usual ready line")
		local snapLines = initPrints("MovementSnap", "snap")
		eq(#snapLines, 1, "snap mode: only the ready line")
		eq(snapLines[1], "[WeaponKit] Movement ready (snap)", "...which names the mode")
	end

	section("Integration / movement: a flag says what was going on around it")
	do
		local details = {}
		local off = Suspicion.onFlag(function(player, reason, detail) table.insert(details, { player = player, reason = reason, detail = detail }) end)
		local function lastDetail(p)
			for i = #details, 1, -1 do
				if details[i].player == p then return details[i].detail end
			end
			return ""
		end
		local p, c, h, r = mover("DT1")
		settle(p, c, h, r)
		frames(1, walk(r, 16))
		setPos(r, r.Position.X + 700, 3, 0)
		frames(0.3)
		local d = lastDetail(p)
		check(d:find("over the limit of", 1, true) ~= nil, "the detail still starts with the number and the limit (" .. d .. ")")
		check(d:find("server move none yet", 1, true) ~= nil, "no server move so far: 'server move none yet'")
		check(d:find("movers 0", 1, true) ~= nil and d:find("ground 0 studs/s", 1, true) ~= nil, "...movers 0, ground 0 studs/s")
		check(d:find("WalkSpeed 16", 1, true) ~= nil and d:find("JumpHeight 6.4", 1, true) ~= nil, "...the server's WalkSpeed 16 and JumpHeight 6.4")

		-- right after a launch pad: flagged once the grace ran out, and the text says how long ago
		local p2, c2, h2, r2 = mover("DT2")
		settle(p2, c2, h2, r2)
		serverSet(r2, "AssemblyLinearVelocity", vec(60, 10, 0))
		frames(1.8, walk(r2, 60))
		d = lastDetail(p2)
		check(d:match("server move %d+%.%d s ago") ~= nil, "a flag after a server push says how long ago it was (" .. d .. ")")

		-- on a conveyor
		local belt = new("Part", "DetailBelt"); belt.Anchored = true; belt.AssemblyLinearVelocity = vec(30, 0, 0); belt.Parent = Workspace
		table.insert(floors, { minX = 300, maxX = 900, part = belt })
		local p3, c3, h3, r3 = mover("DT3")
		settle(p3, c3, h3, r3)
		Movement.allowTeleport(p3, CFrame.new(310, 3, 0))
		frames(1.7)
		setPos(r3, r3.Position.X + 200, 3, 0)
		frames(0.3)
		d = lastDetail(p3)
		check(d:find("ground 30 studs/s", 1, true) ~= nil, "on a conveyor the text shows its speed (" .. d .. ")")
		table.clear(floors)
		off()
	end

	section("Integration / movement: tall and short characters standing still are not flagged")
	do
		local function standAndWalk(label, opt, hoverY)
			local p, c, h, r = mover(label, opt)
			settle(p, c, h, r)
			frames(4)
			eq(flags(p), 0, label .. ": standing still for 4 s is clean")
			frames(3, walk(r, 16))
			eq(flags(p), 0, label .. ": walking at WalkSpeed for 3 s is clean")
			frames(3, function() setPos(r, r.Position.X, hoverY, 0) end)
			check(flags(p, "fly") + flags(p, "jump") >= 1, label .. ": (control) hovering well above the floor is still flagged")
		end
		standAndWalk("Tall2x", { hip = 4, size = vec(4, 4, 2) }, 16)
		standAndWalk("Short", { hip = 1, size = vec(1, 1, 0.5) }, 9)
	end

	section("Integration / movement: other characters are not walls, ladders, the water switch, odd characters")
	do
		-- walking through another player is not noclip; through a real wall it is
		local bystander = new("Model", "Bystander")
		child(bystander, new("Humanoid"))
		local body = child(bystander, new("Part", "Torso"))
		bystander.Parent = Workspace
		local mapGroup = new("Model", "MapGroup") -- a plain model (no Humanoid) is scenery
		mapGroup.Parent = Workspace
		local wall = new("Part", "SolidWall"); wall.Parent = mapGroup
		local function everyRayHits(part)
			rayHandler = function(origin, dir) return { Position = origin + dir.Unit * 1, Instance = part } end
		end
		local p, c, h, r = mover("OT1")
		settle(p, c, h, r)
		everyRayHits(body)
		frames(2, walk(r, 16))
		eq(flags(p), 0, "walking through another character's body (a ray hits a Humanoid model) is not noclip")
		everyRayHits(wall)
		frames(1, walk(r, 16))
		check(flags(p, "noclip") >= 1, "(control) the same rays hitting a plain wall are noclip")
		rayMisses()

		-- ladders built from ordinary parts: a tagged part, a part inside a tagged model, and no ladder
		local ladderModel = new("Model", "Ladder")
		ladderModel.tags["WeaponKitClimbable"] = true
		local rungInModel = child(ladderModel, new("Part", "Rung"))
		local taggedRung = new("Part", "TaggedRung")
		taggedRung.tags["WeaponKitClimbable"] = true
		Workspace.GetPartBoundsInRadius = function(_, position)
			if math.abs(position.X - 3000) < 6 then return { rungInModel } end
			if math.abs(position.X - 3100) < 6 then return { taggedRung } end
			return {}
		end
		local function climb(name, x)
			local pc, cc, hc, rc = mover(name)
			settle(pc, cc, hc, rc)
			Movement.allowTeleport(pc, CFrame.new(x, 3, 0))
			frames(1.7)
			local t0 = 0
			frames(4, function(dt) t0 += dt; setPos(rc, x, 3 + 12 * t0, 0) end)
			return flags(pc)
		end
		eq(climb("OT2", 3000), 0, "climbing a ladder inside a model tagged WeaponKitClimbable for 4 s is clean")
		eq(climb("OT3", 3100), 0, "climbing a part tagged WeaponKitClimbable for 4 s is clean")
		check(climb("OT4", 3200) >= 1, "(control) the same climb with no ladder around is flagged")
		Workspace.GetPartBoundsInRadius = function() return {} end

		-- TERRAIN_WATER = false: the water read is skipped, floating in a pool is judged
		local savedVoxels = Workspace.Terrain.ReadVoxels
		Workspace.Terrain.ReadVoxels = function() return { { { Enum.Material.Water } }, Size = vec(1, 1, 1) } end
		local function floatInWater()
			local pw, cw, hw, rw = mover("OT5")
			settle(pw, cw, hw, rw)
			frames(3, function() setPos(rw, 0, 33, 0) end)
			return flags(pw)
		end
		eq(floatInWater(), 0, "floating 30 studs up in terrain water is clean")
		L.TERRAIN_WATER = false
		check(floatInWater() >= 1, "...but with TERRAIN_WATER = false the same float is judged")
		L.TERRAIN_WATER = true
		Workspace.Terrain.ReadVoxels = savedVoxels

		-- a character whose root part arrives after the character does, and one that leaves the Workspace
		do
			nextId += 1
			local pl = track(makePlayer("OT6", nextId))
			pl.Neutral = true
			Players.PlayerAdded:fire(pl)
			local cl = new("Model", "LateChar"); cl.Parent = Workspace
			local hl = child(cl, new("Humanoid"))
			hl.Health = 100; hl.MaxHealth = 100; hl.WalkSpeed = 16; hl.JumpPower = 50; hl.JumpHeight = 7.2
			hl.UseJumpPower = true; hl.RigType = Enum.HumanoidRigType.R15; hl.HipHeight = 2
			pl.Character = cl
			pl.CharacterAdded:fire(cl)
			frames(1) -- nothing to sample yet: no error
			local rl = child(cl, new("Part", "HumanoidRootPart"))
			rl.Size = vec(2, 2, 1); rl.Anchored = false; rl.CollisionGroup = "Default"
			rl.AssemblyLinearVelocity = vec(0, 0, 0); rl.AssemblyAngularVelocity = vec(0, 0, 0)
			setPos(rl, 0, 3, 0)
			frames(2.5)
			cl:PivotTo(CFrame.new(400, 3, 0))
			frames(1.5)
			eq(flags(pl), 0, "a root part that arrived late is hooked too: a server PivotTo is not flagged")
			eq(cl.pivots, 1, "...and nobody was moved back")
			cl.Parent = nil
			local warnsBefore = #warns
			frames(1, walk(rl, 90))
			eq(flags(pl), 0, "a character taken out of the Workspace is no longer sampled")
			eq(#warns, warnsBefore, "...without any error")
		end

		-- grace and exemption for a player with no character
		nextId += 1
		local nobody = track(makePlayer("OT7", nextId))
		nobody.Neutral = true
		Players.PlayerAdded:fire(nobody)
		Movement.grace(nobody, 5)
		Movement.exempt(nobody, true)
		Movement.exempt(nobody, false)
		check(true, "Movement.grace / exempt for a player with no character are harmless no-ops")

		-- Movement.init picks up players who are already in the game
		local early = track(makePlayer("OT8", 899))
		early.Neutral = true
		local ce, he, re = buildCharacter(early, "OT8", {})
		local players2 = new("Players", "Players")
		players2.list = { early }
		players2.PlayerAdded = newSignal()
		players2.PlayerRemoving = newSignal()
		function players2.GetPlayers(self) return self.list end
		local heartbeat2 = newSignal()
		local services = { Players = players2, ReplicatedStorage = ReplicatedStorage, Workspace = Workspace, RunService = { Heartbeat = heartbeat2 } }
		local modEarly = child(server, module("MovementEarly", "server/Movement"))
		modEarly.gameOverride = { GetService = function(_, n) return assert(services[n], "service " .. n) end }
		local realPrint = print
		print = function() end
		require_(modEarly).init()
		print = realPrint
		for _ = 1, 60 * 3 do advance(1 / 60); heartbeat2:fire() end
		eq(flags(early), 0, "Movement.init: a player already in the game with a character is sampled (standing still: clean)")
		setPos(re, 600, 3, 0)
		for _ = 1, 30 do advance(1 / 60); heartbeat2:fire() end
		check(flags(early, "teleport") >= 1, "...and judged (a client teleport is flagged)")
	end

	-------------------------------------------------------------------------------------- data
	-- The save layer, on its own Players service (a fresh PlayerData instance), with the fake ProfileStore
	-- told what to do with each player (fakeStore.intercept).
	local function newPlayersService()
		local svc = new("Players", "Players")
		svc.list = {}
		svc.PlayerAdded = newSignal()
		svc.PlayerRemoving = newSignal()
		function svc.GetPlayers(self) return self.list end
		return svc
	end
	local function playerIn(svc, name, id)
		local p = new("Player", name)
		p.UserId = id
		p.Parent = svc
		table.insert(svc.list, p)
		return p
	end
	local function fakeProfile(onEnd)
		return {
			Data = {}, OnSessionEnd = newSignal(),
			AddUserId = function() end, Reconcile = function() end,
			EndSession = function() if onEnd then onEnd() end end,
		}
	end
	do
		local dataSvc = newPlayersService()
		local services = { Players = dataSvc, ReplicatedStorage = ReplicatedStorage, Workspace = Workspace }
		local mod = child(server, module("PlayerDataIso", "server/PlayerData"))
		mod.gameOverride = { GetService = function(_, n) return assert(services[n], "service " .. n) end }
		local PD = require_(mod)
		PD.init()
		local errorsAtStart2 = #taskErrors
		local function kickLog(p)
			local log = {}
			p.Kick = function(_, message) table.insert(log, message) end
			return log
		end

		section("Integration / data: a profile load that fails kicks the player with the kit message")
		fakeStore.intercept = function(key) if key == "Player_901" then return true, nil end return false end
		local failing = playerIn(dataSvc, "DFail", 901)
		local kicks = kickLog(failing)
		dataSvc.PlayerAdded:fire(failing)
		eq(#kicks, 1, "a load that returns no profile: the player is kicked once")
		eq(kicks[1], "Data failed to load, please rejoin", "...with the kit's message")
		eq(PD.get(failing), nil, "...and has no data")
		eq(#taskErrors, errorsAtStart2, "...and no Lua error")
		fakeStore.intercept = nil
		local fine = playerIn(dataSvc, "DFine", 902)
		local fineKicks = kickLog(fine)
		dataSvc.PlayerAdded:fire(fine)
		check(PD.get(fine) ~= nil and PD.get(fine).mags.Pistol == 15, "(control) a normal load gives the starting ammo")
		eq(#fineKicks, 0, "...and kicks nobody")
		dataSvc.PlayerRemoving:fire(fine)
		eq(PD.get(fine), nil, "leaving drops the data")

		section("Integration / data: a player who leaves during the load ends the session again")
		local ended, cancelAnswers = 0, {}
		local leaving = playerIn(dataSvc, "DLeave", 903)
		local leaveKicks = kickLog(leaving)
		fakeStore.intercept = function(key, opts)
			if key ~= "Player_903" then return false end
			table.insert(cancelAnswers, opts.Cancel())
			leaving.Parent = nil -- he leaves while the load is running
			table.insert(cancelAnswers, opts.Cancel())
			return true, fakeProfile(function() ended += 1 end)
		end
		dataSvc.PlayerAdded:fire(leaving)
		eq(ended, 1, "the session that opened after he left is ended at once (no lock left behind)")
		eq(PD.get(leaving), nil, "...and no data is kept for him")
		check(cancelAnswers[1] == false and cancelAnswers[2] == true, "the Cancel callback says false while he is here and true once he left")
		eq(#leaveKicks, 0, "nobody kicks a player who already left")
		local ghost = playerIn(dataSvc, "DGhost", 904)
		local ghostKicks = kickLog(ghost)
		fakeStore.intercept = function(key) if key == "Player_904" then ghost.Parent = nil; return true, nil end return false end
		dataSvc.PlayerAdded:fire(ghost)
		eq(#ghostKicks, 0, "a failed load for a player who already left kicks nobody")

		section("Integration / data: data that cannot be prepared, and a session taken over elsewhere")
		local brokenEnded = 0
		local broken = playerIn(dataSvc, "DBroken", 905)
		local brokenKicks = kickLog(broken)
		local warnsBefore = #warns
		fakeStore.intercept = function(key)
			if key ~= "Player_905" then return false end
			local profile = fakeProfile(function() brokenEnded += 1 end)
			profile.Data = nil -- not a table at all
			return true, profile
		end
		dataSvc.PlayerAdded:fire(broken)
		eq(#brokenKicks, 1, "data that cannot be prepared: the player is kicked")
		eq(brokenEnded, 1, "...and the session is ended again")
		check(#warns == warnsBefore + 1 and warns[#warns]:find("could not prepare data for DBroken", 1, true) ~= nil, "...with one warn naming him")
		eq(PD.get(broken), nil, "...and no data")
		local taken = playerIn(dataSvc, "DTaken", 906)
		local takenKicks = kickLog(taken)
		local takenProfile = fakeProfile()
		fakeStore.intercept = function(key) if key == "Player_906" then return true, takenProfile end return false end
		dataSvc.PlayerAdded:fire(taken)
		check(PD.get(taken) ~= nil, "(control) a custom profile loads")
		takenProfile.OnSessionEnd:fire()
		eq(#takenKicks, 1, "a session taken over by another server kicks the player")
		eq(PD.get(taken), nil, "...and drops his data")
		fakeStore.intercept = nil

		section("Integration / data: PlayerData.waitFor and onLoaded")
		local clockAtWait = now
		task.wait = function(t) advance(t); return t end
		local never = playerIn(dataSvc, "DNever", 907)
		eq(PD.waitFor(never, 0.5), nil, "waitFor times out and answers nil")
		check(now - clockAtWait >= 0.5 and now - clockAtWait < 0.8, "...after about the timeout (" .. string.format("%.2f", now - clockAtWait) .. " s)")
		local late = playerIn(dataSvc, "DLate", 908)
		local waits = 0
		task.wait = function(t) advance(t); waits += 1; if waits == 3 then dataSvc.PlayerAdded:fire(late) end return t end
		local got = PD.waitFor(late, 5)
		check(got ~= nil and got.mags.Pistol == 15, "waitFor returns the data when it arrives in time")
		eq(PD.waitFor(late), got, "...and at once when it is already there (no timeout given)")
		local gone = playerIn(dataSvc, "DGone", 909)
		task.wait = function(t) advance(t); gone.Parent = nil; return t end
		eq(PD.waitFor(gone, 5), nil, "waitFor answers nil when the player leaves while waiting")
		task.wait = savedWait

		-- the mock-store notice: ProfileStore decides asynchronously, init waits for it
		fakeStore.DataStoreState = "NotReady"
		local waited = 0
		task.wait = function() waited += 1; fakeStore.DataStoreState = "NoAccess"; return 0 end
		local mockMod = child(server, module("PlayerDataMock", "server/PlayerData"))
		local mockServices = { Players = newPlayersService(), ReplicatedStorage = ReplicatedStorage, Workspace = Workspace }
		mockMod.gameOverride = { GetService = function(_, n) return assert(mockServices[n], "service " .. n) end }
		local printedMock, realPrint = {}, print
		print = function(...) table.insert(printedMock, table.concat({ ... }, " ")) end
		require_(mockMod).init()
		print = realPrint
		task.wait = savedWait
		fakeStore.DataStoreState = "Access"
		eq(waited, 1, "PlayerData.init waits while the store is NotReady")
		eq(printedMock[1], "[WeaponKit] PlayerData: mock store (unpublished place, nothing persists)", "...and says so when it ends up on the mock store")

		local order = {}
		PD.onLoaded(function(p) table.insert(order, "early:" .. p.Name) end) -- already-loaded players are called at once
		check(table.find(order, "early:DLate") ~= nil, "onLoaded calls the listener at once for players already loaded")
		local errorsBefore = #taskErrors
		PD.onLoaded(function() error("listener bug") end) -- (runs at once for DLate, who is loaded already)
		PD.onLoaded(function(p) table.insert(order, "after:" .. p.Name) end)
		local fresh = playerIn(dataSvc, "DFresh", 910)
		dataSvc.PlayerAdded:fire(fresh)
		check(table.find(order, "early:DFresh") ~= nil and table.find(order, "after:DFresh") ~= nil, "a new player's load runs every listener (one failing listener does not block the next)")
		eq(#taskErrors, errorsBefore + 2, "...the failing one fails in its own thread (twice: DLate and DFresh)")
		taskErrors[#taskErrors] = nil
		taskErrors[#taskErrors] = nil
		eq(#taskErrors, errorsAtStart2, "(no other thread error came out of the data tests)")
	end

	-------------------------------------------------------------------------------------- put the world back
	section("Integration: nothing is left behind for the tests after this one")
	for _, p in made do
		p.Parent = nil
		Players.PlayerRemoving:fire(p)
	end
	Players.list = savedPlayers
	while #Workspace.children > savedWorkspaceChildren do
		Workspace.children[#Workspace.children].Parent = nil
	end
	rayHandler, blockHandler = savedRay, savedBlock
	Workspace.GetPartBoundsInRadius = savedBounds
	task.wait = savedWait
	deferSignals = false
	fakeStore.intercept = nil
	Config.PVP, Config.FRIENDLY_FIRE = savedConfig.PVP, savedConfig.FRIENDLY_FIRE
	L.MOVEMENT_ACTION, L.TRUST_SERVER_MOVES, L.EXEMPT_GROUP = savedConfig.MOVEMENT_ACTION, savedConfig.TRUST_SERVER_MOVES, savedConfig.EXEMPT_GROUP
	check(next(Weapons.Defs, nil) ~= nil and Weapons.Defs.Smg == nil and Weapons.Defs.Slow == nil and Weapons.Defs.Spray == nil, "the weapons added at runtime are removed again")
	eq(#L.EXEMPT_USER_IDS, 0, "the exempt UserId list is empty again")
	eq(#taskErrors, errorsAtStart, "no task threw an unexpected error during the integration tests (" .. tostring(taskErrors[errorsAtStart + 1]) .. ")")
end
