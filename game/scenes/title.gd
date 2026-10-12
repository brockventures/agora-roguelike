class_name TitleScreen
extends Control
## The title screen (#192 animated title screen): the approved key art drifting slowly
## behind a darkened left band, the AGORA wordmark and an HR-voice menu. The whole screen
## runs under the CRT shader the game's own viewport uses (a SubViewportContainer, as
## main.tscn does), and hands off to the game through Main.launch_mode.
##
## Menu input is read here in _input, before the SubViewport sees it: up/down move the
## focus between the buttons, accept presses the focused one. While the settings overlay
## is open the SettingsMenu model takes every event (B closes it).

const KEYART_PATH: String = "res://assets/title/keyart.png"
## The CRT shader main.tscn uses. Same file, not a copy; its uniform defaults match the
## values main.tscn sets, so only `enabled` needs setting here.
const CRT_SHADER_PATH: String = "res://shaders/crt_retro.gdshader"
const MAIN_SCENE_PATH: String = "res://scenes/main.tscn"
const VIEW_SIZE: Vector2i = Vector2i(1280, 800)
## Key art drift: scale 1.00 -> DRIFT_SCALE and offset 0 -> DRIFT_OFFSET over DRIFT_SECONDS,
## then back over the same time, looping. Off under reduced motion.
const DRIFT_SECONDS: float = 40.0
const DRIFT_SCALE: float = 1.06
const DRIFT_OFFSET: Vector2 = Vector2(-24.0, -12.0)
const WORDMARK_SIZE: int = 96
const WORDMARK_OUTLINE_SIZE: int = 3
const WORDMARK_COLOR: Color = Color("e6dcc3")
const WORDMARK_OUTLINE: Color = Color("1a1410")
const SUBTITLE_SIZE: int = 28
const SUBTITLE_SPACING: int = 8
const SUBTITLE_COLOR: Color = Color("4fb3a9")
const BUTTON_SIZE: Vector2 = Vector2(360.0, 56.0)
const BUTTON_FONT_SIZE: int = 22
const FOOTER_SIZE: int = 14
const FOOTER_ALPHA: float = 0.6
const SHADE_COLOR: Color = Color(0.07, 0.06, 0.05)
## Settings rows shown at once; SettingsMenu.text() scrolls the rest with the cursor.

## How the menu leaves the title. The default is the real scene change; tests replace it.
var change_scene: Callable
## Set before the title enters the tree (tests). Created on ready outside headless runs.
var save_store: SaveStore = null
var settings: AccessibilitySettings = AccessibilitySettings.new()
var settings_menu: SettingsMenu = null
## The menu buttons in display order: Begin, Resume, Settings, Clock Out.
var menu_buttons: Array[Button] = []

var _stage: SubViewport = null
var _page: Control = null
var _crt: ShaderMaterial = null
var _art: TextureRect = null
var _continue_button: Button = null
var _settings_button: Button = null
var _settings_panel: Panel = null
var _settings_view: SettingsView = null
var kit: HudKit = HudKit.new()
var _drift: Tween = null


func _init() -> void:
	change_scene = _change_to_scene


func _ready() -> void:
	build_screen()
	_focus_first()


## Builds the whole screen. _ready calls it; tests call it on a node that is not in the
## tree (the headless test runner has no main loop to add it to). Nothing here needs the tree.
func build_screen() -> void:
	Loc.apply_env()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if save_store == null and DisplayServer.get_name() != "headless":
		save_store = SaveStore.new()
	if save_store != null:
		save_store.cloud = SteamService.shared()
		settings = AccessibilitySettings.load_from(save_store)
		settings.apply_all(not _locale_pinned_by_env())
		settings.changed.connect(_on_settings_changed)
	settings_menu = SettingsMenu.new(settings)
	settings_menu.closed.connect(_on_settings_closed)
	_build_stage()
	_build_art()
	_build_column()
	_build_footer()
	_build_settings_panel()
	_apply_crt()
	_continue_button.disabled = not has_usable_run()
	_start_drift()


