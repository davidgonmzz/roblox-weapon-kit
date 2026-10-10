--!nonstrict
-- The kit's client API, for your own GUI or LocalScripts. CLIENT ONLY: require it from a LocalScript
-- (a server Script gets its own, unconnected copy). Every LocalScript on a client gets the same table,
-- so you can connect from anywhere, even before the kit's client has started.
--
--   local WeaponKit = require(game.ReplicatedStorage.WeaponKitShared.ClientApi)
--
-- Signals (RBXScriptSignals: :Connect / :Once / :Wait):
--   WeaponKit.WeaponChanged(name: string?)                  weapon taken out (name) or put away (nil)
--   WeaponKit.AmmoChanged(name, mag, reserve?, reloading)   any weapon's ammo changed; reserve nil = not known yet
--   WeaponKit.Fired(name)                                   you fired a shot (sent to the server)
--   WeaponKit.Hit(damage, headshot, killed)                 the server confirmed one of your shots hurt someone
--
-- Functions (do nothing until the kit's client has started; isReady() tells):
--   WeaponKit.equip(name)  /  WeaponKit.unequip()  /  WeaponKit.toggle(name)   take out / put away
--   WeaponKit.reload()                                      same as pressing R
--   WeaponKit.held() -> name?                               weapon in hand
--   WeaponKit.ammo(name) -> mag, reserve?, reloading        what the client believes (the server decides)
--   WeaponKit.isReady() -> boolean
--
-- The weapon list (names, slots, colours, magazine sizes) is WeaponKitShared.Weapons (Order and Defs).
-- Set Config.HUD = false to hide the kit's own HUD and draw your own from these.

local ClientApi = {}

local events = {}
for _, name in { "WeaponChanged", "AmmoChanged", "Fired", "Hit" } do
	local event = Instance.new("BindableEvent")
	events[name] = event
	ClientApi[name] = event.Event
end

local impl -- the kit's WeaponClient functions, set by attach()

function ClientApi.isReady(): boolean
	return impl ~= nil
end

function ClientApi.equip(name: string)
	if impl and type(name) == "string" then
		impl.equip(name)
	end
end

function ClientApi.unequip()
	if impl then
		impl.unequip()
	end
end

function ClientApi.toggle(name: string)
	if impl and type(name) == "string" then
		impl.toggle(name)
	end
end

function ClientApi.reload()
	if impl then
		impl.reload()
	end
end

function ClientApi.held(): string?
	return if impl then impl.held() else nil
end

function ClientApi.ammo(name: string): (number?, number?, boolean?)
	if impl and type(name) == "string" then
		return impl.ammo(name)
	end
	return nil, nil, nil
end

-- Kit internal: WeaponClient hands over its functions and gets the BindableEvents to fire.
function ClientApi._attach(functions)
	impl = functions
	return events
end

return ClientApi
