extends RefCounted
## #160 row 3: PolicyState (grants, offers, picks), the controller hooks (pause, signals,
## filing, takeover), the `policies` save key and its sanitising restore, and the Replay opt-in
## (docs/design/corporate-policies.md sections 4, 6, 7, 8).

const ARES: String = "ares_heavy"
const TPR: int = 4


func _state() -> PolicyState:
	return PolicyState.new()


func _rc(attach: bool = true) -> RunController:
	var rc := RunController.new(null, 1, DoomsdayClock.new(36000, 0, 0, 100), {}, TPR)
	if attach:
		rc.attach_policies()
	return rc


## Runs the clock until it halts or `rounds` rounds pass.
func _run_to_round(rc: RunController, rounds: int) -> void:
	var n := 0
	while rc.get_current_round() < rounds and not rc.sim_clock.paused and n < 100000:
		rc.advance(rc.sim_clock.tick_delta + 0.0001)
		n += 1


func _hash(rc: RunController) -> String:
	return RunSave.hash_dict(RunSave.capture(rc, StationMarket.new(), Bags.new("t", null, 1)))


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


# --- grants ---

func test_milestones_grant_one_pick_each_at_20_50_and_80() -> String:
	var s := _state()
	var got: Array = []
	for r in range(0, 121):
		if s.on_round(r) > 0:
			got.append(r)
	if got != [20, 50, 80] or s.earned != 3 or s.pending() != 3 or s.milestones_done != 3:
		return "granted at %s, earned %d" % [str(got), s.earned]
	if s.on_round(120) != 0:
		return "a milestone fired twice"
	return "ok"


func test_a_late_round_catches_up_every_milestone_passed() -> String:
	var s := _state()
	return "ok" if s.on_round(85) == 3 and s.earned == 3 else "earned %d" % s.earned


func test_the_takeover_pick_is_granted_once() -> String:
	var s := _state()
	if not s.on_takeover() or s.on_takeover() or s.earned != 1:
		return "takeover pick earned %d" % s.earned
	return "ok"


func test_a_run_has_exactly_four_picks() -> String:
	var s := _state()
	s.on_round(120)
	s.on_takeover()
	s.on_takeover()
	return "ok" if s.earned == 4 else "earned %d" % s.earned


# --- offers and picks ---

func test_offers_start_as_the_four_roots_then_open_the_fork() -> String:
	var s := _state()
	if s.offers() != ["supply_chain", "cost_containment", "training_module", "synergy_review"]:
		return "roots %s" % str(s.offers())
	s.earned = 2
	if not s.pick("supply_chain"):
		return "root refused"
	var o := s.offers()
	if o.has("supply_chain") or not o.has("risk_transfer") or not o.has("corridor_access") or o.size() != 5:
		return "after a root %s" % str(o)
	return "ok"


func test_a_capstone_excludes_its_sibling_and_cannot_be_forced() -> String:
	var s := _state()
	s.earned = 3
	s.pick("supply_chain")
	if not s.pick("risk_transfer"):
		return "capstone refused"
	if s.offers().has("corridor_access") or s.pick("corridor_access"):
		return "the excluded sibling was offered or taken"
	if s.pick("risk_transfer") or s.pick("not_a_policy"):
		return "a repeat or unknown id was taken"
	return "ok" if s.picks == ["supply_chain", "risk_transfer"] else "picks %s" % str(s.picks)


func test_a_capstone_needs_its_root() -> String:
	var s := _state()
	s.earned = 1
	return "ok" if not s.pick("risk_transfer") and s.picks.is_empty() else "took a capstone with no root"


func test_a_pick_needs_a_pending_grant() -> String:
	var s := _state()
	if s.pick("supply_chain"):
		return "picked with nothing granted"
	s.earned = 1
	s.pick("supply_chain")
	return "ok" if not s.pick("cost_containment") and s.picks.size() == 1 else "picked past the grants"


# --- sanitising restore ---

func test_from_dict_drops_both_capstones_of_a_fork_and_keeps_the_first() -> String:
	var s := PolicyState.from_dict({"picks": ["supply_chain", "risk_transfer", "corridor_access"], "earned": 3, "milestones_done": 2, "takeover_granted": true})
	return "ok" if s.picks == ["supply_chain", "risk_transfer"] else "kept %s" % str(s.picks)


func test_from_dict_drops_unknown_repeated_and_rootless_picks() -> String:
	var s := PolicyState.from_dict({"picks": ["bogus", 5, null, "supply_chain", "supply_chain", "covenant_relief"], "earned": 4})
	return "ok" if s.picks == ["supply_chain"] else "kept %s" % str(s.picks)


