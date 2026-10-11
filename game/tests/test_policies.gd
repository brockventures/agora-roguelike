extends RefCounted
## #160 PR 1: policies.json, exclusions, Parachutes.combine / modifiers_for, and the
## RunController perk_modifiers seam (docs/design/corporate-policies.md sections 5, 7, 13).

func _pol() -> Parachutes:
	return Parachutes.load_policies()

func _perks() -> Parachutes:
	return Parachutes.load()

func _owned(ids: Array) -> MetaProfile:
	var p := MetaProfile.new()
	for id in ids:
		p.add_unlock(str(id))
	return p

func _clock(debt: int = 0) -> DoomsdayClock:
	return DoomsdayClock.new(36000, debt, 0, 100)

func _node(id: String, requires = [], excludes = [], effects = []) -> Dictionary:
	return {"id": id, "tier": 1, "requires": requires, "excludes": excludes, "effects": effects}

func _tree(nodes: Array) -> Parachutes:
	return Parachutes.load_from_dict({"policies": nodes}, "policies")

func _has_error(errors: Array, needle: String) -> bool:
	for e in errors:
		if str(e).contains(needle):
			return true
	return false

func _m(add: int, mul: int = 10000) -> Dictionary:
	return {"add": add, "mul_bps": mul}

# --- shipped data ---

func test_shipped_policies_are_valid_and_shaped_like_the_doc() -> String:
	var t := _pol()
	var errs := t.validate()
	if not errs.is_empty():
		return "shipped policies invalid: %s" % str(errs)
	if t.perks.size() != 12:
		return "expected 12 nodes, got %d" % t.perks.size()
	if t.milestones != [20, 50, 80] or not t.takeover_pick:
		return "pick rules wrong: %s %s" % [str(t.milestones), str(t.takeover_pick)]
	var per_branch := {}
	for id in t.perks:
		var n: Dictionary = t.perks[id]
		per_branch[n["branch"]] = int(per_branch.get(n["branch"], 0)) + 1
		if str(n["name_key"]) != "POLICY_" + str(id).to_upper() and str(n["name_key"]).is_empty():
			return "%s has no name_key" % id
		if str(n["desc_key"]) != str(n["name_key"]) + "_DESC":
			return "%s desc_key is not name_key + _DESC" % id
		if int(n["cost"]) != 0:
			return "%s has a cost; a policy is free" % id
		if int(n["tier"]) == 1 and (not n["requires"].is_empty() or not n["excludes"].is_empty()):
			return "root %s has requires or excludes" % id
		if int(n["tier"]) == 2:
			if n["requires"].size() != 1 or n["excludes"].size() != 1:
				return "capstone %s is not one root plus one sibling" % id
	if per_branch.size() != 4:
		return "expected 4 branches, got %s" % str(per_branch)
	for b in per_branch:
		if per_branch[b] != 3:
			return "branch %s has %d nodes" % [b, per_branch[b]]
	return "ok"

func test_shipped_policy_effects_match_the_doc_table() -> String:
	var t := _pol()
	var want := {
		"supply_chain": [["fuel_discount_bps", "add", 1500]],
		"risk_transfer": [["piracy_odds_bps", "mul_bps", 7000]],
		"corridor_access": [["hazard_odds_bps", "mul_bps", 6000], ["toll_discount_bps", "add", 10000]],
		"cost_containment": [["burn_rate", "mul_bps", 9000]],
		"covenant_relief": [["interest_bps", "add", -30]],
		"wind_down": [["liquidation_haircut_bps", "add", 1500]],
		"training_module": [["bankruptcy_grace_ticks", "add", 1800]],
		"prepack_reorg": [["fresh_start_cr", "add", 3000]],
		"exit_package": [["severance_bps", "mul_bps", 12500]],
		"synergy_review": [["takeover_threshold_shares", "add", -20]],
		"lbo_framework": [["assumed_debt_bps", "mul_bps", 6000]],
		"rollup_mandate": [["takeover_threshold_shares", "add", -30]],
	}
	for id in want:
		if not t.has_perk(id):
			return "missing node %s" % id
		var got: Array = []
		for e in t.perks[id]["effects"]:
			got.append([e["stat"], e["op"], e["value"]])
		if got != want[id]:
			return "%s effects %s != %s" % [id, str(got), str(want[id])]
	return "ok"

