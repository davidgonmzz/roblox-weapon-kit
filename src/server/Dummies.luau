--!nonstrict
-- Target dummies, built entirely from Parts in the standard R6 layout (Head, Torso, four limbs,
-- HumanoidRootPart, a Humanoid, joined by Motor6Ds like a real R6 character). Because they are
-- real Humanoid rigs, the weapon code needs nothing special for them: a hit part named "Head"
-- is a headshot, damage goes through Humanoid:TakeDamage, and a tag (Config.TARGET_TAG) tells
-- WeaponServer they are allowed targets.
--
-- Each dummy has a health bar, flashes when hit, topples when killed and is replaced by a fresh
-- one Config.DUMMY_RESPAWN_SECONDS after it died. A spot with `strafe` set makes its dummy
-- walk left and right with Humanoid:MoveTo; the others stand still (their root part is
-- anchored, so nothing can push them over).
--
--   Dummies.init(spots)   spots = { { label, position, strafe? }, ... } (see Range.TARGETS)

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("WeaponKitShared"):WaitForChild("Config"))

local Dummies = {}

local TORSO_COLOR = Color3.fromRGB(255, 120, 40)
local HEAD_COLOR = Color3.fromRGB(245, 235, 220)
local LIMB_COLOR = Color3.fromRGB(70, 74, 84)
local ROOT_HEIGHT = 3 -- R6: legs (2) + half the torso (1): root centre above the soles

-- The standard R6 joint table: name, parent part, child part, C0, C1. (Same numbers the
-- default R6 rig uses; the head is a slightly bigger ball, so its neck sits a bit lower.)
local R6 = {
	{
		"RootJoint",
		"HumanoidRootPart",
		"Torso",
		CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0),
		CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0),
	},
	{
		"Neck",
		"Torso",
		"Head",
		CFrame.new(0, 1, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0),
		CFrame.new(0, -0.6, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0),
	},
	{
		"Right Shoulder",
		"Torso",
		"Right Arm",
		CFrame.new(1, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0),
		CFrame.new(-0.5, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0),
	},
	{
		"Left Shoulder",
		"Torso",
		"Left Arm",
		CFrame.new(-1, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0),
		CFrame.new(0.5, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0),
	},
	{
		"Right Hip",
		"Torso",
		"Right Leg",
		CFrame.new(1, -1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0),
		CFrame.new(0.5, 1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0),
	},
	{
		"Left Hip",
		"Torso",
		"Left Leg",
		CFrame.new(-1, -1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0),
		CFrame.new(-0.5, 1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0),
	},
}

local function newPart(name: string, size: Vector3, color: Color3, collides: boolean): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.CanCollide = collides
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- Concentric rings on the front of the torso, so the dummy reads as a target from far away.
local function addBullseye(torso: Part)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Bullseye"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.Parent = torso
	local rings = {
		{ 0.8, Color3.new(1, 1, 1) },
		{ 0.58, Color3.fromRGB(200, 30, 30) },
		{ 0.36, Color3.new(1, 1, 1) },
		{ 0.15, Color3.fromRGB(200, 30, 30) },
	}
	for _, ring in rings do
		local frame = Instance.new("Frame")
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.5)
		frame.Size = UDim2.fromScale(ring[1], ring[1])
		frame.BackgroundColor3 = ring[2]
		frame.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = frame
		frame.Parent = gui
	end
end

-- Health bar and label above the head. Returns a function that takes the new health.
local function addHealthBar(head: Part, humanoid: Humanoid, label: string)
	local gui = Instance.new("BillboardGui")
	gui.Name = "HealthBar"
	gui.Adornee = head
	gui.Size = UDim2.fromScale(4, 1.1) -- scale = studs for a BillboardGui without an offset size
	gui.StudsOffset = Vector3.new(0, 2, 0)
	gui.MaxDistance = 250
	gui.LightInfluence = 0
	gui.Parent = head

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 0.5)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextStrokeTransparency = 0.4
	text.Text = label
	text.Parent = gui

	local back = Instance.new("Frame")
	back.Position = UDim2.fromScale(0, 0.58)
	back.Size = UDim2.fromScale(1, 0.32)
	back.BackgroundColor3 = Color3.fromRGB(20, 22, 26)
	back.BorderSizePixel = 0
	back.Parent = gui

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.Parent = back

	local function update()
		local fraction = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
		fill.Size = UDim2.fromScale(fraction, 1)
		fill.BackgroundColor3 = Color3.fromRGB(230, 60, 60):Lerp(Color3.fromRGB(80, 220, 110), fraction)
	end
	update()
	humanoid.HealthChanged:Connect(update)
	return gui
end