## True when there is an autosaved run that Main would resume. Same check as
## Main.continue_saved_run(): a run slot exists and it loads cleanly.
func has_usable_run() -> bool:
	if save_store == null or not save_store.has_run():
		return false
	return bool(save_store.load_run()["ok"])


func _input(event: InputEvent) -> void:
	if settings_menu.is_open:
		settings_menu.handle_event(event)
		_refresh_settings()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_down"):
		_move_focus(1)
	elif event.is_action_pressed("ui_up"):
		_move_focus(-1)
	elif event.is_action_pressed("ui_accept"):
		var focused := _stage.gui_get_focus_owner() as Button
		if focused == null or focused.disabled:
			return
		focused.pressed.emit()
	else:
		return
	get_viewport().set_input_as_handled()


func _build_stage() -> void:
	var view := SubViewportContainer.new()
	view.stretch = true
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_crt = ShaderMaterial.new()
	_crt.shader = load(CRT_SHADER_PATH)
	view.material = _crt
	add_child(view)
	_stage = SubViewport.new()
	_stage.size = VIEW_SIZE
	view.add_child(_stage)
	_page = Control.new()
	_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_page.theme = HudTheme.load_theme()
	_stage.add_child(_page)


func _build_art() -> void:
	var holder := Control.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.clip_contents = true
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_page.add_child(holder)
	_art = TextureRect.new()
	_art.texture = load(KEYART_PATH)
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art.resized.connect(func() -> void: _art.pivot_offset = _art.size * 0.5)
	holder.add_child(_art)
	# The darkened left band behind the text: black at the left edge, clear by 45% across.
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color(SHADE_COLOR, 0.92), Color(SHADE_COLOR, 0.0)])
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 256
	tex.height = 4
	tex.fill_from = Vector2(0.0, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	var shade := TextureRect.new()
	shade.texture = tex
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.anchor_right = 0.45
	shade.offset_right = 0.0
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(shade)


func _build_column() -> void:
	var col := VBoxContainer.new()
	col.anchor_top = 0.5
	col.anchor_bottom = 0.5
	col.anchor_right = 0.36
	col.offset_left = 80.0
	col.offset_top = -280.0
	col.offset_bottom = 280.0
	col.grow_vertical = Control.GROW_DIRECTION_BOTH
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 6)
	_page.add_child(col)

	var word := Label.new()
	word.text = Loc.t("HUD_TITLE")
	word.add_theme_font_size_override("font_size", WORDMARK_SIZE)
	word.add_theme_color_override("font_color", WORDMARK_COLOR)
	word.add_theme_color_override("font_outline_color", WORDMARK_OUTLINE)
	word.add_theme_constant_override("outline_size", WORDMARK_OUTLINE_SIZE)
	col.add_child(word)

	var sub := Label.new()
	sub.text = Loc.t("TITLE_SUBTITLE")
	var spaced := FontVariation.new()
	spaced.base_font = load(HudTheme.FONT_PATH)
	spaced.spacing_glyph = SUBTITLE_SPACING
	sub.add_theme_font_override("font", spaced)
	sub.add_theme_font_size_override("font_size", SUBTITLE_SIZE)
	sub.add_theme_color_override("font_color", SUBTITLE_COLOR)
	col.add_child(sub)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0.0, 36.0)
	col.add_child(gap)

	var menu := VBoxContainer.new()
	menu.add_theme_constant_override("separation", 12)
	col.add_child(menu)
	_menu_button(menu, "TITLE_NEW", _on_new_pressed)
	_continue_button = _menu_button(menu, "TITLE_CONTINUE", _on_continue_pressed)
	_settings_button = _menu_button(menu, "TITLE_SETTINGS", _on_settings_pressed)
	_menu_button(menu, "TITLE_QUIT", _on_quit_pressed)


