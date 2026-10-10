#!/usr/bin/env python3
# Mutation check: each mutation re-breaks one anti-cheat rule in a COPY of the kit (made next to this
# file in work/, git-ignored) and the
# suite must then fail. Usage: python tests/mutate.py . luau   (from weapon_kit/)
import os, re, shutil, subprocess, sys

kit, luau = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))
work = os.path.join(here, "work")

MUTATIONS = [
    ("judge in the same frame (no deferral)", "server/Movement.luau",
     "\t\tentry.pending = { verdicts = verdicts, sample = sample, at = now }",
     "\t\trespond(player, entry, verdicts, sample, now - 1e-6, now)"),
    ("trust every server write", "server/Movement.luau",
     "\treturn now >= entry.distrustUntil\nend", "\treturn true\nend"),
    ("server move restarts the checks (launders the spot)", "server/Movement.luau",
     "\t\tMovement.shift(entry.state, offset, now, hold)", "\t\tMovement.reset(entry.state, to, now, hold)"),
    ("deferred move measured from this frame's read", "server/Movement.luau",
     "if entry.seenFrame == frame then entry.seenPrev else entry.seen", "entry.seen"),
    ("same-frame sample not taken back", "server/Movement.luau",
     "\tif not (snapshot and snapshot.frame == frame) then", "\tif true then"),
    ("server push allows any speed", "server/Movement.luau",
     "\t\tpushSpeed = push.speed\n", "\t\tpushSpeed = math.huge\n"),
    ("server push never ends", "server/Movement.luau",
     "\tif push and not push.sustained and supported and now - push.at >= limits.SERVER_PUSH_TIME + ping then",
     "\tif false then"),
    ("server push allows any height", "server/Movement.luau",
     "\t\t\tpeak += pushPeak", "\t\t\tpeak = math.huge"),
    ("speed mover switches the checks off", "server/Movement.luau",
     "\t\t\tif s and l then", "\t\t\tif false then"),
    ("every mover counts as active", "server/Movement.luau",
     "\treturn ok and active == true\nend", "\treturn true\nend"),
    ("hold counted from the snap frame", "server/Movement.luau",
     "LIMITS.RUBBERBAND_HOLD - (now - sampledAt)", "LIMITS.RUBBERBAND_HOLD"),
    ("report every refusal", "server/WeaponServer.luau",
     "\tif #times >= limits.FAST_FLAG_COUNT then", "\tif true then"),
    ("no clump merge", "server/WeaponServer.luau",
     "\tif not s.acceptedSinceFast then\n\t\treturn\n\tend", ""),
    ("jitter credit 0.08 s (the first plan)", "shared/Config.luau",
     "FIRE_JITTER = 0.1,", "FIRE_JITTER = 0.08,"),
    ("credit banks up (schedule from arrival)", "server/WeaponServer.luau",
     "s.lastShot = math.max(now, s.lastShot + wait)", "s.lastShot = now"),
    ("rewound shot passes through walls", "server/WeaponServer.luau",
     "castPast(origin, direction, (endPoint - origin).Magnitude, past)", "castPast(origin, direction, math.huge, past)"),
    ("rewind keeps the whole history", "server/LagComp.luau",
     "\t\t\twhile now - times[1] > window do", "\t\t\twhile false do"),
    ("rewind crosses teleports", "server/LagComp.luau",
     "> TELEPORT_STEP then", "> math.huge then"),
    ("rewind ignores turning", "server/LagComp.luau",
     "cf:PointToObjectSpace(origin), cf:VectorToObjectSpace(direction)", "origin - at, direction"),
    ("rewind hits anything with a Humanoid", "server/WeaponServer.luau",
     "\t\t\tif humanoid and canDamage(shooter, model, humanoid) then\n\t\t\t\ttable.insert(list, model)",
     "\t\t\tif humanoid then\n\t\t\t\ttable.insert(list, model)"),
]

results = []
for name, rel, old, new in MUTATIONS:
    if os.path.exists(work):
        shutil.rmtree(work)
    shutil.copytree(os.path.join(kit, "src"), os.path.join(work, "src"))
    shutil.copytree(os.path.join(kit, "tests"), os.path.join(work, "tests"),
                    ignore=shutil.ignore_patterns("work"))  # (work/ lives inside tests/)
    shutil.copy(os.path.join(kit, "rokit.toml"), work)  # (the rokit luau shim needs its manifest)
    path = os.path.join(work, "src", rel)
    text = open(path, encoding="utf-8").read()
    if text.count(old) != 1:
        results.append((name, "MUTATION NOT APPLIED (pattern count %d)" % text.count(old)))
        continue
    open(path, "w", encoding="utf-8").write(text.replace(old, new))
    tests = os.path.join(work, "tests")
    subprocess.run([sys.executable, "build.py"], cwd=tests, check=True)
    st = os.path.join(tests, "server_test.luau")
    body = open(st, encoding="utf-8").read()
    open(st, "w", encoding="utf-8").write("FUZZ_ITER = 20000\n" + body)
    out = subprocess.run([luau, "server_test.luau"], cwd=tests, capture_output=True, text=True, encoding="utf-8", errors="replace")
    m = re.search(r"done: (\d+) passed, (\d+) failed", out.stdout)
    fails = [l.strip() for l in out.stdout.splitlines() if l.startswith("FAIL")][:3]
    if m:
        verdict = "CAUGHT (%s failed)" % m.group(2) if m.group(2) != "0" else "NOT CAUGHT"
    else:
        verdict = "CAUGHT (crash)" if out.returncode else "NO SUMMARY"
    results.append((name, verdict + ("\n      " + "\n      ".join(fails) if fails else "")))

for name, verdict in results:
    print("%-42s %s" % (name, verdict))
