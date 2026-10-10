--!nonstrict
-- DEMO ONLY - delete this file or set Config.DEMO_CHEAT_PANEL = false for production.
--
-- The exploit lab: an "executor simulator" for videos and live demos. Press F2 to open it. Each
-- button does, with ordinary client APIs only, what a script from an executor (Infinite Yield,
-- aimbots, ESP/hitbox tools) would do to a game, then shows what the SERVER did about it.
-- Nothing here weakens or bypasses anything: it is an ordinary client, which is exactly the
-- point. Every test cleans up after itself (WalkSpeed, JumpPower, CanCollide, head sizes, health,
-- velocities), and a character the server did not pull back is put back by the lab.
--
-- COMBAT tab   shots and requests a cheat would send: Rapid fire 3x, Fake origin, Garbage args,
--              Reload spam, Wallbang (through the lab wall), Hitbox expander (client-only
--              giant heads), Silent aim (shots snapped from head to head), Godmode (client-only
--              health), Remote fuzz (junk to every remote)
-- MOVEMENT tab Speed hack, CFrame speed, Teleport, Fly, Super jump, Infinite jump, Noclip, Fling spin
--
-- What it shows after each test:
--   * server flags: the refusals the server counted during the test (the Rejected remote; the
--     server only sends it while DEMO_CHEAT_PANEL is on: a real game must never explain its
--     anti-cheat to the player). The full list below the buttons has a one-line meaning each.
--   * damage the server confirmed and rounds it spent (combat tests): these stay what a normal
--     player would get, however nasty the requests were
--   * "client set X, server still sees Y" (LabQuery, a read-only demo remote)
--   * for movement tests: how far the exploit put you, how far from the start you ended up, and
--     whether the server rubber-banded you
-- Stand where the test says (the lab corner, east of the spawn, for wallbang and noclip).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Weapons = require(Shared:WaitForChild("Weapons"))
local Hud = require(script.Parent.Hud)
local WeaponClient = require(script.Parent.WeaponClient)

local CheatPanel = {}

local TOGGLE_KEY = Enum.KeyCode.F2
local INK = Color3.fromRGB(240, 242, 245)
local DIM = Color3.fromRGB(150, 158, 170)
local PANEL = Color3.fromRGB(16, 18, 22)
local BUTTON = Color3.fromRGB(34, 38, 46)
local RED = Color3.fromRGB(255, 96, 84)
local GREEN = Color3.fromRGB(90, 225, 140)
local AMBER = Color3.fromRGB(255, 206, 80)

local PANEL_WIDTH = 420
local CONTENT_TOP = 106 -- where the tab pages start inside the panel
local RESULT_HEIGHT = 124 -- the result text at the bottom
local REFUSALS_HEIGHT = 214 -- the list of server flags above it (fits the whole list at 1080p)
local RESULT_DELAY = 1.0 -- seconds a test waits for the server's answers before it reports
local MOVED_AT_LEAST = 3 -- studs: a smaller move is not worth a rubber-band report
local RUBBER_BAND = 5 -- studs the server must have pulled you back to count as "rubber-banded"

-- What each server flag means, in the order they are listed.
local REASONS = {
	{ "fast", "kept firing faster than the weapon allows (one burst is only refused: it looks like lag)" },
	{ "origin", "muzzle too far from the player" },
	{ "args", "garbage numbers or wrong types" },
	{ "rate", "flooding the Fire remote" },
	{ "reload", "flooding the Reload remote" },
	{ "crate", "used the ammo crate from too far away" },
	{ "aim", "headshot rate no human has (flag only)" },
	{ "snap", "aim jumped between targets, then hit (flag only)" },
	{ "speed", "moved faster than WalkSpeed allows" },
	{ "teleport", "jumped a long way in one step" },
	{ "fly", "stayed up longer than a jump or fall allows" },
	{ "jump", "rose higher than a jump can" },
	{ "noclip", "went through a solid wall" },
	{ "fling", "spun or flew at impossible speed" },
}

local function colorHex(c: Color3): string
	return "#" .. c:ToHex()
end

local function colored(s: string, c: Color3): string
	return '<font color="' .. colorHex(c) .. '">' .. s .. "</font>"
end