func test_from_dict_ignores_the_saved_order_of_a_legal_pair() -> String:
	var s := PolicyState.from_dict({"picks": ["risk_transfer", "supply_chain"], "earned": 2})
	return "ok" if s.picks.size() == 2 and s.picks.has("risk_transfer") else "kept %s" % str(s.picks)


func test_from_dict_clamps_picks_to_earned_and_earned_to_the_data() -> String:
	var s := PolicyState.from_dict({"picks": ["supply_chain", "cost_containment", "training_module"], "earned": 1})
	if s.picks != ["supply_chain"]:
		return "picks not clamped to earned: %s" % str(s.picks)
	var big := PolicyState.from_dict({"picks": [], "earned": 99, "milestones_done": 99})
	if big.earned != 4 or big.milestones_done != 3:
		return "earned %d, milestones_done %d" % [big.earned, big.milestones_done]
	var neg := PolicyState.from_dict({"earned": -5, "milestones_done": -1})
	return "ok" if neg.earned == 0 and neg.milestones_done == 0 else "negative kept"


func test_from_dict_survives_junk() -> String:
	var s := PolicyState.from_dict({"picks": "nope", "earned": "x", "milestones_done": [], "takeover_granted": "yes"})
	return "ok" if s.picks.is_empty() and s.earned == 0 and s.milestones_done == 0 else "junk kept"


func test_round_trip_through_json_is_exact() -> String:
	var s := _state()
	s.on_round(50)
	s.on_takeover()
	s.pick("synergy_review")
	var back := PolicyState.from_dict(_json(s.to_dict()))
	return "ok" if back.to_dict() == s.to_dict() else "%s vs %s" % [str(back.to_dict()), str(s.to_dict())]


# --- controller: the pause, the signals, filing, takeover ---

func test_a_run_without_policies_never_pauses_for_a_pick() -> String:
	var rc := _rc(false)
	_run_to_round(rc, 25)
	return "ok" if not rc.sim_clock.paused and rc.get_current_round() == 25 and rc.policies == null else "paused or attached"


func test_round_20_pauses_through_the_interrupt_path_and_signals() -> String:
	var rc := _rc()
	var seen: Array = []
	rc.policy_pending.connect(func(n): seen.append(n))
	_run_to_round(rc, 30)
	if rc.get_current_round() != 20 or not rc.sim_clock.paused or rc.sim_clock.auto_paused_reason != "interrupt":
		return "round %d paused=%s reason=%s" % [rc.get_current_round(), rc.sim_clock.paused, rc.sim_clock.auto_paused_reason]
	if rc.sim_clock.total_ticks != 20 * TPR:
		return "stopped on tick %d, not the grant's sub-tick" % rc.sim_clock.total_ticks
	if seen != [1] or rc.policies.pending() != 1:
		return "signal %s pending %d" % [str(seen), rc.policies.pending()]
	# Resuming without choosing trips again at once: picks are mandatory.
	rc.sim_clock.resume()
	rc.advance(rc.sim_clock.tick_delta + 0.0001)
	return "ok" if rc.sim_clock.paused and rc.sim_clock.total_ticks == 20 * TPR + 1 else "the clock ran on past an unmade pick"


func test_adopting_stacks_the_modifiers_signals_and_lets_the_clock_run() -> String:
	var rc := _rc()
	var adopted: Array = []
	rc.policy_adopted.connect(func(id): adopted.append(id))
	_run_to_round(rc, 30)
	if rc.adopt_policy("risk_transfer"):
		return "adopted a capstone with no root"
	if not rc.adopt_policy("supply_chain") or adopted != ["supply_chain"]:
		return "adopt failed: %s" % str(adopted)
	if rc.fuel_discount_bps() != 1500 or rc.perk_modifiers.has("fuel_discount_bps"):
		return "modifiers: %s / base %s" % [str(rc.modifiers), str(rc.perk_modifiers)]
	rc.sim_clock.resume()
	_run_to_round(rc, 30)
	return "ok" if rc.get_current_round() == 30 else "stuck at round %d" % rc.get_current_round()


func test_every_milestone_pauses_in_turn() -> String:
	var rc := _rc()
	var at: Array = []
	for want in [20, 50, 80]:
		_run_to_round(rc, 120)
		at.append(rc.get_current_round())
		var o := rc.policies.offers()
		if o.is_empty() or not rc.adopt_policy(o[0]):
			return "no pick at %d" % want
		rc.sim_clock.resume()
	return "ok" if at == [20, 50, 80] and rc.policies.picks.size() == 3 else "paused at %s" % str(at)


