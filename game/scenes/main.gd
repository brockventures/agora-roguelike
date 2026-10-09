class_name MainScene
extends Control
## Root Scene Controller for Agora Roguelike (M0 Vertical Slice #83).
##
## Assembles the decoupled presentation models and CRT retro shader pipeline
## into a unified 1280x800 Steam Deck viewport using SubViewportContainer.

## Native Steam Deck viewport geometry.
const VIEWPORT_WIDTH: float = 1280.0
const VIEWPORT_HEIGHT: float = 800.0
const VIEWPORT_SIZE: Vector2 = Vector2(VIEWPORT_WIDTH, VIEWPORT_HEIGHT)

# Core presentation models
var hud: OrbitalHUD = null
var vector_orrery: VectorOrrery = null
var tactical_map: SolTacticalMap = null
var trading_overlay: TradingOverlay = null
var tactile_audio: TactileAudio = null
var gamepad_focus: GamepadFocus = null
var controller: RunController = null

# Visual node references
var viewport_container: SubViewportContainer = null
var sub_viewport: SubViewport = null
var background: ColorRect = null
var hud_container: Control = null
var header_panel: Panel = null
var tactical_map_panel: Panel = null
var sidebar_panel: Panel = null
var ticker_panel: Panel = null

var is_initialized: bool = false


func _init() -> void:
	custom_minimum_size = VIEWPORT_SIZE
	initialize_systems()


func _ready() -> void:
	_resolve_child_nodes()
	_setup_crt_pipeline()


func initialize_systems(p_controller: RunController = null) -> void:
	controller = p_controller
	if hud == null:
		hud = OrbitalHUD.new(controller)
	elif controller != null:
		hud.bind_controller(controller)
	else:
		hud.unbind_controller()

	tactical_map = hud.tactical_map
	trading_overlay = hud.trading_overlay
	gamepad_focus = hud.gamepad_focus
	vector_orrery = hud.vector_orrery
	tactile_audio = hud.tactile_audio
	is_initialized = true


func _resolve_child_nodes() -> void:
	if viewport_container == null and has_node("ViewportContainer"):
		viewport_container = get_node("ViewportContainer") as SubViewportContainer
	if sub_viewport == null and has_node("ViewportContainer/SubViewport"):
		sub_viewport = get_node("ViewportContainer/SubViewport") as SubViewport
	if background == null and has_node("ViewportContainer/SubViewport/Background"):
		background = get_node("ViewportContainer/SubViewport/Background") as ColorRect
	if hud_container == null and has_node("ViewportContainer/SubViewport/HUDContainer"):
		hud_container = get_node("ViewportContainer/SubViewport/HUDContainer") as Control
		if hud_container.has_node("HeaderPanel"):
			header_panel = hud_container.get_node("HeaderPanel") as Panel
		if hud_container.has_node("TacticalMapPanel"):
			tactical_map_panel = hud_container.get_node("TacticalMapPanel") as Panel
		if hud_container.has_node("SidebarPanel"):
			sidebar_panel = hud_container.get_node("SidebarPanel") as Panel
		if hud_container.has_node("TickerPanel"):
			ticker_panel = hud_container.get_node("TickerPanel") as Panel


func get_viewport_container() -> SubViewportContainer:
	if viewport_container == null and has_node("ViewportContainer"):
		viewport_container = get_node("ViewportContainer") as SubViewportContainer
	return viewport_container


func _setup_crt_pipeline() -> void:
	var container := get_viewport_container()
	if container != null and container.material is ShaderMaterial:
		var mat := container.material as ShaderMaterial
		if vector_orrery != null:
			var uniforms: Dictionary = vector_orrery.get_crt_shader_uniforms()
			for key: String in uniforms:
				mat.set_shader_parameter(key, uniforms[key])


func set_crt_enabled(p_enabled: bool) -> void:
	if vector_orrery != null:
		vector_orrery.crt_enabled = p_enabled
	var container := get_viewport_container()
	if container != null and container.material is ShaderMaterial:
		var mat := container.material as ShaderMaterial
		mat.set_shader_parameter("enabled", p_enabled)


func set_crt_preset(preset_name: String) -> void:
	if vector_orrery != null:
		vector_orrery.set_preset(preset_name)
		_setup_crt_pipeline()


func get_layout_bounds() -> Dictionary:
	return {
		"viewport_width": VIEWPORT_WIDTH,
		"viewport_height": VIEWPORT_HEIGHT,
		"header_rect": OrbitalHUD.HEADER_RECT,
		"tactical_map_rect": OrbitalHUD.TACTICAL_MAP_RECT,
		"sidebar_rect": OrbitalHUD.SIDEBAR_RECT,
		"ticker_rect": OrbitalHUD.TICKER_RECT,
		"modal_overlay_rect": OrbitalHUD.MODAL_OVERLAY_RECT,
	}


func to_dict() -> Dictionary:
	return {
		"viewport": {
			"width": VIEWPORT_WIDTH,
			"height": VIEWPORT_HEIGHT,
		},
		"initialized": is_initialized,
		"hud": hud.to_dict() if hud != null else {},
		"orrery": vector_orrery.to_dict() if vector_orrery != null else {},
		"has_controller": controller != null,
	}
