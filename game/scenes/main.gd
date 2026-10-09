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
var ticker_clip: Control = null
var ticker_labels: Array[Label] = []
var map_label: Label = null
## Shared readable palette: every HUD label and every opaque modal body uses these.
const HUD_TEXT_COLOR := Color(0.55, 1.0, 0.7)
const MODAL_BG_COLOR := Color(0.02, 0.06, 0.04, 0.97)

var market_modal: Panel = null
var market_label: Label = null
var resolution_modal: Panel = null
var resolution_label: Label = null
var sfx_players: Array[AudioStreamPlayer] = []
var drone_player: AudioStreamPlayer = null
var market_highlight: ColorRect = null
## Per-voice bookkeeping for stealing: play order and whether it carries a priority sound.
var _voice_order: Array[int] = []
var _voice_priority: Array[bool] = []
var _voice_counter: int = 0

## Starting seed for the run MainScene creates when none was bound.
const DEFAULT_RUN_SEED: int = 84
## Chapter 11 resolution modal; the collapse screens use the larger market modal rect.
const RESOLUTION_RECT: Rect2 = Rect2(340.0, 240.0, 600.0, 320.0)
## Voices for routine UI feedback. PRIORITY_VOICES more are reserved for alarms and
## market bells, which may also steal the oldest routine voice if all are busy.
const SFX_POLYPHONY: int = 4
const PRIORITY_VOICES: int = 2

## Controls hint shown under the header readout.
const CONTROLS_HINT: String = "LB/RB tab  R-stick commodity  D-pad ladder/qty  A buy/sell  B back  X Ch.11  Y speed"

var is_initialized: bool = false

## Persistence (#35). Null until enable_persistence(); headless runs (tests,
## smoke) never enable it, so they never touch the real user:// directory.
var save_store: SaveStore = null
## The marble bags backing bad-luck protection; saved and restored with the run.
var bags: Bags = null
var _loaded_profile: MetaProfile = null
var _saved_profile_dict: Dictionary = {}


func _init() -> void:
	custom_minimum_size = VIEWPORT_SIZE
	initialize_systems()


func _ready() -> void:
	_resolve_child_nodes()
	_setup_crt_pipeline()
	if save_store == null and DisplayServer.get_name() != "headless":
		enable_persistence(SaveStore.new())
	if controller == null:
		# Resume the autosaved run when there is a usable one, else start fresh.
		if not continue_saved_run():
			start_new_run(DEFAULT_RUN_SEED)
	_build_readouts()
	_setup_audio()
	_refresh_readouts()


## Advances the SimClock at the selected speed; pause (or an overlay) stops it.
func _process(delta: float) -> void:
	if loop == null:
		return
	loop.advance(delta)
	if hud != null:
		hud.advance_ticker(delta)
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
	var rc := RunController.new(_loaded_profile, p_seed)
	bags = Bags.new("m0", null, p_seed)
	initialize_systems(rc)
	return rc


# --- Persistence (#35) ---

## Turns on autosave (each round advance, profile changes, quit) and loads the
## persisted MetaProfile so the next new run starts with its perks.
func enable_persistence(store: SaveStore) -> void:
	save_store = store
	_loaded_profile = store.load_profile()
	if _loaded_profile != null:
		_saved_profile_dict = _loaded_profile.to_dict()
	if not loop.round_completed.is_connected(_on_round_completed):
		loop.round_completed.connect(_on_round_completed)
		loop.action_handled.connect(_on_action_handled)


## Replaces the current run with the one in the run slot. False (and nothing
## changed) when persistence is off or the slot is missing, corrupt, or from an
## unsupported schema version.
func continue_saved_run() -> bool:
	if save_store == null or not save_store.has_run():
		return false
	var r: Dictionary = save_store.load_run()
	if not bool(r["ok"]):
		push_warning("run save ignored: %s" % str(r["error"]))
		return false
	var rc: RunController = r["controller"]
	bags = r["bags"]
	initialize_systems(rc)
	loop.set_market(r["market"])
	return true


