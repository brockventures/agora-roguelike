extends RefCounted
## The Sol System Rescue Project, task 5 (#32, docs/design/rescue-project.md sections 10 and 11):
## whole-run goldens with a scripted rescue.
##
## The player holds every baron (built with the takeover core) and a greedy hauler in
## tools/rescue_bot.gd builds the four phases through the real game: buys on the real ladders,
## departs, delivers with m0_project, answers the monopoly and rescued modals. Its presses are the
## fixture tests/fixtures/world/rescue_goldens.json (seeds 84 and 7, the real 900-tick round,
## rival fleets and random baron events on), with the final state hash. A save taken mid-project
## is restored and continued, and must land on the same hash as the run that never stopped.
##
## A failure here means the rescue's behaviour changed. If that was meant, regenerate with
##   godot --headless --path game -s res://tools/regen_rescue_goldens.gd
## and put the old and new hashes in the PR. If not, you have a determinism bug.

const FIXTURE := "res://tests/fixtures/world/rescue_goldens.json"
const RB := "res://tools/rescue_bot.gd"
const HINT := "If the change is deliberate, regenerate: godot --headless --path game -s res://tools/regen_rescue_goldens.gd (and list old/new hashes in the PR)."


func _fixture() -> Dictionary:
	return (JSON.parse_string(FileAccess.get_file_as_string(FIXTURE)) as Dictionary)["recordings"]


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


func _seeds() -> Array:
	return (load(RB) as GDScript).get_script_constant_map()["SEEDS"]


func test_the_fixture_replays_to_its_pinned_hash_for_both_seeds() -> String:
	var rb = load(RB)
	var recs: Dictionary = _fixture()
	for sd in _seeds():
		var rec: Dictionary = _json(recs[str(sd)])
		var s: Replay.Session = rb.replay(rec)
		if s.state_hash() != str(rec["state_hash"]):
			return "seed %d: the ops replay to %s, the fixture pins %s. %s" % [sd, s.state_hash(), rec["state_hash"], HINT]
		if s.frames != int(rec["frames"]) or s.controller.sim_clock.total_ticks != int(rec["final_tick"]):
			return "seed %d: ran %d frames to tick %d, the fixture says %d to %d" % [sd, s.frames, s.controller.sim_clock.total_ticks, rec["frames"], rec["final_tick"]]
		if not s.controller.is_rescued():
			return "seed %d: the recorded run did not end rescued" % sd
	if str(recs["84"]["state_hash"]) == str(recs["7"]["state_hash"]):
		return "two seeds pinned the same hash"
	return "ok"


func test_the_scripted_player_still_records_exactly_the_fixture() -> String:
	var rb = load(RB)
	var recs: Dictionary = _fixture()
	for sd in _seeds():
		var res: Dictionary = rb.haul(int(sd), rb.GOLDEN_CR)
		var got: Dictionary = _json(rb.to_recording(res, int(sd), rb.GOLDEN_CR))
		var want: Dictionary = recs[str(sd)]
		if str(got["state_hash"]) != str(want["state_hash"]):
			return "seed %d: the bot's run hashes %s, the fixture pins %s. %s" % [sd, got["state_hash"], want["state_hash"], HINT]
		if RunSave.canonical(got["ops"]) != RunSave.canonical(want["ops"]):
			return "seed %d: the bot now presses different things than the fixture holds. %s" % [sd, HINT]
	return "ok"


func test_the_golden_run_really_builds_the_whole_project() -> String:
	# A golden that never trips a subsystem pins nothing about it.
	var rb = load(RB)
	for sd in _seeds():
		var seen := {"embargo": false, "field": false, "bonus": false, "modal": false}
		var obs := func(s: Replay.Session) -> void:
			var rc: RunController = s.controller
			if rc.rescue != null and rc.rescue.is_open():
				for m in rc.world_mods():
					if int(m.get("ask_depth_bps", -1)) == 0:
						seen["embargo"] = true
				if rc.rescue.keep_bps < RescueProject.FULL_SPEED_BPS:
					seen["field"] = true
				if rc.world.rent_bonus_bps > RescueProject.FULL_SPEED_BPS:
					seen["bonus"] = true
			if s.loop.overlay_state == M0Loop.OVERLAY_RESCUED:
				seen["modal"] = true
		var res: Dictionary = rb.haul(int(sd), rb.GOLDEN_CR, obs)
		var s: Replay.Session = res["session"]
		var rc: RunController = s.controller
		var rp: RescueProject = rc.rescue
		if not rc.is_rescued() or rp == null or not rp.is_complete() or rp.phases_done() != 4:
			return "seed %d: not a finished rescue (%s)" % [sd, str(rb.haul_report(s))]
		for k in seen:
			if not seen[k]:
				return "seed %d: the run never saw %s" % [sd, k]
		# The field slowed the clock: fewer doomsday ticks went by than sim ticks.
		var spent: int = int(res["clock_start"]) - rc.doomsday.ticks_remaining
		if spent >= rc.sim_clock.total_ticks:
			return "seed %d: the clock lost %d ticks in %d sim ticks; the field did nothing" % [sd, spent, rc.sim_clock.total_ticks]
		if rp.keep_bps != 0 or rc.rescue_severance_award <= 0 or rc.profile.rescues_completed != 1:
			return "seed %d: win bookkeeping: keep %d, rescue severance %d, rescues %d" % [sd, rp.keep_bps, rc.rescue_severance_award, rc.profile.rescues_completed]
		# The win delivered exactly the bill (900 units), however many holds it took.
		var delivered: int = 0
		for ph in rp.phases():
			delivered += RescueProject.phase_units(ph)
		if delivered != 900:
			return "seed %d: the bill is %d units, not 900" % [sd, delivered]
		# Every phase finished in order, once.
		var ids: Array = []
		for e in rp.completed:
			ids.append(str(e[0]))
		if ids != ["anchor_yard", "coil_foundry", "containment_shell", "ignition_array"]:
			return "seed %d: phases finished as %s" % [sd, str(ids)]
		# Past the modal the run sits on the summary: one corp, banked once as rescued.
		if rc.end_reason != "rescued" or rc.corp_number != 1:
			return "seed %d: end_reason %s corp %d" % [sd, rc.end_reason, rc.corp_number]
	return "ok"