function CheatPanel.start()
	if not Config.DEMO_CHEAT_PANEL then
		return
	end
	local player = Players.LocalPlayer
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local fireRemote = remotes:WaitForChild("Fire")
	local reloadRemote = remotes:WaitForChild("Reload")
	local ammoRemote = remotes:WaitForChild("AmmoSync")
	local hitRemote = remotes:WaitForChild("HitConfirm")
	local rejectedRemote = remotes:WaitForChild("Rejected")
	local labQuery = remotes:WaitForChild("LabQuery")

	-- What the server has told us so far.
	local refusals = {} -- [reason] = how many
	local totalRefused = 0
	local confirmedDamage = 0
	local roundsSpent = 0
	local lastMag = {} -- [weapon] = last mag the server reported
	local busy = false -- one test at a time
	local cleanups = {} -- functions that undo what the running test changed, newest last

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true

	----------------------------------------------------------------- UI
	local gui = Instance.new("ScreenGui")
	gui.Name = "CheatPanel"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 20
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Full height minus a margin, so nothing runs off a small screen; the pages scroll instead.
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0, 0.5)
	frame.Position = UDim2.new(0, 16, 0.5, 0)
	frame.Size = UDim2.new(0, PANEL_WIDTH, 1, -32)
	frame.BackgroundColor3 = PANEL
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = RED
	stroke.Thickness = 1.5
	stroke.Parent = frame

	local function text(props): TextLabel
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Font = Enum.Font.GothamMedium
		l.TextColor3 = INK
		l.TextSize = 14
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextYAlignment = Enum.TextYAlignment.Top
		l.RichText = true
		for key, value in props do
			l[key] = value
		end
		l.Parent = frame
		return l
	end

	text({
		Text = "EXPLOIT SIMULATOR",
		Font = Enum.Font.GothamBlack,
		TextSize = 17,
		TextColor3 = RED,
		Position = UDim2.fromOffset(16, 12),
		Size = UDim2.new(1, -150, 0, 22),
	})
	local tag = text({
		Text = "DEMO ONLY",
		Font = Enum.Font.GothamBlack,
		TextSize = 11,
		TextColor3 = RED,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 14),
		Size = UDim2.fromOffset(86, 20),
	})
	local tagStroke = Instance.new("UIStroke")
	tagStroke.Color = RED
	tagStroke.Thickness = 1
	tagStroke.Parent = tag
	text({
		Text = "Each button does what an executor script would do. The server decides what happens. Everything is undone afterwards.",
		TextColor3 = DIM,
		TextSize = 12,
		TextWrapped = true,
		Position = UDim2.fromOffset(16, 38),
		Size = UDim2.new(1, -32, 0, 32),
	})

	-- Tabs and their scrolling pages.
	local pages, tabButtons = {}, {}
	local function showTab(name: string)
		for key, page in pages do
			page.Visible = key == name
		end
		for key, button in tabButtons do
			button.BackgroundColor3 = if key == name then Color3.fromRGB(120, 36, 32) else BUTTON
			button.TextColor3 = if key == name then INK else DIM
		end
	end
	local function newTab(name: string, index: number)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0.5, -20, 0, 28)
		button.Position = UDim2.new(if index == 1 then 0 else 0.5, if index == 1 then 16 else 4, 0, 74)
		button.BorderSizePixel = 0
		button.Font = Enum.Font.GothamBold
		button.TextSize = 13
		button.Text = name
		button.AutoButtonColor = true
		button.Parent = frame
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = button
		button.Activated:Connect(function()
			showTab(name)
		end)
		tabButtons[name] = button

		local page = Instance.new("ScrollingFrame")
		page.Name = name
		page.BackgroundTransparency = 1
		page.BorderSizePixel = 0
		page.Position = UDim2.fromOffset(16, CONTENT_TOP)
		page.Size = UDim2.new(1, -32, 1, -(CONTENT_TOP + RESULT_HEIGHT + REFUSALS_HEIGHT + 56))
		page.CanvasSize = UDim2.new()
		page.AutomaticCanvasSize = Enum.AutomaticSize.Y
		page.ScrollingDirection = Enum.ScrollingDirection.Y
		page.ScrollBarThickness = 6
		page.Visible = false
		page.Parent = frame
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 6)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = page
		pages[name] = page
		return page
	end
	local combatPage = newTab("COMBAT", 1)
	local movementPage = newTab("MOVEMENT", 2)

	-- Bottom area, built upwards from the bottom edge: result text, then the list of flags.
	local resultLabel = text({
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -12),
		Size = UDim2.new(1, -32, 0, RESULT_HEIGHT),
		TextSize = 13,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	local refusalScroll = Instance.new("ScrollingFrame")
	refusalScroll.BackgroundTransparency = 1
	refusalScroll.BorderSizePixel = 0
	refusalScroll.AnchorPoint = Vector2.new(0, 1)
	refusalScroll.Position = UDim2.new(0, 16, 1, -(12 + RESULT_HEIGHT + 6))
	refusalScroll.Size = UDim2.new(1, -32, 0, REFUSALS_HEIGHT)
	refusalScroll.CanvasSize = UDim2.new()
	refusalScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	refusalScroll.ScrollBarThickness = 4
	refusalScroll.Parent = frame
	local refusalLabel = Instance.new("TextLabel")
	refusalLabel.BackgroundTransparency = 1
	refusalLabel.Font = Enum.Font.GothamMedium
	refusalLabel.TextSize = 12
	refusalLabel.TextColor3 = INK
	refusalLabel.TextXAlignment = Enum.TextXAlignment.Left
	refusalLabel.TextYAlignment = Enum.TextYAlignment.Top
	refusalLabel.TextWrapped = true
	refusalLabel.RichText = true
	refusalLabel.AutomaticSize = Enum.AutomaticSize.Y
	refusalLabel.Size = UDim2.new(1, -8, 0, 0)
	refusalLabel.Parent = refusalScroll
	text({
		Text = "SERVER FLAGS",
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = DIM,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -(12 + RESULT_HEIGHT + 6 + REFUSALS_HEIGHT + 2)),
		Size = UDim2.new(1, -32, 0, 16),
	})

	local function setResult(richText: string)
		resultLabel.Text = richText
	end

	local function renderRefusals()
		local lines = {}
		for _, reason in REASONS do
			local n = refusals[reason[1]] or 0
			table.insert(
				lines,
				string.format(
					"%s  %s",
					colored(string.format("<b>%s x%d</b>", reason[1], n), if n > 0 then RED else DIM),
					colored(reason[2], DIM)
				)
			)
		end
		refusalLabel.Text = table.concat(lines, "\n")
	end

	----------------------------------------------------------------- helpers for the tests
	-- The local character's parts, or nothing if it is dead or not there.
	local function body()
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and root and humanoid.Health > 0 then
			return character, humanoid, root
		end
		return nil, nil, nil
	end

	-- Which way "forward" is: where the camera looks, flattened.
	local function forward(): Vector3
		local look = Workspace.CurrentCamera.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude < 0.01 then
			return Vector3.new(0, 0, -1)
		end
		return flat.Unit
	end

	-- Registers something to undo when the test is over (even if it fails half way).
	local function undoLater(fn: () -> ())
		table.insert(cleanups, fn)
	end

	local function runCleanups()
		for index = #cleanups, 1, -1 do
			pcall(cleanups[index])
		end
		table.clear(cleanups)
	end

	-- Calls step(dt, elapsed) every frame for `seconds`, and waits until it is done. It runs at the
	-- last render priority, after the default controls, so a Humanoid:Move here beats the keys.
	local function drive(seconds: number, step: (number, number) -> ())
		local name = "CheatLabDrive"
		local started = os.clock()
		local last = started
		local finished = false
		undoLater(function()
			pcall(RunService.UnbindFromRenderStep, RunService, name)
		end)
		RunService:BindToRenderStep(name, Enum.RenderPriority.Last.Value, function()
			local now = os.clock()
			local ok = now - started < seconds and pcall(step, now - last, now - started)
			last = now
			if not ok then
				finished = true
				pcall(RunService.UnbindFromRenderStep, RunService, name)
			end
		end)
		while not finished do
			task.wait()
		end
	end

	-- What the server sees for our character right now (LabQuery), or nil.
	local function serverView()
		local ok, view = pcall(function()
			return labQuery:InvokeServer()
		end)
		if ok and type(view) == "table" then
			return view
		end
		return nil
	end

	-- Living dummies, nearest first not needed: callers sort what they need.
	local function liveDummies()
		local list = {}
		for _, model in CollectionService:GetTagged(Config.TARGET_TAG) do
			local head = model:FindFirstChild("Head")
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if head and humanoid and humanoid.Health > 0 and model:IsDescendantOf(Workspace) then
				table.insert(list, { model = model, head = head })
			end
		end
		return list
	end

	local function labFolder(): Instance?
		local range = Workspace:FindFirstChild("Range")
		return range and range:FindFirstChild("Lab")
	end

	-- Living dummies in reach of a muzzle, ordered so that neighbours in the list are far apart on
	-- screen (leftmost, rightmost, second leftmost, ...): shots in this order "snap" the most.
	local function snapOrder(origin: Vector3, reach: number)
		local right = Workspace.CurrentCamera.CFrame.RightVector
		local near = {}
		for _, dummy in liveDummies() do
			local offset = dummy.head.Position - origin
			if offset.Magnitude <= reach then
				dummy.side = offset.Unit:Dot(right)
				table.insert(near, dummy)
			end
		end
		table.sort(near, function(a, b)
			return a.side < b.side
		end)
		local ordered, low, high = {}, 1, #near
		while low <= high do
			table.insert(ordered, near[low])
			low += 1
			if low <= high then
				table.insert(ordered, near[high])
				high -= 1
			end
		end
		return ordered
	end

	-- Junk for the remote fuzz: a different, nasty set of arguments for every call.
	local function junkArgs(i: number)
		local nested = { a = { b = { c = { d = i } } } }
		local pool = {
			function()
				return
			end,
			function()
				return nil, nil, nil
			end,
			function()
				return 0 / 0, 0 / 0, 0 / 0
			end,
			function()
				return math.huge, -math.huge, 1e308
			end,
			function()
				return string.rep("A", 1024), string.rep("\0", 1024), ""
			end,
			function()
				return {}, { 1, 2, 3 }, { x = {} }
			end,
			function()
				return nested, { { { { {} } } } }
			end,
			function()
				return Workspace, player, player.Character
			end,
			function()
				return Vector3.new(0 / 0, 1, 2), Vector3.new(math.huge, 0, 0), CFrame.new()
			end,
			function()
				return true, false, -1, 2 ^ 53, 1e15
			end,
			function()
				return Vector3.new(1e9, 1e9, 1e9), Vector3.zero, 5
			end,
			function()
				return "999", { "x" }, -5
			end,
		}
		return pool[(i - 1) % #pool + 1]()
	end

	----------------------------------------------------------------- the tests
	-- A test is { tab, title, sub, needsWeapon?, combat?, moves?, run }. run() may yield and returns
	--   sent   number of requests it sent (nil if that makes no sense for the test)
	--   notes  lines of rich text for the result
	local tests = {
		{
			tab = combatPage,
			title = "Rapid fire 3x",
			sub = "3x the weapon's fire rate for 2 s",
			needsWeapon = true,
			combat = true,
			run = function()
				-- What a fire-rate script does: keep firing faster than the rpm. (A single burst in one frame
				-- is refused too, but not reported: a lag spike delivers honest shots the same way.)
				local def = Weapons.Defs[WeaponClient.heldWeapon() or ""]
				if not def then
					return 0
				end
				local sent, stopAt = 0, os.clock() + 2
				while os.clock() < stopAt do
					local muzzle, direction = WeaponClient.getAim()
					if not muzzle then
						break
					end
					fireRemote:FireServer(muzzle, direction, WeaponClient.nextShotId())
					sent += 1
					task.wait(60 / def.rpm / 3)
				end
				return sent
			end,
		},
		{
			tab = combatPage,
			title = "Fake origin",
			sub = "bullet starts 60 studs ahead of you",
			needsWeapon = true,
			combat = true,
			run = function()
				local muzzle, direction = WeaponClient.getAim()
				if not muzzle then
					return 0
				end
				fireRemote:FireServer(muzzle + direction * 60, direction, WeaponClient.nextShotId())
				return 1
			end,
		},
		{
			tab = combatPage,
			title = "Garbage args",
			sub = "NaN vector, string id, absurd direction",
			needsWeapon = true,
			combat = true,
			run = function()
				local muzzle, direction = WeaponClient.getAim()
				if not muzzle then
					return 0
				end
				fireRemote:FireServer(Vector3.new(0 / 0, 0 / 0, 0 / 0), direction, WeaponClient.nextShotId())
				fireRemote:FireServer(muzzle, direction, "999")
				fireRemote:FireServer(muzzle, Vector3.new(1e9, 0, 0), WeaponClient.nextShotId())
				return 3
			end,
		},
		{
			tab = combatPage,
			title = "Reload spam",
			sub = "20 Reload events in one frame",
			needsWeapon = true,
			combat = true,
			run = function()
				for _ = 1, 20 do
					reloadRemote:FireServer()
				end
				return 20
			end,
		},
		{
			tab = combatPage,
			title = "Wallbang",
			sub = "aim through the 4-stud lab wall at the dummy behind it",
			needsWeapon = true,
			combat = true,
			run = function()
				local lab = labFolder()
				local spot = lab and lab:GetAttribute("DummySpot")
				local muzzle = WeaponClient.getAim()
				if not muzzle or typeof(spot) ~= "Vector3" then
					return 0,
						{ colored("The lab corner is not built (Config.DEMO_CHEAT_PANEL on the server?).", AMBER) }
				end
				local head
				for _, dummy in liveDummies() do
					local flat = dummy.head.Position - spot
					if Vector3.new(flat.X, 0, flat.Z).Magnitude < 4 then
						head = dummy.head
					end
				end
				if not head then
					return 0, { colored("The dummy behind the wall is down: wait 3 s for the respawn.", AMBER) }
				end
				-- Make sure the wall really is in the way before the test means anything.
				rayParams.FilterDescendantsInstances = { player.Character }
				local toHead = head.Position - muzzle
				local blocker = Workspace:Raycast(muzzle, toHead, rayParams)
				if not blocker or blocker.Instance.Name ~= "WallbangWall" then
					return 0,
						{
							colored(
								"Stand in front of the lab wall (lab corner, east of the spawn) so it is between you and the dummy.",
								AMBER
							),
						}
				end
				fireRemote:FireServer(muzzle, toHead.Unit, WeaponClient.nextShotId())
				return 1, { "aimed straight through the wall at the dummy's head" }
			end,
		},
		{
			tab = combatPage,
			title = "Hitbox expander",
			sub = "heads x6 on this client, shoot beside the real head",
			needsWeapon = true,
			combat = true,
			run = function()
				local muzzle = WeaponClient.getAim()
				local best, bestDistance
				for _, dummy in liveDummies() do
					local distance = muzzle and (dummy.head.Position - muzzle).Magnitude
					if distance and distance < 120 and (not best or distance < bestDistance) then
						best, bestDistance = dummy, distance
					end
				end
				if not best then
					return 0, { colored("No living dummy within 120 studs.", AMBER) }
				end
				local head = best.head
				local realSize = head.Size
				undoLater(function()
					head.Size = realSize
				end)
				head.Size = realSize * 6 -- only THIS client sees it
				local toHead = head.Position - muzzle
				local aimAt = head.Position + toHead.Unit:Cross(Vector3.yAxis).Unit * 3 -- 3 studs beside the real head
				local direction = (aimAt - muzzle).Unit
				rayParams.FilterDescendantsInstances = { player.Character }
				local localHit = Workspace:Raycast(muzzle, direction * 500, rayParams)
				fireRemote:FireServer(muzzle, direction, WeaponClient.nextShotId())
				return 1,
					{
						"this client's own raycast: " .. (if localHit and localHit.Instance == head
							then colored("HIT the giant head", AMBER)
							else "missed"),
						"the server raycasts ITS heads, so the shot goes past",
					}
			end,
		},
		{
			tab = combatPage,
			title = "Silent aim",
			sub = "shots snapped from head to head, at fire-rate pace",
			needsWeapon = true,
			combat = true,
			run = function()
				local held = WeaponClient.heldWeapon()
				local def = Weapons.Defs[held]
				if def.pellets > 1 or def.rpm < 200 then
					return 0,
						{ colored("Needs a fast single-bullet weapon: equip the Pistol (best) or the Rifle.", AMBER) }
				end
				local interval = 60 / def.rpm * 1.12 -- just slower than the fire-rate limit: every shot is legal
				local reach = math.max(40, 0.5 / math.tan(math.rad(def.spread))) -- close enough that the server's spread stays on a head
				local shots = math.min(14, lastMag[held] or def.magazine)
				local sent = 0
				for index = 1, shots do
					local muzzle = WeaponClient.getAim()
					local targets = if muzzle then snapOrder(muzzle, reach) else {}
					if #targets == 0 then
						break
					end
					local target = targets[(index - 1) % #targets + 1]
					fireRemote:FireServer(muzzle, (target.head.Position - muzzle).Unit, WeaponClient.nextShotId())
					sent += 1
					task.wait(interval)
				end
				if sent == 0 then
					return 0, { colored("No living dummy in reach: walk to the firing line.", AMBER) }
				end
				return sent,
					{
						"every shot aimed at a head, switching dummy each time",
						"(stand at the firing line; the Pistol is the most reliable)",
					}
			end,
		},
		{
			tab = combatPage,
			title = "Godmode",
			sub = "set your own health to 1,000,000 on this client",
			combat = false,
			run = function()
				local _, humanoid = body()
				if not humanoid then
					return 0, { colored("No living character.", AMBER) }
				end
				local maxHealth, health = humanoid.MaxHealth, humanoid.Health
				undoLater(function()
					humanoid.MaxHealth = maxHealth
					humanoid.Health = math.min(health, maxHealth)
				end)
				humanoid.MaxHealth = 1e6
				humanoid.Health = 1e6
				task.wait(0.4)
				local view = serverView()
				return nil,
					{
						string.format("client: health <b>%.0f</b> / %.0f", humanoid.Health, humanoid.MaxHealth),
						view and string.format(
							"server: health <b>%.0f</b> / %.0f  %s",
							view.health,
							view.maxHealth,
							colored("(unchanged)", GREEN)
						) or colored("server view unavailable", AMBER),
						"damage is server-side, so this client-only number protects nothing",
					}
			end,
		},
		{
			tab = combatPage,
			title = "Remote fuzz",
			sub = "junk to every remote: NaN, huge, nested, Instances",
			combat = false,
			run = function()
				local sent = 0
				local all = remotes:GetChildren()
				for call = 1, 30 do
					for index, remote in all do
						if remote:IsA("RemoteEvent") then
							pcall(remote.FireServer, remote, junkArgs(call + index))
							sent += 1
						elseif remote:IsA("RemoteFunction") then
							task.spawn(pcall, remote.InvokeServer, remote, junkArgs(call + index))
							sent += 1
						end
					end
					task.wait(0.04)
				end
				task.wait(0.5)
				local view = serverView()
				return sent,
					{
						string.format("junk sent to %d remotes, 30 calls each", #all),
						view and colored("server still answers (LabQuery): it did not choke", GREEN)
							or colored("no answer from the server: check the Output for errors", RED),
						"also check the server Output: there must be no red errors",
					}
			end,
		},

		{
			tab = movementPage,
			title = "Speed hack",
			sub = "WalkSpeed 60 for 3 s, walking forward",
			moves = true,
			run = function()
				local _, humanoid = body()
				local original = humanoid.WalkSpeed
				undoLater(function()
					humanoid.WalkSpeed = original
				end)
				humanoid.WalkSpeed = 60 -- only this client believes it
				local direction = forward()
				local view
				task.delay(1.2, function()
					view = serverView()
				end)
				drive(3, function()
					humanoid:Move(direction, false)
				end)
				return nil,
					{
						"client WalkSpeed 60 for 3 s",
						view and string.format("server still sees WalkSpeed <b>%.0f</b>", view.walkSpeed) or "",
					}
			end,
		},
		{
			tab = movementPage,
			title = "CFrame speed",
			sub = "slide the root forward 60 studs/s for 2 s",
			moves = true,
			run = function()
				local _, _, root = body()
				local direction = forward()
				drive(2, function(dt)
					root.CFrame = root.CFrame + direction * 60 * dt
				end)
				return nil, { "root part moved by CFrame at 60 studs/s (WalkSpeed untouched)" }
			end,
		},
		{
			tab = movementPage,
			title = "Teleport",
			sub = "jump 80 studs forward in one frame",
			moves = true,
			run = function()
				local _, _, root = body()
				root.CFrame = root.CFrame + forward() * 80
				task.wait(0.5)
				return nil, { "root part set 80 studs ahead in one frame" }
			end,
		},
		{
			tab = movementPage,
			title = "Fly",
			sub = "rise about 20 studs, then hover with gravity cancelled, 3 s",
			moves = true,
			run = function()
				local _, humanoid, root = body()
				-- PlatformStand switches the Humanoid's own controller off, like fly scripts do: with it
				-- on, the Humanoid fights the push and the character barely leaves the ground.
				local platformStand = humanoid.PlatformStand
				undoLater(function()
					humanoid.PlatformStand = platformStand
				end)
				humanoid.PlatformStand = true
				local upright = root.CFrame.Rotation
				drive(3, function(_, elapsed)
					root.CFrame = CFrame.new(root.Position) * upright -- stay upright while the controller is off
					root.AssemblyAngularVelocity = Vector3.zero
					root.AssemblyLinearVelocity = if elapsed < 0.7 then Vector3.new(0, 30, 0) else Vector3.zero
				end)
				return nil, { "rose for 0.7 s, then hovered by zeroing the velocity every frame" }
			end,
		},
		{
			tab = movementPage,
			title = "Super jump",
			sub = "JumpPower 150 on this client, then jump",
			moves = true,
			run = function()
				local _, humanoid = body()
				local useJumpPower, jumpPower, jumpHeight =
					humanoid.UseJumpPower, humanoid.JumpPower, humanoid.JumpHeight
				undoLater(function()
					humanoid.UseJumpPower = useJumpPower
					humanoid.JumpPower = jumpPower
					humanoid.JumpHeight = jumpHeight
				end)
				humanoid.UseJumpPower = true
				humanoid.JumpPower = 150
				humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
				task.wait(0.6)
				local view = serverView()
				task.wait(1.4)
				return nil,
					{
						"client JumpPower 150 (a jump of about 57 studs)",
						view and string.format("server still sees JumpPower <b>%.0f</b>", view.jumpPower) or "",
					}
			end,
		},
		{
			tab = movementPage,
			title = "Infinite jump",
			sub = "5 jumps in a row, 4 of them in mid-air",
			moves = true,
			run = function()
				local _, humanoid = body()
				for _ = 1, 5 do
					humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
					task.wait(0.3)
				end
				task.wait(1)
				return nil, { "Jumping state forced every 0.3 s, also in the air" }
			end,
		},
		{
			tab = movementPage,
			title = "Noclip",
			sub = "CanCollide off, walk through the lab's noclip wall",
			moves = true,
			run = function()
				local character, humanoid, root = body()
				local lab = labFolder()
				local wall = lab and lab:FindFirstChild("NoclipWall")
				if not wall then
					return nil, { colored("The lab corner is not built.", AMBER) }
				end
				local toWall = wall.Position - root.Position
				local flat = Vector3.new(toWall.X, 0, toWall.Z)
				if flat.Magnitude > 25 or flat.Magnitude < 1 then
					return nil,
						{
							colored(
								"Stand 5-20 studs from the NOCLIP WALL in the lab corner (east of the spawn), facing it.",
								AMBER
							),
						}
				end
				local saved = {}
				for _, part in character:GetDescendants() do
					if part:IsA("BasePart") then
						saved[part] = part.CanCollide
					end
				end
				undoLater(function()
					for part, value in saved do
						part.CanCollide = value
					end
				end)
				local direction = flat.Unit
				drive(2, function()
					for part in saved do
						part.CanCollide = false -- Roblox turns it back on, so a real noclip script does this every frame
					end
					humanoid:Move(direction, false)
				end)
				return nil, { "CanCollide off on every part of the character, walked into the wall" }
			end,
		},
		{
			tab = movementPage,
			title = "Fling spin",
			sub = "angular velocity 1500 rad/s for 1 s",
			moves = true,
			run = function()
				local _, _, root = body()
				undoLater(function()
					root.AssemblyAngularVelocity = Vector3.zero
				end)
				drive(1, function()
					root.AssemblyAngularVelocity = Vector3.new(0, 1500, 0)
				end)
				return nil, { "root part spun at 1500 rad/s (a fling script's first step)" }
			end,
		},
	}

	-- Runs one test: checks it can run, lets it work, waits for the server's answers, undoes what
	-- it changed and writes the report.
	local function runTest(test)
		if busy then
			setResult(colored("Wait: another test is still running.", AMBER))
			return
		end
		if test.needsWeapon and not WeaponClient.heldWeapon() then
			setResult(colored("Equip a weapon first (1 / 2 / 3).", AMBER))
			return
		end
		local _, _, root = body()
		if test.moves and not root then
			setResult(colored("You need a living character for this test.", AMBER))
			return
		end
		busy = true
		local before =
			{ refusals = table.clone(refusals), refused = totalRefused, damage = confirmedDamage, rounds = roundsSpent }
		local startCFrame = root and root.CFrame
		local peak = 0 -- the farthest the exploit took us from where we started
		local watcher = RunService.Heartbeat:Connect(function()
			local _, _, now = body()
			if now and startCFrame then
				peak = math.max(peak, (now.Position - startCFrame.Position).Magnitude)
			end
		end)
		setResult(colored(test.title .. ": running...", DIM))

		task.spawn(function()
			local ok, sent, notes = pcall(test.run)
			task.wait(RESULT_DELAY)
			watcher:Disconnect()
			local _, _, nowRoot = body()
			local final = if nowRoot and startCFrame then (nowRoot.Position - startCFrame.Position).Magnitude else 0
			runCleanups()
			-- Judge the server BEFORE the lab tidies up. The server puts a cheater back at the last
			-- clean position it saw, and that can be a few studs into the exploit (the first samples
			-- still looked legal), so "ended near the start" is the wrong test: "pulled back from the
			-- farthest point" is the right one.
			local pulledBack = peak - final
			local serverSnapped = test.moves and peak >= MOVED_AT_LEAST and pulledBack >= RUBBER_BAND
			-- Whatever distance is left (a "log" setup, nothing flagged, or the creep above), the lab
			-- walks us home itself so the next test starts in the same place.
			local putBack = false
			if test.moves and nowRoot and final > RUBBER_BAND then
				nowRoot.CFrame = startCFrame
				putBack = true
			end

			local lines = { "<b>" .. test.title .. "</b>" }
			if not ok then
				warn("[WeaponKit] CheatPanel: " .. test.title .. ": " .. tostring(sent))
				table.insert(lines, colored("the test failed: " .. tostring(sent), RED))
			else
				if type(sent) == "number" and sent > 0 then
					table.insert(
						lines,
						string.format(
							"%d requests sent  ->  %s",
							sent,
							colored(string.format("%d refused", totalRefused - before.refused), RED)
						)
					)
				end
				for _, note in notes or {} do
					if note ~= "" then
						table.insert(lines, note)
					end
				end
			end
			local flags = {}
			for _, reason in REASONS do
				local more = (refusals[reason[1]] or 0) - (before.refusals[reason[1]] or 0)
				if more > 0 then
					table.insert(flags, string.format("%s x%d", reason[1], more))
				end
			end
			table.insert(
				lines,
				"server flags: "
					.. (if #flags > 0 then colored(table.concat(flags, ", "), RED) else colored("none", GREEN))
			)
			if test.combat then
				table.insert(
					lines,
					string.format(
						"rounds spent: <b>%d</b>    damage dealt: <b>%d</b>",
						roundsSpent - before.rounds,
						confirmedDamage - before.damage
					)
				)
			end
			if test.moves and peak >= MOVED_AT_LEAST then
				table.insert(
					lines,
					string.format(
						"the exploit took you <b>%.0f</b> studs; you ended <b>%.0f</b> from the start",
						peak,
						final
					)
				)
				if serverSnapped then
					table.insert(
						lines,
						colored(
							string.format("RUBBER-BANDED: the server pulled you back %.0f studs", pulledBack),
							GREEN
						)
					)
				elseif putBack then
					table.insert(lines, colored("the server did NOT move you back (the lab put you back)", AMBER))
				end
			end
			setResult(table.concat(lines, "\n"))
			busy = false
		end)
	end

	for index, test in tests do
		local button = Instance.new("TextButton")
		button.LayoutOrder = index
		button.Size = UDim2.new(1, -10, 0, 44)
		button.BackgroundColor3 = BUTTON
		button.BorderSizePixel = 0
		button.AutoButtonColor = true
		button.Font = Enum.Font.GothamBold
		button.TextSize = 15
		button.TextColor3 = INK
		button.TextXAlignment = Enum.TextXAlignment.Left
		button.TextYAlignment = Enum.TextYAlignment.Top
		button.Text = "   " .. test.title
		button.Parent = test.tab
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = button
		local sub = Instance.new("TextLabel")
		sub.BackgroundTransparency = 1
		sub.Position = UDim2.fromOffset(12, 25)
		sub.Size = UDim2.new(1, -24, 0, 16)
		sub.Font = Enum.Font.GothamMedium
		sub.TextSize = 11
		sub.TextColor3 = DIM
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.Text = test.sub
		sub.Parent = button
		button.Activated:Connect(function()
			runTest(test)
		end)
	end

	showTab("COMBAT")
	renderRefusals()
	setResult(colored("The server only counted what a normal player could do. Pick a test.", GREEN))

	----------------------------------------------------------------- server answers
	rejectedRemote.OnClientEvent:Connect(function(reason, reasonCount, total)
		if type(reason) == "string" and type(reasonCount) == "number" and type(total) == "number" then
			refusals[reason] = reasonCount
			totalRefused = total
			renderRefusals()
		end
	end)
	hitRemote.OnClientEvent:Connect(function(damage)
		if type(damage) == "number" then
			confirmedDamage += damage
		end
	end)
	ammoRemote.OnClientEvent:Connect(function(weapon, mag)
		if type(weapon) == "string" and type(mag) == "number" then
			local before = lastMag[weapon]
			if before and mag < before then
				roundsSpent += before - mag
			end
			lastMag[weapon] = mag
		end
	end)

	----------------------------------------------------------------- toggle
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == TOGGLE_KEY then
			gui.Enabled = not gui.Enabled
			Hud.showCursor(gui.Enabled) -- the real cursor comes back so the buttons can be clicked
		end
	end)
end

return CheatPanel