## Writes the profile and the run slot. Returns true when both writes succeeded.
func save_all() -> bool:
	if save_store == null or controller == null:
		return false
	if bags == null:
		bags = Bags.new("m0", null, controller.run_seed)
	var ok: bool = _save_profile()
	if save_store.save_run(controller, loop.market, bags) != OK:
		push_warning("run autosave failed")
		ok = false
	return ok


func _save_profile() -> bool:
	if save_store == null or controller == null:
		return false
	var err: Error = save_store.save_profile(controller.profile)
	if err != OK:
		push_warning("profile save failed: error %d" % err)
		return false
	_saved_profile_dict = controller.profile.to_dict()
	return true


func _on_round_completed(_round_num: int) -> void:
	save_all()


## Perks are bought while the run is over; persist the profile as soon as it changes.
func _on_action_handled(_action: String) -> void:
	if controller != null and controller.profile.to_dict() != _saved_profile_dict:
		_save_profile()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_all()


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
	# M0 is one station: Mars (Arcadia Foundries). Dock there and disable station cycling.
	loop.lock_station(M0Loop.M0_STATION)
	if not loop.run_restarted.is_connected(_on_run_restarted):
		loop.run_restarted.connect(_on_run_restarted)
	is_initialized = true


## The collapse flow replaced the run: follow the loop's new controller.
func _on_run_restarted(rc: RunController) -> void:
	controller = rc
	bags = Bags.new("m0", null, rc.run_seed)
	tactical_map = hud.tactical_map
	trading_overlay = hud.trading_overlay
	vector_orrery = hud.vector_orrery


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
	for i in SFX_POLYPHONY + PRIORITY_VOICES:
		var p := AudioStreamPlayer.new()
		p.name = "Sfx%d" % i
		add_child(p)
		sfx_players.append(p)
		_voice_order.append(0)
		_voice_priority.append(false)
	drone_player = AudioStreamPlayer.new()
	drone_player.name = "Drone"
	drone_player.stream = tactile_audio.get_or_generate_waveform(TactileAudio.DRONE_TENSION)
	drone_player.bus = _bus_or_master(TactileAudio.BUS_AMBIENT)
	add_child(drone_player)
	tactile_audio.sound_played.connect(_on_sound_played)
	tactile_audio.bus_volume_changed.connect(_on_bus_volume_changed)
	tactile_audio.bus_mute_changed.connect(_on_bus_mute_changed)
	sync_audio_buses()
	tactile_audio.tension_level_changed.connect(_on_tension_changed)
	_apply_drone(tactile_audio.current_drone_volume_db)
	if is_inside_tree():
		drone_player.play()


func _bus_or_master(bus_name: String) -> String:
	return bus_name if AudioServer.get_bus_index(bus_name) >= 0 else "Master"


## Pushes the model's volumes and mutes onto the AudioServer buses declared in
## res://default_bus_layout.tres. Players then play at their dB offset only; the
## bus carries the volume. Buses missing from the layout are skipped.
func sync_audio_buses() -> void:
	if tactile_audio == null:
		return
	for bus_name in TactileAudio.ALL_BUSES:
		_on_bus_volume_changed(bus_name, tactile_audio.get_bus_volume(bus_name))
		_on_bus_mute_changed(bus_name, tactile_audio.is_bus_muted(bus_name))


func _on_bus_volume_changed(bus_name: String, volume: float) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(0.0001, volume)))


func _on_bus_mute_changed(bus_name: String, muted: bool) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		AudioServer.set_bus_mute(idx, muted)


## Chooses the sfx voice for a sound, or -1 to drop it. Routine sounds use only the
## first SFX_POLYPHONY voices and are dropped when those are busy. Priority sounds
## (alarms, market bells) may use any free voice, else steal the oldest routine
## voice, else the oldest voice of all.
func pick_sfx_voice(priority: bool) -> int:
	var busy: Array[bool] = []
	for p in sfx_players:
		busy.append(p.playing)
	return choose_sfx_voice(priority, busy)


