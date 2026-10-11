extends SceneTree
## Regenerates game/tests/fixtures/world/rescue_goldens.json (#32 task 5).
##
##   godot --headless --path game -s res://tools/regen_rescue_goldens.gd
##
## Run it only when a change to the rescue's behaviour is MEANT to move the whole-run hashes, then
## list the old and new hash per seed in the PR. The scripted rescue is tools/rescue_bot.gd.

const OUT := "res://tests/fixtures/world/rescue_goldens.json"


func _init() -> void:
	var rb = load("res://tools/rescue_bot.gd")
	var recs: PackedStringArray = []
	for sd in rb.SEEDS:
		var res: Dictionary = rb.haul(int(sd), rb.GOLDEN_CR)
		var rec: Dictionary = rb.to_recording(res, int(sd), rb.GOLDEN_CR)
		var rep: Dictionary = rb.haul_report(res["session"])
		var fields: PackedStringArray = []
		var keys: Array = rec.keys()
		keys.sort()
		for k in keys:
			if k != "ops":
				fields.append("   %s: %s" % [JSON.stringify(k), JSON.stringify(rec[k])])
		var ops: PackedStringArray = []
		for e in rec["ops"]:
			ops.append("    " + JSON.stringify(e))
		fields.append("   \"ops\": [\n%s\n   ]" % ",\n".join(ops))
		recs.append("  \"%d\": {\n%s\n  }" % [int(sd), ",\n".join(fields)])
		print("seed %d: %d ops, %d frames, won %s in round %d (phases %s), hash %s" % [sd, rec["ops"].size(), rec["frames"], str(rep["won"]), rep["round_end"], str(rep["completed"]), rec["state_hash"]])
	var desc: String = "The Sol System Rescue Project played end to end from the monopoly (the player holds every baron with %d CR, rival fleets on, the real 900-tick round) by the greedy hauler in tools/rescue_bot.gd, as op recordings (a buy, a depart, an m0_project delivery, a modal answer, each with the frame and tick it landed on). state_hash is RunSave.state_hash at the end. Checked by game/tests/test_rescue_goldens.gd; regenerate with tools/regen_rescue_goldens.gd only for a deliberate change to the rescue's behaviour." % rb.GOLDEN_CR
	var text: String = "{\n \"case\": \"rescue_goldens\",\n \"description\": %s,\n \"recordings\": {\n%s\n }\n}\n" % [JSON.stringify(desc), ",\n".join(recs)]
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
