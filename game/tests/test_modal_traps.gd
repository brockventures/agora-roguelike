extends RefCounted
## Epic 6 (#123): every modal dialog is a focus trap. While one is up the gamepad cannot
## reach the panels behind it (ladder, tabs, stations, orders, speed, credit line, tender
## shares), the mouse is swallowed by the blocker, A and B do only the documented actions,
## and closing the modal puts the focus back where it was. Also the 4:3 art frame of the
## crisis card and the severance breakdown of the run summary.

const FRAME: float = 1.0 / 60.0 + 0.0001
const TPR: int = 4

## The modal kinds this walks: each a way to raise it and its documented closing action.
const KINDS: Array[String] = ["crisis", "contract", "monopoly", "chapter11", "summary", "perks", "sleep"]


func _scene() -> Node:
	var rc := RunController.new(null, 9, null, {}, TPR)
	rc.world = Barons.for_new_run()
	rc.cr = 100000
	var scene = load("res://scenes/main.tscn").instantiate()
	scene.initialize_systems(rc)
	scene._resolve_child_nodes()
	scene._build_readouts()
	return scene


## Puts the gamepad somewhere recognisable: Market tab, ladder row 2 on the sell side, 7 lots.
func _park_focus(scene: Node) -> void:
	var loop: M0Loop = scene.loop
	loop.set_tab(M0Loop.Tab.MARKET)
	var f: GamepadFocus = loop.hud.gamepad_focus
	f.set_zone(GamepadFocus.Zone.ORDER_BOOK)
	f.set_order_side(GamepadFocus.OrderSide.SELL)
	f.ladder_index = 2
	f.order_qty = 7


func _raise(scene: Node, kind: String) -> bool:
	var loop: M0Loop = scene.loop
	var rc: RunController = scene.controller
	match kind:
		"crisis":
			var deck: CrisisDeck = loop.crisis_deck
			var keep: Array = []
			for def in deck.data["crises"]:
				if def["id"] == "localized_shortage":
					keep.append(def)
			deck.data["crises"] = keep
			deck.data["grace_rounds"] = 0
			deck.bags.force("crisis", true)
			for i in 400:
				loop.advance(FRAME)
				if loop.overlay_state == M0Loop.OVERLAY_CRISIS:
					return true
			return false
		"contract":
			rc.world.advance_round(8, rc)
			loop._raise_contract_if_pending()
			return loop.overlay_state == M0Loop.OVERLAY_CONTRACT
		"monopoly":
			rc.sim_clock.pause()
			for id in rc.world.ids():
				loop._post_baron_event(Takeover.take(rc.world, id, Takeover.PLAYER, rc))
			return loop.overlay_state == M0Loop.OVERLAY_MONOPOLY
		"chapter11":
			rc.doomsday.principal_debt = 1000000
			loop.advance(FRAME)
			return loop.overlay_state == M0Loop.OVERLAY_CHAPTER_11
		"summary", "perks":
			rc.doomsday.ticks_remaining = 1
			loop.advance(FRAME)
			if kind == "perks":
				loop.dispatch_action(M0Loop.ACT_SUBMIT)
				return loop.collapse_phase == M0Loop.PHASE_PERKS
			return loop.overlay_state == M0Loop.OVERLAY_COLLAPSED and loop.collapse_phase == M0Loop.PHASE_SUMMARY
		"sleep":
			rc.sim_clock.pause()
			loop.sleep_pause_active = true
			return loop.sleep_trap_active()
	return false


## What the closing action is, per kind: the actions that are live behind the modal.
func _live(kind: String) -> Array:
	match kind:
		"crisis", "monopoly":
			return [M0Loop.ACT_SUBMIT, M0Loop.ACT_CHAPTER_11]
		"contract":
			return [M0Loop.ACT_SUBMIT, M0Loop.ACT_CANCEL, M0Loop.ACT_CHAPTER_11]
		"chapter11":
			return [M0Loop.ACT_CHAPTER_11]
		"summary":
			return [M0Loop.ACT_SUBMIT]
		"perks":
			return [M0Loop.ACT_UP, M0Loop.ACT_DOWN, M0Loop.ACT_SUBMIT, M0Loop.ACT_CANCEL]
		"sleep":
			return [M0Loop.ACT_PAUSE]
	return []


