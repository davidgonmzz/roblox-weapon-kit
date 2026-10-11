--!nonstrict
-- Pose audit for Studio (not shipped; paste into a Client-side execute_luau / command bar during Play).
-- An INDEPENDENT check of src/client/Pose.luau: it shares no code with Pose's own body push-out.
--
--   S2 numbers: dense grid points inside every gun / arm part (0.08-0.1 stud spacing), each tested
--      with the ENGINE's geometry (GetPartsInPart on a 0.04-stud probe), so a rounded head counts as
--      round, not as its box. Baseline: the same metric with no tool equipped.
--   S3 pictures: the posed character is frozen as a clone and shown in a grid of ViewportFrames:
--      rows = cases (neutral + the worst case per metric), columns = 5 fixed cameras relative to the
--      character (player view, front 3/4, right side, top, X-ray), or an 8-step camera orbit.
--      Same cameras every run, so before/after sheets compare 1:1.
--
-- Use (after this file has run once, everything lives in shared.PoseAudit = A):
--   A.pass("Rifle", {-60,-30,0,30,60}, {-75,-40,0,40,75}, 0.6)   -> summary line, rows in A.rows.Rifle
--   A.worst("Rifle", 3)                                          -> the 3 worst distinct aims
--   A.hideUi(true); A.sheet({A.capture("Rifle",0,0), ...})       -> then screen_capture
--   A.hideUi(true); A.orbit(A.capture("Rifle",0,-75))            -> 8 cameras around one pose
--   A.clear()                                                    -> sheet off, UI and camera back
--   A.job("poles", function(log) ... A.poleSearch(gun, candR, candL, L0, train, held, 0.6, 2, log) end)
--   A.poll("poles")                                              -> status + log while it runs
-- With Rojo (dev.project.json) this file is ReplicatedStorage.WeaponKitDev.pose_audit: require it.
-- Anchor the root first for static aims (turn-in-place then stays off): A.anchor(true).

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local p = Players.LocalPlayer
local cam = Workspace.CurrentCamera
local A = {}
shared.PoseAudit = A

local probe = Workspace:FindFirstChild("PoseAuditProbe") or Instance.new("Part")
probe.Name = "PoseAuditProbe"
probe.Size = Vector3.new(0.04, 0.04, 0.04)
probe.Anchored, probe.CanCollide, probe.CanTouch, probe.CanQuery = true, false, false, false
probe.Transparency = 1
probe.Parent = Workspace

function A.params(parts)
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Include
	op.FilterDescendantsInstances = parts
	op.MaxParts = 1
	return op
end

function A.inside(pos, op)
	probe.CFrame = CFrame.new(pos)
	return #Workspace:GetPartsInPart(probe, op) > 0
end

-- cell-centre grid inside a part's box, world space
function A.grid(part, spacing, maxN)
	local s, pts = part.Size, {}
	local nx = math.clamp(math.ceil(s.X / spacing), 1, maxN)
	local ny = math.clamp(math.ceil(s.Y / spacing), 1, maxN)
	local nz = math.clamp(math.ceil(s.Z / spacing), 1, maxN)
	local cf = part.CFrame
	for i = 0, nx - 1 do
		for j = 0, ny - 1 do
			for k = 0, nz - 1 do
				table.insert(
					pts,
					cf
						* Vector3.new(
							(-0.5 + (i + 0.5) / nx) * s.X,
							(-0.5 + (j + 0.5) / ny) * s.Y,
							(-0.5 + (k + 0.5) / nz) * s.Z
						)
				)
			end
		end
	end
	return pts
end

function A.anchor(on)
	p.Character.HumanoidRootPart.Anchored = on
end

