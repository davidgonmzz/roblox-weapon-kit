--!nonstrict
-- Builds the weapon Tools from plain Parts (no meshes, no asset ids) and hands them out.
-- Every spawn gets one Tool per entry in Weapons.luau, and the weapon the player held last
-- (saved as `loadout`) is equipped straight away.
--
-- Model layout, in the Handle's space: the barrel points along -Z (the Handle's LookVector),
-- up is +Y. A Tool is held by its Handle, so the Handle is the grip. Each weapon is a short list
-- of boxes (BUILDS below); the accent boxes take the weapon's `color`. The barrel carries an
-- Attachment called "Muzzle" at its tip: the client fires tracers from there.
--
-- YOUR OWN MODELS: put a Folder "WeaponKitModels" in ServerStorage with a child named like the
-- weapon (the key in Weapons.luau, e.g. "Rifle"). It can be
--   * a Tool with a Handle: used as it is (its Grip too);
--   * a Model or a Part: held at its pivot, the barrel pointing along the pivot's front (LookVector).
-- The barrel tip is an Attachment named "Muzzle" (or "TipAttachment", as in Roblox's own weapons
-- kit); without one the front-most point is used and you get one warning. An Attachment named
-- "LeftGrip" marks where the left hand holds it (client/Pose.luau; without one it is placed between the
-- grip and the muzzle). Every part is made
-- unanchored, non-colliding, unqueryable and massless and welded to the Handle, and scripts inside
-- are removed (the kit does the shooting). Weapons without a model keep the built-in boxes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Weapons = require(ReplicatedStorage:WaitForChild("WeaponKitShared"):WaitForChild("Weapons"))
local PlayerData = require(script.Parent.PlayerData)

local Tools = {}

local DARK = Color3.fromRGB(38, 40, 46)
local STEEL = Color3.fromRGB(78, 82, 92)
local MODELS_FOLDER = "WeaponKitModels"
-- The server accepts a shot's start up to 8 studs from the head (WeaponServer ORIGIN_SLACK, more
-- ahead of a moving shooter); the grip is ~2.6 studs from the head (R15, more on a tall avatar).
-- A muzzle further than this from the grip gets a warning.
local MUZZLE_REACH_WARN = 4.5
-- The built-in boxes are drawn at this scale: real-gun proportions next to a standard R15 avatar, so
-- both hands reach the gun and the stock stops at the shoulder instead of going through the chest
-- (client/Pose.luau; Studio-measured clipping).
local BUILT_IN_SCALE = 0.7

local warned = {} -- [message] = true: each model problem is reported once per server

local function warnOnce(message: string)
	if not warned[message] then
		warned[message] = true
		warn("[WeaponKit] " .. message)
	end
end

-- One box of a weapon: name, size, offset from the Handle's centre, colour ("accent" = the
-- weapon's own colour), material.
type Box = { name: string, size: Vector3, offset: Vector3, color: any, material: Enum.Material? }

-- Handle (the grip) is built separately; these sit on top of / around it.
-- leftGrip: where the left hand holds the gun (client/Pose.luau), in the Handle's space.
local BUILDS: { [string]: { grip: Vector3, boxes: { Box }, muzzle: Vector3, leftGrip: Vector3? } } = {
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
		leftGrip = Vector3.new(-0.3, -0.25, 0), -- cupping the right hand
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
		leftGrip = Vector3.new(0, 0.35, -1.6), -- under the front of the body
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
		leftGrip = Vector3.new(0, 0.25, -2.1), -- on the pump
	},
}

local function weld(handle: BasePart, part: BasePart, offset: Vector3)
	offset *= BUILT_IN_SCALE
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

local function findAttachment(root: Instance, name: string): Attachment?
	for _, item in root:GetDescendants() do
		if item.Name == name and item:IsA("Attachment") and item.Parent and item.Parent:IsA("BasePart") then
			return item
		end
	end
	return nil
end

-- The point of the model furthest along the Handle's front (-Z), on the part that reaches it.
local function frontMost(handle: BasePart, root: Instance): (BasePart, Vector3)
	local look = handle.CFrame.LookVector
	local best, bestPart, bestPoint = -math.huge, handle, handle.Position
	for _, part in root:GetDescendants() do
		if part:IsA("BasePart") then
			local cf, size = part.CFrame, part.Size
			local reach = math.abs(look:Dot(cf.RightVector)) * size.X / 2
				+ math.abs(look:Dot(cf.UpVector)) * size.Y / 2
				+ math.abs(look:Dot(cf.LookVector)) * size.Z / 2
			local front = (part.Position - handle.Position):Dot(look) + reach
			if front > best then
				best, bestPart, bestPoint = front, part, part.Position + look * reach
			end
		end
	end
	return bestPart, bestPoint
end

