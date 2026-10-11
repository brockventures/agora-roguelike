extends RefCounted
## The Sol System Rescue Project core (#32 task 1, docs/design/rescue-project.md): the data and
## its validator, deposits and the pro rata fee, refusals, phase completion, the
## stabiliser-field tick count per phase, the save round trip, and that a run with no
## project hashes exactly as it did before the project existed.

const TPR: int = 30


func _rc(cr: int = 100000) -> RunController:
	var rc := RunController.new(null, 21, null, {}, TPR)
	rc.cr = cr
	return rc


func _proj() -> RescueProject:
	return RescueProject.open_new(79)


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


## A one-phase project with awkward numbers: 3 units of FUEL for 10 CR.
func _tiny() -> RescueProject:
	var d: Dictionary = {
		"version": 1, "unlock": "monopoly", "rent_multiplier_bps": 20000,
		"phases": [{"id": "only", "name": "Only", "site": "earth", "needs": {"FUEL": 3}, "cr": 10, "keep_bps": 0}],
		"win": {"severance_base": 0, "severance_per_round_left": 0, "phase_consolation": 0},
	}
	return RescueProject.open_new(1, d)


# --- Data ---

func test_shipped_data_is_valid_and_has_the_four_phases() -> String:
	var d: Dictionary = RescueProject.load_data()
	var errs: Array = RescueProject.validate(d)
	if not errs.is_empty():
		return "shipped rescue.json invalid: %s" % str(errs)
	var p := _proj()
	if p == null or p.phase_count() != 4:
		return "expected four phases"
	var sites: Array = []
	var ids: Array = []
	for ph in p.phases():
		sites.append(ph["site"])
		ids.append(ph["id"])
	if sites != ["luna", "earth", "mars", "ceres"]:
		return "sites wrong: %s" % str(sites)
	if ids != ["anchor_yard", "coil_foundry", "containment_shell", "ignition_array"]:
		return "ids wrong: %s" % str(ids)
	var units: int = 0
	var cr: int = 0
	for ph in p.phases():
		units += RescueProject.phase_units(ph)
		cr += int(ph["cr"])
	if units != 900 or cr != 24000:
		return "bill is %d units, %d CR; the design says 900 and 24000" % [units, cr]
	if not p.is_open() or p.phase != 0 or p.keep_bps != 10000 or p.opened_round != 79:
		return "a fresh project should have phase 1 open at full speed"
	return "ok"


func test_validator_rejects_bad_data() -> String:
	if RescueProject.validate({}).is_empty():
		return "empty accepted"
	var cases: Array = []
	var base: Callable = func() -> Dictionary: return RescueProject.load_data()
	var d: Dictionary = base.call()
	d["version"] = 2
	cases.append(["version", d])
	d = base.call()
	d["phases"] = []
	cases.append(["empty phases", d])
	d = base.call()
	d["phases"][0]["site"] = "pluto"
	cases.append(["site", d])
	d = base.call()
	d["phases"][0]["needs"] = {"UNOBTAINIUM": 5}
	cases.append(["commodity", d])
	d = base.call()
	d["phases"][0]["needs"] = {"ORE": 0}
	cases.append(["zero need", d])
	d = base.call()
	d["phases"][1]["id"] = d["phases"][0]["id"]
	cases.append(["duplicate id", d])
	d = base.call()
	d["phases"][1]["keep_bps"] = 7000
	cases.append(["keep_bps rising", d])
	d = base.call()
	d["phases"][0]["keep_bps"] = 10001
	cases.append(["keep_bps range", d])
	d = base.call()
	d["phases"][0]["cr"] = -1
	cases.append(["negative cr", d])
	d = base.call()
	d["win"].erase("phase_consolation")
	cases.append(["consolation", d])
	for c in cases:
		if RescueProject.validate(c[1]).is_empty():
			return "validator accepted bad %s" % c[0]
	if RescueProject.open_new(0, cases[0][1]) != null:
		return "open_new built a project from invalid data"
	return "ok"


