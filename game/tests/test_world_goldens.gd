extends RefCounted
## Epic 3 task 12 (part of #18, Rival Syndicate Fleets): whole-world replay and save goldens.
##
## The shipped world (barons, rival fleets, heat, random baron events, nothing stripped out)
## is played for 40 rounds, through the real round loop, by the scripted player in
## tools/world_golden.gd. Its inputs and final state hash for seeds 84 and 7 are the fixture
## tests/fixtures/world/world_goldens.json (not tests/golden/, which check_drift.py reserves
## for referee-generated parity fixtures). Because fleets and barons are pure functions of
## (seed, round, world, player), a replay of the player's inputs alone must land on the same
## hash (design doc 6.3).
##
## A failure here means the world's behaviour changed. If that was meant, regenerate with
##   godot --headless --path game -s res://tools/regen_world_goldens.gd
## and put the old and new hashes in the PR. If not, you have a determinism bug.

const FIXTURE := "res://tests/fixtures/world/world_goldens.json"
const WG := "res://tools/world_golden.gd"
const HINT := "If the change is deliberate, regenerate: godot --headless --path game -s res://tools/regen_world_goldens.gd (and list old/new hashes in the PR)."
## Where the save is taken: the player is mid-voyage Ceres -> Earth (left round 18).
const SAVE_ROUND: int = 19


func _fixture() -> Dictionary:
	return (JSON.parse_string(FileAccess.get_file_as_string(FIXTURE)) as Dictionary)["recordings"]


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


func test_the_fixture_replays_to_its_pinned_hash_for_both_seeds() -> String:
	var recs: Dictionary = _fixture()
	for sd in _seeds():
		var rec: Dictionary = recs[str(sd)]
		var res: Dictionary = Replay.replay(_json(rec))
		if not bool(res["ok"]):
			return "seed %d: world replay failed: %s. got %s, expected %s. %s" % [sd, res["error"], res["actual"], res["expected"], HINT]
		if int(res["frames"]) < 40 * 30 - 5:
			return "seed %d: the recording only ran %d frames" % [sd, res["frames"]]
	if str(recs["84"]["state_hash"]) == str(recs["7"]["state_hash"]):
		return "two seeds pinned the same hash"
	return "ok"


func _seeds() -> Array:
	return (load(WG) as GDScript).get_script_constant_map()["SEEDS"]


func test_the_scripted_player_still_records_exactly_the_fixture() -> String:
	var wg = load(WG)
	var recs: Dictionary = _fixture()
	for sd in _seeds():
		var got: Dictionary = _json(wg.record(sd))
		var want: Dictionary = recs[str(sd)]
		if str(got["state_hash"]) != str(want["state_hash"]):
			return "seed %d: the bot's run hashes %s, the fixture pins %s. %s" % [sd, got["state_hash"], want["state_hash"], HINT]
		if RunSave.canonical(got["inputs"]) != RunSave.canonical(want["inputs"]):
			return "seed %d: the bot now presses different inputs than the fixture holds. %s" % [sd, HINT]
	return "ok"


func test_the_golden_run_really_exercises_the_whole_world() -> String:
	# A golden that never trips a subsystem pins nothing about it.
	var wg = load(WG)
	var seen := {}
	for sd in _seeds():
		seen[sd] = {}
		var obs := func(s: Replay.Session) -> void:
			var rc: RunController = s.controller
			var w: Barons = rc.world
			for c in s.loop.crisis_deck.active:
				seen[sd]["event:" + str(c.get("origin", "random")) + ":" + str(c.get("baron", ""))] = true
			for id in w.rival_ids():
				if not (w.rival(id).front as Dictionary).is_empty():
					seen[sd]["front"] = true
			for id in w.ids():
				if w.state(id).heat > 0:
					seen[sd]["heat"] = true
			if not rc.transit.is_empty():
				seen[sd]["transit"] = true
		var s: Replay.Session = wg.play(sd, obs)
		var w: Barons = s.controller.world
		var moved: bool = false
		for id in w.rival_ids():
			if not w.rival(id).last.is_empty():
				moved = true
		if not moved:
			return "seed %d: no rival fleet ever traded" % sd
		var random_events: int = 0
		for k in seen[sd]:
			if str(k).begins_with("event:random:"):
				random_events += 1
		if random_events == 0:
			return "seed %d: no random baron event fired in 40 rounds (random_event_bps is on)" % sd
		if not seen[sd].has("heat") or not seen[sd].has("transit"):
			return "seed %d: heat or travel never happened: %s" % [sd, str(seen[sd].keys())]
	var any_front: bool = false
	var any_consequence: bool = false
	for sd in seen:
		any_front = any_front or seen[sd].has("front")
		for k in seen[sd]:
			any_consequence = any_consequence or str(k).begins_with("event:consequence:")
	if not any_front:
		return "no seed ever saw a front-run"
	if not any_consequence:
		return "no seed ever saw a heat consequence"
	return "ok"


