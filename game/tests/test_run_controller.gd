extends RefCounted
## Tests for RunController (PR 2 of #10).

## A controller whose doomsday carries no debt unless asked, so it stays solvent.
func _rc(debt: int = 0, total_ticks: int = 36000, burn: int = 0, interest: int = 0) -> RunController:
	return RunController.new(null, 42, DoomsdayClock.new(total_ticks, debt, burn, interest))

func test_fresh_run_state() -> String:
	var rc := _rc()
	if rc.cr != Chapter11.FRESH_START_CR or not rc.cargo.is_empty():
		return "bad fresh cr/cargo"
	if rc.ships.size() != 1 or rc.ships[0]["id"] != Chapter11.STARTER_SHIP["id"]:
		return "bad starter ship"
	if rc.run_seed != 42 or rc.pending_bankruptcy or rc.profile == null:
		return "bad seed/pending/profile"
	return "ok"

func test_insolvency_trips_interrupt_and_pauses_on_that_subtick() -> String:
	var rc := _rc()
	rc.doomsday.principal_debt = 1000000
	var seen: Array = []
	rc.bankruptcy_pending.connect(func(a): seen.append(a))
	var n := rc.advance(0.25)
	if n != 1:
		return "should stop on first sub-tick, ran %d" % n
	if not rc.sim_clock.paused or rc.sim_clock.auto_paused_reason != "interrupt":
		return "clock should be interrupt-paused"
	if not rc.pending_bankruptcy or seen.size() != 1 or not seen[0]["insolvent"]:
		return "pending/signal not set"
	if rc.doomsday.ticks_remaining != rc.doomsday.total_ticks - 1:
		return "doomsday should have stepped exactly the one tick"
	if rc.cr != Chapter11.FRESH_START_CR:
		return "must not file mid-tick"
	if rc.advance(0.25) != 0:
		return "advance must run zero ticks while pending"
	return "ok"

func test_file_bankruptcy_ends_run_and_carries_over() -> String:
	var rc := _rc()
	rc.cr = 123
	rc.cargo = {"FRAG": 3}
	rc.ships = [{"id": "x", "hull_value_cr": 10}]
	rc.doomsday.principal_debt = 1000000
	rc.advance(0.05)
	var remaining := rc.doomsday.ticks_remaining
	var ticks := rc.sim_clock.total_ticks
	var filed: Array = []
	rc.bankruptcy_filed.connect(func(r): filed.append(r))
	var old_seed := rc.run_seed
	var report := rc.file_bankruptcy()
	if report.is_empty() or filed.size() != 1:
		return "report/signal missing"
	if rc.is_run_over() or rc.end_reason != "bankruptcy" or rc.corp_number != 2:
		return "filing must found a new corp, not end the run"
	var lost: Dictionary = rc.carry_over["lost"]
	if int(lost["cr"]) != 123 or lost["cargo"] != {"FRAG": 3} or int(lost["debt"]) <= 0:
		return "lost summary wrong: %s" % str(lost)
	if rc.cr != Chapter11.FRESH_START_CR or not rc.cargo.is_empty():
		return "cr/cargo not reset"
	if rc.ships.size() != 1 or rc.ships[0]["id"] != Chapter11.STARTER_SHIP["id"]:
		return "ships not reset"
	if rc.profile.bankruptcies_filed != 1:
		return "bankruptcies_filed not incremented"
	if rc.doomsday.ticks_remaining != remaining or rc.sim_clock.total_ticks != ticks:
		return "ticks must be preserved"
	if rc.doomsday.get_total_debt() != 0:
		return "debt not cleared"
	if rc.pending_bankruptcy or not rc.sim_clock.paused:
		return "pending cleared and clock left paused"
	if rc.run_seed != old_seed or int(report["next_seed"]) != rc.corp_seed():
		return "world seed must stay; report carries the new corp seed"
	if int(report["forfeited"]["cr"]) != 123:
		return "report should record forfeited cr"
	rc.sim_clock.resume()
	if rc.advance(0.05) == 0:
		return "corp must keep running once unpaused"
	return "ok"

func test_file_when_solvent_and_not_pending_rejected() -> String:
	var rc := _rc()
	var filed: Array = []
	rc.bankruptcy_filed.connect(func(r): filed.append(r))
	var before := rc.to_dict()
	if not rc.file_bankruptcy().is_empty() or not filed.is_empty():
		return "solvent filing must be rejected"
	if rc.to_dict() != before:
		return "rejected filing must not change state"
	return "ok"

func test_file_when_insolvent_without_pending_allowed() -> String:
	var rc := _rc()
	rc.doomsday.principal_debt = 1000000
	if rc.file_bankruptcy().is_empty():
		return "insolvent run may file even if not yet pending"
	return "ok"

func test_reassess_clears_pending_when_solvent() -> String:
	var rc := _rc()
	rc.doomsday.principal_debt = 1000000
	rc.advance(0.05)
	if not rc.pending_bankruptcy:
		return "should be pending"
	rc.doomsday.principal_debt = 0
	if rc.reassess():
		return "pending should clear when solvent"
	return "ok"