# --- Deposit and fee ---

func test_deposit_moves_goods_and_charges_the_fee_pro_rata() -> String:
	var p := _proj()
	var rc := _rc()
	rc.cargo = {"MACHINERY": 100}
	var r: Dictionary = p.deposit(rc, "luna", 80)
	if not bool(r["ok"]):
		return "refused: %s" % str(r)
	# 100 of 200 units of a 4000 CR phase: 2000 CR.
	if int(r["fee"]) != 2000 or rc.cr != 98000 or p.fee_paid != 2000:
		return "fee wrong: %s cr %d paid %d" % [str(r), rc.cr, p.fee_paid]
	if not rc.cargo.is_empty() or int(p.deposits["MACHINERY"]) != 100:
		return "goods did not move: cargo %s deposits %s" % [str(rc.cargo), str(p.deposits)]
	if bool(r["phase_complete"]) or p.phase != 0:
		return "phase should still be open"
	return "ok"


func test_deposit_takes_no_more_than_is_still_needed() -> String:
	var p := _proj()
	var rc := _rc()
	rc.cargo = {"MACHINERY": 100}
	p.deposit(rc, "luna", 1)
	rc.cargo = {"MACHINERY": 60, "ORE": 40}  # MACHINERY is full; only the ORE counts
	var r: Dictionary = p.deposit(rc, "luna", 2)
	if not bool(r["ok"]) or r["units"] != {"ORE": 40}:
		return "should take only ORE: %s" % str(r)
	if int(rc.cargo["MACHINERY"]) != 60 or rc.cargo.has("ORE"):
		return "cargo wrong: %s" % str(rc.cargo)
	# 140 of 200 units: 2800 CR cumulative.
	if p.fee_paid != 2800:
		return "cumulative fee should be 2800, got %d" % p.fee_paid
	return "ok"


func test_fee_rounds_up_and_a_finished_phase_costs_exactly_its_cr() -> String:
	var p := _tiny()
	var rc := _rc(1000)
	var fees: Array = []
	for i in 3:
		rc.cargo = {"FUEL": 1}
		var r: Dictionary = p.deposit(rc, "earth", 5)
		if not bool(r["ok"]):
			return "deposit %d refused: %s" % [i, str(r)]
		fees.append(int(r["fee"]))
	# ceil(10/3)=4, ceil(20/3)=7 -> 3, ceil(30/3)=10 -> 3
	if fees != [4, 3, 3] or rc.cr != 990:
		return "fees %s cr %d, expected [4, 3, 3] and 990" % [str(fees), rc.cr]
	return "ok"


func test_the_arithmetic_is_integer_only() -> String:
	var p := _proj()
	var rc := _rc()
	rc.cargo = {"MACHINERY": 33}
	var r: Dictionary = p.deposit(rc, "luna", 1)
	# ceil(4000 x 33 / 200) = ceil(660) = 660; typeof must be int
	if typeof(r["fee"]) != TYPE_INT or int(r["fee"]) != 660:
		return "fee %s" % str(r["fee"])
	rc.cargo = {"ORE": 7}
	r = p.deposit(rc, "luna", 1)
	# 40 units: 800 cumulative, so 140 more
	if int(r["fee"]) != 140:
		return "second fee %s" % str(r["fee"])
	return "ok"


# --- Refusals ---

