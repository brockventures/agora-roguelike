# AGORA Roguelike (Godot 4)

Godot project root. Layout: `res://core` (simulation), `res://ui`, `res://tests`.

Pinned Godot version: **4.7.2-stable** (see `.github/workflows/godot.yml`).

## Run the interactive demo

```bash
./run_demo.sh            # Standard windowed demo (1280x800)
./run_demo.sh --deck     # Steam Deck Game Mode preset (fullscreen 1280x800)
./run_demo.sh -f         # Fullscreen mode
./run_demo.sh --fetch    # Download verified Godot 4.7.2 into .godot-bin/
./run_demo.sh --headless # Headless smoke test
```

## Run the tests

```
game/tests/run.sh            # uses `godot` on PATH, or pass the binary path
```

The runner (`tests/run_tests.gd`) finds every `test_*.gd` under `res://tests`,
runs each `test_*` method, prints PASS/FAIL, and exits 1 if anything failed.
A test method is typed `-> String` and returns exactly `"ok"` to pass or a failure message to fail. Anything else counts as a failure, including `""`, which is what Godot returns for a method that aborted on a script error, so a crashing test shows FAIL in the runner itself.

## Saves, profile and replays

Everything persistent lives under one Steam Cloud root, `user://saves/`
(override with the `AGORA_SAVE_DIR` environment variable; tests use a temp
directory under `user://test_tmp/` and clean it up):

| File | Contents |
|---|---|
| `user://saves/profile.json` | `MetaProfile` and bought Golden Parachutes perks. Loaded at startup, rewritten when it changes and on quit. |
| `user://saves/run_slot_0.json` | The run in progress: CR, cargo, ships, sim clock, doomsday clock, perk modifiers, every resting order book and the `Bags` marble state (streak counters, drawn/remaining marbles), so bad-luck protection survives a restart. Autosaved at each round advance and on quit; the game resumes it at startup. |

Both are `{"schema_version": 1, "kind": ..., "data": {...}}` envelopes
(`core/save_store.gd`). Writes go to `<file>.tmp` and are renamed over the real
file, so an interrupted write keeps the previous save. A file with another
`schema_version`, the wrong `kind`, or invalid JSON is rejected with an error
and ignored (the game starts a fresh run or profile); it is never migrated or
overwritten until the next save. Headless runs (tests, `--headless`) never
enable persistence. JSON keeps about 15 significant digits of a float, so the
sim clock accumulator can differ by around 1e-15 across a save.

### Seeded replays

`core/replay.gd` records the `m0_*` actions dispatched through `M0Loop`, each
with the frame and sim tick it happened on, plus the seed, starting profile and
a SHA-256 hash of the final state (`RunSave.state_hash`: ledger, cargo, clocks,
order books and Bags). Replaying re-runs the same fixed-step session headless
and fails if an input lands on a different tick or the final hash differs.

```bash
GODOT=godot   # or the path to the 4.7.2 binary
$GODOT --headless --path game -s res://tools/replay.gd -- --record-demo /tmp/demo.json [seed]
$GODOT --headless --path game -s res://tools/replay.gd -- /tmp/demo.json
# PASS ... (exit 0)  |  FAIL ... (exit 1)  |  unreadable file (exit 2)
```

Recordings are driven by fixed frames (`Replay.Session.advance()`), not
wall-clock time; the live game does not record yet.

## Controls (M0 loop)

Defined as `m0_*` actions in `project.godot`, routed by `ui/m0_loop.gd`:

| Action | Pad | Keyboard |
|---|---|---|
| Tab prev / next (Map, Market, Fleet) | LB / RB | Q / E |
| Station prev / next (disabled in M0: the one tradable station is Mars) | LT / RT | 1 / 2 |
| Commodity prev / next | Right stick left / right | 3 / 4 |
| Focus ladder, BUY/SELL, quantity | D-pad or left stick | Arrows or WASD |
| Submit order (A) | A | Space / Enter |
| Cancel / back (B) | B | Esc / Backspace |
| Run over: A summary → perks → new run; D-pad picks perks, A buys / starts | A, D-pad | Space, arrows |
| File Chapter 11 (X) | X | X |
| Cycle speed 1x, 2x, 5x, pause (Y) | Y | R |
| Pause / resume | Start | P |
| Cycle language (en, pseudo; hot swap) | View / Back | L |

## Localization (#40)

All player-facing text comes from `res://localization/agora_strings.csv`
(`keys,en`; Godot's CSV translation importer, registered in `project.godot`).
Add a language by adding a column (`de`, `ja`, `zh_CN`), re-import, and add its
code to `Loc.CHOICES`; there is no code change beyond that.

- **Code:** `tr("HUD_SPEED") % value` in instance code, `Loc.t(...)` in `static`
  funcs (where `tr()` is unavailable). Keys are stable names; `%s`/`%d`
  placeholders live in the translated text, never in the key. Label text is set
  already translated, so HUD labels have `auto_translate_mode = DISABLED`.
- **Data files** (`crises.json`, `parachutes.json`, stations, commodities) keep
  their English as the source of truth and fallback. Display text is looked up
  through a key derived from the id: `CRISIS_<ID>_NAME`, `CRISIS_<ID>_HEADLINE`
  (with `{rounds}`/`{commodity}`/`{station}`), `CRISIS_TIER_<TIER>`,
  `PERK_<ID>_NAME`, `PERK_BRANCH_<BRANCH>`, `STATION_<ID>`, `COMMODITY_<CODE>`
  (`Loc.data_text`). A test fails if a data entry has no key or the CSV's
  English drifts from the data file. Sim state, saves and replays stay English.
- **Ticker:** `OrbitalHUD.post_headline_tr(key, args, ...)` keeps key + args, so
  lines already on the ticker re-render on a language swap.
- **Language selector:** the `m0_locale` action (L / View) calls
  `Loc.cycle_locale()`; `Loc.set_locale(code)` is the programmatic entry. The
  readouts re-read `tr()` every frame, so the swap is visible on the next frame.
- **Pseudo-localization:** `AGORA_PSEUDO=1 ./run_demo.sh` (or `AGORA_LOCALE=pseudo`,
  or the language action) turns on Godot's pseudolocalization: accents, doubled
  vowels, +30% length and `[brackets]` (`internationalization/pseudolocalization/*`).
- **Guards (headless tests):** `test_localization.gd` (CSV, keys, data coverage,
  hot swap), `test_i18n_audit.gd` (regex lint: no raw English literal reaches a
  label, the ticker, a formatter list or `draw_string`; mark an exception with
  `# i18n-ok`), `test_i18n_fit.gd` (every HUD label fits its container at
  1280x800 in English and under pseudo-localization).
