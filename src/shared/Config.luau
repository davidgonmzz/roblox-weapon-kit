--!strict
-- Switches and tuning numbers shared by the server and the client. Nothing in here is a secret:
-- every value is either harmless to show a player or re-checked by the server anyway.

local Config = {
	-- false: bullets pass through other players and only dummies take damage.
	-- true:  players can shoot each other (the shooter's own character is always ignored).
	PVP = false,

	-- Only matters with PVP on. false: a player on the SAME Team as the shooter takes no damage
	-- (bullets still stop at them). Players without a team (Player.Neutral) can always be hit.
	-- true: team mates hurt each other.
	FRIENDLY_FIRE = false,

	-- Demo only. Shows the exploit simulator (client/CheatPanel.luau, F2) and makes the server
	-- tell the shooter WHY it refused a request. Set to false (or delete CheatPanel.luau) for
	-- production: a real game should never explain its anti-cheat to the player.
	DEMO_CHEAT_PANEL = true,

	-- DataStore name used by ProfileStore. Bump the suffix to start everybody on fresh data.
	DATASTORE_NAME = "WeaponKit_v1",

	-- CollectionService tag that marks a Model as shootable. WeaponServer only damages tagged
	-- models (plus other players when PVP is on); Dummies tags the dummies it builds.
	TARGET_TAG = "WeaponKitTarget",

	DUMMY_HEALTH = 100,
	DUMMY_RESPAWN_SECONDS = 3,

	-- Ammo crate: seconds between two restocks for one player.
	CRATE_COOLDOWN = 2,

	-- Server-side exploit checks: movement (server/Movement.luau) and aim flags (server/AimStats.luau).
	-- Distances are studs, speeds studs per second, times seconds. Every value is judged by the
	-- server alone; the client never sees or influences it. The defaults trade a few missed small
	-- cheats for (nearly) no false alarms on a laggy but honest player: tighten them only after
	-- watching your own game's numbers.
	ANTI_CHEAT = {
		-- "snap": a flagged player is put back at their last clean position (rubber-band) and the
		--         flag is counted. "log": only counted, the player is left alone.
		-- "auto" (the default) means "snap" while DEMO_CHEAT_PANEL is on (the exploit lab shows the
		-- rubber-band) and "log" otherwise: a live game should read the Suspicion counts first, then
		-- switch to "snap" once its own scripts (sprint, dash, double jump, admin fly) stop showing up.
		-- Any explicit "snap" / "log" here wins over the default (resolved below the table).
		MOVEMENT_ACTION = "auto",
		SAMPLE_INTERVAL = 0.2, -- how often each player's character is looked at (staggered per player)
		MAX_PING = 1, -- the ping used for lag allowance is capped here (a huge ping must not widen every limit)
		REPORT_COOLDOWN = 0.5, -- the same flag is counted at most this often per player (a "log" mode cheater is not counted 5x a second)

		-- Grace: while one runs nothing is flagged and the baseline simply follows the player. Only for things
		-- the kit has nothing to measure by; everything the server does is an allowance instead (below).
		SPAWN_GRACE = 2, -- after a character spawns
		RELEASE_GRACE = 1, -- after an exemption ends, or the last FORCE mover (VectorForce, BodyForce ...) goes
		-- Hold: samples are ignored while the client catches up (it has not received the move yet), then
		-- everything it did meanwhile is judged in one go; the baseline stays put. After the kit's own snap,
		-- a server move of more than a nudge, and an anchored root being let go.
		RUBBERBAND_HOLD = 0.6,

		-- Things the SERVER does to a character are never the player's doing, and the server can SEE them
		-- (a client's own CFrame / velocity changes never raise the signals used here, and an Instance a
		-- client creates never exists on the server). TRUST_SERVER_MOVES = true makes the checks allow for
		-- them, by what the server did and no more (none of it is time off, so a player who can set one off
		-- himself gains nothing from it):
		--  * any server script moving the character (PivotTo, Model:MoveTo, root.CFrame = ..., admin :tp /
		--    :bring) counts like Movement.allowTeleport: the checks are carried along by the distance moved;
		--  * a server write to the root's velocity (knockback, launch pad, admin fling) adds that speed to
		--    the limits (sideways, upwards as a throw, fling) for SERVER_PUSH_TIME seconds, and after that
		--    until the player stands again;
		--  * a server-made BodyVelocity / LinearVelocity / RocketPropulsion, or an AlignPosition with a
		--    MaxVelocity, adds its speed while it pushes and is let go like a throw. Movers that push with a
		--    FORCE (BodyPosition / BodyForce / BodyThrust / VectorForce / LineForce, a rigid AlignPosition)
		--    have no speed to read: the character is not judged while one pushes, and RELEASE_GRACE follows.
		-- The kit's own rubber-band writes are recognised and never count as such a move. false: only
		-- Movement.allowTeleport / Movement.grace tell the checks about server moves.
		TRUST_SERVER_MOVES = true,
		SERVER_PUSH_TIME = 1,
		-- Only ISOLATED server writes are trusted. Each one lets the client's last frame before it go
		-- unjudged, so a script that writes the root's CFrame or velocity over and over (a "face the target"
		-- loop, a server lock-on) would add up to a free run for a cheater. More than SERVER_WRITE_LIMIT writes
		-- of one kind within a second stop the trust for that player for SERVER_WRITE_DISTRUST seconds, with
		-- one warn in the log. Writes to an anchored root or a seated character are not counted.
		-- Movement.allowTeleport and Movement.grace always work.
		SERVER_WRITE_LIMIT = 2,
		SERVER_WRITE_DISTRUST = 5,

		-- Standing on a moving part (conveyor, moving platform) adds that part's horizontal speed to the
		-- speed allowance, capped here (studs/s). Only ANCHORED or server-owned parts count: a part the
		-- player's own client controls could be moved by a cheater, so its speed is never believed.
		GROUND_SPEED_CAP = 150,

		-- Admins and your own staff: never judged by the movement checks (the baseline just follows them,
		-- nothing is counted). Any of these makes a player exempt:
		--  * EXEMPT_USER_IDS: a list of UserIds, e.g. { 1, 156 };
		--  * EXEMPT_GROUP: members of group `id` with rank >= `minRank` (id 0 = off), looked up once when
		--    the player joins (rank changes mid-session are not noticed);
		--  * Movement.exempt(player, true) from your own server code (an admin system's rank check);
		--  * the Player attribute "WeaponKitExempt" = true, set from a SERVER script (an attribute set by
		--    a client never replicates to the server, so a cheater cannot give it to himself).
		-- Exempting people is a trade: a client-side admin :fly / :noclip is invisible to the server
		-- anyway, so exempt the admins or make those commands server-side.
		EXEMPT_USER_IDS = {} :: { number },
		EXEMPT_GROUP = { id = 0, minRank = 255 },

		-- speed: horizontal distance over the last SPEED_WINDOW seconds must stay below
		-- WalkSpeed * SPEED_TOLERANCE * time + SPEED_SLACK + WalkSpeed * ping.
		SPEED_WINDOW = 1,
		SPEED_TOLERANCE = 1.3, -- 30% over WalkSpeed is allowed (slopes, jitter, a WalkSpeed change in flight)
		SPEED_SLACK = 5, -- studs of extra allowance (position updates arrive in bursts)

		-- teleport: ONE sample further than this (on top of what the speed allows) is not walking.
		TELEPORT_DISTANCE = 30,

		-- jump: rise above the last standing height may not pass JumpHeight * JUMP_TOLERANCE + JUMP_SLACK.
		-- (Catches super jump, and infinite jump as soon as the stack rises past one jump.)
		JUMP_TOLERANCE = 1.25,
		JUMP_SLACK = 1.5,

		-- fly: in the air, the character may be at most as high as the best possible jump/fall
		-- curve (JumpHeight above) says, plus FLY_SLACK. After a few tenths of a second a hover or a
		-- slow glide is above that curve. FLY_DROP_CAP stops the curve being followed below this many
		-- studs under the takeoff height (air drag makes real falls a little slower than the maths).
		FLY_SLACK = 3,
		FLY_DROP_CAP = 40,

		-- "Standing" = a collidable surface within GROUND_REACH studs below the feet, anywhere under
		-- the root's footprint grown by GROUND_MARGIN on each side (a server box cast, so standing on
		-- a ledge with the middle over the drop counts). Climbing = a TrussPart, or a part / model
		-- tagged CLIMB_TAG (ladders built from ordinary parts: tag them), within CLIMB_REACH studs.
		-- Swimming = Terrain water around the root (TERRAIN_WATER false skips that read: set it if
		-- your map has no Terrain water).
		GROUND_REACH = 2,
		GROUND_MARGIN = 0.5,
		CLIMB_REACH = 3,
		CLIMB_TAG = "WeaponKitClimbable",
		TERRAIN_WATER = true,

		-- noclip: two raycasts between the last clean position and now; both must hit a solid part.
		-- A move shorter than NOCLIP_MIN_STEP is not cast at all. The stretch inside solid parts must be
		-- at least NOCLIP_MIN_DEPTH (corner cutting between two samples can clip a corner). A player
		-- who is INSIDE a solid for NOCLIP_STUCK_TIME is flagged too (walls thicker than one step).
		-- Corner check: the same line shifted NOCLIP_SIDE_OFFSET studs to each side must cross as
		-- deeply too, so a player rounding a corner fast is not flagged (walls narrower than about
		-- 2 x this are not checked).
		NOCLIP_MIN_STEP = 0.5,
		NOCLIP_MIN_DEPTH = 0.5,
		NOCLIP_SIDE_OFFSET = 1,
		NOCLIP_STUCK_TIME = 1.5,

		-- fling: angular speed (rad/s) or total speed (studs/s) of the root no real character reaches.
		FLING_ANGULAR = 100,
		FLING_LINEAR = 800,

		-- fire rate (server/WeaponServer.luau): a shot may arrive up to max(20% of the interval,
		-- FIRE_JITTER) seconds before its slot, because network jitter bunches honest shots up. The credit
		-- never builds up, so nobody averages more than a weapon's rpm (a faster weapon fits more shots
		-- into it: at 900 rpm a burst can start with 2 extra rounds). A shot past it is refused and the
		-- client's ammo re-synced. A lag spike delivers several shots at once, so refusals with no accepted
		-- shot between them count as one, and "fast" is reported only when FAST_FLAG_COUNT of those come
		-- within FAST_FLAG_WINDOW seconds (a one-off burst is refused, not reported: it looks like lag).
		FIRE_JITTER = 0.1,
		FAST_FLAG_COUNT = 3,
		FAST_FLAG_WINDOW = 2,

		-- aim: of the last AIM_WINDOW hits, more than AIM_HEADSHOT_RATIO headshots, judged once
		-- AIM_MIN_HITS hits exist. Single-pellet weapons only. Flag only, a shot is never blocked.
		AIM_WINDOW = 20,
		AIM_MIN_HITS = 10,
		AIM_HEADSHOT_RATIO = 0.8,
		-- snap: an aim direction that turns more than AIM_SNAP_ANGLE degrees within AIM_SNAP_TIME
		-- seconds of the last shot and then HITS counts once; AIM_SNAP_COUNT of those inside
		-- AIM_SNAP_WINDOW seconds raise the flag.
		AIM_SNAP_ANGLE = 25,
		AIM_SNAP_TIME = 0.35,
		AIM_SNAP_COUNT = 3,
		AIM_SNAP_WINDOW = 10,
	},
}

-- "auto" resolves here, after the table, so it can look at the other switches.
if Config.ANTI_CHEAT.MOVEMENT_ACTION == "auto" then
	Config.ANTI_CHEAT.MOVEMENT_ACTION = if Config.DEMO_CHEAT_PANEL then "snap" else "log"
end

return Config
