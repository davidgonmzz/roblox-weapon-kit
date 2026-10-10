--!nonstrict
-- Server-side movement checks. Roblox lets the client own its character's physics, so the server
-- cannot stop a modified client from moving wrongly; what it CAN do is look at where the
-- character is every Config.ANTI_CHEAT.SAMPLE_INTERVAL seconds, notice a move no honest character
-- could make, count it (Suspicion) and put the player back at their last clean position.
--
-- Checks (each is a Suspicion reason): speed, teleport, fly, jump, noclip, fling.
--   speed     horizontal distance over the last second beats WalkSpeed * tolerance + slack + lag
--   teleport  one sample moved further than any walk or lag spike can explain
--   jump      rose higher above the last standing height than the server's JumpHeight allows
--             (super jump; infinite jump as soon as the stack passes one jump)
--   fly       stayed above the best possible jump / fall curve: a hover, a rise, a slow glide
--   noclip    the straight line from the last clean position to here passes through a solid part
--             (two raycasts, one from each end, must both hit, and the same line shifted half a
--             character to each side too: rounding a corner is not a noclip), or the character
--             sits INSIDE a solid part for NOCLIP_STUCK_TIME
--   fling     absurd angular or linear velocity of the root part
-- All numbers live in Config.ANTI_CHEAT, one comment each.
--
-- The file has two halves. The top half is PURE maths on plain values (newState, reset,
-- suppressed, evaluate): given the state and a sample it returns verdicts and touches nothing else, so
-- the harness can feed it walks, falls, jumps and hacks. The bottom half is the part that talks
-- to Roblox: it builds the sample (positions, server-side Humanoid numbers, ping, raycasts),
-- runs the loop, applies the response and exposes the API a game must call.
--
-- What the checks follow by themselves (Config.ANTI_CHEAT.TRUST_SERVER_MOVES): whatever the SERVER does
-- to a character, as an ALLOWANCE, never as time off. A server script moving it (PivotTo, Model:MoveTo,
-- root.CFrame = ..., admin :tp / :bring) carries the checks' memory along by the distance the server
-- moved it (Movement.shift), like Movement.allowTeleport; a server write to its velocity (knockback,
-- launch pad, admin fling) and an active server-made mover with a speed the kit can read (BodyVelocity,
-- LinearVelocity, ...) widen the limits by that speed (Movement.push). Only movers that push with a FORCE
-- (VectorForce, BodyForce, ...) have no speed to read: they switch the checks off while they last. The
-- signals behind this fire only for server writes, never for anything the player's own client does, and
-- the kit's own rubber-band is recognised and ignored. Only ISOLATED writes are trusted: a script writing
-- the root over and over (a face-the-target loop) is distrusted for a while (SERVER_WRITE_LIMIT). A flag
-- is judged one frame after the sample, and a sample taken in the frame of a server move is taken back
-- (rewind), so a server move made in the same frame (its signal may be deferred) is never mistaken for a
-- cheat. Standing on a moving part (conveyor, platform) widens the speed allowance
-- by that part's speed, and speeds and jump power changed ON THE SERVER (Humanoid.WalkSpeed,
-- JumpPower, JumpHeight) are followed too. Exempt players (Movement.exempt, EXEMPT_USER_IDS,
-- EXEMPT_GROUP, the Player attribute "WeaponKitExempt") are never judged.
--
-- What a GAME still has to do: things the CLIENT does to its own character are invisible to the
-- server and look exactly like a cheat: a client-side sprint / dash / double jump / grapple /
-- wall-run, a client-side admin :fly / :noclip. Make them ask the server, exempt the admins, or
-- call Movement.grace for the stretch (and start in "log" mode):
--   Movement.grace(player, seconds)         nothing is flagged for that long and the baseline follows
--                                           the player
--   Movement.allowTeleport(player, cframe)  a server-side teleport; optional now, but it states the intent
--   Movement.exempt(player, on)             never judge this player
--
-- Known blind spots (see README "Exploit coverage"): speed boosts inside the tolerance, a hover
-- within GROUND_REACH of a floor (or GROUND_MARGIN past a ledge) or next to a truss or tagged
-- ladder, noclip through parts that are not collidable or narrower than a character, and anything
-- a tick shorter than the sample interval.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("WeaponKitShared")
local Config = require(Shared:WaitForChild("Config"))
local Suspicion = require(script.Parent.Suspicion)

local Movement = {}

local LIMITS = Config.ANTI_CHEAT
local DEFAULT_GRAVITY = 196.2
local MAX_COORD = 1e7 -- no real position is farther from the origin than this

----------------------------------------------------------------------------------- pure half

-- A fresh state for a character standing at `position` at clock `time`.
--   lastGood        the last position that passed every check (where a snap puts the player)
--   prev, lastTime  the previous sample (steps are measured from here)
--   window          { { t, dt, dist, speed } } horizontal steps of the last SPEED_WINDOW seconds
--   groundY         height of the last sample that was standing / climbing / swimming
--   lastGroundTime  clock of that sample
--   airStart        clock of the first sample of the current stretch in the air, or nil
--   graceUntil      nothing is judged before this clock; the baseline follows the player
--   holdUntil       after a snap: samples are ignored until this clock, the baseline stays put
--   pendingSince    clock since when the player seems to be INSIDE a solid part, or nil
--   carriedSpeed    speed (studs/s) of the moving part last stood on: it keeps carrying a player who
--                   steps off or jumps from it
--   push            a push the server gave (see Movement.push), or nil. Replaced, never changed in place.
function Movement.newState(position: Vector3, time: number)
	return {
		lastGood = position,
		prev = position,
		lastTime = time,
		window = {},
		groundY = position.Y,
		lastGroundTime = time,
		airStart = nil,
		graceUntil = 0,
		holdUntil = nil,
		pendingSince = nil,
		carriedSpeed = 0,
		push = nil,
	}
end

-- Forget everything about the recent past and start again from `position` (after a snap, or a
-- sanctioned teleport). `hold` seconds of samples are then ignored (0 or nil: none).
function Movement.reset(state, position: Vector3, time: number, hold: number?)
	state.lastGood = position
	state.prev = position
	state.lastTime = time
	table.clear(state.window)
	state.groundY = position.Y
	state.lastGroundTime = time
	state.airStart = nil
	state.pendingSince = nil
	state.carriedSpeed = 0
	state.push = nil
	state.holdUntil = if hold and hold > 0 then time + hold else nil
end

-- Samples are ignored for `seconds` while the client catches up with something the server did; whatever
-- the player does meanwhile is judged in one go by the first sample after it (the baseline stays put).
-- A hold already running is not made longer: a game cannot keep a player unjudged by repeating moves.
function Movement.hold(state, time: number, seconds: number)
	if seconds > 0 and not (state.holdUntil and time < state.holdUntil) then
		state.holdUntil = time + seconds
	end
end