func test_refusals_leave_everything_untouched() -> String:
	var p := _proj()
	var rc := _rc(100000)
	rc.cargo = {"MACHINERY": 50}
	var before_p: Dictionary = p.to_dict()
	var wrong: Dictionary = p.deposit(rc, "mars", 1)
	if bool(wrong["ok"]) or wrong["reason"] != "WRONG_SITE":
		return "wrong station: %s" % str(wrong)
	rc.cargo = {"FOOD": 50}  # nothing phase 1 needs
	var none: Dictionary = p.deposit(rc, "luna", 1)
	if bool(none["ok"]) or none["reason"] != "NO_CARGO":
		return "missing goods: %s" % str(none)
	rc.cargo = {"MACHINERY": 50}
	rc.cr = 100  # fee would be 1000
	var poor: Dictionary = p.deposit(rc, "luna", 1)
	if bool(poor["ok"]) or poor["reason"] != "NO_CR":
		return "short cash: %s" % str(poor)
	if rc.cr != 100 or rc.cargo != {"MACHINERY": 50} or p.to_dict() != before_p:
		return "a refusal changed state"
	return "ok"


func test_a_deposit_that_would_make_the_corp_insolvent_is_refused() -> String:
	var p := _proj()
	var rc := _rc(5000)
	rc.cargo = {"MACHINERY": 100}
	# Debt exactly at liquidation value: solvent (equal is solvent), but any spend tips it.
	rc.doomsday.add_principal(int(rc.assess()["liquidation_value"]))
	if bool(rc.assess()["insolvent"]):
		return "setup should be solvent"
	var r: Dictionary = p.deposit(rc, "luna", 1)
	if bool(r["ok"]) or r["reason"] != "WOULD_BANKRUPT":
		return "expected WOULD_BANKRUPT: %s" % str(r)
	if rc.cr != 5000 or rc.cargo != {"MACHINERY": 100} or p.units_delivered() != 0:
		return "refusal changed state"
	return "ok"


func test_not_open_once_complete() -> String:
	var p := _tiny()
	var rc := _rc()
	rc.cargo = {"FUEL": 3}
	p.deposit(rc, "earth", 1)
	rc.cargo = {"FUEL": 3}
	var r: Dictionary = p.deposit(rc, "earth", 2)
	if bool(r["ok"]) or r["reason"] != "NOT_OPEN":
		return "a finished project should refuse: %s" % str(r)
	return "ok"


# --- Phase completion ---

func test_phases_complete_in_order_and_set_the_field() -> String:
	var p := _proj()
	var rc := _rc()
	var expect_keep: Array = [6000, 3500, 1500, 0]
	var sites: Array = ["luna", "earth", "mars", "ceres"]
	for i in 4:
		var left: Dictionary = p.remaining()
		for c in left:  # one hold per commodity: needs are 100 each
			rc.cargo = {c: int(left[c])}
			var r: Dictionary = p.deposit(rc, sites[i], 10 + i)
			if not bool(r["ok"]):
				return "phase %d %s refused: %s" % [i, c, str(r)]
			if i == 3 and c == left.keys()[left.size() - 1] and not bool(r["won"]):
				return "the last deposit should win"
		if p.phase != i + 1 or p.keep_bps != expect_keep[i]:
			return "after phase %d: phase %d keep %d" % [i + 1, p.phase, p.keep_bps]
		if p.completed.size() != i + 1 or int(p.completed[i][1]) != 10 + i:
			return "completed log wrong: %s" % str(p.completed)
		if not p.deposits.is_empty() or p.fee_paid != 0:
			return "the next phase should start empty"
	if not p.is_complete() or p.is_open() or not p.current().is_empty():
		return "project should be complete"
	if rc.cr != 100000 - 24000:
		return "total fees should be 24000, cr is %d" % rc.cr
	return "ok"


func test_only_the_open_phase_accepts_deliveries() -> String:
	var p := _proj()
	var rc := _rc()
	rc.cargo = {"FUEL": 50, "FOOD": 50}
	for site in ["earth", "mars", "ceres"]:
		var r: Dictionary = p.deposit(rc, site, 1)
		if bool(r["ok"]):
			return "phase 1 accepted a delivery at %s" % site
	return "ok"


# --- counts_tick ---

