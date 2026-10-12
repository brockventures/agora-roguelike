class_name TestSovereignBoss
extends RefCounted
## Tests for Secret Final Boss: Sol Government Nationalization & Sovereign Buyout (#33).

const SEED: int = 42

## Helper to build a controller with fake monopoly
func _make_monopoly_rc(cr: int = 100000, debt: int = 0) -> RunController:
	var clock := DoomsdayClock.new(360000, 0, 0, 0)
	var rc := RunController.new(null, SEED, clock, {}, 10)
	rc.attach_sovereign()
	rc.world = Barons.for_new_run()
	for id in rc.world.ids():
		Takeover.take(rc.world, id, Takeover.PLAYER, rc)
	rc.cr = cr
	rc.doomsday.clear_debt()
	if debt > 0:
		rc.doomsday.add_principal(debt)
	return rc


func test_sovereign_decree_trigger_and_state() -> String:
	var rc := _make_monopoly_rc()
	var decree_seen: Array = []
	rc.sovereign_decree_issued.connect(func(d): decree_seen.append(d))

	if not rc.has_monopoly():
		return "expected has_monopoly() to be true"

	var ok: bool = rc.open_rescue()
	if not ok:
		return "expected open_rescue() to succeed"
	if rc.sovereign == null:
		return "expected sovereign boss instance to be initialized"
	if not rc.sovereign.is_active():
		return "expected sovereign boss to be active"
	if decree_seen.size() != 1:
		return "expected sovereign_decree_issued signal to fire once"
	if rc.sovereign.ticks_remaining != rc.sovereign.total_ticks:
		return "expected ticks_remaining to match total_ticks"
	if rc.sovereign.rounds_remaining(rc.ticks_per_round) <= 0:
		return "expected rounds_remaining > 0"

	return "ok"


func test_seizure_countdown_and_nationalization() -> String:
	var rc := _make_monopoly_rc()
	rc.open_rescue()

	var nationalized_seen: Array = []
	rc.sovereign_nationalized.connect(func(): nationalized_seen.append(true))

	# Force ticks remaining to 1 and step
	rc.sovereign.ticks_remaining = 1
	var expired: bool = rc.sovereign.step_tick()
	if not expired or not rc.sovereign.is_expired():
		return "expected step_tick to expire at 0"

	rc._on_sovereign_nationalized()

	if nationalized_seen.size() != 1:
		return "expected sovereign_nationalized signal"
	if not rc.is_run_over():
		return "expected is_run_over() to be true"
	if not rc.is_nationalized():
		return "expected is_nationalized() to be true"
	if rc.end_reason != "nationalized":
		return "expected end_reason 'nationalized', got '%s'" % rc.end_reason
	if not rc.sim_clock.paused:
		return "expected clock to pause upon nationalization"

	return "ok"


func test_counter_strategy_bribe() -> String:
	var rc := _make_monopoly_rc(20000)
	rc.open_rescue()

	# Insufficient CR for base bribe (45,000)
	if rc.sovereign.can_bribe(rc.cr, false):
		return "should not be able to bribe with 20,000 CR"
	if rc.resolve_sovereign_bribe():
		return "resolve_sovereign_bribe should fail when can_bribe is false"

	# Grant corrupt regulator perk for discount (33,750 CR)
	rc.profile.add_patent("corrupt_regulator")
	if not rc.has_regulatory_perk():
		return "expected has_regulatory_perk() to be true"
	var discounted: int = rc.sovereign.get_bribe_cost(true)
	if discounted != 33750:
		return "expected discounted bribe 33750, got %d" % discounted

	# Fund enough for discounted bribe
	rc.cr = 35000
	var resolved_seen: Array = []
	rc.sovereign_resolved.connect(func(m, a): resolved_seen.append([m, a]))

	var ok: bool = rc.resolve_sovereign_bribe()
	if not ok:
		return "expected resolve_sovereign_bribe to succeed"
	if rc.cr != 1250:
		return "expected remaining cr 1250, got %d" % rc.cr
	if rc.sovereign.status != SovereignTakeover.STATUS_BRIBED:
		return "expected status 'bribed', got '%s'" % rc.sovereign.status
	if resolved_seen.size() != 1 or resolved_seen[0][0] != "bribed":
		return "expected sovereign_resolved signal with 'bribed'"
	if rc.sovereign_severance_award != 300:
		return "expected 300 severance award, got %d" % rc.sovereign_severance_award

	return "ok"


func test_counter_strategy_debt_choke() -> String:
	var rc := _make_monopoly_rc(50000, 10000)
	rc.open_rescue()

	# 10,000 debt is below 35,000 requirement
	if rc.sovereign.can_debt_choke(rc.doomsday.principal_debt, false):
		return "should not be able to debt choke with 10k debt"

	# With debt leverage perk (threshold 20,000)
	rc.profile.add_patent("hostile_buyout_line")
	if not rc.has_debt_leverage():
		return "expected has_debt_leverage() to be true"
	if rc.sovereign.can_debt_choke(rc.doomsday.principal_debt, true):
		return "10k debt should still be below 20k leverage threshold"

	# Borrow up to 25,000 debt
	rc.doomsday.principal_debt = 25000
	if not rc.sovereign.can_debt_choke(rc.doomsday.principal_debt, true):
		return "25k debt should satisfy 20k leverage threshold"

	var resolved_seen: Array = []
	rc.sovereign_resolved.connect(func(m, a): resolved_seen.append([m, a]))

	var ok: bool = rc.resolve_sovereign_debt_choke()
	if not ok:
		return "expected resolve_sovereign_debt_choke to succeed"
	if rc.sovereign.status != SovereignTakeover.STATUS_DEBT_CHOKED:
		return "expected status 'debt_choked', got '%s'" % rc.sovereign.status
	if resolved_seen.size() != 1 or resolved_seen[0][0] != "debt_choked":
		return "expected sovereign_resolved signal with 'debt_choked'"
	if rc.sovereign_severance_award != 500:
		return "expected 500 severance award, got %d" % rc.sovereign_severance_award

	return "ok"


