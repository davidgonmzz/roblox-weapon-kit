--!nonstrict
-- The on-screen HUD: crosshair (follows the mouse, blooms when you shoot), hit marker and damage
-- number, ammo panel, weapon bar (1 / 2 / 3), stats and a key hint. It only DRAWS what
-- WeaponClient tells it; it never decides anything. Config.HUD = false hides all of it.
-- The layout follows the device in use (UserInputService.PreferredInput): on a phone the ammo panel
-- and weapon bar move to the top (clear of the thumbstick and jump button) and a RELOAD button
-- appears; on a gamepad the hint shows pad buttons. Slots are buttons, so tapping one switches.
--
--   Hud.start(actions)               -> actions = { toggle = fn(weaponName), reload = fn() }
--   Hud.aimPoint()                   -> Vector2 screen position the crosshair is at
--   Hud.setWeapon(def | nil)         -> show / hide the crosshair and ammo panel for a weapon
--   Hud.setAmmo(mag, reserve)        -> "15 / 60" (reserve nil = not known yet)
--   Hud.setReload(startClock | nil)  -> progress bar while reloading
--   Hud.bloom()                      -> crosshair kicks open for a moment
--   Hud.showCursor(bool)             -> a menu is open: real cursor instead of the crosshair
--   Hud.hitMarker(damage, headshot, killed)
--   Hud.selectSlot(name | nil)       -> highlights a slot in the weapon bar

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("WeaponKitShared")
local Config = require(Shared:WaitForChild("Config"))
local Weapons = require(Shared:WaitForChild("Weapons"))

local Hud = {}

local INK = Color3.fromRGB(240, 242, 245)
local DIM = Color3.fromRGB(150, 158, 170)
local PANEL = Color3.fromRGB(16, 18, 22)
local DANGER = Color3.fromRGB(255, 96, 84)
local GOLD = Color3.fromRGB(255, 206, 80)
local FONT = Enum.Font.GothamBold
local FONT_LIGHT = Enum.Font.GothamMedium

local CROSS_GAP = 7 -- pixels between the centre and the crosshair lines
local BLOOM_DECAY = 60 -- pixels per second the bloom closes again
local TOUCH_SCALE = 0.75 -- ammo panel and weapon bar size on a phone

-- Per device: the key hint along the bottom and the empty-magazine prompt.
local HINTS = {
	keyboard = "LMB fire    R reload    1 2 3 switch",
	gamepad = "R2 fire    X reload    L1 R1 switch",
	touch = "", -- the buttons speak for themselves
}
local RELOAD_PROMPTS = { keyboard = "PRESS R", gamepad = "PRESS X", touch = "TAP RELOAD" }

local gui
local crosshair, hitFrame, hitTicks
local ammoPanel, nameLabel, ammoLabel, reloadBar, reloadFill, accent
local slots = {} -- [weaponName] = { frame, stroke }
local slotBar, hintLabel, reloadButton
local panelScale, barScale -- UIScales of the ammo panel and the weapon bar
local statsLabel
local actions = {} -- { toggle = fn(name), reload = fn() } from WeaponClient
local inputKind = "keyboard" -- "keyboard", "gamepad" or "touch": the device the player is using
local weapon -- the Weapon def currently shown, or nil
local bloom = 0
local reloadStart -- os.clock() when the current reload began, or nil
local magEmpty, reserveEmpty = false, false -- for the status text next to the weapon name
local cursorForced = false -- a menu (the cheat panel) is open: show the real cursor, hide the crosshair

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function label(props): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = FONT
	l.TextColor3 = INK
	for key, value in props do
		l[key] = value
	end
	return l
end

local function box(props): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	for key, value in props do
		f[key] = value
	end
	return f
end

