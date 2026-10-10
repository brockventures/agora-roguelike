extends RefCounted
## Accessibility (#37): minimum font size, text scale, colorblind palettes with a
## non-color bid/ask cue, gamepad remapping with conflict handling, and settings
## persistence. Every test restores the global InputMap / Palette / locale it
## touches and writes only under a temp directory, never the real user://.

const TMP_ROOT := "user://test_tmp"
var _counter: int = 0


func _store() -> SaveStore:
	_counter += 1
	return SaveStore.new("%s/a11y_%d_%d" % [TMP_ROOT, Time.get_ticks_usec(), _counter])


func _cleanup(store: SaveStore) -> void:
	load("res://tests/test_save_load.gd")._rm_rf(store.dir)
	DirAccess.remove_absolute(TMP_ROOT)


func _reset_globals() -> void:
	InputRemap.apply(InputRemap.defaults())
	Palette.set_current(Palette.DEFAULT)
	Loc.set_locale(Loc.LOCALE_EN)


func _scene(scale: float = 1.0) -> Node:
	var scene = load("res://scenes/main.tscn").instantiate()
	scene.initialize_systems(RunController.new(null, 84))
	scene._resolve_child_nodes()
	scene._build_readouts()
	scene.settings.text_scale = scale
	scene.apply_text_scale()
	return scene


func _labels(node: Node) -> Array:
	var out: Array = []
	if node is Label:
		out.append(node)
	for c in node.get_children():
		out.append_array(_labels(c))
	return out


func _btn(index: int) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = index
	e.pressed = true
	return e


func _key(code: int) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.pressed = true
	return e


