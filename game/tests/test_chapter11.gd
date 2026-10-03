extends RefCounted
## Tests for Chapter11 assessment and filing (PR 1 of #10).

func _snap(cr: int, principal: int, cargo: Dictionary = {}, ships: Array = [], interest: int = 0, burn: int = 0) -> Dictionary:
	return {
		"cr": cr,
		"cargo": cargo,
		"ships": ships,
		"doomsday": {"principal_debt": principal, "accrued_interest": interest, "accrued_burn": burn},
	}

func test_constants() -> String:
	if Chapter11.LIQUIDATION_HAIRCUT_BPS != 5000 or Chapter11.FRESH_START_CR != 5000 or not Chapter11.AUTO_FILE:
		return "default constants changed"
	return "ok"

func test_boundary_debt_equals_value_is_solvent() -> String:
	var a := Chapter11.assess(_snap(1000, 1000))
	if a["insolvent"] or a["shortfall"] != 0:
		return "debt == value must be solvent, got %s" % str(a)
	var b := Chapter11.assess(_snap(1000, 1001))
	if not b["insolvent"] or b["shortfall"] != 1:
		return "debt == value+1 must be insolvent with shortfall 1, got %s" % str(b)
	return "ok"

func test_boundary_with_cargo_and_ships() -> String:
	# FRAG 15.0 x 3 = 45 -> 22 ; hull 101 -> 50 ; cr 10 => value 82
	var cargo := {"FRAG": 3}
	var ships := [{"hull_value_cr": 101}]
	if Chapter11.assess(_snap(10, 82, cargo, ships))["insolvent"]:
		return "debt 82 vs value 82 must be solvent"
	if not Chapter11.assess(_snap(10, 83, cargo, ships))["insolvent"]:
		return "debt 83 vs value 82 must be insolvent"
	return "ok"

func test_haircut_integer_floor() -> String:
	var a := Chapter11.assess(_snap(0, 0, {"FRAG": 3}, [{"hull_value_cr": 101}]))
	if a["breakdown"]["cargo"] != 22:
		return "cargo 45 at 50 percent should floor to 22, got %d" % a["breakdown"]["cargo"]
	if a["breakdown"]["ships"] != 50:
		return "hull 101 at 50 percent should floor to 50, got %d" % a["breakdown"]["ships"]
	if a["liquidation_value"] != 72:
		return "liquidation value should be 72, got %d" % a["liquidation_value"]
	return "ok"

func test_haircut_floors_per_line_not_in_aggregate() -> String:
	# Two hulls of 1 CR each: per-hull floor 0 + 0, not floor(2 * 0.5) = 1.
	var a := Chapter11.assess(_snap(0, 0, {}, [{"hull_value_cr": 1}, {"hull_value_cr": 1}]))
	if a["breakdown"]["ships"] != 0:
		return "expected per-hull floor (0), got %d" % a["breakdown"]["ships"]
	return "ok"

func test_total_debt_sums_all_three_buckets() -> String:
	var a := Chapter11.assess(_snap(0, 100, {}, [], 20, 3))
	if a["total_debt"] != 123:
		return "expected 123, got %d" % a["total_debt"]
	return "ok"

func test_assess_reads_live_doomsday_clock() -> String:
	var clock := DoomsdayClock.new(36000, 5000, 25, 300, 60)
	clock.step_ticks(3600)
	var snap := {"cr": 0, "cargo": {}, "ships": [], "doomsday": clock}
	var a := Chapter11.assess(snap)
	if a["total_debt"] != clock.get_total_debt():
		return "total_debt should match clock, got %d vs %d" % [a["total_debt"], clock.get_total_debt()]
	if not a["insolvent"]:
		return "no assets against debt should be insolvent"
	return "ok"

func test_assess_tolerates_missing_and_garbage_fields() -> String:
	var a := Chapter11.assess({})
	if a["insolvent"] or a["total_debt"] != 0:
		return "empty snapshot is solvent with no debt"
	var b := Chapter11.assess({"cr": -50, "cargo": {"UNOBTAINIUM": 9, "FRAG": -4}, "ships": ["x", {"hull_value_cr": -9}], "doomsday": 7})
	if b["liquidation_value"] != 0:
		return "garbage should value to 0, got %d" % b["liquidation_value"]
	return "ok"

func test_should_auto_file() -> String:
	if not Chapter11.should_auto_file(_snap(0, 1)):
		return "insolvent run should auto-file"
	if Chapter11.should_auto_file(_snap(1, 1)):
		return "solvent run should not auto-file"
	return "ok"