local function buildCrosshair()
	crosshair = box({
		Name = "Crosshair",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		Visible = false,
	})
	crosshair.Parent = gui
	local function line(name: string, size: Vector2, anchor: Vector2)
		local f =
			box({ Name = name, Size = UDim2.fromOffset(size.X, size.Y), AnchorPoint = anchor, BackgroundColor3 = INK })
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1
		stroke.Transparency = 0.4
		stroke.Parent = f
		f.Parent = crosshair
		return f
	end
	local up = line("Up", Vector2.new(2, 9), Vector2.new(0.5, 1))
	local down = line("Down", Vector2.new(2, 9), Vector2.new(0.5, 0))
	local left = line("Left", Vector2.new(9, 2), Vector2.new(1, 0.5))
	local right = line("Right", Vector2.new(9, 2), Vector2.new(0, 0.5))
	line("Dot", Vector2.new(2, 2), Vector2.new(0.5, 0.5))

	-- The four lines move apart with `bloom`.
	RunService.RenderStepped:Connect(function(dt)
		bloom = math.max(0, bloom - BLOOM_DECAY * dt)
		local gap = CROSS_GAP + bloom
		up.Position = UDim2.fromOffset(0, -gap)
		down.Position = UDim2.fromOffset(0, gap)
		left.Position = UDim2.fromOffset(-gap, 0)
		right.Position = UDim2.fromOffset(gap, 0)
		local at = Hud.aimPoint()
		crosshair.Position = UDim2.fromOffset(at.X, at.Y)
	end)

	-- Hit marker: four short diagonal ticks around the centre, hidden until a hit is confirmed.
	hitFrame = box({ Name = "HitMarker", Size = UDim2.fromOffset(0, 0), BackgroundTransparency = 1 })
	hitFrame.Parent = crosshair
	hitTicks = {}
	for _, spec in { { 1, -1, 45 }, { -1, 1, 45 }, { -1, -1, -45 }, { 1, 1, -45 } } do
		local mark = box({
			Size = UDim2.fromOffset(2, 9),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(spec[1] * 11, spec[2] * 11),
			Rotation = spec[3],
			BackgroundColor3 = INK,
			BackgroundTransparency = 1,
		})
		mark.Parent = hitFrame
		table.insert(hitTicks, mark)
	end
end

local function buildAmmoPanel()
	ammoPanel = box({
		Name = "AmmoPanel",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -24, 1, -24),
		Size = UDim2.fromOffset(230, 92),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.25,
		Visible = false,
	})
	corner(ammoPanel, 8)
	panelScale = Instance.new("UIScale")
	panelScale.Parent = ammoPanel
	ammoPanel.Parent = gui

	accent = box({ Size = UDim2.new(0, 4, 1, -16), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = INK })
	corner(accent, 2)
	accent.Parent = ammoPanel

	nameLabel = label({
		Position = UDim2.fromOffset(22, 8),
		Size = UDim2.new(1, -34, 0, 18),
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = DIM,
	})
	nameLabel.Parent = ammoPanel

	ammoLabel = label({
		Position = UDim2.fromOffset(22, 26),
		Size = UDim2.new(1, -34, 0, 50),
		TextSize = 40,
		TextXAlignment = Enum.TextXAlignment.Left,
		RichText = true,
	})
	ammoLabel.Parent = ammoPanel

	reloadBar = box({
		Position = UDim2.new(0, 22, 1, -14),
		Size = UDim2.new(1, -34, 0, 4),
		BackgroundColor3 = Color3.fromRGB(50, 54, 62),
		Visible = false,
	})
	corner(reloadBar, 2)
	reloadBar.Parent = ammoPanel
	reloadFill = box({ Size = UDim2.fromScale(0, 1), BackgroundColor3 = INK })
	corner(reloadFill, 2)
	reloadFill.Parent = reloadBar

	RunService.RenderStepped:Connect(function()
		if reloadStart and weapon then
			reloadFill.Size = UDim2.fromScale(math.clamp((os.clock() - reloadStart) / weapon.reloadTime, 0, 1), 1)
		end
	end)
end

-- The bar of weapons, built from Weapons.Order (so a new weapon appears by itself). Each slot is a
-- button: click or tap it to take that weapon out or put it away.
local function buildSlots()
	slotBar = box({
		Name = "Slots",
		Size = UDim2.fromOffset(#Weapons.Order * 134, 50),
		BackgroundTransparency = 1,
	})
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = slotBar
	barScale = Instance.new("UIScale")
	barScale.Parent = slotBar
	slotBar.Parent = gui

	for index, name in Weapons.Order do
		local def = Weapons.Defs[name]
		local frame = Instance.new("TextButton")
		frame.Name = name
		frame.Text = ""
		frame.AutoButtonColor = false
		frame.BorderSizePixel = 0
		frame.Size = UDim2.fromOffset(128, 50)
		frame.BackgroundColor3 = PANEL
		frame.BackgroundTransparency = 0.35
		frame.LayoutOrder = index
		frame.Activated:Connect(function()
			if actions.toggle then
				actions.toggle(name)
			end
		end)
		corner(frame, 8)
		local stroke = Instance.new("UIStroke")
		stroke.Color = def.color
		stroke.Thickness = 2
		stroke.Transparency = 1
		stroke.Parent = frame
		local stripe =
			box({ Size = UDim2.new(1, -20, 0, 3), Position = UDim2.new(0, 10, 1, -8), BackgroundColor3 = def.color })
		corner(stripe, 2)
		stripe.Parent = frame
		label({
			Text = tostring(def.slot),
			Position = UDim2.fromOffset(10, 6),
			Size = UDim2.fromOffset(16, 18),
			TextSize = 14,
			TextColor3 = def.color,
		}).Parent =
			frame
		label({
			Text = def.name,
			Position = UDim2.fromOffset(30, 6),
			Size = UDim2.new(1, -38, 0, 18),
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
		}).Parent =
			frame
		frame.Parent = slotBar
		slots[name] = { frame = frame, stroke = stroke }
	end
end

local function buildCorners()
	statsLabel = label({
		Name = "Stats",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 16),
		Size = UDim2.fromOffset(400, 20),
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = INK,
		TextStrokeTransparency = 0.6,
		Text = "",
	})
	statsLabel.Parent = gui

	hintLabel = label({
		Name = "Hint",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -16),
		Size = UDim2.fromOffset(460, 18),
		Font = FONT_LIGHT,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = DIM,
		TextStrokeTransparency = 0.7,
	})
	hintLabel.Parent = gui

	-- Phones only (keyboards have R, pads have X): right edge, above Roblox's jump button.
	reloadButton = Instance.new("TextButton")
	reloadButton.Name = "Reload"
	reloadButton.AnchorPoint = Vector2.new(1, 0.5)
	reloadButton.Position = UDim2.new(1, -24, 0.5, 0)
	reloadButton.Size = UDim2.fromOffset(72, 72)
	reloadButton.BackgroundColor3 = PANEL
	reloadButton.BackgroundTransparency = 0.25
	reloadButton.BorderSizePixel = 0
	reloadButton.Font = FONT
	reloadButton.TextSize = 14
	reloadButton.TextColor3 = INK
	reloadButton.Text = "RELOAD"
	reloadButton.Visible = false
	corner(reloadButton, 36)
	reloadButton.Activated:Connect(function()
		if actions.reload then
			actions.reload()
		end
	end)
	reloadButton.Parent = gui
