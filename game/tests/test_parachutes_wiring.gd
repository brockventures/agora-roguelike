extends RefCounted
## Tests for Golden Parachutes wiring into the run (PR 2 of #11).

func _owned(ids: Array) -> MetaProfile:
	var p := MetaProfile.new()
	for id in ids:
		p.add_unlock(str(id))
	return p

func _clock(debt: int = 0) -> DoomsdayClock:
	return DoomsdayClock.new(36000, debt, 0, 0)

func test_perks_change_fresh_run_start() -> String:
	var p := _owned(["seed_capital", "regulator_contact", "asset_protection"])
	var base := DoomsdayClock.new(36000, 0, 0, 100)
	var rc := RunController.new(p, 1, base)
	if rc.cr != Chapter11.FRESH_START_CR + 2000:
		return "starting cr %d" % rc.cr
	if rc.doomsday.interest_rate_bps_per_minute != 50:
		return "interest %d" % rc.doomsday.interest_rate_bps_per_minute
	if rc.haircut_bps() != 6000:
		return "haircut %d" % rc.haircut_bps()
	return "ok"

func test_fresh_start_cr_perk_applies_on_filing() -> String:
	var p := _owned(["seed_capital", "golden_handshake"])
	var rc := RunController.new(p, 1, _clock(1000000))
	rc.cr = 0
	if rc.file_bankruptcy().is_empty():
		return "filing rejected"
	var nxt := rc.next_run()
	if nxt.cr != Chapter11.FRESH_START_CR + 2000 or int(rc.carry_over["persists"]["fresh_start_cr"]) != nxt.cr:
		return "fresh start cr %d" % nxt.cr
	if not nxt.profile.has_unlock("golden_handshake") or nxt.modifiers.is_empty():
		return "perks must carry into the next corp"
	return "ok"

func test_explicit_modifiers_override_profile() -> String:
	var p := _owned(["seed_capital"])
	var explicit := {"starting_cr": {"add": 7, "mul_bps": 10000}}
	var rc := RunController.new(p, 1, _clock(), explicit)
	if rc.cr != Chapter11.FRESH_START_CR + 7:
		return "explicit should win, cr %d" % rc.cr
	return "ok"

func test_no_perk_run_unchanged() -> String:
	var rc := RunController.new(MetaProfile.new(), 1, DoomsdayClock.new(36000, 0, 5, 100))
	var plain := RunController.new(null, 1, DoomsdayClock.new(36000, 0, 5, 100))
	if not rc.modifiers.is_empty() or rc.cr != Chapter11.FRESH_START_CR:
		return "no-perk profile changed the run"
	if rc.doomsday.interest_rate_bps_per_minute != 100 or rc.doomsday.base_burn_per_second != 5:
		return "doomsday knobs changed"
	if rc.haircut_bps() != Chapter11.LIQUIDATION_HAIRCUT_BPS:
		return "haircut changed"
	if rc.fuel_discount_bps() != 0 or rc.hazard_odds_bps() != 10000 or rc.piracy_odds_bps() != 10000:
		return "transit factors not neutral"
	if rc.peak_net_worth != plain.peak_net_worth or not rc.carry_over.is_empty():
		return "bookkeeping differs"
	return "ok"

func test_fuel_discount_consumed_by_transit() -> String:
	var rc := RunController.new(_owned(["fuel_hedge"]), 1, _clock())
	if rc.fuel_discount_bps() != 1000:
		return "bps %d" % rc.fuel_discount_bps()
	var base := Transit.calculate_fuel_burn("earth", "mars", 0)
	if base <= 1:
		return "need a route with fuel > 1, got %d" % base
	var cut := Transit.calculate_fuel_burn("earth", "mars", 0, 0, false, 0.0, rc.fuel_discount_bps())
	if cut != maxi(1, base * 9000 / 10000):
		return "cut %d vs base %d" % [cut, base]
	if Transit.calculate_fuel_burn("earth", "mars", 0, 0, false, 0.0, 0) != base:
		return "zero discount changed fuel"
	if Transit.calculate_fuel_burn("earth", "mars", 0, 0, false, 0.0, 10000) != 1:
		return "full discount should floor at 1"
	return "ok"