## Pure voice choice over a busy mask (index per voice); see pick_sfx_voice.
func choose_sfx_voice(priority: bool, busy: Array[bool]) -> int:
	var routine_count: int = mini(SFX_POLYPHONY, busy.size())
	var limit: int = busy.size() if priority else routine_count
	for i in limit:
		if not busy[i]:
			return i
	if not priority:
		return -1
	var best: int = -1
	for i in busy.size():
		if not _voice_priority[i] and (best == -1 or _voice_order[i] < _voice_order[best]):
			best = i
	if best == -1:
		for i in busy.size():
			if best == -1 or _voice_order[i] < _voice_order[best]:
				best = i
	return best


func _on_sound_played(sound_id: String, bus: String, volume_db: float, pitch: float) -> void:
	if sound_id == TactileAudio.DRONE_TENSION or not is_inside_tree():
		return
	var priority: bool = tactile_audio.is_priority_sound(sound_id)
	var v: int = pick_sfx_voice(priority)
	if v < 0:
		return
	var p: AudioStreamPlayer = sfx_players[v]
	p.stream = tactile_audio.get_or_generate_waveform(sound_id)
	p.bus = _bus_or_master(bus)
	# The AudioServer bus applies the model's bus/master volume; only the offset
	# (and pitch jitter) belongs on the player. Without the bus, keep the full dB.
	p.volume_db = volume_db - (tactile_audio.get_bus_base_db(bus) if AudioServer.get_bus_index(bus) >= 0 else 0.0)
	p.pitch_scale = pitch
	p.play()
	_voice_counter += 1
	_voice_order[v] = _voice_counter
	_voice_priority[v] = priority


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
	l.add_theme_color_override("font_color", HUD_TEXT_COLOR)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _build_readouts() -> void:
	if hud_container == null or header_label != null:
		return
	header_label = _make_label(header_panel, Rect2(16, 6, 1248, 56), 18)
	map_label = _make_label(tactical_map_panel, Rect2(16, 8, 848, 120), 16)
	sidebar_label = _make_label(sidebar_panel, Rect2(16, 8, 368, 656), 16)
	ticker_clip = Control.new()
	ticker_clip.position = Vector2(16, 6)
	ticker_clip.size = Vector2(OrbitalHUD.TICKER_VIEW_WIDTH, 52)
	ticker_clip.clip_contents = true
	ticker_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ticker_panel.add_child(ticker_clip)
	for i in OrbitalHUD.TICKER_VISIBLE_LINES:
		var tl := _make_label(ticker_clip, Rect2(0, i * 24, 4096, 24), 16)
		tl.autowrap_mode = TextServer.AUTOWRAP_OFF
		ticker_labels.append(tl)
	tactical_map_panel.clip_contents = true
	tactical_map_panel.draw.connect(_draw_map)
	market_modal = Panel.new()
	market_modal.position = OrbitalHUD.MODAL_OVERLAY_RECT.position
	market_modal.size = OrbitalHUD.MODAL_OVERLAY_RECT.size
	hud_container.add_child(market_modal)
	market_highlight = ColorRect.new()
	market_highlight.color = Color(0.2, 0.6, 0.4, 0.35)
	market_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	market_modal.add_child(market_highlight)
	market_label = _make_label(market_modal, Rect2(20, 16, OrbitalHUD.MODAL_OVERLAY_RECT.size.x - 40.0, OrbitalHUD.MODAL_OVERLAY_RECT.size.y - 32.0), 18)
	resolution_modal = Panel.new()
	var opaque := StyleBoxFlat.new()
	opaque.bg_color = MODAL_BG_COLOR
	opaque.border_color = Color(0.3, 0.8, 0.5)
	opaque.set_border_width_all(2)
	resolution_modal.add_theme_stylebox_override("panel", opaque)
	resolution_modal.position = RESOLUTION_RECT.position
	resolution_modal.size = RESOLUTION_RECT.size
	hud_container.add_child(resolution_modal)
	resolution_label = _make_label(resolution_modal, Rect2(20, 16, 560, 288), 20)
	# Body text keeps the shared HUD phosphor green (_make_label). A red override here
	# was unreadable on the dark panel once the CRT aberration split its channels.


