--!nonstrict
-- The shooting range, built from Parts at server start (nothing is stored in the .rbxl):
-- five 12-stud lanes that run away from a firing line, with distance markers at 10 / 25 / 50 /
-- 100 studs on every lane, a few cover walls, a backstop, the spawn pad, simple daylight and the
-- ammo crate. Range.TARGETS says where the dummies go (Dummies.init reads it).
--
-- The ammo crate is where the "server is in charge" rule shows for pickups too: the prompt's
-- reach is checked here on the server (the client-side distance is only a UI hint; a trigger
-- from too far away is counted as a "crate" flag), there is a cooldown per player, and the
-- refill itself is WeaponServer.restock, which only server code can call.
--
-- Demo only (Config.DEMO_CHEAT_PANEL): a "lab corner" east of the lanes, away from the shooting
-- line, with the fixtures of the exploit lab: a 4-stud wall with a dummy behind it (wallbang), a
-- thin wall to walk through (noclip) and a tall truss tower (a legal climb, the control test for
-- the fly check). Range.LAB_TARGETS lists the lab's dummy for Dummies.init.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Suspicion = require(script.Parent.Suspicion)
local WeaponServer = require(script.Parent.WeaponServer)

local Range = {}

local LANE_WIDTH = 12
local LANE_LENGTH = 108 -- from the firing line (z = 0) away from it, towards -Z
local LANE_TOP = 0.2 -- height of the lane slabs above the ground (dummy feet go here)
local MARKERS = { 10, 25, 50, 100 } -- studs from the firing line

-- One entry per lane, left to right. The dummy stands `distance` studs from the firing line;
-- `strafe` (half-width in studs) makes it walk left and right.
Range.TARGETS = {
	{ label = "10 STUDS", position = Vector3.new(-32, LANE_TOP, -10) },
	{ label = "25 STUDS", position = Vector3.new(-16, LANE_TOP, -25) },
	{ label = "MOVING", position = Vector3.new(0, LANE_TOP, -35), strafe = 4 },
	{ label = "50 STUDS", position = Vector3.new(16, LANE_TOP, -50) },
	{ label = "100 STUDS", position = Vector3.new(32, LANE_TOP, -100) },
}

-- The lab corner is centred here. Its dummy (the one behind the wall) is added by buildLab,
-- and only while the demo is on, so a production build gets no lab.
local LAB_CENTER = Vector3.new(100, 0, 0)
Range.LAB_TARGETS = {}

