# Proof log

Independent checks of the kit's claims. Every number says how it was measured, where, how many
samples, and what it can't see. Method: memory `multi-source-proof` (two or more independent
sources per claim, at least one on the real engine; a metric the feature itself optimizes is never
its proof).

## Pose (src/client/Pose.luau): 2026-10-11, Studio solo Play

Tool: `tests/studio/pose_audit.luau` (paste into a Client execute_luau). It shares no code with
Pose's own push-out: dense grid points (0.08 stud for guns, 0.1 for arms) inside every part, each
tested against the engine's own geometry with `GetPartsInPart` on a 0.04-stud probe. Sanity check
passed: torso centre in, 50 studs away out, just inside/outside a torso face in/out, and a head-box
corner OUT (the head mesh is rounded, so a box metric over-counts the head).

Setup: the user's blocky R15 avatar (Height 1.05, Width 1, BodyType 0, Proportion 0.5; torso and
limbs have Box collision, head Default), root anchored, 5 pitches (-60..60) x 5 yaws (-75..75),
0.6 s settle, 1 sample per aim, 1 run (+1 repeat at (0,0)).

| Gun | gun in torso/head | gun in arms | upper arm in body (shoulder 0.6 stud excluded) | forearm+hand in body | barrel vs aim |
|---|---|---|---|---|---|
| Rifle | mean 0.15%, max 2.9% at (0,0); repeat at (0,0): 4.1% | ~30% at every aim, max 54% | max 55% at (0,-75) | max 47% at (0,-75) | max 0.28 deg |
| Pistol | 0% at all 25 aims | max 21% | max 48% at (60,-75) | max 36% at (-60,0) | max 0.12 deg |
| Shotgun | mean 0.17%, max 2.4% at (0,0) | max 55% | max 50% | max 42% | max 0.48 deg |

Baseline (no tool, idle, same metric): upper arm 0%, forearm+hand 0%.

Verdicts vs earlier claims:
- "Gun-in-body 0% on all three guns": FALSE. It was measured with the same box check that the
  push-out minimizes (circular). The engine check finds 2.4-4.1% at a straight-ahead aim (long guns).
- "Arm clip 17-25%, partly a shoulder-joint artifact": FALSE. Up to 55% with the shoulder zone
  excluded. The contact sheet and the 8-camera orbit show the right upper arm through the head
  at hard-right aim (0,-75), and the forearms folded into the chest when aiming down (-60,*).
- "Barrel within 1 degree of the aim": CONFIRMED (independent: Handle.CFrame * Grip vs camera look).
- "Elbows get IK poles" (Pose.luau header): NOT IMPLEMENTED. No IKControl.Pole is set anywhere.
- Gun inside the arms (~30% even at neutral): new finding; the contact sheet shows the left forearm
  crossing the receiver. Needs a visual judgement of how bad it looks.
- Run-to-run spread: (0,0) rifle 2.9% -> 4.1% (1 repeat). Needs 3+ repeats.

Blind spots still open: one avatar (no scaled, Rthro, or layered clothing), anchored and standing
(no walk, run, or jump animations), solo (what other players see is not checked), turn-in-place
off (anchored).

Contact sheets: `A.sheet({A.capture(...)})` (5 fixed cameras: player view, front 3/4, right side,
top, x-ray) and `A.orbit(A.capture(...))` (8 cameras around one pose). Images from this run are in
the session's tool-results folder (not kept in git).

## Elbow poles (IKControl.Pole): 2026-10-11, Studio solo Play

Change: each arm IK gets a pole Attachment on the UpperTorso (offset from that side's
ShoulderRigAttachment, so it turns with the torso and scales with the body). Shipped values:
rifle stance R (1,-2,1) L (-2,-1,0); pistol stance R (1,-2,0) L (-1.5,-1,0.5). The shotgun uses the
rifle stance.

How they were picked (not circular by itself, but the same metric family): `A.poleSearch` (one
background job inside Studio) scored candidates on 15 train aims (pitch -60/0/60 x yaw
-75/-40/0/40/75), right pole first, then left. Score = mean(upper arm + forearm) + 0.5 x
(their maxes) + 0.5 x mean gun-in-arms + 5 x max gun-in-body. Then checked on 8 HELD-OUT aims
(pitch -30/30 x yaw -60/-20/20/60), no poles vs poles, 2-3 repeats.

