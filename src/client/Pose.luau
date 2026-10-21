--!nonstrict
-- Holding and aiming, made in code. No uploaded animations: Roblox plays an uploaded animation only
-- in experiences its owner has granted, so a kit other developers drop in can't ship one. (Studio-
-- verified: IKControls also work on the newer AnimationConstraint joints, where the old "rotate
-- Waist.C0" trick fails because C0 is read-only there.)
--
-- Every client poses every character that holds a kit weapon by itself, with IKControls (Roblox's IK
-- solver) and a few joints turned directly. Nothing here is sent per frame and nothing here can change
-- a shot:
--   * the chest turns to the aim (long guns with the left shoulder forward, as a rifle stance; past
--     the waist's turn the hips follow) and the head looks along it. Your own aim comes from the
--     camera; other players' from their character's "WeaponKitAim" attribute (whole degrees, set by
--     the server from the Aim remote, at most ~10 times a second);
--   * the right hand goes to a hold point that swings with the aim around a pivot on the chest (the
--     chest as actually posed), the left hand to the gun (an Attachment named "LeftGrip" in the
--     model, else a point between the grip and the muzzle);
--   * both hands stay on the gun on any body: each arm's reach is measured from the rig's own joints,
--     and every frame the hold point moves and the left hand slides back along the gun until both
--     are within reach (fitHands). For that the waist, neck and arm joint limits are off while the
--     gun is out (this client only);
--   * after the IK has run, the gun is turned in the hand so the barrel lies exactly on the aim
--     line (the IK alone was 7-33 degrees off in Studio): a local change of the RightGrip weld;
--   * a recoil kick on every shot (a spring: yours at once, others' from FireFX) and a reload motion
--     (yours from the ammo state, others' from the "WeaponKitReloading" attribute);
--   * the gun kept out of the body: every frame the gun's corners are tested against THIS avatar's torso
--     and head boxes and the hold point is pushed out by the smallest move that clears them;
--   * near a wall the gun slides back toward the body and then tilts up (Config.WALL_MODE), so the
--     barrel doesn't go into the wall;
--   * standing still, your legs turn toward the aim once it is far to the side (Config.TURN_IN_PLACE):
--     the upper body never twists further than looks natural (the turn replicates like any movement).
-- Rigs: R15 (AnimationConstraint or Motor6D joints, any body scale or package) and R6 (its whole body
-- turns, and its arms, one joint each, are pointed directly). Any other rig keeps Roblox's normal tool
-- pose. Config.POSE = false turns it all off, for a game with its own gun animations.
-- Measured in Studio over 13 rigs x 3 guns x 25 aims: tests/studio/AUDIT.md.
--
-- Public functions (WeaponClient calls them):
--   Pose.start()
--   Pose.kick(character, recoil)          a shot: recoil = the weapon's `recoil` stat
--   Pose.reload(character, startClock?)   the reload started at os.clock() startClock, or ended (nil)
--   Pose.blocked(character) -> boolean    the gun is tilted up against a wall (WALL_MODE "block": no fire)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("WeaponKitShared")
local Config = require(Shared:WaitForChild("Config"))
local Weapons = require(Shared:WaitForChild("Weapons"))

local Pose = {}

local AIM_ATTRIBUTE = "WeaponKitAim" -- Vector2 (pitch, yaw) in whole degrees, yaw relative to the legs
local RELOAD_ATTRIBUTE = "WeaponKitReloading"
local AIM_DISTANCE = 50 -- studs: how far ahead the chest and hips look
local PITCH_LIMIT = 80 -- degrees up or down
local YAW_LIMIT = 75 -- degrees the upper body turns away from the legs
local SEND_INTERVAL = 0.1 -- seconds between two aim updates to the server
local SEND_STEP = 2 -- degrees: smaller aim changes are not sent
local FOLLOW_RATE = 15 -- 1/s: how fast other players' replicated aim is eased in
local BLEND_TIME = 0.15 -- seconds to blend the pose in after a weapon comes out
local RETRY_TIME = 0.5 -- seconds between two tries to pose a character that isn't ready yet
local TURN_LEFT, TURN_RIGHT = 60, -25 -- degrees: past these the legs turn in place (right is the hard side)
local TURN_RATE = 8 -- 1/s: how quickly the legs catch up
local WALL_PULL = 1 -- studs the gun slides back before it starts tilting up
local WALL_RAISE = 55 -- degrees the gun tilts up when the wall is a further stud closer
local WALL_RATE = 12 -- 1/s: how quickly the gun follows the wall
local CLEAR_MARGIN = 0.08 -- studs kept between the gun and the body
local CLEAR_MAX = 1.2 -- studs the body can push the gun at most
local CLEAR_RATE = 20 -- 1/s: how quickly the push follows
local CLEAR_RELAX = 2 -- 1/s: how quickly an unneeded push fades
local CHEST_CLEAR = 0.3 -- studs the grip is kept in front of the chest
local PISTOL_LENGTH = 1.9 -- studs from grip to muzzle: shorter guns are held like a pistol
local REACH_USE = 0.9 -- of an arm's length: the furthest a bending arm is asked to reach
local REACH_MIN = 0.5 -- of the gun arm's length: closer, the elbow would have to fold past its limit
local SLIDE_MIN = 0.35 -- how far back the left hand may slide along the gun (0 = level with the grip, 1 = its spot)
local SLIDE_RATE = 15 -- 1/s: how quickly the left hand slides
local HEAD_PITCH = 0.8 -- of the aim's pitch: how far the head tilts with it (the eyes do the rest)
local CHEST_RIGHT, CHEST_LEFT = 90, 60 -- degrees the chest may turn away from the hips
local HIPS_RIGHT = 45 -- degrees the hips (and legs) turn right as well when the chest alone can't (R15)
-- Joint limits (the avatar joint upgrade's BallSocketConstraints, which IKControls obey) are switched off
-- on the neck, waist and arms while a gun is held, on this client only, and put back when it's put
-- away. Studio, 10-20, blocky R15 body: with them on, the waist turns at most 20 degrees right (so the
-- left shoulder never comes forward), the neck 40 (the head can't face the aim from a turned chest)
-- and the arms stop 0.5-1.0 stud short of targets well inside their reach; with them off, both hands
-- reach (right <= 0.08, left <= 0.26 stud over 25 aims).
local FREE_JOINTS =
	{ "Neck", "Waist", "RightShoulder", "RightElbow", "RightWrist", "LeftShoulder", "LeftElbow", "LeftWrist" }

-- Recoil kick: a spring (stiffness, damping) on the gun's pitch, in degrees. A shot adds
-- KICK_IMPULSE * recoil to its speed; the gun also slides back KICK_BACK studs per degree.
local KICK_STIFFNESS = 400
local KICK_DAMPING = 24
local KICK_IMPULSE = 140
local KICK_BACK = 0.04

-- Reload motion at the middle of the reload: the gun dips and rolls, the left hand drops to the
-- magazine.
local RELOAD_DIP = 30 -- degrees
local RELOAD_ROLL = 25 -- degrees
local RELOAD_HAND = Vector3.new(0, -0.8, 0.3) -- studs, in the gun's space

-- Per stance: how far the chest turns away from the aim (long guns: left shoulder forward, as a real
-- rifle stance, so both of Roblox's short arms reach the gun: at 65 degrees a rifle sits beside the
-- torso of even a blocky body and both hands reach it); the pivot the grip swings around, from the
-- right shoulder in the chest's space (x right, y up, -z forward), and how far ahead of the pivot the
-- grip sits along the aim (fitHands then moves it into both arms' reach). Calibrated in Studio on
-- R15. The elbows have no IK poles: with the joint limits off, poles made more arm-in-body clipping
-- than none on held-out aims (Studio, 10-20: rifle 72 vs 60, pistol 46 vs 38, lower is better).
local STANCES = {
	rifle = {
		twist = 65,
		twistR6 = 80, -- R6 (no waist, one tall torso): at 65 its front corner was in the gun's path (Studio 10-20)
		pivot = Vector3.new(-0.05, -0.73, -0.71),
		reach = 0.55,
	},
	pistol = {
		twist = 15,
		twistR6 = 15,
		pivot = Vector3.new(0.09, -0.15, -0.35),
		reach = 1.2,
	},
}

local player = Players.LocalPlayer

local rigs = {} -- [character] = the posed rig (see attach)
local wanted = {} -- [character] = the kit Tool it holds
local nextTry = {} -- [character] = os.clock() of the next attach attempt
local aimRemote
local lastSend, sentPitch, sentYaw = -math.huge, math.huge, math.huge

local function findAttachment(root: Instance, name: string): Attachment?
	for _, item in root:GetDescendants() do
		if item.Name == name and item:IsA("Attachment") then
			return item
		end
	end
	return nil
end

-- Where a rig attachment of the upper torso sits in the root part's space when the avatar stands
-- straight: follows the R15 joint attachments (root -> lower torso -> upper torso), so it fits any
-- body scale and doesn't depend on the animation playing right now. Falls back to the current pose.
local function restPoint(character: Model, root: BasePart, upper: BasePart, name: string): Vector3
	local lower = character:FindFirstChild("LowerTorso")
	local a = root:FindFirstChild("RootRigAttachment")
	local b = lower and lower:FindFirstChild("RootRigAttachment")
	local c = lower and lower:FindFirstChild("WaistRigAttachment")
	local d = upper:FindFirstChild("WaistRigAttachment")
	local e = upper:FindFirstChild(name)
	if a and b and c and d and e then
		return a.Position - b.Position + c.Position - d.Position + e.Position
	end
	return root.CFrame:PointToObjectSpace(if e then e.WorldPosition else upper.Position)
end

-- One link of an arm: the distance between two of a part's attachments (`to` nil: to its centre).
local function link(part: Instance?, from: string, to: string?): number?
	local a = part and part:FindFirstChild(from)
	local b = if part and to then part:FindFirstChild(to) else nil
	if not (a and a:IsA("Attachment")) or (to and not (b and b:IsA("Attachment"))) then
		return nil
	end
	return ((if b then b.Position else Vector3.zero) - a.Position).Magnitude
end

-- The body as the pose sees it, or nil for a rig it doesn't know (that one keeps Roblox's tool pose).
-- Each arm is measured from the rig's own joint attachments, so any body scale, proportion or
-- package gets its real reach: shoulder (in the chest's space) and the length from the shoulder joint
-- to the point the IK puts on its target (each hand's grip attachment, in the palm).
local function describeR15(character: Model, root: BasePart)
	local upper, head = character:FindFirstChild("UpperTorso"), character:FindFirstChild("Head")
	local hand, leftHand = character:FindFirstChild("RightHand"), character:FindFirstChild("LeftHand")
	local grip = hand and hand:FindFirstChild("RightGripAttachment")
	local leftGrip = leftHand and leftHand:FindFirstChild("LeftGripAttachment")
	if not (upper and upper:IsA("BasePart") and head and hand and leftHand and leftHand:IsA("BasePart")) then
		return nil
	end
	-- (both hands' IK end effectors are their grip Attachments: the palms)
	if not (grip and grip:IsA("Attachment") and leftGrip and leftGrip:IsA("Attachment")) then
		return nil
	end
	local function arm(side: string, ending: string?)
		local shoulder = upper:FindFirstChild(side .. "ShoulderRigAttachment")
		local upperArm = character:FindFirstChild(side .. "UpperArm")
		local a = link(upperArm, side .. "ShoulderRigAttachment", side .. "ElbowRigAttachment")
		local b = link(
			character:FindFirstChild(side .. "LowerArm"),
			side .. "ElbowRigAttachment",
			side .. "WristRigAttachment"
		)
		local c = link(character:FindFirstChild(side .. "Hand"), side .. "WristRigAttachment", ending)
		if not (a and b and c and shoulder and shoulder:IsA("Attachment")) then
			return nil
		end
		return upperArm, shoulder.Position, a + b + c
	end
	local rightArm, shoulderR, reachR = arm("Right", "RightGripAttachment")
	local leftArm, shoulderL, reachL = arm("Left", "LeftGripAttachment")
	if not (rightArm and leftArm) then
		return nil
	end
	local lower = character:FindFirstChild("LowerTorso")
	local rootRig = root:FindFirstChild("RootRigAttachment")
	local lowerRig = lower and lower:FindFirstChild("RootRigAttachment")
	return {
		kind = "R15",
		neckJoint = head:FindFirstChild("Neck"),
		chest = upper,
		head = head,
		hand = hand,
		grip = grip,
		rightArm = rightArm,
		leftArm = leftArm,
		leftEnd = leftGrip,
		shoulderR = shoulderR,
		shoulderL = shoulderL,
		reachR = reachR,
		reachL = reachL,
		rigid = false,
		neck = restPoint(character, root, upper, "NeckRigAttachment"),
		lower = if lower and lower:IsA("BasePart") then lower else nil,
		-- the hips' centre in the root's space, standing straight
		hips = if rootRig and lowerRig then rootRig.Position - lowerRig.Position else Vector3.zero,
		body = { upper, head, lower },
	}
end

-- R6: each arm is one part on one joint (no elbow), so a hand is always exactly its arm's length from
-- the shoulder: the targets are put on those spheres (`rigid`).
local function describeR6(character: Model, root: BasePart)
	local torso, head = character:FindFirstChild("Torso"), character:FindFirstChild("Head")
	if not (torso and torso:IsA("BasePart") and head) then
		return nil
	end
	local function arm(side: string)
		local part = character:FindFirstChild(side .. " Arm")
		local motor = torso:FindFirstChild(side .. " Shoulder")
		local ending = part and part:FindFirstChild(side .. "GripAttachment")
		if
			not (
				motor
				and motor:IsA("Motor6D")
				and part
				and motor.Part1 == part
				and ending
				and ending:IsA("Attachment")
			)
		then
			return nil
		end
		return part, motor.C0.Position, (ending.Position - motor.C1.Position).Magnitude, ending, motor
	end
	local rightArm, shoulderR, reachR, grip, rightMotor = arm("Right")
	local leftArm, shoulderL, reachL, leftEnd, leftMotor = arm("Left")
	if not (rightArm and leftArm) then
		return nil
	end
	local rootJoint, neckJoint = root:FindFirstChild("RootJoint"), torso:FindFirstChild("Neck")
	return {
		kind = "R6",
		neckJoint = torso:FindFirstChild("Neck"),
		chest = torso,
		head = head,
		hand = rightArm,
		grip = grip,
		rightArm = rightArm,
		leftArm = leftArm,
		leftEnd = leftEnd,
		shoulderR = shoulderR,
		shoulderL = shoulderL,
		reachR = reachR,
		reachL = reachL,
		rigid = true,
		motors = { rightMotor, leftMotor },
		neck = if rootJoint
				and rootJoint:IsA("Motor6D")
				and neckJoint
				and neckJoint:IsA("Motor6D")
			then rootJoint.C0 * rootJoint.C1:Inverse() * neckJoint.C0.Position
			else root.CFrame:PointToObjectSpace(head.Position),
		body = { torso, head },
	}
end

-- The left hand's spot on the gun, in the gun's frame G (the RightGripAttachment's frame: the barrel
-- along -Z, up +Y, as in Roblox's default tool pose; a Handle-space point p sits at G-space
-- Grip:Inverse() * p): the model's "LeftGrip" Attachment, else a spot made from the muzzle.
local function leftSpotFor(tool: Tool, handle: BasePart): (Vector3, number)
	local muzzle = findAttachment(tool, "Muzzle")
	local muzzleG = if muzzle
		then tool.Grip:Inverse() * handle.CFrame:PointToObjectSpace(muzzle.WorldPosition)
		else Vector3.new(0, 0, -2)
	local length = -muzzleG.Z
	local given = findAttachment(tool, "LeftGrip")
	if given then
		return tool.Grip:Inverse() * handle.CFrame:PointToObjectSpace(given.WorldPosition), length
	end
	return if length < PISTOL_LENGTH
		then Vector3.new(-0.3, -0.35, 0.1) -- cupping the right hand
		else Vector3.new(0, muzzleG.Y * 0.5 - 0.25, muzzleG.Z * 0.55), -- under the barrel
		length
end

-- The points the body is kept away from, in the Handle's space: every visible part's centre and
-- corners (welded to the Handle, so they never move relative to it).
local function gunPoints(tool: Tool, handle: BasePart): { Vector3 }
	local points = {}
	for _, part in tool:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 1 then
			local cf, h = handle.CFrame:ToObjectSpace(part.CFrame), part.Size / 2
			table.insert(points, cf.Position)
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						table.insert(points, cf * Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
					end
				end
			end
		end
	end
	return points
end

local function newControl(humanoid: Humanoid, props): IKControl
	local ik = Instance.new("IKControl")
	ik.Name = "WeaponKitPose"
	ik.Weight = 0
	for key, value in props do
		ik[key] = value
	end
	ik.Parent = humanoid
	return ik
end

local function detach(character: Model)
	local rig = rigs[character]
	if not rig then
		return
	end
	rigs[character] = nil
	for _, item in rig.made do
		item:Destroy()
	end
	for joint, limits in rig.freed do
		joint.LimitsEnabled, joint.TwistLimitsEnabled = limits[1], limits[2]
	end
	local weld = rig.weld
	if weld and weld.Parent and rig.tool.Parent then
		weld.C1 = rig.tool.Grip
	end
end

-- Builds the IK setup for a character holding `tool`, or returns nil when it can't be posed (a custom
-- rig, or parts that haven't replicated yet: tried again later).
local function attach(character: Model, tool: Tool)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	local handle = tool:FindFirstChild("Handle")
	if
		not (humanoid and humanoid.Health > 0 and humanoid:FindFirstChildOfClass("Animator"))
		or not (root and root:IsA("BasePart") and handle and handle:IsA("BasePart"))
	then
		return nil
	end
	local body = if humanoid.RigType == Enum.HumanoidRigType.R6
		then describeR6(character, root)
		else describeR15(character, root)
	if not body then
		return nil
	end
	local upper = body.chest

	local def = Weapons.Defs[tool.Name]
	local leftSpot, length = leftSpotFor(tool, handle)
	local stance = STANCES[def.hold or (if length < PISTOL_LENGTH then "pistol" else "rifle")]

	local hold = Instance.new("Attachment")
	hold.Name = "WeaponKitHold"
	hold.Parent = root
	local leftGrip = Instance.new("Attachment")
	leftGrip.Name = "WeaponKitLeftGrip"
	leftGrip.Parent = root

	local rig = {
		character = character,
		humanoid = humanoid,
		root = root,
		hand = body.hand,
		tool = tool,
		handle = handle,
		stance = stance,
		isLocal = character == player.Character,
		upper = upper,
		neck = body.neck,
		shoulderR = body.shoulderR, -- the shoulder joints, in the chest's space
		shoulderL = body.shoulderL,
		reachR = body.reachR, -- studs from each shoulder joint to the point its IK places
		reachL = body.reachL,
		rigid = body.rigid,
		leftSpot = leftSpot, -- the left hand's spot on the gun (G frame)
		-- its IK target: on the root, where the spot will be once the gun is in the right hand (computed
		-- from the hold point, so it doesn't depend on where the IK has put the right hand yet)
		leftGrip = leftGrip,
		slide = 1,
		hold = hold,
		started = os.clock(),
		pitch = 0,
		yaw = 0,
		kick = 0,
		kickSpeed = 0,
		reloadStart = nil,
		gunTurn = CFrame.identity,
		weight = 0,
		length = length, -- grip to muzzle, studs
		wall = 0, -- studs the gun is pushed back by a wall (past WALL_PULL it tilts up)
		clear = Vector3.zero, -- the body's push on the hold point (aim space), see clearBody
		body = body.body,
		made = { hold, leftGrip },
		freed = {}, -- [BallSocketConstraint] = its limits before (put back by detach)
		neckJoint = body.neckJoint,
	}
	local chestAim = Instance.new("Attachment")
	chestAim.Name = "WeaponKitChest"
	chestAim.Parent = root
	rig.chestAim = chestAim
	table.insert(rig.made, chestAim)
	if body.kind == "R15" then
		local free = {}
		for _, name in FREE_JOINTS do
			free[name .. "BallSocket"] = true
		end
		for _, joint in character:GetDescendants() do
			if joint:IsA("BallSocketConstraint") and free[joint.Name] then
				rig.freed[joint] = { joint.LimitsEnabled, joint.TwistLimitsEnabled }
				joint.LimitsEnabled, joint.TwistLimitsEnabled = false, false
			end
		end
	end
	rig.rayParams = RaycastParams.new()
	rig.rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rig.rayParams.FilterDescendantsInstances = { character }
	rig.rayParams.IgnoreWater = true
	rig.points = gunPoints(tool, handle)
	-- solved in Priority order: hips, chest, the gun hand, the hand on the gun (the head: turnHead)
	local function look(part: BasePart, target: Attachment, priority: number): IKControl
		return newControl(humanoid, {
			Type = Enum.IKControlType.LookAt,
			ChainRoot = part,
			EndEffector = part,
			Target = target,
			Priority = priority,
		})
	end
	rig.controls = {
		-- the chest (R15: the waist joint only; R6: the root joint, so the whole body) looks at
		-- WeaponKitChest, set each frame by update (a Rotation control on this one-part chain turned the
		-- body NaN in Studio, 10-20)
		look(upper, chestAim, 1),
	}
	if body.kind == "R15" then
		if body.lower then
			local hipsAim = Instance.new("Attachment")
			hipsAim.Name = "WeaponKitHips"
			hipsAim.Parent = root
			rig.hipsAim, rig.hips = hipsAim, body.hips
			table.insert(rig.made, hipsAim)
			table.insert(rig.controls, look(body.lower, hipsAim, 0))
		end
		table.insert(
			rig.controls,
			newControl(humanoid, {
				Type = Enum.IKControlType.Transform,
				ChainRoot = body.rightArm,
				EndEffector = body.grip,
				Target = hold,
				Priority = 3,
			})
		)
		table.insert(
			rig.controls,
			newControl(humanoid, {
				-- Transform, not Position: a Position control placed the wrist as if the hand kept its
				-- animated turn, and the palm missed by the wrist-to-palm length (0.29 stud, Studio 10-20)
				Type = Enum.IKControlType.Transform,
				ChainRoot = body.leftArm,
				EndEffector = body.leftEnd,
				Target = leftGrip,
				Priority = 4,
			})
		)
	else
		-- R6: no elbows to bend: each arm just points its hand at its target (pointArms, not an IKControl)
		rig.arms = {
			{ motor = body.motors[1], point = body.grip, target = hold },
			{ motor = body.motors[2], point = body.leftEnd, target = leftGrip },
		}
	end
	for _, ik in rig.controls do
		table.insert(rig.made, ik)
	end
	local reloading = character:GetAttribute(RELOAD_ATTRIBUTE)
	if reloading and not rig.isLocal then
		rig.reloadStart = os.clock()
	end
	rigs[character] = rig
	return rig
end

-- The local player's aim, from the camera, in the legs' frame: pitch up, yaw left (degrees; the yaw
-- is not clamped yet).
local function cameraAim(root: BasePart): (number, number)
	local look = root.CFrame:VectorToObjectSpace(Workspace.CurrentCamera.CFrame.LookVector)
	local pitch = math.deg(math.asin(math.clamp(look.Y, -1, 1)))
	return math.clamp(pitch, -PITCH_LIMIT, PITCH_LIMIT), math.deg(math.atan2(-look.X, -look.Z))
end

-- Standing still with the aim far to the side: turn the legs toward it (only the local player's own
-- character; Roblox already turns a moving character, and a seat or an anchored root decides itself).
local function turnInPlace(rig, yaw: number, dt: number)
	local humanoid, root = rig.humanoid, rig.root
	if
		not Config.TURN_IN_PLACE
		or not humanoid.AutoRotate
		or humanoid.SeatPart
		or root.Anchored
		or humanoid.MoveDirection.Magnitude > 0.1
	then
		return
	end
	local excess = if yaw > TURN_LEFT then yaw - TURN_LEFT elseif yaw < TURN_RIGHT then yaw - TURN_RIGHT else 0
	if excess ~= 0 then
		root.CFrame *= CFrame.Angles(0, math.rad(excess * math.min(1, TURN_RATE * dt)), 0)
	end
end

-- How far the body pushes the gun this frame, in world space: for every gun point inside a torso or
-- head box (plus CLEAR_MARGIN), the shortest way out of that box; the biggest push along each of the
-- box's axes wins. The hold point follows it (smoothed), so the gun ends up just outside the body.
local function bodyPush(rig): Vector3
	local push = Vector3.zero
	local handleCF = rig.handle.CFrame
	for _, part in rig.body do
		if part and part.Parent then
			local cf, half = part.CFrame, part.Size / 2 + Vector3.one * CLEAR_MARGIN
			local px, nx, py, ny, pz, nz = 0, 0, 0, 0, 0, 0
			for _, point in rig.points do
				local l = cf:PointToObjectSpace(handleCF * point)
				local dx, dy, dz = half.X - math.abs(l.X), half.Y - math.abs(l.Y), half.Z - math.abs(l.Z)
				if dx > 0 and dy > 0 and dz > 0 then
					-- out through the nearest face (Y last: pushing a gun up or down through a torso looks wrong)
					if dx <= dz and dx <= dy * 2 then
						if l.X >= 0 then
							px = math.max(px, dx)
						else
							nx = math.max(nx, dx)
						end
					elseif dz <= dy * 2 then
						if l.Z >= 0 then
							pz = math.max(pz, dz)
						else
							nz = math.max(nz, dz)
						end
					else
						if l.Y >= 0 then
							py = math.max(py, dy)
						else
							ny = math.max(ny, dy)
						end
					end
				end
			end
			push += cf:VectorToWorldSpace(Vector3.new(px - nx, py - ny, pz - nz))
		end
	end
	return push
end

-- The point of a ball (radius r around c) nearest to p; `rigid`: of its surface (an R6 arm can't bend).
local function onto(p: Vector3, c: Vector3, r: number, rigid: boolean): Vector3
	local v = p - c
	local m = v.Magnitude
	if m < 1e-4 or (m <= r and not rigid) then
		return p
	end
	return c + v * (r / m)
end

-- Both hands on the gun, on any body: moves the grip (root space) and slides the left hand along the gun
-- so that each hand's target is within its arm's measured reach from its shoulder (the chest as posed
-- last frame). Stance numbers alone can't do it: arm length and shoulder width differ by avatar
-- (Studio, 10-20: on a blocky R15 body the rifle's left spot was 2.95 studs from the shoulder, the
-- whole arm 1.84). First the right hand is kept in reach; then the left hand slides back toward the
-- grip, at most to SLIDE_MIN; only if that's not enough does the gun itself move (toward the chest's
-- middle: a two-handed pistol ends up centred, as in a real two-handed grip).
local function fitHands(rig, grip: Vector3, chest: CFrame, keepFront: (Vector3) -> Vector3): (Vector3, number)
	local rigid = rig.rigid
	local use = if rigid then 1 else REACH_USE
	local sR, sL = chest * rig.shoulderR, chest * rig.shoulderL
	local rR, rL = rig.reachR * use, rig.reachL * use
	local spot = rig.leftSpot
	local base = rig.gunTurn:VectorToWorldSpace(Vector3.new(spot.X, spot.Y, 0))
	local along = rig.gunTurn:VectorToWorldSpace(Vector3.new(0, 0, spot.Z))
	local function right(p: Vector3): Vector3
		p = onto(p, sR, rR, rigid)
		local v = p - sR
		local near = rig.reachR * REACH_MIN
		return if not rigid and v.Magnitude < near and v.Magnitude > 1e-4 then sR + v.Unit * near else p
	end
	grip = right(grip)

	-- Slide: the spot at t (1 = the gun's own spot) is grip + base + along * t; the left hand reaches
	-- it where |a + along * t| <= rL (rigid: = rL), a quadratic in t.
	local a = grip + base - sL
	local bb, ab = along:Dot(along), a:Dot(along)
	local slide
	if bb < 0.01 then
		slide = 1 -- nothing to slide along (a pistol's cupping hand)
		if (if rigid then math.abs(a.Magnitude - rL) else a.Magnitude - rL) <= 0.02 then
			return grip, slide
		end
	else
		local disc = ab * ab - bb * (a:Dot(a) - rL * rL)
		if disc >= 0 then
			local s = math.sqrt(disc)
			local t1, t2 = (-ab - s) / bb, (-ab + s) / bb
			if rigid then
				-- on the sphere: the root nearest the gun's own spot, if it lies on the gun's slide range
				local t = if math.abs(t1 - 1) < math.abs(t2 - 1) then t1 else t2
				if t >= SLIDE_MIN and t <= 1 then
					return grip, t
				end
			elseif math.min(1, t2) >= math.max(SLIDE_MIN, t1) then
				return grip, math.min(1, t2)
			end
		end
		slide = math.clamp(-ab / bb, SLIDE_MIN, 1) -- nearest the shoulder
	end

	-- Still out of reach: move the gun into reach of both hands (alternating projections onto the two
	-- reach balls and the space in front of the chest; a few steps settle it).
	local offset = base + along * slide
	for _ = 1, 6 do
		grip = keepFront(grip)
		grip = onto(grip + offset, sL, rL, rigid) - offset
		grip = right(grip)
	end
	return grip, slide
end

local function sendAim(pitch: number, yaw: number, now: number)
	if now - lastSend < SEND_INTERVAL then
		return
	end
	if math.abs(pitch - sentPitch) < SEND_STEP and math.abs(yaw - sentYaw) < SEND_STEP then
		return
	end
	lastSend, sentPitch, sentYaw = now, math.round(pitch), math.round(yaw)
	aimRemote:FireServer(sentPitch, sentYaw)
end

-- 0 -> 1 -> 0 over the weapon's reload time.
local function reloadEnvelope(rig, now: number): number
	if not rig.reloadStart then
		return 0
	end
	local def = Weapons.Defs[rig.tool.Name]
	local t = (now - rig.reloadStart) / def.reloadTime
	if t >= 1 then
		rig.reloadStart = nil
		return 0
	end
	return math.sin(math.pi * math.clamp(t, 0, 1))
end

-- Before the animation step: aim, spring and reload decide where the targets go this frame.
local function update(rig, now: number, dt: number)
	if rig.isLocal then
		local pitch, yaw = cameraAim(rig.root)
		turnInPlace(rig, yaw, dt)
		rig.pitch, rig.yaw = pitch, math.clamp(yaw, -YAW_LIMIT, YAW_LIMIT)
		sendAim(rig.pitch, rig.yaw, now)
	else
		local aim = rig.character:GetAttribute(AIM_ATTRIBUTE)
		if typeof(aim) == "Vector2" then
			local follow = 1 - math.exp(-FOLLOW_RATE * dt)
			rig.pitch += (math.clamp(aim.X, -PITCH_LIMIT, PITCH_LIMIT) - rig.pitch) * follow
			rig.yaw += (math.clamp(aim.Y, -YAW_LIMIT, YAW_LIMIT) - rig.yaw) * follow
		end
	end

	-- Recoil spring (semi-implicit Euler, a few steps when a frame runs long).
	local steps = math.clamp(math.ceil(dt / (1 / 120)), 1, 8)
	local h = dt / steps
	for _ = 1, steps do
		rig.kickSpeed += (-KICK_STIFFNESS * rig.kick - KICK_DAMPING * rig.kickSpeed) * h
		rig.kick += rig.kickSpeed * h
	end

	local reload = reloadEnvelope(rig, now)
	rig.weight = math.clamp((now - rig.started) / BLEND_TIME, 0, 1)
	for _, ik in rig.controls do
		ik.Weight = rig.weight
	end

	local yaw = CFrame.Angles(0, math.rad(rig.yaw), 0)
	local pitch = math.rad(rig.pitch)
	local turn = yaw * CFrame.Angles(pitch, 0, 0)
	if rig.chestAim then
		-- The chest turns right of the aim by the stance's twist (left shoulder forward), upright: bending
		-- it with the aim's pitch swung a turned chest into the gun (Studio, 10-20, blocky body, rifle:
		-- gun-in-body mean 2.1% upright vs 8.4% bent 0.8 of the pitch).
		local chestYaw = rig.yaw - (if rig.arms then rig.stance.twistR6 else rig.stance.twist)
		local hipsYaw = 0
		if rig.hipsAim then
			-- past the waist's turn the hips turn too (seen from outside: the feet turn toward the aim)
			hipsYaw = math.clamp(chestYaw + CHEST_RIGHT, -HIPS_RIGHT, 0)
			rig.hipsAim.Position = rig.hips
				+ Vector3.new(-math.sin(math.rad(hipsYaw)), 0, -math.cos(math.rad(hipsYaw))) * AIM_DISTANCE
		end
		-- (R6 turns its whole body, hips included)
		local most = if rig.arms then -(CHEST_RIGHT + HIPS_RIGHT) else hipsYaw - CHEST_RIGHT
		chestYaw = math.clamp(chestYaw, most, CHEST_LEFT)
		rig.chestAim.Position = rig.neck
			+ Vector3.new(-math.sin(math.rad(chestYaw)), 0, -math.cos(math.rad(chestYaw))) * AIM_DISTANCE
	end

	-- The grip swings with the aim around a pivot fixed to the chest as it was posed last frame. The
	-- real chest, not an ideal one: the turn is capped (CHEST_RIGHT, HIPS_RIGHT), eased by the IK, and
	-- a game's own joint limits or animations can hold it back (with Roblox's limits on, the chest
	-- turned -20 vs -67 degrees at a hard-right aim on the two rig types, Studio 10-11).
	local stance = rig.stance
	local rootCF = rig.root.CFrame
	local chest = rootCF:ToObjectSpace(rig.upper.CFrame)
	local pivot = chest * (rig.shoulderR + stance.pivot)

	-- A wall in front: how far the barrel would go into it, from the pivot along the aim.
	local wallTarget = 0
	if Config.WALL_MODE ~= "off" then
		local reach = stance.reach + rig.length + 0.2
		local hit = Workspace:Raycast(rootCF * pivot, rootCF:VectorToWorldSpace(turn.LookVector) * reach, rig.rayParams)
		if hit then
			wallTarget = reach - hit.Distance
		end
	end
	rig.wall += (wallTarget - rig.wall) * (1 - math.exp(-WALL_RATE * dt))
	local pull = math.min(rig.wall, WALL_PULL)
	local raise = math.rad(WALL_RAISE * math.clamp(rig.wall - WALL_PULL, 0, 1))

	local dip = math.rad(RELOAD_DIP * reload)
	local holdFrame = CFrame.new(pivot) * yaw * CFrame.Angles(pitch - dip + raise, 0, 0)

	-- The body's push (measured on last frame's gun), in the hold's own space, eased and capped. With
	-- nothing to push, it relaxes slowly so the gun drifts back to its stance and settles just clear.
	local push = bodyPush(rig)
	local pushTarget = if push.Magnitude > 0
		then (rootCF * holdFrame):VectorToObjectSpace(push) + rig.clear
		else rig.clear * (1 - math.min(1, CLEAR_RELAX * dt))
	if pushTarget.Magnitude > CLEAR_MAX then
		pushTarget = pushTarget.Unit * CLEAR_MAX
	end
	rig.clear += (pushTarget - rig.clear) * (1 - math.exp(-CLEAR_RATE * dt))

	-- The grip, kept in front of the chest (a very deep or turned torso could still reach it).
	local half = rig.upper.Size / 2
	local front = -(half.Z + CHEST_CLEAR)
	local function keepFront(p: Vector3): Vector3
		local inChest = chest:PointToObjectSpace(p)
		if inChest.Z > front and math.abs(inChest.X) < half.X + CHEST_CLEAR and math.abs(inChest.Y) < half.Y then
			return chest * Vector3.new(inChest.X, inChest.Y, front)
		end
		return p
	end
	local back = Vector3.new(0, 0, rig.kick * KICK_BACK + pull)
	local grip = keepFront(holdFrame * (Vector3.new(0, 0, -stance.reach) + back + rig.clear))
	rig.gunTurn = turn
		* CFrame.Angles(math.rad(rig.kick) - dip + raise, 0, 0)
		* CFrame.Angles(0, 0, math.rad(RELOAD_ROLL * reload))
	local slide
	grip, slide = fitHands(rig, grip, chest, keepFront)
	if grip ~= grip then
		rig.clear = Vector3.zero -- a broken (NaN) body this frame: keep last frame's targets, don't let it stick
		return
	end
	rig.slide += (slide - rig.slide) * (1 - math.exp(-SLIDE_RATE * dt))
	local spot = rig.leftSpot
	-- the left palm on its spot, the hand straight on from the shoulder (no bent wrist), gun side up
	local leftAt = grip
		+ rig.gunTurn:VectorToWorldSpace(Vector3.new(spot.X, spot.Y, spot.Z * rig.slide) + RELOAD_HAND * reload)
	local along = leftAt - chest * rig.shoulderL
	rig.leftGrip.CFrame = if along.Magnitude > 0.01
		then CFrame.lookAt(leftAt, leftAt + along, rig.gunTurn.UpVector)
		else CFrame.new(leftAt)
	rig.hold.CFrame = holdFrame.Rotation + grip
end

-- A joint's two frames: f0 in the world (on its parent part) and f1 in its child part's space, so that
-- child = f0 * Transform * f1:Inverse() (a Motor6D: C0 and C1; an AnimationConstraint: its attachments).
local function jointFrames(joint: Instance?): (CFrame?, CFrame?)
	if joint and joint:IsA("Motor6D") and joint.Part0 then
		return joint.Part0.CFrame * joint.C0, joint.C1
	elseif joint and joint:IsA("AnimationConstraint") and joint.Attachment0 and joint.Attachment1 then
		return joint.Attachment0.WorldCFrame, joint.Attachment1.CFrame
	end
	return nil, nil
end

-- After the animation step: the head looks along the aim, level (no roll). Turned on its neck joint
-- directly: a LookAt IKControl picks its own roll, and from a chest turned 65 degrees the head rolled
-- sideways into the gun when aiming down (Studio, 10-20).
local function turnHead(rig)
	local joint = rig.neckJoint
	local f0, f1 = jointFrames(joint)
	if not (f0 and f1) then
		return
	end
	local want = rig.root.CFrame.Rotation
		* CFrame.Angles(0, math.rad(rig.yaw), 0)
		* CFrame.Angles(math.rad(rig.pitch * HEAD_PITCH), 0, 0)
	local turn = f0.Rotation:Inverse() * want * f1.Rotation
	joint.Transform = joint.Transform:Lerp(turn, rig.weight)
end

-- The rotation that turns direction `from` onto direction `to` the shortest way.
local function arc(from: Vector3, to: Vector3): CFrame
	local a, b = from.Unit, to.Unit
	local axis = a:Cross(b)
	if axis.Magnitude < 1e-5 then
		return if a:Dot(b) > 0
			then CFrame.identity
			else CFrame.fromAxisAngle(a:Cross(Vector3.yAxis + a.Y * Vector3.xAxis).Unit, math.pi)
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(a:Dot(b), -1, 1)))
end

-- R6 arms, after the animation step: each shoulder turns so its hand's point lies on the line to its
-- target (fitHands put the target at the arm's length). Not an IKControl: on these one-joint Motor6D
-- chains it slid the joint instead of turning it (Studio, 10-20: both arms came off the shoulders).
-- The gun hand's new CFrame is kept for alignGun (its part may not have moved yet this frame).
local function pointArms(rig)
	for i, arm in rig.arms do
		local motor = arm.motor
		if motor.Parent and motor.Part0 then
			local joint = motor.Part0.CFrame * motor.C0
			local rest = motor.C1:Inverse() * arm.point.Position -- the hand's point from the joint, unturned
			local want = joint:PointToObjectSpace(arm.target.WorldPosition)
			if want.Magnitude > 0.01 and rest.Magnitude > 0.01 then
				local turn = motor.Transform:Lerp(arc(rest, want), rig.weight)
				motor.Transform = turn
				if i == 1 then
					rig.handCF = joint * turn * motor.C1:Inverse()
				end
			end
		end
	end
end

-- After the animation step (the IK has placed the hand): turn the gun in the hand onto the aim line.
-- RightGrip: Handle = Hand * C0 * C1:Inverse(), so for the grip frame G = Hand * C0 to become D,
-- C1 = Grip * D:Inverse() * G.
local function alignGun(rig)
	local weld = rig.weld
	if not (weld and weld.Parent == rig.hand and weld.Part1 == rig.handle) then
		weld = rig.hand:FindFirstChild("RightGrip")
		if not (weld and weld:IsA("JointInstance") and weld.Part1 == rig.handle) then
			return
		end
		rig.weld = weld
	end
	local g = (rig.handCF or rig.hand.CFrame) * weld.C0
	local d = CFrame.new(g.Position) * rig.root.CFrame.Rotation * rig.gunTurn
	weld.C1 = rig.tool.Grip * g:Lerp(d, rig.weight):Inverse() * g
end

local function watchCharacter(character: Model)
	local function consider(child: Instance)
		if child:IsA("Tool") and Weapons.Defs[child.Name] then
			detach(character)
			wanted[character] = child
			nextTry[character] = 0
		end
	end
	character.ChildAdded:Connect(consider)
	character.ChildRemoved:Connect(function(child)
		if wanted[character] == child then
			wanted[character] = nil
			detach(character)
		end
	end)
	character:GetAttributeChangedSignal(RELOAD_ATTRIBUTE):Connect(function()
		local rig = rigs[character]
		if rig and not rig.isLocal then
			rig.reloadStart = if character:GetAttribute(RELOAD_ATTRIBUTE) then os.clock() else nil
		end
	end)
	character.Destroying:Connect(function()
		wanted[character], nextTry[character] = nil, nil
		detach(character)
	end)
	for _, child in character:GetChildren() do
		consider(child)
	end
end

local function watchPlayer(other: Player)
	other.CharacterAdded:Connect(watchCharacter)
	if other.Character then
		watchCharacter(other.Character)
	end
end

function Pose.kick(character: Model?, recoil: number)
	local rig = character and rigs[character]
	if rig then
		rig.kickSpeed += KICK_IMPULSE * recoil
	end
end

function Pose.reload(character: Model?, startClock: number?)
	local rig = character and rigs[character]
	if rig then
		rig.reloadStart = startClock
	end
end

function Pose.blocked(character: Model?): boolean
	local rig = character and rigs[character]
	return rig ~= nil and Config.WALL_MODE == "block" and rig.wall > WALL_PULL + 0.5
end

function Pose.start()
	if not Config.POSE then
		return
	end
	aimRemote = ReplicatedStorage:WaitForChild("WeaponKitRemotes"):WaitForChild("Aim")
	Players.PlayerAdded:Connect(watchPlayer)
	for _, other in Players:GetPlayers() do
		watchPlayer(other)
	end

	RunService.PreAnimation:Connect(function(dt)
		local now = os.clock()
		for character, tool in wanted do
			local rig = rigs[character]
			if rig and (rig.tool ~= tool or rig.humanoid.Health <= 0 or not character.Parent) then
				detach(character)
				rig = nil
			end
			if not rig and now >= (nextTry[character] or 0) and character.Parent then
				nextTry[character] = now + RETRY_TIME
				rig = attach(character, tool)
			end
			if rig then
				update(rig, now, dt)
			end
		end
	end)
	RunService.PreSimulation:Connect(function()
		for _, rig in rigs do
			turnHead(rig)
			if rig.arms then
				pointArms(rig)
			end
			alignGun(rig)
		end
	end)
end

return Pose
