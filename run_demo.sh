#!/usr/bin/env bash
# run_demo.sh - Zero-dependency launcher for AGORA Roguelike demo
# Supports desktop execution and Steam Deck Game Mode preset.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME_DIR="$HERE/game"
DEFAULT_BIN="$HERE/.godot-bin/Godot_v4.7.2-stable_linux.x86_64"

# 1. Resolve Godot executable
GODOT_BIN="${GODOT:-}"
if [ -z "$GODOT_BIN" ]; then
    if [ -x "$DEFAULT_BIN" ]; then
        GODOT_BIN="$DEFAULT_BIN"
    elif command -v godot >/dev/null 2>&1; then
        GODOT_BIN="$(command -v godot)"
    elif command -v godot4 >/dev/null 2>&1; then
        GODOT_BIN="$(command -v godot4)"
    else
        echo "Error: Godot 4.7.2 binary not found." >&2
        echo "Expected at: $DEFAULT_BIN" >&2
        echo "Or install 'godot' in your PATH, or set the GODOT environment variable." >&2
        exit 1
    fi
fi

# 2. Parse flags & build engine arguments
EXTRA_ARGS=()
PRESET_DECK=false
PRESET_WINDOWED=false
PRESET_FULLSCREEN=false

print_usage() {
    cat << 'EOF'
Usage: ./run_demo.sh [options] [-- <additional godot args>]

AGORA Roguelike — M0 Playable Vertical Slice Launcher

Options:
  --deck            Preset for Steam Deck Game Mode (fullscreen, 1280x800 native)
  -f, --fullscreen  Launch in fullscreen mode
  -w, --windowed    Launch in windowed mode (default: 1280x800)
  --headless        Launch in headless mode (for CI / smoke tests)
  -h, --help        Show this help message

Steam Deck Note:
  Add ./run_demo.sh as a Non-Steam Game in Steam Desktop Mode with launch
  options: ./run_demo.sh --deck

Controls (M0 loop):
  LB / RB (Q / E)         Tab prev / next (Map, Market, Fleet)
  LT / RT (1 / 2)         Station prev / next
  R-Stick X (3 / 4)       Commodity prev / next
  D-pad / L-Stick (WASD)  Focus ladder, BUY/SELL, quantity
  A (Space / Enter)       Submit order
  B (Esc / Backspace)     Cancel / back
  X (X)                   File Chapter 11
  Y (R)                   Cycle sim speed (1x, 2x, 5x, pause)
  Start (P)               Pause / resume
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deck)
            PRESET_DECK=true
            shift
            ;;
        -f|--fullscreen)
            PRESET_FULLSCREEN=true
            shift
            ;;
        -w|--windowed)
            PRESET_WINDOWED=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

GODOT_ARGS=("--path" "$GAME_DIR")

if [ "$PRESET_DECK" = true ]; then
    GODOT_ARGS+=("--fullscreen" "--resolution" "1280x800")
elif [ "$PRESET_FULLSCREEN" = true ]; then
    GODOT_ARGS+=("--fullscreen")
elif [ "$PRESET_WINDOWED" = true ]; then
    GODOT_ARGS+=("--windowed" "--resolution" "1280x800")
fi

# Execute Godot engine
exec "$GODOT_BIN" "${GODOT_ARGS[@]}" "${EXTRA_ARGS[@]}"