func test_the_first_takeover_grants_one_pick_and_the_second_none() -> String:
	var rc := _rc()
	var w := Barons.for_new_run()
	rc.world = w
	var seen: Array = []
	rc.policy_pending.connect(func(n): seen.append(n))
	Takeover.take(w, ARES, "player", rc)
	if seen != [1] or rc.policies.earned != 1 or not rc.policies.takeover_granted:
		return "first takeover: signal %s earned %d" % [str(seen), rc.policies.earned]
	Takeover.take(w, ARES, "player", rc)
	if rc.policies.earned != 1:
		return "a re-take granted again"
	var rival := _rc()
	rival.world = Barons.for_new_run()
	Takeover.take(rival.world, ARES, "rival_a", rival)
	return "ok" if rival.policies.earned == 0 else "a rival's takeover granted the player a pick"


func test_a_takeover_with_no_policies_attached_is_untouched() -> String:
	var rc := _rc(false)
	rc.world = Barons.for_new_run()
	Takeover.take(rc.world, ARES, "player", rc)
	return "ok" if rc.policies == null else "attached by a takeover"


func test_a_filing_rescinds_picks_and_pending_keeps_milestones_and_regrants_takeover() -> String:
	var rc := _rc()
	rc.policies.on_round(85)
	rc.policies.on_takeover()
	rc.adopt_policy("supply_chain")
	rc.doomsday.principal_debt = 1000000
	rc.cr = 0
	if rc.file_bankruptcy().is_empty():
		return "filing rejected"
	var p := rc.policies
	if not p.picks.is_empty() or p.earned != 0 or p.pending() != 0 or p.takeover_granted:
		return "not rescinded: %s" % str(p.to_dict())
	if p.milestones_done != 3:
		return "milestones_done reset to %d" % p.milestones_done
	if rc.modifiers != rc.perk_modifiers:
		return "modifiers still carry the policy"
	if p.on_round(85) != 0:
		return "a passed milestone fired again for the new corp"
	if not p.on_takeover():
		return "the new corp cannot earn its own takeover pick"
	return "ok"


func test_a_filing_with_a_pending_pick_loses_it() -> String:
	var rc := _rc()
	_run_to_round(rc, 30)
	rc.doomsday.principal_debt = 1000000
	rc.cr = 0
	rc.file_bankruptcy()
	return "ok" if rc.policies.pending() == 0 else "the pending pick survived the filing"


# --- saves ---

func test_no_policies_key_until_the_first_grant_and_the_hash_is_unchanged() -> String:
	var bare := _rc(false)
	var attached := _rc()
	_run_to_round(bare, 19)
	_run_to_round(attached, 19)
	if RunSave.capture(attached, StationMarket.new(), Bags.new("t", null, 1)).has("policies"):
		return "a policies key before the first grant"
	if _hash(bare) != _hash(attached):
		return "attaching policies moved the hash before the first grant"
	_run_to_round(attached, 30)
	if not RunSave.capture(attached, StationMarket.new(), Bags.new("t", null, 1)).has("policies"):
		return "no policies key after the first grant"
	return "ok" if _hash(bare) != _hash(attached) else "a grant did not move the hash"


func test_a_pick_adds_exactly_the_policies_key_and_leaves_modifiers_alone() -> String:
	var rc := _rc()
	rc.policies.on_round(20)
	var before := RunSave.capture(rc, StationMarket.new(), Bags.new("t", null, 1))
	rc.adopt_policy("supply_chain")
	var after := RunSave.capture(rc, StationMarket.new(), Bags.new("t", null, 1))
	# The saved modifiers stay the perk base. (apply_modifiers also records the doomsday base
	# the first time any modifier is applied, so that one key may appear; nothing else moves.)
	var b: Dictionary = (before["controller"] as Dictionary).duplicate()
	var a: Dictionary = (after["controller"] as Dictionary).duplicate()
	b.erase("doomsday_base")
	a.erase("doomsday_base")
	if b != a:
		return "the controller block moved (modifiers must stay the perk base)"
	if (after["policies"] as Dictionary)["picks"] != ["supply_chain"]:
		return "picks not saved: %s" % str(after["policies"])
	return "ok"


func test_save_round_trip_keeps_policies_and_their_modifiers() -> String:
	var p := MetaProfile.new()
	p.add_unlock("fuel_hedge")
	var rc := RunController.new(p, 1, DoomsdayClock.new(36000, 0, 0, 100), {}, TPR)
	rc.attach_policies()
	rc.policies.on_round(85)
	rc.policies.on_takeover()
	rc.adopt_policy("supply_chain")
	var cap := RunSave.capture(rc, StationMarket.new(), Bags.new("t", null, 1))
	var r := RunSave.restore(_json(cap))
	if not bool(r["ok"]):
		return "restore failed: %s" % r["error"]
	var back: RunController = r["controller"]
	if back.policies == null or back.policies.picks != ["supply_chain"] or back.policies.pending() != 3:
		return "state lost: %s" % ("null" if back.policies == null else str(back.policies.to_dict()))
	if back.fuel_discount_bps() != 2500 or back.perk_modifiers["fuel_discount_bps"]["add"] != 1000:
		return "modifiers did not stack on load: %s" % str(back.modifiers)
	if _hash(back) != _hash(rc):
		return "the round trip moved the hash"
	return "ok"