| Gun | held-out score, no poles -> poles (lower = better) | upper arm mean/max | forearm max | gun in body max |
|---|---|---|---|---|
| Rifle | 69.2 / 78.1 -> 59.4 / 60.4 | 11.8/30.5 -> 6.4/13.1 | 23.5-31.7 -> 21.0-21.4 | 1.0-1.5 -> 2.5-2.6 |
| Pistol | 51.7 / 58.5 -> 49.7 / 43.4 | 10.2-12.0/21-32 -> 4.9-7.0/20-24 | ~37 -> ~37 (no change) | 0 -> 0 |
| Shotgun (settle 1.2 s, same start pose, 3 repeats) | 92.2 / 81.6 / 82.3 -> 78.4 / 83.7 / 78.8 | max 28 -> 17.6 / 34.7 / 19.0 | ~36 -> ~36 | 3.2-3.8 -> 3.0-4.1 |

Second source (pictures, A.sheet, rifle): at the hard-right aim (0,-75) the right upper arm goes
through the HEAD with no poles; with poles it doesn't (elbow out to the side). But that single
sample still measures upper arm 46% / forearm 44% (no poles: 51% / 29%): at this extreme yaw the
arm now sits in the torso instead of the head.

Verdict: poles = real average improvement (held-out metric + pictures), NOT a fix for:
- hard-right aim (0,-75): needs its own fix (cap the right yaw, more torso turn, or move the hold point);
- aiming down (-60,*): forearms folded into the chest (~36%), unchanged by poles: hold point issue;
- gun-in-body rose slightly on the rifle (1.0-1.5% -> 2.5-2.6%).
Measurement note: the body push relaxes slowly (CLEAR_RELAX 2/s), so a sample depends on the aims
before it. Use settle >= 1.2 s and the same start pose for comparisons (shotgun row). Repeats of
the same setup differed by up to ~15 score points at settle 0.6.
Blind spots unchanged: one blocky avatar, anchored, standing, solo.

## Grip pivot on the real chest (commit 45d342e): 2026-10-11, Studio solo Play

Cause (engine-measured, plus the DevForum "IKControl Joint Constraint [Beta]" post and the
`IKControlConstraintSupport` enum, default Enabled): the avatar joint upgrade rig has
BallSocketConstraint limits that IKControls obey (waist twist -40..20), so at a hard-right aim the
torso stays at -20 degrees while the old hold point assumed a full turn: the grip landed behind
the torso. Fix: the grip swings around a pivot fixed to last frame's real chest, kept 0.3 stud in
front of it.

Before = 3b3d3ac's Pose.luau pasted into the same place (only Pose.luau differs between the two
commits). Same method both sides: anchored, settle 1.2 s, held-out = pitch -30/30 x yaw
-60/-20/20/60, grid = pitch -60..60 x yaw -75..75 (5 x 5).

Default rig (joint limits on):

| Gun | held-out score, before -> after (3 runs each) | grid score | upper arm max | forearm max | gun in body max |
|---|---|---|---|---|---|
| Rifle | 66.0 / 69.5 / 77.3 -> 30.0 / 29.7 / 29.9 | 113 -> 52 / 58 | 51 -> 17 / 21 | 42 -> 24 / 30 | 5.1 -> 0.7 / 0.7 |
| Pistol | 55.5 / 46.1 / 45.9 -> 42.1 / 24.6 / 25.5 | 66 -> 45 / 41 | 51 -> 40 / 38 | 32 -> 25 / 22 | 0.4 -> 0 / 0 |
| Shotgun | 80.7 / 85.8 / 87.6 -> 32.0 / 29.6 / 47.4 | 94 -> 56 / 73 | 49 -> 16 / 22 | 41 -> 22 / 34 | 2.8 -> 2.0 / 3.5 |

No joint limits (proxy for an older rig: the character's 14 BallSocket/Hinge constraints destroyed
client-side):

| Gun | held-out score, before -> after (2 runs each) | grid score | upper arm max | forearm max | gun in body max |
|---|---|---|---|---|---|
| Rifle | 94.5 / 81.0 -> 74.5 / 77.5 | 274 -> 93 | 48 -> 40 | 54 -> 26 | 31.9 -> 2.1 |
| Pistol | 100.3 / 89.5 -> 66.0 / 66.0 | 115 -> 78 | 65 -> 40 | 59 -> 26 | 0 -> 0 |
| Shotgun | 76.1 / 85.0 -> 71.9 / 81.6 | 254 -> 107 | 52 -> 52 | 49 -> 38 | 26.9 -> 2.7 |

Second source (pictures, A.sheet, rifle, anchored): before, the right arm crosses the face at the
hard-right aim (0,-75) (upper arm 50%) and the forearms fold into the chest aiming down (-60,0)
(35%); after, the arms stay in front of the chest at both (15% / 13% and 10% / 7%).

Other findings:
- Hard right is noisy: the pistol at (0,-75) read 33-38% upper arm in 4 targeted samples (from the
  left and from straight ahead) and 13% in one capture. The shotgun at (-30,-75) has two stable
  poses: 3-4% when the aim swings in from the left, 15-22% from straight ahead (2 runs each, steady
  for 4 s).
