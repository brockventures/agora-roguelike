extends SceneTree
## Minimal dependency-free test runner.
## Discovers res://tests/**/test_*.gd, runs every method named test_*,
## prints PASS/FAIL per test and exits 1 on any failure.
##
## A test script extends RefCounted and defines test_* methods typed `-> String`.
## A test passes only if it returns exactly "ok"; any other String is the failure
## message. Godot aborts a method that hits a script error and returns the typed
## default ("" for String), so "" is deliberately a FAIL: a crashing test shows
## FAIL in the runner itself. The game/tests/run.sh wrapper is a second guard and
## also fails the run on SCRIPT ERROR or engine ERROR: output.

const TEST_DIR := "res://tests"
const PASS_SENTINEL := "ok"

func _init() -> void:
	# Existing tests assert English text: pin the locale whatever the host's is.
	Loc.set_locale(Loc.LOCALE_EN)
	var passed := 0
	var failed := 0
	for path in _find_tests(TEST_DIR):
		var script = load(path)
		if script == null:
			print("FAIL  %s (could not load)" % path)
			failed += 1
			continue
		var inst = script.new()
		for m in script.get_script_method_list():
			var name: String = m["name"]
			if not name.begins_with("test_"):
				continue
			var label := "%s::%s" % [path.get_file(), name]
			var result = inst.call(name)
			if result is String and result == PASS_SENTINEL:
				print("PASS  %s" % label)
				passed += 1
			else:
				var why: String
				if result is String and result != "":
					why = result
				else:
					why = "returned %s, not \"ok\" (script error or missing return)" % [var_to_str(result)]
				print("FAIL  %s: %s" % [label, why])
				failed += 1
	print("%d passed, %d failed" % [passed, failed])
	# The shared Steam service (and any SaveStore it attached) must not outlive the run,
	# or the engine reports leaked instances at exit and run.sh fails the run.
	SteamService.set_shared(null)
	quit(1 if failed > 0 else 0)

func _find_tests(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	var names: Array = Array(dir.get_files())
	names.sort()
	for f in names:
		if f.begins_with("test_") and f.ends_with(".gd"):
			out.append(dir_path.path_join(f))
	var subs: Array = Array(dir.get_directories())
	subs.sort()
	for d in subs:
		out.append_array(_find_tests(dir_path.path_join(d)))
	return out
