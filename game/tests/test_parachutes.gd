extends RefCounted
## Tests for Golden Parachutes (PR 1 of #11).

func _perk(id: String, cost: int = 100, requires: Array = [], effects: Array = []) -> Dictionary:
	return {"id": id, "name": id, "tier": 1, "cost": cost, "requires": requires, "effects": effects}

func _fx(stat: String, op: String, value) -> Dictionary:
	return {"stat": stat, "op": op, "value": value}

func _tree(perks: Array) -> Parachutes:
	return Parachutes.load_from_dict({"perks": perks})

func _has_error(errors: Array, needle: String) -> bool:
	for e in errors:
		if str(e).contains(needle):
			return true
	return false

func _shipped() -> Parachutes:
	return Parachutes.load()

# --- shipped data ---

func test_shipped_tree_is_valid_placeholder_content() -> String:
	var t := _shipped()
	var errs := t.validate()
	if not errs.is_empty():
		return "shipped tree invalid: %s" % str(errs)
	if t.perks.size() != 6:
		return "expected 6 perks, got %d" % t.perks.size()
	var has_edge := false
	for id in t.perks:
		var p: Dictionary = t.perks[id]
		if not bool(p["placeholder"]):
			return "%s not marked placeholder" % id
		if int(p["tier"]) < 1 or int(p["tier"]) > 2:
			return "%s tier out of 1-2" % id
		if not (p["requires"] as Array).is_empty():
			has_edge = true
	if not has_edge:
		return "need at least one requires edge"
	return "ok"

func test_load_missing_file_reports_error() -> String:
	var t := Parachutes.load("res://data/does_not_exist.json")
	if t.validate().is_empty():
		return "missing file must be a validation error"
	return "ok"

# --- validation ---

func test_validate_clean_tree() -> String:
	var t := _tree([_perk("a", 10, [], [_fx("starting_cr", "add", 5)]), _perk("b", 10, ["a"])])
	var errs := t.validate()
	if not errs.is_empty():
		return "unexpected errors %s" % str(errs)
	return "ok"

func test_validate_unknown_stat() -> String:
	var errs := _tree([_perk("a", 1, [], [_fx("warp_speed", "add", 1)])]).validate()
	return "ok" if _has_error(errs, "unknown stat") else "no unknown stat error: %s" % str(errs)

func test_validate_unknown_op() -> String:
	var errs := _tree([_perk("a", 1, [], [_fx("starting_cr", "pow", 1)])]).validate()
	return "ok" if _has_error(errs, "unknown op") else "no unknown op error: %s" % str(errs)

func test_validate_unknown_requires() -> String:
	var errs := _tree([_perk("a", 1, ["ghost"])]).validate()
	return "ok" if _has_error(errs, "unknown requires id ghost") else "no unknown requires error: %s" % str(errs)

func test_validate_cycle() -> String:
	var errs := _tree([_perk("a", 1, ["b"]), _perk("b", 1, ["c"]), _perk("c", 1, ["a"])]).validate()
	if not _has_error(errs, "requires cycle"):
		return "no cycle error: %s" % str(errs)
	return "ok"

func test_validate_self_cycle() -> String:
	var errs := _tree([_perk("a", 1, ["a"])]).validate()
	return "ok" if _has_error(errs, "requires cycle") else "self-require not caught: %s" % str(errs)

func test_validate_duplicate_id() -> String:
	var errs := _tree([_perk("a"), _perk("a")]).validate()
	return "ok" if _has_error(errs, "duplicate id: a") else "no duplicate error: %s" % str(errs)

func test_validate_negative_cost() -> String:
	var errs := _tree([_perk("a", -5)]).validate()
	return "ok" if _has_error(errs, "negative cost") else "no negative cost error: %s" % str(errs)

func test_validate_non_integer_value() -> String:
	var errs := _tree([_perk("a", 1, [], [_fx("starting_cr", "add", 1.5)])]).validate()
	return "ok" if _has_error(errs, "not an integer") else "fractional value not caught: %s" % str(errs)

func test_integral_float_values_are_accepted() -> String:
	# JSON parses every number as float; integral ones must load as ints.
	var t := _tree([_perk("a", 10.0, [], [_fx("starting_cr", "add", 5.0)])])
	if not t.validate().is_empty():
		return "integral floats rejected: %s" % str(t.validate())
	return "ok"

# --- buying ---

func _profile(points: int) -> MetaProfile:
	var p := MetaProfile.new()
	p.severance_points = points
	return p

func test_buy_deducts_points_and_unlocks() -> String:
	var t := _shipped()
	var p := _profile(500)
	var r := t.buy(p, "seed_capital")
	if not bool(r["ok"]):
		return "buy failed: %s" % str(r)
	if p.severance_points != 300 or not p.has_unlock("seed_capital"):
		return "bad state after buy: %d points" % p.severance_points
	return "ok"

