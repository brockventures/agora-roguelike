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
var loop: M0Loop = null

# Visual node references
var viewport_container: SubViewportContainer = null
var sub_viewport: SubViewport = null
var background: ColorRect = null
var hud_container: Control = null
var header_panel: Panel = null
var tactical_map_panel: Panel = null
var sidebar_panel: Panel = null
var ticker_panel: Panel = null

# Readouts and audio players, built in _ready (a scene instantiated outside the
# tree, as the unit tests do, never creates them).
var header_label: Label = null
var sidebar_label: Label = null
var ticker_label: Label = null
var map_label: Label = null
var market_modal: Panel = null
var market_label: Label = null
var resolution_modal: Panel = null
var resolution_label: Label = null
var sfx_players: Array[AudioStreamPlayer] = []
var drone_player: AudioStreamPlayer = null

## Starting seed for the run MainScene creates when none was bound.
const DEFAULT_RUN_SEED: int = 84
const SFX_POLYPHONY: int = 4

var is_initialized: bool = false


func _init() -> void:
	custom_minimum_size = VIEWPORT_SIZE
	initialize_systems()


func _ready() -> void:
	_resolve_child_nodes()
	_setup_crt_pipeline()
	if controller == null:
		start_new_run(DEFAULT_RUN_SEED)
	_build_readouts()
	_setup_audio()
	_refresh_readouts()


## Advances the SimClock at the selected speed; pause (or an overlay) stops it.
func _process(delta: float) -> void:
	if loop == null:
		return
	loop.advance(delta)
	_refresh_readouts()


## _input rather than _unhandled_input: the SubViewportContainer forwards
## non-mouse events into its SubViewport, and Main sees them first this way.
func _input(event: InputEvent) -> void:
	if handle_input(event):
		get_viewport().set_input_as_handled()


## Routes an InputEvent to the game loop (m0_* InputMap actions). True if consumed.
func handle_input(event: InputEvent) -> bool:
	return loop != null and loop.handle_input(event)


## Creates a fresh RunController and binds it to the HUD, loop and clock.
func start_new_run(p_seed: int = DEFAULT_RUN_SEED) -> RunController:
	var rc := RunController.new(null, p_seed)
	initialize_systems(rc)
	return rc


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
	if loop == null:
		loop = M0Loop.new(hud)
	else:
		loop.rebind_controller()
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
		"loop": loop.to_dict() if loop != null else {},
	}


# --- Audio (headless-safe: players are only driven while inside the tree) ---

func _setup_audio() -> void:
	if tactile_audio == null or not sfx_players.is_empty():
		return
	for i in SFX_POLYPHONY:
		var p := AudioStreamPlayer.new()
		p.name = "Sfx%d" % i
		add_child(p)
		sfx_players.append(p)
	drone_player = AudioStreamPlayer.new()
	drone_player.name = "Drone"
	drone_player.stream = tactile_audio.get_or_generate_waveform(TactileAudio.DRONE_TENSION)
	drone_player.bus = _bus_or_master(TactileAudio.BUS_AMBIENT)
	add_child(drone_player)
	tactile_audio.sound_played.connect(_on_sound_played)
	tactile_audio.tension_level_changed.connect(_on_tension_changed)
	_apply_drone(tactile_audio.current_drone_volume_db)
	if is_inside_tree():
		drone_player.play()


func _bus_or_master(bus_name: String) -> String:
	return bus_name if AudioServer.get_bus_index(bus_name) >= 0 else "Master"


func _on_sound_played(sound_id: String, bus: String, volume_db: float, pitch: float) -> void:
	if sound_id == TactileAudio.DRONE_TENSION or not is_inside_tree():
		return
	for p in sfx_players:
		if not p.playing:
			p.stream = tactile_audio.get_or_generate_waveform(sound_id)
			p.bus = _bus_or_master(bus)
			p.volume_db = volume_db
			p.pitch_scale = pitch
			p.play()
			return