-- A move the SERVER made (a script's PivotTo, an admin :tp): everything the checks remember is carried
-- along by `offset`, the distance the server moved the character. It is not a fresh start: what the
-- player did before the move and does after it is still measured from where they were, so a cheater
-- gains no free time and the spot they were at is not taken as clean. `hold`: see Movement.hold.
function Movement.shift(state, offset: Vector3, time: number, hold: number?)
	state.lastGood += offset
	state.prev += offset
	state.groundY += offset.Y
	Movement.hold(state, time, hold or 0)
end

-- True if a sample at `time` would not be judged (grace, a snap's hold, or sitting in a seat).
-- The impure half uses it to skip the raycasts for samples that are going to be ignored.
function Movement.suppressed(state, time: number, seated: boolean?): boolean
	return seated == true or time < state.graceUntil or (state.holdUntil ~= nil and time < state.holdUntil)
end

-- Nothing is judged, but the baseline moves with the player. Every such sample counts as a
-- fresh start, so the first judged sample afterwards measures only what happened since.
local function follow(state, sample)
	local position = sample.position
	state.lastGood = position
	state.prev = position
	state.lastTime = sample.time
	table.clear(state.window)
	state.groundY = position.Y
	state.lastGroundTime = sample.time
	state.airStart = nil
	state.pendingSince = nil
	state.carriedSpeed = 0
	state.push = nil
end

-- The greatest height above the takeoff point that a body launched upwards at speed `v` can be at
-- for ANY airtime in [t0, t1]. height(t) = v*t - g*t^2/2 is a parabola: the best value is at its
-- peak (t = v/g) if the range holds it, else at the end of the range nearest to it. A range
-- (not one time) because a sample only knows the takeoff happened somewhere in the last interval.
local function highestRise(v: number, g: number, t0: number, t1: number): number
	local t = math.min(math.max(v / g, t0), t1)
	return v * t - 0.5 * g * t * t
end

-- The speed of the floor under the player that may be added to the allowance: nothing for a missing,
-- zero, negative or NaN value, never more than `cap`.
local function groundAllowance(speed: number?, cap: number): number
	if not (speed and speed > 0) then
		return 0
	end
	return math.min(speed, cap)
end

-- How far up (studs above groundY + one full jump) a push lets the character be: `peak` = the most at any
-- time, `curve` = the most for an airtime since the push in [t0, t1]. A sustained push (a mover holding a
-- velocity) climbs at `lift` the whole time; a released one is a throw that gravity brings down. The
-- client starts a push up to `ping` after the server gave it, hence the wider range.
local function pushReach(push, t0: number, t1: number, ping: number, gravity: number, tolerance: number)
	if push.sustained then
		local height = push.base + push.lift * tolerance * (math.max(t1, 0) + ping)
		return height, height
	end
	local launch = push.lift * math.sqrt(tolerance)
	local peak = push.base + launch * launch / (2 * gravity)
	return peak, push.base + highestRise(launch, gravity, math.max(t0 - ping, 0), math.max(t1, 0))
end

-- A push the SERVER gave: a velocity write (knockback, launch pad, admin fling), or a mover with a known
-- speed in the character (BodyVelocity, LinearVelocity ...). It is an ALLOWANCE, not a grace: the checks
-- keep judging, with `speed` studs/s more sideways, a throw upwards at `lift` studs/s on top of a full
-- jump, and fling limits raised to `linear` (studs/s) / `angular` (rad/s). A cheater gets at most what
-- the push gave. `sustained` = a mover still holding it (refreshed every sample); a push that is not
-- sustained lasts SERVER_PUSH_TIME, and after that until the player is held up again (lands, climbs).
-- push = { speed, lift, linear, angular, sustained }, all optional (0 / false).
function Movement.push(state, push, time: number, limits, gravity: number)
	local old = state.push
	local sustained = push.sustained == true
	local base, at = 0, time
	if old then
		if old.sustained and sustained then
			base, at = old.base, old.at -- the same climb goes on
		else
			-- a new push starts from the highest the old one could have taken them by now
			local _, soFar = pushReach(old, 0, time - old.at, 0, gravity, limits.JUMP_TOLERANCE)
			base = soFar
		end
	end
	local function larger(key: string): number
		return math.max(push[key] or 0, if old then old[key] else 0)
	end
	state.push = {
		at = at,
		base = math.max(base, 0),
		sustained = sustained,
		speed = larger("speed"),
		lift = if old and old.sustained and sustained then larger("lift") else push.lift or 0,
		linear = larger("linear"),
		angular = larger("angular"),
	}
end

local function addVerdict(verdicts, reason: string, value: number, limit: number)
	table.insert(verdicts, { reason = reason, value = value, limit = limit })
end

-- Corner check for noclip: the same line shifted sideways (left and right, about half a character)
-- must cross solid stuff as deeply too. A character rounding a corner between two samples cuts
-- that corner with the straight line, but the shifted line on the outside of the turn passes clear
-- of it; a wall walked through blocks all three. No side lines (nil): the middle line decides alone.
local function crossesBeside(sides, length: number, minDepth: number): boolean
	if not sides then
		return true
	end
	for _, side in sides do
		if not (side.a and side.b and length - side.a - side.b >= minDepth) then
			return false
		end
	end
	return true
end

-- Judges one sample. Returns a list of verdicts { reason, value, limit } (empty = clean) and
-- updates `state`. `limits` is Config.ANTI_CHEAT.
--
-- sample:
--   time, position           clock and root position
--   walkSpeed                the SERVER's Humanoid.WalkSpeed
--   jumpHeight, gravity      studs one jump rises (from the server's JumpPower / JumpHeight), Workspace.Gravity
--   ping                     seconds, already capped
--   grounded                 a collidable surface within reach below the feet
--   climbing, swimming       a TrussPart close / Terrain water around the root
--   seated                   Humanoid.SeatPart ~= nil, or any other reason this sample must not be judged
--                            (the player is exempt, or a server mover is on the character)
--   groundSpeed              horizontal speed (studs/s) of the part the character stands on, 0 if none
--                            or not one the server controls. Capped here by limits.GROUND_SPEED_CAP
--   angularSpeed, linearSpeed  magnitude of the root's AssemblyAngularVelocity / AssemblyLinearVelocity
--   wallA                    noclip rays, only when the move since lastGood is long enough:
--                            distance from lastGood to the first solid part towards here, or nil
--   wallB                    distance from here to the first solid part back towards lastGood, or nil
--   sides                    only when wallA and wallB both hit: { { a, b }, { a, b } }, the same two
--                            rays on lines shifted left and right (corner check, see crossesBeside)
function Movement.evaluate(state, sample, limits)
	local verdicts = {}
	local now = sample.time
	local position = sample.position

	-- A position that is not a finite number is not a position: never let it into the state.
	if
		not (math.abs(position.X) < MAX_COORD and math.abs(position.Y) < MAX_COORD and math.abs(position.Z) < MAX_COORD)
	then
		addVerdict(verdicts, "teleport", math.huge, MAX_COORD)
		return verdicts
	end

	if state.holdUntil then
		if now < state.holdUntil then
			return verdicts
		end
		state.holdUntil = nil
	end
	if sample.seated or now < state.graceUntil then
		follow(state, sample)
		return verdicts
	end

	local dt = math.max(now - state.lastTime, 0.001)
	local dx, dy, dz = position.X - state.prev.X, position.Y - state.prev.Y, position.Z - state.prev.Z
	local horizontal = math.sqrt(dx * dx + dz * dz)
	local ping = math.clamp(sample.ping or 0, 0, limits.MAX_PING)
	local walkSpeed = math.max(sample.walkSpeed, 0)
	-- A moving floor (conveyor, platform) carries the player: its speed (capped) is extra allowance.
	-- It keeps carrying through the air and for the step after stepping off, hence the max.
	local ground = math.max(groundAllowance(sample.groundSpeed, limits.GROUND_SPEED_CAP), state.carriedSpeed)
	if sample.grounded then
		state.carriedSpeed = groundAllowance(sample.groundSpeed, limits.GROUND_SPEED_CAP)
	end
	-- A push the server gave (Movement.push) widens the limits by what it gave, nothing more.
	local push = state.push
	local pushSpeed, pushLift = 0, 0
	if push then
		pushSpeed = push.speed
		pushLift = push.lift * limits.SPEED_TOLERANCE
		ground += pushSpeed
	end

	-- Standing, climbing and swimming all "hold the character up": its height is the new baseline.
	local supported = sample.grounded or sample.climbing or sample.swimming
	if supported then
		state.groundY = position.Y
		state.lastGroundTime = now
		state.airStart = nil
	elseif not state.airStart then
		state.airStart = now
	end

	-- Horizontal path over the last SPEED_WINDOW seconds: a step covers the interval ending at its
	-- clock, so the ones that ended a full window ago or earlier fall out.
	local window = state.window
	table.insert(window, { t = now, dt = dt, dist = horizontal, speed = walkSpeed, ground = ground })
	while window[1] and window[1].t <= now - limits.SPEED_WINDOW + 1e-9 do
		table.remove(window, 1)
	end
	local distance, span, fastest, carried = 0, 0, walkSpeed, 0
	for _, step in window do
		distance += step.dist
		span += step.dt
		fastest = math.max(fastest, step.speed) -- a WalkSpeed that just dropped still counts for a moment
		carried += step.ground * step.dt -- how far the floor under that step took the player
	end

	-- teleport: one step beyond anything walking (plus a lag spike) explains.
	local stepLimit = limits.TELEPORT_DISTANCE + fastest * (limits.SPEED_TOLERANCE * dt + ping) + ground * dt
	if horizontal > stepLimit then
		addVerdict(verdicts, "teleport", horizontal, stepLimit)
	elseif dy > limits.TELEPORT_DISTANCE + pushLift * dt then
		addVerdict(verdicts, "teleport", dy, limits.TELEPORT_DISTANCE + pushLift * dt)
	end

	-- speed: skipped when it is already a teleport (that says it better).
	local allowed = fastest * limits.SPEED_TOLERANCE * span + limits.SPEED_SLACK + fastest * ping + carried
	if distance > allowed and #verdicts == 0 then
		addVerdict(verdicts, "speed", distance, allowed)
	end

	-- jump and fly: only while nothing holds the character up.
	if not supported then
		local rise = position.Y - state.groundY
		local gravity = math.max(sample.gravity or DEFAULT_GRAVITY, 1)
		local jumpLimit = sample.jumpHeight * limits.JUMP_TOLERANCE + limits.JUMP_SLACK
		local launch = math.sqrt(2 * gravity * jumpLimit) -- the fastest upward speed a jump may start with
		local best = highestRise(launch, gravity, now - state.airStart, now - state.lastGroundTime)
		local peak = jumpLimit
		if push then
			-- a push may come at the top of a jump: its throw starts one full jump up
			local pushPeak, pushCurve =
				pushReach(push, now - dt - push.at, now - push.at, ping, gravity, limits.JUMP_TOLERANCE)
			peak += pushPeak
			best = math.max(best, jumpLimit + pushCurve)
		end
		if rise > peak then
			addVerdict(verdicts, "jump", rise, peak)
		else
			local flyLimit = math.max(best, -limits.FLY_DROP_CAP) + limits.FLY_SLACK
			if rise > flyLimit then
				addVerdict(verdicts, "fly", rise, flyLimit)
			end
		end
	end

	-- noclip: wallA / wallB are the two rays between the last clean position and here. Both hit =
	-- the line crosses solid stuff. Only wallA = the character ended up INSIDE a solid part (its
	-- ray cannot hit the part it starts in): not clean yet, and flagged if it stays there.
	local pending = false
	if sample.wallA then
		if sample.wallB then
			local lx, ly, lz =
				position.X - state.lastGood.X, position.Y - state.lastGood.Y, position.Z - state.lastGood.Z
			local length = math.sqrt(lx * lx + ly * ly + lz * lz)
			local depth = length - sample.wallA - sample.wallB
			if depth >= limits.NOCLIP_MIN_DEPTH and crossesBeside(sample.sides, length, limits.NOCLIP_MIN_DEPTH) then
				addVerdict(verdicts, "noclip", depth, limits.NOCLIP_MIN_DEPTH)
			end
		else
			pending = true
		end
	end
	if pending then
		state.pendingSince = state.pendingSince or now
		if now - state.pendingSince >= limits.NOCLIP_STUCK_TIME then
			addVerdict(verdicts, "noclip", now - state.pendingSince, limits.NOCLIP_STUCK_TIME)
		end
	else
		state.pendingSince = nil
	end

	-- fling (a server push raises the limits to what it gave, with SPEED_TOLERANCE on top)
	local angularLimit, linearLimit = limits.FLING_ANGULAR, limits.FLING_LINEAR
	if push then
		angularLimit = math.max(angularLimit, push.angular * limits.SPEED_TOLERANCE)
		linearLimit = math.max(linearLimit, push.linear * limits.SPEED_TOLERANCE)
	end
	if (sample.angularSpeed or 0) > angularLimit then
		addVerdict(verdicts, "fling", sample.angularSpeed, angularLimit)
	elseif (sample.linearSpeed or 0) > linearLimit then
		addVerdict(verdicts, "fling", sample.linearSpeed, linearLimit)
	end

	-- A push that is over (not held by a mover, SERVER_PUSH_TIME and the lag gone, and the player held up
	-- again) stops widening the limits. This sample's own step still had it.
	if push and not push.sustained and supported and now - push.at >= limits.SERVER_PUSH_TIME + ping then
		state.push = nil
	end

	state.prev = position
	state.lastTime = now
	-- lastGood moves only on a clean sample. In "log" mode nobody is ever put back, so the
	-- baseline simply follows the player (otherwise every later raycast would span the whole cheat).
	if not pending and (#verdicts == 0 or limits.MOVEMENT_ACTION == "log") then
		state.lastGood = position
	end
	return verdicts
end

----------------------------------------------------------------------------------- impure half

-- [Player] = {
--   character     the character this record belongs to
--   state         the pure state above; nil until the first sample sees the character's parts
--   nextAt        os.clock() of this player's next sample (staggered between players)
--   spawnGraceUntil, graceUntil   queued graces, copied into the state when it is created
--   lastGoodCFrame  full CFrame of state.lastGood (the pure state only keeps the position)
--   wasSeated, wasExempt, wasForced, wasAnchored   were they true at the previous sample (see sampleEntry)
--   moverPush     { speed, lift } of the speed-limited movers at the previous sample, or nil
--   seatVelocity  velocity of the seat at the previous sample (it carries a player who gets out)
--   lastReport    { [reason] = os.clock() } for REPORT_COOLDOWN
--   movers        { [Instance] = true }: server-made movers (BodyVelocity ...) in the character
--   activeMovers  how many of them pushed at the last sample (for the text of a flag)
--   lastServerMove  os.clock() of the last thing a server script did to this character (a move, a push,
--                 a mover coming or going), or nil. Only used for the text of a flag.
--   trustedMoveAt  os.clock() of the last server move / push the checks trusted, or nil
--   seen, seenPrev, seenFrame   root position at this frame's and the previous frame's step, and the frame
--                 `seen` was read in (-1: `seen` is where a move the kit already accounted for left it)
--   snapshot      { state, lastGoodCFrame, frame }: the state as it was before the last sample, to take
--                 that sample back when a server move turns out to have come before it (see rewind)
--   writes        { cframe = {...}, linear = {...}, angular = {...} }: clocks of the game's writes of the
--                 last second, to tell isolated writes from a script writing every frame
--   distrustUntil  until this clock the game's writes to this character are not trusted
--   pending       { verdicts, sample, at }: flags of the last sample, judged on the next frame
--   own           { cframe = {...}, linear = {...}, angular = {...} }: the kit's own recent writes,
--                 { value, at } each, so their signals are not mistaken for a game's (see isOwn)
--   root          the root part the signal connections below belong to
--   rootConnections, connections   signal connections: on the root / on the character
-- }
local entries = {}
local rng = Random.new()
local reportedError = false
local exemptByApi = {} -- [Player] = true: Movement.exempt(player, true), kept across respawns
local exemptByGroup = {} -- [Player] = true: the player's rank in EXEMPT_GROUP, read once at join
local warnedBurst = false -- the "a script keeps writing a character" warn is given once per server
local frame = 0 -- counts the kit's Heartbeat steps
local HOLD_DISTANCE = 2 -- studs: a server move shorter than this (a turn, a nudge) needs no catch-up hold

-- Instances that move a character from the server. A client cannot create one on the server, so
-- finding one in a character means a server script made it. Constraint movers act on Attachment0;
-- Body movers on the part they sit in, with the property that says how hard they push.
local CONSTRAINT_MOVERS = { LinearVelocity = true, VectorForce = true, AlignPosition = true, LineForce = true }
local BODY_MOVERS = {
	BodyVelocity = "MaxForce",
	BodyPosition = "MaxForce",
	BodyForce = "Force",
	BodyThrust = "Force",
	RocketPropulsion = "MaxThrust",
}
local function isMoverClass(inst: Instance): boolean
	return CONSTRAINT_MOVERS[inst.ClassName] == true or BODY_MOVERS[inst.ClassName] ~= nil
end
-- A signal about the root fires for EVERY server write, including the kit's own rubber-band. The kit
-- remembers what it wrote (value + clock) and ignores a signal whose root value still matches one of
-- those writes for this long. (Signals may be deferred: the handler can run after the write returned,
-- so a "writing right now" flag would not work. The handler reads the current value instead.)
local OWN_WRITE_WINDOW = 0.5 -- seconds
local OWN_WRITE_TOLERANCE = 0.05 -- studs for a position, studs/s for a velocity

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true
groundParams.RespectCanCollide = true
local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude
wallParams.IgnoreWater = true
wallParams.RespectCanCollide = true
local climbParams = OverlapParams.new()
climbParams.FilterType = Enum.RaycastFilterType.Exclude

-- Is `inst` part of anything with a Humanoid (a player, a dummy, an NPC)? Those are not walls.
local function belongsToCharacter(inst: Instance): boolean
	local model = inst:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") then
			return true
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return false
end

-- Can only the server move this part? Anchored parts (a client's own changes to them never reach the
-- server) and parts the server owns the physics of. A part a player's client owns is moved by that
-- client: a cheater could give it any velocity, so its velocity is never believed.
local function controlledByServer(part: BasePart): boolean
	local root = part.AssemblyRootPart or part
	if root.Anchored then
		return true
	end
	local ok, owner = pcall(root.GetNetworkOwner, root)
	return ok and owner == nil
end

-- How fast the part under the feet moves sideways (studs/s): a conveyor, a moving platform. 0 when the
-- part is not one the server controls. Not capped here: Movement.evaluate applies GROUND_SPEED_CAP.
local function groundSpeedOf(part: BasePart): number
	if not controlledByServer(part) then
		return 0
	end
	local velocity = part.AssemblyLinearVelocity
	local speed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
	if speed ~= speed then
		return 0
	end
	return speed
end

-- Is something solid just below the feet, and how fast does it move? A thin box the size of the
-- root's footprint (plus GROUND_MARGIN on every side) swept straight down. A box, not one ray: a
-- character standing on a ledge with its middle over the drop still has floor under part of the box.
-- It ignores the character's own parts but not other players (standing on a head is legal).
local GROUND_BOX = 0.2 -- studs: thickness of that box
local function isStanding(character: Model, humanoid: Humanoid, root: BasePart): (boolean, number)
	local feet = root.Size.Y / 2 + (if humanoid.RigType == Enum.HumanoidRigType.R6 then 2 else humanoid.HipHeight)
	groundParams.FilterDescendantsInstances = { character }
	groundParams.CollisionGroup = root.CollisionGroup
	local margin = 2 * LIMITS.GROUND_MARGIN
	local box = Vector3.new(root.Size.X + margin, GROUND_BOX, root.Size.Z + margin)
	local drop = Vector3.new(0, -(feet + LIMITS.GROUND_REACH - GROUND_BOX / 2), 0)
	local hit = Workspace:Blockcast(root.CFrame, box, drop, groundParams)
	if not hit then
		return false, 0
	end
	return true, groundSpeedOf(hit.Instance)
end

-- A TrussPart, or a part tagged CLIMB_TAG (or inside a model with that tag: ladders built from
-- ordinary parts), within CLIMB_REACH studs of the root. (The Humanoid's own "climbing" state is
-- NOT trusted: the client reports it, and a cheater could just claim it.)
local function isClimbing(character: Model, position: Vector3): boolean
	climbParams.FilterDescendantsInstances = { character }
	local tag = LIMITS.CLIMB_TAG
	for _, part in Workspace:GetPartBoundsInRadius(position, LIMITS.CLIMB_REACH, climbParams) do
		if part:IsA("TrussPart") or part:HasTag(tag) then
			return true
		end
		local model = part:FindFirstAncestorOfClass("Model")
		if model and model:HasTag(tag) then
			return true
		end
	end
	return false
end

-- Terrain water around the position. One small voxel read, inside pcall: if the call is
-- refused for any reason the answer is "not swimming" (the check then simply stays strict).
local function isSwimming(position: Vector3): boolean
	if not LIMITS.TERRAIN_WATER then
		return false
	end
	local ok, found = pcall(function()
		local region = Region3.new(position - Vector3.new(2, 2, 2), position + Vector3.new(2, 2, 2)):ExpandToGrid(4)
		-- A 3D array [x][y][z] that also carries a Size field: index it, don't iterate it.
		local materials = Workspace.Terrain:ReadVoxels(region, 4)
		local size = materials.Size
		for x = 1, size.X do
			for y = 1, size.Y do
				for z = 1, size.Z do
					if materials[x][y][z] == Enum.Material.Water then
						return true
					end
				end
			end
		end
		return false
	end)
	return ok and found == true
end

-- Distance along the ray to the first solid part that is not a character, or nil.
local function solidHit(origin: Vector3, direction: Vector3): number?
	local result = Workspace:Raycast(origin, direction, wallParams)
	if result and not belongsToCharacter(result.Instance) then
		return (result.Position - origin).Magnitude
	end
	return nil
end

-- Everything the pure half needs, read off the character. At most three raycasts (one down, two
-- for noclip) plus one bounds query and one voxel read, and only while something is unusual (in the
-- air, or moved). Samples that will be ignored anyway cost nothing. `held` = this sample will not be
-- judged (seated, exempt, or a server mover on the character).
local function buildSample(
	player: Player,
	state,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	now: number,
	held: boolean
)
	local position = root.Position
	local gravity = Workspace.Gravity
	local sample = {
		time = now,
		position = position,
		seated = held,
		walkSpeed = humanoid.WalkSpeed,
		jumpHeight = if humanoid.UseJumpPower then humanoid.JumpPower ^ 2 / (2 * gravity) else humanoid.JumpHeight,
		gravity = gravity,
		ping = math.min(player:GetNetworkPing(), LIMITS.MAX_PING),
		angularSpeed = root.AssemblyAngularVelocity.Magnitude,
		linearSpeed = root.AssemblyLinearVelocity.Magnitude,
		grounded = false,
		groundSpeed = 0,
		climbing = false,
		swimming = false,
	}
	if Movement.suppressed(state, now, held) then
		return sample
	end

	sample.grounded, sample.groundSpeed = isStanding(character, humanoid, root)
	if not sample.grounded then
		sample.climbing = isClimbing(character, position)
		if not sample.climbing then
			sample.swimming = isSwimming(position)
		end
	end

	-- Noclip rays run between the last CLEAN position and here (not the previous sample), so a
	-- character that is inside a wall is still measured from where it was outside.
	local line = position - state.lastGood
	if line.Magnitude >= LIMITS.NOCLIP_MIN_STEP then
		wallParams.FilterDescendantsInstances = { character }
		wallParams.CollisionGroup = root.CollisionGroup
		sample.wallA = solidHit(state.lastGood, line)
		sample.wallB = solidHit(position, -line)
		if sample.wallA and sample.wallB then
			-- The middle line crosses something: cast the same line shifted to each side (corner check).
			local side = Vector3.new(-line.Z, 0, line.X)
			side = (if side.Magnitude > 1e-3 then side.Unit else Vector3.xAxis) * LIMITS.NOCLIP_SIDE_OFFSET
			sample.sides = {}
			for _, shift in { side, -side } do
				table.insert(
					sample.sides,
					{ a = solidHit(state.lastGood + shift, line), b = solidHit(position + shift, -line) }
				)
			end
		end
	end
	return sample
end

-- Nothing is judged for a while: the baseline follows the player. (Movement.grace and the server-move
-- signals both end up here.)
local function extendGrace(entry, untilClock: number)
	entry.graceUntil = math.max(entry.graceUntil, untilClock)
	if entry.state then
		entry.state.graceUntil = math.max(entry.state.graceUntil, untilClock)
	end
end

-- A server write reached the kit. If the kit sampled this character earlier in the same frame, that
-- sample may have seen the write's result without knowing about it (a deferred signal arrives after the
-- sample): take the sample back. Whatever happened since the previous sample is then judged by the next
-- one, with the write accounted for. (Its flags, still waiting in entry.pending, go too.)
local function rewind(entry)
	local snapshot = entry.snapshot
	entry.snapshot = nil
	if not (snapshot and snapshot.frame == frame) then
		return
	end
	local state = snapshot.state
	if state and entry.state then
		-- (a Movement.grace given since the sample stays)
		state.graceUntil = math.max(state.graceUntil, entry.state.graceUntil)
	end
	entry.state = state
	entry.lastGoodCFrame = snapshot.lastGoodCFrame
	entry.pending = nil
end

-- A move the SERVER made (and meant) from `from` to `to`: the checks' memory is carried along by the
-- difference (Movement.shift), plus a catch-up hold when it is more than a nudge. Used by
-- Movement.allowTeleport and by the signal that notices any other server script moving the root.
local function moveBy(entry, from: Vector3, to: Vector3, now: number)
	local offset = to - from
	entry.lastServerMove = now
	entry.trustedMoveAt = now
	entry.seen, entry.seenFrame = to, -1
	if entry.state then
		local hold = if offset.Magnitude > HOLD_DISTANCE then LIMITS.RUBBERBAND_HOLD else 0
		Movement.shift(entry.state, offset, now, hold)
	end
	if entry.lastGoodCFrame then
		entry.lastGoodCFrame += offset
	end
end

-- A push the SERVER gave (see Movement.push). Before the first sample there is nothing to widen: the
-- spawn grace covers that stretch.
local function pushEntry(entry, push, now: number)
	if entry.state then
		Movement.push(entry.state, push, now, LIMITS, Workspace.Gravity)
	end
end

local function horizontalSpeed(v: Vector3): number
	return math.sqrt(v.X * v.X + v.Z * v.Z)
end

-- Is this write by a game script one to trust? Only an ISOLATED one: each trusted write lets whatever
-- the client did in the frame just before it pass unjudged (see the CFrame handler), and a script that
-- writes the root over and over (a face-the-target loop, a server lock-on) would add that up into a
-- free run. So more than SERVER_WRITE_LIMIT writes of one kind within a second stop the trust for
-- SERVER_WRITE_DISTRUST seconds. A write to an anchored root or a seated character is the game's anyway
-- (a cutscene, a ride): trusted and not counted.
local function trustWrite(entry, kind: string, now: number): boolean
	local humanoid = entry.character:FindFirstChildOfClass("Humanoid")
	if (entry.root and entry.root.Anchored) or (humanoid and humanoid.SeatPart ~= nil) then
		return true
	end
	local list = entry.writes[kind]
	table.insert(list, now)
	while list[1] and now - list[1] > 1 do
		table.remove(list, 1)
	end
	if #list > LIMITS.SERVER_WRITE_LIMIT then
		if now >= entry.distrustUntil then
			if not warnedBurst then
				warnedBurst = true
				warn(
					string.format(
						"[WeaponKit] Movement: a server script writes the %s of %s's character more than %d times a second, so those writes are not trusted (anyone could be moved anywhere). Move players with Movement.allowTeleport, or wrap the effect in Movement.grace.",
						if kind == "cframe" then "CFrame" else kind .. " velocity",
						entry.character.Name,
						LIMITS.SERVER_WRITE_LIMIT
					)
				)
			end
		end
		entry.distrustUntil = now + LIMITS.SERVER_WRITE_DISTRUST
	end
	return now >= entry.distrustUntil
end

-- Remember a write the kit itself is about to make (or just made): `kind` is "cframe" (a position),
-- "linear" or "angular" (velocities).
local function noteOwn(entry, kind: string, value: Vector3, now: number)
	local list = entry.own[kind]
	while list[1] and now - list[1].at > OWN_WRITE_WINDOW do
		table.remove(list, 1)
	end
	table.insert(list, { value = value, at = now })
end

-- Does the root's CURRENT value still match one of the kit's own recent writes? Then the signal that
-- brought us here was the kit's own, not a game script's. A game's write has another value, so a
-- cheater being rubber-banded never gets the grace a server move earns.
local function isOwn(entry, kind: string, current: Vector3, now: number): boolean
	for _, write in entry.own[kind] do
		if now - write.at <= OWN_WRITE_WINDOW and (current - write.value).Magnitude <= OWN_WRITE_TOLERANCE then
			return true
		end
	end
	return false
end

local function disconnectAll(connections)
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

-- Server scripts writing the root part's CFrame or velocities. A client's own changes (teleports,
-- spin, jumps, walking, client-made movers) and physics never fire these signals on the server; only
-- a server write does. Skipped entirely when TRUST_SERVER_MOVES is off.
local function hookRoot(entry, root: BasePart)
	disconnectAll(entry.rootConnections)
	entry.root = root
	if not LIMITS.TRUST_SERVER_MOVES then
		return
	end
	-- knockback, launch pad, admin fling: an allowance of the speed written (see Movement.push)
	local function velocityHandler(kind: string, read: () -> Vector3, toPush: (Vector3) -> any)
		return function()
			local now = os.clock()
			local value = read()
			if isOwn(entry, kind, value, now) then
				return
			end
			entry.lastServerMove = now
			if trustWrite(entry, kind, now) then
				rewind(entry)
				entry.trustedMoveAt = now
				pushEntry(entry, toPush(value), now)
			end
		end
	end
	table.insert(
		entry.rootConnections,
		root:GetPropertyChangedSignal("CFrame"):Connect(function()
			local now = os.clock()
			local to = root.Position
			if isOwn(entry, "cframe", to, now) then
				return
			end
			entry.lastServerMove = now
			if not trustWrite(entry, "cframe", now) then
				return
			end
			-- Where was the character before the write? If the kit read it earlier in this frame, that read
			-- may already hold the result (a deferred signal comes after the write, and the client may have
			-- moved on since, so the values cannot tell): take the frame before. Else the last read. The
			-- client's last frame or two of movement before the write go unjudged.
			local from = if entry.seenFrame == frame then entry.seenPrev else entry.seen
			from = from or to
			rewind(entry)
			moveBy(entry, from, to, now)
		end)
	)
	table.insert(
		entry.rootConnections,
		root:GetPropertyChangedSignal("AssemblyLinearVelocity"):Connect(velocityHandler("linear", function()
			return root.AssemblyLinearVelocity
		end, function(v)
			return { speed = horizontalSpeed(v), lift = math.max(v.Y, 0), linear = v.Magnitude }
		end))
	)
	table.insert(
		entry.rootConnections,
		root:GetPropertyChangedSignal("AssemblyAngularVelocity"):Connect(velocityHandler("angular", function()
			return root.AssemblyAngularVelocity
		end, function(v)
			return { angular = v.Magnitude }
		end))
	)
end

-- Does this server-made mover push the character right now? A constraint mover needs Enabled and an
-- Attachment0 inside the character, and something to push with: a VectorForce a non-zero Force, a
-- LineForce a non-zero Magnitude and an Attachment1, a LinearVelocity / AlignPosition a force limit
-- above 0 (only the plain Magnitude limit is read; a rigid AlignPosition or another limit mode counts
-- as pushing). A Body mover must sit in one of the character's parts with a non-zero MaxForce / Force /
-- MaxThrust. A disabled or zero mover left in a character must not switch the checks off for good.
-- Anything unreadable counts as "not pushing": the player is then simply judged.
local function isActiveMover(inst: Instance, character: Model): boolean
	local ok, active = pcall(function()
		local class = inst.ClassName
		if CONSTRAINT_MOVERS[class] then
			local attachment = inst.Attachment0
			if not (inst.Enabled and attachment and attachment:IsDescendantOf(character)) then
				return false
			end
			if class == "VectorForce" then
				return inst.Force.Magnitude > 0
			elseif class == "LineForce" then
				return inst.Magnitude ~= 0 and inst.Attachment1 ~= nil
			elseif class == "AlignPosition" and inst.RigidityEnabled then
				return true
			end
			local limited = class == "AlignPosition" or inst.ForceLimitsEnabled
			return not (limited and inst.ForceLimitMode == Enum.ForceLimitMode.Magnitude and inst.MaxForce <= 0)
		end
		local parent = inst.Parent
		if not (parent and parent:IsA("BasePart")) then
			return false
		end
		local push = inst[BODY_MOVERS[inst.ClassName]]
		return if type(push) == "number" then push > 0 else push.Magnitude > 0
	end)
	return ok and active == true
end

-- The speed an active mover drives the character at: (sideways, upwards) in studs/s, or nil when it
-- pushes with a force (VectorForce, BodyForce, BodyThrust, LineForce, BodyPosition, a rigid or speed-unlimited
-- AlignPosition) and has no speed to read. A direction the kit cannot place in the world (a LinearVelocity
-- relative to an attachment, a line or a plane) counts its whole speed both ways.
local function moverSpeed(inst: Instance): (number?, number?)
	local ok, speed, lift = pcall(function()
		local class = inst.ClassName
		if class == "BodyVelocity" then
			local v = inst.Velocity
			return horizontalSpeed(v), math.max(v.Y, 0)
		elseif class == "LinearVelocity" then
			local mode = inst.VelocityConstraintMode
			local s
			if mode == Enum.VelocityConstraintMode.Line then
				s = math.abs(inst.LineVelocity)
			elseif mode == Enum.VelocityConstraintMode.Plane then
				s = inst.PlaneVelocity.Magnitude
			else
				local v = inst.VectorVelocity
				if inst.RelativeTo == Enum.ActuatorRelativeTo.World then
					return horizontalSpeed(v), math.max(v.Y, 0)
				end
				s = v.Magnitude
			end
			return s, s
		elseif class == "AlignPosition" and not inst.RigidityEnabled and inst.MaxVelocity < math.huge then
			return inst.MaxVelocity, inst.MaxVelocity
		elseif class == "RocketPropulsion" then
			return inst.MaxSpeed, inst.MaxSpeed
		end
		return nil, nil
	end)
	if not (ok and type(speed) == "number" and type(lift) == "number" and speed == speed and lift == lift) then
		return nil, nil -- unreadable: treated like a force mover (not judged while it pushes)
	end
	return math.max(speed, 0), math.max(lift, 0)
end

-- Server-made movers in the character (BodyVelocity, LinearVelocity ...). While one with a readable speed
-- is ACTIVE the checks allow that speed (sampleEntry: a sustained Movement.push), and when it stops the
-- push carries on like a throw. A force mover (no speed to read) switches the checks off while it pushes,
-- and RELEASE_GRACE follows it. One removed while still pushing counts the same (a knockback that came and
-- went between two samples still leaves its displacement behind). Skipped when TRUST_SERVER_MOVES is off.
local function hookMovers(entry, character: Model)
	if not LIMITS.TRUST_SERVER_MOVES then
		return
	end
	for _, inst in character:GetDescendants() do
		if isMoverClass(inst) then
			entry.movers[inst] = true
		end
	end
	table.insert(
		entry.connections,
		character.DescendantAdded:Connect(function(inst)
			if isMoverClass(inst) then
				entry.movers[inst] = true
				entry.lastServerMove = os.clock()
			end
		end)
	)
	-- (DescendantRemoving fires before the instance goes: it can still be read here.)
	table.insert(
		entry.connections,
		character.DescendantRemoving:Connect(function(inst)
			if entry.movers[inst] then
				entry.movers[inst] = nil
				local now = os.clock()
				entry.lastServerMove = now
				if isActiveMover(inst, character) then
					local speed, lift = moverSpeed(inst)
					if speed then
						pushEntry(entry, { speed = speed, lift = lift, linear = speed + lift }, now)
					else
						extendGrace(entry, now + LIMITS.RELEASE_GRACE)
					end
				end
			end
		end)
	)
end

local function dropEntry(player: Player)
	local entry = entries[player]
	entries[player] = nil
	if entry then
		disconnectAll(entry.rootConnections)
		disconnectAll(entry.connections)
	end
end

-- Exempt players are never judged: the API flag, a Player attribute, the UserId list, or the group
-- rank read at join. The attribute is read here every sample; a client cannot set it (an attribute
-- written by a client never replicates to the server).
local function isExempt(player: Player): boolean
	if exemptByApi[player] or exemptByGroup[player] or player:GetAttribute("WeaponKitExempt") == true then
		return true
	end
	local ids = LIMITS.EXEMPT_USER_IDS
	return ids ~= nil and table.find(ids, player.UserId) ~= nil
end

-- EXEMPT_GROUP: the rank is asked once when the player joins (in its own thread: GetRankInGroup
-- yields and can fail), and cached. A failed lookup is retried twice, then the player is simply judged.
local function lookUpGroupRank(player: Player)
	local group = LIMITS.EXEMPT_GROUP
	if not group or not group.id or group.id <= 0 then
		return
	end
	task.spawn(function()
		for attempt = 1, 3 do
			local ok, rank = pcall(player.GetRankInGroup, player, group.id)
			if player.Parent ~= Players then
				return
			end
			if ok then
				if type(rank) == "number" and rank >= (group.minRank or 255) then
					exemptByGroup[player] = true
				end
				return
			end
			if attempt < 3 then
				task.wait(2)
			end
		end
		warn("[WeaponKit] Movement: could not read the group rank of " .. player.Name .. ", so it is not exempt")
	end)
end

-- What was going on around a flag, for the log: "flagged 0.1 s after a server move" is a game script
-- that should have been announced, not a cheater.
local function context(entry, sample, now: number): string
	local since = if entry.lastServerMove then string.format("%.1f s ago", now - entry.lastServerMove) else "none yet"
	return string.format(
		"server move %s, movers %d, ground %.0f studs/s, WalkSpeed %.0f, JumpHeight %.1f",
		since,
		entry.activeMovers,
		sample.groundSpeed,
		sample.walkSpeed,
		sample.jumpHeight
	)
end

-- What happens to a flagged player: every verdict is counted (at most once per REPORT_COOLDOWN
-- per reason), and in "snap" mode the character is put back at the last clean position, its
-- velocities zeroed, and the next samples ignored while the client catches up.
-- Runs one frame AFTER the sample (see step): a game script that moved the character in the sampled
-- frame may have its signal deferred until after the sample, and that move must win, not be undone.
local function respond(player: Player, entry, verdicts, sample, sampledAt: number, now: number)
	if entry.trustedMoveAt and entry.trustedMoveAt >= sampledAt then
		return -- a server move the sample had not heard of yet explains it (and has reset the state)
	end
	-- The same for a grace or an exemption the game gave in between (Movement.grace from the RemoteEvent
	-- that starts a dash, an admin system exempting someone): a flagged sample never had a grace running.
	if (entry.state and now < entry.state.graceUntil) or isExempt(player) then
		return
	end
	local character = entry.character
	local root = character:FindFirstChild("HumanoidRootPart")
	if player.Character ~= character or not root then
		return
	end
	for _, verdict in verdicts do
		if now - (entry.lastReport[verdict.reason] or -math.huge) >= LIMITS.REPORT_COOLDOWN then
			entry.lastReport[verdict.reason] = now
			Suspicion.report(
				player,
				verdict.reason,
				string.format(
					"%.1f over the limit of %.1f (%s)",
					verdict.value,
					verdict.limit,
					context(entry, sample, now)
				)
			)
		end
	end
	if LIMITS.MOVEMENT_ACTION == "snap" then
		local target = entry.lastGoodCFrame
		-- Written down BEFORE the writes (a signal can arrive inside them) and again after (the value
		-- the root really ended up with): these are the kit's own, not a game's.
		noteOwn(entry, "cframe", target.Position, now)
		noteOwn(entry, "linear", Vector3.zero, now)
		noteOwn(entry, "angular", Vector3.zero, now)
		character:PivotTo(target)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		noteOwn(entry, "cframe", root.Position, now)
		entry.seen, entry.seenFrame = root.Position, -1 -- (a game move later this frame starts from here)
		-- (The hold counts from the sample, not from this frame: a later end would skip a whole sample.)
		Movement.reset(entry.state, target.Position, now, LIMITS.RUBBERBAND_HOLD - (now - sampledAt))
	end
end

local function sampleEntry(player: Player, entry, now: number)
	local character = entry.character
	if player.Character ~= character or not character.Parent then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then
		return -- not spawned in yet, or dead
	end
	if entry.root ~= root then
		hookRoot(entry, root) -- the root part arrived after the character did
	end

	local state = entry.state
	if not state then
		-- The first sight of the character is only the starting point.
		state = Movement.newState(root.Position, now)
		state.graceUntil = math.max(entry.spawnGraceUntil, entry.graceUntil)
		entry.snapshot = { state = nil, lastGoodCFrame = entry.lastGoodCFrame, frame = frame }
		entry.state = state
		entry.lastGoodCFrame = root.CFrame
		return
	end

	local gravity = Workspace.Gravity
	local seated = humanoid.SeatPart ~= nil
	local anchored = root.Anchored
	local exempt = isExempt(player)
	-- Server movers: a speed-limited one is an allowance of that speed, a force one switches the checks off.
	local active, forced, speed, lift = 0, false, 0, 0
	for inst in entry.movers do
		if isActiveMover(inst, character) then
			active += 1
			local s, l = moverSpeed(inst)
			if s and l then
				speed += s
				lift += l
			else
				forced = true
			end
		end
	end
	entry.activeMovers = active
	local driven = active > 0 and not forced
	if driven then
		local push = { speed = speed, lift = lift, linear = speed + lift, sustained = true }
		Movement.push(state, push, now, LIMITS, gravity)
	elseif entry.moverPush then -- the movers stopped: their push carries on like a throw
		Movement.push(state, entry.moverPush, now, LIMITS, gravity)
	end
	entry.moverPush = if driven then { speed = speed, lift = lift, linear = speed + lift } else nil

	-- Getting out of a seat: the seat's speed carries the player for a moment (capped like a moving floor).
	if entry.wasSeated and not seated and entry.seatVelocity then
		local v, cap = entry.seatVelocity, LIMITS.GROUND_SPEED_CAP
		Movement.push(state, {
			speed = math.min(horizontalSpeed(v), cap),
			lift = math.clamp(v.Y, 0, cap),
			linear = math.min(v.Magnitude, cap),
		}, now, LIMITS, gravity)
	end
	entry.seatVelocity = if seated then humanoid.SeatPart.AssemblyLinearVelocity else nil
	-- A frozen root is the game's: once it is let go, the client needs a moment to catch up (judged after).
	if entry.wasAnchored and not anchored then
		Movement.hold(state, now, LIMITS.RUBBERBAND_HOLD)
	end
	-- An exemption the game took back, or the last force mover gone: nothing to measure them by, so a grace.
	if (entry.wasExempt and not exempt) or (entry.wasForced and not forced) then
		state.graceUntil = math.max(state.graceUntil, now + LIMITS.RELEASE_GRACE)
	end
	entry.wasSeated = seated
	entry.wasAnchored = anchored
	entry.wasExempt = exempt
	entry.wasForced = forced

	-- The state before the judgement, kept in case a server write of this same frame turns up later
	-- (see rewind).
	local before = table.clone(state)
	before.window = table.clone(state.window)
	entry.snapshot = { state = before, lastGoodCFrame = entry.lastGoodCFrame, frame = frame }

	-- Not judged at all (the baseline follows): seated, frozen, exempt, or pushed by a force mover.
	local held = seated or anchored or exempt or forced
	local sample = buildSample(player, state, character, humanoid, root, now, held)
	local verdicts = Movement.evaluate(state, sample, LIMITS)
	if state.lastGood == sample.position then
		entry.lastGoodCFrame = root.CFrame
	end
	if #verdicts > 0 then
		entry.pending = { verdicts = verdicts, sample = sample, at = now }
	end
end

-- One broken character must never stop the loop for everybody else.
local function guarded(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and not reportedError then
		reportedError = true
		warn("[WeaponKit] Movement: " .. tostring(err))
	end
end

local function step()
	local now = os.clock()
	frame += 1
	for player, entry in entries do
		-- where each character is this frame, for a server move that turns up later (see the CFrame handler)
		local root = entry.root
		if root then
			entry.seenPrev, entry.seen, entry.seenFrame = entry.seen, root.Position, frame
		end
		-- Last frame's flags first: every deferred signal of that frame has run by now.
		local pending = entry.pending
		if pending and now > pending.at then
			entry.pending = nil
			guarded(respond, player, entry, pending.verdicts, pending.sample, pending.at, now)
		end
		if now >= entry.nextAt then
			entry.nextAt = now + LIMITS.SAMPLE_INTERVAL
			guarded(sampleEntry, player, entry, now)
		end
	end
end

local function startEntry(player: Player, character: Model)
	dropEntry(player)
	local now = os.clock()
	local entry = {
		character = character,
		state = nil,
		nextAt = now + rng:NextNumber() * LIMITS.SAMPLE_INTERVAL, -- staggered: not everybody in the same frame
		spawnGraceUntil = now + LIMITS.SPAWN_GRACE,
		graceUntil = 0,
		lastGoodCFrame = nil,
		wasSeated = false,
		wasAnchored = false,
		wasExempt = false,
		wasForced = false,
		moverPush = nil,
		seatVelocity = nil,
		lastReport = {},
		movers = {},
		activeMovers = 0,
		lastServerMove = nil,
		trustedMoveAt = nil,
		seen = nil,
		seenPrev = nil,
		seenFrame = 0,
		snapshot = nil,
		writes = { cframe = {}, linear = {}, angular = {} },
		distrustUntil = 0,
		pending = nil,
		own = { cframe = {}, linear = {}, angular = {} },
		root = nil,
		rootConnections = {},
		connections = {},
	}
	entries[player] = entry
	hookMovers(entry, character)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		hookRoot(entry, root)
	end
end

----------------------------------------------------------------------------------- public API

-- Nothing is flagged for `seconds`, and the baseline follows the player meanwhile. For anything the
-- game does to a player's movement that the checks cannot see for themselves: a dash or custom flight
-- the CLIENT does, a long ride you want to cover in one go. (Server moves, server velocity writes and
-- server-made movers need no call: see Config.ANTI_CHEAT.TRUST_SERVER_MOVES.) A grace is time off: a
-- cheater can do anything inside it, so keep it short when a player can set it off themselves.
function Movement.grace(player: Player, seconds: number)
	local entry = entries[player]
	if not entry then
		return
	end
	extendGrace(entry, os.clock() + seconds)
end

-- A teleport the SERVER wants: moves the character and tells the checks it was meant. Optional since
-- any server-side move is noticed (TRUST_SERVER_MOVES), but it works with that switched off too, is
-- never distrusted, and knows exactly where the character was before. Like any server move it is not
-- time off: the checks are carried along by the distance moved (Movement.shift). Returns false if the
-- player has no character.
function Movement.allowTeleport(player: Player, cframe: CFrame): boolean
	local character = player.Character
	if not character then
		return false
	end
	local now = os.clock()
	local entry = entries[player]
	local root = character:FindFirstChild("HumanoidRootPart")
	local from = if root then root.Position else cframe.Position
	if entry then
		noteOwn(entry, "cframe", cframe.Position, now) -- (before the write: its signal may come inside it)
	end
	character:PivotTo(cframe)
	if entry then
		local to = if root then root.Position else cframe.Position
		noteOwn(entry, "cframe", to, now)
		moveBy(entry, from, to, now)
		if entry.state then -- (face the way the teleport says)
			entry.lastGoodCFrame = cframe + (entry.state.lastGood - cframe.Position)
		end
	end
	return true
end

-- Exempt (true) or judge again (false) a player: an admin, a moderator, a developer. The movement
-- checks then never flag them and the baseline just follows them. Lasts until the player leaves
-- (respawning does not clear it). Config.ANTI_CHEAT.EXEMPT_USER_IDS / EXEMPT_GROUP and the Player
-- attribute "WeaponKitExempt" do the same without a call.
function Movement.exempt(player: Player, on: boolean)
	exemptByApi[player] = if on then true else nil
end

function Movement.init()
	local function onPlayer(player: Player)
		lookUpGroupRank(player)
		player.CharacterAdded:Connect(function(character)
			startEntry(player, character)
		end)
		player.CharacterRemoving:Connect(function(character)
			local entry = entries[player]
			if entry and entry.character == character then
				dropEntry(player) -- (not a newer character's entry)
			end
		end)
		if player.Character then
			startEntry(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		dropEntry(player)
		exemptByApi[player] = nil
		exemptByGroup[player] = nil
	end)

	RunService.Heartbeat:Connect(step)
	if LIMITS.MOVEMENT_ACTION == "log" then
		print(
			'[WeaponKit] Movement: log mode - nobody is moved back. Watch the Suspicion counts, then set ANTI_CHEAT.MOVEMENT_ACTION = "snap"'
		)
	end
	print("[WeaponKit] Movement ready (" .. LIMITS.MOVEMENT_ACTION .. ")")
end

return Movement
