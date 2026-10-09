extends RefCounted
## Unit tests for MainScene root assembly and CRT pipeline (M0 Task 1 #83).

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const MAIN_SCRIPT_PATH := "res://scenes/main.gd"
const MainScript := preload("res://scenes/main.gd")


func test_scene_file_and_script_exist() -> String:
	if not FileAccess.file_exists(MAIN_SCENE_PATH):
		return "Main scene file missing: %s" % MAIN_SCENE_PATH
	if not FileAccess.file_exists(MAIN_SCRIPT_PATH):
		return "Main script file missing: %s" % MAIN_SCRIPT_PATH

	var packed: PackedScene = load(MAIN_SCENE_PATH)
	if packed == null:
		return "Failed to load PackedScene from %s" % MAIN_SCENE_PATH
	if not packed.can_instantiate():
		return "PackedScene cannot be instantiated"
	return "ok"


func test_project_settings_main_scene_and_display() -> String:
	var main_scene = ProjectSettings.get_setting("application/run/main_scene")
	if main_scene != MAIN_SCENE_PATH:
		return "application/run/main_scene mismatch: %s" % str(main_scene)

	var w = ProjectSettings.get_setting("display/window/size/viewport_width")
	var h = ProjectSettings.get_setting("display/window/size/viewport_height")
	if w != 1280 or h != 800:
		return "viewport size in ProjectSettings mismatch: %sx%s" % [str(w), str(h)]

	var stretch_mode = ProjectSettings.get_setting("display/window/stretch/mode")
	if stretch_mode != "canvas_items":
		return "stretch mode mismatch: %s" % str(stretch_mode)

	var stretch_aspect = ProjectSettings.get_setting("display/window/stretch/aspect")
	if stretch_aspect != "keep":
		return "stretch aspect mismatch: %s" % str(stretch_aspect)

	return "ok"


func test_main_scene_instantiation() -> String:
	var packed: PackedScene = load(MAIN_SCENE_PATH)
	var scene: Node = packed.instantiate()
	if scene == null:
		return "instantiate() returned null"
	if not (scene is Control):
		return "scene root is not a Control node"
	if scene.get_script() != MainScript:
		return "scene root script is not res://scenes/main.gd"

	var main: Variant = scene
	if main.VIEWPORT_WIDTH != 1280.0 or main.VIEWPORT_HEIGHT != 800.0:
		return "viewport size constants mismatch (expected 1280x800, got %dx%d)" % [main.VIEWPORT_WIDTH, main.VIEWPORT_HEIGHT]
	if main.custom_minimum_size != Vector2(1280.0, 800.0):
		return "root Control custom_minimum_size mismatch: %s" % str(main.custom_minimum_size)

	scene.free()
	return "ok"


func test_child_presentation_models_initialized() -> String:
	var packed: PackedScene = load(MAIN_SCENE_PATH)
	var scene: Node = packed.instantiate()
	var main: Variant = scene

	if not main.is_initialized:
		scene.free()
		return "is_initialized flag is false"
	if main.hud == null:
		scene.free()
		return "hud (OrbitalHUD) is null"
	if main.tactical_map == null:
		scene.free()
		return "tactical_map (SolTacticalMap) is null"
	if main.trading_overlay == null:
		scene.free()
		return "trading_overlay (TradingOverlay) is null"
	if main.gamepad_focus == null:
		scene.free()
		return "gamepad_focus (GamepadFocus) is null"
	if main.vector_orrery == null:
		scene.free()
		return "vector_orrery (VectorOrrery) is null"
	if main.tactile_audio == null:
		scene.free()
		return "tactile_audio (TactileAudio) is null"

	# Check child model coherence
	if main.tactical_map.selected_station != main.hud.active_station:
		scene.free()
		return "tactical map station mismatch with HUD active station"
	if main.trading_overlay.selected_commodity != main.hud.active_commodity:
		scene.free()
		return "trading overlay commodity mismatch with HUD active commodity"

	scene.free()
	return "ok"


func test_layout_bounds_and_panels() -> String:
	var packed: PackedScene = load(MAIN_SCENE_PATH)
	var scene: Node = packed.instantiate()
	var main: Variant = scene

	var bounds: Dictionary = main.get_layout_bounds()
	if bounds["viewport_width"] != 1280.0 or bounds["viewport_height"] != 800.0:
		scene.free()
		return "layout bounds dimensions mismatch"

	var header_rect: Rect2 = bounds["header_rect"]
	if header_rect.size != Vector2(1280.0, 64.0):
		scene.free()
		return "header rect size mismatch: %s" % str(header_rect)

	var map_rect: Rect2 = bounds["tactical_map_rect"]
	if map_rect.size != Vector2(880.0, 672.0) or map_rect.position != Vector2(0.0, 64.0):
		scene.free()
		return "tactical map rect mismatch: %s" % str(map_rect)

	var sidebar_rect: Rect2 = bounds["sidebar_rect"]
	if sidebar_rect.size != Vector2(400.0, 672.0) or sidebar_rect.position != Vector2(880.0, 64.0):
		scene.free()
		return "sidebar rect mismatch: %s" % str(sidebar_rect)

	var ticker_rect: Rect2 = bounds["ticker_rect"]
	if ticker_rect.size != Vector2(1280.0, 64.0) or ticker_rect.position != Vector2(0.0, 736.0):
		scene.free()
		return "ticker rect mismatch: %s" % str(ticker_rect)

	scene.free()
	return "ok"


