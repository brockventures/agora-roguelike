# AGENTS.md

Two things live in this repo:

- `agora/`, `tools/`, `tests/`, `db/`, `public/`, `docs/`: the Python market sandbox (the Station Agora referee, ledger, web terminal). See `README.md`.
- `game/`: a Godot 4 roguelike built on the same economy. Pinned engine: **4.7.2-stable** (`.github/workflows/godot.yml`).

## Test

Godot tests (`game/`): no full build is needed, the suite runs headless.

```
# Download the exact CI binary (URL and SHA512 are in .github/workflows/godot.yml)
mkdir -p .godot-bin && curl -fsSL -o .godot-bin/godot.zip \
  "https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip"
echo "<GODOT_SHA512 from godot.yml>  .godot-bin/godot.zip" | sha512sum -c -
python3 -c "import zipfile;zipfile.ZipFile('.godot-bin/godot.zip').extractall('.godot-bin')"
chmod +x .godot-bin/Godot_v4.7.2-stable_linux.x86_64

game/tests/run.sh "$PWD/.godot-bin/Godot_v4.7.2-stable_linux.x86_64"
```

`run.sh` runs the import pass first (a fresh clone hangs without it), then `tests/run_tests.gd`, and fails on any `SCRIPT ERROR` or engine `ERROR:` line. `.godot-bin/` and `.godot/` are gitignored.

Python tests (what `.github/workflows/ci.yml` runs):

```
python -m unittest discover -s tests -v
python tools/golden/check_drift.py
python tools/fuzz_harness.py 1500
```

## Release

Tagging `vX.Y.Z` runs `.github/workflows/release.yml`: tests, then Linux, Windows and Steam Deck exports attached to a GitHub Release. See `docs/release.md`. Presets are in `game/export_presets.cfg`, guarded by `tests/test_export_presets.py`; running `Godot --export-release` locally needs export templates installed (see `docs/release.md`).

## Where things live (`game/`)

- `core/`: simulation models with no UI (`run_controller.gd`, `sim_clock.gd`, `doomsday_clock.gd`, `chapter11.gd`, `order_book.gd`, `station_market.gd`, ...).
- `ui/`: presentation models, plain `RefCounted` classes, not nodes (`orbital_hud.gd`, `gamepad_focus.gd`, `tactile_audio.gd`, `m0_loop.gd`, ...).
- `scenes/main.tscn` + `main.gd`: the root scene. It owns the nodes (SubViewportContainer with the CRT shader, panels, labels, audio players) and delegates to the `ui/` models.
- `tests/`: `test_*.gd` files, auto-discovered by `run_tests.gd`. `tests/golden/` holds fixtures shared with the Python referee.
- `export_presets.cfg`: the three release presets (Linux x86_64, Windows Desktop, Steam Deck).
- `project.godot`: window 1280x800 (Steam Deck), main scene, and the `m0_*` InputMap actions (joypad plus keyboard).

## Conventions

- Typed GDScript with `class_name`. Models expose `to_dict()` so state is assertable in tests.
- Money is integer CR.
- A test is a `func test_*() -> String` in a script that `extends RefCounted`. It returns exactly `"ok"` to pass; any other string is the failure message. A script error returns `""` and counts as a failure.
- New `.gd` files get their `.gd.uid` committed alongside (Godot generates it on import).
- Reuse the existing model APIs instead of duplicating them: `OrbitalHUD` is the hub that owns `GamepadFocus`, `TactileAudio`, `TradingOverlay`, `SolTacticalMap` and `VectorOrrery`.
- PRs target `main`; `docs/merge-authority.md` says who can merge.
