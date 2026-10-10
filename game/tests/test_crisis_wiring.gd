extends RefCounted
## Crisis deck wired into the M0 loop (#12): the interrupt modal pauses the clock
## and A resumes it, the GalNet ticker posts, the market and orders feel the
## effects, and a lifted crisis restores everything.

const FRAME: float = 1.0 / 60.0 + 0.0001
const RICH: int = 20000


func _loop(p_seed: int = 9, p_ticks_per_round: int = 4) -> Dictionary:
	var rc := RunController.new(null, p_seed, null, {}, p_ticks_per_round)
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.lock_station("mars")
	return {"rc": rc, "hud": hud, "loop": lp}


## Runs frames until the crisis modal is up (or the frame budget runs out).
func _run_to_crisis(lp: M0Loop, budget: int = 200) -> bool:
	for i in budget:
		lp.advance(FRAME)
		if lp.overlay_state == M0Loop.OVERLAY_CRISIS:
			return true
	return false


func _only(deck: CrisisDeck, id: String) -> void:
	var keep: Array = []
	for def in deck.data["crises"]:
		if def["id"] == id:
			keep.append(def)
	deck.data["crises"] = keep
	deck.data["grace_rounds"] = 0


func test_loop_attaches_a_deck_to_the_controller() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	if rc.crisis_deck == null or lp.crisis_deck != rc.crisis_deck:
		return "deck not attached"
	var bare := RunController.new(null, 1)
	if bare.crisis_deck != null or bare.trade_cap_qty() != 0 or bare.trade_fee(1000) != 0:
		return "a bare controller must have no crisis behaviour"
	return "ok"


func test_modal_pauses_clock_and_a_resumes() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	_only(lp.crisis_deck, "localized_shortage")
	lp.crisis_deck.bags.force("crisis", true)
	if not _run_to_crisis(lp):
		return "no crisis modal raised"
	if not rc.sim_clock.paused:
		return "clock not paused by the modal"
	var ticks: int = rc.sim_clock.total_ticks
	if lp.advance(FRAME) != 0 or rc.sim_clock.total_ticks != ticks:
		return "clock advanced under the modal"
	if lp.current_crisis().is_empty():
		return "no current crisis"
	# Other buttons do nothing behind the modal; A on the Map tab acknowledges and never trades.
	var fills: int = lp.total_fills
	if lp.dispatch_action(M0Loop.ACT_PAUSE) or lp.dispatch_action(M0Loop.ACT_SPEED):
		return "pause / speed must be dead under the modal"
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "A did not acknowledge"
	if lp.overlay_state != M0Loop.OVERLAY_NONE or rc.sim_clock.paused:
		return "A should lower the modal and resume the clock"
	if lp.total_fills != fills or rc.cargo.size() != 0:
		return "acknowledging must not place an order"
	if lp.advance(FRAME) < 1 or rc.sim_clock.total_ticks <= ticks:
		return "clock did not run after acknowledge"
	return "ok"


func test_modal_stops_the_clock_on_the_drawing_subtick() -> String:
	# One big 5x frame spans several sub-ticks; none may run after the draw.
	var ctx := _loop(9, 2)
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	_only(lp.crisis_deck, "localized_shortage")
	lp.crisis_deck.bags.force("crisis", true)
	rc.sim_clock.set_speed(5)
	var seen := {"at": -1}
	var clock: SimClock = rc.sim_clock  # not rc: a lambda holding rc would cycle through rc's deck
	lp.crisis_deck.crisis_drawn.connect(func(_c): seen["at"] = clock.total_ticks)
	for i in 100:
		lp.advance(0.2)
		if lp.overlay_state == M0Loop.OVERLAY_CRISIS:
			break
	if int(seen["at"]) < 0:
		return "no crisis drawn"
	if rc.sim_clock.total_ticks != int(seen["at"]):
		return "clock ran %d sub-ticks past the draw" % (rc.sim_clock.total_ticks - int(seen["at"]))
	return "ok"


func test_ticker_posts_on_draw_and_expiry() -> String:
	var ctx := _loop()
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	_only(lp.crisis_deck, "localized_shortage")
	lp.crisis_deck.bags.force("crisis", true)
	if not _run_to_crisis(lp):
		return "no crisis"
	var head: Dictionary = hud.get_recent_headlines(1)[0]
	if head["category"] != "CRISIS" or not str(head["text"]).begins_with("SHORTAGE:"):
		return "no crisis headline: %s" % str(head)
	lp.dispatch_action(M0Loop.ACT_SUBMIT)
	for i in 200:
		lp.advance(FRAME)
		if lp.crisis_deck.active.is_empty():
			break
	for h in hud.get_recent_headlines(8):
		if str(h["text"]).contains("has lifted") and h["category"] == "CRISIS":
			return "ok"
	return "no expiry headline: %s" % str(hud.get_recent_headlines(8))