func test_a_pending_pick_survives_a_save_and_pauses_again() -> String:
	var rc := _rc()
	_run_to_round(rc, 30)
	var r := RunSave.restore(_json(RunSave.capture(rc, StationMarket.new(), Bags.new("t", null, 1))))
	var back: RunController = r["controller"]
	if back.policies.pending() != 1:
		return "pending lost"
	back.sim_clock.resume()
	back.advance(back.sim_clock.tick_delta + 0.0001)
	return "ok" if back.sim_clock.paused else "the loaded run ran past an unmade pick"


func test_a_filed_corp_saves_its_milestones_so_a_reload_cannot_regrant() -> String:
	var rc := _rc()
	rc.policies.on_round(85)
	rc.doomsday.principal_debt = 1000000
	rc.cr = 0
	rc.file_bankruptcy()
	var cap := RunSave.capture(rc, StationMarket.new(), Bags.new("t", null, 1))
	if not cap.has("policies") or int(cap["policies"]["milestones_done"]) != 3:
		return "milestones not saved after a filing: %s" % str(cap.get("policies"))
	var back: RunController = RunSave.restore(_json(cap))["controller"]
	return "ok" if back.policies.on_round(85) == 0 else "milestones re-fired after reload"


func test_a_hand_edited_save_with_both_capstones_loads_with_one() -> String:
	var rc := _rc()
	rc.policies.on_round(85)
	var cap := RunSave.capture(rc, StationMarket.new(), Bags.new("t", null, 1))
	cap["policies"]["picks"] = ["supply_chain", "risk_transfer", "corridor_access"]
	var back: RunController = RunSave.restore(_json(cap))["controller"]
	if back.policies.picks != ["supply_chain", "risk_transfer"]:
		return "kept %s" % str(back.policies.picks)
	return "ok" if back.fuel_discount_bps() == 1500 and back.modifiers.has("piracy_odds_bps") and not back.modifiers.has("hazard_odds_bps") else "modifiers %s" % str(back.modifiers)


func test_a_save_with_a_junk_policies_block_still_loads() -> String:
	var rc := _rc()
	rc.policies.on_round(20)
	var cap := RunSave.capture(rc, StationMarket.new(), Bags.new("t", null, 1))
	cap["policies"] = {"picks": 5, "earned": "many"}
	var r := RunSave.restore(_json(cap))
	return "ok" if bool(r["ok"]) and (r["controller"] as RunController).policies.picks.is_empty() else "did not load"


# --- replay opt-in ---

func test_replay_policies_are_opt_in_and_a_default_recording_has_no_key() -> String:
	var s := Replay.start_recording(5, {}, Replay.DEFAULT_FRAME_DELTA, 30, true)
	if s.controller.policies != null or s.to_recording().has("policies"):
		return "policies attached by default"
	var on := Replay.start_recording(5, {}, Replay.DEFAULT_FRAME_DELTA, 30, true, true)
	if on.controller.policies == null or not bool(on.to_recording().get("policies", false)):
		return "opt-in did not attach or record"
	return "ok"


func test_the_shipped_world_goldens_carry_no_policies() -> String:
	var text := FileAccess.get_file_as_string("res://tests/fixtures/world/world_goldens.json")
	var recs: Dictionary = (JSON.parse_string(text) as Dictionary)["recordings"]
	for sd in recs:
		if (recs[sd] as Dictionary).has("policies"):
			return "seed %s world golden attaches policies" % sd
		for e in recs[sd]["inputs"]:
			if str(e["action"]).begins_with(Replay.POLICY_PREFIX):
				return "seed %s world golden holds a policy pick" % sd
	return "ok"


func test_a_world_golden_run_crosses_round_20_with_no_pause_when_not_attached() -> String:
	# The doc's safeguard (section 8): the 40-round world bot never attaches policies, so round
	# 20 passes without a stop and a controller there has none.
	var wg = load("res://tools/world_golden.gd")
	var s: Replay.Session = wg.play(84, Callable(), 25)
	return "ok" if s.controller.policies == null and s.controller.get_current_round() >= 25 else "stopped at round %d" % s.controller.get_current_round()