-- Builds one dummy with its feet on spot.position, facing +Z (towards the firing line).
local function build(spot, strafes: boolean): Model
	local model = Instance.new("Model")
	model.Name = "Dummy"

	local parts = {
		HumanoidRootPart = newPart("HumanoidRootPart", Vector3.new(2, 2, 1), TORSO_COLOR, false),
		Torso = newPart("Torso", Vector3.new(2, 2, 1), TORSO_COLOR, true),
		Head = newPart("Head", Vector3.new(1.2, 1.2, 1.2), HEAD_COLOR, true),
		["Right Arm"] = newPart("Right Arm", Vector3.new(1, 2, 1), LIMB_COLOR, false),
		["Left Arm"] = newPart("Left Arm", Vector3.new(1, 2, 1), LIMB_COLOR, false),
		["Right Leg"] = newPart("Right Leg", Vector3.new(1, 2, 1), LIMB_COLOR, false),
		["Left Leg"] = newPart("Left Leg", Vector3.new(1, 2, 1), LIMB_COLOR, false),
	}
	parts.Head.Shape = Enum.PartType.Ball
	parts.HumanoidRootPart.Transparency = 1
	parts.HumanoidRootPart.CanQuery = false -- it overlaps the torso: bullets should hit what you see
	parts.HumanoidRootPart.CanTouch = false

	-- Pose: the root faces the shooters (+Z), every other part follows from the joint table.
	local root = parts.HumanoidRootPart
	root.CFrame = CFrame.new(spot.position + Vector3.new(0, ROOT_HEIGHT, 0)) * CFrame.Angles(0, math.pi, 0)
	for _, joint in R6 do
		local name, part0, part1, c0, c1 = table.unpack(joint)
		local motor = Instance.new("Motor6D")
		motor.Name = name
		motor.Part0 = parts[part0]
		motor.Part1 = parts[part1]
		motor.C0 = c0
		motor.C1 = c1
		parts[part1].CFrame = parts[part0].CFrame * c0 * c1:Inverse()
		motor.Parent = parts[part0]
	end
	for _, part in parts do
		part.Parent = model
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.MaxHealth = Config.DUMMY_HEALTH
	humanoid.Health = Config.DUMMY_HEALTH
	humanoid.WalkSpeed = if strafes then 8 else 0
	humanoid.BreakJointsOnDeath = false -- we topple it ourselves
	humanoid.RequiresNeck = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.Parent = model

	model.PrimaryPart = root
	root.Anchored = not strafes -- the strafer must be free to walk; the rest stand rock still

	addBullseye(parts.Torso)
	addHealthBar(parts.Head, humanoid, spot.label)
	CollectionService:AddTag(model, Config.TARGET_TAG)
	return model
end

-- White flash when hit: one Highlight per dummy, switched on for a moment.
local function addHitFlash(model: Model, humanoid: Humanoid)
	local highlight = Instance.new("Highlight")
	highlight.Name = "HitFlash"
	highlight.Adornee = model
	highlight.FillColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.35
	highlight.OutlineTransparency = 1
	highlight.Enabled = false
	highlight.Parent = model

	local lastHealth = humanoid.Health
	local token = 0
	humanoid.HealthChanged:Connect(function(health)
		if health < lastHealth and health > 0 then
			token += 1
			local mine = token
			highlight.Enabled = true
			task.delay(0.07, function()
				if token == mine then
					highlight.Enabled = false
				end
			end)
		end
		lastHealth = health
	end)
end

-- Walks the dummy between two points beside its spot until it dies.
local function strafeLoop(model: Model, humanoid: Humanoid, spot)
	local root = model.PrimaryPart
	local goRight = true
	while model.Parent and humanoid.Health > 0 do
		local targetX = spot.position.X + (if goRight then spot.strafe else -spot.strafe)
		humanoid:MoveTo(Vector3.new(targetX, spot.position.Y, spot.position.Z))
		-- Poll instead of waiting on MoveToFinished: that event never fires if the model is
		-- destroyed mid-walk, and this loop must end cleanly. MoveTo itself gives up after 8 s.
		local started = os.clock()
		while
			model.Parent
			and humanoid.Health > 0
			and math.abs(root.Position.X - targetX) > 0.7
			and os.clock() - started < 7
		do
			task.wait(0.1)
		end
		task.wait(0.4) -- a short stop at each end, so it is a fair target
		goRight = not goRight
	end
end

-- Death: stop being hittable, fall over backwards, fade out.
local function onDied(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanQuery = false
			d.CanCollide = false
		end
	end
	local bar = model:FindFirstChild("HealthBar", true)
	if bar then
		bar.Enabled = false
	end

	local root = model.PrimaryPart
	root.Anchored = true -- hold it still for the tween (the strafer was free until now)
	local feet = root.CFrame * CFrame.new(0, -ROOT_HEIGHT, 0)
	local lying = CFrame.new(0, 0.5, 0) * feet * CFrame.Angles(math.pi / 2, 0, 0) * CFrame.new(0, ROOT_HEIGHT, 0)
	TweenService:Create(root, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = lying })
		:Play()

	task.delay(Config.DUMMY_RESPAWN_SECONDS - 0.5, function()
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d.Transparency < 1 then
				TweenService:Create(d, TweenInfo.new(0.4), { Transparency = 1 }):Play()
			elseif d:IsA("SurfaceGui") then
				d.Enabled = false -- the bullseye would otherwise float on the faded torso
			end
		end
	end)
end

local function spawnDummy(spot)
	local strafes = spot.strafe ~= nil
	local model = build(spot, strafes)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	addHitFlash(model, humanoid)
	model.Parent = Workspace:FindFirstChild("Dummies") or Workspace

	if strafes then
		model.PrimaryPart:SetNetworkOwner(nil) -- keep the physics on the server so hits match what everyone sees
		task.spawn(strafeLoop, model, humanoid, spot)
	end

	humanoid.Died:Once(function()
		onDied(model)
		task.delay(Config.DUMMY_RESPAWN_SECONDS, function()
			model:Destroy()
			spawnDummy(spot)
		end)
	end)
end

function Dummies.init(spots)
	local folder = Workspace:FindFirstChild("Dummies") or Instance.new("Folder")
	folder.Name = "Dummies"
	folder.Parent = Workspace
	for _, spot in spots do
		spawnDummy(spot)
	end
	print("[WeaponKit] Dummies ready (" .. #spots .. ")")
end

return Dummies