- Barrel vs aim: under 1 degree 0.3 s after a full diagonal flick and under 0.15 degree by 0.6 s
  (4 of 4). Two grid samples out of 150 were over 1 degree (1.6 and 4.35, the second right after a
  flick); neither came back in 4 targeted repeats.
- Turn in place on (the default, root not anchored): the body turns toward the aim and the same
  hard-right aims read 0-3%. The anchored numbers are the worst case: a standing player rarely
  sees them, a running player looking sideways can.

Verdict: better on every gun, on both rig types, by held-out score, grid and pictures. Not a full
fix: the pistol's upper arm at a hard-right aim (~35-40%), and a rig with no joint limits still
clips about twice as much as the default rig (upper arm mean ~24% vs ~7%).
Blind spots: the no-limits case is a proxy (constraints destroyed on a joint-upgrade rig), not a
real Motor6D rig; Workspace's avatar joint setting is not script-readable and was not switched.
One blocky avatar, anchored, solo.

## Both hands on the gun, every avatar (v0.1.1): 2026-10-20, Studio solo Play

Bug (user's recording, their blocky R15 avatar): the left hand floated 1.25-1.39 studs off the gun.
Cause, measured: reach. The rifle's left spot was 2.95 studs from the left shoulder, the arm (shoulder
to hand) 1.84 long. The stance numbers had been calibrated on rigs where Roblox's joint limits held
the waist to 20 degrees of turn, so the rifle's 65-degree stance never actually happened.

