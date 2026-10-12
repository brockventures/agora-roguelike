extends SceneTree
## Regenerates game/tests/fixtures/world/policy_goldens.json (#160 row 3).
##
##   godot --headless --path game -s res://tools/regen_policy_goldens.gd
##
## Run it only when a change is MEANT to move the policy hashes, and say so in the PR. The
## scripted player is tools/policy_golden.gd. The world goldens (world_goldens.json) are NOT
## touched by this: they attach no policies.

const OUT := "res://tests/fixtures/world/policy_goldens.json"


func _init() -> void:
	var pg = load("res://tools/policy_golden.gd")
	var recs: PackedStringArray = []
	for sd in pg.SEEDS:
		var played: Replay.Session = pg.play(int(sd))
		var rec: Dictionary = played.to_recording()
		var fields: PackedStringArray = []
		var keys: Array = rec.keys()
		keys.sort()
		for k in keys:
			if k != "inputs":
				fields.append("   %s: %s" % [JSON.stringify(k), JSON.stringify(rec[k])])
		fields.append("   \"picks\": %s" % JSON.stringify(pg.picks_of(played)))
		var inputs: PackedStringArray = []
		for e in rec["inputs"]:
			inputs.append("    " + JSON.stringify(e))
		fields.append("   \"inputs\": [\n%s\n   ]" % ",\n".join(inputs))
		recs.append("  \"%d\": {\n%s\n  }" % [int(sd), ",\n".join(fields)])
		print("seed %d: %d inputs, %d frames, picks %s, hash %s" % [sd, rec["inputs"].size(), rec["frames"], str(pg.picks_of(played)), rec["state_hash"]])
	var desc: String = "The shipped world with corporate policies attached, played for %d rounds by the scripted player in tools/policy_golden.gd (first listed offer at each pick), as Replay recordings. A pick is the input policy:<id>. Checked by game/tests/test_policy_goldens.gd; regenerate with tools/regen_policy_goldens.gd only for a deliberate change." % pg.ROUNDS
	var text: String = "{\n \"case\": \"policy_goldens\",\n \"description\": %s,\n \"recordings\": {\n%s\n }\n}\n" % [JSON.stringify(desc), ",\n".join(recs)]
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