func test_perk_tree_still_loads_and_has_no_pick_rules() -> String:
	var t := _perks()
	if not t.validate().is_empty() or t.perks.size() != 8:
		return "perk tree changed"
	if not t.milestones.is_empty() or t.takeover_pick:
		return "perk tree picked up policy pick rules"
	return "ok"

# --- exclusion validation ---

func test_excludes_must_name_known_ids() -> String:
	var errs := _tree([_node("a", [], ["ghost"])]).validate()
	return "ok" if _has_error(errs, "unknown excludes id ghost") else "not flagged: %s" % str(errs)

func test_excludes_must_be_symmetric() -> String:
	var errs := _tree([_node("a", [], ["b"]), _node("b")]).validate()
	return "ok" if _has_error(errs, "does not exclude a back") else "not flagged: %s" % str(errs)

func test_excludes_cannot_name_self_or_a_requirement() -> String:
	var errs := _tree([_node("a", [], ["a"])]).validate()
	if not _has_error(errs, "excludes itself"):
		return "self exclusion not flagged: %s" % str(errs)
	errs = _tree([_node("a"), _node("b", ["a"], ["a"])]).validate()
	if not _has_error(errs, "which it also requires"):
		return "requires/excludes clash not flagged: %s" % str(errs)
	return "ok"

func test_a_symmetric_fork_validates() -> String:
	var errs := _tree([_node("root"), _node("l", ["root"], ["r"]), _node("r", ["root"], ["l"])]).validate()
	return "ok" if errs.is_empty() else str(errs)

# --- hostile JSON ---

func test_hostile_policy_files_report_errors_and_never_crash() -> String:
	var t := Parachutes.load_from_dict({"policies": "nope"}, "policies")
	if not _has_error(t.validate(), "policies is not an array"):
		return "non-array policies not flagged"
	t = Parachutes.load_from_dict({"policies": [5, null, [], {"id": 7}, {"name_key": "x"}]}, "policies")
	if not t.perks.is_empty() or t.validate().is_empty():
		return "junk nodes should load nothing and report errors"
	t = _tree([_node("a", "x", 5), _node("a")])
	if not _has_error(t.validate(), "duplicate id: a"):
		return "duplicate id not flagged"
	if t.perks["a"]["requires"] != [] or t.perks["a"]["excludes"] != []:
		return "non-array requires or excludes kept"
	t = _tree([_node("a", [], [], [{"stat": "bogus", "op": "add", "value": 1}, {"stat": "burn_rate", "op": "pow", "value": 1}, {"stat": "burn_rate", "op": "add", "value": 1.5}, {"stat": "burn_rate", "op": "mul_bps", "value": -1}, 7])])
	var errs := t.validate()
	for needle in ["unknown stat bogus", "unknown op pow", "is not an integer", "negative mul_bps"]:
		if not _has_error(errs, needle):
			return "missing error %s in %s" % [needle, str(errs)]
	if t.modifiers_for(["a"]).has("bogus"):
		return "unknown stat leaked into a fold"
	return "ok"

func test_hostile_pick_rules_grant_nothing() -> String:
	for bad in [{"milestones": "20"}, {"milestones": [50, 20]}, {"milestones": [0]}, {"milestones": [-5, 10]}, {"milestones": [20.5]}, {"milestones": ["20"]}, {"milestones": [20, 20]}]:
		var d: Dictionary = bad.duplicate()
		d["policies"] = []
		var t := Parachutes.load_from_dict(d, "policies")
		if not t.milestones.is_empty():
			return "bad milestones kept: %s" % str(bad)
		if t.validate().is_empty():
			return "bad milestones not reported: %s" % str(bad)
	var t2 := Parachutes.load_from_dict({"policies": [], "takeover_pick": "yes"}, "policies")
	if t2.takeover_pick or not _has_error(t2.validate(), "takeover_pick"):
		return "non-bool takeover_pick accepted"
	var t3 := Parachutes.load_from_dict({"policies": [], "milestones": [20.0, 50.0]}, "policies")
	if t3.milestones != [20, 50]:
		return "integral floats from JSON should load: %s" % str(t3.milestones)
	return "ok"

func test_missing_policy_file_reports_instead_of_crashing() -> String:
	var t := Parachutes.load_policies("res://data/does_not_exist.json")
	return "ok" if t.perks.is_empty() and _has_error(t.validate(), "file not found") else "not reported"

