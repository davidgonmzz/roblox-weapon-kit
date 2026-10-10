#!/usr/bin/env python3
# Stitches the kit's server sources and the mock-world test files into a single
# server_test.luau that runs under the plain Luau CLI (no Roblox, no Studio).
# Paths are relative to this file, so it works in CI and on any machine.
import os

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, "..", "src")

srcs = {
    "shared/Config": "shared/Config.luau",
    "shared/Weapons": "shared/Weapons.luau",
    "shared/Ballistics": "shared/Ballistics.luau",
    "server/PlayerData": "server/PlayerData.luau",
    "server/RateLimit": "server/RateLimit.luau",
    "server/Remotes": "server/Remotes.luau",
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
for part in ("body.luau", "new_tests.luau", "wrapper_tests.luau", "integration_tests.luau", "fuzz.luau"):
    out.append(open(os.path.join(here, part), encoding="utf-8").read())
out.append('print(string.format("done: %d passed, %d failed", passes, failures))')

open(os.path.join(here, "server_test.luau"), "w", encoding="utf-8").write("\n".join(out))
