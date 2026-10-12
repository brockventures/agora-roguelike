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
