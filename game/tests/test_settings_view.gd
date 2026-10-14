extends RefCounted
## The settings screen as HudKit cards (#193): the SettingsMenu row model the view draws
## (row_parts, footer_text) and the SettingsView layout over it. Headless: the view is
## built on a HudKit with no scene, and its nodes are measured where they sit.


func _menu() -> SettingsMenu:
	var m := SettingsMenu.new(AccessibilitySettings.new())
	m.open()
	return m


func _row_of(m: SettingsMenu, kind: int) -> int:
	for i in m.rows().size():
		if int(m.rows()[i]["kind"]) == kind:
			return i
	return -1


func _view(m: SettingsMenu, p_size: Vector2 = Vector2(840.0, 460.0)) -> SettingsView:
	var v := SettingsView.new()
	v.setup(m, HudKit.new(), p_size)
	return v


func _prefs_count(m: SettingsMenu) -> int:
	var n: int = 0
	for i in m.rows().size():
		if str(m.row_parts(i)["section"]) == "prefs":
			n += 1
	return n


func test_row_parts_kind_per_row() -> String:
	var m := _menu()
	var expect: Dictionary = {
		SettingsMenu.Row.SCALE: "choice",
		SettingsMenu.Row.PALETTE: "choice",
		SettingsMenu.Row.LANGUAGE: "choice",
		SettingsMenu.Row.CRT: "toggle",
		SettingsMenu.Row.ALERT_VOLUME: "slider",
		SettingsMenu.Row.ALERT_MUTE: "toggle",
		SettingsMenu.Row.REDUCED_MOTION: "toggle",
		SettingsMenu.Row.TUTORIAL: "toggle",
		SettingsMenu.Row.ACTION: "binding",
		SettingsMenu.Row.RESET: "button",
		SettingsMenu.Row.CLOSE: "button",
	}
	var seen: Dictionary = {}
	for i in m.rows().size():
		var kind: int = int(m.rows()[i]["kind"])
		var part: Dictionary = m.row_parts(i)
		seen[kind] = true
		if str(part["kind"]) != str(expect[kind]):
			return "row %d (kind %d) is %s, expected %s" % [i, kind, part["kind"], expect[kind]]
		var section: String = "prefs" if kind <= SettingsMenu.Row.TUTORIAL else ("controls" if kind == SettingsMenu.Row.ACTION else "footer")
		if str(part["section"]) != section:
			return "row %d section %s, expected %s" % [i, part["section"], section]
	if seen.size() != expect.size():
		return "not every Row kind was covered"
	return "ok"


func test_text_size_is_a_three_step_choice() -> String:
	var m := _menu()
	var scale_row: int = _row_of(m, SettingsMenu.Row.SCALE)
	m.cursor = scale_row
	var before: Dictionary = m.row_parts(scale_row)
	if str(before["kind"]) != "choice" or str(before["value"]) != "100%":
		return "text size starts as %s %s, expected choice 100%%" % [before["kind"], before["value"]]
	m._change(1)
	if str(m.row_parts(scale_row)["value"]) != "115%":
		return "text size after one step is %s, expected 115%%" % m.row_parts(scale_row)["value"]
	m._change(1)
	m._change(1)
	if str(m.row_parts(scale_row)["value"]) != "130%":
		return "text size at the top is %s, expected 130%%" % m.row_parts(scale_row)["value"]
	return "ok"


func test_alert_volume_slider_fraction_in_range_and_moves() -> String:
	var m := _menu()
	var vol_row: int = _row_of(m, SettingsMenu.Row.ALERT_VOLUME)
	m.cursor = vol_row
	m._change(-1)
	var part: Dictionary = m.row_parts(vol_row)
	var vol: float = float(part["fraction"])
	if str(part["kind"]) != "slider" or absf(vol - 0.9) > 0.001 or str(part["value"]) != "90%":
		return "alert volume row shows %s %s at %f" % [part["kind"], part["value"], vol]
	return "ok"


func test_close_row_uses_close_key() -> String:
	var m := _menu()
	var close_row: int = m.rows().size() - 1
	if str(m.row_parts(close_row)["label"]) != Loc.t("SET_CLOSE") or not m.text().contains(Loc.t("SET_CLOSE")):
		return "default close row is not Back to game"
	m.close_key = "SET_CLOSE_TITLE"
	if str(m.row_parts(close_row)["label"]) != Loc.t("SET_CLOSE_TITLE") or not m.text().contains(Loc.t("SET_CLOSE_TITLE")):
		return "close_key is not used by row_parts and text"
	return "ok"


