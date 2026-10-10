# Weapon Kit - Studio test checklist

Tick each line as you go. "Expect" says what should happen. Anything that doesn't match is a bug to report.

## 0. Start-up

1. Run `rojo serve` in `weapon_kit`, open an empty (or Baseplate) place in Studio, Plugins > Rojo > Connect. Or build with `rojo build default.project.json -o WeaponKit.rbxl` and open that.
2. Press Play (F5).
   - Expect in Output, in order: `[WeaponKit] server started`, the PlayerData mock-store line (unpublished place only), `Range ready`, `WeaponServer ready`, `Tools ready (3 weapons)`, `Dummies ready (5)`, `Dummies ready (1)` (the lab's wallbang dummy), `Movement ready (snap)`, `LabQuery ready (demo)`, `[WeaponKit] ready`, `[WeaponKit] client started`. No red errors.
3. Look around.
   - Expect: you spawn on a teal pad behind the firing line, a banner "WEAPON KIT" above, five lanes ahead, an olive ammo crate with a yellow "AMMO" label to your right, five orange dummies with bullseyes and health bars.
   - Expect: the Pistol is already in your hand, the bottom bar shows `1 PISTOL  2 RIFLE  3 SHOTGUN` with the Pistol highlighted, the ammo panel reads `15 / 60`.

## 1. Pistol

4. Walk to the firing line (the white strip). Click once on the 10-stud dummy (left-most lane) in the chest.
   - Expect: a tracer and spark, the crosshair opens briefly, a white hit marker and `20` floats up. The dummy flashes, its bar drops 20%. Ammo `14 / 60`.
5. Hold the mouse button down on the pistol.
   - Expect: one shot per click only (it is semi-auto), however long you hold.
6. Aim at the head (the pale ball) and click.
   - Expect: a red, bigger hit marker and `HEADSHOT 40`. Three headshots kill the dummy.
7. Kill the dummy (a gold marker on the last hit).
   - Expect: it falls backwards, fades, and a fresh one stands there 3 seconds after it died. The top of the screen shows `KILLS 1` and an accuracy figure.

## 2. Rifle

8. Press 2.
   - Expect: Rifle in hand, bar highlights 2, ammo `30 / 120`, a cyan accent on the HUD.
9. Hold the mouse button on the 25-stud dummy.
   - Expect: continuous fire (about 10 shots per second), camera kicks up and settles when you stop, the crosshair stays open while firing. Body hits show `14`, head hits `28`.
10. Fire until the magazine is empty.
    - Expect: the number turns red at `0`, a reload starts by itself (the label above says `RELOADING` and a progress bar fills under the number), then `30 / 90`. The reserve dropped by exactly the rounds you used.
11. Shoot the strafing dummy in the middle lane.
    - Expect: it walks left and right, pausing at each end. Hits register on it where the server has it.

## 3. Shotgun

12. Press 3, walk up to the 10-stud dummy, stand 2 - 3 studs away and fire at its chest.
    - Expect: a burst of 8 tracers, one large damage number (up to `88`), ammo `5 / 24`. A second shot is not accepted until the pump is back (about 0.85 s).
13. Step back to the 25-stud dummy and fire.
    - Expect: pellets spread out; only some hit. Fewer at 50 studs, almost none at 100.
14. Press R with 5 / 6 in the magazine.
    - Expect: a reload moves exactly 1 round: `6 / 23`.

## 4. Reload and reserve

15. With the Pistol, fire 5 shots then press R.
    - Expect: `RELOADING` and the progress bar for about 1.6 s, then `15 / (reserve - 5)`.
16. Start a reload and press 1 / 2 / 3 to switch weapons before it finishes.
    - Expect: the reload is cancelled; switch back and the magazine and reserve are unchanged.
17. Spend a weapon's whole reserve (Shotgun: 24 spare rounds = 4 magazines).
    - Expect: at `0 / 0` the panel says `OUT OF AMMO`; clicking does nothing; R does nothing.

## 5. Ammo crate

18. Walk up to the crate. Expect: an "Ammo crate / Restock ammo [E]" prompt.
19. Hold E for under a second.
    - Expect: reserve jumps to the cap: Pistol 90, Rifle 180, Shotgun 36 (check by switching weapons).
20. Hold E again straight away. Expect: nothing for about 2 s (cooldown).

## 6. Exploit lab (F2): the original four tests

Equip the Pistol or Rifle first. F2 opens a panel on the left (tabs COMBAT and MOVEMENT, the flag list at the bottom, the result of the last test under it) and brings back the mouse cursor. The panel is scrollable; on a small screen scroll the button list.

21. **Rapid fire 3x** (Pistol). It fires at 3x the rpm for 2 s. Expect: about `30 requests sent`, `rounds spent: 11` or so (the real 300 rpm over 2 s, plus one), and `fast` flags in red (about 3, one for every 3 too-early shots). With the Rifle: about 60 sent, about 21 spent.
22. **Fake origin**. Expect: `origin x1`, and the shot still happens from your real position (the tracer is not drawn from the fake point, damage is that of one normal shot or none if you weren't aiming at a target).
23. **Garbage args**. Expect: `args x3` or more, rounds spent: 0, damage: 0.
24. **Reload spam**. Expect: `reload x16` or so, and your ammo is not refilled.
25. By now the flags add up to more than 25 (press **Rapid fire** once more if not).
    - Expect in Output: exactly one warning like `[WeaponKit] Suspicion: Player1 reached 25 flags (args=3, fast=9, ...)`.
26. Stand behind a grey cover wall behind the firing line, aim at a dummy over it, and press **Fake origin** while the crosshair is on a dummy.
    - Expect: `origin x1`; the server ignores the muzzle you sent.
27. Close the panel with F2. Expect: the crosshair is back.

## 7. Other players and PVP

28. Test > Clients and Servers > 2 players, Start.
    - Expect: client A sees client B's tracers and muzzle flashes (FireFX). Bullets pass through B (PVP is off) and B's health does not change.
29. Stop. Set `PVP = true` in `src/shared/Config.luau`, run the 2-player test again.
    - Expect: A's shots hurt B (a pistol headshot does 40), and A's own character is still ignored by A's bullets.
30. Set `PVP = false` again.

## 8. Saving (needs a published place)

The mock store keeps nothing: in an unpublished place, step 31 onwards will show fresh ammo each time. That is expected.

31. Publish the place (File > Publish to Roblox). Game Settings > Security > switch on *Enable Studio Access to API Services*. Run the test again: the mock-store line should be gone from Output.
32. Equip the Rifle, fire half a magazine, and note the numbers (for example `17 / 120`). Switch to the Shotgun and note its numbers.
33. Stop. Press Play again.
    - Expect: you spawn holding the Shotgun (the last weapon equipped), and its ammo is where you left it. Press 2: the Rifle's magazine and reserve are where you left them (not refilled).
34. Shoot a dummy dead, stop, play again. Expect: `KILLS` kept.
35. Use the crate to refill. Expect: back to 90 / 180 / 36.

## 9. Production switch

36. Set `DEMO_CHEAT_PANEL = false` in Config, play. Expect: no `F2 exploit simulator` in the bottom-left hint, F2 does nothing, and the Output never shows `Rejected` activity. In the Explorer, ReplicatedStorage > Remotes has no `Rejected` and no `LabQuery`; the range has no lab corner (no `Range.Lab` folder, `Dummies ready (5)` only). The movement checks still run (`Movement ready (snap)`).

## 10. Exploit lab: the other COMBAT tests

Pistol in hand, full magazine, standing on the spawn pad or at the firing line unless a step says otherwise. After each test the result box ends with `server flags: ...`; the flag list shows the running totals.

37. **Wallbang.** Walk to the lab corner (east of the spawn, x about 86, in front of the grey 4-stud wall, z about +6 so the wall is between you and the dummy marked BEHIND WALL). Click **Wallbang**.
    - Expect: `1 requests sent -> 0 refused`, `rounds spent: 1`, `damage dealt: 0`, `server flags: none`. The dummy behind the wall keeps full health.
    - From the wrong place you get an amber "Stand in front of the lab wall..." and nothing is fired.
    - Control: walk around the wall and shoot the same dummy by hand: it takes damage. So the wall is what stopped the bullet.
38. **Hitbox expander** (at the firing line, dummies in view).
    - Expect: for a moment the nearest dummy's head is a giant ball on YOUR screen only; the result says `this client's own raycast: HIT the giant head`, `damage dealt: 0`, `server flags: none`. The head is normal size again afterwards, and the dummy's health did not change.
39. **Silent aim** (Pistol is the most reliable; the Rifle works too; the Shotgun refuses with an amber message). Stand at the firing line.
    - Expect: within about 3 s a burst of shots, each at a different dummy's head. `snap` is flagged at least once (`snap x1` or more). `aim` is flagged once 10 hits in a row are almost all headshots (usually with the Pistol; not guaranteed with the Rifle, whose spread misses heads at range). `rounds spent` is about the number of shots and `damage dealt` is above 0: aim flags never block a shot.
    - If neither flag shows, move closer to the dummies (the shots must hit) or lower `AIM_SNAP_ANGLE` in Config for the demo.
40. **Godmode.**
    - Expect: `client: health 1000000 / 1000000`, `server: health 100 / 100 (unchanged)`, `server flags: none`. Afterwards your health bar is normal.
41. **Remote fuzz.**
    - Expect: about 210 calls (30 to each of the 7 remotes); the flag list grows (`args`, `rate`, `reload`); the result says `server still answers (LabQuery): it did not choke`. In Output (server side) there are NO red errors. Shooting still works afterwards.
42. No spread: with the Rifle, hold fire at the 100-stud dummy.
    - Expect: hits scatter around the head, however steady you hold the crosshair. The client sends only a direction.
43. Infinite ammo: fire the Pistol until `0 / x`, then click **Reload spam**.
    - Expect: the reserve is not refilled and the magazine does not grow beyond the reload rule.
44. Ammo crate from afar (optional; skip if Studio ignores the call). Stand 40 or more studs from the crate. In the Output window set the context to Client and run in the command bar: `local p = workspace.Range.AmmoCrate.Base.ProximityPrompt; p:InputHoldBegin(); task.wait(1); p:InputHoldEnd()`.
    - Expect: your ammo is unchanged and the flag list shows `crate x1`. Standing at the crate, the same call refills (step 19).

## 11. Exploit lab: the MOVEMENT tab

Click the MOVEMENT tab. Stand on the spawn pad with the camera looking down the lanes (towards -Z): there are 150 free studs ahead. Every test ends with the lab restoring WalkSpeed, JumpPower, CanCollide, velocities and health, and (if the server did not) putting you back; the result says `RUBBER-BANDED: pulled back N studs` when the server did it.

45. **Speed hack** (WalkSpeed 60 for 3 s).
    - Expect: you lurch forward fast, are yanked back, lurch again; `speed x2` or more (`teleport` can appear too); `RUBBER-BANDED`; `server still sees WalkSpeed 16`. Afterwards you walk at the normal speed.
46. **CFrame speed.** Expect: the same lurch and snap back; `speed` (and `teleport`); `RUBBER-BANDED`.
47. **Teleport.** Expect: you flicker 80 studs ahead and are put back within about half a second; `teleport x1`; `the exploit took you 80 studs`, `RUBBER-BANDED`.
48. **Fly.** Expect: you rise and hover, then drop back to the ground; `fly x1` or more (`jump` can appear if the rise was quick); `RUBBER-BANDED`.
49. **Super jump.** Expect: a huge jump, cut short by a snap; `jump x1`; `server still sees JumpPower 50`. You fall back normally (no damage in this kit).
50. **Infinite jump.** Expect: a few jumps climbing higher than a jump can; `jump` (or `fly`); pulled back.
51. **Noclip** (needs the lab corner). Stand 5 - 12 studs from the thin NOCLIP WALL, facing it (on its +Z side, looking towards -Z), then click.
    - Expect: you walk into and through the wall, then are put back in front of it; `noclip x1` or more. Afterwards the wall is solid again when you walk into it.
    - Too far or too close: an amber hint, nothing happens.
52. **Fling spin.** Expect: you spin for an instant, then stop; `fling x1`.
53. After steps 45 - 52: walk normally, jump, bump a wall. Expect: nothing left over from any test (speed, jump height, collisions, rotation are all normal).

## 12. False-positive controls (these must NOT flag anything)

Open the lab (F2) and note the totals in the flag list; close it, do the step, open it again. The totals must not move, and the Output must show no new `Suspicion` warning.

54. **Walk and strafe.** Run around the range for 60 s with WASD, diagonals, sudden direction changes, turning with the mouse. Expect: no flags.
55. **Jump spam.** Hold Space while walking for 30 s, also jump from the cover walls and the firing-line steps. Expect: no `jump`, no `fly`.
56. **Truss tower.** In the lab corner climb the truss to the top, rest on the platform, walk to the edge and step off (a 38-stud fall), land, then climb again and let go half way. Expect: no flags at all (climbing is not flying, falling is not a teleport).
57. **Walk along a wall.** Hug the grey walls on the range and in the lab, sliding along them for 20 s, and run diagonally round the corner of a cover wall 10 times at full speed. Expect: no `noclip`.
58. **Spawn and respawn.** Reset your character (Esc > Reset) five times in a row, once while shooting. Expect: no flags; you are not snapped anywhere.
59. **Shoot while falling and jumping** from the tower top with the Rifle. Expect: shots work, no flags.
60. **Laggy client** (if your Studio build has it): Studio Settings > Network > Incoming Replication Lag, set 0.3, then repeat steps 54 and 55 for 60 s in a 2-player Test. Expect: no movement flags at 300 ms. If your Studio has no such setting, note that step 60 was not run. (Real players on bad connections are the case to worry about; if flags show up under lag, raise `SPEED_SLACK` or run `MOVEMENT_ACTION = "log"` first.)
61. **Standing still** for 2 minutes, then walking off. Expect: no flags.

## 13. Policy hooks and the game API (optional)

62. **Log mode.** Set `MOVEMENT_ACTION = "log"` in `Config.ANTI_CHEAT`, play, run **Speed hack**. Expect: flags count (`speed x2` or more), you are NOT pulled back by the server (the result says `the server did NOT move you back (the lab put you back)`). Set it back to `"snap"`.
63. **onFlag hook.** Temporarily add to `Main.server.luau`: `require(script.Parent.Suspicion).onFlag(function(p, reason, detail, n, total) print("FLAG", p.Name, reason, detail, n, total) end)`. Run **Speed hack**. Expect: one `FLAG ...` line per counted flag in the server Output, with a detail like `31.2 over the limit of 24.8`. Remove the line again.
64. **Sanctioned teleport.** In the server command bar (Output context: Server), with one player in the game: `require(game.ServerScriptService.Server.Movement).allowTeleport(game.Players:GetPlayers()[1], CFrame.new(60, 3, 40))`. Expect: you are moved, no flag, and you can walk on from there. Then run `game.Players:GetPlayers()[1].Character:PivotTo(CFrame.new(-60, 3, 40))` (a teleport your game did NOT announce). Expect: a `teleport` flag and you are put back.

---

# Demo video shot list (60 - 90 seconds)

Record at 1080p. Hide the Studio panels (run the game in a client window, or use the Test tab > full screen). Keep the mouse movement slow; viewers need to read the numbers.

| Time | What to show | Notes |
| --- | --- | --- |
| 0:00 - 0:05 | Slow pan over the range from the spawn pad: banner, lanes, dummies | Text overlay: "Server-validated gun system" |
| 0:05 - 0:17 | **Pistol** at the 25-stud dummy: body hit, then a headshot (red marker, `HEADSHOT 40`), kill, dummy falls and respawns | Stay on the dummy through the respawn: it proves the 3 s loop |
| 0:17 - 0:30 | **Rifle** (press 2): full-auto at the strafing dummy, show the recoil, empty the magazine into an auto-reload | Zoom the ammo panel in the edit if you can |
| 0:30 - 0:38 | **Shotgun** (press 3): point-blank at the 10-stud dummy (`88`), then one shot at 25 studs showing the spread | Two shots only |
| 0:38 - 0:58 | **Press F2.** Click Rapid fire 3x, Fake origin, Garbage args, Reload spam, one after another, pausing about 3 s on each result line | This is the money shot: say or caption "the server refused all of it" |
| (new, 20 - 30 s) | MOVEMENT tab: Speed hack, Teleport, Fly, Noclip at the lab wall. Let the rubber-band show; pause on `RUBBER-BANDED` and `server still sees WalkSpeed 16` | Caption "client says 60, server says 16" |
| (new, 15 s) | COMBAT tab: Wallbang, Hitbox expander, Silent aim | Caption "flagged, never trusted" for Silent aim |
| 0:58 - 1:03 | Cut to Output: the `25 suspicious requests` warning line | Optional, 3 s |
| 1:03 - 1:13 | Ammo and saving: show the reserve low, press E at the crate to refill; then (published place) stop, play again and show the reserve and loadout kept | If saving isn't set up, skip the rejoin and keep the crate only |
| 1:13 - 1:23 | Code peek: `Weapons.luau` with the Smg example added, press 4 and shoot it | Proves "a new weapon is one entry" |
| 1:23 - 1:30 | End card: prices, `<Discord>`, the line "AI-assisted tooling; all code reviewed and tested by me." | Same text as the README |

Trim to 60 s by dropping the Output cut, the code peek, the rejoin and the new lab rows.