Method: `A.matrix` (pose_audit.luau) with `rig_server.luau` swapping the player's avatar for each rig
(HumanoidDescription scales on the default body, R6, the player's own avatar, and that avatar with
every joint turned into a Motor6D = a rig without the avatar joint upgrade). Each rig x Pistol /
Rifle / Shotgun x pitch -60..60 x yaw -60..60 (5 x 5), root anchored, 0.6 s settle, 1 sample per
aim. Same grid for v0.1.0 (e30c7f6's Pose.luau pasted in) and v0.1.1. Hands: right = grip
attachment to the hold target; left = to its target (v0.1.0: hand centre to the model's LeftGrip;
v0.1.1: palm, the LeftGripAttachment, to WeaponKitLeftGrip); "on gun" = palm to the nearest visible
gun part. Body metrics: the S2 numbers above (engine geometry, GetPartsInPart).

| Rig | v0.1.0 left hand off (max) | v0.1.1 left / right off (max) | v0.1.1 palm to gun (max) | gun-in-body mean (max), v0.1.0 -> v0.1.1, worst gun | arms-in-body mean (upper / fore), v0.1.0 -> v0.1.1 |
|---|---|---|---|---|---|
| user's avatar (blocky, H 1.05, P 0.5) | 2.09-3.16 | 0.01 / 0.01 | 0.18 | 0.2 (2.0) -> 0.0 (0.1) | 4.4-4.6 / 3.3-4.3 -> 6.9-8.9 / 8.6-9.8 |
| blocky scales, default body | 2.09-3.37 | 0.02 / 0.01 | 0.18 | 0.2 (2.1) -> 0.0 (0.1) | 3.4-4.6 / 3.3-4.1 -> 7.0-11.1 / 8.9-11.4 |
| default R15 | 1.94-3.31 | 0.01 / 0.01 | 0.18 | 0.1 (2.0) -> 0.0 (0.0) | 3.1-4.7 / 3.4-3.9 -> 6.0-10.3 / 8.1-10.6 |
| Rthro (BodyType 1) | 2.05-2.88 | 0.07 / 0.03 | 0.18 | 0.2 (4.0) -> 0.0 (0.4) | 2.0-5.3 / 1.4-3.9 -> 3.3-8.8 / 6.5-8.3 |
| Rthro slender (+ Proportion 1) | 1.82-3.07 | 0.02 / 0.02 | 0.18 | 0.0 (0.0) -> 0.0 (0.5) | 2.0-5.4 / 1.4-3.9 -> 3.3-10.0 / 6.4-9.2 |
| height 0.9 | 2.36-2.95 | 0.04 / 0.01 | 0.18 | 0.4 (4.6) -> 0.1 (0.8) | 3.5-4.9 / 4.7-5.1 -> 8.3-11.5 / 11.8-14.9 |
| height 1.05 | 1.71-3.30 | 0.05 / 0.01 | 0.18 | 0.0 (0.3) -> 0.0 (0.0) | 2.8-4.5 / 2.9-3.1 -> 5.6-10.2 / 7.3-10.0 |
| width 0.7 | 1.59-2.69 | 0.01 / 0.01 | 0.18 | 0.3 (3.3) -> 0.0 (0.0) | 4.0-7.0 / 2.7-4.8 -> 2.2-9.2 / 6.0-8.6 |
| width 1.0 | 2.03-3.31 | 0.01 / 0.01 | 0.18 | 0.1 (1.5) -> 0.0 (0.0) | 3.0-4.3 / 3.3-3.6 -> 6.7-11.1 / 8.7-11.4 |
| depth 0.75 | 2.03-3.13 | 0.04 / 0.01 | 0.18 | 0.0 (0.1) -> 0.0 (0.3) | 1.3-2.1 / 1.6 -> 4.3-6.3 / 5.6-6.5 |
| head 0.95 | 1.81-3.15 | 0.02 / 0.01 | 0.18 | 0.1 (1.8) -> 0.0 (0.0) | 3.1-5.0 / 3.6-4.2 -> 6.6-10.3 / 8.6-10.6 |
| R6 (default body) | 3.66-4.90 (no pose: Roblox's tool pose) | 0.09 / 0.00 | 0.18 | 0.0 (0.0) -> 0.2-0.4 (5.8) | 0 / - -> 5.0-8.9 / - |
| user's avatar, Motor6D joints | (not measured) | 0.02 / 0.01 | 0.18 | - -> 0.0 (0.0) | - -> 7.8-11.1 / 9.9-10.3 |

Barrel vs aim: max 0.82 degrees over all 975 v0.1.1 samples (Rthro rifle), 0.37 or less elsewhere.
A custom rig the pose doesn't know (R15 with the left hand renamed): no IKControls, Roblox's tool
pose, 0 errors in the log.

What it took (each step measured on the blocky body before it was kept):
- Joint limits off on the waist, neck and arms while a gun is out (client only, restored when put
  away): with them on, the waist stopped at 20 degrees right and the arms 0.5-1.0 stud short of
  targets well inside their reach.
- The chest turned by its own LookAt on the waist alone: the old UpperTorso-to-Head LookAt split the
  turn between waist and neck (20-30 of 65 degrees). A Rotation control on that one-part chain made
  the whole body NaN.
- Each arm's reach from the rig's own attachments; fitHands keeps both hand targets inside 0.9 of it
  (the left hand slides back along the gun first, then the gun moves).
- The chest stays upright (bending it with the aim's pitch swung the turned chest into the gun:
  rifle gun-in-body mean 8.4% at 0.8 of the pitch vs 2.1% at 0).
- The head turned on its neck joint directly, level: a LookAt picked its own roll and from the turned
  chest rolled the head into the stock when aiming down (8.9-18.6% head-in-gun at pitch -60).
- The left arm as a Transform IK (palm position and turn): a Position control placed the wrist as if
  the hand kept its animated turn, and the hand missed by about the wrist-to-palm length (0.13 with
  the hand's centre as end effector, 0.29-0.44 with the palm). Its target is an Attachment on the
  root, computed from the hold point (moving it there off the gun changed nothing measurable by
  itself: 0.34-0.44 before and after; the Transform type fixed it, 0.01).
- No elbow poles: with the limits off, poles made more arm clipping than none on held-out aims.
- R6: an IKControl on a one-joint Motor6D chain slid the shoulder instead of turning it (arms came
  off), so R6 arms are pointed directly; its whole body turns 80 degrees for long guns (at 65 the
  torso's corner was in the gun's path: 5.8% -> 0.7%).

Verdict: both hands on the gun on every rig, aim and gun tested (left within 0.09 stud of its spot,
palm within 0.18 of the gun's surface), gun-in-body mean at or below v0.1.0 on every R15 rig
(single-aim maxima up to 0.8%; the two maxima that rose: slender rifle 0.0 -> 0.5, depth-0.75 rifle
0.1 -> 0.3). NOT better on two counts: (1) arms crossing the chest overlap the body box about
twice as much as v0.1.0 (where the left arm hung away from the gun), worst aiming the pistol 60
degrees down (upper arm / forearm up to ~29%); (2) R6 long guns put 0.2-0.4% of the gun in the body on
average, up to 5.8% at the capped hard-right-and-down corner (v0.1.0 didn't pose R6 at all).
Blind spots: anchored and standing (no walk/run/jump), solo (other players see the same code fed by
the replicated aim, not checked here), no mesh body packages (Rthro here = BodyTypeScale on the
default body), no layered clothing.

Dev setup: `rojo serve dev.project.json` (Rojo 7.7.1 via rokit) syncs src/ into the place under
Workspace.WeaponKit and this folder into ReplicatedStorage.WeaponKitDev (dev only, never shipped):
`require(game.ReplicatedStorage.WeaponKitDev.pose_audit)` in a Play client.
