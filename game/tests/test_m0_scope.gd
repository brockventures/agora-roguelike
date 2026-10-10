extends RefCounted
## M0 scope completion (#34): Mars-only station, Ares Heavy counterparty, the
## collapse -> summary -> Golden Parachutes -> new run loop, and 60 FPS pacing.

const MainScript := preload("res://scenes/main.gd")
const FRAME: float = 1.0 / 60.0 + 0.0001


func _main() -> MainScene:
	var m: MainScene = MainScript.new()
	m.start_new_run(5)
	m.controller.world.rivals.clear()  # not what this test is about; test_rival_fleets.gd covers the fleets
	return m


func _collapse(m: MainScene) -> void:
	m.controller.doomsday.ticks_remaining = 1
	m.loop.advance(FRAME)


func test_starts_docked_at_mars() -> String:
	var m := _main()
	var r: String = _t_starts_docked_at_mars(m)
	m.free()
	return r


func _t_starts_docked_at_mars(m: MainScene) -> String:
	if m.controller.docked_at != "mars" or m.hud.active_station != "mars":
		return "expected docked and active at mars, got %s / %s" % [m.controller.docked_at, m.hud.active_station]
	if StationMarket.station_name(m.controller.docked_at) != "Arcadia Foundries":
		return "mars station name wrong"
	return "ok"


func test_station_cycling_allowed_but_trading_only_where_docked() -> String:
	var m := _main()
	var r: String = _t_station_cycling_allowed_but_trading_only_where_docked(m)
	m.free()
	return r


## Was "station cycling must be disabled in M0". Since the travel loop (#111) LT/RT
## select a destination; trading is still only possible at the docked station.
func _t_station_cycling_allowed_but_trading_only_where_docked(m: MainScene) -> String:
	var lp: M0Loop = m.loop
	lp.set_tab(M0Loop.Tab.MARKET)
	if not lp.dispatch_action(M0Loop.ACT_STATION_NEXT) or m.hud.active_station == "mars":
		return "station cycling should move the selection, got %s" % m.hud.active_station
	if lp.dispatch_action(M0Loop.ACT_SUBMIT) or m.hud.gamepad_focus.last_rejection_reason != "NOT_DOCKED_AT_STATION":
		return "trading away from the dock must be rejected, got %s" % m.hud.gamepad_focus.last_rejection_reason
	if not lp.dispatch_action(M0Loop.ACT_STATION_PREV) or m.hud.active_station != "mars":
		return "station cycling back failed: %s" % m.hud.active_station
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "buy at mars rejected: %s" % m.hud.gamepad_focus.last_rejection_reason
	return "ok"


func test_fill_names_ares_heavy_counterparty() -> String:
	var m := _main()
	var r: String = _t_fill_names_ares_heavy_counterparty(m)
	m.free()
	return r


func _t_fill_names_ares_heavy_counterparty(m: MainScene) -> String:
	var lp: M0Loop = m.loop
	lp.set_tab(M0Loop.Tab.MARKET)
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "buy rejected"
	var buy: Dictionary = m.hud.gamepad_focus.last_executed_order
	if buy.get("counterparty", "") != "ARES HEAVY":
		return "buy counterparty: %s" % str(buy.get("counterparty"))
	m.hud.gamepad_focus.set_order_side(GamepadFocus.OrderSide.SELL)
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "sell rejected"
	if m.hud.gamepad_focus.last_executed_order.get("counterparty", "") != "ARES HEAVY":
		return "sell counterparty wrong"
	if str(m._card_notes()).find("ARES HEAVY") < 0:
		return "receipt line missing ARES HEAVY"
	for c in Transit.COMMODITIES:
		for o: Order in lp.market.get_book("mars", c).asks:
			if o.agent_id != StationMarket.MAKER_ID:
				return "resting maker is %s" % o.agent_id
	return "ok"


func test_book_replenishes_across_rounds() -> String:
	var m := _main()
	var r: String = _t_book_replenishes_across_rounds(m)
	m.free()
	return r


func _t_book_replenishes_across_rounds(m: MainScene) -> String:
	var lp: M0Loop = m.loop
	lp.set_tab(M0Loop.Tab.MARKET)
	var depth0: int = int(m.hud.get_order_book_ladder()["asks"][0]["quantity"])
	m.hud.gamepad_focus.set_quantity(depth0)
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "drain buy rejected"
	if int(m.hud.get_order_book_ladder()["asks"][0]["quantity"]) == depth0:
		return "top ask not consumed"
	m.controller.sim_clock.set_speed(1)
	var ticks: int = m.controller.ticks_per_round
	for i in ticks + 5:
		lp.advance(FRAME)
	if int(m.hud.get_order_book_ladder()["asks"][0]["quantity"]) != depth0:
		return "book not replenished after a round"
	return "ok"


func test_collapse_summary_perks_new_run() -> String:
	var m := _main()
	var r: String = _t_collapse_summary_perks_new_run(m)
	m.free()
	return r