func test_market_changes_then_reverts_through_the_loop() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	var fresh := StationMarket.new()
	_only(lp.crisis_deck, "localized_shortage")
	lp.crisis_deck.bags.force("crisis", true)
	if not _run_to_crisis(lp):
		return "no crisis"
	var c: Dictionary = lp.current_crisis()
	var key: String = c["commodity"]
	if lp.market.ladder("mars", key, 5) == fresh.ladder("mars", key, 5):
		return "market untouched by an active shortage"
	if lp.crisis_deck.tag_for("mars", key) == "":
		return "board tag missing"
	lp.dispatch_action(M0Loop.ACT_SUBMIT)
	lp.crisis_deck.data["grace_rounds"] = 1000000  # no re-roll once it expires (seed-independent)
	for i in 400:
		lp.advance(FRAME)
		if lp.crisis_deck.active.is_empty():
			break
	if not lp.crisis_deck.active.is_empty():
		return "shortage never expired"
	if lp.market.ladder("mars", key, 5) != fresh.ladder("mars", key, 5):
		return "market did not revert after expiry"
	if rc.sim_clock.paused:
		return "clock should be running"
	return "ok"


func test_audit_cap_and_fee_hit_orders_then_lift() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	var deck: CrisisDeck = lp.crisis_deck
	_only(deck, "antitrust_audit")
	deck.bags.force("crisis", true)
	var c: Dictionary = deck.advance_round(3, 1, RICH)
	deck.acknowledge()
	if c.is_empty():
		return "no audit"
	lp.set_tab(M0Loop.Tab.MARKET)
	var f: GamepadFocus = hud.gamepad_focus
	f.set_quantity(deck.order_cap() + 1)
	if bool(f.execute_focused_order().get("ok", true)) or f.last_rejection_reason != "AUDIT_TRADE_CAP":
		return "over-cap order not rejected: %s" % f.last_rejection_reason
	if not f.get_rejection_message().contains("capped at 20"):
		return "message: %s" % f.get_rejection_message()
	f.set_quantity(3)
	var cr0: int = rc.cr
	var res: Dictionary = f.execute_focused_order()
	if not bool(res.get("ok", false)):
		return "in-cap order rejected: %s" % f.last_rejection_reason
	var fee: int = int(res["fee"])
	if fee < 1 or fee != deck.fee_for(int(res["total_cr"])):
		return "fee %d" % fee
	if rc.cr != cr0 - int(res["total_cr"]) - fee:
		return "CR %d, want %d" % [rc.cr, cr0 - int(res["total_cr"]) - fee]
	deck.advance_round(int(c["expires_round"]), 1, RICH)
	f.set_quantity(5)
	var cr1: int = rc.cr
	var after: Dictionary = f.execute_focused_order()
	if not bool(after.get("ok", false)) or int(after["fee"]) != 0 or rc.cr != cr1 - int(after["total_cr"]):
		return "audit did not lift: %s" % str(after)
	return "ok"


func test_margin_call_drains_cargo_value_once_per_round() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	rc.cargo["ORE"] = 100
	var deck: CrisisDeck = rc.crisis_deck
	_only(deck, "systemic_margin_collapse")
	deck.bags.force("crisis", true)
	var drained: Array = []
	rc.margin_call_applied.connect(func(n): drained.append(n))
	deck.advance_round(5, 3, 8000)
	rc._advance_crisis_deck(6)
	if drained.size() != 1:
		return "expected one margin call, got %d" % drained.size()
	var want: int = Piracy.cargo_value("ORE", 100) * 150 / 10000
	if drained[0] != want or rc.cr != Chapter11.FRESH_START_CR - want:
		return "drain %d want %d, cr %d" % [drained[0], want, rc.cr]
	return "ok"


func test_chapter_11_outranks_a_crisis_and_it_returns_afterwards() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	var deck: CrisisDeck = lp.crisis_deck
	_only(deck, "localized_shortage")
	lp._set_overlay(M0Loop.OVERLAY_CHAPTER_11)
	deck.bags.force("crisis", true)
	deck.advance_round(3, 0, RICH)
	if lp.overlay_state != M0Loop.OVERLAY_CHAPTER_11 or not deck.has_pending_ack():
		return "crisis should wait behind Chapter 11"
	lp._set_overlay(M0Loop.OVERLAY_NONE)
	lp._raise_crisis_if_pending()
	if lp.overlay_state != M0Loop.OVERLAY_CRISIS or not rc.sim_clock.paused:
		return "crisis modal should follow"
	return "ok"


func test_main_scene_renders_the_crisis_modal() -> String:
	var scene := MainScene.new()
	scene.start_new_run(5)
	var lp: M0Loop = scene.loop
	_only(lp.crisis_deck, "antitrust_audit")
	lp.crisis_deck.bags.force("crisis", true)
	lp.crisis_deck.advance_round(3, 1, RICH)
	lp._raise_crisis_if_pending()
	var text: String = scene._resolution_text()
	var ok: bool = text.contains("ANTITRUST AUDIT") and text.contains("Press A to acknowledge") and text.contains("capped at 20")
	scene.free()
	return "ok" if ok else "modal text: %s" % text
