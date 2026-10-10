
---------------------------------------------------------------- NEW: Movement wrapper, in a mocked world
-- Runs Movement.init() against mock players and a mock physics world: ground at y = 0, solid
-- boxes, a truss, terrain water. The mover is "the client": each frame the test moves the root part
-- the way a real client would (or a cheat would), then fires Heartbeat.
do
	section("Movement (live world): rubber-band, teleport API, noclip, fly, climb, swim, seat, fling, log, errors")
	local Suspicion = require_(server.Suspicion)
	Players.list = {} -- forget the players of the earlier tests

	-- mock world --------------------------------------------------------------
	local boxes = {}
	local groundPart = new("Part", "Ground"); groundPart.Parent = Workspace
	local function addBox(minV, maxV)
		local inst = new("Part", "Wall"); inst.Parent = Workspace
		table.insert(boxes, { min = minV, max = maxV, inst = inst })
	end
	-- first entry of the segment origin -> origin + dir into the box, as a fraction in [0, 1]; nil if it
	-- starts inside (a Roblox ray never hits the part it starts in) or misses
	local function enter(origin, dir, box)
		local tmin, tmax = 0, 1
		local inside = true
		for _, axis in { "X", "Y", "Z" } do
			local o, d, lo, hi = origin[axis], dir[axis], box.min[axis], box.max[axis]
			if o <= lo or o >= hi then inside = false end
			if math.abs(d) < 1e-9 then
				if o < lo or o > hi then return nil end
			else
				local t1, t2 = (lo - o) / d, (hi - o) / d
				if t1 > t2 then t1, t2 = t2, t1 end
				tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
				if tmin > tmax then return nil end
			end
		end
		if inside then return nil end
		return tmin
	end
	local rayCount = 0
	rayHandler = function(origin, dir, params)
		rayCount += 1
		if dir.X == 0 and dir.Z == 0 and dir.Y < 0 then -- the ground probe
			if origin.Y + dir.Y <= 0 then return { Position = vec(origin.X, 0, origin.Z), Instance = groundPart } end
			return nil
		end
		local best, bestBox
		for _, box in boxes do
			local t = enter(origin, dir, box)
			if t and (not best or t < best) then best, bestBox = t, box end
		end
		if best then return { Position = origin + dir * best, Instance = bestBox.inst } end
		return nil
	end
	-- the ground probe is a box swept down: it lands if its bottom reaches the ground at y = 0
	blockHandler = function(cframe, size, dir, params)
		local bottom = cframe.Position.Y - size.Y / 2 + dir.Y
		if dir.X == 0 and dir.Z == 0 and dir.Y < 0 and bottom <= 0 then
			return { Position = vec(cframe.Position.X, 0, cframe.Position.Z), Instance = groundPart }
		end
		return nil
	end
	local truss = new("TrussPart", "Truss")
	Workspace.GetPartBoundsInRadius = function(self, position, radius)
		if math.abs(position.X - 100) < 3 then return { truss } end
		return {}
	end
	local waterVoxels = false
	Workspace.Terrain.ReadVoxels = function()
		if waterVoxels then return { { { Enum.Material.Water } }, Size = vec(1, 1, 1) } end
		return { { { Enum.Material.Air } }, Size = vec(1, 1, 1) }
	end

	-- mock players -----------------------------------------------------------------
	local function setPos(hrp, x, y, z)
		local v = vec(x, y, z)
		hrp.Position = v
		hrp.CFrame = CFrame.new(x, y, z)
	end
	local function spawn(name, id)
		local p = makePlayer(name, id)
		Players.PlayerAdded:fire(p)
		local c = new("Model", name .. "Char"); c.Parent = Workspace
		local hum = child(c, new("Humanoid"))
		hum.Health = 100; hum.MaxHealth = 100; hum.WalkSpeed = 16; hum.JumpPower = 50; hum.JumpHeight = 7.2
		hum.UseJumpPower = true; hum.RigType = Enum.HumanoidRigType.R15; hum.HipHeight = 2
		local hrp = child(c, new("Part", "HumanoidRootPart"))
		hrp.Size = vec(2, 2, 1); hrp.Anchored = false; hrp.CollisionGroup = "Default"
		hrp.AssemblyLinearVelocity = vec(0, 0, 0); hrp.AssemblyAngularVelocity = vec(0, 0, 0)
		setPos(hrp, 0, 3, 0)
		p.Character = c
		p.CharacterAdded:fire(c)
		return p, c, hum, hrp
	end
	local function frames(seconds, perFrame)
		for _ = 1, math.floor(seconds * 60 + 0.5) do
			advance(1 / 60)
			if perFrame then perFrame(1 / 60) end
			RunService.Heartbeat:fire()
		end
	end
	local function flags(p, reason)
		local total, reasons = Suspicion.total(p)
		if reason then return reasons[reason] or 0 end
		return total
	end

	Movement.init()

	-- W1: spawn grace, then an honest walk (and standing still) is clean ------------------
	local p1m, c1, h1, r1 = spawn("W1", 101)
	frames(1)
	setPos(r1, 500, 3, 0) -- the engine moving the new character into place during the spawn grace
	frames(1.5)
	frames(4, function(dt) setPos(r1, r1.Position.X + 16 * dt, 3, 0) end)
	eq(flags(p1m), 0, "W1: spawn move + a 4 s walk + standing: no flags")
	check((c1.pivots or 0) == 0, "W1: nobody was snapped")
	check(rayCount > 0 and rayCount < 4 * 60 * 2, "W1: raycasts only at the sample rate (" .. rayCount .. ")")

	-- W2: speed hack gets flagged and rubber-banded -----------------------------------------
	local xBefore = r1.Position.X
	frames(1.0, function(dt) setPos(r1, r1.Position.X + 60 * dt, 3, 0) end)
	check(flags(p1m, "speed") + flags(p1m, "teleport") >= 1, "W2: WalkSpeed-60 hack flagged (speed " .. flags(p1m, "speed") .. ", teleport " .. flags(p1m, "teleport") .. ")")
	check((c1.pivots or 0) >= 1, "W2: the cheater was put back (PivotTo called)")
	check(r1.Position.X < xBefore + 60 * 1.0 - 15, "W2: ...so he ended well short of where the hack would have taken him")
	local rej = last(rejR)
	check(rej and (rej[1] == "speed" or rej[1] == "teleport"), "W2: the demo remote said why (" .. tostring(rej and rej[1]) .. ")")
	eq(r1.AssemblyLinearVelocity.Magnitude, 0, "W2: velocity zeroed by the snap")
	frames(2) -- stand still: clean after the snap
	local afterSnap = flags(p1m)
	frames(2)
	eq(flags(p1m), afterSnap, "W2: standing still after a snap raises nothing")

	-- W3: grace API -----------------------------------------------------------------------------
	local pg, cg, hg, rg = spawn("W3", 103)
	frames(2.5)
	Movement.grace(pg, 3)
	frames(2, function(dt) setPos(rg, rg.Position.X + 60 * dt, 3, 0) end)
	eq(flags(pg), 0, "W3: Movement.grace: a 60 stud/s dash inside the grace is not flagged")
	frames(1.5)
	frames(1, function(dt) setPos(rg, rg.Position.X + 60 * dt, 3, 0) end)
	check(flags(pg) >= 1, "W3: ...and flagged once the grace is over")

	-- W4: server teleport API ------------------------------------------------------------------
	local pt, ct, ht, rt = spawn("W4", 104)
	frames(2.5)
	check(Movement.allowTeleport(pt, CFrame.new(300, 3, 40)), "W4: allowTeleport returns true")
	eq(rt.Position.X, 300, "W4: allowTeleport moved the character")
	frames(1)
	frames(2, function(dt) setPos(rt, rt.Position.X + 8 * dt, 3, 40) end)
	eq(flags(pt), 0, "W4: no flag after a sanctioned teleport")
	setPos(rt, 700, 3, 40) -- the same move by a client, unannounced
	frames(0.5)
	check(flags(pt, "teleport") >= 1, "W4: an unannounced teleport is flagged")
	local nobody = makePlayer("W4b", 1040)
	eq(Movement.allowTeleport(nobody, CFrame.new(0, 3, 0)), false, "W4: no character: false")

	-- W5: noclip through a 4-stud wall at walking speed -------------------------------------------
	addBox(vec(40, 0, -10), vec(44, 10, 10))
	local pn, cn, hn, rn = spawn("W5", 105)
	frames(2.5)
	Movement.allowTeleport(pn, CFrame.new(30, 3, 0))
	frames(1.7)
	local seenPivots, xAfterSnap = 0, nil
	frames(2, function(dt)
		if (cn.pivots or 0) > seenPivots then seenPivots = cn.pivots; xAfterSnap = xAfterSnap or rn.Position.X end
		setPos(rn, rn.Position.X + 16 * dt, 3, 0)
	end)
	check(flags(pn, "noclip") >= 1, "W5: walking through a wall is flagged noclip (" .. flags(pn, "noclip") .. ")")
	check(xAfterSnap and xAfterSnap < 40, "W5: and the player was put back in front of the wall (x = " .. string.format("%.1f", xAfterSnap or -1) .. ")")
	-- walking beside the wall, parallel, is fine
	local pn2, cn2, hn2, rn2 = spawn("W5b", 1050)
	frames(2.5)
	Movement.allowTeleport(pn2, CFrame.new(30, 3, 12))
	frames(1.7)
	frames(3, function(dt) setPos(rn2, rn2.Position.X + 16 * dt, 3, 12) end)
	eq(flags(pn2), 0, "W5: walking past the end of the wall is clean")

	-- W6: fly through the ground probe; legal jump; climb; swim --------------------------------
	local pf, cf, hf, rf = spawn("W6", 106)
	frames(2.5)
	local t0 = 0
	-- a real jump (v0 = 50): clean
	for _ = 1, 3 do
		t0 = 0
		frames(0.8, function(dt) t0 += dt; setPos(rf, rf.Position.X, math.max(3, 3 + 50 * t0 - 98.1 * t0 * t0), 0) end)
	end
	eq(flags(pf), 0, "W6: three ordinary jumps in a row are clean")
	frames(2.5, function(dt) setPos(rf, rf.Position.X, 9, 0) end) -- hover 6 studs up
	check(flags(pf, "fly") >= 1, "W6: hovering is flagged fly (" .. flags(pf, "fly") .. ")")
	-- climbing the truss at x = 100
	local pc, cc, hc, rc = spawn("W6b", 1060)
	frames(2.5)
	Movement.allowTeleport(pc, CFrame.new(100, 3, 0))
	frames(1.7)
	t0 = 0
	frames(5, function(dt) t0 += dt; setPos(rc, 100, 3 + 12 * t0, 0) end)
	eq(flags(pc), 0, "W6: climbing a truss for 5 s is clean")
	-- swimming: water around the root, floating 30 studs above the ground
	local ps2, cs2, hs2, rs2 = spawn("W6c", 1061)
	frames(2.5)
	waterVoxels = true
	frames(3, function(dt) setPos(rs2, 0, 33, 0) end)
	waterVoxels = false
	eq(flags(ps2), 0, "W6: floating in terrain water is clean")
	-- the same float without water is a cheat
	frames(3, function(dt) setPos(rs2, 0, 33, 0) end)
	check(flags(ps2) >= 1, "W6: ...and without water it is flagged")

	-- W7: seat, anchored, dead, fling ----------------------------------------------------------
	local pv, cv, hv, rv = spawn("W7", 107)
	frames(2.5)
	hv.SeatPart = {}
	frames(2, function(dt) setPos(rv, rv.Position.X + 80 * dt, 3, 0) end)
	eq(flags(pv), 0, "W7: a seated player (vehicle at 80 studs/s) is not judged")
	hv.SeatPart = nil
	frames(0.6, function(dt) setPos(rv, rv.Position.X + 3 * dt, 3, 0) end)
	eq(flags(pv), 0, "W7: standing up is clean (release grace)")
	rv.Anchored = true
	frames(1, function(dt) setPos(rv, rv.Position.X + 80 * dt, 3, 0) end)
	rv.Anchored = false
	frames(0.6)
	eq(flags(pv), 0, "W7: an anchored (frozen / cutscene) root is not judged")
	frames(2)
	rv.AssemblyAngularVelocity = vec(0, 3000, 0)
	frames(0.5)
	check(flags(pv, "fling") >= 1, "W7: fling spin flagged")
	eq(rv.AssemblyAngularVelocity.Magnitude, 0, "W7: ...and the spin is zeroed by the snap")
	hv.Health = 0
	local before = flags(pv)
	frames(1, function(dt) setPos(rv, rv.Position.X + 80 * dt, 3, 0) end)
	eq(flags(pv), before, "W7: a dead character is not judged")

	-- W8: log mode: counted, never moved --------------------------------------------------------
	L.MOVEMENT_ACTION = "log"
	local pl2, cl2, hl2, rl2 = spawn("W8", 108)
	frames(2.5)
	local startX = rl2.Position.X
	frames(2, function(dt) setPos(rl2, rl2.Position.X + 60 * dt, 3, 0) end)
	check(flags(pl2, "speed") >= 2, "W8: log mode counts a sustained speed hack (" .. flags(pl2, "speed") .. ")")
	check((cl2.pivots or 0) == 0, "W8: log mode never moves the player")
	check(rl2.Position.X > startX + 100, "W8: ...so he got where the hack took him")
	L.MOVEMENT_ACTION = "snap"

	-- W9: a character that goes away, a broken character, leaving ----------------------------------
	local px, cx, hx, rx = spawn("W9", 109)
	frames(1)
	px.CharacterRemoving:fire(cx)
	px.Character = nil
	frames(1)
	rx.Parent = nil
	local pb, cb, hb, rb = spawn("W9b", 1090)
	rb.AssemblyLinearVelocity = nil -- a part with missing properties: the wrapper must contain the error, not stop the loop
	frames(3)
	check(#warns > 0 and warns[#warns]:find("Movement"), "W9: an error in one sample is warned once, not thrown")
	Players.PlayerRemoving:fire(pb)
	frames(0.5)
	local pm, cm, hm, rm = spawn("W9c", 1091)
	frames(2.5)
	setPos(rm, 900, 3, 0)
	frames(0.5)
	check(flags(pm) >= 1, "W9: the loop kept running for the other players")
end

eq(#taskErrors, 0, "no task threw an unexpected error (" .. tostring(taskErrors[1]) .. ")")
