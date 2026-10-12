#!/usr/bin/env bash
# Run the Godot headless tests and fail on any script error.
# The runner passes a test only on the exact return value "ok", so a method that
# aborts on a script error (typed default "") shows FAIL. This wrapper is a
# second guard: it also fails the run if the output contains "SCRIPT ERROR" or
# an engine "ERROR:" line.
# Usage: game/tests/run.sh [godot-binary] [filter...]
#   e.g. game/tests/run.sh godot test_bag doomsday
# Each filter is a plain substring of a test file name; with filters, only the
# matching test_*.gd files run. No filters runs the full suite.
set -uo pipefail
GODOT="${1:-${GODOT:-godot}}"
if [ $# -gt 0 ]; then shift; fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# A fresh clone has no .godot import cache; without an import pass the -s run
# below hangs indefinitely (seen 2026-10-02 on a clean checkout).
"$GODOT" --headless --path "$HERE" --import >/dev/null 2>&1 || true
if [ $# -gt 0 ]; then
  out="$("$GODOT" --headless --path "$HERE" -s res://tests/run_tests.gd -- "$@" 2>&1)"
else
  out="$("$GODOT" --headless --path "$HERE" -s res://tests/run_tests.gd 2>&1)"
fi
rc=$?
printf '%s\n' "$out"
if printf '%s\n' "$out" | grep -qE '^(SCRIPT ERROR|ERROR):'; then
  echo "run.sh: script or engine error in test output; failing the run" >&2
  exit 1
fi
exit "$rc"
