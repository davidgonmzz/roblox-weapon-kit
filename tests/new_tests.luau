
---------------------------------------------------------------- NEW: Suspicion
section("Suspicion: flag counting, warn threshold & policy hooks")
local Config = require_(shared.Config)
local L = Config.ANTI_CHEAT
do
	local Suspicion = require_(server.Suspicion)
	local ps = makePlayer("PS", 50)
	local warnsBefore = #warns

	Suspicion.report(ps, "speed", "d1"); Suspicion.report(ps, "speed"); Suspicion.report(ps, "speed")
	Suspicion.report(ps, "fly")
	r = last(rejR)
	check(r and r[1] == "fly" and r[2] == 1 and r[3] == 4, "S1: Rejected carries (reason, reasonCount, total)")
	local total, reasons = Suspicion.total(ps)
	eq(total, 4, "S1: total"); eq(reasons.speed, 3, "S1: speed count"); eq(reasons.fly, 1, "S1: fly count")
	eq(select("#", table.unpack(last(rejR))), 3, "S1: exactly three args, like before")

	-- hooks
	local seen = {}
	local remove = Suspicion.onFlag(function(player, reason, detail, n, tot) table.insert(seen, { player, reason, detail, n, tot }) end)
	Suspicion.report(ps, "jump", "rose 30")
	eq(#seen, 1, "S2: hook called"); check(seen[1][1] == ps and seen[1][2] == "jump" and seen[1][3] == "rose 30" and seen[1][4] == 1 and seen[1][5] == 5, "S2: hook args")
	remove()
	Suspicion.report(ps, "jump")
	eq(#seen, 1, "S2: removed hook not called")

	-- a failing hook must not stop the reporter or the other hooks
	local errorsBefore = #taskErrors
	local calls = 0
	local r1 = Suspicion.onFlag(function() error("policy bug") end)
	local r2 = Suspicion.onFlag(function() calls += 1 end)
	Suspicion.report(ps, "noclip")
	eq(calls, 1, "S3: second hook still runs"); eq(#taskErrors, errorsBefore + 1, "S3: the failure was contained in its own thread")
	taskErrors[#taskErrors] = nil
	r1(); r2()
	-- a hook may remove itself while running
	local selfRemove
	selfRemove = Suspicion.onFlag(function() selfRemove() end)
	Suspicion.report(ps, "noclip")
	Suspicion.report(ps, "noclip")

	-- one warn at 25 flags, and it names the reasons
	local warnsNow = #warns
	local pw = makePlayer("PW", 51)
	for i = 1, 40 do Suspicion.report(pw, i % 2 == 0 and "speed" or "fly") end
	eq(#warns, warnsNow + 1, "S4: exactly one warn for 40 flags")
	check(warns[#warns]:find("PW") and warns[#warns]:find("25") and warns[#warns]:find("fly=13") and warns[#warns]:find("speed=12"), "S4: warn text (" .. warns[#warns] .. ")")

	-- clean up when the player leaves; flags for a player who is already gone are ignored
	Players.PlayerRemoving:fire(ps)
	eq((Suspicion.total(ps)), 0, "S5: state dropped on PlayerRemoving")
	local gone = makePlayer("PG", 52)
	gone.Parent = nil
	local firedBefore = #rejR.fired
	Suspicion.report(gone, "speed")
	eq((Suspicion.total(gone)), 0, "S5: no state for a player who left"); eq(#rejR.fired, firedBefore, "S5: nothing sent to a player who left")
end

-- Demo flag off: no Rejected remote and no LabQuery remote exist, reports still count.
do
	local remotesFolder = ReplicatedStorage.WeaponKitRemotes
	local savedRejected = remotesFolder.Rejected
	savedRejected.Parent = nil
	Config.DEMO_CHEAT_PANEL = false
	local freshSuspicion = require_(child(server, module("SuspicionOff", "server/Suspicion")))
	local LabQueryOff = require_(child(server, module("LabQueryOff", "server/LabQuery")))
	LabQueryOff.init()
	check(remotesFolder:FindFirstChild("Rejected") == nil, "S6: flag off: no Rejected remote")
	check(remotesFolder:FindFirstChild("LabQuery") == nil, "S6: flag off: no LabQuery remote")
	local po = makePlayer("PO", 53)
	freshSuspicion.report(po, "speed")
	eq((freshSuspicion.total(po)), 1, "S6: flag off: still counted")
	Config.DEMO_CHEAT_PANEL = true
	savedRejected.Parent = remotesFolder
end

---------------------------------------------------------------- NEW: LabQuery (demo only)
section("LabQuery: demo-only server view of your own character, rate-limited")
do
	local LabQuery = require_(server.LabQuery)
	LabQuery.init()
	local query = ReplicatedStorage.WeaponKitRemotes:FindFirstChild("LabQuery")
	check(query ~= nil, "L1: LabQuery exists while the demo flag is on")
	local pl = makePlayer("PL", 54)
	eq(query.OnServerInvoke(pl), nil, "L1: no character: nil")
	local c = makeCharacter(pl, vec(1, 5, 2))
	c.Humanoid.WalkSpeed = 16; c.Humanoid.JumpPower = 50; c.Humanoid.JumpHeight = 7.2; c.Humanoid.UseJumpPower = true
	local view = query.OnServerInvoke(pl, "ignored", 1, {}, 0 / 0)
	check(view and view.health == 100 and view.maxHealth == 100 and view.walkSpeed == 16 and view.jumpPower == 50 and view.position.X == 1, "L2: server view of the caller's own character")
	local answered = 1
	for _ = 1, 15 do if query.OnServerInvoke(pl) then answered += 1 end end
	check(answered <= 9, "L3: rate limited (answered " .. answered .. " of 16 at once)")
end

---------------------------------------------------------------- NEW: AimStats
section("AimStats: headshot-ratio & aim-snap detection (flag-only, never blocks)")
do
	local AimStats = require_(server.AimStats)
	local function dir(deg) local r = math.rad(deg); return vec(math.sin(r), 0, -math.cos(r)) end

	check(math.abs(AimStats.angleBetween(dir(0), dir(40)) - 40) < 1e-6, "A1: angleBetween 40 degrees")
	check(AimStats.angleBetween(dir(10), dir(10)) < 1e-3, "A1: angleBetween same direction")

	-- a normal player: 30% headshots over 60 hits never flags
	local s = AimStats.newState()
	local flags = 0
	for i = 1, 60 do if (AimStats.recordHit(s, i % 10 < 3, L)) then flags += 1 end end
	eq(flags, 0, "A2: 30% headshots never flagged")
	-- a very good player: 60% headshots never flags
	s = AimStats.newState(); flags = 0
	for i = 1, 60 do if (AimStats.recordHit(s, i % 5 < 3, L)) then flags += 1 end end
	eq(flags, 0, "A2: 60% headshots never flagged")
	-- exactly the threshold (16 of a full window of 20 = 80%) is not "more than"; one more headshot is
	s = AimStats.newState()
	s.heads = { false, false, false, false, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true }
	eq((AimStats.recordHit(s, true, L)), false, "A2: exactly 80% is not flagged")
	eq((AimStats.recordHit(s, true, L)), true, "A2: 85% is")

	-- all headshots: nothing before the minimum sample, flagged on the minimum-th hit
	s = AimStats.newState()
	local firstFlag
	for i = 1, 25 do
		local flagged, ratio = AimStats.recordHit(s, true, L)
		if flagged and not firstFlag then firstFlag = i; check(ratio == 1, "A3: ratio reported") end
	end
	eq(firstFlag, L.AIM_MIN_HITS, "A3: flagged exactly at the minimum sample")
	-- after a flag the sample is cleared: the next flag needs another full sample
	s = AimStats.newState(); local at = {}
	for i = 1, 35 do if (AimStats.recordHit(s, true, L)) then table.insert(at, i) end end
	check(#at == 3 and at[1] == 10 and at[2] == 20 and at[3] == 30, "A3: one flag per minimum sample (" .. table.concat(at, ",") .. ")")
	-- old hits roll out of the window: a streak of body hits cools the ratio down
	s = AimStats.newState()
	for _ = 1, 9 do AimStats.recordHit(s, true, L) end
	for _ = 1, 15 do AimStats.recordHit(s, false, L) end
	eq((AimStats.recordHit(s, true, L)), false, "A3: ratio falls after body hits")

	-- snaps: 40 degrees between consecutive shots 0.2 s apart, every shot hits
	local function snapRun(angleStep, interval, hits, count)
		local st = AimStats.newState()
		local t0 = 1000
		local flaggedAt
		for i = 1, count do
			local f = AimStats.recordShot(st, t0 + (i - 1) * interval, dir((i % 2 == 0) and angleStep or 0), hits, L)
			if f and not flaggedAt then flaggedAt = i end
		end
		return flaggedAt
	end
	eq(snapRun(40, 0.2, true, 10), 4, "A4: 40-degree snaps at 0.2 s flagged after 3 events (shot 4)")
	eq(snapRun(40, 0.2, false, 10), nil, "A4: snaps that MISS are not counted")
	eq(snapRun(10, 0.2, true, 10), nil, "A4: small angle (10 degrees) not flagged")
	eq(snapRun(40, 0.5, true, 10), nil, "A4: slow flick (0.5 s apart) not flagged")
	eq(snapRun(40, 0.2, true, 3), nil, "A4: two events are not enough")
	-- events must fall inside the window
	do
		local st = AimStats.newState()
		local f1 = AimStats.recordShot(st, 0, dir(0), true, L)
		local f2 = AimStats.recordShot(st, 0.2, dir(40), true, L)   -- event 1
		local f3 = AimStats.recordShot(st, 20, dir(0), true, L)     -- long gap: no event
		local f4 = AimStats.recordShot(st, 20.2, dir(40), true, L)  -- event 2 (the first one is 20 s old)
		local f5 = AimStats.recordShot(st, 40, dir(0), true, L)
		local f6 = AimStats.recordShot(st, 40.2, dir(40), true, L)  -- event 3, but spread over 40 s
		check(not (f1 or f2 or f3 or f4 or f5 or f6), "A5: three events spread over 40 s are not flagged")
	end
	-- counter restarts after a flag
	do
		local st = AimStats.newState()
		local n = 0
		for i = 1, 14 do if AimStats.recordShot(st, i * 0.2, dir((i % 2 == 0) and 40 or 0), true, L) then n += 1 end end
		eq(n, 4, "A6: 13 events -> the count restarts after every flag (4 flags)")
	end
end

---------------------------------------------------------------- NEW: Movement.evaluate (pure)
section("Movement logic: speed/teleport/fly/jump/noclip/climb/swim/fling + lag, grace, hold")
local Movement = require_(server.Movement)
do
	local function newState(y) return Movement.newState(vec(0, y or 3, 0), 0) end
	local function mk(t, x, y, z, over)
		local s = { time = t, position = vec(x, y, z), walkSpeed = 16, jumpHeight = 7.2, gravity = 196.2, ping = 0.05,
			grounded = true, climbing = false, swimming = false, seated = false, angularSpeed = 0, linearSpeed = 0 }
		if over then for k, v in over do s[k] = v end end
		return s
	end
	local function names(verdicts)
		local out = {}
		for _, v in verdicts do table.insert(out, v.reason) end
		table.sort(out)
		return table.concat(out, ",")
	end
	local function has(verdicts, reason) for _, v in verdicts do if v.reason == reason then return true end end return false end
	-- Runs a list of samples; returns the names of the first non-clean sample (or "" if all clean) and its index.
	local function run(state, samples, limits)
		for i, s in samples do
			local v = Movement.evaluate(state, s, limits or L)
			if #v > 0 then return names(v), i, v end
		end
		return "", nil, nil
	end

	local G = 196.2
	-- A body that stands at height y0, leaves the ground at clock `takeoff` with upward speed v0 and
	-- flies ballistically until it lands on a floor whose surface is at `surface`. Samples every 0.2 s
	-- from 0. The ground probe sees the floor when the root is within 5 studs of its surface
	-- (standing height 3 + GROUND_REACH 2). `vx` is the horizontal speed.
	local function flight(takeoff, v0, vx, y0, surface, duration, extra)
		local samples = {}
		local t = 0
		while t <= duration + 1e-9 do
			local air = t - takeoff
			local y, grounded = y0, true
			if air > 0 then
				y = y0 + v0 * air - 0.5 * G * air * air
				grounded = (y - surface) <= 5
				if y < surface + 3 then y = surface + 3 end
			end
			local s = mk(t, vx * t, y, 0, { grounded = grounded })
			if extra then for k, v in extra do s[k] = v end end
			table.insert(samples, s)
			t += 0.2
		end
		return samples
	end

	-- walking
	do
		local samples = {}
		for i = 1, 40 do table.insert(samples, mk(i * 0.2, 3.2 * i, 3, 0)) end
		eq(run(newState(), samples), "", "M1: walking at WalkSpeed for 8 s is clean")
		samples = {}
		for i = 1, 40 do table.insert(samples, mk(i * 0.2, 3.2 * i + ((i % 2 == 0) and 0.8 or -0.8), 3, 0)) end
		eq(run(newState(), samples), "", "M1: walking with +-0.8 stud position jitter is clean")
		-- standing still, strafing in circles
		samples = {}
		for i = 1, 40 do table.insert(samples, mk(i * 0.2, 5 * math.cos(i * 0.5), 3, 5 * math.sin(i * 0.5))) end
		eq(run(newState(), samples), "", "M1: strafing in a circle is clean")
	end

	-- lag: a burst after a stall
	do
		local function burst(ping)
			local samples = {}
			local x = 0
			for i = 1, 5 do table.insert(samples, mk(i * 0.2, x, 3, 0, { ping = ping })) end -- standing
			x = 29
			table.insert(samples, mk(1.2, x, 3, 0, { ping = ping })) -- 29 studs arrive in one sample (stall catch-up)
			return samples
		end
		eq(run(newState(), burst(0.3)), "", "M2: a 29-stud catch-up burst at 300 ms ping is clean")
		local what = run(newState(), burst(0.05))
		eq(what, "speed", "M2: the same burst at 50 ms ping is flagged: the ping allowance is what excuses it")
		-- ping is capped: a claimed ping of 100 s does not excuse anything
		local capped = run(newState(), burst(100))
		eq(capped, "", "M2: (ping 100 is capped to MAX_PING = 1: the 29-stud burst is within that allowance)")
		local huge = {}
		for i = 1, 5 do table.insert(huge, mk(i * 0.2, 0, 3, 0, { ping = 100 })) end
		table.insert(huge, mk(1.2, 60, 3, 0, { ping = 100 }))
		check(run(newState(), huge) ~= "", "M2: capped ping still flags a 60-stud burst")
	end

	-- speed hack, CFrame speed
	do
		local samples = {}
		for i = 1, 20 do table.insert(samples, mk(i * 0.2, 12 * i, 3, 0)) end -- 60 studs/s
		local what, index = run(newState(), samples)
		check(what == "speed" and index == 1, "M3: WalkSpeed 60 flagged on the first sample (" .. what .. " at " .. tostring(index) .. ")")
		samples = {}
		for i = 1, 40 do table.insert(samples, mk(i * 0.2, 6.4 * i, 3, 0)) end -- 32 studs/s (2x)
		what, index = run(newState(), samples)
		check(what == "speed" and index <= 5, "M3: 2x speed flagged within a second (at " .. tostring(index) .. ")")
		samples = {}
		for i = 1, 40 do table.insert(samples, mk(i * 0.2, 4.8 * i, 3, 0)) end -- 24 studs/s (1.5x)
		eq(run(newState(), samples), "", "M3: 1.5x speed stays inside the tolerance (documented blind spot)")
		-- a server-side WalkSpeed boost is followed
		samples = {}
		for i = 1, 40 do table.insert(samples, mk(i * 0.2, 6.4 * i, 3, 0, { walkSpeed = 32 })) end
		eq(run(newState(), samples), "", "M3: server-side WalkSpeed 32 and moving at 32 is clean")
		-- WalkSpeed drops from 32 to 16 while the client is still at 32 for a moment
		samples = {}
		for i = 1, 5 do table.insert(samples, mk(i * 0.2, 6.4 * i, 3, 0, { walkSpeed = 32 })) end
		for i = 6, 8 do table.insert(samples, mk(i * 0.2, 6.4 * 5 + 6.4 * (i - 5), 3, 0, { walkSpeed = 16 })) end
		eq(run(newState(), samples), "", "M3: sprint ending: the old, higher WalkSpeed counts for one window")
	end

	-- teleport
	do
		local what, index, v = run(newState(), { mk(0.2, 0, 3, 0), mk(0.4, 80, 3, 0) })
		check(what == "teleport" and index == 2 and not has(v, "speed"), "M4: 80-stud jump is 'teleport' only (" .. what .. ")")
		what = run(newState(), { mk(0.2, 0, 3, 0), mk(0.4, 0, 3, 90) })
		eq(what, "teleport", "M4: teleport along Z")
		what = run(newState(), { mk(0.2, 0, 3, 0), mk(0.4, 20, 3, 0) })
		eq(what, "speed", "M4: a 20-stud hop is 'speed', not a teleport")
		what = run(newState(), { mk(0.2, 0, 3, 0), mk(0.4, 0, 60, 0, { grounded = false }) })
		check(what:find("teleport") ~= nil, "M4: 57 studs straight up in one sample is a teleport (" .. what .. ")")
		what = run(newState(), { mk(0.2, 0, 3, 0), mk(0.4, 0 / 0, 3, 0) })
		eq(what, "teleport", "M4: a NaN position is a teleport")
		local st = newState()
		Movement.evaluate(st, mk(0.2, 0 / 0, 3, 0), L)
		check(st.lastGood.X == 0 and st.prev.X == 0, "M4: a NaN position never enters the state")
		what = run(newState(), { mk(0.2, 0, 3, 0), mk(0.4, math.huge, 3, 0) })
		eq(what, "teleport", "M4: an infinite position is a teleport")
	end

	-- falling and jumping (honest movement in the air)
	do
		-- every takeoff phase relative to the 0.2 s sample grid, for jump heights 7.2 (JumpHeight) and 50 power
		for _, v0 in { math.sqrt(2 * G * 7.2), 50 } do
			for _, phase in { 0.01, 0.05, 0.1, 0.15, 0.19, 0.2 } do
				local what, index = run(newState(), flight(1 + phase, v0, 16, 3, 0, 4))
				eq(what, "", string.format("M5: normal jump v0=%.1f takeoff phase %.2f is clean", v0, phase))
			end
		end
		-- a jump with a higher server JumpPower of 100 (a game with big jumps)
		for _, phase in { 0.01, 0.1, 0.19 } do
			local big = flight(1 + phase, 100, 16, 3, 0, 5, { jumpHeight = 100 * 100 / (2 * G) })
			eq(run(newState(), big), "", "M5: server JumpPower 100 jump is clean (phase " .. phase .. ")")
		end
		-- walking off a 20-stud ledge and landing
		local fall = flight(1.07, 0, 16, 23, 0, 5)
		eq(run(newState(23), fall), "", "M5: walking off a 20-stud ledge is clean")
		-- a 400-stud drop, true free fall
		eq(run(newState(403), flight(1.0, 0, 0, 403, 0, 12)), "", "M6: 400-stud free fall is clean")
		-- a 400-stud drop with air drag: speed capped at 120 studs/s (slower than the maths)
		local samples = { mk(0, 0, 403, 0) }
		local y, vy = 403, 0
		for step = 1, 60 do
			for _ = 1, 20 do vy = math.max(vy - G * 0.01, -120); y += vy * 0.01 end
			local grounded = (y <= 5)
			if y <= 3 then y = 3 end
			table.insert(samples, mk(step * 0.2, 0, y, 0, { grounded = grounded }))
			if y <= 3 then break end
		end
		eq(run(newState(403), samples), "", "M6: 400-stud fall with drag (capped at 120 studs/s) is clean")
	end

	-- fly: hover, rise, glide
	do
		local function airborne(fn, seconds)
			local samples = { mk(0.2, 0, 3, 0) } -- standing
			local t = 0.2
			while t < 0.2 + seconds do
				t += 0.2
				table.insert(samples, mk(t, 0, fn(t - 0.2), 0, { grounded = false }))
			end
			return samples
		end
		local what, index = run(newState(), airborne(function() return 8.5 end, 3))
		check(what == "fly" and index <= 6, "M7: hovering at +5.5 studs flagged within 1 s of takeoff (" .. what .. " at sample " .. tostring(index) .. ")")
		what, index = run(newState(), airborne(function(t) return 3 + 10 * t end, 3))
		check(what == "fly" or what == "jump", "M7: rising at 10 studs/s flagged (" .. what .. " at sample " .. tostring(index) .. ")")
		check(index <= 6, "M7: rise flagged within 1 s (sample " .. tostring(index) .. ")")
		what, index = run(newState(), airborne(function(t) return 8.5 - 5 * t end, 4))
		check(what == "fly" and index <= 6, "M7: slow glide (-5 studs/s) flagged (" .. what .. " at sample " .. tostring(index) .. ")")
		what, index = run(newState(), airborne(function(t) return 8.5 - 25 * t end, 4))
		check(what == "fly", "M7: fast glide (-25 studs/s) still flagged early (" .. what .. ")")
		-- hover that starts mid-fall: stops falling
		local fall = flight(1.0, 0, 0, 43, 0, 1.2)
		local hoverY = fall[#fall].position.Y
		local samples = fall
		for i = 1, 8 do table.insert(samples, mk(1.2 + i * 0.2, 0, hoverY, 0, { grounded = false })) end
		check(run(newState(43), samples) == "fly", "M7: stopping in mid-fall (hover) is flagged")
	end

	-- climbing a truss is legal, however long
	do
		local samples = {}
		for i = 1, 60 do table.insert(samples, mk(i * 0.2, 0, 3 + 12 * i * 0.2, 0, { grounded = false, climbing = true })) end
		eq(run(newState(), samples), "", "M8: a 12 s climb (144 studs) is clean")
		-- climbing then falling off
		local top = 3 + 12 * 60 * 0.2
		for i = 1, 25 do
			local air = i * 0.2
			table.insert(samples, mk(12 + air, 0, top - 0.5 * G * air * air, 0, { grounded = false }))
			if top - 0.5 * G * air * air < 8 then break end
		end
		eq(run(newState(), samples), "", "M8: climbing, then letting go and falling, is clean")
		-- the same rising motion without a truss is a cheat
		samples = {}
		for i = 1, 60 do table.insert(samples, mk(i * 0.2, 0, 3 + 12 * i * 0.2, 0, { grounded = false })) end
		check(run(newState(), samples) ~= "", "M8: the same climb with no truss nearby is flagged")
		-- swimming: out of the water and back, any depth
		samples = {}
		for i = 1, 40 do table.insert(samples, mk(i * 0.2, 0, -20 + 1.5 * i, 0, { grounded = false, swimming = true })) end
		eq(run(newState(), samples), "", "M8: swimming up 60 studs of water is clean")
	end

	-- super jump, infinite jump
	do
		local what, index = run(newState(), flight(1.0, 150, 0, 3, 0, 5))
		check(what == "jump", "M9: super jump (JumpPower 150 vs server 50) flagged as jump (" .. what .. ")")
		check(index <= 8, "M9: ...within the first second of the jump (sample " .. tostring(index) .. ")")
		-- infinite jump: a new jump every 0.3 s in mid-air (vy replaced by 50 each time)
		local samples = { mk(0, 0, 3, 0) }
		local y, vy, clock = 3, 0, 0
		local nextJump, jumps = 1.0, 0
		local sampleAt = 0.2
		for _ = 1, 600 do
			clock += 0.01
			if clock >= nextJump and jumps < 8 then vy = 50; jumps += 1; nextJump += 0.3 end
			vy -= G * 0.01
			y += vy * 0.01
			if y < 3 then y, vy = 3, 0 end
			if clock >= sampleAt - 1e-9 then
				table.insert(samples, mk(sampleAt, 0, y, 0, { grounded = (y <= 5) }))
				sampleAt += 0.2
			end
		end
		what, index = run(newState(), samples)
		check(what == "jump" or what == "fly", "M9: 8 stacked jumps flagged (" .. what .. " at sample " .. tostring(index) .. ")")
		-- spamming jump on the ground (bunny hop at the normal height) is fine
		samples = { mk(0, 0, 3, 0) }
		y, vy, clock, sampleAt = 3, 0, 0, 0.2
		local nextHop = 0.3
		for _ = 1, 800 do
			clock += 0.01
			if y <= 3.0001 and clock >= nextHop then vy = 50; nextHop = clock + 0.02 end
			vy -= G * 0.01
			y += vy * 0.01
			if y < 3 then y, vy = 3, 0 end
			if clock >= sampleAt - 1e-9 then
				table.insert(samples, mk(sampleAt, 3.2 * sampleAt, y, 0, { grounded = (y <= 5) }))
				sampleAt += 0.2
			end
		end
		eq(run(newState(), samples), "", "M9: jump spam (hop as soon as you land) while walking is clean")
	end

	-- grace, seat, hold
	do
		local st = newState()
		st.graceUntil = 5
		local samples = {}
		for i = 1, 24 do table.insert(samples, mk(i * 0.2, 12 * i, 3, 0)) end -- 60 studs/s during grace
		eq(run(st, samples), "", "M10: nothing flagged during grace")
		check(st.lastGood.X == 12 * 24, "M10: the baseline follows the player during grace")
		local after = {}
		for i = 1, 10 do table.insert(after, mk(4.8 + i * 0.2, 12 * 24 + 3.2 * i, 3, 0)) end
		eq(run(st, after), "", "M10: a normal walk right after grace is clean")
		after = { mk(7.2, 12 * 24 + 32 + 100, 3, 0) }
		eq(run(st, after), "teleport", "M10: a teleport after grace is flagged")

		st = newState()
		samples = {}
		for i = 1, 20 do table.insert(samples, mk(i * 0.2, 30 * i, 3, 0, { seated = true })) end
		eq(run(st, samples), "", "M11: a seated player (vehicle) is not judged")
		check(st.lastGood.X == 30 * 20, "M11: the baseline follows a seated player")
		eq(run(st, { mk(4.2, 30 * 20 + 3.2, 3, 0) }), "", "M11: standing up and walking is clean")

		-- snap hold: samples ignored until the hold ends, then judged against the baseline
		st = newState()
		Movement.reset(st, vec(0, 3, 0), 10, 0.6)
		eq(run(st, { mk(10.2, 40, 3, 0), mk(10.4, 50, 3, 0) }), "", "M12: samples inside the hold are ignored")
		check(st.lastGood.X == 0, "M12: ...and the baseline stays put")
		local what, index, v = run(st, { mk(10.8, 30, 3, 0) })
		eq(what, "speed", "M12: after the hold, 30 studs in 0.8 s is judged with the real elapsed time (speed)")
		st = newState()
		Movement.reset(st, vec(0, 3, 0), 10, 0.6)
		eq(run(st, { mk(10.8, 0, 3, 0), mk(11.0, 3.2, 3, 0) }), "", "M12: a player who was snapped back and stands still is clean afterwards")
	end

	-- noclip
	do
		local function noclipRun(a, b, steps)
			local st = newState()
			local what, index
			for i = 1, steps or 1 do
				local s = mk(i * 0.2, 6, 3, 0, { wallA = a, wallB = b })
				local v = Movement.evaluate(st, s, L)
				if #v > 0 then return names(v), i, st end
			end
			return "", nil, st
		end
		local what, _, st = noclipRun(2, 2)
		eq(what, "noclip", "M13: both rays hit (6 studs line, 2+2 studs before the wall -> 2 studs inside) = noclip")
		what, _, st = noclipRun(2, nil)
		eq(what, "", "M13: only the forward ray hits (ended inside a wall): not flagged yet")
		check(st.lastGood.X == 0 and st.pendingSince ~= nil, "M13: ...but the baseline stays outside and 'pending' starts")
		what, _, st = noclipRun(nil, 2)
		eq(what, "", "M13: only the backward ray hits: not flagged")
		what, _, st = noclipRun(nil, nil)
		eq(what, "", "M13: no hits: clean")
		check(st.lastGood.X == 6, "M13: clean sample moves the baseline")
		what = noclipRun(2.8, 2.9)
		eq(what, "", "M13: shallow overlap (0.3 studs inside) is ignored (corner cutting)")
		what = noclipRun(2.7, 2.7)
		eq(what, "noclip", "M13: 0.6 studs inside is flagged")
		-- stuck inside a wall for 1.5 s -> flagged; leaving earlier clears it
		local st2 = newState()
		local flaggedAt
		for i = 1, 12 do
			local v = Movement.evaluate(st2, mk(i * 0.2, 1, 3, 0, { wallA = 0.5 }), L)
			if #v > 0 and not flaggedAt then flaggedAt = i; eq(v[1].reason, "noclip", "M13: stuck verdict is noclip") end
		end
		check(flaggedAt and flaggedAt * 0.2 - 0.2 >= L.NOCLIP_STUCK_TIME - 1e-9 and flaggedAt <= 9, "M13: standing inside a wall is flagged after NOCLIP_STUCK_TIME (sample " .. tostring(flaggedAt) .. ")")
		st2 = newState()
		for i = 1, 6 do Movement.evaluate(st2, mk(i * 0.2, 1, 3, 0, { wallA = 0.5 }), L) end
		check(st2.pendingSince ~= nil, "M13: pending while inside")
		Movement.evaluate(st2, mk(1.4, 0, 3, 0), L)
		check(st2.pendingSince == nil, "M13: walking back out clears pending")
		-- thick wall, walking through it at normal speed: sample 1 ends inside (pending), sample 2 ends beyond (both rays) -> flagged
		st2 = newState()
		local v1 = Movement.evaluate(st2, mk(0.2, 3.2, 3, 0, { wallA = 1.0 }), L)           -- inside a 4-thick wall starting at x=1
		local v2 = Movement.evaluate(st2, mk(0.4, 6.4, 3, 0, { wallA = 1.0, wallB = 1.4 }), L) -- wall spans x 1..5; beyond it at 6.4
		check(#v1 == 0 and #v2 == 1 and v2[1].reason == "noclip", "M13: walking through a 4-stud wall: inside = pending, out the other side = noclip")
		-- corner check: the middle line is deep inside, the side lines decide
		local function sideRun(sides)
			local s = Movement.evaluate(newState(), mk(0.2, 6, 3, 0, { wallA = 1.5, wallB = 1.5, sides = sides }), L)
			return names(s)
		end
		eq(sideRun({ { a = nil, b = nil }, { a = 1, b = 1 } }), "", "M16: rounding a corner (outer side line clear) is not noclip")
		eq(sideRun({ { a = 2, b = 2 }, { a = 2.8, b = 2.9 } }), "", "M16: a side line that only grazes (0.3 inside) is not noclip")
		eq(sideRun({ { a = 2, b = nil }, { a = 2, b = 2 } }), "", "M16: a side line hitting from one end only is not a crossing")
		eq(sideRun({ { a = 1.5, b = 1.5 }, { a = 1.4, b = 1.6 } }), "noclip", "M16: all three lines cross a wide wall = noclip")
		eq(sideRun(nil), "noclip", "M16: no side lines = the middle line decides alone")
	end

	-- fling
	do
		eq(run(newState(), { mk(0.2, 0, 3, 0, { angularSpeed = 5000 }) }), "fling", "M14: huge angular velocity")
		eq(run(newState(), { mk(0.2, 0, 3, 0, { angularSpeed = 30 }) }), "", "M14: a fast turn (30 rad/s) is fine")
		eq(run(newState(), { mk(0.2, 0, 3, 0, { linearSpeed = 9e5 }) }), "fling", "M14: huge linear velocity")
		eq(run(newState(), { mk(0.2, 0, 3, 0, { linearSpeed = 300 }) }), "", "M14: terminal-ish fall speed (300) is fine")
	end

	-- lastGood only moves on clean samples ("snap"), and follows the player in "log" mode
	do
		local st = newState()
		Movement.evaluate(st, mk(0.2, 3.2, 3, 0), L)
		check(st.lastGood.X == 3.2, "M15: clean sample moves lastGood")
		local v = Movement.evaluate(st, mk(0.4, 90, 3, 0), L)
		check(#v == 1 and st.lastGood.X == 3.2, "M15: flagged sample leaves lastGood (snap mode)")
		local logLimits = table.clone(L)
		logLimits.MOVEMENT_ACTION = "log"
		st = newState()
		Movement.evaluate(st, mk(0.2, 3.2, 3, 0), logLimits)
		v = Movement.evaluate(st, mk(0.4, 90, 3, 0), logLimits)
		check(#v == 1 and st.lastGood.X == 90, "M15: log mode: the baseline follows even a flagged player")
	end
end
