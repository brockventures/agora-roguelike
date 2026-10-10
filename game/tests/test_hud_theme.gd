extends RefCounted
## Epic 6 HUD re-skin sample (#105): the Theme resource loads with the panel styles, and
## the CRT filter (shader, scanlines, chromatic fringe) is off by default.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"


func test_theme_loads_with_ink_outlined_panels() -> String:
	var theme: Theme = HudTheme.load_theme()
	if theme == null:
		return "hud_theme.tres did not load as a Theme"
	for variation in ["HeaderPanel", "MapPanel", "SidebarPanel", "TickerPanel"]:
		var box := theme.get_stylebox("panel", variation) as StyleBoxFlat
		if box == null:
			return "%s has no flat panel style" % variation
		if box.border_width_left < 3 or Vector3(box.border_color.r - HudTheme.INK.r, box.border_color.g - HudTheme.INK.g, box.border_color.b - HudTheme.INK.b).length() > 0.01:
			return "%s lacks a heavy ink contour" % variation
	return "ok"


func test_main_scene_applies_the_theme_to_the_hud() -> String:
	var scene: Node = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	var hud := scene.get_node("ViewportContainer/SubViewport/HUDContainer") as Control
	var ok: bool = hud.theme != null and hud.theme == HudTheme.load_theme()
	var variation: String = String(scene.get_node("ViewportContainer/SubViewport/HUDContainer/TacticalMapPanel").theme_type_variation)
	scene.free()
	if not ok:
		return "HUDContainer does not carry hud_theme.tres"
	if variation != "MapPanel":
		return "map panel variation is %s" % variation
	return "ok"


func test_crt_filter_is_off_by_default() -> String:
	var scene: Node = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	var main: Variant = scene
	var mat := (scene.get_node("ViewportContainer") as SubViewportContainer).material as ShaderMaterial
	var scene_flag: Variant = mat.get_shader_parameter("enabled")
	var model_flag: bool = main.vector_orrery.crt_enabled
	scene.free()
	if scene_flag != false:
		return "scene CRT shader is enabled by default"
	if model_flag:
		return "VectorOrrery.crt_enabled is true by default"
	return "ok"
