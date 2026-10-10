-- Fuzz / property test. Drives the REAL server code (WeaponServer, RateLimit, PlayerData,
-- Suspicion, AimStats) through tens of thousands of randomized, mostly-malicious requests and
-- checks hard invariants after every single action. Seeded, so a failure is reproducible.
--
-- Invariants (must hold no matter what the client sends):
--   A  no Lua error ever reaches the server (taskErrors never grows)
--   B  ammo is never created: sum of every weapon's (mag + reserve) only goes UP right after a
--      restock; a fire spends at most one round; a reload moves rounds, it never mints them
--   C  mag and reserve stay within [0, magazine] / [0, reserveMax] for every weapon, always
--   D  damage in a single trigger pull never exceeds pellets * damage * headshotMultiplier
--   E  no damage without a round spent: if a target lost health, the round count dropped too
--   F  a dead target is never hurt again; health never goes below 0
-- and one LIVENESS invariant, because safety alone would be satisfied by a server that refuses everybody:
--   G  every so often, among the attacks, an HONEST shot (the real head plus a small offset, a unit
--      direction, the next shot id, weapon in hand, rounds in the magazine, not reloading) must be ACCEPTED
--      (one round spent, stats.shots + 1) and must raise no Suspicion flag. Honest timing = the client sends
--      exactly on the weapon's interval (a real client is never earlier: its own gate), and every packet
--      takes a random one-way delay of +-40 ms plus up to one server frame, arriving in order. The attacker
--      and the honest player are the same Player here, so each probe starts after a quiet moment.
-- After the attacks, G2 runs a separate honest player through ~50,000 shots on that bad network, with
-- lag spikes that deliver 2-4 shots at once (see there).
-- Shared helpers (fire, reloadR, advance, data, Weapons, makeDummy, rayHandler, check, taskErrors,
-- char/pistol/rifle/shotgun, p1/p2/char2) come from body.luau, which is concatenated before this.