func test_piracy_odds_consumed() -> String:
	var rc := RunController.new(_owned(["regulator_contact", "black_market_lanes"]), 1, _clock())
	if rc.piracy_odds_bps() != 8000:
		return "bps %d" % rc.piracy_odds_bps()
	var desk := Piracy.new([0.2, 0.2], null, null, 5)
	var a := desk.chance("a", "earth", "mars", false, "FRAG", 1000, false, 1)
	var b := desk.chance("a", "earth", "mars", false, "FRAG", 1000, false, 1, null, false, 1.0, 0, 1.0, 0, false, "", rc.piracy_odds_bps())
	if a["odds"] <= 0.0:
		return "baseline odds zero"
	if absf(float(b["exact_odds"]) - float(a["exact_odds"]) * 0.8) > 0.0000001:
		return "odds %s vs %s" % [str(b["exact_odds"]), str(a["exact_odds"])]
	var c := desk.chance("a", "earth", "mars", false, "FRAG", 1000, false, 1, null, false, 1.0, 0, 1.0, 0, false, "", 10000)
	if c["exact_odds"] != a["exact_odds"]:
		return "default bps changed odds"
	return "ok"

func test_hazard_odds_consumed() -> String:
	var h := Hazards.new([0.4, 0.2], null, null, 3)
	var q0 := h.quote()
	var q1 := h.quote(1.0, 1.0, 1.0, "", null, 5000)
	if absf(float(q1["p_delay"]) - float(q0["p_delay"]) * 0.5) > 0.0001:
		return "delay %s vs %s" % [str(q1["p_delay"]), str(q0["p_delay"])]
	if absf(float(q1["p_loss"]) - float(q0["p_loss"]) * 0.5) > 0.0001:
		return "loss odds not scaled"
	for i in range(50):
		var r := Hazards.new([1.0, 1.0], null, null, i).roll(10, 1.0, 1.0, 1.0, "a", null, 0)
		if r["delay"] != 0 or r["lost"] != 0:
			return "zero odds still hit"
	return "ok"

## Collapse a run by stepping its clock to the end.
func _collapse(rc: RunController) -> void:
	rc.doomsday.step_ticks(rc.doomsday.ticks_remaining + 1)

func test_severance_awarded_once_on_collapse() -> String:
	var p := MetaProfile.new()
	var rc := RunController.new(p, 1, DoomsdayClock.new(5, 0, 0, 0))
	var awards: Array = []
	rc.severance_awarded.connect(func(pts): awards.append(pts))
	_collapse(rc)
	if not rc.is_collapsed():
		return "run did not collapse"
	var expected := Parachutes.SEVERANCE_NET_WORTH_BPS * Chapter11.FRESH_START_CR / Parachutes.BPS
	if rc.profile.severance_points != expected or awards != [expected]:
		return "points %d awards %s expected %d" % [rc.profile.severance_points, str(awards), expected]
	if rc.end_run() != 0 or rc.end_run() != 0:
		return "second end_run should award nothing"
	_collapse(rc)
	if rc.profile.severance_points != expected or awards.size() != 1:
		return "double end re-awarded"
	return "ok"

## A corp that peaks at `peak` CR, then goes insolvent holding `cr_at_filing` CR.
func _insolvent_after_peak(p: MetaProfile, peak: int, cr_at_filing: int) -> RunController:
	var rc := RunController.new(p, 1, _clock())
	rc.cr = peak
	rc.advance(0.05)
	rc.doomsday.principal_debt = 1000000
	rc.cr = cr_at_filing
	rc.advance(0.05)
	return rc

func test_filing_awards_once_for_failed_corp_with_pre_filing_peak() -> String:
	# Marvin's review: peak must be the pre-filing 20,000, not the post-wipe
	# value of the 30,000 CR still held when the debt is cleared.
	var rc := _insolvent_after_peak(MetaProfile.new(), 20000, 30000)
	if not rc.pending_bankruptcy:
		return "setup: should be pending"
	var banked_peak := rc.peak_net_worth
	if banked_peak != 20000:
		return "setup peak %d" % banked_peak
	var report := rc.file_bankruptcy()
	var expected := Parachutes.SEVERANCE_PER_FILING + 20000 * Parachutes.SEVERANCE_NET_WORTH_BPS / Parachutes.BPS
	if report.is_empty() or rc.severance_award != expected or rc.profile.severance_points != expected:
		return "award %d expected %d" % [rc.severance_award, expected]
	if rc.carry_over["persists"]["severance_balance"] != expected or rc.profile.runs_completed != 1:
		return "carry-over summary wrong"
	if rc.corp_number != 2 or rc.peak_net_worth != rc.net_worth() or rc.peak_net_worth != Chapter11.FRESH_START_CR:
		return "new corp peak must restart from the fresh stake, got %d" % rc.peak_net_worth
	# Double-signalled filing: solvent after the wipe, so nothing more happens.
	if not rc.file_bankruptcy().is_empty() or rc.profile.severance_points != expected:
		return "double filing re-awarded"
	return "ok"