func test_modifiers_for_ignores_hostile_ids() -> String:
	var t := _pol()
	var m := t.modifiers_for(["supply_chain", "supply_chain", "ghost", 5, null, ["x"], {}])
	if m != {"fuel_discount_bps": _m(1500)}:
		return "got %s" % str(m)
	return "ok"

# --- the fold ---

func test_modifiers_for_matches_the_profile_fold_and_ignores_order() -> String:
	var t := _perks()
	var p := _owned(["fuel_hedge", "black_market_corridors", "corrupt_regulator", "seed_capital"])
	if t.modifiers(p) != t.modifiers_for(p.unlocks):
		return "wrapper differs from modifiers_for"
	var a := t.modifiers_for(["fuel_hedge", "black_market_corridors", "corrupt_regulator"])
	var b := t.modifiers_for(["corrupt_regulator", "black_market_corridors", "fuel_hedge"])
	return "ok" if a == b else "order mattered"

func test_combine_arithmetic() -> String:
	var a := {"x": _m(10, 8000), "only_a": _m(5, 9000)}
	var b := {"x": _m(-4, 7000), "only_b": _m(-3, 12500)}
	var c := Parachutes.combine(a, b)
	if c["x"] != _m(6, 5600):
		return "x: %s" % str(c["x"])
	if c["only_a"] != _m(5, 9000) or c["only_b"] != _m(-3, 12500):
		return "one-sided stats must pass through: %s" % str(c)
	if a["x"] != _m(10, 8000) or b["x"] != _m(-4, 7000) or a.has("only_b"):
		return "combine mutated an input"
	# truncating like the fold: 3333 * 3333 / 10000 = 1110 (not 1110.8896 rounded up)
	if Parachutes.combine({"x": _m(0, 3333)}, {"x": _m(0, 3333)})["x"]["mul_bps"] != 1110:
		return "multiplier must truncate"
	return "ok"

func test_combine_identities_and_hostile_entries() -> String:
	var a := {"x": _m(10, 8000)}
	if Parachutes.combine(a, {}) != a or Parachutes.combine({}, a) != a:
		return "empty is not the identity"
	if Parachutes.combine({}, {}) != {}:
		return "empty + empty"
	var c := Parachutes.combine({"x": "junk", "y": _m(1)}, {"y": {"add": 2}})
	if c != {"y": _m(3)}:
		return "hostile entry: %s" % str(c)
	return "ok"

func test_combine_is_the_fold_of_the_union() -> String:
	# Folding perks and policies together equals folding apart then combining, for the mul
	# multiples of 100 bps the placeholders use (section 5.3).
	var pk := _perks()
	var po := _pol()
	var apart := Parachutes.combine(pk.modifiers_for(["fuel_hedge", "black_market_corridors"]), po.modifiers_for(["supply_chain", "risk_transfer"]))
	if apart["piracy_odds_bps"]["mul_bps"] != 5600 or apart["fuel_discount_bps"]["add"] != 2500:
		return "got %s" % str(apart)
	return "ok"

# --- section 5.3 stacking table, every row ---

func test_stacking_examples_table() -> String:
	var pk := _perks()
	var po := _pol()
	var rows := [
		["fuel_discount_bps", 0, ["fuel_hedge"], ["supply_chain"], 2500],
		["piracy_odds_bps", 10000, ["black_market_corridors", "fuel_hedge"], ["risk_transfer"], 5600],
		["hazard_odds_bps", 10000, [], ["corridor_access"], 6000],
		["interest_bps", 100, ["corrupt_regulator"], ["covenant_relief"], 20],
		["takeover_threshold_shares", 501, ["hostile_buyout_line"], ["synergy_review", "rollup_mandate"], 401],
		["liquidation_haircut_bps", 5000, ["asset_protection", "seed_capital"], ["wind_down"], 7500],
		["bankruptcy_grace_ticks", 0, ["deferred_audit", "corrupt_regulator"], ["training_module"], 3600],
		["assumed_debt_bps", 5000, [], ["lbo_framework"], 3000],
		["severance_bps", 10000, [], ["exit_package"], 12500],
	]
	for r in rows:
		var mods := Parachutes.combine(pk.modifiers_for(r[2]), po.modifiers_for(r[3]))
		var got := Parachutes.apply_stat(mods, r[0], r[1])
		if got != r[4]:
			return "%s: %d != %d" % [r[0], got, r[4]]
	# burn_rate is a multiplier only: x8500 then x9000 is x7650 (6.12 CR/s on a base of 8).
	var burn := Parachutes.combine(pk.modifiers_for(["corporate_shielding"]), po.modifiers_for(["cost_containment"]))
	if burn["burn_rate"]["mul_bps"] != 7650:
		return "burn %s" % str(burn["burn_rate"])
	return "ok"