func test_counter_strategy_privatize_and_victory() -> String:
	var rc := _make_monopoly_rc(80000)
	rc.open_rescue()

	# Without buyout perk: 75,000 base cost
	if not rc.sovereign.can_privatize(rc.cr, rc.has_monopoly(), false):
		return "80,000 CR should satisfy 75,000 base privatize cost"

	# With buyout perk: 33.33% discount -> 50,002 CR
	rc.profile.add_patent("hostile_buyout_line")
	var discounted: int = rc.sovereign.get_privatize_cost(true)
	if discounted > 51000:
		return "expected discounted privatize cost ~50,000 CR, got %d" % discounted

	var resolved_seen: Array = []
	rc.sovereign_resolved.connect(func(m, a): resolved_seen.append([m, a]))

	var ok: bool = rc.resolve_sovereign_privatize()
	if not ok:
		return "expected resolve_sovereign_privatize to succeed"
	if rc.sovereign.status != SovereignTakeover.STATUS_PRIVATIZED:
		return "expected status 'privatized', got '%s'" % rc.sovereign.status
	if resolved_seen.size() != 1 or resolved_seen[0][0] != "privatized":
		return "expected sovereign_resolved signal with 'privatized'"
	if rc.sovereign_severance_award != 800:
		return "expected 800 severance award, got %d" % rc.sovereign_severance_award

	# Sovereign Buyout victory finish
	var award: int = rc.finish_sovereign_buyout()
	if award <= 0:
		return "expected positive severance award from finish_sovereign_buyout"
	if not rc.is_sovereign_buyout():
		return "expected is_sovereign_buyout() to be true"
	if rc.end_reason != "sovereign_buyout":
		return "expected end_reason 'sovereign_buyout', got '%s'" % rc.end_reason

	return "ok"


func test_sovereign_save_load_roundtrip() -> String:
	var rc := _make_monopoly_rc(90000)
	rc.open_rescue()
	rc.sovereign.ticks_remaining = 5432
	rc.sovereign.status = SovereignTakeover.STATUS_ACTIVE
	rc.sovereign_severance_award = 150

	var d: Dictionary = rc.to_dict()
	var rc2 := RunController.from_dict(d)

	if rc2.sovereign == null:
		return "restored controller missing sovereign"
	if rc2.sovereign.ticks_remaining != 5432:
		return "ticks_remaining not restored: %d" % rc2.sovereign.ticks_remaining
	if rc2.sovereign.status != SovereignTakeover.STATUS_ACTIVE:
		return "status not restored: %s" % rc2.sovereign.status
	if rc2.sovereign_severance_award != 150:
		return "sovereign_severance_award not restored: %d" % rc2.sovereign_severance_award

	# Test RunSave capture & restore
	var mkt := StationMarket.new()
	var save_dict := RunSave.capture(rc, mkt, Bags.new())
	if not (save_dict.has("controller") and save_dict["controller"].has("sovereign")):
		return "RunSave.capture missing controller.sovereign"

	var res: Dictionary = RunSave.restore(save_dict)
	if not res.get("ok", false):
		return "RunSave.restore failed: %s" % res.get("error", "unknown")
	var rc3: RunController = res["controller"]
	if rc3.sovereign == null or rc3.sovereign.ticks_remaining != 5432:
		return "RunSave.restore failed to reconstruct sovereign"

	return "ok"


func test_m0_loop_sovereign_overlay_actions() -> String:
	var rc := _make_monopoly_rc(60000)
	var hud := OrbitalHUD.new(rc)
	var loop := M0Loop.new(hud)

	rc.open_rescue()
	loop.show_sovereign_decree()

	if loop.overlay_state != M0Loop.OVERLAY_SOVEREIGN_DECREE:
		return "expected loop overlay OVERLAY_SOVEREIGN_DECREE, got '%s'" % loop.overlay_state
	if not rc.sim_clock.paused:
		return "expected sim_clock to pause on decree"

	# Dismiss allows resuming clock
	var ok: bool = loop.dispatch_action(M0Loop.ACT_SOVEREIGN_DISMISS)
	if not ok:
		return "expected ACT_SOVEREIGN_DISMISS to succeed"
	if loop.overlay_state != M0Loop.OVERLAY_NONE:
		return "expected overlay OVERLAY_NONE after dismiss"
	if rc.sim_clock.paused:
		return "expected sim_clock to resume after dismiss"

	# Re-open overlay and test bribe action
	loop.show_sovereign_decree()
	var bribe_ok: bool = loop.dispatch_action(M0Loop.ACT_SOVEREIGN_BRIBE)
	if not bribe_ok:
		return "expected ACT_SOVEREIGN_BRIBE to succeed"
	if loop.overlay_state != M0Loop.OVERLAY_NONE:
		return "expected overlay cleared after bribe"
	if rc.sovereign.status != SovereignTakeover.STATUS_BRIBED:
		return "expected status 'bribed'"

	return "ok"