local function block(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?,
	solid: boolean?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if solid == false then
		-- Decoration: bullets and players pass through it.
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end
	part.Parent = parent
	return part
end

-- Text on one face of a part (SurfaceGui). Returns the TextLabel.
local function labelOn(part: Part, face: Enum.NormalId, text: string, color: Color3?): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = color or Color3.new(1, 1, 1)
	label.Text = text
	label.Parent = gui
	return label
end

-- A sign on a post, facing +Z (the firing line looks towards -Z, so it reads the Back face).
local function signPost(parent: Instance, text: string, position: Vector3, width: number)
	local height = 3 + width * 0.3
	block(
		parent,
		"Post",
		Vector3.new(0.3, height, 0.3),
		CFrame.new(position + Vector3.new(0, height / 2, 0)),
		Color3.fromRGB(60, 64, 72),
		nil,
		false
	)
	local board = block(
		parent,
		"Sign",
		Vector3.new(width, width * 0.5, 0.3),
		CFrame.new(position + Vector3.new(0, height, 0)),
		Color3.fromRGB(28, 32, 40),
		nil,
		false
	)
	labelOn(board, Enum.NormalId.Back, text, Color3.fromRGB(255, 220, 120))
end

local function setupLighting()
	Lighting.ClockTime = 14
	Lighting.GeographicLatitude = 30
	Lighting.Brightness = 2.2
	Lighting.Ambient = Color3.fromRGB(110, 115, 125)
	Lighting.OutdoorAmbient = Color3.fromRGB(135, 140, 150)
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.3
	Lighting.EnvironmentDiffuseScale = 0.5
	Lighting.EnvironmentSpecularScale = 0.3
	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Density = 0.22
		atmosphere.Offset = 0.1
		atmosphere.Color = Color3.fromRGB(199, 210, 225)
		atmosphere.Decay = Color3.fromRGB(150, 160, 175)
		atmosphere.Glare = 0
		atmosphere.Haze = 0.4
		atmosphere.Parent = Lighting
	end
end

local function buildLanes(folder: Folder)
	local slab = Color3.fromRGB(112, 118, 110)
	local paint = Color3.fromRGB(235, 235, 225)

	-- Firing line across all lanes.
	block(folder, "FiringLine", Vector3.new(84, 0.24, 0.5), CFrame.new(0, 0.12, 0), paint, nil, false)

	for index, target in Range.TARGETS do
		local x = target.position.X
		block(
			folder,
			"Lane" .. index,
			Vector3.new(LANE_WIDTH, LANE_TOP, LANE_LENGTH),
			CFrame.new(x, LANE_TOP / 2, -LANE_LENGTH / 2),
			slab,
			Enum.Material.Concrete
		)

		-- Lane sign just behind the firing line, then a stripe + sign at every marker distance.
		signPost(folder, "LANE " .. index, Vector3.new(x - LANE_WIDTH / 2 + 1.5, 0, 3), 4)
		for _, distance in MARKERS do
			block(
				folder,
				"Stripe" .. distance,
				Vector3.new(LANE_WIDTH, 0.04, 0.3),
				CFrame.new(x, LANE_TOP + 0.02, -distance),
				paint,
				nil,
				false
			)
			signPost(
				folder,
				tostring(distance),
				Vector3.new(x - LANE_WIDTH / 2 + 1, LANE_TOP, -distance),
				2.5 + distance * 0.03
			)
		end
	end

	-- Backstop: catches everything that flies past the last dummy.
	block(
		folder,
		"Backstop",
		Vector3.new(96, 14, 2),
		CFrame.new(0, 7, -LANE_LENGTH - 4),
		Color3.fromRGB(70, 74, 80),
		Enum.Material.Concrete
	)
end

local function buildCover(folder: Folder)
	local color = Color3.fromRGB(122, 128, 138)
	-- Waist-high walls behind the firing line: shoot over them, or hide a fake muzzle behind them
	-- (the cheat panel's "Fake origin" test) and watch the server ignore it.
	for _, x in { -32, 0, 32 } do
		block(folder, "Cover", Vector3.new(8, 3.5, 1), CFrame.new(x, 1.75, 8), color, Enum.Material.Concrete)
	end
	-- Two more in the gaps between lanes, out on the range.
	for _, x in { -8, 8 } do
		block(folder, "Cover", Vector3.new(3.6, 4.5, 1), CFrame.new(x, 2.25, -18), color, Enum.Material.Concrete)
	end
end

local function buildSpawn(folder: Folder)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Size = Vector3.new(14, 0.4, 14)
	spawn.CFrame = CFrame.new(0, 0.2, 26)
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0 -- no spawn forcefield bubble in the video
	spawn.Color = Color3.fromRGB(60, 120, 120)
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = folder

	-- Title banner over the firing line.
	local banner =
		block(folder, "Banner", Vector3.new(40, 6, 0.5), CFrame.new(0, 14, 4), Color3.fromRGB(24, 28, 36), nil, false)
	labelOn(banner, Enum.NormalId.Back, "WEAPON KIT  -  server-validated guns", Color3.fromRGB(255, 220, 120))
	for _, x in { -18, 18 } do
		block(
			folder,
			"BannerPost",
			Vector3.new(0.6, 14, 0.6),
			CFrame.new(x, 7, 4),
			Color3.fromRGB(60, 64, 72),
			nil,
			false
		)
	end
end

-- The ammo crate: touch-free, E to restock, validated on the server.
local function buildCrate(folder: Folder)
	local crate = Instance.new("Model")
	crate.Name = "AmmoCrate"
	local base = block(
		crate,
		"Base",
		Vector3.new(4, 2.4, 2.8),
		CFrame.new(13, 1.2, 17) * CFrame.Angles(0, math.rad(-25), 0),
		Color3.fromRGB(70, 88, 58),
		Enum.Material.Metal
	)
	for _, offset in { -1.2, 1.2 } do
		block(
			crate,
			"Band",
			Vector3.new(0.4, 2.5, 2.9),
			base.CFrame * CFrame.new(offset, 0, 0),
			Color3.fromRGB(235, 190, 50)
		)
	end
	labelOn(base, Enum.NormalId.Back, "AMMO", Color3.fromRGB(235, 190, 50)) -- Back = towards the spawn
	labelOn(base, Enum.NormalId.Front, "AMMO", Color3.fromRGB(235, 190, 50))
	crate.PrimaryPart = base
	crate.Parent = folder

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Restock ammo"
	prompt.ObjectText = "Ammo crate"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = base

	local lastUse = {} -- [Player] = os.clock() of their last restock
	prompt.Triggered:Connect(function(player)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid or humanoid.Health <= 0 then
			return
		end
		-- The prompt only appears when you are near, but that is the client's opinion: check the
		-- distance here too (a little slack for lag).
		if (root.Position - base.Position).Magnitude > prompt.MaxActivationDistance + 8 then
			Suspicion.report(player, "crate", "crate prompt triggered from too far away")
			return
		end
		local now = os.clock()
		if now - (lastUse[player] or -math.huge) < Config.CRATE_COOLDOWN then
			return
		end
		lastUse[player] = now
		WeaponServer.restock(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastUse[player] = nil
	end)
end

-- Demo only: the exploit lab's fixtures (see the header). Everything is anchored; the walls and
-- the tower are solid, the signs are decoration. The panel finds them by name under Range.Lab.
local function buildLab(folder: Folder)
	local lab = Instance.new("Folder")
	lab.Name = "Lab"
	lab.Parent = folder
	local concrete = Color3.fromRGB(122, 128, 138)
	local x, z = LAB_CENTER.X, LAB_CENTER.Z

	block(
		lab,
		"Pad",
		Vector3.new(64, LANE_TOP, 56),
		CFrame.new(x, LANE_TOP / 2, z),
		Color3.fromRGB(112, 118, 110),
		Enum.Material.Concrete
	)
	signPost(lab, "EXPLOIT LAB", Vector3.new(x - 28, LANE_TOP, z + 24), 6)

	-- Wallbang: stand in front of the 4-stud wall; the dummy is on the other side.
	local wallZ = z - 4
	block(
		lab,
		"WallbangWall",
		Vector3.new(14, 9, 4),
		CFrame.new(x - 14, LANE_TOP + 4.5, wallZ),
		concrete,
		Enum.Material.Concrete
	)
	signPost(lab, "WALLBANG WALL", Vector3.new(x - 21, LANE_TOP, z + 8), 5)
	local dummySpot = Vector3.new(x - 14, LANE_TOP, wallZ - 8)
	lab:SetAttribute("DummySpot", dummySpot) -- the panel aims at the dummy standing here
	table.insert(Range.LAB_TARGETS, { label = "BEHIND WALL", position = dummySpot })

	-- Noclip: a thin wall to stand next to and (as a cheater) walk through.
	block(
		lab,
		"NoclipWall",
		Vector3.new(14, 8, 2),
		CFrame.new(x + 12, LANE_TOP + 4, z + 8),
		concrete,
		Enum.Material.Concrete
	)
	signPost(lab, "NOCLIP WALL", Vector3.new(x + 4, LANE_TOP, z + 14), 5)

	-- Climb: a legal truss climb, then a platform to step off and fall from. The fly check must
	-- NOT flag any of it (control test).
	local trussHeight = 38
	local truss = Instance.new("TrussPart")
	truss.Name = "ClimbTruss"
	truss.Size = Vector3.new(2, trussHeight, 2)
	truss.CFrame = CFrame.new(x + 22, LANE_TOP + trussHeight / 2, z + 10)
	truss.Anchored = true
	truss.Parent = lab
	block(
		lab,
		"TowerTop",
		Vector3.new(12, 1, 12),
		CFrame.new(x + 29, LANE_TOP + trussHeight - 0.5, z + 10),
		concrete,
		Enum.Material.Concrete
	)
	signPost(lab, "CLIMB TEST (legal)", Vector3.new(x + 18, LANE_TOP, z + 16), 6)
end

function Range.build()
	setupLighting()

	-- Studio's "Baseplate" template ships its own floor and spawn: remove them so they don't
	-- z-fight with the range or pull players away from our spawn pad.
	for _, name in { "Baseplate", "SpawnLocation" } do
		local leftover = Workspace:FindFirstChild(name)
		if leftover then
			leftover:Destroy()
		end
	end

	local folder = Workspace:FindFirstChild("Range") or Instance.new("Folder")
	folder.Name = "Range"
	folder.Parent = Workspace

	block(
		folder,
		"Ground",
		Vector3.new(300, 2, 360),
		CFrame.new(0, -1, -70),
		Color3.fromRGB(78, 88, 76),
		Enum.Material.Concrete
	)
	buildLanes(folder)
	buildCover(folder)
	buildSpawn(folder)
	buildCrate(folder)
	if Config.DEMO_CHEAT_PANEL then
		buildLab(folder)
	end
	print("[WeaponKit] Range ready")
end

return Range