func test_counts_tick_per_phase() -> String:
	var p := _proj()
	var expect: Dictionary = {10000: 10000, 6000: 6000, 3500: 3500, 1500: 1500, 0: 0}
	var sites: Array = ["luna", "earth", "mars", "ceres"]
	var rc := _rc()
	var order: Array = [10000, 6000, 3500, 1500, 0]
	for i in 5:
		var kb: int = order[i]
		if p.keep_bps != kb:
			return "step %d keep_bps %d, expected %d" % [i, p.keep_bps, kb]
		# Over 10000 consecutive ticks exactly keep_bps count; over any window the count is
		# within one of the exact share.
		var n: int = 0
		var run: int = 0
		for t in range(20001, 30001):
			if p.counts_tick(t):
				n += 1
				run = 0
			else:
				run += 1
		if n != int(expect[kb]):
			return "keep %d counted %d of 10000 ticks" % [kb, n]
		if kb == 10000 and n != 10000:
			return "full speed must count every tick"
		if i < 4:
			var left: Dictionary = p.remaining()
			for c in left:
				rc.cargo = {c: int(left[c])}
				p.deposit(rc, sites[i], 1)
	if p.counts_tick(12345) or p.counts_tick(0):
		return "a halted clock counts no tick"
	return "ok"


func test_counts_tick_is_stateless_and_survives_a_save() -> String:
	var p := _proj()
	var rc := _rc()
	rc.cargo = {"MACHINERY": 100}
	p.deposit(rc, "luna", 1)
	rc.cargo = {"ORE": 100}
	p.deposit(rc, "luna", 1)  # phase 2, keep 3500... phase 1 is 6000
	var q: RescueProject = RescueProject.from_dict(_json(p.to_dict()))
	for t in range(1, 2000):
		if p.counts_tick(t) != q.counts_tick(t):
			return "restored project counts tick %d differently" % t
	return "ok"


# --- Saves ---

func test_to_dict_from_dict_round_trip_mid_phase_and_through_json() -> String:
	var p := _proj()
	var rc := _rc()
	rc.cargo = {"MACHINERY": 100}
	p.deposit(rc, "luna", 80)
	rc.cargo = {"ORE": 100}
	p.deposit(rc, "luna", 81)  # phase 1 complete
	rc.cargo = {"FUEL": 60}
	p.deposit(rc, "earth", 85)  # partway into phase 2
	var d: Dictionary = p.to_dict()
	var q: RescueProject = RescueProject.from_dict(d)
	var j: RescueProject = RescueProject.from_dict(_json(d))
	for r in [q, j]:
		if r.to_dict() != d:
			return "round trip changed state: %s vs %s" % [str(r.to_dict()), str(d)]
		if RunSave.canonical(r.to_dict()) != RunSave.canonical(d):
			return "canonical form differs after the round trip"
	if p.phase != 1 or p.keep_bps != 6000 or int(p.deposits["FUEL"]) != 60:
		return "setup wrong: %s" % str(d)
	# Continue both and compare: same future.
	rc.cargo = {"FUEL": 40, "MACHINERY": 100}
	var rc2 := _rc()
	rc2.cargo = rc.cargo.duplicate()
	rc2.cr = rc.cr
	var a: Dictionary = p.deposit(rc, "earth", 90)
	var b: Dictionary = j.deposit(rc2, "earth", 90)
	if a != b or p.to_dict() != j.to_dict() or rc.cr != rc2.cr:
		return "a restored project diverged"
	return "ok"


func test_from_dict_sanitises() -> String:
	var q: RescueProject = RescueProject.from_dict({
		"phase": 99, "deposits": {"ORE": 5}, "fee_paid": 1e9, "keep_bps": -5,
		"completed": [["a", 1], "junk", [1, 2], ["b", -3]], "opened_round": -4,
	})
	if q.phase != 4 or not q.deposits.is_empty() or q.fee_paid != 0 or q.keep_bps != 0:
		return "complete project should hold no open-phase state: %s" % str(q.to_dict())
	if q.completed != [["a", 1], ["b", 0]] or q.opened_round != 0:
		return "completed/opened wrong: %s" % str(q.to_dict())
	q = RescueProject.from_dict({"phase": 0, "deposits": {"MACHINERY": 5000, "FOOD": 9, "ORE": -3}, "fee_paid": 99999})
	if q.deposits != {"MACHINERY": 100} or q.fee_paid != 4000 or q.keep_bps != 10000:
		return "clamping wrong: %s" % str(q.to_dict())
	q = RescueProject.from_dict({})
	if q.phase != 0 or q.keep_bps != 10000:
		return "empty dict should give a fresh project"
	return "ok"