-- aim the local player (Pose reads only the camera's look direction) from an over-the-shoulder spot
function A.setAim(pitch, yaw)
	local char = p.Character
	local root = char.HumanoidRootPart
	local dir = root.CFrame:VectorToWorldSpace(
		(CFrame.Angles(0, math.rad(yaw), 0) * CFrame.Angles(math.rad(pitch), 0, 0)).LookVector
	)
	local eye = char.Head.Position - dir * 8 + root.CFrame.RightVector * 2 + Vector3.new(0, 1, 0)
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.lookAt(eye, eye + dir)
	return dir
end

function A.equip(name)
	local char = p.Character
	local tool = char:FindFirstChild(name) or p.Backpack:FindFirstChild(name)
	if tool and tool.Parent ~= char then
		char:FindFirstChildOfClass("Humanoid"):EquipTool(tool)
	end
	return tool
end

-- one sample of every metric for the current pose (tool = nil: baseline)
function A.sample(tool)
	local char = p.Character
	local opBody = A.params({ char.UpperTorso, char.LowerTorso, char.Head })
	local r = { gunPts = 0, gunIn = 0, gunInArm = 0, upPts = 0, upIn = 0, foPts = 0, foIn = 0 }
	if tool then
		local opArms = A.params({ char.RightLowerArm, char.LeftLowerArm, char.RightUpperArm, char.LeftUpperArm })
		for _, part in tool:GetDescendants() do
			if part:IsA("BasePart") and part.Transparency < 1 then
				for _, pt in A.grid(part, 0.08, 40) do
					r.gunPts += 1
					if A.inside(pt, opBody) then
						r.gunIn += 1
					end
					if A.inside(pt, opArms) then
						r.gunInArm += 1
					end
				end
			end
		end
		local g = tool.Handle.CFrame * tool.Grip -- the barrel lies along -Z of this frame
		r.err = math.deg(math.acos(math.clamp(g.LookVector:Dot(cam.CFrame.LookVector), -1, 1)))
	end
	for _, side in { "Right", "Left" } do
		-- the upper arm's first 0.6 studs from the shoulder joint overlap the torso in any pose: skipped
		local shoulder = char[side .. "UpperArm"][side .. "ShoulderRigAttachment"].WorldPosition
		for _, pt in A.grid(char[side .. "UpperArm"], 0.1, 20) do
			if (pt - shoulder).Magnitude > 0.6 then
				r.upPts += 1
				if A.inside(pt, opBody) then
					r.upIn += 1
				end
			end
		end
		for _, n in { "LowerArm", "Hand" } do
			for _, pt in A.grid(char[side .. n], 0.1, 20) do
				r.foPts += 1
				if A.inside(pt, opBody) then
					r.foIn += 1
				end
			end
		end
	end
	r.gunBody = r.gunPts > 0 and r.gunIn / r.gunPts * 100 or 0
	r.gunArm = r.gunPts > 0 and r.gunInArm / r.gunPts * 100 or 0
	r.upArm = r.upIn / r.upPts * 100
	r.fore = r.foIn / r.foPts * 100
	return r
end

local METRICS = { "gunBody", "gunArm", "upArm", "fore" }

function A.pass(name, pitches, yaws, settle)
	local tool = A.equip(name)
	if not tool then
		return name .. ": not found"
	end
	task.wait(1)
	local rows = {}
	for _, pitch in pitches do
		for _, yaw in yaws do
			A.setAim(pitch, yaw)
			task.wait(settle)
			local r = A.sample(tool)
			r.pitch, r.yaw = pitch, yaw
			table.insert(rows, r)
		end
	end
	A.rows = A.rows or {}
	A.rows[name] = rows
	local sum, max, at, nonzero, maxErr = {}, {}, {}, 0, 0
	for _, m in METRICS do
		sum[m], max[m], at[m] = 0, -1, ""
	end
	for _, r in rows do
		for _, m in METRICS do
			sum[m] += r[m]
			if r[m] > max[m] then
				max[m], at[m] = r[m], string.format("(%d,%d)", r.pitch, r.yaw)
			end
		end
		if r.gunBody > 0 then
			nonzero += 1
		end
		maxErr = math.max(maxErr, r.err or 0)
	end
	local parts = { string.format("%s n=%d", name, #rows) }
	for _, m in METRICS do
		table.insert(parts, string.format("%s mean %.1f max %.1f %s", m, sum[m] / #rows, max[m], at[m]))
	end
	table.insert(parts, string.format("gunBody>0 at %d aims, barrel err max %.2f deg", nonzero, maxErr))
	return table.concat(parts, " | ")
end

-- the k worst distinct aims of a pass (one per metric first), neutral always first
function A.worst(name, k)
	local picked, seen = { { 0, 0 } }, { ["0,0"] = true }
	for _, m in METRICS do
		local best
		for _, r in A.rows[name] do
			if not seen[r.pitch .. "," .. r.yaw] and (not best or r[m] > best[m]) then
				best = r
			end
		end
		if best and #picked < k then
			seen[best.pitch .. "," .. best.yaw] = true
			table.insert(picked, { best.pitch, best.yaw })
		end
	end
	return picked
end

-- a frozen copy of the character as posed right now (no scripts, joints, accessories)
function A.snapshot()
	local char = p.Character
	char.Archivable = true
	local c = char:Clone()
	for _, d in c:GetDescendants() do
		if
			d:IsA("LuaSourceContainer")
			or d:IsA("Accessory")
			or d:IsA("IKControl")
			or d:IsA("JointInstance")
			or d:IsA("Constraint")
		then
			d:Destroy()
		end
	end
	for _, d in c:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	return c
end

-- pose at an aim, measure, freeze
function A.capture(name, pitch, yaw)
	local tool = A.equip(name)
	task.wait(0.3)
	local dir = A.setAim(pitch, yaw)
	task.wait(0.6)
	local r = A.sample(tool)
	return {
		model = A.snapshot(),
		aimDir = dir,
		label = string.format(
			"%s (%d,%d)  gun-in-body %.1f%%  gun-in-arms %.0f%%  upper arm %.0f%%  forearm %.0f%%",
			name,
			pitch,
			yaw,
			r.gunBody,
			r.gunArm,
			r.upArm,
			r.fore
		),
	}
end

local VIEWS = { "player view", "front 3/4", "right side", "top", "x-ray 3/4" }

local function viewCF(view, root, target, aimDir)
	local R = root.CFrame
	local h = target.Y - R.Y
	if view == 1 then
		local eye = target - aimDir * 6 + R.RightVector * 1.6 + Vector3.new(0, 1.2, 0)
		return CFrame.lookAt(eye, target + aimDir * 2.5)
	elseif view == 2 or view == 5 then
		return CFrame.lookAt(R * Vector3.new(4.2, h + 1, -6.5), target)
	elseif view == 3 then
		return CFrame.lookAt(R * Vector3.new(7.5, h + 0.3, -0.8), target)
	end
	return CFrame.lookAt(target + Vector3.new(0, 8, 0), target, R.LookVector)
end

local function xray(model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			if d:FindFirstAncestorOfClass("Tool") then
				d.Color, d.Material = Color3.fromRGB(255, 30, 30), Enum.Material.Neon
			elseif d.Name ~= "HumanoidRootPart" then
				d.Transparency = 0.6
			end
		elseif d:IsA("Decal") then
			d.Transparency = 1
		end
	end
end

local function cell(bg, model, cframe, x, y, w, h, text, xr)
	local vpf = Instance.new("ViewportFrame")
	vpf.Size = UDim2.new(w, -4, h, -4)
	vpf.Position = UDim2.new(x, 2, y, 2)
	vpf.BackgroundColor3 = Color3.fromRGB(150, 160, 170)
	vpf.Ambient = Color3.fromRGB(150, 150, 150)
	vpf.LightColor = Color3.new(1, 1, 1)
	vpf.LightDirection = Vector3.new(-0.5, -1, -0.7)
	local m = model:Clone()
	if xr then
		xray(m)
	end
	m.Parent = vpf
	local c = Instance.new("Camera")
	c.FieldOfView = 40
	c.CFrame = cframe
	c.Parent = vpf
	vpf.CurrentCamera = c
	vpf.Parent = bg
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 0.3
	t.BackgroundColor3 = Color3.new(0, 0, 0)
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextSize = 14
	t.Font = Enum.Font.GothamMedium
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.TextWrapped = true
	t.Size = UDim2.new(1, 0, 0, 0)
	t.AutomaticSize = Enum.AutomaticSize.Y
	t.Text = text
	t.Parent = vpf
end

local function board()
	local old = p.PlayerGui:FindFirstChild("PoseAuditSheet")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "PoseAuditSheet"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	gui.ResetOnSpawn = false
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(205, 210, 215)
	bg.BorderSizePixel = 0
	bg.Parent = gui
	gui.Parent = p.PlayerGui
	return bg
end

local function target(model)
	return model.UpperTorso.Position + Vector3.new(0, 0.2, 0)
end

-- rows = { A.capture(...), ... } (3 fit one screen): 5 fixed cameras per row
function A.sheet(rows)
	local bg = board()
	for i, row in rows do
		local root, t = row.model.HumanoidRootPart, target(row.model)
		for v = 1, #VIEWS do
			local text = if v == 1 then row.label .. "\n" .. VIEWS[v] else VIEWS[v]
			cell(
				bg,
				row.model,
				viewCF(v, root, t, row.aimDir),
				(v - 1) / #VIEWS,
				(i - 1) / #rows,
				1 / #VIEWS,
				1 / #rows,
				text,
				v == 5
			)
		end
	end
end

-- one pose, the camera orbiting it in 8 steps of 45 degrees (2 rows: level, then from 35 degrees above)
function A.orbit(row)
	local bg = board()
	local root, t = row.model.HumanoidRootPart, target(row.model)
	for i = 0, 7 do
		local angle = math.rad(i * 90) / 2 + (if i >= 4 then math.rad(22.5) else 0)
		local up = if i >= 4 then 5 else 0.8
		local offset = root.CFrame:VectorToWorldSpace(Vector3.new(math.sin(angle), 0, -math.cos(angle)) * 7.5)
		local text = string.format(
			"%sorbit %d deg%s",
			if i == 0 then row.label .. "\n" else "",
			(i % 4) * 90 + (if i >= 4 then 45 else 0),
			if i >= 4 then " (high)" else ""
		)
		cell(
			bg,
			row.model,
			CFrame.lookAt(t + offset + Vector3.new(0, up, 0), t),
			(i % 4) / 4,
			math.floor(i / 4) / 2,
			1 / 4,
			1 / 2,
			text,
			false
		)
	end
end

function A.hideUi(hidden)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, not hidden)
	end)
	for _, g in p.PlayerGui:GetChildren() do
		if g:IsA("ScreenGui") and g.Name ~= "PoseAuditSheet" then
			if hidden then
				if g:GetAttribute("AuditWasEnabled") == nil then
					g:SetAttribute("AuditWasEnabled", g.Enabled)
				end
				g.Enabled = false
			elseif g:GetAttribute("AuditWasEnabled") ~= nil then
				g.Enabled = g:GetAttribute("AuditWasEnabled")
				g:SetAttribute("AuditWasEnabled", nil)
			end
		end
	end
end

-- Elbow poles: R, L = offsets from each shoulder in UpperTorso space; false = no pole (baseline).
-- Only for the current rig (equipping another tool rebuilds it with the stance's own poles).
function A.setPoles(R, L)
	local char = p.Character
	local up = char.UpperTorso
	local right, left
	for _, ik in char.Humanoid:GetChildren() do
		if ik:IsA("IKControl") and ik.Name == "WeaponKitPose" then
			if ik.Type == Enum.IKControlType.Transform then
				right = ik
			elseif ik.Type == Enum.IKControlType.Position then
				left = ik
			end
		end
	end
	for _, s in { { right, R, "Right" }, { left, L, "Left" } } do
		local ik, offset, side = s[1], s[2], s[3]
		local pole = up:FindFirstChild("WeaponKitPole" .. side)
		if offset and pole then
			pole.Position = up[side .. "ShoulderRigAttachment"].Position + offset
			ik.Pole = pole
		else
			ik.Pole = nil
		end
	end
end

-- One number per pass (lower = better): clipping means, worst cases and gun-in-body weighted up.
function A.score(rows)
	local n, up, fo, arm, upMax, foMax, bodyMax = #rows, 0, 0, 0, 0, 0, 0
	for _, r in rows do
		up, fo, arm = up + r.upArm, fo + r.fore, arm + r.gunArm
		upMax, foMax, bodyMax = math.max(upMax, r.upArm), math.max(foMax, r.fore), math.max(bodyMax, r.gunBody)
	end
	return (up + fo) / n + 0.5 * (upMax + foMax) + 0.5 * arm / n + 5 * bodyMax
end

-- Background jobs: a long search runs inside Studio while the caller polls, so one tool call never
-- has to wait for it. A.job(name, fn) starts fn(log); A.poll(name) -> status, log lines, result.
A.jobs = A.jobs or {}
function A.job(name, fn)
	local j = { status = "running", log = {}, started = os.clock() }
	A.jobs[name] = j
	task.spawn(function()
		local ok, result = pcall(fn, function(line)
			table.insert(j.log, string.format("[%3.0fs] %s", os.clock() - j.started, line))
		end)
		j.status, j.result = if ok then "done" else "error: " .. tostring(result), result
	end)
	return name .. " started"
end
function A.poll(name)
	local j = A.jobs[name]
	if not j then
		return "no job " .. name
	end
	return j.status .. "\n" .. table.concat(j.log, "\n")
end

-- Pole search for one gun: right pole over candR (left at L0), then left over candL (right at the
-- best), each scored on the train aims; then the winner vs no poles on held-out aims, `repeats` times.
function A.poleSearch(gun, candR, candL, L0, train, held, settle, repeats, log)
	A.equip(gun)
	task.wait(1)
	local function run(R, L, aims)
		A.setPoles(R, L)
		A.pass(gun, aims[1], aims[2], settle)
		return A.score(A.rows[gun]), A.rows[gun]
	end
	local bestR, bestS = nil, math.huge
	for _, R in candR do
		local s = run(R, L0, train)
		log(string.format("%s R %s L %s score %.1f", gun, tostring(R), tostring(L0), s))
		if s < bestS then
			bestR, bestS = R, s
		end
	end
	local bestL = L0
	for _, L in candL do
		local s = run(bestR, L, train)
		log(string.format("%s R %s L %s score %.1f", gun, tostring(bestR), tostring(L), s))
		if s < bestS then
			bestL, bestS = L, s
		end
	end
	local function summary(rows)
		local up, fo, upMax, foMax, bodyMax = 0, 0, 0, 0, 0
		for _, r in rows do
			up, fo = up + r.upArm, fo + r.fore
			upMax, foMax, bodyMax = math.max(upMax, r.upArm), math.max(foMax, r.fore), math.max(bodyMax, r.gunBody)
		end
		return string.format("up %.1f/%.1f fore %.1f/%.1f body max %.1f", up / #rows, upMax, fo / #rows, foMax, bodyMax)
	end
	for k = 1, repeats do
		local s0, rows0 = run(false, false, held)
		local t0 = summary(rows0)
		local s1, rows1 = run(bestR, bestL, held)
		log(string.format("%s held-out #%d: no poles %.1f (%s) | poles %.1f (%s)", gun, k, s0, t0, s1, summary(rows1)))
	end
	return { R = bestR, L = bestL, score = bestS }
end

function A.clear()
	local gui = p.PlayerGui:FindFirstChild("PoseAuditSheet")
	if gui then
		gui:Destroy()
	end
	A.hideUi(false)
	cam.CameraType = Enum.CameraType.Custom
	A.anchor(false)
end

return "pose_audit loaded"