# --- RunController seam: the three re-derive sites plus the guard ---

func test_init_site_perk_base_equals_effective_without_policies() -> String:
	var p := _owned(["fuel_hedge", "seed_capital"])
	var rc := RunController.new(p, 1, _clock())
	if rc.modifiers.is_empty() or rc.modifiers != rc.perk_modifiers:
		return "profile-derived: %s vs %s" % [str(rc.modifiers), str(rc.perk_modifiers)]
	var explicit := {"fuel_discount_bps": _m(7)}
	var rc2 := RunController.new(p, 1, _clock(), explicit)
	if rc2.perk_modifiers != explicit or rc2.modifiers != explicit:
		return "explicit: %s" % str(rc2.modifiers)
	var rc3 := RunController.new(null, 1, _clock())
	if not rc3.modifiers.is_empty() or not rc3.perk_modifiers.is_empty():
		return "no-perk run grew modifiers"
	return "ok"

func test_apply_modifiers_stacks_held_policies_over_the_base() -> String:
	var rc := RunController.new(_owned(["fuel_hedge"]), 1, _clock())
	rc.policy_picks = ["supply_chain"]
	rc.apply_modifiers(rc.perk_modifiers)
	if rc.perk_modifiers["fuel_discount_bps"]["add"] != 1000:
		return "base polluted: %s" % str(rc.perk_modifiers)
	if rc.modifiers["fuel_discount_bps"]["add"] != 2500 or rc.fuel_discount_bps() != 2500:
		return "effective %s" % str(rc.modifiers)
	# Re-applying is idempotent: it never stacks twice.
	rc.apply_modifiers(rc.perk_modifiers)
	rc.apply_modifiers(rc.perk_modifiers)
	return "ok" if rc.fuel_discount_bps() == 2500 else "stacked on re-apply: %d" % rc.fuel_discount_bps()

func test_filing_site_settles_with_policies_then_clears_them() -> String:
	var p := _owned(["seed_capital", "fuel_hedge"])
	var rc := RunController.new(p, 1, _clock(1000000))
	rc.policy_picks = ["training_module", "prepack_reorg", "supply_chain"]
	rc._refresh_modifiers()
	if rc.bankruptcy_grace_ticks() != 1800 or rc.fuel_discount_bps() != 2500:
		return "policies not in force before the filing"
	rc.cr = 0
	if rc.file_bankruptcy().is_empty():
		return "filing rejected"
	# The new corp's stake was settled with Pre-Packaged Reorganization in force (+3000),
	# and the seed_capital bonus; then the policies were rescinded.
	if rc.cr != Chapter11.FRESH_START_CR + 3000 + 2000:
		return "stake %d" % rc.cr
	if not rc.policy_picks.is_empty():
		return "picks survived the filing: %s" % str(rc.policy_picks)
	if rc.modifiers != rc.perk_modifiers or rc.fuel_discount_bps() != 1000 or rc.bankruptcy_grace_ticks() != 0:
		return "modifiers still carry policies: %s" % str(rc.modifiers)
	if rc.perk_modifiers != Parachutes.load().modifiers(rc.profile):
		return "perk base not re-derived from the profile"
	return "ok"

func test_filing_site_clears_policies_for_explicit_modifier_runs_too() -> String:
	var explicit := {"fuel_discount_bps": _m(500)}
	var rc := RunController.new(null, 1, _clock(1000000), explicit)
	rc.policy_picks = ["supply_chain"]
	rc._refresh_modifiers()
	if rc.fuel_discount_bps() != 2000:
		return "stack %d" % rc.fuel_discount_bps()
	rc.cr = 0
	if rc.file_bankruptcy().is_empty():
		return "filing rejected"
	if rc.perk_modifiers != explicit or rc.modifiers != explicit or not rc.policy_picks.is_empty():
		return "explicit base lost or policy kept: %s" % str(rc.modifiers)
	return "ok"

