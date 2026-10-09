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
