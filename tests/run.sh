#!/usr/bin/env bash
# Rebuilds and runs the mock-world test suite. No Roblox or Studio needed.
# Requires: python3 and luau on PATH (install both with Rokit: `rokit install`).
set -euo pipefail
cd "$(dirname "$0")"
python3 build.py
luau server_test.luau