end

-- Kills and accuracy of the local player (the server keeps them as Player attributes).
local function watchStats()
	local player = Players.LocalPlayer
	local function refresh()
		local kills = player:GetAttribute("Kills") or 0
		local shots = player:GetAttribute("Shots") or 0
		local hits = player:GetAttribute("Hits") or 0
		local accuracy = if shots > 0 then math.floor(hits / shots * 100 + 0.5) else 0
		statsLabel.Text = string.format("KILLS %d    ACCURACY %d%%    SHOTS %d", kills, accuracy, shots)
	end
	for _, key in { "Kills", "Shots", "Hits" } do
		player:GetAttributeChangedSignal(key):Connect(refresh)
	end
	refresh()
end

-- The device the player is using, from Roblox's own pick (PreferredInput); clients without that
-- property fall back to what the device has.
local function readInputKind(): string
	local ok, preferred = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok and typeof(preferred) == "EnumItem" then
		if preferred.Name == "Touch" then
			return "touch"
		elseif preferred.Name == "Gamepad" or preferred.Name == "MicroGamepad" then
			return "gamepad"
		end
		return "keyboard"
	end
	if not UserInputService.MouseEnabled then
		if UserInputService.TouchEnabled then
			return "touch"
		elseif UserInputService.GamepadEnabled then
			return "gamepad"
		end
	end
	return "keyboard"
end

-- Mouse: where the mouse is. Phone and gamepad: the screen centre (there is no pointer to follow).
function Hud.aimPoint(): Vector2
	if inputKind == "keyboard" and UserInputService.MouseEnabled then
		return UserInputService:GetMouseLocation() -- (equals the screen centre when the mouse is locked)
	end
	local camera = Workspace.CurrentCamera
	return if camera then camera.ViewportSize / 2 else Vector2.zero
end

-- Weapon name plus a status: RELOADING, PRESS R (empty magazine) or OUT OF AMMO.
local function renderName()
	local name = weapon and weapon.name or ""
	if reloadStart then
		nameLabel.Text = name .. "   -   RELOADING"
		nameLabel.TextColor3 = INK
	elseif magEmpty and reserveEmpty then
		nameLabel.Text = name .. "   -   OUT OF AMMO"
		nameLabel.TextColor3 = DANGER
	elseif magEmpty then
		nameLabel.Text = name .. "   -   " .. RELOAD_PROMPTS[inputKind]
		nameLabel.TextColor3 = DANGER
	else
		nameLabel.Text = name
		nameLabel.TextColor3 = DIM
	end
end

local function updateCursor()
	crosshair.Visible = weapon ~= nil and not cursorForced
	reloadButton.Visible = weapon ~= nil and inputKind == "touch"
	if Config.HUD then
		UserInputService.MouseIconEnabled = weapon == nil or cursorForced -- our crosshair replaces the cursor
	end
end

