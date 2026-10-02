extends SceneTree
## Minimal dependency-free test runner.
## Discovers res://tests/**/test_*.gd, runs every method named test_*,
## prints PASS/FAIL per test and exits 1 on any failure.
##
## A test script extends RefCounted and defines test_* methods. A test passes
## if it returns "" (or nothing) and fails if it returns a non-empty String
## (the failure message).

const TEST_DIR := "res://tests"

func _init() -> void:
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
			if result is String and result != "":
				print("FAIL  %s: %s" % [label, result])
				failed += 1
			else:
				print("PASS  %s" % label)
				passed += 1
	print("%d passed, %d failed" % [passed, failed])
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