func _t_collapse_summary_perks_new_run(m: MainScene) -> String:
	var lp: M0Loop = m.loop
	var rc: RunController = m.controller
	# Run a bit so the summary has numbers, then collapse.
	for i in 40:
		lp.advance(FRAME)
	_collapse(m)
	if lp.overlay_state != M0Loop.OVERLAY_COLLAPSED or lp.collapse_phase != M0Loop.PHASE_SUMMARY:
		return "expected collapsed summary, got %s / %s" % [lp.overlay_state, lp.collapse_phase]
	var sum: Dictionary = lp.run_summary()
	for k in ["net_worth", "peak_net_worth", "rounds_survived", "severance_awarded", "severance_balance"]:
		if not sum.has(k):
			return "summary missing %s" % k
	if rc.profile.runs_completed != 1:
		return "run not banked into the profile"
	if str(m._resolution_model()).find("PEAK NET WORTH") < 0:
		return "summary text missing"
	# Give the profile points, then pick a perk through the UI path.
	rc.profile.severance_points = 100
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT) or lp.collapse_phase != M0Loop.PHASE_PERKS:
		return "A on summary should open perk select"
	var rows: Array = lp.perk_rows()
	if rows.is_empty() or lp.perk_cursor >= rows.size():
		return "cursor should start on a buyable perk: %d of %d" % [lp.perk_cursor, rows.size()]
	var pick: String = str(rows[lp.perk_cursor]["id"])
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT) or not rc.profile.has_unlock(pick):
		return "perk %s not bought" % pick
	if rc.profile.severance_points >= 100:
		return "severance not spent"
	# A locked tier-2 perk must be refused.
	var locked_idx: int = -1
	for i in lp.perk_rows().size():
		if not bool(lp.perk_rows()[i]["can_buy"]) and not bool(lp.perk_rows()[i]["owned"]):
			locked_idx = i
			break
	lp.perk_cursor = locked_idx
	if lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "unaffordable or locked perk was accepted"
	if str(m._resolution_model()).find("GOLDEN PARACHUTES") < 0:
		return "perk text missing"
	# Move to START NEW RUN and go.
	for i in 20:
		lp.dispatch_action(M0Loop.ACT_DOWN)
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "START NEW RUN rejected"
	var rc2: RunController = m.controller
	if rc2 == rc or rc2.is_collapsed() or lp.overlay_state != M0Loop.OVERLAY_NONE:
		return "new run not started cleanly"
	if rc2.modifiers.is_empty():
		return "perk modifiers not applied to the new run"
	if rc2.docked_at != "mars" or m.hud.active_station != "mars":
		return "new run not docked at mars"
	if rc2.sim_clock.paused or rc2.doomsday.ticks_remaining != DoomsdayClock.DEFAULT_TOTAL_TICKS:
		return "new run clock not fresh"
	if not rc2.profile.has_unlock(pick):
		return "profile lost the perk"
	if lp.advance(FRAME) == 0:
		return "new run does not tick"
	if not lp.market.has_book("mars", "ORE") or m.hud.market != lp.market:
		return "fresh market not bound"
	return "ok"


func test_no_soft_lock_after_collapse() -> String:
	var m := _main()
	var r: String = _t_no_soft_lock_after_collapse(m)
	m.free()
	return r


func _t_no_soft_lock_after_collapse(m: MainScene) -> String:
	var lp: M0Loop = m.loop
	_collapse(m)
	if lp.dispatch_action(M0Loop.ACT_CHAPTER_11):
		return "X should not file after collapse"
	# From the summary, A (twice, with zero severance) must always reach a new run.
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "A rejected on summary"
	var guard: int = 0
	while lp.overlay_state == M0Loop.OVERLAY_COLLAPSED and guard < 5:
		if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
			return "A rejected in perk select with cursor %d" % lp.perk_cursor
		guard += 1
	if lp.overlay_state != M0Loop.OVERLAY_NONE:
		return "still stuck after A presses"
	return "ok"


func test_input_event_path_after_collapse() -> String:
	var m := _main()
	var r: String = _t_input_event_path_after_collapse(m)
	m.free()
	return r


func _t_input_event_path_after_collapse(m: MainScene) -> String:
	_collapse(m)
	var e := InputEventAction.new()
	e.action = M0Loop.ACT_SUBMIT
	e.pressed = true
	if not m.handle_input(e):
		return "A event not consumed on summary"
	return "ok"


func test_chapter_11_mid_run_flow_unchanged() -> String:
	var m := _main()
	var r: String = _t_chapter_11_mid_run_flow_unchanged(m)
	m.free()
	return r


func _t_chapter_11_mid_run_flow_unchanged(m: MainScene) -> String:
	var rc: RunController = m.controller
	rc.doomsday.principal_debt = 1_000_000
	m.loop.advance(FRAME)
	if m.loop.overlay_state != M0Loop.OVERLAY_CHAPTER_11 or m.loop.collapse_phase != M0Loop.PHASE_NONE:
		return "expected chapter 11 overlay, got %s" % m.loop.overlay_state
	if not m.loop.dispatch_action(M0Loop.ACT_CHAPTER_11) or rc.corp_number != 2:
		return "X did not file"
	if rc.docked_at != "mars":
		return "docked_at lost on filing"
	return "ok"


func test_max_fps_is_60() -> String:
	if int(ProjectSettings.get_setting("application/run/max_fps", 0)) != 60:
		return "application/run/max_fps should be 60"
	return "ok"
