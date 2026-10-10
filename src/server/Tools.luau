--!nonstrict
-- Builds the weapon Tools from plain Parts (no meshes, no asset ids) and hands them out.
-- Every spawn gets one Tool per entry in Weapons.luau, and the weapon the player held last
-- (saved as `loadout`) is equipped straight away.
--
-- Model layout, in the Handle's space: the barrel points along -Z (the Handle's LookVector),
-- up is +Y. A Tool is held by its Handle, so the Handle is the grip. Each weapon is a short list
-- of boxes (BUILDS below); the accent boxes take the weapon's `color`. The barrel carries an
-- Attachment called "Muzzle" at its tip: the client fires tracers from there.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Weapons = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Weapons"))
local PlayerData = require(script.Parent.PlayerData)

local Tools = {}

local DARK = Color3.fromRGB(38, 40, 46)
local STEEL = Color3.fromRGB(78, 82, 92)

-- One box of a weapon: name, size, offset from the Handle's centre, colour ("accent" = the
-- weapon's own colour), material.
type Box = { name: string, size: Vector3, offset: Vector3, color: any, material: Enum.Material? }

-- Handle (the grip) is built separately; these sit on top of / around it.
local BUILDS: { [string]: { grip: Vector3, boxes: { Box }, muzzle: Vector3 } } = {
	Pistol = {
		grip = Vector3.new(0.35, 1, 0.5),
		boxes = {
			{
				name = "Body",
				size = Vector3.new(0.4, 0.45, 1.8),
				offset = Vector3.new(0, 0.7, -0.55),
				color = "accent",
			},
			{
				name = "Barrel",
				size = Vector3.new(0.2, 0.2, 0.5),
				offset = Vector3.new(0, 0.7, -1.7),
				color = STEEL,
				material = Enum.Material.Metal,
			},
			{
				name = "Magazine",
				size = Vector3.new(0.3, 0.25, 0.45),
				offset = Vector3.new(0, -0.6, 0.02),
				color = STEEL,
			},
			{ name = "Sight", size = Vector3.new(0.12, 0.12, 0.2), offset = Vector3.new(0, 1.0, -1.3), color = DARK },
		},
		muzzle = Vector3.new(0, 0.7, -1.95),
	},
	Rifle = {
		grip = Vector3.new(0.4, 0.9, 0.5),
		boxes = {
			{ name = "Body", size = Vector3.new(0.5, 0.55, 2.4), offset = Vector3.new(0, 0.78, -0.7), color = DARK },
			{ name = "Stock", size = Vector3.new(0.45, 0.7, 1.5), offset = Vector3.new(0, 0.5, 1.25), color = DARK },
			{
				name = "Barrel",
				size = Vector3.new(0.22, 0.22, 1.8),
				offset = Vector3.new(0, 0.85, -2.8),
				color = STEEL,
				material = Enum.Material.Metal,
			},
			{ name = "Magazine", size = Vector3.new(0.35, 1, 0.5), offset = Vector3.new(0, 0, -0.9), color = "accent" },
			{
				name = "Sight",
				size = Vector3.new(0.15, 0.2, 0.5),
				offset = Vector3.new(0, 1.16, -0.4),
				color = "accent",
			},
		},
		muzzle = Vector3.new(0, 0.85, -3.7),
	},
	Shotgun = {
		grip = Vector3.new(0.4, 0.9, 0.5),
		boxes = {
			{ name = "Body", size = Vector3.new(0.5, 0.55, 1.6), offset = Vector3.new(0, 0.78, -0.3), color = DARK },
			{ name = "Stock", size = Vector3.new(0.45, 0.65, 1.6), offset = Vector3.new(0, 0.55, 1.3), color = DARK },
			{
				name = "Barrel",
				size = Vector3.new(0.3, 0.3, 2.6),
				offset = Vector3.new(0, 0.82, -2.4),
				color = STEEL,
				material = Enum.Material.Metal,
			},
			{
				name = "Magazine",
				size = Vector3.new(0.25, 0.25, 2.4),
				offset = Vector3.new(0, 0.5, -2.45),
				color = STEEL,
			},
			{ name = "Pump", size = Vector3.new(0.5, 0.4, 1), offset = Vector3.new(0, 0.5, -2.2), color = "accent" },
		},
		muzzle = Vector3.new(0, 0.82, -3.7),
	},
}

