extends RefCounted
## Smoke test: proves the runner discovers and runs tests.
## A test returns "" on success or a failure message string.

func test_arithmetic() -> String:
	return "" if 1 + 1 == 2 else "1 + 1 != 2"

func test_engine_is_godot_4() -> String:
	return "" if Engine.get_version_info()["major"] == 4 else "expected Godot 4"