## Everything the gamepad and the books could be changed through, as one comparable value.
func _state(scene: Node) -> Array:
	var loop: M0Loop = scene.loop
	var rc: RunController = scene.controller
	return [loop._capture_focus(), rc.cr, rc.cargo.duplicate(), rc.sim_clock.speed, rc.sim_clock.paused, loop.total_fills, loop.overlay_state, loop.collapse_phase, loop.perk_cursor, rc.docked_at, rc.profile.severance_points]


func test_every_modal_traps_the_gamepad() -> String:
	var bad: Array = []
	for kind in KINDS:
		var scene := _scene()
		_park_focus(scene)
		var loop: M0Loop = scene.loop
		var before: Dictionary = loop._capture_focus()
		if not _raise(scene, kind):
			bad.append("%s: could not be raised (overlay %s)" % [kind, loop.overlay_state])
			scene.free()
			continue
		scene._refresh_readouts()
		var live: Array = _live(kind)
		var snap: Array = _state(scene)
		for action in M0Loop.ALL_ACTIONS:
			if live.has(action) or action == M0Loop.ACT_LOCALE:
				continue
			if loop.dispatch_action(action):
				bad.append("%s: %s reached the panels behind the modal" % [kind, action])
			if _state(scene) != snap:
				bad.append("%s: %s changed state behind the modal" % [kind, action])
				snap = _state(scene)
		# The same through the real input path: a stick push and a button press.
		var e := InputEventJoypadButton.new()
		e.button_index = JOY_BUTTON_DPAD_DOWN
		e.pressed = true
		if kind != "perks" and loop.handle_input(e):
			bad.append("%s: a D-pad press was consumed behind the modal" % kind)
		# The mouse is swallowed by the blocker and the dim shows.
		if not scene._blocker.visible or scene._blocker.mouse_filter != Control.MOUSE_FILTER_STOP:
			bad.append("%s: the mouse blocker is not up" % kind)
		if not (scene.resolution_modal.visible or scene.sleep_modal.visible):
			bad.append("%s: no modal panel is visible" % kind)
		# Nothing in the HUD can take keyboard or gamepad focus from the modal.
		for n in _controls(scene.hud_container):
			if n.focus_mode != Control.FOCUS_NONE:
				bad.append("%s: %s can take focus" % [kind, n.name])
				break
		scene.free()
	return "ok" if bad.is_empty() else "\n".join(PackedStringArray(bad))


func _controls(root: Node) -> Array:
	var out: Array = []
	for c in root.get_children():
		if c is Control:
			out.append(c)
		out.append_array(_controls(c))
	return out


func test_documented_actions_close_a_modal_and_restore_focus() -> String:
	var bad: Array = []
	var closers: Dictionary = {
		"crisis": M0Loop.ACT_SUBMIT, "contract": M0Loop.ACT_SUBMIT, "monopoly": M0Loop.ACT_SUBMIT,
		"chapter11": M0Loop.ACT_CHAPTER_11,
	}
	for kind in closers:
		var scene := _scene()
		_park_focus(scene)
		var loop: M0Loop = scene.loop
		var before: Dictionary = loop._capture_focus()
		if not _raise(scene, kind):
			bad.append("%s: could not be raised" % kind)
			scene.free()
			continue
		if loop.focus_trap != before:
			bad.append("%s: the trap did not note the focus (%s vs %s)" % [kind, str(loop.focus_trap), str(before)])
		# Scramble the focus the way a stray input could, then close with the documented action.
		loop.hud.gamepad_focus.set_zone(GamepadFocus.Zone.SYSTEM_BAR)
		loop.hud.gamepad_focus.order_qty = 99
		if not loop.dispatch_action(closers[kind]):
			bad.append("%s: %s did not close the modal" % [kind, closers[kind]])
		if loop.overlay_state != M0Loop.OVERLAY_NONE and not (kind == "crisis" and loop.overlay_state != M0Loop.OVERLAY_CRISIS):
			bad.append("%s: still up as %s" % [kind, loop.overlay_state])
		elif kind != "chapter11" and loop._capture_focus() != before:
			bad.append("%s: focus not restored (%s vs %s)" % [kind, str(loop._capture_focus()), str(before)])
		scene.free()
	return "ok" if bad.is_empty() else "\n".join(PackedStringArray(bad))