func test_scene_node_tree_hierarchy() -> String:
	var packed: PackedScene = load(MAIN_SCENE_PATH)
	var scene: Node = packed.instantiate()

	var required_paths := [
		"ViewportContainer",
		"ViewportContainer/SubViewport",
		"ViewportContainer/SubViewport/Background",
		"ViewportContainer/SubViewport/HUDContainer",
		"ViewportContainer/SubViewport/HUDContainer/HeaderPanel",
		"ViewportContainer/SubViewport/HUDContainer/TacticalMapPanel",
		"ViewportContainer/SubViewport/HUDContainer/SidebarPanel",
		"ViewportContainer/SubViewport/HUDContainer/TickerPanel",
	]

	for path in required_paths:
		if not scene.has_node(path):
			scene.free()
			return "Missing required node in scene tree: %s" % path

	# Ensure legacy CRTOverlay ColorRect is completely removed
	if scene.has_node("CRTOverlay"):
		scene.free()
		return "CRTOverlay ColorRect must be removed (replaced by SubViewportContainer post-processing)"

	var container := scene.get_node("ViewportContainer") as SubViewportContainer
	if container == null:
		scene.free()
		return "ViewportContainer is not a SubViewportContainer"
	if container.material == null or not (container.material is ShaderMaterial):
		scene.free()
		return "ViewportContainer must carry ShaderMaterial for CRT shader pipeline"

	var sub_vp := scene.get_node("ViewportContainer/SubViewport") as SubViewport
	if sub_vp == null:
		scene.free()
		return "SubViewport missing or invalid"
	if sub_vp.size != Vector2i(1280, 800):
		scene.free()
		return "SubViewport size mismatch (expected 1280x800, got %s)" % str(sub_vp.size)

	var bg := scene.get_node("ViewportContainer/SubViewport/Background") as ColorRect
	if bg == null:
		scene.free()
		return "Background is not a ColorRect"

	scene.free()
	return "ok"


func test_crt_shader_pipeline_controls() -> String:
	var packed: PackedScene = load(MAIN_SCENE_PATH)
	var scene: Node = packed.instantiate()
	var main: Variant = scene

	var container := scene.get_node("ViewportContainer") as SubViewportContainer
	var mat := container.material as ShaderMaterial
	if mat.shader == null:
		scene.free()
		return "ShaderMaterial has no shader loaded"

	# Test toggling CRT
	main.set_crt_enabled(false)
	if main.vector_orrery.crt_enabled != false:
		scene.free()
		return "set_crt_enabled(false) did not update vector_orrery"
	var enabled_param = mat.get_shader_parameter("enabled")
	if enabled_param != false:
		scene.free()
		return "set_crt_enabled(false) did not update shader material"

	main.set_crt_enabled(true)
	if main.vector_orrery.crt_enabled != true:
		scene.free()
		return "set_crt_enabled(true) failed"

	# Test preset change
	main.set_crt_preset("AMBER_P1")
	if main.vector_orrery.current_preset != "AMBER_P1":
		scene.free()
		return "set_crt_preset failed to update orrery preset"

	scene.free()
	return "ok"


func test_binding_run_controller() -> String:
	var packed: PackedScene = load(MAIN_SCENE_PATH)
	var scene: Node = packed.instantiate()
	var main: Variant = scene

	var rc := RunController.new()
	main.initialize_systems(rc)

	if main.controller != rc:
		scene.free()
		return "controller reference mismatch on MainScene"
	if main.hud.controller != rc:
		scene.free()
		return "controller was not bound to OrbitalHUD"
	if main.tactical_map.controller != rc:
		scene.free()
		return "controller was not bound to SolTacticalMap"
	if main.trading_overlay.controller != rc:
		scene.free()
		return "controller was not bound to TradingOverlay"

	var d: Dictionary = main.to_dict()
	if d["has_controller"] != true or d["initialized"] != true:
		scene.free()
		return "to_dict() telemetry invalid: %s" % str(d)

	# Verify unbinding controller (Amos review item #3)
	main.initialize_systems(null)
	if main.controller != null:
		scene.free()
		return "controller was not cleared on initialize_systems(null)"
	if main.hud.controller != null:
		scene.free()
		return "hud controller was not unbound on initialize_systems(null)"

	scene.free()
	return "ok"