func _draw_map() -> void:
	if tactical_map == null or tactical_map_panel == null:
		return
	var origin: Vector2 = OrbitalHUD.TACTICAL_MAP_RECT.position
	var round_num: int = controller.get_current_round() if controller != null else 0
	var center: Vector2 = SolTacticalMap.MAP_CENTER - origin
	# The panel clips to its own rect; the projection is sized to fit it.
	tactical_map_panel.draw_circle(center, SolTacticalMap.SOL_NODE_RADIUS_PX, Color(1.0, 0.85, 0.3))
	for st in tactical_map.get_stations():
		var pos: Vector2 = tactical_map.get_station_screen_pos(st, round_num) - origin
		tactical_map_panel.draw_arc(center, pos.distance_to(center), 0.0, TAU, 96, Color(0.2, 0.5, 0.35), 1.0)
		var col := Color(0.4, 1.0, 0.6) if st == hud.active_station else Color(0.3, 0.7, 0.5)
		tactical_map_panel.draw_circle(pos, SolTacticalMap.STATION_NODE_RADIUS_PX, col)
		tactical_map_panel.draw_string(ThemeDB.fallback_font, pos + SolTacticalMap.get_label_offset(st), StationMarket.station_name(st).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)


func _refresh_readouts() -> void:
	if header_label == null or hud == null or loop == null:
		return
	var h: Dictionary = hud.get_header_telemetry()
	var secs: int = int(h["ticks_remaining"]) / DoomsdayClock.DEFAULT_TICKS_PER_SECOND
	var tabs: PackedStringArray = []
	for i in M0Loop.TAB_NAMES.size():
		tabs.append("[%s]" % M0Loop.TAB_NAMES[i] if i == int(loop.tab) else M0Loop.TAB_NAMES[i])
	header_label.text = "AGORA   CR %s   DEBT %s   DOOMSDAY %d:%02d %s   SPEED %s\n%s     %s" % [
		_fmt(int(h["cr"])), _fmt(int(h["total_debt"])), secs / 60, secs % 60, h["stage_name"], h["speed_label"], "  ".join(tabs), CONTROLS_HINT]
	map_label.text = _fleet_text() if loop.tab == M0Loop.Tab.FLEET else "SOL TACTICAL MAP   docked: %s" % StationMarket.station_name(controller.docked_at)
	sidebar_label.text = _sidebar_text()
	_refresh_ticker()
	market_modal.visible = hud.is_trading_overlay_open() and loop.overlay_state == M0Loop.OVERLAY_NONE
	market_label.text = _board_text() if market_modal.visible else ""
	_update_market_highlight()
	resolution_modal.visible = loop.overlay_state != M0Loop.OVERLAY_NONE
	var collapsed: bool = loop.overlay_state == M0Loop.OVERLAY_COLLAPSED
	resolution_modal.position = OrbitalHUD.MODAL_OVERLAY_RECT.position if collapsed else RESOLUTION_RECT.position
	resolution_modal.size = OrbitalHUD.MODAL_OVERLAY_RECT.size if collapsed else RESOLUTION_RECT.size
	resolution_label.size = resolution_modal.size - Vector2(40, 32)
	resolution_label.text = _resolution_text() if resolution_modal.visible else ""
	tactical_map_panel.queue_redraw()


## Draws the newest GalNet lines; a line wider than the panel scrolls sideways.
func _refresh_ticker() -> void:
	if ticker_labels.is_empty():
		return
	var font: Font = ticker_labels[0].get_theme_default_font()
	var measure := func(t: String) -> float: return font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	var lines: Array = hud.get_ticker_lines(measure)
	for i in ticker_labels.size():
		var tl: Label = ticker_labels[i]
		if i < lines.size():
			tl.text = lines[i]["text"]
			tl.position.x = -float(lines[i]["offset"])
		else:
			tl.text = ""
			tl.position.x = 0.0


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
		out.append("REJECTED: " + f.get_rejection_message())
	elif not f.last_executed_order.is_empty():
		var o: Dictionary = f.last_executed_order
		var who: String = str(o.get("counterparty", ""))
		out.append("FILLED %s %d @ %.1f%s" % [o["side"], o["qty"], o["price"], "  vs %s" % who if who != "" else ""])
	return "\n".join(out)