local function ensureMuzzle(tool: Tool, handle: BasePart, label: string)
	local muzzle = findAttachment(tool, "Muzzle")
	if not muzzle then
		local tip = findAttachment(tool, "TipAttachment")
		local holder, point
		if tip then
			holder, point = tip.Parent, tip.WorldPosition
		else
			holder, point = frontMost(handle, tool)
			warnOnce(
				label
					.. " has no Attachment named Muzzle: tracers start at its front-most point. Add one at the barrel tip."
			)
		end
		muzzle = Instance.new("Attachment")
		muzzle.Name = "Muzzle"
		muzzle.Parent = holder
		muzzle.WorldPosition = point
	end
	local reach = (muzzle.WorldPosition - handle.Position).Magnitude
	if reach > MUZZLE_REACH_WARN then
		warnOnce(
			string.format(
				"%s: the Muzzle is %.1f studs from the grip. The server takes a shot's start up to 8 studs from the head (the grip is ~2.6 from it); shots from further out start at the head (and past 16 studs are flagged 'origin'). Move the Muzzle (or the grip) closer.",
				label,
				reach
			)
		)
	end
end

-- A copy of the developer's model as a ready Tool, or nil (with a warning) if it can't be used.
local function buildCustom(name: string, source: Instance): Tool?
	local label = MODELS_FOLDER .. "." .. name
	local copy = source:Clone()
	if not copy then
		warnOnce(label .. " can't be copied (Archivable is off): using the built-in model.")
		return nil
	end

	local removed = 0
	for _, item in copy:GetDescendants() do
		if item:IsA("LuaSourceContainer") then
			removed += 1
			item:Destroy()
		end
	end
	if removed > 0 then
		warnOnce(string.format("%s: removed %d script(s) inside it (the kit does the shooting).", label, removed))
	end

	local tool, handle
	if copy:IsA("Tool") then
		tool, handle = copy, copy:FindFirstChild("Handle")
		if not (handle and handle:IsA("BasePart")) then
			warnOnce(label .. " is a Tool without a part named Handle: using the built-in model.")
			copy:Destroy()
			return nil
		end
	elseif copy:IsA("Model") or copy:IsA("BasePart") then
		tool = Instance.new("Tool")
		handle = newPart("Handle", Vector3.new(0.2, 0.2, 0.2), DARK)
		handle.Transparency = 1
		handle.CFrame = copy:GetPivot() -- the grip; its front is the barrel's direction
		handle.Parent = tool
		copy.Parent = tool
	else
		warnOnce(label .. " must be a Tool, a Model or a Part: using the built-in model.")
		copy:Destroy()
		return nil
	end

	tool.Name = name
	if tool.ToolTip == "" then
		tool.ToolTip = Weapons.Defs[name].name
	end
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	for _, part in tool:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = false -- a held gun must never block a bullet
			part.CanTouch = false
			part.Massless = true
			if part ~= handle then
				local weldTo = Instance.new("WeldConstraint")
				weldTo.Part0 = handle
				weldTo.Part1 = part
				weldTo.Parent = part
			end
		end
	end
	ensureMuzzle(tool, handle, label)
	return tool
end

local function build(name: string): Tool?
	local folder = ServerStorage:FindFirstChild(MODELS_FOLDER)
	local source = folder and folder:FindFirstChild(name)
	if source then
		local tool = buildCustom(name, source)
		if tool then
			return tool
		end
	end

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

	local handle = newPart("Handle", spec.grip * BUILT_IN_SCALE, DARK)
	handle.CFrame = CFrame.new(0, 10, 0) -- (any place; parts are positioned relative to it)
	handle.Parent = tool

	local barrel: BasePart? = nil
	for _, box in spec.boxes do
		local color = if box.color == "accent" then def.color else box.color
		local part = newPart(box.name, box.size * BUILT_IN_SCALE, color, box.material)
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
	muzzle.CFrame = holder.CFrame:ToObjectSpace(handle.CFrame * CFrame.new(spec.muzzle * BUILT_IN_SCALE))
	muzzle.Parent = holder
	if spec.leftGrip then
		local left = Instance.new("Attachment")
		left.Name = "LeftGrip"
		left.Position = spec.leftGrip * BUILT_IN_SCALE
		left.Parent = handle
	end
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

	-- A model whose name matches no weapon is never used: say so (a typo, most likely).
	local folder = ServerStorage:FindFirstChild(MODELS_FOLDER)
	local custom = 0
	if folder then
		for _, child in folder:GetChildren() do
			if Weapons.Defs[child.Name] then
				custom += 1
			else
				warnOnce(
					string.format(
						"%s.%s matches no weapon in Weapons.luau (names: %s), so it is not used.",
						MODELS_FOLDER,
						child.Name,
						table.concat(Weapons.Order, ", ")
					)
				)
			end
		end
	end
	print(string.format("[WeaponKit] Tools ready (%d weapons, %d own models)", #Weapons.Order, custom))
end

return Tools
