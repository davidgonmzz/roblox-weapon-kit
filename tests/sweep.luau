-- Coverage sweep: find the iteration count where the fuzzer stops discovering NEW distinct
-- attack scenarios (saturation). A "scenario" = (origin-class, dir-class, id-class, ray-outcome,
-- server-result). Each is encoded as an integer key (no per-iteration string building, so the
-- sweep stays fast). All 6 safety invariants are also checked every step, so this run doubles as
-- a 20-million-scale correctness proof. Reuses the mock + helpers from body.luau.

do
	local seen = {}
	local distinct = 0
	local lastNewAt = 0
	local function mark(key, it)
		if not seen[key] then
			seen[key] = true
			distinct += 1
			lastNewAt = it
		end
	end

	-- setup: p1 alive, pistol only, ammo at caps
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
	local target, thum, thead, ttorso = makeDummy("SweepTarget")
	local tools = { Pistol = pistol, Rifle = rifle, Shotgun = shotgun }
	local toolCode = { Pistol = 1, Rifle = 2, Shotgun = 3 }
	local function equip(name)
		if name ~= held then
			tools[held].Parent = nil
			tools[name].Parent = char
			held = name
		end
	end
	local function sumRounds()
		local t = 0
		for name in Weapons.Defs do
			t += (data.mags[name] or 0) + (data.reserve[name] or 0)
		end
		return t
	end

	local function genOrigin() -- value, code 1..7
		local r = math.random(1, 7)
		if r == 1 then return vec(0, 5, -1), 1 end -- clean near head
		if r == 2 then return vec(0, 5, -math.random(7, 90)), 2 end -- far (origin flag)
		if r == 3 then return vec(0 / 0, 0 / 0, 0 / 0), 3 end -- NaN
		if r == 4 then return vec(1 / 0, 0, 0), 4 end -- inf
		if r == 5 then return vec(1e9, 1e9, 1e9), 5 end -- absurd
		if r == 6 then return "x", 6 end -- wrong type
		return nil, 7 -- missing
	end
	local function genDir() -- value, code 1..6
		local r = math.random(1, 6)
		if r == 1 then return vec(0, 0, -1), 1 end -- clean
		if r == 2 then return vec(0, 0, 0), 2 end -- zero
		if r == 3 then return vec(0 / 0, 0, 0), 3 end -- NaN
		if r == 4 then return vec(1 / 0, 0, 0), 4 end -- inf
		if r == 5 then return vec(1e9, 0, 0), 5 end -- absurd
		return "x", 6 -- wrong type
	end
	local goodId = 1000000
	local function genId() -- value, code 1..7
		local r = math.random(1, 7)
		if r == 1 then
			goodId += 1
			return goodId, 1 -- fresh increasing (valid)
		end
		if r == 2 then return goodId, 2 end -- replay (equal to last valid)
		if r == 3 then return math.random(1, 100), 3 end -- old
		if r == 4 then return 1.5, 4 end -- non-integer
		if r == 5 then return 0 / 0, 5 end -- NaN
		if r == 6 then return -5, 6 end -- negative
		return "99", 7 -- wrong type
	end
	local flagCode = { args = 1, fast = 2, origin = 3, rate = 4, snap = 5, aim = 6, crate = 7, reload = 8 }

	local violations = 0
	local function inv(ok, it, msg)
		if not ok then
			violations += 1
			if violations <= 5 then
				print(string.format("  SWEEP invariant fail (iter %d): %s", it, msg))
			end
		end
	end

	local checkpoints = { 100000, 250000, 500000, 1000000, 2000000, 5000000, 10000000, 20000000 }
	local ci = 1
	local MAX = checkpoints[#checkpoints]
	local prevDistinct = 0

	math.randomseed(20241010)
	for it = 1, MAX do
		if thum.Health <= 0 and math.random() < 0.4 then
			thum.Health = 100
		end
		local rc = math.random(1, 4)
		if rc == 1 then
			rayHandler = function() return { Position = vec(0, 5, -10), Instance = thead } end
		elseif rc == 2 then
			rayHandler = function() return { Position = vec(0, 3, -10), Instance = ttorso } end
		elseif rc == 3 then
			rayHandler = function() return nil end
		else
			rayHandler = function() return { Position = vec(0, 5, -10), Instance = char2.Head } end
		end

		local def = Weapons.Defs[held]
		local beforeRounds = sumRounds()
		local beforeErr = #taskErrors
		local beforeHp = thum.Health
		local beforeRej = last(rejR)
		local beforeFlagTotal = (beforeRej and beforeRej[3]) or 0
		local restocked = false

		local act = math.random(1, 14)
		if act <= 7 then
			local origin, oc = genOrigin()
			local dir, dc = genDir()
			local id, idc = genId()
			fire(p1, origin, dir, id)
			-- classify the server's response
			local afterRej = last(rejR)
			local flagTotal = (afterRej and afterRej[3]) or 0
			local accepted = (sumRounds() < beforeRounds) and 1 or 0
			local fc = 0
			if flagTotal > beforeFlagTotal and afterRej then
				fc = flagCode[afterRej[1]] or 9
			end
			local key = ((((oc * 8 + dc) * 8 + idc) * 8 + rc) * 16 + (accepted * 8 + fc))
			mark(key, it)
		elseif act <= 9 then
			advance(math.random() * 0.4)
			mark(-1, it)
		elseif act == 10 then
			reloadR.OnServerEvent:fire(p1)
			local afterRej = last(rejR)
			local fl = (afterRej and afterRej[3] or 0) > beforeFlagTotal
			mark(fl and -20 or -21, it)
		elseif act == 11 then
			equip(({ "Pistol", "Rifle", "Shotgun" })[math.random(1, 3)])
			mark(-30 - toolCode[held], it)
		elseif act == 12 then
			WeaponServer.restock(p1)
			restocked = true
			mark(-40, it)
		elseif act == 13 then
			advance(0.3)
			goodId += 1
			fire(p1, vec(0, 5, -1), vec(0, 0, -1), goodId)
			mark(-50, it)
		else
			goodId += 1
			local n = 0
			for _ = 1, 5 do
				fire(p1, vec(0, 5, -1), vec(0, 0, -1), goodId)
			end
			mark(-60, it)
		end

		-- invariants (every step)
		inv(#taskErrors == beforeErr, it, "server error")
		local afterRounds = sumRounds()
		inv(restocked or afterRounds <= beforeRounds, it, "ammo created")
		for name, d in Weapons.Defs do
			local m, rsv = data.mags[name], data.reserve[name]
			inv(type(m) == "number" and m >= 0 and m <= d.magazine, it, "mag " .. name)
			inv(type(rsv) == "number" and rsv >= 0 and rsv <= d.reserveMax, it, "reserve " .. name)
		end
		local drop = beforeHp - thum.Health
		if drop > 0 then
			inv(drop <= def.pellets * def.damage * def.headshotMultiplier + 1e-6, it, "overdamage")
			inv(restocked or afterRounds < beforeRounds, it, "damage without round")
		end
		inv(thum.Health >= -1e-9, it, "health < 0")

		if it == checkpoints[ci] then
			print(string.format(
				"  %10d iters | distinct scenarios %4d | new %3d | iters since last new %d",
				it,
				distinct,
				distinct - prevDistinct,
				it - lastNewAt
			))
			prevDistinct = distinct
			ci += 1
		end
	end

	target.Parent = nil
	check(violations == 0, string.format("SWEEP: %d actions, 0 invariant violations (got %d); %d distinct scenarios; saturated at iter %d", MAX, violations, distinct, lastNewAt))
end