func test_contract_b_declines_and_restores_focus() -> String:
	var scene := _scene()
	_park_focus(scene)
	var loop: M0Loop = scene.loop
	var before: Dictionary = loop._capture_focus()
	if not _raise(scene, "contract"):
		return "no contract offer"
	if not loop.dispatch_action(M0Loop.ACT_CANCEL) or loop.overlay_state != M0Loop.OVERLAY_NONE:
		return "B must decline the offer"
	var got: Dictionary = loop._capture_focus()
	scene.free()
	return "ok" if got == before else "focus not restored after B: %s vs %s" % [str(got), str(before)]


func test_summary_and_perks_flow_is_a_and_b_only() -> String:
	var scene := _scene()
	_park_focus(scene)
	var loop: M0Loop = scene.loop
	if not _raise(scene, "summary"):
		return "no summary"
	if loop.dispatch_action(M0Loop.ACT_CANCEL):
		return "B must do nothing on the run summary"
	if not loop.dispatch_action(M0Loop.ACT_SUBMIT) or loop.collapse_phase != M0Loop.PHASE_PERKS:
		return "A on the summary must open Golden Parachutes"
	if not loop.dispatch_action(M0Loop.ACT_CANCEL) or loop.collapse_phase != M0Loop.PHASE_SUMMARY:
		return "B must go back to the summary"
	loop.dispatch_action(M0Loop.ACT_SUBMIT)
	loop.perk_cursor = loop.perk_rows().size()
	if not loop.dispatch_action(M0Loop.ACT_SUBMIT) or loop.overlay_state != M0Loop.OVERLAY_NONE:
		return "A on START must begin the next run"
	var f: GamepadFocus = loop.hud.gamepad_focus
	var ok: bool = f.current_zone == GamepadFocus.Zone.TACTICAL_MAP and loop.focus_trap.is_empty() and loop.tab == M0Loop.Tab.MAP
	scene.free()
	return "ok" if ok else "a new run must start on the map with no stale trap"


func test_sleep_banner_only_lets_start_through() -> String:
	var scene := _scene()
	_park_focus(scene)
	var loop: M0Loop = scene.loop
	_raise(scene, "sleep")
	var before: Dictionary = loop._capture_focus()
	for action in [M0Loop.ACT_SUBMIT, M0Loop.ACT_UP, M0Loop.ACT_TAB_NEXT, M0Loop.ACT_STATION_NEXT, M0Loop.ACT_CREDIT, M0Loop.ACT_SHARES]:
		if loop.dispatch_action(action):
			return "%s got through the sleep banner" % action
	if loop._capture_focus() != before:
		return "the sleep banner let the focus move"
	if not loop.dispatch_action(M0Loop.ACT_PAUSE) or loop.sleep_trap_active():
		return "Start must resume from the sleep banner"
	scene.free()
	return "ok"


func test_credit_line_and_tender_are_dead_behind_every_modal() -> String:
	# Neither is a dialog of its own (Y credit, shares/tender key act on the docked baron), so
	# the trap's job is that no modal lets either key through.
	var bad: Array = []
	for kind in KINDS:
		var scene := _scene()
		var loop: M0Loop = scene.loop
		loop.set_tab(M0Loop.Tab.MARKET)
		if not _raise(scene, kind):
			scene.free()
			continue
		var cr: int = scene.controller.cr
		for action in [M0Loop.ACT_CREDIT, M0Loop.ACT_SHARES]:
			if loop.dispatch_action(action) or scene.controller.cr != cr or loop.last_credit_reason != "":
				bad.append("%s: %s acted behind the modal" % [kind, action])
		scene.free()
	return "ok" if bad.is_empty() else "\n".join(PackedStringArray(bad))


func test_settings_menu_swallows_input() -> String:
	var scene := _scene()
	_park_focus(scene)
	scene.settings_menu.open()
	scene._refresh_readouts()
	var before: Dictionary = scene.loop._capture_focus()
	var bad: Array = []
	for button in [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X, JOY_BUTTON_Y, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER]:
		var e := InputEventJoypadButton.new()
		e.button_index = button
		e.pressed = true
		if not scene.handle_input(e):
			bad.append("button %d leaked past the settings menu" % button)
	if scene.loop._capture_focus() != before:
		bad.append("the settings menu let the focus move")
	if not scene._blocker.visible:
		bad.append("no mouse blocker under settings")
	scene.free()
	return "ok" if bad.is_empty() else "\n".join(PackedStringArray(bad))


