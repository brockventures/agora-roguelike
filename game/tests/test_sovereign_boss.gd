class_name TestSovereignBoss
extends RefCounted
## Tests for Secret Final Boss: Sol Government Nationalization & Sovereign Buyout (#33).

const SEED: int = 42

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
	if rc.sovereign != null:
		return "expected sovereign to be null before open_rescue()"

	var signals_seen: Array = []
	rc.sovereign_decree_issued.connect(func(d): signals_seen.append(d))

	var opened: bool = rc.open_rescue()
	if not opened:
		return "expected open_rescue() to succeed"
	if rc.sovereign == null:
		return "expected sovereign to be attached on open_rescue()"
	if not rc.sovereign.is_active():
		return "expected sovereign status 'active', got '%s'" % rc.sovereign.status
	if signals_seen.size() != 1:
		return "expected sovereign_decree_issued signal emitted once"
	if rc.sovereign.rounds_remaining() != 15:
		return "expected 15 rounds remaining, got %d" % rc.sovereign.rounds_remaining()

	return "ok"


func test_seizure_countdown_and_nationalization() -> String:
	var rc := _make_monopoly_rc()
	rc.open_rescue()

	var nationalized_seen: Array = []
	rc.sovereign_nationalized.connect(func(): nationalized_seen.append(true))

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
	var rc := _make_monopoly_rc(50000)
	rc.open_rescue()

	if not rc.sovereign.can_bribe(rc.cr, false):
		return "50,000 CR should satisfy 45,000 base bribe cost"

	# With regulatory perk: 25% discount -> 33,750 CR
	rc.perk_modifiers["corrupt_regulator"] = true
	var discounted: int = rc.sovereign.get_bribe_cost(true)
	if discounted != 33750:
		return "expected discounted bribe cost 33,750, got %d" % discounted

	rc.cr = 30000
	if rc.sovereign.can_bribe(rc.cr, true):
		return "30,000 CR should be insufficient for 33,750 discounted cost"

	rc.cr = 50000
	var resolved_seen: Array = []
	rc.sovereign_resolved.connect(func(m, a): resolved_seen.append([m, a]))

	var ok: bool = rc.resolve_sovereign_bribe()
	if not ok:
		return "expected resolve_sovereign_bribe to succeed"
	if rc.cr != (50000 - 33750):
		return "expected cr to be deducted, got %d" % rc.cr
	if rc.sovereign.status != SovereignTakeover.STATUS_BRIBED:
		return "expected status 'bribed', got '%s'" % rc.sovereign.status
	if resolved_seen.size() != 1 or resolved_seen[0][0] != "bribed":
		return "expected sovereign_resolved signal with 'bribed'"
	if rc.sovereign_severance_award != 300:
		return "expected 300 severance award, got %d" % rc.sovereign_severance_award

	var ticks_before: int = rc.sovereign.ticks_remaining
	rc.sim_clock.step(100)
	if rc.sovereign.ticks_remaining != ticks_before:
		return "ticks should not step after resolution"

	return "ok"


func test_counter_strategy_debt_choke() -> String:
	var rc := _make_monopoly_rc(50000, 10000)
	rc.open_rescue()

	# 10,000 debt is below 35,000 requirement
	if rc.sovereign.can_debt_choke(rc.cr, rc.doomsday.principal_debt, false):
		return "should not be able to debt choke with 10k debt"

	# With debt leverage perk (threshold 20,000, discounted cost 18,750)
	rc.perk_modifiers["hostile_buyout_line"] = true
	if not rc.has_debt_leverage():
		return "expected has_debt_leverage() to be true"
	if rc.sovereign.can_debt_choke(rc.cr, rc.doomsday.principal_debt, true):
		return "10k debt should still be below 20k leverage threshold"

	# Insufficient CR check
	rc.cr = 10000
	rc.doomsday.principal_debt = 25000
	if rc.sovereign.can_debt_choke(rc.cr, rc.doomsday.principal_debt, true):
		return "should not be able to debt choke without required restructuring CR"

	# Borrow up to 25,000 debt and restore CR
	rc.cr = 50000
	rc.doomsday.principal_debt = 25000
	if not rc.sovereign.can_debt_choke(rc.cr, rc.doomsday.principal_debt, true):
		return "25k debt and 50k CR should satisfy leverage threshold and cost"

	var resolved_seen: Array = []
	rc.sovereign_resolved.connect(func(m, a): resolved_seen.append([m, a]))

	var cost: int = rc.sovereign.get_debt_choke_cost(true)
	var prev_cr: int = rc.cr
	var prev_debt: int = rc.doomsday.principal_debt
	var ok: bool = rc.resolve_sovereign_debt_choke()
	if not ok:
		return "expected resolve_sovereign_debt_choke to succeed"
	if rc.cr != prev_cr - cost:
		return "expected CR deducted by %d, got %d" % [cost, rc.cr]
	if rc.doomsday.principal_debt >= prev_debt:
		return "expected principal debt relieved, got %d" % rc.doomsday.principal_debt
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

	if not rc.sovereign.can_privatize(rc.cr, false):
		return "80,000 CR should satisfy 75,000 base privatize cost"

	# With buyout perk: 33.33% discount -> 50,002 CR
	rc.perk_modifiers["hostile_buyout_line"] = true
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

	var award: int = rc.finish_sovereign_buyout()
	if award <= 0:
		return "expected positive severance award from finish_sovereign_buyout"
	if not rc.is_sovereign_buyout():
		return "expected is_sovereign_buyout() to be true"
	if rc.end_reason != "sovereign_buyout":
		return "expected end_reason 'sovereign_buyout', got '%s'" % rc.end_reason

	return "ok"


