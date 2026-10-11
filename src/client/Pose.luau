--!nonstrict
-- Holding and aiming, made in code. No uploaded animations: Roblox plays an uploaded animation only
-- in experiences its owner has granted, so a kit other developers drop in can't ship one. (Studio-
-- verified: IKControls also work on the newer AnimationConstraint joints, where the old "rotate
-- Waist.C0" trick fails because C0 is read-only there.)
--
-- Every client poses every character that holds a kit weapon by itself, with IKControls (Roblox's IK
-- solver). Nothing here is sent per frame and nothing here can change a shot:
--   * the upper body and head turn to the aim. Your own aim comes from the camera; other players'
--     from their character's "WeaponKitAim" attribute (whole degrees, set by the server from the Aim
--     remote, at most ~10 times a second). Long guns turn the torso so both hands reach the gun;
--   * the right hand goes to a hold point in front of the right shoulder, the left hand to the gun
--     (an Attachment named "LeftGrip" in the model, else a point between the grip and the muzzle);
--   * after the IK has run, the gun is turned in the hand so the barrel lies exactly on the aim
--     line (the IK alone was 7-33 degrees off in Studio): a local change of the RightGrip weld;
--   * a recoil kick on every shot (a spring: yours at once, others' from FireFX) and a reload motion
--     (yours from the ammo state, others' from the "WeaponKitReloading" attribute);
--   * no gun through the body: every frame the gun's corners are tested against THIS avatar's torso
--     and head boxes and the hold point is pushed out by the smallest move that clears them, so it
--     fits any body shape (Rthro, scaled, bulky) without per-avatar tuning. Elbows get IK poles that
--     keep them out and down, away from the chest;
--   * near a wall the gun slides back toward the body and then tilts up (Config.WALL_MODE), so the
--     barrel doesn't go into the wall;
--   * standing still, your legs turn toward the aim once it is far to the side (Config.TURN_IN_PLACE):
--     the upper body never twists further than looks natural (the turn replicates like any movement).
-- Stance numbers were calibrated in Studio by a search that scored, over 10 aim directions: the gun
-- turned in the hand, the hands' distance from their targets, and gun/arm points inside the torso or
-- head (body clipping).
-- R15 only: an R6 or custom rig keeps Roblox's normal tool pose. Config.POSE = false turns it all
-- off, for a game with its own gun animations.
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
local AIM_DISTANCE = 50 -- studs: how far ahead the torso and head look
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

-- Per stance: how far the torso turns away from the aim (long guns: left shoulder forward, as a
-- real rifle stance, so both of Roblox's short arms reach the gun); the pivot the grip swings
-- around, from the right shoulder in the upper torso's space (x right, y up, -z forward: a rifle's
-- butt pocket in front of the chest, a pistol's straight arm), and how far ahead of the pivot the
-- grip sits along the aim; and the points the elbows bend toward (IK poles), from each shoulder in
-- the upper torso's space (they turn with the torso). Calibrated in Studio on R15 (pivot and reach
-- keep the straight-ahead grip where the earlier calibration put it).
local STANCES = {
	rifle = {
		twist = 65,
		pivot = Vector3.new(-0.05, -0.73, -0.71),
		reach = 0.55,
		poleRight = Vector3.new(1, -2, 1),
		poleLeft = Vector3.new(-2, -1, 0),
	},
	pistol = {
		twist = 25,
		pivot = Vector3.new(0.09, -0.15, -0.35),
		reach = 1.2,
		poleRight = Vector3.new(1, -2, 0),
		poleLeft = Vector3.new(-1.5, -1, 0.5),
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

-- The right shoulder joint in the upper torso's own space (follows the body's scale).
local function shoulderPoint(upper: BasePart): Vector3
	local joint = upper:FindFirstChild("RightShoulderRigAttachment")
	return if joint and joint:IsA("Attachment")
		then joint.Position
		else Vector3.new(upper.Size.X / 2, upper.Size.Y * 0.35, 0)
end

-- The left hand's spot on the gun: the model's "LeftGrip" Attachment, else one made from the muzzle.
-- Positions are in the gun's frame G (the RightGripAttachment's frame: the barrel along -Z, up +Y,
-- as in Roblox's default tool pose); a Handle-space point p sits at G-space Grip:Inverse() * p.
local function leftGripFor(tool: Tool, handle: BasePart): (Attachment, boolean, number)
	local muzzle = findAttachment(tool, "Muzzle")
	local muzzleG = if muzzle
		then tool.Grip:Inverse() * handle.CFrame:PointToObjectSpace(muzzle.WorldPosition)
		else Vector3.new(0, 0, -2)
	local length = -muzzleG.Z
	local given = findAttachment(tool, "LeftGrip")
	if given then
		return given, false, length
	end
	local spotG = if length < PISTOL_LENGTH
		then Vector3.new(-0.3, -0.35, 0.1) -- cupping the right hand
		else Vector3.new(0, muzzleG.Y * 0.5 - 0.25, muzzleG.Z * 0.55) -- under the barrel
	local made = Instance.new("Attachment")
	made.Name = "WeaponKitLeftGrip"
	made.Position = tool.Grip * spotG
	made.Parent = handle
	return made, true, length
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
	local weld = rig.weld
	if weld and weld.Parent and rig.tool.Parent then
		weld.C1 = rig.tool.Grip
	end
end

-- Builds the IK setup for a character holding `tool`, or returns nil when it can't be posed (R6, a
-- custom rig, or parts that haven't replicated yet: tried again later).
local function attach(character: Model, tool: Tool)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	local upper, head = character:FindFirstChild("UpperTorso"), character:FindFirstChild("Head")
	local rightArm, leftArm = character:FindFirstChild("RightUpperArm"), character:FindFirstChild("LeftUpperArm")
	local rightHand, leftHand = character:FindFirstChild("RightHand"), character:FindFirstChild("LeftHand")
	local handle = tool:FindFirstChild("Handle")
	local gripPoint = rightHand and rightHand:FindFirstChild("RightGripAttachment")
	if
		not (humanoid and humanoid.Health > 0 and humanoid:FindFirstChildOfClass("Animator"))
		or not (root and upper and head and rightArm and leftArm and rightHand and leftHand)
		or not (handle and handle:IsA("BasePart") and gripPoint)
	then
		return nil
	end

	local def = Weapons.Defs[tool.Name]
	local leftGrip, madeLeft, length = leftGripFor(tool, handle)
	local stance = STANCES[def.hold or (if length < PISTOL_LENGTH then "pistol" else "rifle")]

	local aim = Instance.new("Attachment")
	aim.Name = "WeaponKitAim"
	aim.Parent = root
	local hold = Instance.new("Attachment")
	hold.Name = "WeaponKitHold"
	hold.Parent = root

	local rig = {
		character = character,
		humanoid = humanoid,
		root = root,
		hand = rightHand,
		tool = tool,
		handle = handle,
		stance = stance,
		isLocal = character == player.Character,
		upper = upper,
		neck = restPoint(character, root, upper, "NeckRigAttachment"),
		shoulder = shoulderPoint(upper),
		aim = aim,
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
		body = { upper, head, character:FindFirstChild("LowerTorso") },
		made = { aim, hold },
	}
	rig.rayParams = RaycastParams.new()
	rig.rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rig.rayParams.FilterDescendantsInstances = { character }
	rig.rayParams.IgnoreWater = true
	rig.points = gunPoints(tool, handle)
	local function pole(side: string, offset: Vector3): Attachment
		local shoulder = upper:FindFirstChild(side .. "ShoulderRigAttachment")
		local point = Instance.new("Attachment")
		point.Name = "WeaponKitPole" .. side
		point.Position = (if shoulder then shoulder.Position else Vector3.zero) + offset
		point.Parent = upper
		table.insert(rig.made, point)
		return point
	end
	rig.controls = {
		-- solved in Priority order: torso, then head, then the gun hand, then the hand on the gun
		newControl(humanoid, {
			Type = Enum.IKControlType.LookAt,
			ChainRoot = upper,
			EndEffector = head,
			Target = aim,
			-- the axis that points at the aim is turned left: the torso turns right (left shoulder forward)
			EndEffectorOffset = CFrame.Angles(0, math.rad(stance.twist), 0),
			Priority = 0,
		}),
		newControl(humanoid, {
			Type = Enum.IKControlType.LookAt,
			ChainRoot = head,
			EndEffector = head,
			Target = aim,
			Priority = 1,
		}),
		newControl(humanoid, {
			Type = Enum.IKControlType.Transform,
			ChainRoot = rightArm,
			EndEffector = gripPoint,
			Target = hold,
			Pole = pole("Right", stance.poleRight),
			Priority = 2,
		}),
		newControl(humanoid, {
			Type = Enum.IKControlType.Position,
			ChainRoot = leftArm,
			EndEffector = leftHand,
			Target = leftGrip,
			Pole = pole("Left", stance.poleLeft),
			Priority = 3,
		}),
	}
	rig.leftControl = rig.controls[4]
	for _, ik in rig.controls do
		table.insert(rig.made, ik)
	end
	if madeLeft then
		table.insert(rig.made, leftGrip)
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
	rig.aim.Position = rig.neck + turn.LookVector * AIM_DISTANCE

	-- The grip swings with the aim around a pivot fixed to the chest as it was posed last frame. The
	-- real chest, not an ideal one: joint limits (the BallSocketConstraints of Roblox's avatar joint
	-- upgrade, which IKControls obey) let the torso follow the aim only part of the way, and by a
	-- different amount on each rig type (Studio: -20 vs -67 degrees at a hard-right aim).
	local stance = rig.stance
	local rootCF = rig.root.CFrame
	local chest = rootCF:ToObjectSpace(rig.upper.CFrame)
	local pivot = chest * (rig.shoulder + stance.pivot)

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
	local back = Vector3.new(0, 0, rig.kick * KICK_BACK + pull)
	local grip = holdFrame * (Vector3.new(0, 0, -stance.reach) + back + rig.clear)
	local inChest, half = chest:PointToObjectSpace(grip), rig.upper.Size / 2
	local front = -(half.Z + CHEST_CLEAR)
	if inChest.Z > front and math.abs(inChest.X) < half.X + CHEST_CLEAR and math.abs(inChest.Y) < half.Y then
		grip = chest * Vector3.new(inChest.X, inChest.Y, front)
	end
	rig.hold.CFrame = holdFrame.Rotation + grip
	rig.leftControl.Offset = CFrame.new(RELOAD_HAND * reload)
	rig.gunTurn = turn
		* CFrame.Angles(math.rad(rig.kick) - dip + raise, 0, 0)
		* CFrame.Angles(0, 0, math.rad(RELOAD_ROLL * reload))
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
	local g = rig.hand.CFrame * weld.C0
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
			alignGun(rig)
		end
	end)
end

return Pose
