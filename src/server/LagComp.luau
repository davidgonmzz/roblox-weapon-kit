--!nonstrict
-- Lag compensation: where targets WERE. Every player sees the rest of the world a little in the past
-- (measured in Studio at zero ping: a moving target shows 0.2-0.33 s behind the server; a real server
-- adds the shooter's ping), so a shot aimed dead at a running target reaches the server after the
-- target has moved on, and the server's ray misses it. This keeps a short history of every target's
-- root CFrame. When a server ray misses all targets where they stand NOW, WeaponServer asks castPast
-- whether the same ray (same origin, same server-rolled direction, stopped by the same walls) went
-- through a target where it stood at some moment of the last Config.ANTI_CHEAT.REWIND_TIME seconds.
--
-- The client sends nothing new for this: no target, no time, no hit point. The price is the usual one
-- of lag compensation in any shooter: a target can be hit up to REWIND_TIME after it moved (just round
-- a corner, say), and a cheater can aim at that short trail as well as at the target.
--
-- Shapes: every BasePart of the target with CanQuery on counts, at its CURRENT offset from the root
-- (the body moves back with the root; limb animation is not replayed). A Ball is a sphere, every other
-- part its box (exact for Block parts, a little generous for meshes).
--
--   LagComp.new()                                a history of where models stood
--   history:record(models, now, window)          one sample per model (call every Heartbeat), keeps `window` seconds;
--                                                models not passed are forgotten
--   history:castPast(origin, direction, maxDistance, models)
--                                       -> part, position, distance of the first past hit along the ray, or nil

local TELEPORT_STEP = 20 -- studs between two samples: a teleport, so the trail before it is dropped
local SAME_SPOT = 0.2 -- studs: a sample this close to one already tested is skipped
local RESIZE_EVERY = 1 -- seconds between two measurements of how far a model's parts reach from its root
local AXES = { "X", "Y", "Z" }

local LagComp = {}
LagComp.__index = LagComp

local function rootOf(model: Model): BasePart?
	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- The parts a bullet can hit, each with its offset from the root (as the root is now).
local function hitboxes(model: Model, rootCFrame: CFrame)
	local list = {}
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.CanQuery ~= false then
			local size = part.Size
			local ball = part:IsA("Part") and part.Shape == Enum.PartType.Ball
			table.insert(list, {
				part = part,
				offset = rootCFrame:ToObjectSpace(part.CFrame),
				half = size / 2,
				radius = if ball then math.min(size.X, size.Y, size.Z) / 2 else nil,
			})
		end
	end
	return list
end

-- How far from the root any hitbox reaches (the radius of a sphere around the root holding them all).
local function reachOf(model: Model, rootCFrame: CFrame): number
	local reach = 0
	for _, box in hitboxes(model, rootCFrame) do
		reach = math.max(reach, box.offset.Position.Magnitude + box.half.Magnitude)
	end
	return reach
end

-- Distance from `point` to the segment origin -> origin + direction * length (direction is unit).
local function distanceToRay(point: Vector3, origin: Vector3, direction: Vector3, length: number): number
	local v = point - origin
	local t = math.clamp(v:Dot(direction), 0, length)
	return (v - direction * t).Magnitude
end

-- Distance along a ray (unit direction, in the box's own space) to where it enters a box of half-size
-- `half` centred on that space's origin, or nil. A ray that starts inside the box hits it at 0.
local function rayBox(o: Vector3, d: Vector3, half: Vector3): number?
	local enter, leave = 0, math.huge
	for _, axis in AXES do
		local oa, da, h = o[axis], d[axis], half[axis]
		if math.abs(da) < 1e-9 then
			if oa < -h or oa > h then
				return nil
			end
		else
			local t1, t2 = (-h - oa) / da, (h - oa) / da
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			enter = math.max(enter, t1)
			leave = math.min(leave, t2)
			if enter > leave then
				return nil
			end
		end
	end
	return enter
end

-- Same for a sphere of radius r centred on the origin.
local function raySphere(o: Vector3, d: Vector3, r: number): number?
	local c = o:Dot(o) - r * r
	if c <= 0 then
		return 0
	end
	local b = o:Dot(d)
	local disc = b * b - c
	if b > 0 or disc < 0 then
		return nil
	end
	return -b - math.sqrt(disc)
end

function LagComp.new()
	return setmetatable({ entries = {} }, LagComp)
end

function LagComp:record(models: { Model }, now: number, window: number)
	local entries = self.entries
	local seen = {}
	for _, model in models do
		local root = rootOf(model)
		local cf = root and root.CFrame
		if cf then
			seen[model] = true
			local entry = entries[model]
			if not entry then
				entry = { times = {}, cframes = {}, reach = 0, sizedAt = -math.huge }
				entries[model] = entry
			end
			local times, cframes = entry.times, entry.cframes
			local n = #times
			if n > 0 and (cf.Position - cframes[n].Position).Magnitude > TELEPORT_STEP then
				table.clear(times) -- teleported: where it stood before is not a trail anyone saw it walk
				table.clear(cframes)
			end
			table.insert(times, now)
			table.insert(cframes, cf)
			while now - times[1] > window do
				table.remove(times, 1)
				table.remove(cframes, 1)
			end
			if now - entry.sizedAt >= RESIZE_EVERY then
				entry.reach = reachOf(model, cf)
				entry.sizedAt = now
			end
		end
	end
	for model in entries do
		if not seen[model] then
			entries[model] = nil -- gone, dead and cleaned up, or untagged
		end
	end
end

function LagComp:castPast(origin: Vector3, direction: Vector3, maxDistance: number, models: { Model })
	local bestPart, bestDistance = nil, maxDistance
	for _, model in models do
		local entry = self.entries[model]
		local root = entry and rootOf(model)
		local rootNow = root and root.CFrame
		local n = if rootNow then #entry.times else 0
		-- Cheap test first: is the ray anywhere near the whole trail? (Most targets are nowhere near.)
		local latest = n > 0 and entry.cframes[n].Position
		local trail = 0
		for i = 1, n do
			trail = math.max(trail, (entry.cframes[i].Position - latest).Magnitude)
		end
		if n > 0 and distanceToRay(latest, origin, direction, bestDistance) <= entry.reach + trail then
			local boxes = hitboxes(model, rootNow)
			local tested = nil
			for i = n, 1, -1 do -- newest first: the smallest step back in time that hits wins
				local cf = entry.cframes[i]
				local at = cf.Position
				if
					(not tested or (at - tested).Magnitude >= SAME_SPOT)
					and distanceToRay(at, origin, direction, bestDistance) <= entry.reach
				then
					tested = at
					local o, d = cf:PointToObjectSpace(origin), cf:VectorToObjectSpace(direction)
					local hitPart, hitDistance = nil, bestDistance
					for _, box in boxes do
						local bo, bd = box.offset:PointToObjectSpace(o), box.offset:VectorToObjectSpace(d)
						local t = if box.radius then raySphere(bo, bd, box.radius) else rayBox(bo, bd, box.half)
						if t and t <= hitDistance then
							hitPart, hitDistance = box.part, t
						end
					end
					if hitPart then
						bestPart, bestDistance = hitPart, hitDistance
						break -- this target's newest hit; another target may still be nearer along the ray
					end
				end
			end
		end
	end
	if bestPart then
		return bestPart, origin + direction * bestDistance, bestDistance
	end
	return nil, nil, nil
end

return LagComp
