extends SceneTree
## Regenerates game/tests/fixtures/world/world_goldens.json (Epic 3 task 12, part of #18).
##
##   godot --headless --path game -s res://tools/regen_world_goldens.gd
##
## Run it only when a change to the world's behaviour is MEANT to move the whole-world
## hashes (a replay-contract change), then say so in the PR: list the old and new hash
## per seed. The scripted player is tools/world_golden.gd.

const OUT := "res://tests/fixtures/world/world_goldens.json"


func _init() -> void:
	var wg = load("res://tools/world_golden.gd")
	var recs: PackedStringArray = []
	for sd in wg.SEEDS:
		var rec: Dictionary = wg.record(int(sd))
		var fields: PackedStringArray = []
		var keys: Array = rec.keys()
		keys.sort()
		for k in keys:
			if k != "inputs":
				fields.append("   %s: %s" % [JSON.stringify(k), JSON.stringify(rec[k])])
		var inputs: PackedStringArray = []
		for e in rec["inputs"]:
			inputs.append("    " + JSON.stringify(e))
		fields.append("   \"inputs\": [\n%s\n   ]" % ",\n".join(inputs))
		recs.append("  \"%d\": {\n%s\n  }" % [int(sd), ",\n".join(fields)])
		print("seed %d: %d inputs, %d frames, hash %s" % [sd, rec["inputs"].size(), rec["frames"], rec["state_hash"]])
	var desc: String = "The shipped world (barons, rival fleets, heat, random baron events) played for %d rounds by the scripted player in tools/world_golden.gd, as Replay recordings. state_hash is RunSave.state_hash at the end. Checked by game/tests/test_world_goldens.gd; regenerate with tools/regen_world_goldens.gd only for a deliberate replay-contract change." % wg.ROUNDS
	var text: String = "{\n \"case\": \"world_goldens\",\n \"description\": %s,\n \"recordings\": {\n%s\n }\n}\n" % [JSON.stringify(desc), ",\n".join(recs)]
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT), FileAccess.WRITE)
	if f == null:
		printerr("cannot write %s" % OUT)
		quit(2)
		return
	f.store_string(text)
	f.close()
	if JSON.parse_string(text) == null:
		printerr("wrote %s but it does not parse" % OUT)
		quit(1)
		return
	print("wrote %s" % OUT)
	quit(0)