# --- determinism ---

func test_a_run_replayed_twice_from_the_same_inputs_hashes_identically() -> String:
	var rec: Dictionary = _fixture()["84"]
	var a: Dictionary = Replay.replay(_json(rec))
	var b: Dictionary = Replay.replay(_json(rec))
	if not bool(a["ok"]) or not bool(b["ok"]) or a["actual"] != b["actual"]:
		return "two replays of one recording disagreed: %s vs %s" % [a["actual"], b["actual"]]
	var wg = load(WG)
	if wg.play(84).state_hash() != wg.play(84).state_hash():
		return "two live runs of the same seed hashed differently"
	if wg.play(84).state_hash() == wg.play(7).state_hash():
		return "two seeds hashed alike"
	return "ok"


func test_dropping_or_adding_an_input_desyncs_the_replay() -> String:
	var rec: Dictionary = _json(_fixture()["84"])
	var inputs: Array = rec["inputs"]
	# Drop one stock-up purchase made just before the first voyage.
	var idx: int = -1
	for i in inputs.size():
		if int(inputs[i]["tick"]) >= 7 * 30 and str(inputs[i]["action"]) == M0Loop.ACT_SUBMIT:
			idx = i
			break
	if idx < 0:
		return "no input to drop"
	var dropped: Dictionary = _json(rec)
	(dropped["inputs"] as Array).remove_at(idx)
	var res: Dictionary = Replay.replay(dropped)
	if bool(res["ok"]):
		return "a replay with input #%d skipped still matched the pinned hash" % idx
	var added: Dictionary = _json(rec)
	(added["inputs"] as Array).insert(idx, {"action": M0Loop.ACT_COMMODITY_NEXT, "frame": inputs[idx]["frame"], "tick": inputs[idx]["tick"]})
	(added["inputs"] as Array).insert(idx + 1, {"action": M0Loop.ACT_RIGHT, "frame": inputs[idx]["frame"], "tick": inputs[idx]["tick"]})
	(added["inputs"] as Array).insert(idx + 2, {"action": M0Loop.ACT_SUBMIT, "frame": inputs[idx]["frame"], "tick": inputs[idx]["tick"]})
	if bool(Replay.replay(added)["ok"]):
		return "a replay with an extra purchase still matched the pinned hash"
	return "ok"


# --- save / restore ---

func test_save_at_a_round_restore_and_continue_equals_the_uninterrupted_run() -> String:
	var wg = load(WG)
	for sd in _seeds():
		var whole: Replay.Session = wg.play(sd, Callable(), SAVE_ROUND)
		var split: Replay.Session = wg.play(sd, Callable(), SAVE_ROUND)
		if split.state_hash() != whole.state_hash():
			return "seed %d: two plays to round %d disagree" % [sd, SAVE_ROUND]
		if split.controller.transit.is_empty():
			return "seed %d: round %d is not mid-voyage; move SAVE_ROUND" % [sd, SAVE_ROUND]
		wg.run_quiet(whole.controller, whole.loop)
		var cap: Dictionary = RunSave.capture(split.controller, split.loop.market, split.bags)
		if not cap.has("world") or not (cap["world"] as Dictionary).has("rivals"):
			return "seed %d: the save has no world or no fleets" % sd
		# Through the JSON file the hash must survive. The continue runs from the in-memory
		# capture: JSON text keeps ~15 significant digits and the sim clock's float
		# accumulator would drift by an ulp, which is not the world's doing.
		var via_json: Dictionary = RunSave.restore(_json(cap))
		if not bool(via_json["ok"]) or RunSave.state_hash(via_json["controller"], via_json["market"], via_json["bags"]) != split.state_hash():
			return "seed %d: the save file round trip changed the hash. %s" % [sd, HINT]
		var r: Dictionary = RunSave.restore(cap.duplicate(true))
		if not bool(r["ok"]):
			return "seed %d: restore failed: %s" % [sd, r["error"]]
		var rc: RunController = r["controller"]
		if RunSave.state_hash(rc, r["market"], r["bags"]) != split.state_hash():
			return "seed %d: hash changed across the save. %s" % [sd, HINT]
		var hud := OrbitalHUD.new(rc)
		var lp := M0Loop.new(hud)
		lp.set_market(r["market"])
		lp.sync_hud_to_ship()
		hud.set_station(rc.docked_at if rc.docked_at != "" else "mars")
		wg.run_quiet(rc, lp)
		var got: String = RunSave.state_hash(rc, lp.market, r["bags"])
		var want: String = whole.state_hash()
		if got != want:
			return "seed %d: save at round %d, restore, continue gave %s; the uninterrupted run gave %s. %s" % [sd, SAVE_ROUND, got, want, HINT]
	return "ok"