func test_buy_enforces_cost() -> String:
	var t := _shipped()
	var p := _profile(199)
	var r := t.buy(p, "seed_capital")
	if bool(r["ok"]) or not (r["reasons"] as Array).has("insufficient_points"):
		return "should reject for points: %s" % str(r)
	if p.severance_points != 199 or p.has_unlock("seed_capital"):
		return "rejected buy must not change profile"
	return "ok"

func test_buy_enforces_requires() -> String:
	var t := _shipped()
	var p := _profile(10000)
	var r := t.buy(p, "golden_handshake")
	if bool(r["ok"]):
		return "should require seed_capital"
	if not str((r["reasons"] as Array)[0]).begins_with("missing_requires:seed_capital"):
		return "wrong reason %s" % str(r)
	if p.severance_points != 10000:
		return "rejected buy must not deduct"
	t.buy(p, "seed_capital")
	if not bool(t.buy(p, "golden_handshake")["ok"]):
		return "should succeed once requirement owned"
	return "ok"

func test_rebuy_is_rejected_without_charge() -> String:
	var t := _shipped()
	var p := _profile(1000)
	t.buy(p, "seed_capital")
	var after := p.severance_points
	var r := t.buy(p, "seed_capital")
	if bool(r["ok"]) or not (r["reasons"] as Array).has("already_owned"):
		return "re-buy should be rejected as already_owned: %s" % str(r)
	if p.severance_points != after or p.unlocks.count("seed_capital") != 1:
		return "re-buy changed state"
	return "ok"

func test_buy_unknown_perk() -> String:
	var r := _shipped().can_buy(_profile(10000), "nope")
	if bool(r["ok"]) or not (r["reasons"] as Array).has("unknown_perk"):
		return "unknown perk should be rejected"
	return "ok"

# --- modifiers ---

func test_modifiers_empty_for_no_perks() -> String:
	return "ok" if _shipped().modifiers(MetaProfile.new()).is_empty() else "expected empty"

func test_modifiers_fold_add_and_mul() -> String:
	var t := _tree([
		_perk("a", 1, [], [_fx("starting_cr", "add", 100), _fx("piracy_odds_bps", "mul_bps", 8000)]),
		_perk("b", 1, [], [_fx("starting_cr", "add", 50), _fx("piracy_odds_bps", "mul_bps", 5000)]),
	])
	var p := MetaProfile.new()
	p.add_unlock("a")
	p.add_unlock("b")
	var m := t.modifiers(p)
	if m["starting_cr"]["add"] != 150:
		return "adds should sum"
	if m["piracy_odds_bps"]["mul_bps"] != 4000:
		return "0.8 * 0.5 should be 4000 bps, got %s" % str(m["piracy_odds_bps"]["mul_bps"])
	if not (m["starting_cr"]["add"] is int and m["piracy_odds_bps"]["mul_bps"] is int):
		return "values must be ints"
	return "ok"

func test_modifiers_order_independent() -> String:
	var t := _tree([
		_perk("a", 1, [], [_fx("burn_rate", "mul_bps", 9333)]),
		_perk("b", 1, [], [_fx("burn_rate", "mul_bps", 7777)]),
		_perk("c", 1, [], [_fx("burn_rate", "mul_bps", 8123), _fx("burn_rate", "add", -3)]),
	])
	var orders := [["a", "b", "c"], ["c", "b", "a"], ["b", "c", "a"]]
	var first := {}
	for o in orders:
		var p := MetaProfile.new()
		for id in o:
			p.add_unlock(id)
		var m := t.modifiers(p)
		if first.is_empty():
			first = m
		elif m != first:
			return "order changed result: %s vs %s" % [str(m), str(first)]
	return "ok"

func test_modifiers_ignore_foreign_unlocks() -> String:
	var p := MetaProfile.new()
	p.add_unlock("some_other_unlock")
	return "ok" if _shipped().modifiers(p).is_empty() else "foreign unlock leaked"

func test_apply_stat_integer_math() -> String:
	var m := {"x": {"add": 3, "mul_bps": 8000}}
	if Parachutes.apply_stat(m, "x", 100) != 82:  # (100+3)*0.8 = 82.4 -> 82
		return "bad apply_stat"
	if Parachutes.apply_stat(m, "missing", 7) != 7:
		return "missing stat should return base"
	return "ok"

# --- severance ---

func test_award_severance_formula() -> String:
	var p := MetaProfile.new()
	var award := Parachutes.award_severance(p, 2, 100000)
	var want: int = 2 * Parachutes.SEVERANCE_PER_FILING + 100000 * Parachutes.SEVERANCE_NET_WORTH_BPS / 10000
	if award != want or p.severance_points != want:
		return "award %d points %d want %d" % [award, p.severance_points, want]
	if Parachutes.award_severance(p, -4, -9) != 0 or p.severance_points != want:
		return "negative inputs must award zero"
	return "ok"

# --- profile ---

