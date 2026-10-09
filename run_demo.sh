#!/usr/bin/env bash
# run_demo.sh - Zero-dependency launcher for AGORA Roguelike demo
# Supports desktop execution, automated engine fetch, and Steam Deck Game Mode preset.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME_DIR="$HERE/game"
DEFAULT_BIN_DIR="$HERE/.godot-bin"
GODOT_VERSION="4.7.2-stable"
GODOT_SHA512="9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65"
DEFAULT_BIN="$DEFAULT_BIN_DIR/Godot_v${GODOT_VERSION}_linux.x86_64"

fetch_godot() {
    local zip_file="$DEFAULT_BIN_DIR/godot.zip"
    if [ -x "$DEFAULT_BIN" ]; then
        echo "Godot $GODOT_VERSION already installed at $DEFAULT_BIN"
        return 0
    fi

    echo "Fetching Godot $GODOT_VERSION for Linux x86_64..."
    mkdir -p "$DEFAULT_BIN_DIR"
    curl -fsSL -o "$zip_file" \
        "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip"

    echo "Verifying SHA-512 checksum..."
    echo "${GODOT_SHA512}  ${zip_file}" | sha512sum -c -

    echo "Extracting binary..."
    if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$zip_file" -d "$DEFAULT_BIN_DIR"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import zipfile; zipfile.ZipFile('$zip_file').extractall('$DEFAULT_BIN_DIR')"
    else
        echo "Error: Neither unzip nor python3 found to extract $zip_file" >&2
        exit 1
    fi
    rm -f "$zip_file"
    chmod +x "$DEFAULT_BIN"
    echo "Godot $GODOT_VERSION successfully installed to $DEFAULT_BIN"
}

print_usage() {
    cat << 'EOF'
Usage: ./run_demo.sh [options] [-- <additional godot args>]

AGORA Roguelike — M0 Playable Vertical Slice Launcher

Options:
  --deck            Preset for Steam Deck Game Mode (fullscreen, 1280x800 native)
  --fetch           Download verified Godot 4.7.2 binary to .godot-bin/
  -f, --fullscreen  Launch in fullscreen mode
  -w, --windowed    Launch in windowed mode (default: 1280x800)
  --headless        Launch in headless mode (for CI / smoke tests)
  -h, --help        Show this help message

Note: Any additional flags (e.g. --quit-after <N>, --verbose) are forwarded to Godot.

Steam Deck Note:
  1. In Steam Desktop Mode, run: ./run_demo.sh --fetch
  2. Add ./run_demo.sh as a Non-Steam Game with launch option: --deck

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

# 1. Parse flags
EXTRA_ARGS=()
PRESET_DECK=false
PRESET_WINDOWED=false
PRESET_FULLSCREEN=false
DO_FETCH=false
HEADLESS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fetch)
            DO_FETCH=true
            shift
            ;;
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
        --headless)
            HEADLESS=true
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

if [ "$DO_FETCH" = true ]; then
    fetch_godot
    # If called with only --fetch, exit cleanly after fetch
    if [ "$PRESET_DECK" = false ] && [ "$PRESET_FULLSCREEN" = false ] && [ "$PRESET_WINDOWED" = false ] && [ "$HEADLESS" = false ] && [ ${#EXTRA_ARGS[@]} -eq 0 ]; then
        exit 0
    fi
fi

# 2. Resolve Godot executable
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
        echo "Run './run_demo.sh --fetch' to download Godot 4.7.2 into .godot-bin/," >&2
        echo "or install Godot on PATH, or set the GODOT environment variable." >&2
        exit 1
    fi
fi

# 3. Assemble arguments
GODOT_ARGS=("--path" "$GAME_DIR")

if [ "$HEADLESS" = true ]; then
    GODOT_ARGS+=("--headless")
fi

if [ "$PRESET_DECK" = true ]; then
    GODOT_ARGS+=("--fullscreen" "--resolution" "1280x800")
elif [ "$PRESET_FULLSCREEN" = true ]; then
    GODOT_ARGS+=("--fullscreen")
elif [ "$PRESET_WINDOWED" = true ]; then
    GODOT_ARGS+=("--windowed" "--resolution" "1280x800")
fi

# Execute Godot engine
exec "$GODOT_BIN" "${GODOT_ARGS[@]}" "${EXTRA_ARGS[@]}"