func test_toggle_on_flips() -> String:
	var m := _menu()
	var crt: int = _row_of(m, SettingsMenu.Row.CRT)
	m.cursor = crt
	var before: bool = bool(m.row_parts(crt)["on"])
	m._activate()
	var after: bool = bool(m.row_parts(crt)["on"])
	if before == after:
		return "CRT toggle did not flip"
	if str(m.row_parts(crt)["value"]) != Loc.t("SET_ON"):
		return "CRT toggle value is %s, expected On" % m.row_parts(crt)["value"]
	return "ok"


func test_listening_action_shows_listen_prompt() -> String:
	var m := _menu()
	var act: int = _row_of(m, SettingsMenu.Row.ACTION)
	m.cursor = act
	m._activate()
	var part: Dictionary = m.row_parts(act)
	if str(part["value"]) != Loc.t("SET_LISTENING"):
		return "listening binding shows %s" % part["value"]
	if str(part["section"]) != "controls":
		return "action row is not in the controls section"
	return "ok"


func test_footer_text_is_the_last_line_of_text() -> String:
	var m := _menu()
	var last: String = m.text().split("\n")[-1]
	if m.footer_text() != last:
		return "idle footer %s != text last line %s" % [m.footer_text(), last]
	m.cursor = _row_of(m, SettingsMenu.Row.ACTION)
	m._activate()
	last = m.text().split("\n")[-1]
	if m.footer_text() != last or m.footer_text() != Loc.t("SET_LISTEN_HINT"):
		return "listening footer does not match text()"
	m.handle_event(_key_escape())
	m.cursor = _row_of(m, SettingsMenu.Row.RESET)
	m._activate()
	last = m.text().split("\n")[-1]
	if m.footer_text() != last or m.footer_text() == Loc.t("SET_HINT"):
		return "result footer does not match text()"
	return "ok"


func _key_escape() -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = KEY_ESCAPE
	e.physical_keycode = KEY_ESCAPE
	e.pressed = true
	return e


func test_view_has_one_row_node_per_prefs_row() -> String:
	var m := _menu()
	var v := _view(m)
	var hosts: Array = v.row_hosts(true)
	var expect: int = _prefs_count(m)
	if hosts.size() != expect or expect != 8:
		v.free()
		return "%d prefs row nodes for %d prefs rows" % [hosts.size(), expect]
	v.free()
	return "ok"


func test_focus_bar_follows_the_cursor() -> String:
	var m := _menu()
	var v := _view(m)
	m.move(1)
	v.refresh()
	var r: Rect2 = v.row_rect(m.cursor)
	var ok: bool = v.focus_visible() and r.size.y > 0.0 and v.focus_rect().position.is_equal_approx(r.position)
	var first_prefs: Rect2 = v.row_rect(0)
	var below: bool = r.position.y > first_prefs.position.y
	v.free()
	if not ok:
		return "focus bar is not on the cursor row (cursor %d)" % m.cursor
	if not below:
		return "cursor row 1 is not below row 0"
	return "ok"


func test_controls_window_keeps_the_last_action_visible() -> String:
	var m := _menu()
	var v := _view(m)
	var last_action: int = _row_of(m, SettingsMenu.Row.RESET) - 1
	m.cursor = last_action
	v.refresh()
	var win: Vector2i = v.control_window()
	var r: Rect2 = v.row_rect(last_action)
	var ok: bool = v.focus_visible() and r.size.y > 0.0 and r.position.x > v.size.x * 0.5
	var first_action: int = _row_of(m, SettingsMenu.Row.ACTION)
	var in_window: bool = win.x + win.y - 1 == last_action - first_action
	v.free()
	if win.y < 1:
		return "controls window shows no rows"
	if not ok:
		return "the last action row is not on screen (window %s)" % str(win)
	if not in_window:
		return "window %s does not end at the last action" % str(win)
	return "ok"


func test_view_footer_and_buttons_on_screen() -> String:
	var m := _menu()
	var v := _view(m)
	var reset: Rect2 = v.row_rect(_row_of(m, SettingsMenu.Row.RESET))
	var close: Rect2 = v.row_rect(_row_of(m, SettingsMenu.Row.CLOSE))
	var bottom: float = v.size.y
	v.free()
	if reset.size.x <= 0.0 or close.size.x <= 0.0:
		return "RESET or CLOSE is not laid out"
	if reset.end.x > close.position.x or close.end.y > bottom:
		return "buttons overlap or fall off the view"
	return "ok"
