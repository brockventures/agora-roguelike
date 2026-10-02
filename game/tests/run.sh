#!/usr/bin/env bash
# Run the Godot headless tests and fail on any script error.
# Godot aborts a test method that hits a script error and returns the typed
# default ("" for String), which the runner counts as a pass, so the runner's
# exit code alone cannot catch a crashing test. This wrapper also fails the run
# if the output contains "SCRIPT ERROR" or an engine "ERROR:" line.
# Usage: game/tests/run.sh [path-to-godot-binary]   (default: godot on PATH)
set -uo pipefail
GODOT="${1:-${GODOT:-godot}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$("$GODOT" --headless --path "$HERE" -s res://tests/run_tests.gd 2>&1)"
rc=$?
printf '%s\n' "$out"
if printf '%s\n' "$out" | grep -qE '^(SCRIPT ERROR|ERROR):'; then
  echo "run.sh: script or engine error in test output; failing the run" >&2
  exit 1
fi
exit "$rc"