func test_crisis_modal_carries_a_4_3_art_frame() -> String:
	var scene := _scene()
	if not _raise(scene, "crisis"):
		return "no crisis"
	scene._refresh_readouts()
	var art: Control = scene._res["art"]
	var ok: bool = art.visible and absf(art.size.x / art.size.y - 4.0 / 3.0) < 0.001
	var inside: bool = Rect2(Vector2.ZERO, scene.resolution_modal.size).encloses(Rect2(art.position, art.size))
	scene.free()
	if not ok:
		return "the crisis modal needs a visible 4:3 art frame"
	return "ok" if inside else "the art frame escapes the modal"


func test_other_modals_have_no_crisis_art_except_the_run_summary() -> String:
	var bad: Array = []
	for kind in ["contract", "monopoly", "chapter11", "perks"]:
		var scene := _scene()
		_raise(scene, kind)
		scene._refresh_readouts()
		if (scene._res["art"] as Control).visible:
			bad.append(kind)
		scene.free()
	return "ok" if bad.is_empty() else "stray art frame on: %s" % str(bad)


func test_summary_shows_the_severance_breakdown_that_adds_up() -> String:
	var scene := _scene()
	var rc: RunController = scene.controller
	var loop: M0Loop = scene.loop
	rc.sim_clock.pause()
	for id in ["ares_heavy", "titan_cryo_hydro"]:
		loop._post_baron_event(Takeover.take(rc.world, id, Takeover.PLAYER, rc))
	rc.cr = 40000
	rc._track_peak(rc.assess())
	rc.sim_clock.resume()
	rc.doomsday.ticks_remaining = 1
	loop.advance(FRAME)
	if loop.overlay_state != M0Loop.OVERLAY_COLLAPSED:
		return "no collapse"
	var r: Dictionary = loop.run_summary()
	var parts: int = int(r["severance_filings_pts"]) + int(r["severance_peak_pts"]) + int(r["barons_severance"])
	if parts != int(r["severance_awarded"]):
		return "breakdown %d does not add up to the award %d (%s)" % [parts, int(r["severance_awarded"]), str(r)]
	if (r["broken_ids"] as Array).size() != 2 or int(r["barons_broken"]) != 2:
		return "per-baron rows need the two broken barons: %s" % str(r)
	scene._refresh_readouts()
	var shown: String = scene.panel_text(scene.resolution_modal)
	for needle in ["PEAK NET WORTH", "ROUNDS SURVIVED", "FILINGS", "BROKEN", "SEVERANCE BANKED"]:
		if not shown.contains(needle):
			return "the summary does not show %s:\n%s" % [needle, shown]
	var summed: int = 0
	for row in scene._summary_model()["rows"]:
		if str(row["key"]).begins_with("FILINGS") or str(row["key"]).begins_with("PEAK NET WORTH @") or str(row["key"]).begins_with("BROKEN"):
			summed += int(str(row["value"]).trim_prefix("+"))
	scene.free()
	return "ok" if summed == int(r["severance_awarded"]) else "the rows on screen add to %d, not the award %d" % [summed, int(r["severance_awarded"])]


# --- Toasts ---

func test_toast_tray_is_deterministic_and_bounded() -> String:
	var a := ToastTray.new()
	var b := ToastTray.new()
	for t in [a, b]:
		t.push(ToastTray.KIND_FILLED, "BUY 5 ORE")
		t.push("bogus", "ignored")
		t.push(ToastTray.KIND_INFO, "")
		t.push(ToastTray.KIND_INFO, "ALERT")
	if a.toasts.size() != 2:
		return "bad kinds and empty text must be refused"
	for i in 16:
		a.advance(0.25)
	for i in 3:
		b.advance(1.0 / 60.0)
	if a.toasts.size() != 0 or b.toasts.size() != 2:
		return "expiry must follow the ages alone (%d, %d)" % [a.toasts.size(), b.toasts.size()]
	for i in 6:
		b.push(ToastTray.KIND_FILLED, "x%d" % i)
	if b.toasts.size() != ToastTray.MAX_VISIBLE or b.toasts[ToastTray.MAX_VISIBLE - 1]["text"] != "x5":
		return "at most %d toasts, newest kept" % ToastTray.MAX_VISIBLE
	b.advance(1000.0)
	return "ok" if b.toasts.size() == ToastTray.MAX_VISIBLE else "a wake-sized delta must not skip the whole life"


