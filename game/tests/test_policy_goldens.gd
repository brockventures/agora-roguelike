extends RefCounted
## #160 row 3: the policy goldens (docs/design/corporate-policies.md section 8). The shipped
## world with policies attached is played for 60 rounds by tools/policy_golden.gd, which takes
## the first listed offer at every pick. The fixture pins the picks, the round each lands on and
## the final hash for seeds 84 and 7. A pick is a recorded input ("policy:<id>"), so a replay
## reaches the same hash. The whole-world goldens (test_world_goldens.gd) attach no policies and
## keep their pins.
##
## A failure means policy behaviour changed. If that was meant, regenerate with
##   godot --headless --path game -s res://tools/regen_policy_goldens.gd
## and list the old and new hashes in the PR.

const FIXTURE := "res://tests/fixtures/world/policy_goldens.json"
const PG := "res://tools/policy_golden.gd"
const HINT := "If deliberate, regenerate: godot --headless --path game -s res://tools/regen_policy_goldens.gd (and list old/new hashes in the PR)."


func _fixture() -> Dictionary:
	return (JSON.parse_string(FileAccess.get_file_as_string(FIXTURE)) as Dictionary)["recordings"]


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


func test_the_fixture_replays_to_its_pinned_hash_for_both_seeds() -> String:
	var recs := _fixture()
	for sd in (load(PG) as GDScript).get_script_constant_map()["SEEDS"]:
		var rec: Dictionary = recs[str(sd)]
		var res: Dictionary = Replay.replay(_json(rec))
		if not bool(res["ok"]):
			return "seed %d: policy replay failed: %s. got %s, expected %s. %s" % [sd, res["error"], res["actual"], res["expected"], HINT]
		if int(res["frames"]) < 60 * 30 - 5:
			return "seed %d: the recording only ran %d frames" % [sd, res["frames"]]
	if str(recs["84"]["state_hash"]) == str(recs["7"]["state_hash"]):
		return "two seeds pinned the same hash"
	return "ok"


func test_the_scripted_player_still_records_exactly_the_fixture() -> String:
	var pg = load(PG)
	var recs := _fixture()
	for sd in pg.SEEDS:
		var got: Dictionary = _json(pg.record(sd))
		var want: Dictionary = recs[str(sd)]
		if str(got["state_hash"]) != str(want["state_hash"]):
			return "seed %d: the bot's run hashes %s, the fixture pins %s. %s" % [sd, got["state_hash"], want["state_hash"], HINT]
		if RunSave.canonical(got["inputs"]) != RunSave.canonical(want["inputs"]):
			return "seed %d: the bot now presses different inputs than the fixture holds. %s" % [sd, HINT]
	return "ok"


func test_picks_land_on_the_milestone_rounds_with_the_first_listed_offer() -> String:
	var pg = load(PG)
	var recs := _fixture()
	for sd in pg.SEEDS:
		var rec: Dictionary = recs[str(sd)]
		var picks: Array = pg.picks_of(pg.play(sd))
		if RunSave.canonical(picks) != RunSave.canonical(rec["picks"]):
			return "seed %d: the pinned picks %s disagree with the bot's %s" % [sd, str(rec["picks"]), str(picks)]
		if picks.size() != 2 or int(picks[0]["round"]) != 20 or int(picks[1]["round"]) != 50:
			return "seed %d: picks %s, wanted one at round 20 and one at round 50" % [sd, str(picks)]
		if str(picks[0]["id"]) != "supply_chain" or str(picks[1]["id"]) != "risk_transfer":
			return "seed %d: first listed offers were %s" % [sd, str(picks)]
	return "ok"


func test_the_golden_run_ends_holding_the_picks_with_the_modifiers_stacked() -> String:
	var s: Replay.Session = (load(PG)).play(84)
	var rc := s.controller
	if rc.policies.picks != ["supply_chain", "risk_transfer"] or rc.policies.pending() != 0:
		return "ended with %s" % str(rc.policies.to_dict())
	if rc.fuel_discount_bps() < 1500 or not rc.modifiers.has("piracy_odds_bps"):
		return "the picks are not in force: %s" % str(rc.modifiers)
	if not RunSave.capture(rc, s.loop.market, s.bags).has("policies"):
		return "no policies key in the final save"
	return "ok"


func test_dropping_a_pick_desyncs_the_replay() -> String:
	var pg = load(PG)
	var rec := _json(_fixture()["84"])
	var idx: int = int(pg.play(84).get_meta("pick_inputs")[0])
	if str(rec["inputs"][idx]["action"]) != M0Loop.ACT_SUBMIT or int(rec["inputs"][idx]["tick"]) != 600:
		return "input #%d is not the round 20 pick: %s" % [idx, str(rec["inputs"][idx])]
	(rec["inputs"] as Array).remove_at(idx)
	return "ok" if not bool(Replay.replay(rec)["ok"]) else "a replay with a pick dropped still matched"


## The pick is the modal's own input, not a private one: the D-pad moves the cursor in the
## recording like any other press, and a pick made one row down lands on another policy.
func test_a_cursor_that_wanders_and_returns_picks_the_same_policy_and_the_same_hash() -> String:
	var pg = load(PG)
	var rec := _json(_fixture()["84"])
	var idx: int = int(pg.play(84).get_meta("pick_inputs")[0])
	var at: Dictionary = (rec["inputs"] as Array)[idx]
	(rec["inputs"] as Array).insert(idx, {"frame": at["frame"], "tick": at["tick"], "action": M0Loop.ACT_UP})
	(rec["inputs"] as Array).insert(idx, {"frame": at["frame"], "tick": at["tick"], "action": M0Loop.ACT_DOWN})
	var res := Replay.replay(rec)
	return "ok" if bool(res["ok"]) else "D-pad down then up before A changed the run: %s" % str(res)


func test_a_dpad_press_before_the_pick_changes_the_policy_and_the_hash() -> String:
	var pg = load(PG)
	var rec := _json(_fixture()["84"])
	var idx: int = int(pg.play(84).get_meta("pick_inputs")[0])
	(rec["inputs"] as Array).insert(idx, {"frame": rec["inputs"][idx]["frame"], "tick": rec["inputs"][idx]["tick"], "action": M0Loop.ACT_DOWN})
	var res := Replay.replay(rec)
	if bool(res["ok"]):
		return "a recording that moved the cursor before the pick still matched"
	return "ok" if str(res["error"]) == "state hash mismatch" else "wanted a hash mismatch, got %s" % str(res)


func test_a_save_at_round_55_restores_and_continues_to_the_same_hash() -> String:
	var pg = load(PG)
	var whole: Replay.Session = pg.play(84)
	var half: Replay.Session = pg.play(84, 55)
	var cap: Dictionary = RunSave.capture(half.controller, half.loop.market, half.bags)
	var r: Dictionary = RunSave.restore(_json(cap))
	if not bool(r["ok"]) or RunSave.state_hash(r["controller"], r["market"], r["bags"]) != half.state_hash():
		return "the round 55 save changed the hash"
	var back: RunController = r["controller"]
	if back.policies.picks != whole.controller.policies.picks.slice(0, 2) or back.fuel_discount_bps() != half.controller.fuel_discount_bps():
		return "picks or modifiers lost across the save"
	return "ok"