# --- determinism ---

func test_a_run_replayed_twice_hashes_identically_and_seeds_differ() -> String:
	var rb = load(RB)
	var rec: Dictionary = _json(_fixture()["84"])
	if rb.replay(rec).state_hash() != rb.replay(rec).state_hash():
		return "two replays of one recording disagreed"
	if str(_fixture()["84"]["state_hash"]) == str(_fixture()["7"]["state_hash"]):
		return "two seeds hashed alike"
	return "ok"


func test_dropping_a_delivery_changes_the_run() -> String:
	var rb = load(RB)
	var rec: Dictionary = _json(_fixture()["84"])
	var ops: Array = rec["ops"]
	var idx: int = -1
	for i in ops.size():
		if str(ops[i]["op"]) == "deliver":
			idx = i
			break
	if idx < 0:
		return "no delivery to drop"
	ops.remove_at(idx)
	var s: Replay.Session = rb.replay(rec)
	if s.state_hash() == str(rec["state_hash"]):
		return "a run with its first delivery skipped still matched the pinned hash"
	return "ok"


# --- save / restore ---

## The frame to save at: the first quiet frame inside phase 3 once some of its goods are in.
func _split_frame(rb, rec: Dictionary) -> int:
	var found := [-1]
	rb.haul(int(rec["seed"]), int(rec["cr"]), Callable(), func(s: Replay.Session) -> bool:
		var rp: RescueProject = s.controller.rescue
		if rp != null and rp.phase == 2 and not rp.deposits.is_empty() and s.loop.overlay_state == M0Loop.OVERLAY_NONE:
			found[0] = s.frames
			return true
		return false)
	return found[0]


func _restored(rb, rec: Dictionary, cap: Dictionary, frames: int) -> Replay.Session:
	var r: Dictionary = RunSave.restore(cap.duplicate(true))
	if not bool(r["ok"]):
		return null
	var s: Replay.Session = rb.new_session(int(rec["seed"]), bool(rec.get("rivals", true)))
	s.controller = r["controller"]
	s.hud = OrbitalHUD.new(s.controller)
	s.loop = M0Loop.new(s.hud)
	s.loop.set_market(r["market"])
	s.bags = r["bags"]
	s.loop.sync_hud_to_ship()
	s.hud.set_station(s.controller.docked_at if s.controller.docked_at != "" else "mars")
	s.frames = frames
	return s


func test_save_mid_project_restore_and_continue_equals_the_uninterrupted_run() -> String:
	var rb = load(RB)
	for sd in _seeds():
		var rec: Dictionary = _json(_fixture()[str(sd)])
		var at: int = _split_frame(rb, rec)
		if at <= 0:
			return "seed %d: never reached a mid-phase-3 frame to save at" % sd
		var split: Replay.Session = rb.replay(rec, null, at, false)
		if split.frames != at or split.controller.rescue == null or split.controller.rescue.phase != 2 or split.controller.rescue.deposits.is_empty():
			return "seed %d: the replay is not mid phase 3 at frame %d" % [sd, at]
		var cap: Dictionary = RunSave.capture(split.controller, split.loop.market, split.bags)
		if not cap.has("rescue") or not cap.has("world"):
			return "seed %d: the save has no rescue or no world" % sd
		var before: String = split.state_hash()
		# Through the JSON file the hash must survive. The continue runs from the in-memory
		# capture: JSON text keeps ~15 significant digits and the sim clock's float accumulator
		# would drift by an ulp, which is not the project's doing.
		var via_json: Dictionary = RunSave.restore(_json(cap))
		if not bool(via_json["ok"]) or RunSave.state_hash(via_json["controller"], via_json["market"], via_json["bags"]) != before:
			return "seed %d: the save file round trip changed the hash. %s" % [sd, HINT]
		var s2: Replay.Session = _restored(rb, rec, cap, at)
		if s2 == null:
			return "seed %d: restore failed" % sd
		if s2.state_hash() != before:
			return "seed %d: hash changed across the save. %s" % [sd, HINT]
		# The restored run still has the embargo, the field and the rent bonus: all derived.
		var rc2: RunController = s2.controller
		var embargoed: bool = false
		for m in rc2.world_mods():
			if int(m.get("ask_depth_bps", -1)) == 0:
				embargoed = true
		if not embargoed or rc2.rescue.keep_bps != 3500 or rc2.world.rent_bonus_bps != 20000:
			return "seed %d: the restored run lost its embargo (%s), field (%d) or rent bonus (%d)" % [sd, str(embargoed), rc2.rescue.keep_bps, rc2.world.rent_bonus_bps]
		var done: Replay.Session = rb.replay(rec, s2, -1, true)
		var want: String = str(rec["state_hash"])
		if done.state_hash() != want:
			return "seed %d: save at frame %d, restore, continue gave %s; the uninterrupted run gave %s. %s" % [sd, at, done.state_hash(), want, HINT]
		if not done.controller.is_rescued():
			return "seed %d: the continued run did not win" % sd
	return "ok"