func test_severance_points_roundtrip_and_sanitise() -> String:
	var p := MetaProfile.new()
	p.severance_points = 321
	if MetaProfile.from_dict(p.to_dict()).severance_points != 321:
		return "did not roundtrip"
	if MetaProfile.from_dict({"severance_points": -5}).severance_points != 0:
		return "negative not clamped"
	if MetaProfile.from_dict({"severance_points": "lots"}).severance_points != 0:
		return "non-number not zeroed"
	if MetaProfile.from_dict({}).severance_points != 0:
		return "missing should be 0"
	return "ok"

# --- RunController wiring ---

func _owned(ids: Array, points: int = 0) -> MetaProfile:
	var p := MetaProfile.new()
	p.severance_points = points
	for id in ids:
		p.add_unlock(id)
	return p

func test_seed_capital_changes_starting_cr() -> String:
	var t := _shipped()
	var p := _owned(["seed_capital"])
	var rc := RunController.new(p, 1, null, t.modifiers(p))
	if rc.cr != Chapter11.FRESH_START_CR + 2000:
		return "starting cr %d" % rc.cr
	var plain := RunController.new(MetaProfile.new(), 1)
	if plain.cr != Chapter11.FRESH_START_CR:
		return "no-perk run must be unchanged"
	return "ok"

func test_regulator_contact_lowers_doomsday_interest() -> String:
	var t := _shipped()
	var p := _owned(["regulator_contact"])
	var rc := RunController.new(p, 1, null, t.modifiers(p))
	if rc.doomsday.interest_rate_bps_per_minute != DoomsdayClock.DEFAULT_INTEREST_RATE_BPS_PER_MINUTE - 50:
		return "interest bps %d" % rc.doomsday.interest_rate_bps_per_minute
	# re-applying must not stack
	rc.apply_modifiers(t.modifiers(p))
	if rc.doomsday.interest_rate_bps_per_minute != DoomsdayClock.DEFAULT_INTEREST_RATE_BPS_PER_MINUTE - 50:
		return "re-apply stacked"
	return "ok"

func test_burn_rate_modifier_applies() -> String:
	var mods := {"burn_rate": {"add": 0, "mul_bps": 5000}}
	var rc := RunController.new(null, 1, DoomsdayClock.new(36000, 0, 20, 0), mods)
	if rc.doomsday.base_burn_per_second != 10:
		return "burn %d" % rc.doomsday.base_burn_per_second
	return "ok"

func test_golden_handshake_sets_fresh_start_cr() -> String:
	var t := _shipped()
	var p := _owned(["seed_capital", "golden_handshake"])
	var rc := RunController.new(p, 1, DoomsdayClock.new(36000, 1000000, 0, 0), t.modifiers(p))
	rc.cr = 0
	var report := rc.file_bankruptcy()
	if report.is_empty():
		return "should have filed"
	if rc.cr != Chapter11.FRESH_START_CR + 2000:
		return "fresh start cr %d" % rc.cr
	return "ok"

func test_asset_protection_raises_haircut() -> String:
	var t := _shipped()
	var p := _owned(["seed_capital", "asset_protection"])
	var rc := RunController.new(p, 1, null, t.modifiers(p))
	if rc.haircut_bps() != 6000:
		return "haircut %d" % rc.haircut_bps()
	rc.cr = 0
	rc.ships = [{"id": "h", "hull_value_cr": 1000}]
	if rc.assess()["liquidation_value"] != 600:
		return "liquidation should use 60%%, got %s" % str(rc.assess()["liquidation_value"])
	if MetaProfile.new() == null or RunController.new().haircut_bps() != Chapter11.LIQUIDATION_HAIRCUT_BPS:
		return "default haircut changed"
	return "ok"

func test_pending_modifiers_are_exposed_not_applied() -> String:
	var t := _shipped()
	var p := _owned(["fuel_hedge", "regulator_contact", "black_market_lanes"])
	var rc := RunController.new(p, 1, null, t.modifiers(p))
	if rc.modifiers["fuel_discount_bps"]["add"] != 1000 or rc.modifiers["piracy_odds_bps"]["mul_bps"] != 8000:
		return "pending modifiers should be exposed on the controller"
	return "ok"

func test_controller_roundtrip_keeps_modifiers() -> String:
	var t := _shipped()
	var p := _owned(["regulator_contact", "seed_capital", "golden_handshake"])
	var rc := RunController.new(p, 1, null, t.modifiers(p))
	var rc2 := RunController.from_dict(rc.to_dict())
	if rc2.modifiers != rc.modifiers:
		return "modifiers lost in roundtrip"
	if rc2.doomsday.interest_rate_bps_per_minute != rc.doomsday.interest_rate_bps_per_minute:
		return "interest changed in roundtrip"
	rc2.apply_modifiers(rc2.modifiers)
	if rc2.doomsday.interest_rate_bps_per_minute != rc.doomsday.interest_rate_bps_per_minute:
		return "re-apply after load stacked"
	if RunController._sanitise_modifiers({"bogus": {"add": 1}, "starting_cr": "x"}) != {}:
		return "bad modifiers not dropped"
	return "ok"
