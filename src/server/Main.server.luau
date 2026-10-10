--!nonstrict
-- Server entry point. The order matters: PlayerData first (everything else reads a player's
-- saved ammo through it), the map before anyone can spawn, the weapon remotes before the Tools
-- that use them. Suspicion (the shared flag counter) loads with the first module that needs it.
print("[WeaponKit] server started")

local PlayerData = require(script.Parent.PlayerData)
local Range = require(script.Parent.Range)
local WeaponServer = require(script.Parent.WeaponServer)
local Tools = require(script.Parent.Tools)
local Dummies = require(script.Parent.Dummies)
local Movement = require(script.Parent.Movement)
local LabQuery = require(script.Parent.LabQuery)

PlayerData.init() -- first: the other modules read a player's data through it
Range.build() -- the map, the spawn and the ammo crate (before anyone spawns)
WeaponServer.init() -- the Fire / Reload remotes; refuses shots until a player's data is loaded
Tools.init() -- builds the weapon Tools and gives them on every spawn
Dummies.init(Range.TARGETS)
if #Range.LAB_TARGETS > 0 then
	Dummies.init(Range.LAB_TARGETS) -- the exploit lab's wallbang dummy (demo only)
end
Movement.init() -- server movement checks: speed, teleport, fly, jump, noclip, fling
LabQuery.init() -- demo only: lets the exploit lab ask what the server sees

print("[WeaponKit] ready")
