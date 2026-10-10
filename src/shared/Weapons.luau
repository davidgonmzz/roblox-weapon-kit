--!strict
-- Weapon stats: pure data, no logic. The server resolves shots from these numbers
-- (server/WeaponServer.luau), the client reads them for its fire-rate gate, HUD and recoil
-- (client/WeaponClient.luau). The key of each entry is also the Tool's name.
--
-- ADDING A WEAPON = adding one entry to DEFS below (give it a free `slot`). The Tool is built
-- from `color` and the key by server/Tools.luau, the HUD slot, number key, save-data reserve and
-- ammo crate refill all follow automatically.

export type Weapon = {
	name: string, -- display name (HUD, tooltip)
	slot: number, -- number key that equips it, and its place in the HUD bar. Keep unique
	mode: "semi" | "auto", -- semi: one shot per click (pump-actions too); auto: hold to keep firing
	damage: number, -- per pellet, before the headshot multiplier
	headshotMultiplier: number, -- applied when the hit part is named "Head"
	pellets: number, -- projectiles per trigger pull. The SERVER rolls each one
	rpm: number, -- rounds per minute: the fastest rate the server accepts
	magazine: number,
	reserveMax: number, -- spare rounds a player can carry (the ammo crate refills to this)
	startReserve: number, -- spare rounds in a brand-new save
	reloadTime: number, -- seconds
	range: number, -- studs
	spread: number, -- degrees: half-angle of the random cone the SERVER applies to every pellet
	recoil: number, -- degrees of camera kick per shot. Client only, never sent to the server
	color: Color3, -- accent colour of the model, tracers, HUD
}

local DEFS: { [string]: Weapon } = {
	Pistol = {
		name = "PISTOL",
		slot = 1,
		mode = "semi",
		damage = 20,
		headshotMultiplier = 2,
		pellets = 1,
		rpm = 300,
		magazine = 15,
		reserveMax = 90,
		startReserve = 60,
		reloadTime = 1.6,
		range = 300,
		spread = 0.6,
		recoil = 1.2,
		color = Color3.fromRGB(255, 184, 76),
	},
	Rifle = {
		name = "RIFLE",
		slot = 2,
		mode = "auto",
		damage = 14,
		headshotMultiplier = 2,
		pellets = 1,
		rpm = 600,
		magazine = 30,
		reserveMax = 180,
		startReserve = 120,
		reloadTime = 2.3,
		range = 500,
		spread = 1.1,
		recoil = 0.9,
		color = Color3.fromRGB(90, 200, 255),
	},
	Shotgun = {
		name = "SHOTGUN",
		slot = 3,
		mode = "semi", -- a pump-action: rpm 70 is the time it takes to rack the pump
		damage = 11,
		headshotMultiplier = 1.5,
		pellets = 8,
		rpm = 70,
		magazine = 6,
		reserveMax = 36,
		startReserve = 24,
		reloadTime = 2.8,
		range = 120,
		spread = 5,
		recoil = 4.5,
		color = Color3.fromRGB(255, 96, 96),
	},
}

-- Weapon names sorted by slot: the order of the HUD bar and the number keys.
local order: { string } = {}
for name in DEFS do
	table.insert(order, name)
end
table.sort(order, function(a, b)
	return DEFS[a].slot < DEFS[b].slot
end)

return {
	Defs = DEFS,
	Order = order,
}