func _on_tension_changed(_stage: int, _freq: float) -> void:
	_apply_drone(tactile_audio.current_drone_volume_db)


## Drone pitch follows the Doomsday stage frequency, volume its loudness curve.
func _apply_drone(volume_db: float) -> void:
	if drone_player == null:
		return
	drone_player.pitch_scale = tactile_audio.get_drone_pitch_scale()
	drone_player.volume_db = volume_db


# --- Readouts ---

func _make_label(parent: Control, rect: Rect2, size: int = 16) -> Label:
	var l := Label.new()
	l.position = rect.position
	l.size = rect.size
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(0.55, 1.0, 0.7))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _build_readouts() -> void:
	if hud_container == null or header_label != null:
		return
	header_label = _make_label(header_panel, Rect2(16, 6, 1248, 56), 18)
	map_label = _make_label(tactical_map_panel, Rect2(16, 8, 848, 120), 16)
	sidebar_label = _make_label(sidebar_panel, Rect2(16, 8, 368, 656), 16)
	ticker_label = _make_label(ticker_panel, Rect2(16, 6, 1248, 52), 16)
	tactical_map_panel.draw.connect(_draw_map)
	market_modal = Panel.new()
	market_modal.position = OrbitalHUD.MODAL_OVERLAY_RECT.position
	market_modal.size = OrbitalHUD.MODAL_OVERLAY_RECT.size
	hud_container.add_child(market_modal)
	market_label = _make_label(market_modal, Rect2(20, 16, 840, 528), 18)
	resolution_modal = Panel.new()
	resolution_modal.position = Vector2(340, 240)
	resolution_modal.size = Vector2(600, 320)
	hud_container.add_child(resolution_modal)
	resolution_label = _make_label(resolution_modal, Rect2(20, 16, 560, 288), 20)
	resolution_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))


func _draw_map() -> void:
	if tactical_map == null or tactical_map_panel == null:
		return
	var origin: Vector2 = OrbitalHUD.TACTICAL_MAP_RECT.position
	var round_num: int = controller.get_current_round() if controller != null else 0
	var center: Vector2 = SolTacticalMap.MAP_CENTER - origin
	tactical_map_panel.draw_circle(center, SolTacticalMap.SOL_NODE_RADIUS_PX, Color(1.0, 0.85, 0.3))
	for st in tactical_map.get_stations():
		var pos: Vector2 = tactical_map.get_station_screen_pos(st, round_num) - origin
		tactical_map_panel.draw_arc(center, pos.distance_to(center), 0.0, TAU, 96, Color(0.2, 0.5, 0.35), 1.0)
		var col := Color(0.4, 1.0, 0.6) if st == hud.active_station else Color(0.3, 0.7, 0.5)
		tactical_map_panel.draw_circle(pos, SolTacticalMap.STATION_NODE_RADIUS_PX, col)
		tactical_map_panel.draw_string(ThemeDB.fallback_font, pos + Vector2(18, 5), StationMarket.station_name(st).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)


func _refresh_readouts() -> void:
	if header_label == null or hud == null or loop == null:
		return
	var h: Dictionary = hud.get_header_telemetry()
	var secs: int = int(h["ticks_remaining"]) / DoomsdayClock.DEFAULT_TICKS_PER_SECOND
	var tabs: PackedStringArray = []
	for i in M0Loop.TAB_NAMES.size():
		tabs.append("[%s]" % M0Loop.TAB_NAMES[i] if i == int(loop.tab) else M0Loop.TAB_NAMES[i])
	header_label.text = "AGORA   CR %s   DEBT %s   DOOMSDAY %d:%02d %s   SPEED %s\n%s     LB/RB tab   LT/RT station   A buy/sell   B back   X Chapter 11   Y speed" % [
		_fmt(int(h["cr"])), _fmt(int(h["total_debt"])), secs / 60, secs % 60, h["stage_name"], h["speed_label"], "  ".join(tabs)]
	map_label.text = _fleet_text() if loop.tab == M0Loop.Tab.FLEET else "SOL TACTICAL MAP   docked: %s" % StationMarket.station_name(controller.docked_at)
	sidebar_label.text = _sidebar_text()
	var lines: PackedStringArray = []
	for item in hud.get_recent_headlines(2):
		lines.append("%s: %s" % [item["category"], item["text"]])
	ticker_label.text = "\n".join(lines)
	market_modal.visible = hud.is_trading_overlay_open() and loop.overlay_state == M0Loop.OVERLAY_NONE
	market_label.text = _board_text() if market_modal.visible else ""
	resolution_modal.visible = loop.overlay_state != M0Loop.OVERLAY_NONE
	resolution_label.text = _resolution_text() if resolution_modal.visible else ""
	tactical_map_panel.queue_redraw()