local function weld(handle: BasePart, part: BasePart, offset: Vector3)
	part.CFrame = handle.CFrame * CFrame.new(offset)
	local w = Instance.new("Weld")
	w.Part0 = handle
	w.Part1 = part
	w.C0 = CFrame.new(offset) -- relative to the Handle; C1 stays identity
	w.Parent = part
end

local function newPart(name: string, size: Vector3, color: Color3, material: Enum.Material?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.CanCollide = false
	part.CanQuery = false -- a held gun must never block a bullet
	part.CanTouch = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function build(name: string): Tool?
	local def = Weapons.Defs[name]
	local spec = BUILDS[name]
	if not spec then
		-- A weapon was added to Weapons.luau without a model: give it a plain slab so it still works.
		spec = {
			grip = Vector3.new(0.4, 0.9, 0.5),
			boxes = {
				{
					name = "Body",
					size = Vector3.new(0.5, 0.5, 2),
					offset = Vector3.new(0, 0.7, -0.6),
					color = "accent",
				},
			},
			muzzle = Vector3.new(0, 0.7, -1.6),
		}
	end

	local tool = Instance.new("Tool")
	tool.Name = name
	tool.ToolTip = def.name
	tool.CanBeDropped = false
	tool.RequiresHandle = true

	local handle = newPart("Handle", spec.grip, DARK)
	handle.CFrame = CFrame.new(0, 10, 0) -- (any place; parts are positioned relative to it)
	handle.Parent = tool

	local barrel: BasePart? = nil
	for _, box in spec.boxes do
		local color = if box.color == "accent" then def.color else box.color
		local part = newPart(box.name, box.size, color, box.material)
		weld(handle, part, box.offset)
		part.Parent = tool
		if box.name == "Barrel" then
			barrel = part
		end
	end

	-- The muzzle Attachment sits on the barrel (or the Handle if the build has none).
	local holder = barrel or handle
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.CFrame = holder.CFrame:ToObjectSpace(handle.CFrame * CFrame.new(spec.muzzle))
	muzzle.Parent = holder
	return tool
end

-- Replaces whatever weapon Tools the player has (none, normally: Backpack is cleared on respawn)
-- with a fresh set, then equips the saved loadout.
local function giveTools(player: Player, character: Model)
	local data = PlayerData.waitFor(player, 60)
	if not data or player.Character ~= character then
		return -- left, or already respawned: the next CharacterAdded handles it
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local backpack = player:WaitForChild("Backpack", 10)
	if not humanoid or humanoid.Health <= 0 or not backpack then
		return
	end
	-- A Tool is held by the hand: on a fresh spawn the arm may not exist yet (R6 "Right Arm",
	-- R15 "RightHand"), and equipping before it does fails. Wait a moment for it.
	local waited = 0
	while not (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")) and waited < 5 do
		waited += task.wait(0.1)
	end
	if player.Character ~= character or humanoid.Health <= 0 then
		return
	end

	for _, name in Weapons.Order do
		if not backpack:FindFirstChild(name) and not character:FindFirstChild(name) then
			local tool = build(name)
			if tool then
				tool.Parent = backpack
			end
		end
	end

	local loadout = backpack:FindFirstChild(data.loadout)
	if loadout then
		humanoid:EquipTool(loadout)
	end
end

function Tools.init()
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			task.spawn(giveTools, player, character)
		end)
		if player.Character then
			task.spawn(giveTools, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	print("[WeaponKit] Tools ready (" .. #Weapons.Order .. " weapons)")
end

return Tools
