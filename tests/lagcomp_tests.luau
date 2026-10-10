---------------------------------------------------------------- LAG COMPENSATION: moving targets
-- A player sees every moving target a little in the past (Studio, zero ping: 0.2-0.35 s behind the
-- server), so a shot aimed dead at a running target reaches the server after it moved on. These tests
-- walk a target across the firing line, then shoot where it WAS: the hit must land inside REWIND_TIME,
-- with the right part (headshots too), through no wall, never across a teleport, never on something
-- the shooter may not hurt, and the target's turn must be respected. The mock ray (rayHandler) plays
-- the world where the target stands NOW: it misses, or stops at a wall.
section("Lag compensation: shots at moving targets register, and nothing else does")
do
	local savedRay, savedPVP, savedWindow = rayHandler, Config.PVP, L.REWIND_TIME
	local errorsAtStart = #taskErrors
	local Z, Y = -20, 5 -- the target walks along x at this depth, at the shooter's head height
	local HEAD_UP = 1.6

	local sp = makePlayer("LagShooter", 800)
	sp.Neutral = true
	Players.PlayerAdded:fire(sp)
	local sc = makeCharacter(sp, vec(0, Y, 0))
	new("Tool", "Pistol").Parent = sc
	local shotId = 0

	-- A target like the range dummies: invisible root (not hittable), torso on it, head above.
	local function target(name, tagged)
		local m = new("Model", name)
		local hum = child(m, new("Humanoid")); hum.Health = 100; hum.MaxHealth = 100
		local root = child(m, new("Part", "HumanoidRootPart")); root.Size = vec(2, 2, 1); root.CanQuery = false
		child(m, new("Part", "Torso")).Size = vec(2, 2, 1)
		child(m, new("Part", "Head")).Size = vec(1.2, 1.2, 1.2)
		if tagged then m.tags.WeaponKitTarget = true end
		m.Parent = Workspace
		return m, hum
	end
	local function place(m, cf)
		for _, pair in { { m.HumanoidRootPart, cf }, { m.Torso, cf }, { m.Head, cf * CFrame.new(0, HEAD_UP, 0) } } do
			pair[1].CFrame = pair[2]; pair[1].Position = pair[2].Position
		end
	end
	-- `seconds` of 60 Hz frames; move(t) places the target each frame (t = seconds since the start).
	local function frames(seconds, move)
		local n = math.floor(seconds * 60 + 0.5)
		for i = 1, n do
			advance(1 / 60)
			if move then move(i / 60) end
			RunService.Heartbeat:fire()
		end
	end
	-- Walks `m` along +x at 16 studs/s for `seconds`, from x0; returns x(secondsAgo) for the walk.
	local function walk(m, x0, seconds)
		frames(seconds, function(t) place(m, CFrame.new(x0 + 16 * t, Y, Z)) end)
		return function(ago) return x0 + 16 * (seconds - ago) end
	end
	-- One shot from the shooter's head at a world point (magazine topped up first). Returns the
	-- HitConfirm it caused (or nil) and whether the server took the shot at all: a "miss" only counts
	-- if the shot was accepted and judged.
	local data = PlayerData.get(sp)
	check(data ~= nil, "LC: the shooter's data is loaded")
	local function shootAt(point)
		shotId += 1
		data.mags.Pistol = 15
		local hitsBefore, shotsBefore = #hitR.fired, data.stats.shots
		local origin = vec(0, Y, 0)
		fire(sp, origin, (point - origin).Unit, shotId)
		return if #hitR.fired > hitsBefore then hitR.fired[#hitR.fired].args else nil, data.stats.shots == shotsBefore + 1
	end
	local function missed(point)
		local h, accepted = shootAt(point)
		return accepted and h == nil
	end
	local function miss() rayHandler = function() return nil end end

	local walker, wh = target("Walker", true)
	place(walker, CFrame.new(-20, Y, Z))
	frames(0.5) -- standing still first: an old trail that must not matter

	-- LC1-3: shot at where it stood 0.3 s ago (what a shooter sees) -> body hit / headshot; the newest spot counts too.
	miss()
	local xAt = walk(walker, -4, 0.5)
	local h = shootAt(vec(xAt(0.3), Y, Z))
	check(h and h[1] == 20 and h[2] == false, "LC1: a body shot at where the target was 0.3 s ago hits (20, no headshot)")
	eq(wh.Health, 80, "LC1: and does its damage")
	xAt = walk(walker, -4, 0.5)
	h = shootAt(vec(xAt(0.3), Y + HEAD_UP, Z))
	check(h and h[1] == 40 and h[2] == true, "LC2: a head shot at where the head was 0.3 s ago is a headshot (40)")
	xAt = walk(walker, -4, 0.5)
	h = shootAt(vec(xAt(0), Y, Z))
	check(h and h[1] == 20, "LC3: a shot at where it stands now hits too, even if the live ray missed")
	eq(wh.Health, 20, "LC1-3: 20 + 40 + 20 damage taken")
	wh.Health = 100

	-- LC4: older than REWIND_TIME (0.6 s) -> miss.
	xAt = walk(walker, -8, 1)
	check(missed(vec(xAt(0.9), Y, Z)), "LC4: a shot at where it was 0.9 s ago misses (window 0.6 s)")
	frames(0.25) -- it stands still now: the spot it had 0.5 s ago is 0.75 s old
	check(missed(vec(xAt(0.5), Y, Z)), "LC4: the trail keeps ageing while nobody shoots")

	-- LC5-6: a wall between the shooter and where the target was stops the shot; a wall behind it does not.
	local wall = child(Workspace, new("Part", "LagWall"))
	xAt = walk(walker, -4, 0.5)
	local past = vec(xAt(0.3), Y, Z)
	rayHandler = function(origin, dir) return { Position = origin + dir.Unit * 10, Instance = wall } end
	check(missed(past), "LC5: a wall 10 studs out stops a shot at a target 20 studs out where it was")
	eq(wh.Health, 100, "LC5: no damage through the wall")
	xAt = walk(walker, -4, 0.5)
	past = vec(xAt(0.3), Y, Z)
	rayHandler = function(origin, dir) return { Position = origin + dir.Unit * 30, Instance = wall } end
	check(shootAt(past) ~= nil, "LC6: a wall behind the target's old spot does not stop the hit")
	wall.Parent = nil
	wh.Health = 100
	miss()

	-- LC7: teleported (a respawn spot, an admin :tp, the kit's own rubber-band) -> the trail before it is gone.
	xAt = walk(walker, -4, 0.3)
	local before = vec(xAt(0.1), Y, Z)
	frames(0.1, function() place(walker, CFrame.new(80, Y, Z)) end)
	check(missed(before), "LC7: a shot at where it stood before a teleport misses (0.2 s ago)")

	-- LC8: turning is replayed: torso 2 wide x 1 deep. Turned 90 deg at x = 0 for 0.3 s, then snapped to x = 5.
	frames(0.3, function() place(walker, CFrame.new(0, Y, Z) * CFrame.Angles(0, math.pi / 2, 0)) end)
	frames(0.1, function() place(walker, CFrame.new(5, Y, Z)) end)
	check(missed(vec(0.8, Y, Z)), "LC8: 0.8 studs off centre misses the turned (1 wide) torso")
	frames(0.25)
	check(shootAt(vec(0.3, Y, Z)) ~= nil, "LC8: 0.3 studs off centre hits it")
	wh.Health = 100

	-- LC9: nothing the shooter may not hurt: a dead target, an untagged model, a player with PVP off.
	frames(0.3)
	xAt = walk(walker, -4, 0.5)
	wh.Health = 0
	check(missed(vec(xAt(0.3), Y, Z)), "LC9: a dead target is not hit where it was")
	wh.Health = 100
	walker.tags.WeaponKitTarget = nil
	xAt = walk(walker, -4, 0.5)
	check(missed(vec(xAt(0.3), Y, Z)), "LC9: an untagged model (not a target) is not hit")
	walker.tags.WeaponKitTarget = true

	local runner = makePlayer("LagRunner", 801)
	runner.Neutral = true
	local rc, rh = target("RunnerChar", false)
	runner.Character = rc
	Config.PVP = false
	xAt = walk(rc, -4, 0.5)
	check(missed(vec(xAt(0.3), Y, Z)), "LC9: PVP off: a running player is not hit where he was")
	Config.PVP = true
	xAt = walk(rc, -4, 0.5)
	h = shootAt(vec(xAt(0.3), Y, Z))
	check(h ~= nil and rh.Health == 80, "LC9: PVP on: a running player IS hit where he was (players are followed too)")
	Config.PVP = savedPVP

	-- LC10: REWIND_TIME = 0 switches it off: only where targets stand now counts.
	L.REWIND_TIME = 0
	xAt = walk(walker, -4, 0.5)
	check(missed(vec(xAt(0.2), Y, Z)), "LC10: REWIND_TIME 0: a shot at where it was 0.2 s ago misses")
	L.REWIND_TIME = savedWindow

	-- LC11: the nearer of two targets along the ray takes the bullet.
	local other, oh = target("Behind", true)
	frames(0.3, function()
		place(walker, CFrame.new(0, Y, Z))
		place(other, CFrame.new(0, Y, Z - 10))
	end)
	frames(0.2, function(t)
		place(walker, CFrame.new(16 * t, Y, Z))
		place(other, CFrame.new(16 * t, Y, Z - 10))
	end)
	wh.Health, oh.Health = 100, 100
	check(shootAt(vec(0, Y, Z)) ~= nil and wh.Health == 80 and oh.Health == 100, "LC11: the nearer target's old spot takes the shot, not the one behind it")

	-- clean up for the tests after this file
	walker.Parent = nil
	other.Parent = nil
	runner.Character = nil
	Players.PlayerRemoving:fire(runner)
	table.remove(Players.list, table.find(Players.list, runner))
	Players.PlayerRemoving:fire(sp)
	table.remove(Players.list, table.find(Players.list, sp))
	sc.Parent = nil
	rayHandler = savedRay
	eq(#taskErrors, errorsAtStart, "LC: no task threw an error")
end