func _act(name: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	return e


# --- Minimum text size ---

func test_no_label_is_smaller_than_the_deck_verified_minimum() -> String:
	var bad: Array = []
	var seen := 0
	for scale in AccessibilitySettings.TEXT_SCALES:
		var scene := _scene(scale)
		for l in _labels(scene.hud_container):
			seen += 1
			var fs: int = l.get_theme_font_size("font_size")
			if fs < AccessibilitySettings.MIN_FONT_SIZE:
				bad.append("%s at %.2fx: %d px" % [l.get_path(), scale, fs])
		for px in [scene.scaled_size(MainScene.MAP_FONT_SIZE), scene.scaled_size(MainScene.TICKER_FONT_SIZE), scene.scaled_size(MainScene.HINT_FONT_SIZE)]:
			if px < AccessibilitySettings.MIN_FONT_SIZE:
				bad.append("drawn text %d px at %.2fx" % [px, scale])
		scene.free()
	if seen < 30:
		return "audit saw only %d labels" % seen
	return "ok" if bad.is_empty() else "text below %d px: %s" % [AccessibilitySettings.MIN_FONT_SIZE, str(bad)]


func test_no_font_size_literal_below_the_minimum_in_source() -> String:
	var re := RegEx.create_from_string("(?:font_size\"\\s*,\\s*|_make_label\\([^\\n]*,\\s*|draw_string\\([^\\n]*,\\s*-1,\\s*|FONT_SIZE\\s*:\\s*int\\s*=\\s*)(\\d+)")
	var bad: Array = []
	var matches := 0
	for d in ["res://ui", "res://scenes"]:
		for f in DirAccess.open(d).get_files():
			if not f.ends_with(".gd"):
				continue
			for m in re.search_all(FileAccess.get_file_as_string(d.path_join(f))):
				matches += 1
				if int(m.get_string(1)) < AccessibilitySettings.MIN_FONT_SIZE:
					bad.append("%s: %s" % [f, m.get_string(0)])
	if matches < 8:
		return "source scan found only %d font sizes; the regex is stale" % matches
	return "ok" if bad.is_empty() else str(bad)


func test_text_scale_multiplies_every_label_and_keeps_100_percent_geometry() -> String:
	var scene := _scene(1.0)
	var base_sizes: Array = []
	for l in scene._scaled_labels():
		base_sizes.append(l.get_theme_font_size("font_size"))
	var hint_y: float = scene.hint_label.position.y
	scene.settings.text_scale = 1.3
	scene.apply_text_scale()
	var i := 0
	var err := ""
	for l in scene._scaled_labels():
		var want: int = int(round(float(base_sizes[i]) * 1.3))
		if l.get_theme_font_size("font_size") != want:
			err = "%s: %d, wanted %d" % [l.get_path(), l.get_theme_font_size("font_size"), want]
		i += 1
	scene.settings.text_scale = 1.0
	scene.apply_text_scale()
	var back_ok: bool = is_equal_approx(scene.hint_label.position.y, hint_y) and scene.header_label.get_theme_font_size("font_size") == 18
	scene.free()
	if err != "":
		return err
	return "ok" if back_ok else "100% did not restore the original layout"


func test_labels_fit_at_every_text_scale() -> String:
	var fit = load("res://tests/test_i18n_fit.gd").new()
	var report: Array = []
	for scale in AccessibilitySettings.TEXT_SCALES:
		Loc.set_locale(Loc.LOCALE_EN)
		var scene := _scene(scale)
		var f: Array = fit.findings(scene)
		scene.free()
		if not f.is_empty():
			report.append("%.2fx: %s" % [scale, "\n  ".join(PackedStringArray(f))])
	return "ok" if report.is_empty() else "overflow at larger text: %s" % "\n".join(PackedStringArray(report))


func test_settings_screen_text_fits_at_every_text_scale() -> String:
	var fit = load("res://tests/test_i18n_fit.gd").new()
	var report: Array = []
	for scale in AccessibilitySettings.TEXT_SCALES:
		var scene := _scene(scale)
		var menu: SettingsMenu = scene.settings_menu
		menu.open()
		# Walk the cursor over every row; each page must fit the modal.
		for i in menu.rows().size():
			menu.cursor = i
			scene._refresh_readouts()
			var f: Array = fit.overflow_of("settings[row %d @%.2f]" % [i, scale], scene.settings_label, scene.settings_label.text, scene.settings_label.size, scene.settings_modal.size)
			report.append_array(f)
		scene.free()
	return "ok" if report.is_empty() else str(report.slice(0, 6))


# --- Palettes ---

func test_palette_switch_changes_the_ladder_colors() -> String:
	var scene := _scene()
	scene.loop.set_tab(M0Loop.Tab.MARKET)
	scene._refresh_readouts()
	var seen: Dictionary = {}
	for id in Palette.CHOICES:
		scene.settings.set_palette(id)
		scene._refresh_readouts()
		var swatches: Array = []
		for r in scene._ladder_swatches:
			if r.visible:
				swatches.append(r.color)
		if swatches.size() < 2:
			scene.free()
			_reset_globals()
			return "no ladder swatches under %s" % id
		var ask: Color = swatches[0]
		var bid: Color = swatches[swatches.size() - 1]
		if ask != Palette.ask_color(id) or bid != Palette.bid_color(id):
			scene.free()
			_reset_globals()
			return "%s swatches %s/%s do not match the palette" % [id, ask, bid]
		seen[id] = [ask, bid]
	scene.free()
	_reset_globals()
	for id in [Palette.DEUTERANOPIA, Palette.PROTANOPIA]:
		if seen[id][0] == seen[Palette.DEFAULT][0] or seen[id][1] == seen[Palette.DEFAULT][1]:
			return "%s did not change a ladder color" % id
	return "ok"


func test_every_palette_separates_bid_from_ask_by_hue_or_lightness() -> String:
	for id in Palette.CHOICES:
		var a: Color = Palette.ask_color(id)
		var b: Color = Palette.bid_color(id)
		var dist: float = Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()
		if dist < 0.4:
			return "%s bid/ask only %.2f apart" % [id, dist]
	# The colorblind sets must not rely on a red/green split: bid is blue, ask is not green or red-dominant.
	for id in [Palette.DEUTERANOPIA, Palette.PROTANOPIA]:
		var b: Color = Palette.bid_color(id)
		if not (b.b > b.r and b.b > b.g * 0.9):
			return "%s bid is not blue" % id
	return "ok"


func test_bid_and_ask_keep_a_non_color_cue_in_every_palette() -> String:
	var scene := _scene()
	scene.loop.set_tab(M0Loop.Tab.MARKET)
	var err := ""
	for id in Palette.CHOICES:
		scene.settings.set_palette(id)
		scene._refresh_readouts()
		var side: String = scene.sidebar_label.text
		var board: String = scene._board_text()
		var asks := 0
		var bids := 0
		for line in side.split("\n"):
			var t: String = line.strip_edges().trim_prefix(">").strip_edges()
			if t.contains("ASK"):
				asks += 1
				if not t.begins_with(Palette.ASK_GLYPH + " ASK"):
					err = "%s: ask row has no glyph: '%s'" % [id, line]
			if t.contains("BID"):
				bids += 1
				if not t.begins_with(Palette.BID_GLYPH + " BID"):
					err = "%s: bid row has no glyph: '%s'" % [id, line]
		if asks == 0 or bids == 0:
			err = "%s: ladder lacks ask or bid rows" % id
		if not board.contains(Palette.BID_GLYPH + " BID") or not board.contains(Palette.ASK_GLYPH + " ASK"):
			err = "%s: market board lacks the bid/ask glyphs" % id
	scene.free()
	_reset_globals()
	return "ok" if err == "" else err


# --- Remapping ---

func test_rebinding_changes_the_input_map() -> String:
	var s := AccessibilitySettings.new()
	var r: Dictionary = s.rebind("m0_speed", _btn(15))
	var pads: Array = []
	for ev in InputMap.action_get_events("m0_speed"):
		if ev is InputEventJoypadButton:
			pads.append(ev.button_index)
	var key_r: Dictionary = s.rebind("m0_speed", _key(KEY_T))
	var keys: Array = []
	for ev in InputMap.action_get_events("m0_speed"):
		if ev is InputEventKey:
			keys.append(ev.physical_keycode)
	_reset_globals()
	if not bool(r["ok"]) or pads != [15]:
		return "pad rebind failed: %s %s" % [str(r), str(pads)]
	if not bool(key_r["ok"]) or keys != [KEY_T]:
		return "key rebind failed: %s" % str(keys)
	return "ok"


func test_a_rebound_action_fires_from_its_new_button_only() -> String:
	var s := AccessibilitySettings.new()
	s.rebind("m0_speed", _btn(15))
	var new_ev := _btn(15)
	var old_ev := _btn(JOY_BUTTON_Y)
	var fires_new: bool = new_ev.is_action("m0_speed")
	var fires_old: bool = old_ev.is_action("m0_speed")
	_reset_globals()
	return "ok" if fires_new and not fires_old else "new %s, old %s" % [fires_new, fires_old]


func test_rebinding_leaves_stick_axes_alone() -> String:
	var before := 0
	for ev in InputMap.action_get_events("m0_up"):
		before += 1 if ev is InputEventJoypadMotion else 0
	var s := AccessibilitySettings.new()
	s.rebind("m0_up", _btn(15))
	var after := 0
	for ev in InputMap.action_get_events("m0_up"):
		after += 1 if ev is InputEventJoypadMotion else 0
	_reset_globals()
	return "ok" if before == after else "stick events %d -> %d" % [before, after]


func test_conflict_swaps_the_two_actions() -> String:
	var s := AccessibilitySettings.new()
	var speed_btn: int = int(s.bindings["m0_speed"]["joy"][0])
	var pause_btn: int = int(s.bindings["m0_pause"]["joy"][0])
	var r: Dictionary = s.rebind("m0_speed", _btn(pause_btn))
	var err := ""
	if not bool(r["ok"]) or str(r["swapped_with"]) != "m0_pause":
		err = "no swap: %s" % str(r)
	elif s.bindings["m0_speed"]["joy"] != [pause_btn] or s.bindings["m0_pause"]["joy"] != [speed_btn]:
		err = "swap wrong: speed %s pause %s" % [str(s.bindings["m0_speed"]["joy"]), str(s.bindings["m0_pause"]["joy"])]
	elif not _btn(speed_btn).is_action("m0_pause") or _btn(speed_btn).is_action("m0_speed"):
		err = "InputMap not swapped"
	elif InputMap.action_has_event("m0_speed", _btn(pause_btn)) == false:
		err = "speed lost its button"
	_reset_globals()
	return "ok" if err == "" else err


func test_no_input_is_ever_bound_to_two_actions_after_rebinds() -> String:
	var s := AccessibilitySettings.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 60:
		var a: String = InputRemap.actions()[rng.randi() % InputRemap.actions().size()]
		if rng.randi() % 2 == 0:
			s.rebind(a, _btn(rng.randi_range(0, 3) + (9 if rng.randi() % 2 == 0 else 0)))
		else:
			s.rebind(a, _key(KEY_A + rng.randi() % 8))
	var owners: Dictionary = {}
	var err := ""
	for a in InputRemap.actions():
		for slot in ["joy", "key"]:
			var seen_here: Array = []
			for c in s.bindings[a][slot]:
				var k: String = "%s:%d" % [slot, c]
				if seen_here.has(k):
					err = "%s has %s twice" % [a, k]
				seen_here.append(k)
				if owners.has(k) and owners[k] != a:
					err = "%s bound to %s and %s" % [k, owners[k], a]
				owners[k] = a
	var live := InputRemap.capture()
	_reset_globals()
	if err == "" and live != s.bindings:
		err = "InputMap and settings disagree"
	return "ok" if err == "" else err


func test_refuses_when_a_swap_would_leave_the_other_action_bare() -> String:
	var s := AccessibilitySettings.new()
	# Strip m0_speed's key so it has nothing to give, then try to take m0_pause's key.
	s.bindings["m0_speed"]["key"] = []
	var pause_key: int = int(s.bindings["m0_pause"]["key"][0])
	var before: Dictionary = s.bindings.duplicate(true)
	var r: Dictionary = s.rebind("m0_speed", _key(pause_key))
	var same: bool = s.bindings == before
	_reset_globals()
	if bool(r["ok"]) or not same:
		return "should have refused without changing anything: %s" % str(r)
	return "ok" if str(r["message"][0]) == "SET_MSG_REFUSED" else "no refusal message: %s" % str(r["message"])


func test_reserved_inputs_cannot_be_bound() -> String:
	var s := AccessibilitySettings.new()
	for ev in [_btn(JOY_BUTTON_BACK), _key(KEY_ESCAPE), _key(KEY_F1)]:
		var r: Dictionary = s.rebind("m0_speed", ev)
		if bool(r["ok"]) or str(r["message"][0]) != "SET_MSG_RESERVED":
			_reset_globals()
			return "reserved input accepted: %s" % InputRemap.describe(ev)
	var r2: Dictionary = s.rebind("m0_speed", InputEventMouseButton.new())
	_reset_globals()
	return "ok" if not bool(r2["ok"]) else "mouse button accepted"


func test_reset_restores_defaults() -> String:
	var s := AccessibilitySettings.new()
	var shipped: Dictionary = InputRemap.defaults()
	s.rebind("m0_speed", _btn(15))
	s.rebind("m0_pause", _key(KEY_T))
	s.set_text_scale(1.3)
	s.set_palette(Palette.PROTANOPIA)
	s.reset_defaults()
	var live := InputRemap.capture()
	var err := ""
	if s.bindings != shipped or live != shipped:
		err = "bindings not restored"
	elif s.text_scale != 1.0 or s.palette != Palette.DEFAULT or Palette.current() != Palette.DEFAULT:
		err = "scale or palette not restored"
	_reset_globals()
	return "ok" if err == "" else err


# --- Persistence ---

func test_settings_round_trip_through_settings_json() -> String:
	var store := _store()
	var s := AccessibilitySettings.new()
	s.rebind("m0_speed", _btn(15))
	s.rebind("m0_tab_next", _key(KEY_T))
	s.set_text_scale(1.15)
	s.set_palette(Palette.DEUTERANOPIA)
	s.set_locale(Loc.LOCALE_PSEUDO)
	var err: Error = s.save(store)
	_reset_globals()  # as if the game restarted
	var err_msg := ""
	if err != OK or not FileAccess.file_exists(store.dir.path_join("settings.json")):
		err_msg = "settings.json not written (%d)" % err
	else:
		var loaded := AccessibilitySettings.load_from(store)
		loaded.apply_all()
		var speed_pads: Array = []
		for ev in InputMap.action_get_events("m0_speed"):
			if ev is InputEventJoypadButton:
				speed_pads.append(ev.button_index)
		if loaded.text_scale != 1.15 or loaded.palette != Palette.DEUTERANOPIA or loaded.locale != Loc.LOCALE_PSEUDO:
			err_msg = "scalars lost: %s" % str(loaded.to_dict())
		elif loaded.bindings != s.bindings:
			err_msg = "bindings lost"
		elif speed_pads != [15] or Palette.current() != Palette.DEUTERANOPIA or Loc.current() != Loc.LOCALE_PSEUDO:
			err_msg = "load did not reach InputMap/Palette/Loc: %s" % str(speed_pads)
		elif not InputMap.action_has_event("m0_tab_next", _key(KEY_T)):
			err_msg = "key binding not live"
	_reset_globals()
	_cleanup(store)
	return "ok" if err_msg == "" else err_msg


func test_settings_load_survives_missing_corrupt_and_hostile_files() -> String:
	var store := _store()
	var plain := AccessibilitySettings.load_from(store)
	if plain.text_scale != 1.0 or plain.bindings != InputRemap.defaults():
		return "missing file should give defaults"
	var hostile := {"text_scale": 9.0, "palette": "neon", "locale": "xx",
		"bindings": {"m0_speed": {"joy": ["a", 3.0, null], "key": "oops"}, "not_an_action": {"joy": [1]}, "m0_up": 5}}
	store.save_settings(hostile)
	var s := AccessibilitySettings.load_from(store)
	var err := ""
	if s.text_scale != 1.0 or s.palette != Palette.DEFAULT or s.locale != Loc.LOCALE_EN:
		err = "bad scalars not defaulted: %s" % str(s.to_dict())
	elif s.bindings["m0_speed"]["joy"] != [3] or s.bindings["m0_speed"]["key"] != []:
		err = "bad binding entries not cleaned: %s" % str(s.bindings["m0_speed"])
	elif s.bindings.has("not_an_action") or s.bindings["m0_up"] != InputRemap.defaults()["m0_up"]:
		err = "unknown action kept or bad entry not defaulted"
	var f := FileAccess.open(store.settings_path(), FileAccess.WRITE)
	f.store_string("{ not json")
	f.close()
	if err == "" and AccessibilitySettings.load_from(store).text_scale != 1.0:
		err = "corrupt file should give defaults"
	_cleanup(store)
	return "ok" if err == "" else err


func test_settings_write_is_atomic_and_stays_in_the_given_directory() -> String:
	var store := _store()
	var s := AccessibilitySettings.new()
	s.set_text_scale(1.3)
	s.save(store)
	store.simulate_write_failure = true
	s.set_text_scale(1.0)
	var fail: Error = s.save(store)
	store.simulate_write_failure = false
	var kept := AccessibilitySettings.load_from(store).text_scale
	var tmp_left := FileAccess.file_exists(store.settings_path() + SaveStore.TMP_SUFFIX)
	var in_dir: bool = store.settings_path().begins_with(store.dir) and not store.dir.begins_with("user://saves")
	_cleanup(store)
	if fail == OK or kept != 1.3 or tmp_left:
		return "failed write damaged the file (err %d, kept %s, tmp %s)" % [fail, kept, tmp_left]
	return "ok" if in_dir else "test store not isolated from user://saves"


func test_main_saves_settings_changes_and_reloads_them() -> String:
	var store := _store()
	var scene := _scene()
	scene.enable_persistence(store)
	scene.settings.set_text_scale(1.3)
	scene.settings.set_palette(Palette.PROTANOPIA)
	scene.settings.rebind("m0_speed", _btn(15))
	_reset_globals()
	var scene2 := _scene()
	scene2.enable_persistence(store)
	var err := ""
	if scene2.settings.text_scale != 1.3 or Palette.current() != Palette.PROTANOPIA:
		err = "scale/palette not reloaded"
	elif scene2.header_label.get_theme_font_size("font_size") != 23:
		err = "scale not applied on load: %d" % scene2.header_label.get_theme_font_size("font_size")
	elif not InputMap.action_has_event("m0_speed", _btn(15)):
		err = "binding not reloaded into the InputMap"
	scene.free()
	scene2.free()
	_reset_globals()
	_cleanup(store)
	return "ok" if err == "" else err


# --- Settings screen ---

func test_settings_screen_opens_with_view_and_is_fully_gamepad_navigable() -> String:
	var scene := _scene()
	if not scene.handle_input(_btn(JOY_BUTTON_BACK)) or not scene.settings_menu.is_open:
		scene.free()
		return "View did not open the settings screen"
	var menu: SettingsMenu = scene.settings_menu
	var n: int = menu.rows().size()
	# D-pad down walks every row and wraps.
	for i in n:
		scene.handle_input(_act("ui_down"))
	var wrapped: bool = menu.cursor == 0
	# Left/right on the first row steps the text scale.
	scene.handle_input(_act("ui_right"))
	var stepped: bool = scene.settings.text_scale == 1.15
	# Down to Colors, A cycles it.
	scene.handle_input(_act("ui_down"))
	scene.handle_input(_act("ui_accept"))
	var cycled: bool = scene.settings.palette == Palette.DEUTERANOPIA
	# The left stick works too, once per push.
	var stick := InputEventJoypadMotion.new()
	stick.axis = JOY_AXIS_LEFT_Y
	stick.axis_value = 1.0
	scene.handle_input(stick)
	scene.handle_input(stick)
	var stick_moved: bool = menu.cursor == 2
	var release := InputEventJoypadMotion.new()
	release.axis = JOY_AXIS_LEFT_Y
	release.axis_value = 0.0
	scene.handle_input(release)
	# B closes.
	scene.handle_input(_act("ui_cancel"))
	var closed: bool = not menu.is_open
	scene.free()
	_reset_globals()
	if not wrapped:
		return "cursor did not wrap over %d rows" % n
	if not stepped or not cycled:
		return "left/right or A did not change values (scale %s, palette %s)" % [stepped, cycled]
	if not stick_moved:
		return "stick did not move the cursor once per push (cursor %d)" % menu.cursor
	return "ok" if closed else "B did not close the screen"


func test_rebinding_from_the_screen_with_a_pad_button() -> String:
	var scene := _scene()
	scene.handle_input(_btn(JOY_BUTTON_BACK))
	var menu: SettingsMenu = scene.settings_menu
	var row := -1
	for i in menu.rows().size():
		if menu.rows()[i].get("action", "") == "m0_speed":
			row = i
	menu.cursor = row
	scene.handle_input(_act("ui_accept"))
	var listening: bool = menu.listening_action == "m0_speed"
	var text_listening: String = menu.text()
	# The press arrives while listening: it is captured, not treated as navigation.
	scene.handle_input(_btn(15))
	var done: bool = menu.listening_action == "" and scene.settings.bindings["m0_speed"]["joy"] == [15]
	# Listen again; View cancels without changing anything.
	scene.handle_input(_act("ui_accept"))
	scene.handle_input(_btn(JOY_BUTTON_BACK))
	var cancelled: bool = menu.listening_action == "" and menu.is_open and scene.settings.bindings["m0_speed"]["joy"] == [15]
	# A key works as well.
	scene.handle_input(_act("ui_accept"))
	scene.handle_input(_key(KEY_T))
	var keyed: bool = scene.settings.bindings["m0_speed"]["key"] == [KEY_T]
	scene.free()
	_reset_globals()
	if not listening or not text_listening.contains(Loc.t("SET_LISTENING")):
		return "A did not start listening"
	if not done:
		return "button not captured"
	if not cancelled:
		return "View did not cancel the rebind"
	return "ok" if keyed else "key not captured"


func test_settings_screen_freezes_the_sim_and_swallows_game_input() -> String:
	var scene := _scene()
	var before: int = scene.controller.sim_clock.total_ticks
	scene.handle_input(_btn(JOY_BUTTON_BACK))
	var tab_before: int = scene.loop.tab
	var swallowed: bool = scene.handle_input(_btn(JOY_BUTTON_RIGHT_SHOULDER))
	scene._process(1.0)
	var frozen: bool = scene.controller.sim_clock.total_ticks == before
	var same_tab: bool = scene.loop.tab == tab_before
	scene.free()
	_reset_globals()
	if not swallowed or not same_tab:
		return "game input leaked through the open settings screen"
	return "ok" if frozen else "sim advanced behind the settings screen"


func test_every_remappable_action_has_a_row_and_a_translated_name() -> String:
	var rows: Dictionary = load("res://tests/test_localization.gd").csv_rows()
	var menu := SettingsMenu.new()
	var listed: Array = []
	for r in menu.rows():
		if r["kind"] == SettingsMenu.Row.ACTION:
			listed.append(r["action"])
	if listed != M0Loop.ALL_ACTIONS:
		return "rows %s do not match the m0 actions" % str(listed)
	for a in listed:
		if not rows.has("SET_ACT_" + a.trim_prefix("m0_").to_upper()):
			return "no name for %s" % a
	return "ok"


func test_sidebar_scrolls_instead_of_truncating_when_larger_text_overflows_it() -> String:
	var scene := _scene(1.3)
	var deck: CrisisDeck = scene.loop.crisis_deck
	var actives: Array = []
	var uid := 900
	for def in deck.data["crises"]:
		var fx: Dictionary = def["effects"].duplicate()
		if str(def["kind"]) == "audit":
			fx = {"trade_cap_qty": int(fx["trade_cap_qty"]), "fee_bps": int(fx["fee_max_bps"])}
		if str(def["kind"]) == "collapse":
			fx["margin_call_bps"] = int(fx.get("margin_call_bps", 150))
		actives.append({"uid": uid, "id": str(def["id"]), "kind": str(def["kind"]), "tier": str(def["tier"]), "name": str(def["name"]), "text": str(def["headline"]),
			"band": "high", "station": "mars", "commodity": "MACHINERY", "started_round": 1, "expires_round": 9, "rounds": 5, "effects": fx})
		uid += 1
	deck.active = actives
	scene._refresh_readouts()
	var overflow: float = scene.sidebar_overflow()
	var starts: float = MainScene.marquee_offset(0.0, overflow)
	var ends: float = MainScene.marquee_offset(1000.0 * 0.0 + MainScene.SIDEBAR_DWELL_TOP + overflow / MainScene.SIDEBAR_SCROLL_SPEED + 0.5, overflow)
	scene._sidebar_scroll_t = MainScene.SIDEBAR_DWELL_TOP + overflow / MainScene.SIDEBAR_SCROLL_SPEED + 0.5
	scene._refresh_readouts()
	var reaches_end: bool = is_equal_approx(-scene.sidebar_label.position.y, overflow)
	scene.free()
	_reset_globals()
	if overflow <= 0.0:
		return "five crises at 130%% should overflow the sidebar view, got %.0f" % overflow
	if starts != 0.0 or not is_equal_approx(ends, overflow) or not reaches_end:
		return "marquee does not run from the top (%.1f) to the last line (%.1f of %.1f)" % [starts, ends, overflow]
	return "ok"


func test_nothing_scrolls_at_100_percent() -> String:
	var scene := _scene(1.0)
	scene._refresh_readouts()
	var none: bool = scene.sidebar_overflow() == 0.0 and scene.sidebar_label.position.y == 0.0
	scene.free()
	return "ok" if none else "sidebar scrolls at 100%"