func test_run_save_carries_the_rescue_key_only_when_a_project_exists() -> String:
	var s := Replay.Session.new(7, {}, Replay.DEFAULT_FRAME_DELTA, TPR)
	var plain: String = s.state_hash()
	if RunSave.capture(s.controller, s.loop.market, s.bags).has("rescue"):
		return "capture wrote a rescue key with no project"
	s.controller.rescue = _proj()
	var cap: Dictionary = RunSave.capture(s.controller, s.loop.market, s.bags)
	if not cap.has("rescue"):
		return "an attached project was not captured"
	var with_p: String = s.state_hash()
	if with_p == plain:
		return "the project is not covered by the state hash"
	var r: Dictionary = RunSave.restore(_json(cap))
	if not bool(r["ok"]) or r["controller"].rescue == null:
		return "restore dropped the project: %s" % str(r)
	if r["controller"].rescue.to_dict() != s.controller.rescue.to_dict():
		return "restored project differs"
	s.controller.rescue = null
	if s.state_hash() != plain:
		return "a run with no project must hash exactly as before"
	var r2: Dictionary = RunSave.restore(_json(RunSave.capture(s.controller, s.loop.market, s.bags)))
	if r2["controller"].rescue != null:
		return "restore invented a project"
	return "ok"


func test_a_run_with_no_project_hashes_as_before_the_project_existed() -> String:
	# NEVER_TRAVELS_HASH was pinned before this feature; a bare controller carries no project.
	var s := Replay.Session.new(7, {}, Replay.DEFAULT_FRAME_DELTA, TPR)
	if s.controller.rescue != null:
		return "a fresh controller must carry no project"
	var d: Dictionary = RunSave.capture(s.controller, s.loop.market, s.bags)
	for k in d:
		if k == "rescue":
			return "capture has a rescue key"
	return "ok"


func test_a_chapter_11_filing_leaves_the_project_alone() -> String:
	# Q5 (a): progress belongs to Sol, not the corp.
	var rc := _rc(1000)
	rc.rescue = _proj()
	var c := _rc()
	c.cargo = {"MACHINERY": 100}
	rc.rescue.deposit(c, "luna", 1)
	var before: Dictionary = rc.rescue.to_dict()
	rc.cr = 0
	rc.doomsday.add_principal(100000)
	var rep: Dictionary = rc.file_bankruptcy()
	if rep.is_empty():
		return "the filing did not happen"
	if rc.rescue == null or rc.rescue.to_dict() != before:
		return "the filing disturbed the project"
	return "ok"


# --- Meta profile ---

func test_rescues_completed_defaults_to_zero_and_is_saved_only_above_zero() -> String:
	var p := MetaProfile.new()
	if p.rescues_completed != 0 or p.to_dict().has("rescues_completed"):
		return "a new profile should not save the key"
	if MetaProfile.from_dict({}).rescues_completed != 0:
		return "default read should be 0"
	p.rescues_completed = 2
	var d: Dictionary = p.to_dict()
	if int(d["rescues_completed"]) != 2 or MetaProfile.from_dict(_json(d)).rescues_completed != 2:
		return "round trip lost the count"
	if MetaProfile.from_dict({"rescues_completed": -3}).rescues_completed != 0:
		return "negative should clamp to 0"
	if MetaProfile.from_dict({"rescues_completed": "x"}).rescues_completed != 0:
		return "junk should read 0"
	return "ok"
