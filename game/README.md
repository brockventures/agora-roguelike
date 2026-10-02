# AGORA Roguelike (Godot 4)

Godot project root. Layout: `res://core` (simulation), `res://ui`, `res://tests`.

Pinned Godot version: **4.7.2-stable** (see `.github/workflows/godot.yml`).

## Run the tests

```
godot --headless --path game -s res://tests/run_tests.gd
```

The runner (`tests/run_tests.gd`) finds every `test_*.gd` under `res://tests`,
runs each `test_*` method, prints PASS/FAIL, and exits 1 if anything failed.
A test method returns `""` to pass, or a failure message string to fail.
