---------------------------------------------------------------- clock + tasks
local now = 100
local fakeOs = { clock = function() return now end }
local delayed = {}
local taskErrors = {}
local task = {
	spawn = function(fn, ...) local co = coroutine.create(fn); local ok, err = coroutine.resume(co, ...); if not ok then table.insert(taskErrors, tostring(err)) end return co end,
	delay = function(t, fn) table.insert(delayed, { at = now + t, fn = fn }) end,
	wait = function(t) return t end,
}
local function advance(dt)
	now += dt
	local i = 1
	table.sort(delayed, function(a, b) return a.at < b.at end)
	while delayed[i] do
		if delayed[i].at <= now then
			local d = table.remove(delayed, i)
			d.fn()
		else
			i += 1
		end
	end
end

---------------------------------------------------------------- Vector3
local V3 = { __type = "Vector3" }
local function vec(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V3) end
V3.__index = function(v, k)
	if k == "Dot" then return function(self, o) return self.X * o.X + self.Y * o.Y + self.Z * o.Z end end
	if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
	if k == "Unit" then local m = v.Magnitude; return vec(v.X / m, v.Y / m, v.Z / m) end
	return nil
end
V3.__unm = function(a) return vec(-a.X, -a.Y, -a.Z) end
V3.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__mul = function(a, b)
	if type(a) == "number" then return vec(a * b.X, a * b.Y, a * b.Z) end
	if type(b) == "number" then return vec(a.X * b, a.Y * b, a.Z * b) end
	return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__div = function(a, b)
	if type(b) == "number" then return vec(a.X / b, a.Y / b, a.Z / b) end
	return vec(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
local Vector3 = { new = vec, zero = vec(0, 0, 0), one = vec(1, 1, 1) }
-- CFrame: only a position; `cf + v` moves it (the kit shifts a remembered CFrame that way).
local CF = {}
CF.__add = function(cf, v) return setmetatable({ Position = cf.Position + v }, CF) end
local CFrame = { new = function(x, y, z) return setmetatable({ Position = vec(x, y, z) }, CF) end }
local function typeofMock(v)
	local mt = type(v) == "table" and getmetatable(v)
	if mt and mt.__type then return mt.__type end
	return type(v)
end

---------------------------------------------------------------- signals + instances
local function newSignal()
	local s = { handlers = {} }
	function s.Connect(self, fn)
		table.insert(self.handlers, fn)
		return { Disconnect = function()
			local i = table.find(self.handlers, fn)
			if i then table.remove(self.handlers, i) end
		end }
	end
	function s.Once(self, fn) return s.Connect(self, fn) end
	function s.fire(self, ...) for _, h in table.clone(self.handlers) do h(...) end end
	return s
end
-- Property-changed signals (GetPropertyChangedSignal). Only a SERVER write fires one: PivotTo, MoveTo,
-- serverSet. A client move is a plain field change and fires nothing (measured in Studio). With
-- deferSignals on, a fired signal waits in pendingSignals until flushSignals(), like Workspace
-- SignalBehavior = Deferred: the handler then sees the value as it is at flush time.
local deferSignals = false
local pendingSignals = {}
-- Velocity properties: a write fires the signal only while serverWriting is on (serverSet turns it on, and
-- so does a test around the kit's own Heartbeat): a plain assignment in a test is "the client's physics".
local serverWriting = false
local VELOCITY_KEYS = { AssemblyLinearVelocity = "_lin", AssemblyAngularVelocity = "_ang" }
local function firePropertySignal(inst, prop)
	local sigs = rawget(inst, "propSignals")
	local s = sigs and sigs[prop]
	if not s then return end
	if deferSignals then table.insert(pendingSignals, s) else s:fire() end
end
local function flushSignals()
	while #pendingSignals > 0 do table.remove(pendingSignals, 1):fire() end
end
-- A server script writing a property (instance[prop] = value on the server): sets it and fires the signal.
local function serverSet(inst, prop, value)
	local saved = serverWriting
	serverWriting = true
	inst[prop] = value -- (a velocity fires its own signal from the proxy below)
	serverWriting = saved
	if prop == "CFrame" then inst.Position = value.Position end
	if not VELOCITY_KEYS[prop] then firePropertySignal(inst, prop) end
end
local Inst = {}
local classIs = {
	Tool = { Tool = true, Instance = true }, Model = { Model = true, Instance = true },
	Part = { Part = true, BasePart = true, Instance = true }, Humanoid = { Humanoid = true, Instance = true },
	Folder = { Folder = true, Instance = true }, RemoteEvent = { RemoteEvent = true, Instance = true },
}
local function subtreeOf(inst, out)
	table.insert(out, inst)
	for _, c in inst.children do subtreeOf(c, out) end
	return out
end
local function fireDescendantSignal(from, signalName, inst)
	local a = from
	while a do
		local sig = rawget(a, signalName)
		if sig and #sig.handlers > 0 then
			for _, d in subtreeOf(inst, {}) do sig:fire(d) end
		end
		a = rawget(a, "_parent")
	end
end
local function setParent(self, p)
	local old = rawget(self, "_parent")
	if old then
		fireDescendantSignal(old, "DescendantRemoving", self) -- (fires before the instance goes)
		for i, c in old.children do if c == self then table.remove(old.children, i) break end end
		old.ChildRemoved:fire(self)
	end
	rawset(self, "_parent", p)
	if p then
		table.insert(p.children, self); p.ChildAdded:fire(self)
		fireDescendantSignal(p, "DescendantAdded", self)
	end
end
Inst.__index = function(t, k)
	if k == "Parent" then return rawget(t, "_parent") end
	if VELOCITY_KEYS[k] then return rawget(t, VELOCITY_KEYS[k]) end
	if Inst[k] ~= nil then return Inst[k] end
	for _, c in rawget(t, "children") do if c.Name == k then return c end end
	return nil
end
Inst.__newindex = function(t, k, v)
	if k == "Parent" then setParent(t, v)
	elseif VELOCITY_KEYS[k] then
		rawset(t, VELOCITY_KEYS[k], v)
		if serverWriting then firePropertySignal(t, k) end
	else rawset(t, k, v) end
end
local function new(class, name)
	local o = setmetatable({ ClassName = class, Name = name or class, children = {}, tags = {}, attrs = {},
		ChildAdded = newSignal(), ChildRemoved = newSignal(), OnServerEvent = newSignal(), fired = {},
		DescendantAdded = newSignal(), DescendantRemoving = newSignal() }, Inst)
	if class == "Part" or class == "TrussPart" then o.AssemblyLinearVelocity = vec(0, 0, 0) end
	return o
end
function Inst.IsA(self, c) return (classIs[self.ClassName] or { [self.ClassName] = true })[c] == true end
function Inst.GetChildren(self) return table.clone(self.children) end
function Inst.FindFirstChild(self, n) for _, c in self.children do if c.Name == n then return c end end return nil end
function Inst.FindFirstChildOfClass(self, cls) for _, c in self.children do if c.ClassName == cls then return c end end return nil end
function Inst.FireClient(self, player, ...) table.insert(self.fired, { player = player, args = { ... } }) end
function Inst.SetAttribute(self, k, v) self.attrs[k] = v end
function Inst.HasTag(self, tag) return self.tags[tag] == true end
function Inst.WaitForChild(self, n) return self:FindFirstChild(n) end
function Inst.IsDescendantOf(self, ancestor)
	local p = rawget(self, "_parent")
	while p do if p == ancestor then return true end p = rawget(p, "_parent") end
	return false
end
function Inst.FindFirstAncestorOfClass(self, cls)
	local p = rawget(self, "_parent")
	while p do if p.ClassName == cls then return p end p = rawget(p, "_parent") end
	return nil
end
function Inst.PivotTo(self, cf)
	local hrp = self:FindFirstChild("HumanoidRootPart")
	if hrp then hrp.CFrame = cf; hrp.Position = cf.Position; firePropertySignal(hrp, "CFrame") end
	self.pivots = (self.pivots or 0) + 1
end
function Inst.MoveTo(self, position) self:PivotTo(CFrame.new(position.X, position.Y, position.Z)) end
function Inst.GetDescendants(self)
	local out = subtreeOf(self, {})
	table.remove(out, 1)
	return out
end
function Inst.GetAttribute(self, k) return self.attrs[k] end
function Inst.GetNetworkOwner(self) return self.owner end -- nil = the server (set .owner = player for a client-owned part)
function Inst.GetPropertyChangedSignal(self, prop)
	local sigs = rawget(self, "propSignals")
	if not sigs then sigs = {}; rawset(self, "propSignals", sigs) end
	if not sigs[prop] then sigs[prop] = newSignal() end
	return sigs[prop]
end
function Inst.TakeDamage(self, d) self.Health = math.max(0, self.Health - d) end
local function child(parent, o) o.Parent = parent; return o end

---------------------------------------------------------------- services
local Players = new("Players", "Players")
Players.list = {}
Players.PlayerAdded = newSignal()
Players.PlayerRemoving = newSignal()
function Players.GetPlayers(self) return self.list end
function Players.GetPlayerFromCharacter(self, model)
	for _, p in self.list do if p.Character == model then return p end end
	return nil
end
local ReplicatedStorage = new("ReplicatedStorage")
local RunService = new("RunService", "RunService")
RunService.Heartbeat = newSignal()
local Workspace = new("Workspace", "Workspace")
Workspace.Gravity = 196.2
Workspace.Terrain = { ReadVoxels = function() return {} end }
local rayCalls = {}
local rayHandler = function() return nil end
function Workspace.Raycast(self, origin, dir, params)
	table.insert(rayCalls, { origin = origin, dir = dir, filter = params.FilterDescendantsInstances })
	return rayHandler(origin, dir, params)
end
function Workspace.GetPartBoundsInRadius() return {} end
-- Every mock part (has a Position and a Size, treated as an axis-aligned box) whose box touches the
-- sphere, skipping anything in or under an instance of the Exclude filter.
local function realPartBounds(self, position, radius, params)
	local excluded = params and params.FilterDescendantsInstances or {}
	local found = {}
	for _, inst in Workspace:GetDescendants() do
		local center, size = rawget(inst, "Position"), rawget(inst, "Size")
		if center and size then
			local skip, a = false, inst
			while a do
				if table.find(excluded, a) then skip = true break end
				a = rawget(a, "_parent")
			end
			if not skip then
				local d2 = 0
				for _, axis in { "X", "Y", "Z" } do
					local gap = math.max(math.abs(position[axis] - center[axis]) - size[axis] / 2, 0)
					d2 += gap * gap
				end
				if d2 <= radius * radius then table.insert(found, inst) end
			end
		end
	end
	return found
end
local blockHandler = function() return nil end
function Workspace.Blockcast(self, cframe, size, dir, params)
	return blockHandler(cframe, size, dir, params)
end
local CollectionService = {
	HasTag = function(self, inst, tag) return inst.tags[tag] == true end,
	AddTag = function(self, inst, tag) inst.tags[tag] = true end,
}
local Services = { Players = Players, ReplicatedStorage = ReplicatedStorage, Workspace = Workspace, CollectionService = CollectionService, RunService = RunService }
local game = { GetService = function(self, n) return assert(Services[n], "service " .. n) end }
local Enum = setmetatable({}, { __index = function(_, k) return setmetatable({}, { __index = function(_, k2) return k .. "." .. k2 end }) end })
local Instance = { new = function(class) return new(class) end }
local Random = { new = function() return { NextNumber = function() return 0.5 end } end }
local RaycastParams = { new = function() return {} end }
local OverlapParams = { new = function() return {} end }
local Color3 = { fromRGB = function() return {} end }
local Region3 = { new = function(a, b) local r = {}; function r.ExpandToGrid(self) return self end; return r end }
local warns = {}
local function warn(...) table.insert(warns, table.concat({ ... }, " ")) end

---------------------------------------------------------------- module loader
local cache = {}
local function module(name, srcKey, value)
	local m = new("ModuleScript", name)
	m.srcKey = srcKey
	m.value = value
	return m
end
local require_
function require_(inst)
	if inst.value ~= nil then return inst.value end
	if cache[inst] ~= nil then return cache[inst] end
	local f, err = loadstring("local script, os, typeof, require, game, task, Enum, Instance, Vector3, Random, RaycastParams, OverlapParams, warn, Color3, CFrame, Region3 = ...; " .. SOURCES[inst.srcKey], inst.srcKey)
	assert(f, err)
	local v = f(inst, fakeOs, typeofMock, require_, rawget(inst, "gameOverride") or game, task, Enum, Instance, Vector3, Random, RaycastParams, OverlapParams, warn, Color3, CFrame, Region3)
	cache[inst] = v
	return v
end

local shared = child(ReplicatedStorage, new("Folder", "Shared"))
child(shared, module("Config", "shared/Config"))
child(shared, module("Weapons", "shared/Weapons"))
child(shared, module("Ballistics", nil, { spread = function(d) return d end }))
local server = new("Folder", "Server")
child(server, module("WeaponServer", "server/WeaponServer"))
child(server, module("PlayerData", "server/PlayerData"))
child(server, module("RateLimit", "server/RateLimit"))
child(server, module("Suspicion", "server/Suspicion"))
child(server, module("AimStats", "server/AimStats"))
child(server, module("Movement", "server/Movement"))
child(server, module("LabQuery", "server/LabQuery"))
local vendor = child(server, new("Folder", "Vendor"))
local fakeStore = { DataStoreState = "Access" }
function fakeStore.New(name, template)
	return { StartSessionAsync = function(self, key, opts)
		if fakeStore.intercept then
			local handled, result = fakeStore.intercept(key, opts)
			if handled then return result end
		end
		local function deep(t) local c = {} for k, v in t do c[k] = type(v) == "table" and deep(v) or v end return c end
		local profile = { Data = deep(template), OnSessionEnd = newSignal() }
		if fakeStore.mutate then fakeStore.mutate(profile.Data) end
		function profile.AddUserId() end
		function profile.Reconcile() end
		function profile.EndSession() end
		return profile
	end }
end
child(vendor, module("ProfileStore", nil, fakeStore))

---------------------------------------------------------------- test helpers
local failures, passes = 0, 0
local results = {}
local curSection = "General"
local function section(title) curSection = title end
local function check(cond, msg)
	if cond then passes += 1 else failures += 1 end
	table.insert(results, { section = curSection, msg = msg, ok = cond })
	if not cond then print("FAIL: " .. msg) end
end
local function eq(a, b, msg) check(a == b, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end
-- Prints a human-readable report of every named scenario, grouped by what it defends. This is what
-- a buyer reads to see exactly what the kit is tested against.
local function report()
	local order, bySection = {}, {}
	for _, r in results do
		if not bySection[r.section] then
			bySection[r.section] = {}
			table.insert(order, r.section)
		end
		table.insert(bySection[r.section], r)
	end
	print("\n================  WEAPON KIT: WHAT THE TESTS PROVE  ================")
	for _, sec in order do
		local list = bySection[sec]
		local pass = 0
		for _, r in list do
			if r.ok then pass += 1 end
		end
		print(string.format("\n[%s]  (%d/%d)", sec, pass, #list))
		for _, r in list do
			print("   " .. (r.ok and "[PASS] " or "[FAIL] ") .. r.msg)
		end
	end
	print("\n-------------------------------------------------------------------")
	print(string.format("TOTAL: %d checks  |  %d passed  |  %d failed", passes + failures, passes, failures))
	print("===================================================================\n")
end

local function makePlayer(name, id)
	local p = new("Player", name)
	p.UserId = id
	p.CharacterAdded = newSignal()
	p.CharacterRemoving = newSignal()
	p.GetNetworkPing = function() return 0.05 end
	p.Kick = function() end
	p.GetRankInGroup = function() return 0 end
	p.Parent = Players
	table.insert(Players.list, p)
	return p
end
local function makeCharacter(p, headPos)
	local c = new("Model", p.Name .. "Char")
	local hum = child(c, new("Humanoid")); hum.Health = 100; hum.MaxHealth = 100
	local head = child(c, new("Part", "Head")); head.Position = headPos
	local hrp = child(c, new("Part", "HumanoidRootPart")); hrp.Position = headPos
	p.Character = c
	p.CharacterAdded:fire(c)
	return c
end
local function makeDummy(name)
	local m = new("Model", name)
	local hum = child(m, new("Humanoid")); hum.Health = 100; hum.MaxHealth = 100
	local head = child(m, new("Part", "Head"))
	local torso = child(m, new("Part", "Torso"))
	m.tags["WeaponKitTarget"] = true
	m.Parent = Workspace
	return m, hum, head, torso
end

local WeaponServer = require_(server.WeaponServer)
local PlayerData = require_(server.PlayerData)
local Weapons = require_(shared.Weapons)
local p1 = makePlayer("P1", 1)
PlayerData.init()
WeaponServer.init()
local remotes = ReplicatedStorage.Remotes
local fireR, reloadR, ammoR, fxR, hitR, rejR = remotes.Fire, remotes.Reload, remotes.AmmoSync, remotes.FireFX, remotes.HitConfirm, remotes.Rejected
local function fire(player, origin, dir, id) fireR.OnServerEvent:fire(player, origin, dir, id) end
local function last(remote) local f = remote.fired[#remote.fired]; return f and f.args end

section("WeaponServer: server-authoritative fire, damage, ammo, targets & fire-rate")
local data = PlayerData.get(p1)
check(data ~= nil, "data loaded")
eq(data.reserve.Pistol, 60, "start reserve pistol"); eq(data.reserve.Rifle, 120, "rifle"); eq(data.reserve.Shotgun, 24, "shotgun")
eq(data.loadout, "Pistol", "default loadout")

local char = makeCharacter(p1, vec(0, 5, 0))
local pistol = new("Tool", "Pistol")
pistol.Parent = char
local a = last(ammoR)
check(a and a[1] == "Pistol" and a[2] == 15 and a[3] == 60 and a[4] == false and a[5] == 0, "AmmoSync on equip")

local dummy, dhum, dhead, dtorso = makeDummy("Dummy1")
rayHandler = function(origin, dir) return { Position = vec(0, 5, -10), Instance = dhead } end

-- A: legit headshot
fire(p1, vec(0, 5, -1), vec(0, 0, -1), 1)
a = last(ammoR); check(a and a[2] == 14 and a[5] == 1, "A: mag 14, lastId 1")
local h = last(hitR); check(h and h[1] == 40 and h[2] == true and h[3] == false, "A: HitConfirm 40 headshot")
eq(dhum.Health, 60, "A: dummy health")
eq(data.stats.shots, 1, "A: shots"); eq(data.stats.hits, 1, "A: hits")
eq(p1.attrs.Shots, 1, "A: attribute")

-- B: 10 shots in the same instant -> all refused, but not reported: one burst looks like a lag spike
-- (sustained rapid fire IS reported: see "Integration / combat: fire rate")
local rejBefore = #rejR.fired
for id = 2, 11 do fire(p1, vec(0, 5, -1), vec(0, 0, -1), id) end
eq(#rejR.fired, rejBefore, "B: a one-off burst is not reported")
a = last(ammoR); eq(a[2], 14, "B: mag unchanged (all 10 refused)")
eq(dhum.Health, 60, "B: no damage")

-- C, D, E: normal pace kills, then shooting a corpse
advance(0.25); fire(p1, vec(0, 5, -1), vec(0, 0, -1), 12); eq(dhum.Health, 20, "C: health 20")
advance(0.25); fire(p1, vec(0, 5, -1), vec(0, 0, -1), 13)
eq(dhum.Health, 0, "D: dead"); h = last(hitR); check(h and h[3] == true, "D: killed flag"); eq(data.stats.kills, 1, "D: kills")
local hitsBefore = #hitR.fired
advance(0.25); fire(p1, vec(0, 5, -1), vec(0, 0, -1), 14)
eq(#hitR.fired, hitsBefore, "E: no HitConfirm on a corpse"); eq(data.stats.hits, 3, "E: hits unchanged")
eq(last(ammoR)[2], 11, "E: mag spent anyway")

-- F: garbage args
fire(p1, vec(0 / 0, 0 / 0, 0 / 0), vec(0, 0, -1), 20)
fire(p1, vec(0, 5, -1), vec(0, 0, -1), "999")
fire(p1, vec(0, 5, -1), vec(1e9, 0, 0), 21)
fire(p1, "nope", vec(0, 0, -1), 22)
fire(p1, vec(0, 5, -1), vec(0, 0, 0), 23)
fire(p1, vec(0, 5, -1), vec(0, 0, -1), 0 / 0)
fire(p1, vec(0, 5, -1), vec(0, 0, -1), 1.5)
fire(p1, vec(0, 5, -1), vec(0, 0, -1), 12) -- replay of an old id
fire(p1, nil, nil, nil)
r = last(rejR); check(r and r[1] == "args" and r[2] == 9, "F: args x9 (got " .. tostring(r and r[2]) .. ")")
eq(last(ammoR)[2], 11, "F: mag unchanged")

-- G: fake origin 60 studs away -> shot still happens, but from the head
rayCalls = {}
advance(0.25); fire(p1, vec(0, 5, -60), vec(0, 0, -1), 30)
r = last(rejR); check(r[1] == "origin" and r[2] == 1, "G: origin x1")
local pellet = rayCalls[#rayCalls]
check(pellet and pellet.origin.X == 0 and pellet.origin.Y == 5 and pellet.origin.Z == 0, "G: pellet starts at the head")
eq(last(ammoR)[2], 10, "G: mag 10")

-- H: reload moves rounds from the reserve; fire during the reload is ignored quietly
advance(0.25)
local susBefore = last(rejR)[3]
reloadR.OnServerEvent:fire(p1)
a = last(ammoR); check(a[4] == true, "H: reloading flag")
fire(p1, vec(0, 5, -1), vec(0, 0, -1), 31)
eq(last(ammoR)[2], 10, "H: no shot while reloading"); eq(last(rejR)[3], susBefore, "H: not suspicious")
advance(1.7)
a = last(ammoR); check(a[2] == 15 and a[3] == 55 and a[4] == false, "H: reload done mag 15 reserve 55 (got " .. tostring(a[2]) .. "/" .. tostring(a[3]) .. ")")
eq(data.reserve.Pistol, 55, "H: saved reserve")

-- I: reload spam
for _ = 1, 20 do reloadR.OnServerEvent:fire(p1) end
r = last(rejR); check(r[1] == "reload" and r[2] >= 15, "I: reload flood refused (" .. tostring(r[2]) .. ")")

-- J: no reserve -> reload refuses; magazine not refilled
advance(2)
data.reserve.Pistol = 0
advance(0.25); fire(p1, vec(0, 5, -1), vec(0, 0, -1), 32)
local dummy2, dhum2, dhead2, dtorso2 = makeDummy("Dummy2")
reloadR.OnServerEvent:fire(p1)
check(last(ammoR)[4] == false, "J: not reloading without reserve")
advance(3); eq(last(ammoR)[2], 14, "J: mag still 14")

-- K: switch to the shotgun: 8 pellets, body hits, shared fire timer
data.reserve.Pistol = 60
pistol.Parent = nil
local shotgun = new("Tool", "Shotgun"); shotgun.Parent = char
eq(data.loadout, "Shotgun", "K: loadout remembered")
a = last(ammoR); check(a[1] == "Shotgun" and a[2] == 6 and a[3] == 24, "K: shotgun AmmoSync")
rayCalls = {}
rayHandler = function(origin, dir) return { Position = vec(0, 3, -10), Instance = dtorso2 } end
advance(1); fire(p1, vec(0, 5, -1), vec(0, 0, -1), 40)
eq(#rayCalls, 9, "K: 8 pellet rays + 1 origin wall check")
h = last(hitR); check(h and h[1] == 88 and h[2] == false, "K: 88 body damage (got " .. tostring(h and h[1]) .. ")")
eq(dhum2.Health, 12, "K: dummy2 health")
eq(last(ammoR)[2], 5, "K: shotgun mag 5")
advance(0.3)
fire(p1, vec(0, 5, -1), vec(0, 0, -1), 41)
eq(last(ammoR)[2], 5, "K: pump not ready -> refused, mag still 5")

-- L: swapping weapons doesn't dodge the fire rate
shotgun.Parent = nil; pistol.Parent = char
local pistolMag = data.mags.Pistol
fire(p1, vec(0, 5, -1), vec(0, 0, -1), 42)
eq(data.mags.Pistol, pistolMag, "L: pistol right after shotgun is also too fast (refused)")

-- L2: rifle shot then shotgun shot right after must be refused (shotgun interval applies)
advance(2)
pistol.Parent = nil; local rifle = new("Tool", "Rifle"); rifle.Parent = char
rayHandler = function(origin, dir) return { Position = vec(0, 3, -10), Instance = dtorso2 } end
fire(p1, vec(0, 5, -1), vec(0, 0, -1), 60)
eq(last(ammoR)[1], "Rifle", "L2: rifle fired"); eq(last(ammoR)[2], 29, "L2: rifle mag 29")
rifle.Parent = nil; shotgun.Parent = char
advance(0.09)
fire(p1, vec(0, 5, -1), vec(0, 0, -1), 61)
eq(data.mags.Shotgun, 5, "L2: shotgun 0.09 s after a rifle shot is too fast (refused)")
rifle.Parent = nil; shotgun.Parent = nil; pistol.Parent = nil
pistol.Parent = char

-- M: reload cancelled by putting the weapon away
advance(1)
reloadR.OnServerEvent:fire(p1)
check(last(ammoR)[4] == true, "M: reloading")
pistol.Parent = nil
check(last(ammoR)[4] == false, "M: cancelled on unequip")
local magBefore = last(ammoR)[2]
advance(3); eq(last(ammoR)[2], magBefore, "M: nothing moved after cancel")
pistol.Parent = char

-- N: restock
data.reserve.Pistol = 3
check(WeaponServer.restock(p1), "N: restock ok")
eq(data.reserve.Pistol, 90, "N: pistol cap"); eq(data.reserve.Rifle, 180, "N: rifle cap"); eq(data.reserve.Shotgun, 36, "N: shotgun cap")
eq(last(ammoR)[3], 90, "N: AmmoSync shows new reserve")

-- O: no weapon in hand, dead player, other player as target
pistol.Parent = nil
local sus = last(rejR)[3]
local ammoCount = #ammoR.fired
advance(1); fire(p1, vec(0, 5, -1), vec(0, 0, -1), 70)
eq(#ammoR.fired, ammoCount, "O: unarmed shot does nothing"); eq(last(rejR)[3], sus, "O: not suspicious")
pistol.Parent = char
local p2 = makePlayer("P2", 2)
local char2 = makeCharacter(p2, vec(0, 5, -10))
rayHandler = function() return { Position = vec(0, 5, -10), Instance = char2.Head } end
rayCalls = {}
advance(1); fire(p1, vec(0, 5, -1), vec(0, 0, -1), 71)
eq(char2.Humanoid.Health, 100, "O: PVP off: other player untouched")
local filtered = rayCalls[#rayCalls].filter
local hasP2 = false; for _, c in filtered do if c == char2 then hasP2 = true end end
check(hasP2, "O: other player's character is excluded from the ray")
char.Humanoid.Health = 0
advance(1); fire(p1, vec(0, 5, -1), vec(0, 0, -1), 72)
local mag = last(ammoR)[2]
advance(1); fire(p1, vec(0, 5, -1), vec(0, 0, -1), 73)
eq(last(ammoR)[2], mag, "O: dead player can't shoot")

-- P: one warn at the 25th suspicious request
check(#warns == 1, "P: exactly one warn (got " .. #warns .. ")")

section("PlayerData: corrupt / malicious save-data is repaired on load")
-- Q: corrupt save data is repaired
fakeStore.mutate = function(d)
	d.reserve = { Pistol = 9999, Rifle = -5, Shotgun = "x", Laser = 3 }
	d.loadout = "Banana"
	d.mags = { Pistol = 99, Rifle = "x", Gun9 = 1 }
	d.stats = { kills = "a", shots = 5.7 }
end
local p3 = makePlayer("P3", 3)
PlayerData.init() -- (connects again; harmless) loads p3
local d3 = PlayerData.get(p3)
check(d3 ~= nil, "Q: data for p3")
if d3 then
	eq(d3.reserve.Pistol, 90, "Q: reserve clamped to cap"); eq(d3.reserve.Rifle, 120, "Q: negative -> start"); eq(d3.reserve.Shotgun, 24, "Q: string -> start")
	eq(d3.reserve.Laser, nil, "Q: unknown weapon dropped"); eq(d3.loadout, "Pistol", "Q: bad loadout"); eq(d3.stats.kills, 0, "Q: bad kills"); eq(d3.stats.shots, 5, "Q: shots floored")
	eq(d3.stats.hits, 0, "Q: missing hits")
	eq(d3.mags.Pistol, 15, "Q: mag clamped"); eq(d3.mags.Rifle, 30, "Q: bad mag -> full"); eq(d3.mags.Shotgun, 6, "Q: missing mag -> full"); eq(d3.mags.Gun9, nil, "Q: unknown mag dropped")
end

-- R: firing at the tolerance edge (81% of the interval) must not beat the real rpm on average
advance(5)
char.Humanoid.Health = 100 -- (O killed p1)
pistol.Parent = nil; shotgun.Parent = nil; rifle.Parent = char
rayHandler = function() return nil end
data.mags.Rifle = 30
for i = 1, 20 do
	fire(p1, vec(0, 5, -1), vec(0, 0, -1), 200 + i)
	advance(0.081)
end
local acceptedN = 30 - data.mags.Rifle
-- The exact cap: one shot, plus one per interval over the span between the first and the last shot plus
-- the jitter credit (FIRE_JITTER 0.1 s). The credit is a one-off: it does not grow with the span.
local capN = math.floor(1 + (19 * 0.081 + 0.1) / 0.1)
check(acceptedN >= 12 and acceptedN <= capN, "R: real rpm at the tolerance edge (accepted " .. acceptedN .. " of 20 in 1.62 s, cap " .. capN .. ", rifle 0.1 s)")