-- Moves things for the device in use. Phone: ammo panel top right and weapon bar top left, both
-- smaller, so the thumbstick (bottom left) and jump button (bottom right) stay free.
local function applyLayout()
	local touch = inputKind == "touch"
	-- Below Roblox's top bar. Its height is still 0 while the HUD is built (Studio, iPhone sim):
	-- assume today's 58 until the real value arrives (TopbarInset re-runs this).
	local inset = GuiService:GetGuiInset().Y
	local top = (if inset > 0 then inset else 58) + 8
	if touch then
		-- Same row, opposite corners: on a 667-wide phone a centred bar would touch the panel.
		ammoPanel.AnchorPoint = Vector2.new(1, 0)
		ammoPanel.Position = UDim2.new(1, -16, 0, top)
		slotBar.AnchorPoint = Vector2.new(0, 0)
		slotBar.Position = UDim2.fromOffset(16, top)
	else
		ammoPanel.AnchorPoint = Vector2.new(1, 1)
		ammoPanel.Position = UDim2.new(1, -24, 1, -24)
		slotBar.AnchorPoint = Vector2.new(0.5, 1)
		slotBar.Position = UDim2.new(0.5, 0, 1, -24)
	end
	panelScale.Scale = if touch then TOUCH_SCALE else 1
	barScale.Scale = if touch then TOUCH_SCALE else 1

	local hint = HINTS[inputKind]
	if Config.DEMO_CHEAT_PANEL and inputKind == "keyboard" then
		hint ..= "    F2 exploit simulator"
	end
	hintLabel.Text = hint
	hintLabel.Visible = hint ~= ""
	updateCursor()
	renderName()
end

function Hud.setWeapon(def)
	weapon = def
	ammoPanel.Visible = def ~= nil
	updateCursor()
	if def then
		accent.BackgroundColor3 = def.color
	end
	renderName()
end

function Hud.setAmmo(mag: number, reserve: number?)
	magEmpty = mag <= 0
	reserveEmpty = reserve ~= nil and reserve <= 0
	ammoLabel.Text = string.format(
		'<font color="#%s">%d</font><font size="22" color="#%s">  /  %s</font>',
		(if magEmpty then DANGER else INK):ToHex(),
		mag,
		(if reserveEmpty then DANGER else DIM):ToHex(),
		if reserve then tostring(reserve) else "-"
	)
	renderName()
end

function Hud.setReload(startClock: number?)
	reloadStart = startClock
	reloadBar.Visible = startClock ~= nil
	reloadFill.Size = UDim2.fromScale(0, 1)
	renderName()
end

-- True while a menu is open: the normal mouse cursor comes back and the crosshair hides.
function Hud.showCursor(show: boolean)
	cursorForced = show
	updateCursor()
end

function Hud.bloom()
	bloom = math.min(bloom + 7, 22)
end

-- Hit marker (red and bigger for a headshot, gold when it killed) plus a floating damage number.
function Hud.hitMarker(damage: number, headshot: boolean, killed: boolean)
	local color = if killed then GOLD elseif headshot then DANGER else INK
	for _, mark in hitTicks do
		mark.BackgroundColor3 = color
		mark.Size = UDim2.fromOffset(if headshot then 3 else 2, if headshot then 13 else 9)
		mark.BackgroundTransparency = 0
		TweenService:Create(mark, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
	end

	local at = Hud.aimPoint()
	local number = label({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromOffset(at.X + 22, at.Y - 10),
		Size = UDim2.fromOffset(260, 28),
		TextSize = if headshot then 26 else 20,
		TextColor3 = color,
		TextStrokeTransparency = 0.3,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = (if headshot then "HEADSHOT  " else "") .. math.floor(damage + 0.5),
	})
	number.Parent = gui
	local tween = TweenService:Create(number, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.fromOffset(at.X + 22, at.Y - 48),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	tween.Completed:Once(function()
		number:Destroy()
	end)
	tween:Play()
end

function Hud.selectSlot(name: string?)
	for slotName, slot in slots do
		local selected = slotName == name
		slot.stroke.Transparency = if selected then 0 else 1
		slot.frame.BackgroundTransparency = if selected then 0.1 else 0.45
	end
end

function Hud.start(newActions)
	actions = newActions or {}
	gui = Instance.new("ScreenGui")
	gui.Name = "WeaponKitHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- so GetMouseLocation() and GUI coordinates are the same space
	gui.DisplayOrder = 5
	gui.Enabled = Config.HUD -- off: built anyway (aimPoint and the calls still work), never shown
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	buildCrosshair()
	buildAmmoPanel()
	buildSlots()
	buildCorners()
	watchStats()
	Hud.selectSlot(nil)

	inputKind = readInputKind()
	applyLayout()
	pcall(function() -- Roblox's top bar height arrives after the HUD is built
		GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(applyLayout)
	end)
	pcall(function() -- a pad plugged in, or a touch screen laptop switching: re-lay out
		UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(function()
			local kind = readInputKind()
			if kind ~= inputKind then
				inputKind = kind
				applyLayout()
			end
		end)
	end)
end

return Hud