func test_filing_keeps_clock_and_rederives_perks() -> String:
	var rc := RunController.new(_owned(["seed_capital", "golden_handshake"]), 1, _clock())
	rc.advance(0.05)
	var ticks := rc.doomsday.ticks_remaining
	rc.doomsday.principal_debt = 1000000
	rc.cr = 0
	if rc.file_bankruptcy().is_empty():
		return "filing rejected"
	if rc.is_run_over() or rc.doomsday.ticks_remaining != ticks:
		return "clock must keep running, not reset"
	if rc.cr != Chapter11.FRESH_START_CR + 2000 or rc.modifiers.is_empty():
		return "fresh stake or perks wrong: cr %d" % rc.cr
	var seen: Array = []
	rc.corp_ended.connect(func(sm): seen.append(sm))
	rc.doomsday.principal_debt = 1000000
	rc.cr = 0
	rc.file_bankruptcy()
	if seen.size() != 1 or seen[0]["corp_number"] != 2 or rc.corp_number != 3:
		return "second corp should end once with its own summary"
	return "ok"

func test_save_load_midcorp_then_filing_awards_once() -> String:
	var rc := _insolvent_after_peak(_owned(["seed_capital"]), 20000, 0)
	var rc2 := RunController.from_dict(rc.to_dict())
	if rc2.corp_number != 1 or rc2.peak_net_worth != rc.peak_net_worth or not rc2.carry_over.is_empty():
		return "midcorp state lost"
	var before := rc2.profile.severance_points
	if rc2.file_bankruptcy().is_empty():
		return "loaded corp should file"
	var award := rc2.severance_award
	if award <= 0 or rc2.profile.severance_points != before + award:
		return "award %d points %d" % [award, rc2.profile.severance_points]
	var rc3 := RunController.from_dict(rc2.to_dict())
	if rc3.corp_number != 2 or rc3.severance_award != award or rc3.run_seed != rc2.run_seed:
		return "state not persisted across filing"
	if rc3.profile.severance_points != before + award:
		return "balance lost"
	return "ok"

func test_save_load_midrun_then_collapse_awards_once() -> String:
	var rc := RunController.new(_owned(["seed_capital"]), 1, DoomsdayClock.new(5, 0, 0, 0))
	var rc2 := RunController.from_dict(rc.to_dict())
	var before := rc2.profile.severance_points
	_collapse(rc2)
	var award := rc2.severance_award
	if award <= 0 or rc2.profile.severance_points != before + award or rc2.end_reason != "collapse":
		return "award %d points %d" % [award, rc2.profile.severance_points]
	var rc3 := RunController.from_dict(rc2.to_dict())
	if rc3.end_run() != 0 or rc3.profile.severance_points != before + award:
		return "loaded collapsed run re-awarded"
	return "ok"

func test_default_round_is_900_ticks() -> String:
	if RunController.DEFAULT_TICKS_PER_ROUND != 900 or RunController.new().ticks_per_round != 900:
		return "default round length"
	return "ok"

func test_collapse_after_filings_awards_final_corp_once() -> String:
	var rc := RunController.new(MetaProfile.new(), 1, DoomsdayClock.new(40, 1000000, 0, 0))
	rc.cr = 0
	rc.file_bankruptcy()
	var pts := rc.profile.severance_points
	_collapse(rc)
	var expected_final := Parachutes.SEVERANCE_NET_WORTH_BPS * Chapter11.FRESH_START_CR / Parachutes.BPS
	if rc.profile.severance_points != pts + expected_final or rc.end_reason != "collapse" or not rc.is_run_over():
		return "final corp award wrong"
	if rc.file_bankruptcy() != {}:
		return "cannot file after collapse"
	return "ok"

func test_next_run_after_collapse_keeps_perks_and_points() -> String:
	var p := _owned(["seed_capital"])
	var rc := RunController.new(p, 9, DoomsdayClock.new(5, 0, 0, 0))
	_collapse(rc)
	var s: Dictionary = rc.carry_over
	if s["reason"] != "collapse" or s["persists"]["unlocks"] != ["seed_capital"]:
		return "summary wrong"
	var nxt := rc.next_run()
	if nxt.profile.severance_points != rc.profile.severance_points or nxt.run_seed != rc.next_seed:
		return "next run state"
	if nxt.is_run_over() or nxt.cr != Chapter11.FRESH_START_CR:
		return "next run should be live with fresh-start stake"
	return "ok"