func test_doomsday_via_controller_matches_direct_stepping() -> String:
	var rc := _rc(100, 36000, 1, 300)
	var direct := DoomsdayClock.new(36000, 100, 1, 300)
	var deltas := [0.016, 0.0167, 0.1, 0.25, 0.033, 0.2, 0.016]
	var total := 0
	for i in 60:
		total += rc.advance(deltas[i % deltas.size()])
	if total != rc.sim_clock.total_ticks or total < 100:
		return "tick count mismatch %d vs %d" % [total, rc.sim_clock.total_ticks]
	if rc.sim_clock.paused or rc.pending_bankruptcy:
		return "no interrupt expected"
	for i in total:
		direct.step_ticks(1)
	if rc.doomsday.to_dict() != direct.to_dict():
		return "controller-driven doomsday differs from direct stepping"
	var batch := DoomsdayClock.new(36000, 100, 1, 300)
	batch.step_ticks(total)
	if rc.doomsday.to_dict() != batch.to_dict():
		return "controller-driven doomsday differs from batch stepping"
	return "ok"

func test_stage_change_pauses_and_forwards_signal() -> String:
	var rc := _rc(0, 100)
	var changes: Array = []
	rc.stage_changed.connect(func(o, n): changes.append([o, n]))
	var total := 0
	# NORMAL -> UNSTABLE at 75 ticks remaining, i.e. after 25 ticks.
	while changes.is_empty() and total < 200:
		var n := rc.advance(0.25)
		total += n
	if changes.size() != 1 or changes[0] != [DoomsdayClock.Stage.NORMAL, DoomsdayClock.Stage.UNSTABLE]:
		return "stage change not forwarded: %s" % str(changes)
	if total != 25 or not rc.sim_clock.paused:
		return "clock should pause on the stage-change tick, total=%d" % total
	return "ok"

func test_collapse_forwards_run_collapsed() -> String:
	var rc := _rc(0, 10)
	var collapsed: Array = []
	rc.run_collapsed.connect(func(): collapsed.append(true))
	for i in 100:
		if rc.sim_clock.paused:
			rc.sim_clock.resume()
		rc.advance(0.25)
	if collapsed.size() != 1:
		return "run_collapsed should fire exactly once, got %d" % collapsed.size()
	if not rc.is_collapsed() or rc.doomsday.ticks_remaining != 0:
		return "doomsday should be collapsed at 0"
	if rc.advance(0.25) != 0:
		return "no ticks after collapse"
	return "ok"

func test_snapshot_shape() -> String:
	var rc := _rc()
	rc.cargo = {"FRAG": 2}
	var s := rc.snapshot()
	if s["cr"] != rc.cr or s["cargo"] != rc.cargo or s["ships"] != rc.ships:
		return "snapshot fields wrong"
	if s["doomsday"] != rc.doomsday:
		return "snapshot must carry the live doomsday clock"
	s["cargo"]["FRAG"] = 99
	if rc.cargo["FRAG"] != 2:
		return "snapshot cargo must be a copy"
	return "ok"

func test_roundtrip_including_pending() -> String:
	var rc := _rc()
	rc.profile.add_patent("p1")
	rc.cargo = {"FRAG": 3}
	rc.doomsday.principal_debt = 1000000
	rc.advance(0.05)
	if not rc.pending_bankruptcy:
		return "setup: should be pending"
	var d := rc.to_dict()
	var rc2 := RunController.from_dict(d)
	if rc2.to_dict() != d:
		return "roundtrip dict differs"
	if not rc2.pending_bankruptcy or not rc2.profile.has_patent("p1") or rc2.run_seed != 42:
		return "restored fields wrong"
	if not rc2.sim_clock.paused:
		return "paused state should restore"
	# Restored controller is wired: it can file, which ends the run; the next
	# corp is live-wired.
	if rc2.file_bankruptcy().is_empty():
		return "restored pending run should file"
	rc2.sim_clock.resume()
	var rem := rc2.doomsday.ticks_remaining
	if rc2.advance(0.05) == 0 or rc2.doomsday.ticks_remaining >= rem:
		return "restored controller must be wired to doomsday stepping"
	return "ok"

func test_roundtrip_is_wired_to_hooks_once() -> String:
	var rc := RunController.from_dict(_rc().to_dict())
	if rc.sim_clock.interrupt_hooks.size() != 1:
		return "exactly one interrupt hook expected"
	rc.advance(0.25)
	if rc.doomsday.ticks_remaining != rc.doomsday.total_ticks - rc.sim_clock.total_ticks:
		return "doomsday must step once per sub-tick"
	return "ok"

func test_round_calculation_and_pacing() -> String:
	# 60 ticks per round with zero debt so it does not trip bankruptcy interrupt
	var clock := DoomsdayClock.new(36000, 0, 0, 0)
	var rc := RunController.new(null, 42, clock, {}, 60)
	var rounds: Array = []
	rc.round_advanced.connect(func(r): rounds.append(r))

	if rc.get_current_round() != 0 or rc.get_round_progress() != 0.0:
		return "initial round or progress not zero"

	# Advance 30 ticks -> round 0, progress 0.5
	for i in 30:
		rc.advance(1.0 / 60.0)

	if rc.get_current_round() != 0:
		return "should still be round 0"
	if absf(rc.get_round_progress() - 0.5) > 0.01:
		return "round progress mismatch: %f" % rc.get_round_progress()

	# Advance another 30 ticks -> round 1
	for i in 30:
		rc.advance(1.0 / 60.0)

	if rc.get_current_round() != 1 or rounds != [1]:
		return "round should be 1 and signal emitted: %s" % str(rounds)

	# Serialization preserves ticks_per_round
	var dict_data := rc.to_dict()
	var rc2 := RunController.from_dict(dict_data)
	if rc2.ticks_per_round != 60 or rc2.get_current_round() != 1:
		return "ticks_per_round not restored in from_dict"

	return "ok"
