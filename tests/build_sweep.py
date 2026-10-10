#!/usr/bin/env python3
# Builds sweep_test.luau = kit sources + mock world (body.luau) + the coverage sweep.
# Separate from the committed suite; used to find the saturation point, not run in CI.
import os

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, "..", "src")

srcs = {
    "shared/Config": "shared/Config.luau",
    "shared/Weapons": "shared/Weapons.luau",
    "server/PlayerData": "server/PlayerData.luau",
    "server/RateLimit": "server/RateLimit.luau",
    "server/Suspicion": "server/Suspicion.luau",
    "server/AimStats": "server/AimStats.luau",
    "server/Movement": "server/Movement.luau",
    "server/LabQuery": "server/LabQuery.luau",
    "server/WeaponServer": "server/WeaponServer.luau",
}

out = ["local SOURCES = {}"]
for k, p in srcs.items():
    t = open(os.path.join(root, p), encoding="utf-8").read()
    assert "]=====]" not in t
    out.append('SOURCES["%s"] = [=====[\n%s]=====]' % (k, t))
for part in ("body.luau", "sweep.luau"):
    out.append(open(os.path.join(here, part), encoding="utf-8").read())
out.append('print(string.format("done: %d passed, %d failed", passes, failures))')

open(os.path.join(here, "sweep_test.luau"), "w", encoding="utf-8").write("\n".join(out))