func _menu_button(parent: Control, key: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = Loc.t(key)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = BUTTON_SIZE
	b.add_theme_font_size_override("font_size", BUTTON_FONT_SIZE)
	b.pressed.connect(handler)
	parent.add_child(b)
	menu_buttons.append(b)
	return b


func _build_footer() -> void:
	var foot := Label.new()
	foot.text = Loc.t("TITLE_FOOTER")
	foot.add_theme_font_size_override("font_size", FOOTER_SIZE)
	foot.add_theme_color_override("font_color", Color(WORDMARK_COLOR, FOOTER_ALPHA))
	foot.anchor_top = 1.0
	foot.anchor_bottom = 1.0
	foot.offset_left = 80.0
	foot.offset_top = -48.0
	foot.offset_right = 900.0
	foot.offset_bottom = -16.0
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_page.add_child(foot)


func _build_settings_panel() -> void:
	_settings_panel = Panel.new()
	HudTheme.style_panel(_settings_panel, "ModalPanel")
	_settings_panel.anchor_left = 0.5
	_settings_panel.anchor_right = 0.5
	_settings_panel.anchor_top = 0.5
	_settings_panel.anchor_bottom = 0.5
	_settings_panel.offset_left = -520.0
	_settings_panel.offset_right = 520.0
	_settings_panel.offset_top = -310.0
	_settings_panel.offset_bottom = 310.0
	_settings_panel.visible = false
	_page.add_child(_settings_panel)
	_settings_view = SettingsView.new()
	_settings_panel.add_child(_settings_view)
	_settings_view.setup(settings_menu, kit, Vector2(1040.0, 620.0))


func _start_drift() -> void:
	if settings.reduced_motion:
		return
	_drift = create_tween().set_loops()
	_drift.tween_property(_art, "scale", Vector2.ONE * DRIFT_SCALE, DRIFT_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_drift.parallel().tween_property(_art, "position", DRIFT_OFFSET, DRIFT_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_drift.tween_property(_art, "scale", Vector2.ONE, DRIFT_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_drift.parallel().tween_property(_art, "position", Vector2.ZERO, DRIFT_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _apply_crt() -> void:
	if _crt != null:
		_crt.set_shader_parameter("enabled", settings.crt_filter)


func _focus_first() -> void:
	for b in menu_buttons:
		if not b.disabled:
			b.grab_focus()
			return


func _move_focus(dir: int) -> void:
	var live: Array[Button] = []
	for b in menu_buttons:
		if not b.disabled:
			live.append(b)
	if live.is_empty():
		return
	var cur: int = live.find(_stage.gui_get_focus_owner())
	var next: int = 0 if cur < 0 else posmod(cur + dir, live.size())
	live[next].grab_focus()


func _refresh_settings() -> void:
	if _settings_panel == null:
		return
	_settings_panel.visible = settings_menu.is_open
	if settings_menu.is_open:
		kit.apply_scale(settings.text_scale)
		_settings_view.refresh()


func _on_settings_changed() -> void:
	settings.apply_all(not _locale_pinned_by_env())
	_apply_crt()
	if save_store != null:
		settings.save(save_store)


func _on_settings_closed() -> void:
	_refresh_settings()
	if is_inside_tree():
		_settings_button.grab_focus()


func _on_new_pressed() -> void:
	_launch("new")


func _on_continue_pressed() -> void:
	_launch("continue")


func _on_settings_pressed() -> void:
	settings_menu.open()
	_refresh_settings()


func _on_quit_pressed() -> void:
	get_tree().quit()


## Tells Main which way to start, then leaves for the game scene.
func _launch(mode: String) -> void:
	MainScene.launch_mode = mode
	change_scene.call(MAIN_SCENE_PATH)


func _change_to_scene(path: String) -> void:
	get_tree().change_scene_to_file(path)


## Same test Main applies to the environment locale pins.
func _locale_pinned_by_env() -> bool:
	return OS.get_environment(Loc.PSEUDO_ENV) in ["1", "true", "yes"] or OS.get_environment(Loc.LOCALE_ENV) != ""
