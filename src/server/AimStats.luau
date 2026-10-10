--!nonstrict
-- Aim-cheat flags: the numbers behind "this player's aim looks scripted". Pure functions with no
-- game services, so the rules can be tested on their own; WeaponServer feeds them every shot
-- and reports a flag to Suspicion when one says yes.
--
--   local stats = AimStats.newState()                         one per player
--   AimStats.recordHit(stats, isHeadshot, limits)  -> flagged: boolean, ratio
--       Of the last AIM_WINDOW hits, are more than AIM_HEADSHOT_RATIO headshots? Judged once
--       AIM_MIN_HITS hits exist. After a flag the sample is cleared, so a player is flagged at most
--       once per AIM_MIN_HITS hits.
--   AimStats.recordShot(stats, time, direction, hit, limits)  -> flagged: boolean
--       Did the aim direction turn more than AIM_SNAP_ANGLE degrees within AIM_SNAP_TIME seconds of
--       the previous shot, and then hit? AIM_SNAP_COUNT of those inside AIM_SNAP_WINDOW seconds
--       raise the flag (then the count restarts).
--   AimStats.angleBetween(a, b)                    -> degrees between two directions
--
-- These are FLAGS, never blocks. Good players exist: a skilled sniper on a standing target can
-- have a very high headshot rate, and a fast flick between two enemies can be real. A flag means
-- "worth a look", so use it for review and for the weight you give it in Suspicion.onFlag,
-- not as an automatic ban. `limits` is Config.ANTI_CHEAT.

local AimStats = {}

function AimStats.newState()
	return {
		heads = {}, -- newest last: true for a headshot, false for a body hit
		lastTime = -math.huge, -- time of the previous shot
		lastDirection = nil, -- aim direction of the previous shot
		snaps = {}, -- times of recent "snap and hit" events
	}
end

function AimStats.angleBetween(a: Vector3, b: Vector3): number
	local cosine = a:Dot(b) / (a.Magnitude * b.Magnitude)
	return math.deg(math.acos(math.clamp(cosine, -1, 1)))
end

function AimStats.recordHit(state, isHeadshot: boolean, limits): (boolean, number)
	local heads = state.heads
	table.insert(heads, isHeadshot)
	while #heads > limits.AIM_WINDOW do
		table.remove(heads, 1)
	end
	if #heads < limits.AIM_MIN_HITS then
		return false, 0
	end
	local count = 0
	for _, head in heads do
		if head then
			count += 1
		end
	end
	local ratio = count / #heads
	if ratio > limits.AIM_HEADSHOT_RATIO then
		table.clear(heads)
		return true, ratio
	end
	return false, ratio
end

function AimStats.recordShot(state, time: number, direction: Vector3, hit: boolean, limits): boolean
	local last = state.lastDirection
	if hit and last and time - state.lastTime < limits.AIM_SNAP_TIME then
		if AimStats.angleBetween(last, direction) > limits.AIM_SNAP_ANGLE then
			table.insert(state.snaps, time)
		end
	end
	state.lastTime = time
	state.lastDirection = direction

	local snaps = state.snaps
	while snaps[1] and time - snaps[1] > limits.AIM_SNAP_WINDOW do
		table.remove(snaps, 1)
	end
	if #snaps >= limits.AIM_SNAP_COUNT then
		table.clear(snaps)
		return true
	end
	return false
end

return AimStats
