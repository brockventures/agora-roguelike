extends RefCounted
## Epic 6 (#124) motion: the map ring's stepped dash march and the ticker's fresh-line
## wipe-in. Both run on UI frame time only (never the sim clock), play on twos (12 drawings
## a second), stand still under the reduced-motion setting, and leave every capture and
## test settled: a scene driven by a script holds still unless a test freezes it at a phase.
## Reduced motion is an accessibility setting, default off, saved with settings.json and
## never with a run.

const TMP_ROOT := "user://test_tmp"
var _counter: int = 0


func _scene() -> Node:
	var scene = load("res://scenes/main.tscn").instantiate()
	scene.initialize_systems(RunController.new(null, 84))
	scene._resolve_child_nodes()
	scene._build_readouts()
	scene._refresh_readouts()
	return scene


func _store() -> SaveStore:
	_counter += 1
	return SaveStore.new("%s/motion_%d_%d" % [TMP_ROOT, Time.get_ticks_usec(), _counter])


func _cleanup(store: SaveStore) -> void:
	load("res://tests/test_save_load.gd")._rm_rf(store.dir)
	DirAccess.remove_absolute(TMP_ROOT)


func _act(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


# --- Reduced motion: a saved accessibility setting ---

func test_reduced_motion_defaults_off_and_round_trips_in_settings() -> String:
	var store := _store()
	var s := AccessibilitySettings.new()
	if s.reduced_motion:
		return "reduced motion must default to off"
	s.set_reduced_motion(true)
	if s.save(store) != OK:
		return "save failed"
	var back := AccessibilitySettings.load_from(store)
	var err := ""
	if not back.reduced_motion or not bool(back.to_dict()["reduced_motion"]):
		err = "reduced motion did not round-trip through settings.json"
	if err == "" and AccessibilitySettings.from_dict({"reduced_motion": "yes"}).reduced_motion:
		err = "a non-bool stored value should fall back to off"
	if err == "" and AccessibilitySettings.from_dict({"text_scale": 1.3}).reduced_motion:
		err = "a settings.json from before #124 should load with motion on"
	s.reset_defaults()
	if err == "" and s.reduced_motion:
		err = "reset should restore full motion"
	_cleanup(store)
	return "ok" if err == "" else err


func test_reduced_motion_is_not_part_of_a_run_save() -> String:
	var rc := RunController.new(null, 84)
	var blob: String = var_to_str(rc.to_dict()) if rc.has_method("to_dict") else ""
	if blob.find("reduced_motion") >= 0:
		return "the run state must not carry the a11y setting"
	var store := _store()
	var m: MainScene = load("res://scenes/main.gd").new()
	m.enable_persistence(store)
	m.start_new_run(5)
	m.settings.set_reduced_motion(true)
	var saved: Dictionary = store.load_settings()
	m.free()
	_cleanup(store)
	return "ok" if saved.get("reduced_motion", false) == true else "settings.json missing reduced_motion: %s" % str(saved)


func test_settings_menu_has_a_reduced_motion_row_on_the_gamepad() -> String:
	var menu := SettingsMenu.new(AccessibilitySettings.new())
	menu.open()
	var row := -1
	for i in menu.rows().size():
		if int(menu.rows()[i]["kind"]) == SettingsMenu.Row.REDUCED_MOTION:
			row = i
	if row < 0:
		return "no reduced-motion row"
	for i in row:
		menu.handle_event(_act("ui_down"))
	if menu.cursor != row:
		return "D-pad did not reach the row"
	var off_text: String = menu.row_text(row, menu.rows()[row])
	menu.handle_event(_act("ui_accept"))
	if not menu.settings.reduced_motion or menu.row_text(row, menu.rows()[row]).find("On") < 0 or off_text.find("Off") < 0:
		return "A should turn reduced motion on: %s / %s" % [off_text, menu.row_text(row, menu.rows()[row])]
	menu.handle_event(_act("ui_left"))
	return "ok" if not menu.settings.reduced_motion else "Left/Right should toggle it back off"


# --- Ring march ---

func test_ring_marches_in_whole_drawings_and_loops() -> String:
	var scene := _scene()
	var got: Array = []
	for k in 9:
		scene.freeze_motion_at(float(k) / MainScene.MOTION_FPS)
		got.append(scene.ring_march_px())
	# Mid-drawing times hold the drawing: 12 fps, no tween.
	scene.freeze_motion_at(0.5 / MainScene.MOTION_FPS)
	var held0: float = scene.ring_march_px()
	scene.freeze_motion_at(1.9 / MainScene.MOTION_FPS)
	var held1: float = scene.ring_march_px()
	scene.free()
	if got != [0.0, 7.0, 14.0, 21.0, 0.0, 7.0, 14.0, 21.0, 0.0]:
		return "the dashes should march 7 px a drawing over 4 drawings, then loop: %s" % str(got)
	if held0 != 0.0 or held1 != 7.0:
		return "a drawing must hold between ticks, got %f then %f" % [held0, held1]
	return "ok"


func test_ring_draw_phase_changes_the_ring_and_is_repeatable() -> String:
	var scene := _scene()
	scene.freeze_motion_at(0.0)
	var a: float = scene.ring_march_px()
	scene.freeze_motion_at(1.0 / MainScene.MOTION_FPS)
	var b: float = scene.ring_march_px()
	scene.freeze_motion_at(1.0 / MainScene.MOTION_FPS)
	var b2: float = scene.ring_march_px()
	scene.free()
	return "ok" if a != b and b == b2 else "phases should differ between drawings and repeat for the same time (%f %f %f)" % [a, b, b2]


func test_motion_runs_on_ui_frame_time_not_the_sim_clock() -> String:
	var scene := _scene()
	scene.run_motion_from(0.0)
	var rc: RunController = scene.controller
	rc.sim_clock.paused = true
	rc.sim_clock.speed = 1
	scene.advance_motion(0.1)
	var paused_t: float = scene.ui_time
	rc.sim_clock.paused = false
	rc.sim_clock.speed = 4
	scene.advance_motion(0.1)
	var fast_t: float = scene.ui_time
	# Sim time passing leaves UI time alone.
	var before: float = scene.ui_time
	scene.loop.advance(1.0 / 60.0 + 0.0001)
	var after_loop: float = scene.ui_time
	# A wake-sized raw delta is dropped, as everywhere else.
	scene.advance_motion(SimClock.SUSPEND_THRESHOLD + 1.0)
	var after_wake: float = scene.ui_time
	scene.free()
	if not is_equal_approx(paused_t, 0.1) or not is_equal_approx(fast_t, 0.2):
		return "UI time should advance by the raw delta whatever the pause or speed: %f %f" % [paused_t, fast_t]
	if after_loop != before:
		return "advancing the sim moved UI time"
	return "ok" if after_wake == after_loop else "a wake-sized delta moved UI time"


func test_a_scripted_scene_starts_settled() -> String:
	var scene := _scene()
	scene.advance_motion(1.0)
	var t: float = scene.ui_time
	var ring: float = scene.ring_march_px()
	scene.free()
	return "ok" if t == 0.0 and ring == 0.0 else "a scene under a SceneTree script must not animate (t=%f ring=%f)" % [t, ring]


func test_reduced_motion_holds_the_ring_still() -> String:
	var scene := _scene()
	scene.freeze_motion_at(1.0 / MainScene.MOTION_FPS)
	var moving: float = scene.ring_march_px()
	scene.settings.reduced_motion = true
	var still: float = scene.ring_march_px()
	scene.free()
	return "ok" if moving == 7.0 and still == 0.0 else "reduced motion should settle the ring (%f -> %f)" % [moving, still]


# --- Ticker wipe ---

func _fresh_line_scene() -> Node:
	var scene := _scene()
	# The seeded lines were there on the first refresh: they never wipe.
	scene.hud.post_headline("Belt Authority raises the Ceres lane toll to 25 CR.", "REGULATION", "WARNING")
	scene.freeze_motion_at(10.0)
	scene._refresh_readouts()
	return scene


func _revealed(scene: Node, row: int) -> float:
	var cover: Control = scene.ticker_wipes[row]
	if not cover.visible:
		return 1.0
	return (cover.position.x - 12.0) / (scene.ticker_panel.size.x - 24.0)


func test_ticker_wipes_a_fresh_line_in_three_drawings() -> String:
	var scene := _fresh_line_scene()
	var got: Array = []
	for k in 5:
		scene.freeze_motion_at(10.0 + float(k) / MainScene.MOTION_FPS)
		scene._refresh_readouts()
		got.append(snappedf(_revealed(scene, 0), 0.001))
	var older: float = _revealed(scene, 1)
	scene.free()
	# Hard cuts in thirds (ag-wipe, steps(3)): nothing, a third, two thirds, whole, whole.
	if got != [0.0, 0.333, 0.667, 1.0, 1.0]:
		return "the fresh line should reveal in thirds over three drawings: %s" % str(got)
	return "ok" if older == 1.0 else "an older line must not wipe (row 1 revealed %f)" % older


func test_ticker_wipe_is_repeatable_and_does_not_replay() -> String:
	var scene := _fresh_line_scene()
	scene.freeze_motion_at(10.0 + 1.0 / MainScene.MOTION_FPS)
	scene._refresh_readouts()
	var a: float = _revealed(scene, 0)
	scene._refresh_readouts()
	scene._refresh_readouts()
	var b: float = _revealed(scene, 0)
	scene.freeze_motion_at(20.0)
	scene._refresh_readouts()
	var done: float = _revealed(scene, 0)
	# Going back in time on the same line does not make it wipe again from a later refresh.
	scene.freeze_motion_at(30.0)
	scene._refresh_readouts()
	var later: float = _revealed(scene, 0)
	scene.free()
	if a != b:
		return "refreshing at the same time changed the wipe (%f vs %f)" % [a, b]
	return "ok" if done == 1.0 and later == 1.0 else "a settled line wiped again"


func test_settled_scene_and_reduced_motion_show_ticker_lines_whole() -> String:
	var scene := _scene()
	scene.hud.post_headline("Raiders reported off the Mars lane; escorts advised.", "PIRACY", "WARNING")
	scene._refresh_readouts()
	var settled: float = _revealed(scene, 0)
	scene.freeze_motion_at(10.0)
	scene.hud.post_headline("Refinancing window opens; margin calls on overdue notes.", "DEBT", "INFO")
	scene._refresh_readouts()
	var wiping: float = _revealed(scene, 0)
	scene.settings.reduced_motion = true
	scene._refresh_readouts()
	var reduced: float = _revealed(scene, 0)
	scene.free()
	if settled != 1.0:
		return "a settled scene shows a fresh line whole, got %f" % settled
	if wiping != 0.0:
		return "the test did not catch a line mid-wipe (%f)" % wiping
	return "ok" if reduced == 1.0 else "reduced motion should show the line whole, got %f" % reduced


func test_wipe_cover_matches_the_strip_and_the_row() -> String:
	var scene := _fresh_line_scene()
	scene.freeze_motion_at(10.0 + 1.0 / MainScene.MOTION_FPS)
	scene._refresh_readouts()
	var cover: HudKit.Plate = scene.ticker_wipes[0]
	var strip: StyleBoxFlat = scene.ticker_panel.get_theme_stylebox("panel") as StyleBoxFlat
	var chip: Control = scene.ticker_chips[0]
	var ok_color: bool = strip != null and cover.fill.is_equal_approx(strip.bg_color)
	var ok_rect: bool = cover.visible and cover.position.x > chip.position.x and cover.position.x + cover.size.x <= scene.ticker_panel.size.x + 0.5
	var ok_row: bool = cover.position.y <= chip.position.y and cover.position.y + cover.size.y >= chip.position.y + chip.size.y
	scene.free()
	if not ok_color:
		return "the cover must be the strip's own colour"
	return "ok" if ok_rect and ok_row else "the cover does not span the unrevealed part of the row"