func _board_text() -> String:
	var out: PackedStringArray = ["%s QUOTES   counterparty %s" % [StationMarket.station_name(hud.active_station).to_upper(), StationMarket.MAKER_NAME], ""]
	for c in Transit.COMMODITIES:
		var key_prefix: String = "%s %-10s" % [">" if c == hud.active_commodity else " ", c]
		if loop.market.has_book(hud.active_station, c):
			var lad: Dictionary = loop.market.ladder(hud.active_station, c, 1)
			out.append("%s BID %6.1f   ASK %6.1f" % [key_prefix, lad["best_bid"], lad["best_ask"]])
		else:
			out.append("%s base %6.1f   (no live book)" % [key_prefix, Transit.BASE_PRICES[hud.active_station][c]])
	out.append("")
	out.append("R-STICK commodity   D-PAD up/down ladder, left/right qty   B back")
	return "\n".join(out)


## Index of the selected commodity's row in the board text (title + blank + rows).
func market_row_line() -> int:
	return 2 + maxi(0, Transit.COMMODITIES.find(hud.active_commodity))


func _update_market_highlight() -> void:
	if market_highlight == null or market_label == null or hud == null:
		return
	var lh: float = float(market_label.get_line_height() + market_label.get_theme_constant("line_spacing"))
	market_highlight.position = market_label.position + Vector2(-4.0, lh * float(market_row_line()))
	market_highlight.size = Vector2(market_label.size.x, lh)


func _fleet_text() -> String:
	var parts: PackedStringArray = ["FLEET   hulls: %d" % controller.ships.size()]
	for c in controller.cargo:
		parts.append("  %s x%d" % [c, int(controller.cargo[c])])
	return "\n".join(parts)


func _resolution_text() -> String:
	if loop.overlay_state == M0Loop.OVERLAY_CHAPTER_11:
		var a: Dictionary = controller.assess()
		return "CHAPTER 11\n\nInsolvent: debt %s exceeds liquidation value %s.\nThe clock is halted.\n\nPress X to file and found a new corp." % [_fmt(int(a["total_debt"])), _fmt(int(a["liquidation_value"]))]
	if loop.collapse_phase == M0Loop.PHASE_PERKS:
		return _perks_text()
	return _summary_text()


func _summary_text() -> String:
	var r: Dictionary = loop.run_summary()
	return "SOVEREIGN DEFAULT   RUN OVER\n\nThe Doomsday Clock has run out.\n\nNET WORTH        %s CR\nPEAK NET WORTH   %s CR\nROUNDS SURVIVED  %d\nSEVERANCE BANKED +%d  (balance %d)\n\nPress A for Golden Parachutes." % [
		_fmt(int(r["net_worth"])), _fmt(int(r["peak_net_worth"])), int(r["rounds_survived"]), int(r["severance_awarded"]), int(r["severance_balance"])]


func _perks_text() -> String:
	var rows: Array = loop.perk_rows()
	var out: PackedStringArray = ["GOLDEN PARACHUTES   Severance %d" % controller.profile.severance_points, ""]
	for i in rows.size():
		var row: Dictionary = rows[i]
		var tag: String = "OWNED" if bool(row["owned"]) else ("%d" % int(row["cost"]) if bool(row["can_buy"]) else "%d  locked" % int(row["cost"]))
		out.append("%s T%d  %s  [%s]  -  %s" % [">" if i == loop.perk_cursor else " ", int(row["tier"]), row["name"], row["branch"], tag])
	out.append("%s START NEW RUN" % (">" if loop.perk_cursor >= rows.size() else " "))
	out.append("")
	out.append("D-pad up/down select   A buy perk / start run   B back")
	return "\n".join(out)


static func _fmt(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out