func _sidebar_text() -> String:
	var side: Dictionary = hud.get_sidebar_telemetry()
	var ladder: Dictionary = side["order_book_ladder"]
	var f: GamepadFocus = hud.gamepad_focus
	var buying: bool = f.active_side == GamepadFocus.OrderSide.BUY
	var out: PackedStringArray = []
	out.append("%s  %s" % [StationMarket.station_name(hud.active_station).to_upper(), hud.active_commodity])
	out.append("")
	var asks: Array = ladder["asks"]
	for i in range(asks.size() - 1, -1, -1):
		out.append("%s ASK %6.1f  x%d" % [">" if buying and i == f.ladder_index else " ", asks[i]["price"], asks[i]["quantity"]])
	out.append("---- spread %.1f ----" % float(ladder["spread"]))
	var bids: Array = ladder["bids"]
	for i in bids.size():
		out.append("%s BID %6.1f  x%d" % [">" if not buying and i == f.ladder_index else " ", bids[i]["price"], bids[i]["quantity"]])
	out.append("")
	out.append("ORDER  %s  qty %d" % ["BUY" if buying else "SELL", f.order_qty])
	out.append("HELD   %d %s   CARGO %d/%d" % [hud.get_cargo_qty(hud.active_commodity), hud.active_commodity, controller.get_total_cargo(), controller.cargo_capacity])
	if f.last_rejection_reason != "":
		out.append("REJECTED: " + f.last_rejection_reason)
	elif not f.last_executed_order.is_empty():
		var o: Dictionary = f.last_executed_order
		out.append("FILLED %s %d @ %.1f" % [o["side"], o["qty"], o["price"]])
	return "\n".join(out)


func _board_text() -> String:
	var out: PackedStringArray = ["%s QUOTES" % StationMarket.station_name(hud.active_station).to_upper(), ""]
	for c in Transit.COMMODITIES:
		var key_prefix: String = "%-10s" % c
		if loop.market.has_book(hud.active_station, c):
			var lad: Dictionary = loop.market.ladder(hud.active_station, c, 1)
			out.append("%s BID %6.1f   ASK %6.1f" % [key_prefix, lad["best_bid"], lad["best_ask"]])
		else:
			out.append("%s base %6.1f   (no live book)" % [key_prefix, Transit.BASE_PRICES[hud.active_station][c]])
	return "\n".join(out)


func _fleet_text() -> String:
	var parts: PackedStringArray = ["FLEET   hulls: %d" % controller.ships.size()]
	for c in controller.cargo:
		parts.append("  %s x%d" % [c, int(controller.cargo[c])])
	return "\n".join(parts)


func _resolution_text() -> String:
	if loop.overlay_state == M0Loop.OVERLAY_CHAPTER_11:
		var a: Dictionary = controller.assess()
		return "CHAPTER 11\n\nInsolvent: debt %s exceeds liquidation value %s.\nThe clock is halted.\n\nPress X to file and found a new corp." % [_fmt(int(a["total_debt"])), _fmt(int(a["liquidation_value"]))]
	return "SOVEREIGN DEFAULT\n\nThe Doomsday Clock has run out. Run collapsed."


static func _fmt(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out