func test_toasts_show_fills_and_alerts_without_touching_the_sim() -> String:
	var scene := _scene()
	var rc: RunController = scene.controller
	var loop: M0Loop = scene.loop
	var hud: OrbitalHUD = loop.hud
	scene._refresh_readouts()
	var sim: Array = [rc.sim_clock.total_ticks, rc.cr, rc.sim_clock.paused, rc.get_current_round(), loop._capture_focus()]
	hud.gamepad_focus.order_executed.emit({"side": "BUY", "qty": 5, "commodity": "ORE", "price": 18.0, "station": "mars"})
	hud.post_headline("Ares Heavy squeezes the machinery lanes", "MARKET", "WARNING")
	scene._refresh_readouts()
	if scene.toasts.toasts.size() != 2:
		return "a fill and a warning make two toasts, got %d" % scene.toasts.toasts.size()
	if scene.toasts.toasts[0]["kind"] != ToastTray.KIND_FILLED or scene.toasts.toasts[1]["kind"] != ToastTray.KIND_INFO:
		return "toast kinds wrong: %s" % str(scene.toasts.toasts)
	var visible: int = 0
	for r in scene._toast_rows:
		var host: Control = r["host"]
		if host.visible:
			visible += 1
			if host.mouse_filter != Control.MOUSE_FILTER_IGNORE or host.focus_mode != Control.FOCUS_NONE:
				return "a toast must ignore the mouse and take no focus"
	if visible != 2:
		return "two toasts should be drawn, got %d" % visible
	# They age on the UI delta only and leave when their time is up; the sim is untouched.
	var shown_ticks: int = rc.sim_clock.total_ticks
	for i in int(ToastTray.LIFETIME / ToastTray.MAX_STEP) + 2:
		scene.toasts.advance(ToastTray.MAX_STEP)
	scene._refresh_readouts()
	for r in scene._toast_rows:
		if (r["host"] as Control).visible:
			return "toasts must auto-dismiss"
	var after: Array = [rc.sim_clock.total_ticks, rc.cr, rc.sim_clock.paused, rc.get_current_round(), loop._capture_focus()]
	scene.free()
	return "ok" if after == sim and shown_ticks == sim[0] else "a toast moved sim state: %s -> %s" % [str(sim), str(after)]


func test_a_toast_neither_blocks_input_nor_closes_a_modal() -> String:
	var scene := _scene()
	var loop: M0Loop = scene.loop
	_raise(scene, "crisis")
	scene.toasts.push(ToastTray.KIND_FILLED, "BUY 1 ORE")
	scene._refresh_readouts()
	if loop.overlay_state != M0Loop.OVERLAY_CRISIS:
		return "a toast closed the modal"
	if not loop.dispatch_action(M0Loop.ACT_SUBMIT):
		return "A must still acknowledge the crisis with a toast up"
	scene.free()
	return "ok"


func test_toasts_wait_behind_a_modal_and_show_once_it_closes() -> String:
	var scene := _scene()
	var loop: M0Loop = scene.loop
	scene.toasts.push(ToastTray.KIND_INFO, "ALERT")
	_raise(scene, "crisis")
	scene._refresh_readouts()
	var age: float = scene.toasts.toasts[0]["age"]
	for r in scene._toast_rows:
		if (r["host"] as Control).visible:
			return "a toast is drawn over a modal"
	scene._process(0.2)
	if float(scene.toasts.toasts[0]["age"]) != age:
		return "a toast aged while the modal was up"
	loop.dispatch_action(M0Loop.ACT_SUBMIT)
	scene._refresh_readouts()
	var shown: bool = (scene._toast_rows[0]["host"] as Control).visible
	scene.free()
	return "ok" if shown else "the toast did not come back after the modal closed"