func test_should_auto_file_as_sim_clock_interrupt() -> String:
	var snap := _snap(0, 1)
	var sc := SimClock.new()
	sc.register_interrupt_hook(func(): return Chapter11.should_auto_file(snap))
	var executed := sc.step(0.1)
	if executed != 1 or not sc.paused or sc.auto_paused_reason != "interrupt":
		return "insolvency should halt SimClock after one sub-tick, got %d" % executed
	return "ok"

func test_file_keeps_profile_and_wipes_run() -> String:
	var profile := MetaProfile.new()
	profile.add_patent("p1")
	profile.add_unlock("u1")
	profile.add_contract("c1")
	profile.bankruptcies_filed = 1
	var snap := _snap(40, 9000, {"FUEL": 10}, [{"id": "big", "hull_value_cr": 500}], 100, 50)
	var r := Chapter11.file(snap, profile, 42)
	var run: Dictionary = r["new_run"]
	if run["cr"] != 5000 or not run["cargo"].is_empty():
		return "new run should be fresh-start CR with no cargo"
	if run["ships"].size() != 1:
		return "new run should have exactly one starter ship"
	if not run["debt_cleared"]:
		return "debt_cleared flag missing"
	var p: MetaProfile = r["profile"]
	if p.bankruptcies_filed != 2:
		return "bankruptcies_filed should be 2, got %d" % p.bankruptcies_filed
	if p.patents != ["p1"] or p.unlocks != ["u1"] or p.contracts != ["c1"]:
		return "profile contents must be kept"
	if profile.bankruptcies_filed != 1:
		return "input profile must not be mutated"
	var rep: Dictionary = r["report"]
	if rep["forfeited"]["cr"] != 40 or rep["forfeited"]["cargo"] != {"FUEL": 10} or rep["forfeited"]["ships"].size() != 1:
		return "report.forfeited wrong: %s" % str(rep["forfeited"])
	if rep["kept"]["patents"] != ["p1"] or rep["kept"]["bankruptcies_filed"] != 2:
		return "report.kept wrong: %s" % str(rep["kept"])
	if rep["debt_wiped"] != 9150:
		return "debt_wiped should be 9150, got %d" % rep["debt_wiped"]
	if not rep.has("next_seed") or rep["next_seed"] != run["seed"]:
		return "next_seed missing or inconsistent"
	if snap["cr"] != 40:
		return "input snapshot must not be mutated"
	var dd: Dictionary = run["doomsday"]
	if dd["principal_debt"] != 0 or dd["accrued_interest"] != 0 or dd["accrued_burn"] != 0:
		return "dict doomsday debt not zeroed"
	if snap["doomsday"]["principal_debt"] != 9000:
		return "input doomsday dict must not be mutated"
	return "ok"

func test_file_clears_clock_debt_but_not_ticks_or_stage() -> String:
	var clock := DoomsdayClock.new(10000, 3000, 25, 300, 100)
	clock.step_ticks(6000)
	var ticks := clock.ticks_remaining
	var stage := clock.stage
	var snap := {"cr": 0, "cargo": {}, "ships": [], "doomsday": clock}
	var r := Chapter11.file(snap, MetaProfile.new(), 1)
	if clock.get_total_debt() != 0:
		return "clock debt should be wiped, got %d" % clock.get_total_debt()
	if clock.ticks_remaining != ticks:
		return "ticks_remaining must be unchanged: %d -> %d" % [ticks, clock.ticks_remaining]
	if clock.stage != stage:
		return "stage must be unchanged"
	if r["new_run"]["doomsday"] != clock:
		return "new_run should carry the same clock"
	if Chapter11.assess({"cr": 5000, "cargo": {}, "ships": [], "doomsday": clock})["insolvent"]:
		return "fresh run should be solvent"
	return "ok"

func test_next_seed_deterministic() -> String:
	var a: int = Chapter11.file(_snap(0, 1), MetaProfile.new(), 777)["report"]["next_seed"]
	var b: int = Chapter11.file(_snap(0, 1), MetaProfile.new(), 777)["report"]["next_seed"]
	if a != b:
		return "same inputs must give same seed"
	if a != Chapter11.next_seed_for(777, 0):
		return "file() must use next_seed_for(run_seed, filings before)"
	if a < 0:
		return "seed should be non-negative"
	if a == Chapter11.next_seed_for(778, 0):
		return "different run_seed should change seed"
	if Chapter11.next_seed_for(777, 0) == Chapter11.next_seed_for(777, 1):
		return "different filing count should change seed"
	return "ok"
