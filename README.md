# Weapon Kit

**A server-validated gun system for Roblox: three weapons, saved ammo, a shooting range, server-side movement checks and an exploit lab that shows the server saying no to speed hacks, fly, noclip, aimbots and more. Every part, map and target is built from code - no meshes, no Toolbox models, no asset IDs.**

[![CI](https://github.com/davidgonmzz/roblox-weapon-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/davidgonmzz/roblox-weapon-kit/actions/workflows/ci.yml)

Demo video and playable place: coming soon | [Hire me](#hire-me)

## What you get

- **Three weapons from one data file** - Pistol (semi-auto), Rifle (full-auto), Shotgun (pump, 8 pellets). A new weapon is one table entry.
- **Server authority** - the client only says "fired from here, this way". The server decides whether the shot is allowed, where it starts, where every pellet goes, what it hits and how much damage it does.
- **Real ammo** - per-weapon magazine and reserve, reloads that move rounds (never create them), all saved with ProfileStore.
- **Headshots, hit markers, damage numbers, recoil, tracers, muzzle flash, crosshair bloom, ammo HUD, weapon bar** - instant on the client, confirmed by the server.
- **A shooting range** - five lanes with 10 / 25 / 50 / 100 stud markers, cover walls, target dummies (one strafes) with health bars, an ammo crate.
- **Exploit lab (F2)** - 17 buttons in two tabs that do, with ordinary client APIs, what executor scripts like Infinite Yield do: speed hack, teleport, fly, super jump, noclip, fling, wallbang, hitbox expander, silent aim, godmode, remote fuzz and more. Each shows what the server flagged, whether it rubber-banded you, and "client set X, server still sees Y". Made for demo videos.
- **Movement anti-cheat** - the server samples every character five times a second and flags speed, teleport, fly, jump, noclip and fling; flagged players are put back at their last clean position. No kicks or bans: a hook (`Suspicion.onFlag`) is where your policy goes. It starts in log mode unless the demo panel is on (see below).
- **Works with admin systems and your own scripts** - teleports, pushes, movers and conveyors made by server code (HD Admin, Adonis, Kohl's, your own) are recognised instead of flagged; staff can be exempted. [Details](#works-with-admin-systems-and-your-own-scripts).
- **Teams and hooks** - `FRIENDLY_FIRE`, `WeaponServer.onDamage` (armour, damage caps) and `WeaponServer.onKill` (kill credit, scoreboards). [Details](#teams-damage-hooks-and-kill-credit).
- **Saves** - spare ammo, magazines, last weapon and lifetime stats survive rejoining (ProfileStore: session-locked, sanitised on load, schema-versioned).
- **Your own GUI** - a client API (four signals, a few functions) and `Config.HUD = false` to draw your own HUD. [Details](#your-own-gui-client-api).
- **Phones and gamepads** - the HUD lays itself out for touch and pad; phones get a RELOAD button. [Details](#phones-and-gamepads).
- **Your own gun models** - put models in ServerStorage; the kit welds them, finds the muzzle and warns about mistakes. [Details](#your-own-gun-models).

## How the server stays in charge

Mostly in `src/server/WeaponServer.luau`; the flag counter, the aim flags and the movement checks have their own modules (see below).

- **The client never names a weapon, a damage number, a pellet direction or a target.** The remote is `Fire(originHint, direction, shotId)`. The weapon is whichever Tool the server sees in your character's hand.
- **Types and numbers are checked first.** NaN, infinity, wrong types, absurdly long vectors and non-integer shot ids are dropped before any maths touches them.
- **Shot ids must keep rising.** A replayed or duplicated request is refused.
- **Flood guard.** A token bucket per player per remote stops spam before it reaches the game logic.
- **Fire rate is a server timer**, not a client promise. It is shared by all weapons, so swapping weapons can't dodge a fire rate. Each accepted shot books the next slot one full interval later, and a shot may arrive up to 0.1 s (or 20% of the interval, whichever is longer) before its slot, because network jitter bunches honest shots up. That credit never builds up, so no timing averages more than the rpm. Shots past it are refused; `fast` is reported only when it keeps happening (3 times within 2 s), because one lag spike delivers several honest shots in the same instant.
- **Dead players and players with nothing in hand can't shoot.**
- **Ammo is server state.** Magazine and reserve live in the saved profile. Reloading needs rounds in the reserve, moves them into the magazine, and is cancelled by putting the weapon away or dying.
- **The bullet's starting point is checked.** The client's muzzle is used only if it is within 8 studs of the real head (for a moving shooter: of where the head goes in the next 0.5 s, because the server sees a moving player slightly late) and not behind a wall; otherwise the shot starts at the head. It is only flagged when the muzzle is more than 16 studs out (past what lag can explain: a player who just started running is seen late). The check fails closed: if the server cannot read a finite head position the shot is refused (no round spent, flag `origin`). A shooter sitting in a seat (a vehicle's muzzle runs ahead of the head) is not flagged for a far muzzle, the shot just starts at the head.
- **Spread and pellets are rolled on the server.** One shotgun request becomes eight server-rolled pellets, each raycast on its own.
- **Shots at moving targets register (lag compensation).** Every player sees the others a little in the past: measured in Studio at zero ping, a moving target shows 0.2-0.35 s behind the server, and a real server adds the shooter's ping. Without help, a shot aimed dead at a running player reaches the server after they moved on and misses (in the measurement, about half of the shots at a dummy walking at half a player's speed). So the server keeps the last `ANTI_CHEAT.REWIND_TIME` seconds (0.6) of every target's position (`LagComp.luau`): when its own ray misses every target where it stands now, the same ray, with the same server-rolled spread, is tried against where each target stood in that window. It is stopped by the same walls, and a teleport wipes the trail. The client still sends nothing extra: no target, no time, no hit point. After the fix, 34 of 34 shots at the moving dummy hit in Studio, with 0 and 0.1 s of added lag.
- **Damage is server-side.** A hit part named `Head` gets the weapon's multiplier (an accessory's `Handle` is body damage). Only tagged targets take damage, and other players only when `Config.PVP` is on (team mates only with `Config.FRIENDLY_FIRE`).
- **No shooting through a target you are touching.** A muzzle pressed into a hitbox counts as a hit (a ray that starts inside a part would otherwise pass straight through).
- **One shared suspicion counter.** `Suspicion.luau` counts every flag per player and reason (refused shots, movement, aim, the crate) with one warning in the log at 25. Honest mismatches - empty magazine, mid-reload - are not counted. `Suspicion.onFlag(fn)` is the hook for your kick / ban / webhook policy; the default is none.
- **Aim flags never block a shot.** `AimStats.luau` watches the rolling headshot ratio and aim snapping and raises `aim` / `snap` flags, for review only: good players exist.
- **Movement is judged by position, not by what the client says.** `Movement.luau` compares where the character is with what the server's own `WalkSpeed`, `JumpPower` and gravity allow (details in "Exploit coverage").
- **The ammo crate re-checks everything.** Distance to the crate and a cooldown are verified on the server; the client-side prompt range is only a hint. Refilling is a server-only function.
- **Saves are cleaned on load.** Reserves and magazines are clamped to their caps, unknown weapons are dropped, a bad loadout falls back to the Pistol.
- **The explanation channel is demo-only.** The `Rejected` remote (which tells the player why they were flagged) and the lab's `LabQuery` remote exist only while `Config.DEMO_CHEAT_PANEL` is on. A real game should never explain its anti-cheat.

## File map

```
default.project.json            Rojo project of the demo place (sets the WeaponKitDemo attribute)
install.project.json            Rojo project of the release file WeaponKit.rbxm
src/
  shared/                       ReplicatedStorage.WeaponKitShared
    Config.luau                 switches: PVP, FRIENDLY_FIRE, HUD, DEMO_RANGE, DEMO_CHEAT_PANEL, DATASTORE_NAME, dummy settings,
                                ANTI_CHEAT (every movement / aim threshold and exemption, one comment each)
    Weapons.luau                weapon data (add a weapon here)
    Ballistics.luau             spread maths + which characters a shot passes through, shared by server
                                (real) and client (visual)
    ClientApi.luau              client API for your own GUI: signals + equip / reload (see "Your own GUI")
  server/                       ServerScriptService.WeaponKitServer
    Main.server.luau            install check + start-up order
    WeaponServer.luau           the authority: validation, ammo, pellets, damage, remotes, onDamage / onKill hooks
    Suspicion.luau              shared flag counter + the onFlag policy hook
    Movement.luau               speed / teleport / fly / jump / noclip / fling checks + the game API
                                (allowTeleport, grace, exempt) + recognition of server-side moves
    AimStats.luau               headshot-ratio and aim-snap flags (pure functions)
    LagComp.luau                where targets stood lately, so shots at moving targets register
    LabQuery.luau               demo only: read-only "what does the server see for me"
    PlayerData.luau             ProfileStore wrapper: template, sanitise, migrate
    RateLimit.luau              token-bucket limiter + number / Vector3 validators
    Remotes.luau                finds or creates every remote in ReplicatedStorage.WeaponKitRemotes
    Tools.luau                  builds the three Tools from Parts, gives them every spawn
    Range.luau                  map, lighting, spawn, ammo crate, the lab corner (demo only)
    Dummies.luau                R6 target dummies, health bars, respawn, strafer
    Vendor/ProfileStore.luau    third-party save library (unmodified)
  client/                       StarterPlayerScripts.WeaponKitClient
    Main.client.luau            start-up
    WeaponClient.luau           input, prediction, tracers, server answers
    Hud.luau                    crosshair, hit marker, ammo panel, weapon bar, stats
    Effects.luau                tracers, muzzle flash, impacts, camera recoil
    CheatPanel.luau             F2 exploit lab (demo only)
third_party/ProfileStore/       licence and source note
```

## Install in 30 seconds

1. Download `WeaponKit.rbxm` from the [latest release](https://github.com/davidgonmzz/roblox-weapon-kit/releases/latest).
2. Drag `WeaponKit.rbxm` into the Studio window (or right-click Workspace in the Explorer > *Insert from File...*). One folder, `WeaponKit`, appears. Leave it in the Workspace (or move it into ServerScriptService).
3. Press Play. The Output should end with `[WeaponKit] ready`, and every player spawns with the three weapons.

That is the whole install. Each time a server starts, the kit moves its three folders where they belong (`WeaponKitServer` into ServerScriptService, `WeaponKitShared` into ReplicatedStorage, `WeaponKitClient` into StarterPlayerScripts); in Studio's edit view they stay inside `WeaponKit`. The settings are in `WeaponKit > WeaponKitShared > Config`.

Your map is not touched: the kit adds no parts, no lighting and no spawn to a game (the range, dummies and crate are the demo place's, see below). If you place the three folders yourself and one ends up in the wrong spot, the kit does not start and the Output says which folder to move where. A second copy of the kit refuses to start too (it would double every shot).

Next steps in your game: tag what players may shoot with the `WeaponKitTarget` tag (other players are shot with `Config.PVP = true`), refill ammo from your own server code with `WeaponServer.restock(player)`, and read "What your game must call" below.

**The demo place (range + exploit lab).** The demo is switched on by one Workspace attribute: `WeaponKitDemo` (boolean, ticked). With it, the kit builds the shooting range (it REPLACES Studio's Baseplate and SpawnLocation), the dummies, the ammo crate and the F2 exploit lab, and the movement checks rubber-band by default. Add it to a fresh Baseplate place to try everything; never add it to your game. `rojo build default.project.json -o WeaponKit.rbxl` makes a demo place with the attribute already set.

**With Rojo (for working on the kit itself).** [Rojo 7.7](https://rojo.space) + its Studio plugin: `rojo serve` in this folder, then Plugins > Rojo > Connect in an empty Baseplate place. `default.project.json` is the demo place; `install.project.json` builds the release file (`rojo build install.project.json -o WeaponKit.rbxm`).

**Saving.** Real saving needs a published place and Game Settings > Security > *Enable Studio Access to API Services*. Without them ProfileStore switches to a mock store on its own: everything works, nothing is kept after you stop. The Output window prints `[WeaponKit] PlayerData: mock store` when that is the case.

**Controls.** Left mouse = fire (hold for the Rifle), R = reload, 1 / 2 / 3 = take out a weapon (press again to put it away), E at the crate = restock, F2 = exploit lab. Gamepad and phone controls: [Phones and gamepads](#phones-and-gamepads).

**The lab corner.** East of the spawn (x about 100) the range has a few fixtures for the lab: a 4-stud wall with a dummy behind it (wallbang), a thin wall (noclip) and a tall truss tower you can legally climb (the control test: climbing must not be flagged).

**Production.** Nothing to switch off: without the `WeaponKitDemo` attribute the range, the lab corner, the `Rejected` remote and the `LabQuery` remote are never created, and the movement checks start in `"log"` mode (they count but move nobody back) until you set `ANTI_CHEAT.MOVEMENT_ACTION = "snap"`. You may delete the demo-only modules `CheatPanel` (client) and `LabQuery`, `Range`, `Dummies` (server) to keep the folders lean; `Main` copes without them.

## Add a weapon

Add an entry to `src/shared/Weapons.luau`:

```lua
Smg = {
	name = "SMG",
	slot = 4, -- number key, and its place in the HUD bar
	mode = "auto",
	damage = 9,
	headshotMultiplier = 1.8,
	pellets = 1,
	rpm = 900,
	magazine = 35,
	reserveMax = 210,
	startReserve = 140,
	reloadTime = 2,
	range = 250,
	spread = 1.6,
	recoil = 0.6,
	color = Color3.fromRGB(180, 120, 255),
},
```

That is all the code needed. The Tool, the HUD slot, the key, the saved ammo and the crate refill all follow. The weapon gets a plain placeholder model; give it a proper one by adding a list of boxes under its name in `BUILDS` in `src/server/Tools.luau`, or use a model of your own ([Your own gun models](#your-own-gun-models)).

## Your own gun models

Every weapon starts with a plain model built from boxes. To use your own, make a Folder named `WeaponKitModels` in **ServerStorage** and put one model in it per weapon, **named exactly like the weapon's key in `Weapons.luau`** (`Pistol`, `Rifle`, `Shotgun`, or your own). A weapon with no model there keeps the built-in one. The folder is read each time a character spawns and the model is copied, so your original is never touched.

| What you put there | How it is held |
| --- | --- |
| A `Tool` with a part named `Handle` | As it is, with its `Grip` kept. |
| A `Model` or a `Part` | At its pivot, with the barrel pointing along the pivot's `LookVector` (the Front side, -Z). The kit makes an invisible `Handle` at the pivot. |

- **The muzzle.** Add an `Attachment` named `Muzzle` (or `TipAttachment`, as in Roblox's own weapon kits) at the tip of the barrel. Tracers and the shot's start point come from there. Without one, the kit puts a `Muzzle` on the model's front-most point and warns.
- **What the kit does to the copy.** Every part is made unanchored, non-colliding (`CanCollide`, `CanTouch` and `CanQuery` off, so a held gun never blocks a bullet), massless and welded to the `Handle`. Scripts inside the model are removed: the kit does the shooting.
- **How far the muzzle may be from the grip.** The server takes a shot's start up to 8 studs from the player's head, and the grip is about 2.6 studs from it, so keep the muzzle within 4.5 studs of the grip. A start further out is replaced by the head position (and flagged `origin` from 16 studs).

Mistakes are reported in the Output, once per server each, as warnings (never errors). The weapon still works: it keeps the built-in model or uses yours without the part that was wrong. Examples (`Rifle` stands for your model's name):

```
[WeaponKit] WeaponKitModels.Rilfe matches no weapon in Weapons.luau (names: Pistol, Rifle, Shotgun), so it is not used.
[WeaponKit] WeaponKitModels.Rifle has no Attachment named Muzzle: tracers start at its front-most point. Add one at the barrel tip.
[WeaponKit] WeaponKitModels.Rifle: removed 1 script(s) inside it (the kit does the shooting).
[WeaponKit] WeaponKitModels.Rifle: the Muzzle is 6.2 studs from the grip. The server takes a shot's start up to 8 studs from the head (the grip is ~2.6 from it); shots from further out start at the head (and past 16 studs are flagged 'origin'). Move the Muzzle (or the grip) closer.
```

A model that cannot be used at all (a Tool without a `Handle`, something that is not a Tool, Model or Part, or a model with Archivable off) gets its own warning ending `using the built-in model.` The start-up line `[WeaponKit] Tools ready (3 weapons, 1 own models)` counts the models it found.

## Phones and gamepads

The HUD follows the device the player is using. It reads `UserInputService.PreferredInput` (a client without that property falls back to what the device has) and lays itself out again when the device changes, for example when a pad is plugged in.

| | Keyboard and mouse | Gamepad | Phone |
| --- | --- | --- | --- |
| Fire | Left mouse (hold for the Rifle) | R2 (hold for the Rifle) | Tap the screen (Roblox's Tool activation) |
| Reload | R | X | The round RELOAD button, right edge, above the jump button |
| Switch weapon | 1 / 2 / 3, or click a slot | L1 previous, R1 next | Tap a slot in the weapon bar |
| Aim | The mouse position | The screen centre | The screen centre |
| Key hint (bottom left) | `LMB fire    R reload    1 2 3 switch` | `R2 fire    X reload    L1 R1 switch` | None (the buttons speak for themselves) |
| Empty magazine | `PRESS R` | `PRESS X` | `TAP RELOAD` |

On a phone the ammo panel moves to the top right and the weapon bar to the top left, both below Roblox's top bar and at 75% size, so the thumbstick (bottom left) and the jump button (bottom right) stay free. L1 / R1 cycle through the weapons the player has, in `Weapons.Order`. With `Config.HUD = false` the number keys and L1 / R1 are left to Roblox's hotbar and the phone has no RELOAD button (see below).

## Your own GUI (client API)

`ReplicatedStorage.WeaponKitShared.ClientApi` lets your own LocalScripts watch and drive the kit without touching its code. Require it from a **LocalScript**:

```lua
local WeaponKit = require(game.ReplicatedStorage.WeaponKitShared.ClientApi)
```

It is client only: a server Script that requires it gets its own copy, which is never connected to anything. Every LocalScript on a client gets the same table, so you can connect from anywhere, even before the kit's client has started (use `WaitForChild` if your script may run very early). Weapon names are the keys in `Weapons.luau` (`"Pistol"`, ...); `WeaponKitShared.Weapons` has `Order` and `Defs` (names, slots, colours, magazine sizes).

**Signals** (RBXScriptSignals: `:Connect`, `:Once`, `:Wait`):

| Signal | Arguments | Fires when |
| --- | --- | --- |
| `WeaponChanged` | `name: string?` | A weapon is taken out (its name) or put away (`nil`). |
| `AmmoChanged` | `name, mag, reserve?, reloading` | Any weapon's ammo changed. `reserve` is `nil` until the server has told the client. |
| `Fired` | `name` | You fired a shot (it is sent to the server). |
| `Hit` | `damage, headshot, killed` | The server confirmed that one of your shots hurt someone. |

**Functions** (they do nothing until the kit's client has started; `isReady()` tells):

| Function | What it does |
| --- | --- |
| `WeaponKit.equip(name)` | Takes that weapon out. |
| `WeaponKit.unequip()` | Puts the weapon away. |
| `WeaponKit.toggle(name)` | Takes it out, or puts it away if it is in hand (what the number keys do). |
| `WeaponKit.reload()` | Same as pressing R. |
| `WeaponKit.held()` | The name of the weapon in hand, or `nil`. |
| `WeaponKit.ammo(name)` | `mag, reserve?, reloading`: what the client believes (the server decides). |
| `WeaponKit.isReady()` | `true` once the kit's client has started. |

Example: print every ammo change and show the weapon in hand in a label.

```lua
-- LocalScript in StarterPlayerScripts
local WeaponKit = require(game.ReplicatedStorage.WeaponKitShared.ClientApi)

local gui = Instance.new("ScreenGui")
gui.ResetOnSpawn = false
gui.Parent = game.Players.LocalPlayer:WaitForChild("PlayerGui")
local label = Instance.new("TextLabel")
label.Size = UDim2.fromOffset(200, 36)
label.Position = UDim2.fromOffset(20, 120)
label.Parent = gui

WeaponKit.WeaponChanged:Connect(function(name)
	label.Text = name or "no weapon"
end)
WeaponKit.AmmoChanged:Connect(function(name, mag, reserve, reloading)
	print(name, mag, reserve, reloading)
end)
```

**Hiding the kit's HUD.** Set `HUD = false` in `Config`. The kit then shows nothing of its own (no crosshair, ammo panel, weapon bar, hit markers, stats or phone RELOAD button), leaves the mouse cursor and Roblox's own hotbar alone, and no longer handles the number keys and L1 / R1: Roblox's hotbar does. Firing and reloading (mouse, R, X, R2, a tap) work as before, shots still aim at the mouse position (the screen centre on a phone or pad), and the signals and functions above keep working. On a phone add your own reload button that calls `WeaponKit.reload()`.

## Exploit coverage

What each common exploit gets against this kit, and how to see it in the lab (F2). Statuses:
**BLOCKED** = the request is refused, **IMMUNE** = the cheat only changes the cheater's own screen and the server never trusts it, **FLAGGED** = counted for review (movement flags also undo the move: the player is put back at the last clean position), **NOT DETECTABLE** = nothing the server can see.

| Exploit | What the kit does | Lab button or test step | Honest note |
| --- | --- | --- | --- |
| Speed hack (WalkSpeed) | **FLAGGED**, snapped back (`speed`) | Movement > Speed hack | A client-set `WalkSpeed` never reaches the server; the position gives it away. The limit is WalkSpeed x 1.3 + 5 studs + a lag allowance, so a boost of +50% or less hides inside lag. Change speed on the server only. |
| Speed hack (CFrame) | **FLAGGED**, snapped back (`speed`, `teleport`) | Movement > CFrame speed | Same maths, whatever moved the root part. |
| Teleport | **FLAGGED**, snapped back (`teleport`) | Movement > Teleport | One step beyond about 30 studs is a teleport; shorter hops count as `speed`. A teleport made by a server script (`PivotTo`, `MoveTo`, admin `:tp`) is recognised and not flagged; only moves made by the player's own client are. `Movement.allowTeleport` still works and is optional. |
| Fly | **FLAGGED**, snapped back (`fly`, `jump`) | Movement > Fly | Compared with the best possible jump / fall curve, so hovers, rises and slow glides are caught after about a second. A hover within 2 studs of a floor (or half a stud past a ledge), or next to a TrussPart or tagged ladder, looks like standing. Ladders built from ordinary parts: tag them `WeaponKitClimbable` or climbing them gets flagged. |
| Super jump / infinite jump | **FLAGGED**, snapped back (`jump`) | Movement > Super jump, Infinite jump | The server's own `JumpPower` / `JumpHeight` is the reference (x 1.25 + 1.5 studs). Jump pads and launchers that push from the server (a velocity write or a mover) are recognised; client-side ones need `Movement.grace`. |
| Noclip | **FLAGGED**, snapped back (`noclip`) | Movement > Noclip | Server raycasts between the last clean position and now, repeated half a character to each side so rounding a corner fast is not a noclip, plus a "stuck inside a solid for 1.5 s" rule for thick walls. Only solid (CanCollide) parts at least about 2 studs wide count; a door that closes between two samples can cause one false flag. |
| Fling | **FLAGGED** (`fling`), velocities zeroed | Movement > Fling spin | The server cannot stop contact that happens between two samples. The player who GETS flung is flagged and snapped back too (that undoes the fling), so never punish `fling` automatically. A spin or push your own server code or an admin command applies (a velocity write) raises the fling limits to what it gave instead. The real fix is a no-collide CollisionGroup for players. |
| Rapid fire | **BLOCKED** (capped at the rpm), **FLAGGED** when sustained (`fast`) | Combat > Rapid fire 3x | Tested from 1.1x to 20x the rpm: every rate is held to the real rpm (plus at most 0.1 s worth of shots once), and 1.25x or more is reported within 2 s. A single burst is refused but not reported (it looks like a lag spike). |
| Auto-fire / auto-clicker within the rate | **NOT DETECTABLE** (and harmless) | none | The most it can do is the weapon's rpm, which a held button already does. |
| Fake bullet origin | **BLOCKED** (`origin`): the shot starts at the real head | Combat > Fake origin | A muzzle within 8 studs of the head (plus up to 0.5 s of the shooter's own movement ahead) and not behind a wall is used; anything else is replaced, and flagged past 16 studs. Seated shooters are replaced without a flag. |
| Wallbang | **IMMUNE** | Combat > Wallbang | The server raycasts; the 4-stud lab wall stops the bullet. |
| Hitbox expander | **IMMUNE** | Combat > Hitbox expander | Hits are decided against the server's hitboxes, never the client's. Keep it that way: do not add client-reported hits. |
| No spread | **IMMUNE** | Test step: Rifle at the 100-stud dummy, hits scatter | The client sends a direction; the server rolls every pellet's spread. |
| No recoil | **NOT DETECTABLE** | none | Recoil is camera-only here and changes nothing on the server. A no-recoil user just has steadier aim, which is aim. |
| Silent aim / aimbot | **FLAGGED**, never blocked (`aim`, `snap`) | Combat > Silent aim | Rolling headshot ratio, and fast aim jumps between targets that then hit. Good players trip these too: use them for review or as one weight in `Suspicion.onFlag`, not as an auto-ban. A cheater who adds misses and keeps angles small stays under them. |
| Triggerbot | **NOT DETECTABLE** at human reaction times | none | It fires when the crosshair touches a target, which a fast human also does. |
| Infinite ammo | **IMMUNE** | Test step: fire until empty, then Reload spam | Magazine and reserve are server state, saved in the profile. |
| Damage edit | **IMMUNE** | none | Damage is never sent by the client. |
| Godmode (client health) | **IMMUNE** while health is server-side | Combat > Godmode | Shows "client: 1,000,000, server: 100". If your game lets clients report damage taken, this protection is gone. |
| Remote spam / fuzz | **BLOCKED** | Combat > Remote fuzz, Reload spam, Garbage args | Token-bucket rate limits and type / range checks on every argument. The server Output must stay free of red errors. |
| Replayed or duplicated shots | **BLOCKED** (`args`) | Combat > Garbage args | Shot ids must rise on every shot. |
| Ammo crate / prompt from afar | **BLOCKED** and **FLAGGED** (`crate`) | Test step: TEST_CHECKLIST step 44 | The server re-checks the distance and a cooldown; the prompt range on the client is only a hint. |
| ESP / wallhack | **NOT DETECTABLE** | none | It only reads what the server already replicated. The only fix is not to replicate what a player should not see (StreamingEnabled, server-side visibility). This kit replicates every character to everyone. |
| Client animation abuse | **IMMUNE** for dummies, **NOT DETECTABLE** for players | none | Animations are visuals. With `PVP = true` a player's limb and head positions come from that player's client, so a cheater can reshape their own hitbox: for a real PVP game shoot a server-built hitbox (a capsule around the root part), not limb parts. |
| Tool / data dupes | **IMMUNE**: ProfileStore session lock, ammo owned by the server | Test step: needs two servers (published place) | One server owns a profile at a time. Dupes through your own trading or inventory code are out of scope. |

## Works with admin systems and your own scripts

A movement check only sees where a character is, so an admin command (`:tp`, `:bring`, `:fling`, `:speed`) looks like a cheat unless the kit knows about it. What the kit can use is that a server script leaves a trace a player's own client never does. Measured in Studio, on the server: `GetPropertyChangedSignal("CFrame")` and `("AssemblyLinearVelocity")` on the root part fire when a server script moves or pushes the character, and do **not** fire for anything the owning client does (its own teleports, spin, jumps, walking, client-made movers) or for physics; and an Instance a client creates never exists on the server, so a mover found in a character on the server was made by the server. `Config.ANTI_CHEAT.TRUST_SERVER_MOVES` (default `true`) turns that into the rules below.

**Handled automatically** (nothing to call):

| What your game does | What the kit does |
| --- | --- |
| A server script moves a player: `PivotTo`, `Model:MoveTo`, `root.CFrame = ...`, admin `:tp` / `:bring`, checkpoints, round starts | Counts like `Movement.allowTeleport`: the checks are carried along by the distance the server moved the player. Nobody is flagged or moved back for the move, and it is not time off: what the player does before and after it is still measured from where they were. A move longer than 2 studs pauses the samples for 0.6 s (`RUBBERBAND_HOLD`) while the client catches up, and then everything since is judged in one go. |
| A server script writes the root's velocity (knockback, launch pad, admin `:fling`) | That speed is added to the limits: sideways, upwards as a throw that gravity brings down, and the fling limits. It lasts `SERVER_PUSH_TIME` (1 s), and after that until the player is standing again (a long launch stays covered). It is an allowance, not a grace: a 30 studs/s knockback does not cover running at 120. |
| A server-made mover pushes the character: `BodyVelocity`, `LinearVelocity`, `RocketPropulsion`, an `AlignPosition` with a `MaxVelocity` | While it is **active** its speed is added to the limits the same way (a lift climbs at its speed for as long as it lifts), and when it stops the push carries on like a throw. A `LinearVelocity` in `Vector` mode relative to `World` gives the exact direction; relative to an attachment, or in `Line` / `Plane` mode, its whole speed counts both sideways and upwards. |
| A server-made mover that pushes with a **force**: `BodyPosition`, `BodyForce`, `BodyThrust`, `VectorForce`, `LineForce`, a rigid `AlignPosition` or one with the default unlimited `MaxVelocity` | It has no speed the kit can read, so the player is not judged while one is active, and `RELEASE_GRACE` (1 s) follows the last one. For player abilities (dashes, jetpacks, knockback) use a `LinearVelocity` or give the `AlignPosition` a `MaxVelocity`. |
| Which movers count | Active = a constraint mover that is `Enabled` with an `Attachment0` inside the character and something to push with (a `VectorForce` a non-zero `Force`; a `LineForce` a non-zero `Magnitude` and an `Attachment1`; a `LinearVelocity` / `AlignPosition` a `MaxForce` above 0 when its force limit is the plain Magnitude kind), or a Body mover inside one of the character's parts with a non-zero `MaxForce` / `Force` / `MaxThrust`. A disabled or zero mover left in a character changes nothing. A mover that came and went between two samples still counts (a quick knockback). Movers that only turn the character (`BodyGyro`, `AlignOrientation`) are not on the list. Put movers inside the character: one parented elsewhere is not seen. |
| A server script writes the root **every frame** (a "face the target" loop, a server lock-on, a velocity loop) | Not trusted: each trusted write lets the client's last frame or two before it go unjudged, and every frame of that adds up to a free run. More than 2 writes of one kind within a second stop the trust for that player for 5 s (`SERVER_WRITE_LIMIT`, `SERVER_WRITE_DISTRUST`), and the log gets one warning. Writes to an anchored root (a cutscene) or a seated character (a ride) are not counted. `Movement.allowTeleport` and `Movement.grace` always work. A slower loop (2 writes a second or fewer, e.g. `task.wait(0.5)`) is trusted and costs nothing: a speed hack or a hover under it is still flagged. |
| Conveyors and moving platforms | The horizontal speed of the part under the feet (capped at `GROUND_SPEED_CAP`, 150 studs/s) is added to the speed allowance; it keeps carrying a player who jumps off or steps off. **Only anchored parts and parts the server owns count**: a part the player's own client simulates could be given any speed by a cheater, so its speed is never believed. Anchor your platforms or `SetNetworkOwner(nil)`. |
| Server-side `WalkSpeed`, `JumpPower`, `JumpHeight` (admin `:speed`, shop upgrades) | Followed, as before. |
| Seats, the first 2 seconds after a spawn, a frozen (anchored) root | Not judged. Getting out of a seat: the seat's speed (capped at `GROUND_SPEED_CAP`) carries the player for a moment, like a push. A root let go after being anchored gets the 0.6 s catch-up pause, then is judged. |

The kit's own rubber-band is a server write too. It is remembered (value and time) and recognised, so it never counts as a game's move: a cheater who has just been put back is judged again on the next sample. The same goes for the signals being delivered late (Deferred signal behaviour): the handler compares what the root holds *now* with what the kit wrote, instead of relying on "the kit is writing right now". And because a game script's move can reach the kit only after the kit has already sampled that frame (Roblox does not document the order), a flag is judged one frame after its sample, and a sample taken in the same frame as a server move is taken back and judged again on the next sample with the move accounted for: a server move never gets flagged or undone.

**Needs you** (the server cannot see these, and they look exactly like a cheat):

| What your game does | What to do |
| --- | --- |
| Sprint set in a LocalScript (`WalkSpeed = 24`) | Make the script ask the server (a RemoteEvent the server checks), and let the server set `WalkSpeed`. The kit follows the server's value. |
| Client-side dash, double jump, grapple, wall-run, glide | Do the move on the server (set the velocity or add a mover from a server script) or call `Movement.grace(player, seconds)` from the RemoteEvent that starts it. |
| Client-side admin `:fly` / `:noclip` | Make the commands server-side (a server-made mover is recognised), or exempt the admins (below). |

**Exempting staff.** An exempt player is never judged by the movement checks: the baseline just follows them and nothing is counted. Any one of these is enough:

```lua
-- 1. From your admin system's rank check (lasts until the player leaves, also across respawns):
Movement.exempt(player, true)
Movement.exempt(player, false)

-- 2. A Player attribute set from a SERVER script (an attribute set by a client never replicates to the
--    server, so a cheater cannot give it to himself). Only the value true counts:
player:SetAttribute("WeaponKitExempt", true)

-- 3. In Config.luau: UserIds, and/or a group rank (asked once when the player joins, then cached;
--    id = 0 switches the group off; promotions during a session are not noticed):
ANTI_CHEAT = {
	EXEMPT_USER_IDS = { 1, 156 },
	EXEMPT_GROUP = { id = 1234567, minRank = 250 },
}
```

Exempting is a trade: an exempt player can fly and teleport without a flag. It only covers the movement checks; shooting rules still apply to everybody.

**Roll it out in log mode first.** `ANTI_CHEAT.MOVEMENT_ACTION` defaults to `"auto"`: `"snap"` while `DEMO_CHEAT_PANEL` is on (the exploit lab needs the rubber-band), `"log"` otherwise; an explicit `"snap"` or `"log"` always wins. In log mode the server prints one line at start and then only counts: nobody is moved back.

1. Ship with `"log"`. Use every admin command and movement feature your game has.
2. Read the counts and the detail of each flag (`Suspicion.onFlag(function(player, reason, detail, ...)`). A movement flag now says what was going on around it, for example `39.0 over the limit of 19.3 (server move 1.7 s ago, movers 0, ground 0 studs/s, WalkSpeed 16, JumpHeight 6.4)`: a flag shortly after a server move is a client-side part of that effect you should make server-side (or cover with `Movement.grace`); one on a conveyor shows the belt speed the kit saw.
3. Fix or exempt whatever shows up, then set `MOVEMENT_ACTION = "snap"`.

**Things this cannot do.**

- The checks cannot tell the client's own sprint from a speed hack (see "Needs you").
- Server-move recognition relies on the property-changed signals. If a Roblox update changed when they fire, the symptom would be admin teleports being flagged again; `TRUST_SERVER_MOVES = false` plus `Movement.allowTeleport` is the fallback.
- **What a server move or push still gives a cheater.** Server moves, pushes and speed movers are allowances, not time off, so a player who can set one off themselves (a server dash, an ability, self-knockback, a lock-on that turns them) gains little from it. What is left:
  - each trusted server move lets the client's last frame or two before it go unjudged (a teleport landing in exactly that frame is carried along), which is why only isolated writes are trusted;
  - while a push or speed mover lasts, its speed can be used in any direction (a 30 studs/s knockback is 30 studs/s more for a second, in any direction, never more), and a mover whose direction the kit cannot place counts its whole speed upwards too;
  - a **force** mover (`VectorForce`, `BodyForce`, `BodyThrust`, `LineForce`, `BodyPosition`, a rigid or speed-unlimited `AlignPosition`) still switches the checks off while it pushes, plus `RELEASE_GRACE`: use a `LinearVelocity` for anything a player can trigger;
  - getting out of a seat allows the seat's speed for a moment, and a vehicle the player drives is simulated by their own client;
  - after a server move longer than 2 studs the samples pause for 0.6 s. Everything is judged afterwards, but a short hop that is back on the ground before the pause ends is not seen;
  - `Movement.grace` is time off, by definition: keep it short when a player can trigger it.
- A moving mover runs in the player's own physics, so a modified client can steer it within the allowance above.
- A part moved by `TweenService` or by setting its `CFrame` does not carry a player standing on it (it has no velocity), so the kit adds no allowance for it either. A script that carries players along on the client is the game's job (`Movement.grace`). Physics platforms count only when anchored or server-owned (see the conveyor row above).
- A character whose `Humanoid.HipHeight` does not match its real standing height (a custom rig) can look like it is hovering.
- `EXEMPT_GROUP` reads the rank once when the player joins: a promotion during the session is not noticed (use `Movement.exempt` from your admin system for that).

## Teams, damage hooks and kill credit

- **`Config.FRIENDLY_FIRE`** (default `false`, only matters with `PVP` on): a player on the same `Team` as the shooter takes no damage. Players with no team (`Player.Neutral`) can always be hit, and nobody is ever their own team mate. The rule applies to rays and to the point-blank check alike.
- **`WeaponServer.onDamage(fn)`** - `fn(shooter, humanoid, damage, info) -> number?`, called for every victim of a shot right before `TakeDamage`. Return `nil` to keep the damage or a finite number `>= 0` to replace it (armour, a damage cap, `0` = absorbed). Hooks run in the order added, each seeing the previous result. It runs inside `pcall` and **must not yield**. An error or a return value that is not `nil` / a finite number `>= 0` is ignored, with one warning per hook. `HitConfirm` and the saved stats use the final damage; the round is spent whatever a hook decides. Returns a function that removes the hook.
- **`WeaponServer.onKill(fn)`** - `fn(shooter, humanoid, info)`, called once for every humanoid *this* shot took from above 0 health to 0 (a shotgun blast is one shot: one call per victim; a corpse never counts again). Each hook runs in its own thread, so it may yield; an error stays in that thread. Returns a function that removes the hook.
- `info = { weapon = "Pistol", headshot = true, model = victimModel }`.

```lua
local WeaponServer = require(ServerScriptService.WeaponKitServer.WeaponServer)

local stopArmour = WeaponServer.onDamage(function(shooter, humanoid, damage, info)
	if humanoid:GetAttribute("Armor") then
		return damage * 0.5
	end
	return nil
end)

WeaponServer.onKill(function(shooter, humanoid, info)
	shooter:SetAttribute("Streak", (shooter:GetAttribute("Streak") or 0) + 1)
end)
```

## What your game must call

Everything here is server code.

```lua
local Movement = require(ServerScriptService.WeaponKitServer.Movement)
local Suspicion = require(ServerScriptService.WeaponKitServer.Suspicion)

-- 1. Optional: a teleport YOU want (checkpoint, warp, round start). The kit now notices any server-side
--    PivotTo / MoveTo by itself (see "Works with admin systems"), but this states the intent and also
--    works with TRUST_SERVER_MOVES = false:
Movement.allowTeleport(player, CFrame.new(spawnPoint))

-- 2. Anything the CLIENT does to its own character that the server cannot see: a client-side dash, double
--    jump, grapple or glide. Nothing is flagged for that many seconds and the baseline follows the player:
Movement.grace(player, 1.5)

-- 3. Staff who must never be judged (see "Exempting staff" for the Config and attribute options):
Movement.exempt(player, true)

-- 4. Your policy. The default is to only count; this is where kicks, bans and webhooks go.
Suspicion.onFlag(function(player, reason, detail, reasonCount, totalCount)
	if reason == "noclip" and reasonCount >= 5 then
		player:Kick("Unexpected movement")
	end
end)
```

- Change `WalkSpeed`, `JumpPower`, `JumpHeight` and gravity **on the server**: the checks read the server's values. The same change made only on the client is exactly what gets flagged. **Sprint and double-jump scripts are the usual trap:** most free ones set `WalkSpeed` in a LocalScript, and every sprinting player then gets rubber-banded. Make them ask the server (a RemoteEvent the server checks, then sets `WalkSpeed`), or run in `"log"` mode until they do.
- Players in a `Seat` / `VehicleSeat`, a frozen (anchored) root, and the first 2 seconds after a spawn are not judged. Leaving a seat allows the seat's speed for a moment; nothing else is forgiven.
- `Config.ANTI_CHEAT.MOVEMENT_ACTION = "log"` counts without ever moving anyone: start there on a live game and read the numbers before switching to `"snap"` (this is the default whenever `DEMO_CHEAT_PANEL` is off).
- Aim flags (`aim`, `snap`) and movement flags are suggestions. Weigh them in `onFlag` (for example, `snap` and `aim` together mean more than either alone).

## Limits worth knowing

- Lag compensation has the usual cost: a target can be hit up to `REWIND_TIME` (0.6 s) after it moved, for example just after stepping behind cover, and a cheater can aim at that short trail as well as at the target. Lower it if your players have good ping; 0 turns it off. The look back moves the whole body with its root (limb animation is not replayed) and treats every part except a Ball as its box, which is a little generous for mesh parts.
- Movement checks cannot prevent the client from moving its own character (Roblox gives it that physics): they notice and undo it, within about a second. They look at samples 0.2 s apart, so a very short trick between two samples is invisible.
- Small cheats hide inside the tolerances on purpose (a +30% speed boost, a +25% jump): the defaults prefer a missed small cheat to a false alarm on a laggy honest player.
- The fire-rate credit (0.1 s) is time, so a faster weapon fits more shots into it: at 900 rpm a burst can open with 2 extra rounds. The average never beats the rpm. During a lag spike that delivers 2-4 shots at once, all but one or two of them are refused (the player sees their ammo corrected); that is the price of never letting a burst through.
- `fast` is built not to fire on honest players (see "Tests"), but a connection worse than the test model (several lag spikes within 2 s) can still trip it. Weigh it in `onFlag`; do not ban on it alone.
- No sounds or animations: they need asset IDs, and this kit has none by design.
- The range, the lab corner and the dummies are a demo scene; the weapon code does not depend on them.

## Tests

Everything server-side runs in a mock Roblox world under the plain Luau CLI, no Studio needed: `tests/run.sh` (needs `python3` and `luau`; `rokit install` gets `luau`). GitHub Actions runs the same suite, StyLua and Selene on every push. The report is grouped by topic, one line per named scenario.

- **708 named checks:** shots, ammo, reloads, saves, PVP and teams, damage hooks, shots at moving targets (hit where the shooter saw them, never through a wall, across a teleport, past the window or on something the shooter may not hurt, turning included), every movement check (walks, ledges, ladders, corners, conveyors, seats), admin-style server moves and pushes, movers (including idle ones left in a character), scripts that write a character every frame, server moves, graces and exemptions that land in the same frame as a sample, and cheaters hiding behind server moves (a teleport right before a server turn, a speed hack or hover under a slow lock-on loop, a self-triggered dash, a small knockback or a slow mover covering a fast run, a super jump on a launch pad).
- **Fuzz:** 1,000,000 randomized, mostly malicious requests (NaN, inf, wrong types, replays, floods, weapon swaps, reload spam) against 6 safety invariants (no Lua error, ammo never created, ammo within its caps, damage within the weapon's maximum, no damage without a spent round, no damage to the dead). Honest shots mixed into the attacks must all be accepted.
- **Honest players on a bad network:** 52,200 shots from 2,000 magazines, each packet delayed by a random ±40 ms plus up to one server frame (gaming guides call over 30 ms of jitter "poor"; a measured 4G/5G figure is about 14 ms), with a lag spike in 30% of the magazines. Not one `fast` flag; the only refused shots are the ones a spike bunched up.
- **Rapid fire from 1.1x to 20x the rpm:** always held to the real rpm; reported within 2 s from 1.25x.
- **Mutation check:** each anti-cheat rule was broken on purpose and the suite had to fail (e.g. trusting every server write, counting idle movers, judging a flag in the same frame, a server move restarting the checks, a push with no end or no limit, the old 0.08 s jitter credit, a look back that ignores walls, teleports, turning or the window). All were caught (`python tests/mutate.py . luau`).

What the mock cannot prove is how Roblox itself behaves, so those parts were measured in Studio: which writes fire the property-changed signals, client-made changes never replicating, NaN positions never reaching the server, and the lab's exploits against a real server. A local server with 3 player clients (Studio's Server and Clients test) confirmed the rest across real client processes: PVP hits and kill credit between players, bullets passing through players with PVP off, every client seeing the others' shots, a speed hack flagged and pulled back while another player walking at the same moment got no flag, rapid fire held to the cap while another player's honest shots were all accepted, and server teleports from inside Heartbeat never undone. The allowance rules were checked in Studio too: a server dash every 0.55 s with a 60 studs/s speed hack between was flagged and pulled back while all six dashes were kept, and the same dashes at walking pace raised nothing; a hack and a hover under a slow "face the target" loop were both flagged; an honest 36-stud launch-pad throw and three 42-stud `LinearVelocity` dashes raised nothing, while a 30 studs/s knockback and a 20 studs/s mover did not cover a 120 studs/s run; and with 0.25 s of replication lag a server teleport was never pulled back by the client's late updates.

The client API, the phone and gamepad layout and the own-model loader (`Tools.luau`) run only in Roblox, so the mock suite does not cover them. They were checked by hand in Studio; the steps are in `TEST_CHECKLIST.md`, section 14.

## Hire me

I build server-validated gun systems and fix Roblox scripts. This kit is a sample of how I work: clean modules, comments that explain why, and no trust in the client.

- Demo video: coming soon
- Try it in Roblox: coming soon
- Contact: Discord `imbetter0597`

**Prices (USD)**

| Job | Price |
| --- | --- |
| Starter deal: 3 bug fixes | $15 |
| One bug fix | $10 - $25 |
| One feature | $25 - $60 |
| Server-validated weapon module | $60 - $150 |
| Bigger systems | from $200 |

**Terms**

- You get a preview video first. Then a 30 - 50% deposit. Files are delivered after payment.
- USD preferred.
- Fixed price, with the number of revision rounds agreed up front.
- 7-day bug-fix warranty on everything I deliver.

Built with Claude as a coding assistant. Every module was reviewed and tested by me; the "Tests" section above is how it was verified.

## Licence and credits

The kit is MIT-licensed (see `LICENSE`): use it in any game, free or paid, keep the notice.

[ProfileStore](https://github.com/MadStudioRoblox/ProfileStore) by MadStudioRoblox (loleris), Apache-2.0, shipped unmodified in `src/server/Vendor/`. The licence and source note (commit and checksum) are in `third_party/ProfileStore/`.