func test_filing_site_without_policies_is_unchanged() -> String:
	var p := _owned(["seed_capital", "asset_protection"])
	var rc := RunController.new(p, 1, _clock(1000000))
	var before := rc.modifiers.duplicate(true)
	rc.cr = 0
	if rc.file_bankruptcy().is_empty():
		return "filing rejected"
	if rc.modifiers != before or rc.perk_modifiers != before:
		return "modifiers moved"
	if rc.cr != Chapter11.FRESH_START_CR + 2000:
		return "stake %d" % rc.cr
	return "ok"

func test_from_dict_site_rederives_base_and_effective() -> String:
	var p := _owned(["fuel_hedge", "corrupt_regulator"])
	var rc := RunController.new(p, 1, _clock())
	rc.policy_picks = ["supply_chain"]
	rc._refresh_modifiers()
	var d := rc.to_dict()
	# The saved key is the permanent base, so a load can never double count a policy.
	if d["modifiers"] != rc.perk_modifiers or d["modifiers"]["fuel_discount_bps"]["add"] != 1000:
		return "saved modifiers are not the base: %s" % str(d["modifiers"])
	if d.has("policy_picks") or d.has("perk_modifiers") or d.has("policies"):
		return "to_dict grew a key: %s" % str(d.keys())
	var back := RunController.from_dict(d)
	var want := Parachutes.load().modifiers(back.profile)
	if back.perk_modifiers != want or back.modifiers != want:
		return "base %s effective %s" % [str(back.perk_modifiers), str(back.modifiers)]
	# A hostile save cannot smuggle policy-sized numbers in through "modifiers": a profile-
	# backed run re-derives them, an explicit run bounds them to known stats.
	d["modifiers"] = {"fuel_discount_bps": _m(9999)}
	if RunController.from_dict(d).fuel_discount_bps() != 1000:
		return "forged modifiers survived a load"
	var ex := RunController.new(null, 1, _clock(), {"fuel_discount_bps": _m(500)})
	var exd := ex.to_dict()
	exd["modifiers"] = {"fuel_discount_bps": _m(500), "bogus": _m(1)}
	var exb := RunController.from_dict(exd)
	if exb.perk_modifiers != {"fuel_discount_bps": _m(500)} or exb.modifiers != exb.perk_modifiers:
		return "explicit base %s" % str(exb.perk_modifiers)
	return "ok"

func test_from_dict_site_goes_through_the_seam_when_picks_are_held() -> String:
	# Picks are not saved until PolicyState lands, so a loaded controller holds none; the seam
	# is exercised by handing the loaded controller picks and refreshing.
	var back := RunController.from_dict(RunController.new(_owned(["fuel_hedge"]), 1, _clock()).to_dict())
	back.policy_picks = ["supply_chain"]
	back._refresh_modifiers()
	return "ok" if back.fuel_discount_bps() == 2500 and back.perk_modifiers["fuel_discount_bps"]["add"] == 1000 else "got %s" % str(back.modifiers)

func test_policies_do_not_unlock_tender_offers() -> String:
	var rc := RunController.new(null, 1, _clock())
	rc.policy_picks = ["synergy_review"]
	rc._refresh_modifiers()
	if not rc.modifiers.has("takeover_threshold_shares"):
		return "policy did not reach the effective modifiers"
	if Takeover.tender_unlocked(rc):
		return "a policy unlocked tender offers"
	var perk_rc := RunController.new(_owned(["hostile_buyout_line"]), 1, _clock())
	if not Takeover.tender_unlocked(perk_rc):
		return "the perk no longer unlocks tender offers"
	perk_rc.policy_picks = ["synergy_review"]
	perk_rc._refresh_modifiers()
	return "ok" if Takeover.tender_unlocked(perk_rc) else "perk lost its unlock when a policy was added"

func test_threshold_reads_the_effective_modifiers() -> String:
	var rc := RunController.new(_owned(["hostile_buyout_line"]), 1, _clock())
	var w := Barons.new()
	var base := Takeover.threshold_for(w, Takeover.PLAYER, rc)
	rc.policy_picks = ["synergy_review", "rollup_mandate"]
	rc._refresh_modifiers()
	return "ok" if Takeover.threshold_for(w, Takeover.PLAYER, rc) == base - 50 else "threshold %d from %d" % [Takeover.threshold_for(w, Takeover.PLAYER, rc), base]