do
	section("Fuzz backstop: 1,000,000 randomized malicious requests, 6 safety invariants")
	-- Strictly-increasing valid shot id, shared across every seed: the server remembers the last
	-- id per player, so if this reset per seed the "clean" shots would look like replays and be
	-- rejected, starving the damage path. Starts well above any id used by the tests above.
	local goodId = 1000000
	local Suspicion = require_(server.Suspicion)
	local PROBE_EVERY = 200 -- iterations between honest probes (the iteration counts are unchanged)
	local NET_JITTER = 0.04 -- one-way delay varies +-40 ms...
	local NET_FRAME = 1 / 60 -- ...plus up to one server frame before the server reads the packet
	local probes, probeBad, probeSkipped = 0, 0, 0
	-- Arrival times of `n` shots sent exactly `interval` apart, relative to the first send: a random
	-- delay per packet, delivered in order (a late packet holds back the ones behind it).
	local function arrivalsOf(n, interval)
		local arrivals, latest = {}, -math.huge
		for k = 1, n do
			latest = math.max(latest, (k - 1) * interval + (math.random() * 2 - 1) * NET_JITTER + math.random() * NET_FRAME)
			arrivals[k] = latest
		end
		return arrivals
	end

	local function runFuzz(seed, iterations)
		math.randomseed(seed)

		-- Known starting point: p1 alive, only the pistol equipped, ammo at the caps.
		advance(10)
		char.Humanoid.Health = 100
		shotgun.Parent = nil
		rifle.Parent = nil
		pistol.Parent = char
		local held = "Pistol"
		for name, def in Weapons.Defs do
			data.mags[name] = def.magazine
			data.reserve[name] = def.reserveMax
		end
		local target, thum, thead, ttorso = makeDummy("FuzzTarget")

		local tools = { Pistol = pistol, Rifle = rifle, Shotgun = shotgun }
		local function equip(name)
			if name == held then
				return
			end
			tools[held].Parent = nil
			tools[name].Parent = char
			held = name
		end

		local function sumRounds()
			local t = 0
			for name in Weapons.Defs do
				t += (data.mags[name] or 0) + (data.reserve[name] or 0)
			end
			return t
		end

		local HEAD = vec(0, 5, 0) -- p1's head position (makeCharacter put it here)
		local function badVec()
			local r = math.random(1, 6)
			if r == 1 then return vec(0 / 0, 0 / 0, 0 / 0) end -- NaN
			if r == 2 then return vec(1 / 0, 0, 0) end -- inf
			if r == 3 then return vec(1e9, 1e9, 1e9) end -- absurd
			if r == 4 then return vec(0, 0, 0) end -- zero
			if r == 5 then return "notavector" end -- wrong type
			return nil -- missing
		end
		local function badId(lastValid)
			local r = math.random(1, 6)
			if r == 1 then return lastValid end -- replay (equal)
			if r == 2 then return math.random(1, 100) end -- old id
			if r == 3 then return 1.5 end -- non-integer
			if r == 4 then return 0 / 0 end -- NaN
			if r == 5 then return -5 end -- negative
			return "99" -- wrong type
		end

		-- Invariant G. A burst of up to 4 honest shots after a quiet moment, sent on the weapon's interval and
		-- delivered through the jittery network above. Misses only (nothing is hit, so no aim flag can come from them).
		local function honestProbe(it)
			advance(10)
			local def = Weapons.Defs[held]
			local interval = 60 / def.rpm
			local count = math.min(4, data.mags[held])
			if count < 1 then
				probeSkipped += 1
				return
			end
			rayHandler = function() return nil end
			local arrivals = arrivalsOf(count, interval)
			local gapRatio = 1
			for k = 1, count do
				if k > 1 then
					gapRatio = (arrivals[k] - arrivals[k - 1]) / interval
					advance(arrivals[k] - arrivals[k - 1])
				end
				local rounds, shots = data.mags[held], data.stats.shots
				local flagsBefore, errBefore = (Suspicion.total(p1)), #taskErrors
				local aim = vec((math.random() - 0.5) * 0.4, (math.random() - 0.5) * 0.4, -1).Unit
				local muzzle = HEAD + vec((math.random() - 0.5) * 2, (math.random() - 0.5), -math.random() * 1.5)
				fire(p1, muzzle, aim, goodId)
				goodId += 1
				probes += 1
				local flagged = (Suspicion.total(p1)) - flagsBefore
				if data.mags[held] ~= rounds - 1 or data.stats.shots ~= shots + 1 or flagged ~= 0 or #taskErrors ~= errBefore then
					probeBad += 1
					if probeBad <= 5 then
						local why = last(rejR)
						print(string.format(
							"  FUZZ G (seed %d, iter %d): honest %s shot %d/%d refused: gap %.1f%% of the interval, round spent %s, flags +%d (%s)",
							seed, it, held, k, count, gapRatio * 100, tostring(rounds - data.mags[held] == 1), flagged,
							tostring(why and why[1])
						))
					end
				end
			end
		end

		local violations = 0
		local function bad(msg, it)
			violations += 1
			if violations <= 5 then
				print(string.format("  FUZZ violation (seed %d, iter %d): %s", seed, it, msg))
			end
		end

		for it = 1, iterations do
			-- Keep a live target around so damage paths stay exercised.
			if thum.Health <= 0 and math.random() < 0.4 then
				thum.Health = 100
			end
			-- Where the server's raycast lands this step: a head, a torso, a miss, or another
			-- player (PVP off -> must deal no damage).
			local rr = math.random(1, 5)
			if rr == 1 then
				rayHandler = function() return { Position = vec(0, 5, -10), Instance = thead } end
			elseif rr == 2 then
				rayHandler = function() return { Position = vec(0, 3, -10), Instance = ttorso } end
			elseif rr == 3 then
				rayHandler = function() return nil end
			else
				rayHandler = function() return { Position = vec(0, 5, -10), Instance = char2.Head } end
			end

			local def = Weapons.Defs[held]
			local beforeRounds = sumRounds()
			local beforeErr = #taskErrors
			local beforeHp = thum.Health
			local restocked = false

			local act = math.random(1, 14)
			if act <= 6 then
				-- Fire with a payload: ~40% clean, the rest malformed in some way.
				local origin, dir, id
				if math.random() < 0.4 then
					origin, dir, id = vec(0, 5, -1), vec(0, 0, -1), goodId
					goodId += 1
				else
					origin = if math.random() < 0.5 then badVec() else vec(0, 5, -math.random(1, 90))
					dir = if math.random() < 0.5 then badVec() else vec(0, 0, -1)
					id = if math.random() < 0.5 then badId(goodId - 1) else goodId
					if id == goodId then
						goodId += 1
					end
				end
				fire(p1, origin, dir, id)
			elseif act <= 9 then
				advance(math.random() * 0.4)
			elseif act == 10 then
				reloadR.OnServerEvent:fire(p1)
			elseif act == 11 then
				equip(({ "Pistol", "Rifle", "Shotgun" })[math.random(1, 3)])
			elseif act == 12 then
				WeaponServer.restock(p1)
				restocked = true
			elseif act == 13 then
				-- A clean, well-paced shot so accepted fires keep happening.
				advance(0.3)
				fire(p1, vec(0, 5, -1), vec(0, 0, -1), goodId)
				goodId += 1
			else
				-- Burst of identical ids in one instant (replay + rate pressure).
				for _ = 1, 5 do
					fire(p1, vec(0, 5, -1), vec(0, 0, -1), goodId)
				end
				goodId += 1
			end

			-- ---- invariants ----
			if #taskErrors ~= beforeErr then
				bad("A: server error: " .. tostring(taskErrors[#taskErrors]), it)
			end
			local afterRounds = sumRounds()
			if not restocked and afterRounds > beforeRounds then
				bad(string.format("B: ammo created %d -> %d", beforeRounds, afterRounds), it)
			end
			for name, d in Weapons.Defs do
				local m, rsv = data.mags[name], data.reserve[name]
				if type(m) ~= "number" or m < 0 or m > d.magazine then
					bad("C: mag " .. name .. "=" .. tostring(m), it)
				end
				if type(rsv) ~= "number" or rsv < 0 or rsv > d.reserveMax then
					bad("C: reserve " .. name .. "=" .. tostring(rsv), it)
				end
			end
			local drop = beforeHp - thum.Health
			if drop > 0 then
				local maxDmg = def.pellets * def.damage * def.headshotMultiplier + 1e-6
				if drop > maxDmg then
					bad(string.format("D: %s dealt %.1f > max %.1f", held, drop, maxDmg), it)
				end
				if afterRounds >= beforeRounds and not restocked then
					bad("E: damage dealt but no round spent", it)
				end
			end
			if thum.Health < -1e-9 then
				bad("F: health below zero: " .. tostring(thum.Health), it)
			end
			if it % PROBE_EVERY == 0 then
				honestProbe(it) -- (after the A-F checks: it spends rounds of its own)
			end
		end

		-- Clean up the fuzz target so later output isn't affected.
		target.Parent = nil
		return violations
	end

	-- Total attacks = ITER x #seeds. A coverage sweep (tests/sweep.luau) found the scenario space
	-- saturates at ~100K actions (99.8% of all reachable scenarios); 20M found only 4 more, all
	-- benign. So 1,000,000 here is comfortably past saturation while still running in ~3s: enough
	-- to certify "1,000,000 randomized attacks, 0 failures" on every CI run without wasting time.
	-- CI passes a smaller count (build.py <n>) for snappy pushes; the default run is the 1M headline.
	local ITER = FUZZ_ITER or 200000
	local seeds = { 1, 7, 42, 1337, 2024 }
	local total = 0
	for _, s in seeds do
		total += runFuzz(s, ITER)
	end
	check(total == 0, string.format("FUZZ: %d randomized malicious actions across %d seeds, 0 invariant violations (got %d)", ITER * #seeds, #seeds, total))
	check(probes > 0 and probeBad == 0, string.format("FUZZ G (liveness): %d honest shots among the attacks (%d probes skipped for an empty magazine), sent at the weapon's rpm through +-%d ms of network jitter - every one accepted and unflagged (refused: %d)", probes, probeSkipped, NET_JITTER * 1000, probeBad))

	-- G2. One honest player, nothing else going on: 2,000 magazines (rifle mostly, every 5th a pistol, every
	-- 10th a shotgun), each fired as fast as the weapon allows through the same bad network, and in 30% of
	-- the magazines a lag spike that holds 2-4 shots back and delivers them in the same instant. A spike
	-- delivers shots faster than the rpm, so some of them may be refused: at most (spike size - 1) per
	-- magazine (the rifle's jitter credit can move one of those refusals a few shots later). Everything
	-- else must be accepted, and "fast" must never be reported.
	section("Fuzz G2 (liveness under a bad network): an honest player through jitter, frame delay and lag spikes")
	do
		math.randomseed(4242)
		local hp = makePlayer("NetHonest", 9001)
		hp.Neutral = true
		Players.PlayerAdded:fire(hp)
		local hc = makeCharacter(hp, vec(0, 5, 0))
		local hdata = PlayerData.get(hp)
		local tool = new("Tool", "Rifle")
		tool.Parent = hc
		rayHandler = function() return nil end
		local id, shots, refusedTotal, badMags, spikes, spikeShots = 0, 0, 0, 0, 0, 0
		for mag = 1, 2000 do
			local name = if mag % 10 == 0 then "Shotgun" elseif mag % 5 == 0 then "Pistol" else "Rifle"
			if tool.Name ~= name then
				tool.Parent = nil
				tool = new("Tool", name)
				tool.Parent = hc
			end
			local def = Weapons.Defs[name]
			hdata.mags[name] = def.magazine
			advance(def.reloadTime + math.random() * 2) -- a reload / a pause between magazines
			local n = def.magazine
			local arrivals = arrivalsOf(n, 60 / def.rpm)
			local spike = 0
			if math.random() < 0.3 then
				spike = math.random(2, 4)
				local first = math.random(1, n - spike + 1)
				for k = first, first + spike - 2 do
					arrivals[k] = arrivals[first + spike - 1] -- held back, then delivered with the last one
				end
				spikes += 1
				spikeShots += spike
			end
			for k = 1, n do
				if k > 1 then
					advance(arrivals[k] - arrivals[k - 1])
				end
				id += 1
				fire(hp, vec(0, 5, -1), vec(0, 0, -1), id)
			end
			local refused = hdata.mags[name] -- (every shot that was accepted spent a round)
			shots += n
			refusedTotal += refused
			if refused > math.max(spike - 1, 0) then
				badMags += 1
				if badMags <= 5 then
					print(string.format("  FUZZ G2: %s magazine %d (spike of %d): %d of %d shots refused", name, mag, spike, refused, n))
				end
			end
		end
		local _, reasons = Suspicion.total(hp)
		check(badMags == 0, string.format("G2: %d honest shots in 2,000 magazines, %d lag spikes (%d shots in them): every shot accepted except the ones a spike bunched up (refused: %d, magazines over the limit: %d)", shots, spikes, spikeShots, refusedTotal, badMags))
		check(next(reasons) == nil, "G2: ...and the honest player was never flagged (" .. (reasons.fast or 0) .. " 'fast')")
		hc.Parent = nil
	end
end

report()
