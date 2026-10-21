---------------------------------------------------------------- pose: what other players' clients are told
-- client/Pose.luau runs on clients only (no harness for it: Studio is its test). The server half is
-- here: the Aim remote -> "WeaponKitAim" attribute, the "WeaponKitReloading" attribute and the shooter
-- in FireFX. All of it is cosmetic: none of it may ever change a shot.
section("Pose: aim and reload attributes for other clients (cosmetic only)")
do
	local errorsAtStart = #taskErrors
	local Suspicion = require_(server.Suspicion)
	local aimR = remotes.Aim
	check(aimR ~= nil, "the Aim remote exists")
	local susBefore = Suspicion.total(p1)

	local c = makeCharacter(p1, vec(0, 5, 0))
	advance(2) -- a full rate-limit budget
	aimR.OnServerEvent:fire(p1, 12.4, -30.6)
	local v = c:GetAttribute("WeaponKitAim")
	check(typeofMock(v) == "Vector2" and v.X == 12 and v.Y == -31, "pitch/yaw become a Vector2 attribute in whole degrees")

	local junk = {
		{ 0 / 0, 0 },
		{ 0, 0 / 0 },
		{ 91, 0 },
		{ -91, 0 },
		{ 0, 181 },
		{ math.huge, 0 },
		{ "10", 0 },
		{ vec(1, 2, 3), 0 },
		{ nil, nil },
		{ 10, nil },
	}
	for _, args in junk do
		advance(0.2)
		aimR.OnServerEvent:fire(p1, args[1], args[2])
	end
	v = c:GetAttribute("WeaponKitAim")
	check(v.X == 12 and v.Y == -31, "NaN, inf, out-of-range, missing and wrong-typed values are ignored")

	advance(2)
	for i = 1, 100 do
		aimR.OnServerEvent:fire(p1, i % 80, 0)
	end
	eq(c:GetAttribute("WeaponKitAim").X, 15, "a flood of 100 in one instant stops at the burst of 15")
	eq(Suspicion.total(p1), susBefore, "...and is not flagged: the remote is cosmetic")

	p1.Character = nil
	advance(2)
	aimR.OnServerEvent:fire(p1, 5, 5)
	eq(#taskErrors, errorsAtStart, "no character: ignored without an error")

	-- Reloading: set when the server starts a reload, cleared when it ends or is cancelled.
	local c2 = makeCharacter(p1, vec(0, 5, 0))
	local data = PlayerData.get(p1)
	data.mags.Pistol, data.reserve.Pistol = 3, 30
	local tool = new("Tool", "Pistol")
	tool.Parent = c2
	advance(2)
	reloadR.OnServerEvent:fire(p1)
	eq(c2:GetAttribute("WeaponKitReloading"), true, "a reload sets WeaponKitReloading")
	advance(Weapons.Defs.Pistol.reloadTime + 0.1)
	eq(c2:GetAttribute("WeaponKitReloading"), nil, "...the finished reload clears it")
	eq(data.mags.Pistol, 15, "...and the magazine is full (the attribute changed nothing)")

	data.mags.Pistol = 3
	advance(1)
	reloadR.OnServerEvent:fire(p1)
	eq(c2:GetAttribute("WeaponKitReloading"), true, "a second reload sets it again")
	tool.Parent = nil
	eq(c2:GetAttribute("WeaponKitReloading"), nil, "putting the weapon away mid-reload clears it")
	advance(Weapons.Defs.Pistol.reloadTime + 0.1)
	eq(c2:GetAttribute("WeaponKitReloading"), nil, "...and the cancelled reload's timer doesn't set it back")

	-- FireFX names the shooter so other clients can play its recoil kick.
	local p2 = makePlayer("PoseWatcher", 4242)
	local c3 = makeCharacter(p2, vec(5, 5, 0))
	tool = new("Tool", "Pistol")
	tool.Parent = c2
	data.mags.Pistol = 10
	advance(2)
	local savedRay = rayHandler
	rayHandler = function()
		return nil
	end
	local fxBefore = #fxR.fired
	fire(p1, vec(0, 5, -1), vec(0, 0, -1), 2 ^ 31 - 5)
	rayHandler = savedRay
	local toWatcher
	for i = fxBefore + 1, #fxR.fired do
		if fxR.fired[i].player == p2 then
			toWatcher = fxR.fired[i]
		end
	end
	check(toWatcher ~= nil and toWatcher.args[5] == p1, "FireFX tells the watcher who fired (sent " .. (#fxR.fired - fxBefore) .. ")")

	p2.Parent = nil
	Players.PlayerRemoving:fire(p2)
	table.remove(Players.list, table.find(Players.list, p2))
	c3.Parent = nil
	tool.Parent = nil
	eq(#taskErrors, errorsAtStart, "Pose: no task threw an error")
end

section("Whole suite: the movement checks never crashed")
eq(#MOVEMENT_ERRORS, 0, "no Movement sample threw an error in the whole run" .. (MOVEMENT_ERRORS[1] and (" (first: " .. MOVEMENT_ERRORS[1] .. ")") or ""))
