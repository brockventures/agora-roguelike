extends RefCounted
## The title screen (#192 animated title screen): menu order and texts, Resume Shift
## gated on a usable save, the launch_mode handoff to Main, the settings overlay, and
## the project's main scene.

const TITLE_PATH := "res://scenes/title.tscn"
const TMP_ROOT := "user://test_tmp"
var _counter: int = 0


func _store() -> SaveStore:
	_counter += 1
	return SaveStore.new("%s/title_%d_%d" % [TMP_ROOT, Time.get_ticks_usec(), _counter])


func _cleanup(store: SaveStore) -> void:
	var dir := store.dir
	if DirAccess.dir_exists_absolute(dir):
		for f in DirAccess.get_files_at(dir):
			DirAccess.remove_absolute(dir.path_join(f))
		DirAccess.remove_absolute(dir)
	DirAccess.remove_absolute(TMP_ROOT)  # only succeeds once empty


## Instantiates the title scene and builds it off-tree (the test runner has no main loop).
func _title(store: SaveStore, scene_changes: Array) -> TitleScreen:
	var packed: PackedScene = load(TITLE_PATH)
	var t := packed.instantiate() as TitleScreen
	t.save_store = store
	t.change_scene = func(path: String) -> void: scene_changes.append(path)
	t.build_screen()
	return t


func _release(t: TitleScreen) -> void:
	t.free()


func test_title_scene_has_four_buttons_in_order() -> String:
	var store := _store()
	var t := _title(store, [])
	var texts: Array = []
	for b in t.menu_buttons:
		texts.append(b.text)
	var want := [Loc.t("TITLE_NEW"), Loc.t("TITLE_CONTINUE"), Loc.t("TITLE_SETTINGS"), Loc.t("TITLE_QUIT")]
	_release(t)
	_cleanup(store)
	if texts != want:
		return "menu texts %s, want %s" % [str(texts), str(want)]
	if want != ["Incorporate", "Reconvene the Board", "Corporate Governance", "Adjourn"]:
		return "EN menu copy changed: %s" % str(want)
	return "ok"


func test_continue_disabled_without_saved_run() -> String:
	var store := _store()
	var t := _title(store, [])
	var disabled: bool = t.menu_buttons[1].disabled
	_release(t)
	_cleanup(store)
	if not disabled:
		return "Resume Shift enabled with no save"
	return "ok"


func test_continue_enabled_with_usable_save() -> String:
	var store := _store()
	var main := MainScene.new()
	main.start_new_run(21)
	if store.save_run(main.controller, main.loop.market, main.bags) != OK:
		main.free()
		_cleanup(store)
		return "could not write the fixture save"
	var changes: Array = []
	var t := _title(store, changes)
	var enabled: bool = not t.menu_buttons[1].disabled
	t.menu_buttons[1].pressed.emit()
	var mode: String = MainScene.launch_mode
	MainScene.launch_mode = ""
	_release(t)
	main.free()
	_cleanup(store)
	if not enabled:
		return "Resume Shift disabled with a usable save"
	if mode != "continue" or changes != [TitleScreen.MAIN_SCENE_PATH]:
		return "continue handoff wrong: mode=%s changes=%s" % [mode, str(changes)]
	return "ok"


func test_begin_sets_launch_mode_new_and_changes_scene() -> String:
	var store := _store()
	var changes: Array = []
	var t := _title(store, changes)
	MainScene.launch_mode = ""
	t.menu_buttons[0].pressed.emit()
	var mode: String = MainScene.launch_mode
	MainScene.launch_mode = ""
	_release(t)
	_cleanup(store)
	if mode != "new":
		return "launch_mode is '%s', want 'new'" % mode
	if changes != [TitleScreen.MAIN_SCENE_PATH]:
		return "scene change went to %s" % str(changes)
	return "ok"


func test_settings_overlay_opens_and_closes() -> String:
	var store := _store()
	var t := _title(store, [])
	t.menu_buttons[2].pressed.emit()
	var opened: bool = t.settings_menu.is_open
	t.settings_menu.close()
	var closed: bool = not t.settings_menu.is_open
	_release(t)
	_cleanup(store)
	if not opened or not closed:
		return "settings overlay did not open and close (opened=%s closed=%s)" % [str(opened), str(closed)]
	return "ok"


func test_project_main_scene_is_title() -> String:
	var main_scene = ProjectSettings.get_setting("application/run/main_scene")
	if main_scene != TITLE_PATH:
		return "application/run/main_scene is %s" % str(main_scene)
	return "ok"

func test_title_shows_regulatory_capture_when_profile_has_progress() -> String:
	var store := _store()
	var t0 := _title(store, [])
	var empty_cap: String = t0.capture_text()
	_release(t0)
	var p := MetaProfile.new()
	p.rescues_completed = 2
	p.consultants = ["enforcement", "customs"] as Array[String]
	store.save_profile(p)
	var t1 := _title(store, [])
	var cap: String = t1.capture_text()
	_release(t1)
	_cleanup(store)
	if empty_cap != "":
		return "fresh profile should not show capture on title, got: %s" % empty_cap
	if not cap.contains("40%") or not cap.contains("2/5"):
		return "expected 40%% (2/5) capture on title, got: %s" % cap
	return "ok"


func test_title_gamepad_a_selects_b_closes_settings_and_stick_debounces() -> String:
	var store := _store()
	var changes: Array = []
	var t := _title(store, changes)
	# Push left stick down multiple motion frames without releasing: should step once to Settings (index 2, since Continue is disabled).
	for v in [0.6, 0.75, 0.9, 1.0]:
		var motion := InputEventJoypadMotion.new()
		motion.axis = JOY_AXIS_LEFT_Y
		motion.axis_value = v
		t._input(motion)
	if t.cursor != 2:
		_release(t)
		_cleanup(store)
		return "stick down should step once to Settings (index 2), got cursor=%d" % t.cursor
	# Press A (JOY_BUTTON_A) to open Settings.
	var btn_a := InputEventJoypadButton.new()
	btn_a.button_index = JOY_BUTTON_A
	btn_a.pressed = true
	t._input(btn_a)
	if not t.settings_menu.is_open:
		_release(t)
		_cleanup(store)
		return "JOY_BUTTON_A did not open Settings from TitleScreen"
	# Inside Settings, press A on row 0 (Text Size) to step scale.
	var scale_before: float = t.settings.text_scale
	t._input(btn_a)
	var scale_after: float = t.settings.text_scale
	# Press B (JOY_BUTTON_B) to close Settings and return to TitleScreen.
	var btn_b := InputEventJoypadButton.new()
	btn_b.button_index = JOY_BUTTON_B
	btn_b.pressed = true
	t._input(btn_b)
	var closed: bool = not t.settings_menu.is_open
	_release(t)
	_cleanup(store)
	if scale_after == scale_before:
		return "JOY_BUTTON_A inside SettingsMenu did not activate row 0"
	if not closed:
		return "JOY_BUTTON_B inside SettingsMenu did not close settings"
	return "ok"
