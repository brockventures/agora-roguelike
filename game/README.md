# AGORA Roguelike (Godot 4)

Godot project root. Layout: `res://core` (simulation), `res://ui`, `res://tests`.

Pinned Godot version: **4.7.2-stable** (see `.github/workflows/godot.yml`).

## Run the tests

```
game/tests/run.sh            # uses `godot` on PATH, or pass the binary path
```

The runner (`tests/run_tests.gd`) finds every `test_*.gd` under `res://tests`,
runs each `test_*` method, prints PASS/FAIL, and exits 1 if anything failed.
A test method is typed `-> String` and returns `""` to pass or a failure message to fail. Anything else, such as null after a script error, counts as a failure.