func test_sovereign_save_load_roundtrip() -> String:
	var rc := _make_monopoly_rc(70000, 25000)
	rc.open_rescue()
	rc.sim_clock.step(900)

	var dict: Dictionary = rc.to_dict()
	if not dict.has("sovereign"):
		return "expected 'sovereign' key in rc.to_dict()"
	if not dict.has("sovereign_enabled"):
		return "expected 'sovereign_enabled' key in rc.to_dict()"

	var loaded := RunController.from_dict(dict)
	if loaded.sovereign == null:
		return "expected sovereign to be restored in from_dict"
	if not loaded.sovereign_enabled:
		return "expected sovereign_enabled to be true in from_dict"
	if loaded.sovereign.ticks_remaining != rc.sovereign.ticks_remaining:
		return "expected ticks_remaining %d, got %d" % [rc.sovereign.ticks_remaining, loaded.sovereign.ticks_remaining]
	if loaded.sovereign.status != rc.sovereign.status:
		return "expected status '%s', got '%s'" % [rc.sovereign.status, loaded.sovereign.status]

	rc.resolve_sovereign_bribe()
	var dict_resolved: Dictionary = rc.to_dict()
	var loaded_resolved := RunController.from_dict(dict_resolved)
	if loaded_resolved.sovereign.status != SovereignTakeover.STATUS_BRIBED:
		return "expected status 'bribed' after roundtrip"
	if loaded_resolved.sovereign_severance_award != 300:
		return "expected 300 severance award after roundtrip"

	return "ok"


func test_m0_loop_sovereign_overlay_actions() -> String:
	var rc := _make_monopoly_rc(60000, 30000)
	var hud := OrbitalHUD.new(rc)
	var loop := M0Loop.new(hud)

	rc.open_rescue()
	loop.show_sovereign_decree()

	if loop.overlay_state != M0Loop.OVERLAY_SOVEREIGN_DECREE:
		return "expected loop overlay OVERLAY_SOVEREIGN_DECREE, got '%s'" % loop.overlay_state
	if not rc.sim_clock.paused:
		return "expected sim_clock to pause on decree"
	if loop.sovereign_cursor != 0:
		return "expected cursor 0, got %d" % loop.sovereign_cursor

	loop.dispatch_action(M0Loop.ACT_DOWN)
	if loop.sovereign_cursor != 1:
		return "expected cursor 1 after ACT_DOWN, got %d" % loop.sovereign_cursor

	loop.dispatch_action(M0Loop.ACT_UP)
	if loop.sovereign_cursor != 0:
		return "expected cursor 0 after ACT_UP, got %d" % loop.sovereign_cursor

	var ok: bool = loop.dispatch_action(M0Loop.ACT_CANCEL)
	if not ok:
		return "expected ACT_CANCEL to succeed"
	if loop.overlay_state != M0Loop.OVERLAY_NONE:
		return "expected overlay OVERLAY_NONE after cancel"
	if rc.sim_clock.paused:
		return "expected sim_clock to resume after cancel"

	loop.dispatch_action(M0Loop.ACT_PROJECT)
	if loop.overlay_state != M0Loop.OVERLAY_SOVEREIGN_DECREE:
		return "expected ACT_PROJECT to reopen sovereign decree modal"

	loop.sovereign_cursor = 3
	loop.dispatch_action(M0Loop.ACT_SUBMIT)
	if loop.overlay_state != M0Loop.OVERLAY_NONE:
		return "expected overlay OVERLAY_NONE after submitting dismiss option"

	loop.show_sovereign_decree()
	loop.sovereign_cursor = 0
	var submit_ok: bool = loop.dispatch_action(M0Loop.ACT_SUBMIT)
	if not submit_ok:
		return "expected ACT_SUBMIT at cursor 0 to execute bribe"
	if loop.overlay_state != M0Loop.OVERLAY_NONE:
		return "expected overlay cleared after bribe"
	if rc.sovereign.status != SovereignTakeover.STATUS_BRIBED:
		return "expected status 'bribed'"

	return "ok"
