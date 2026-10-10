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
## Second header line (tabs + controls hint) in a smaller face so a translated hint still fits 1248 px.
var hint_label: Label = null
var sidebar_label: Label = null
var ticker_clip: Control = null
var ticker_labels: Array[Label] = []
var map_label: Label = null
## Shared readable palette: every HUD label and every opaque modal body uses these.
const HUD_TEXT_COLOR := HudTheme.BONE
const MODAL_BG_COLOR := Color(0.1725, 0.2078, 0.2314, 1.0)
## Text on the light paper panels (map, sidebar).
const PAPER_TEXT_COLOR := HudTheme.INK
## Gamepad focus, in the new style (#105): the focused zone gets a heavy coloured frame
## (rust on the paper panels, ochre on the slate ones) and the focused row a flat bar with
## an ink or ochre outline. The ">" glyph stays, so focus never depends on colour alone.
const FOCUS_BAR_PAPER_FILL := HudTheme.OCHRE
const FOCUS_BAR_PAPER_EDGE := HudTheme.INK
const FOCUS_BAR_DARK_FILL := HudTheme.RUST_DARK
const FOCUS_BAR_DARK_EDGE := HudTheme.OCHRE

## "PAUSED - resumed from sleep" banner, shown while a wake-pause is active.
var sleep_modal: Panel = null
var sleep_label: Label = null
## How many times audio has been re-armed after a wake (read by tests).
var audio_rearm_count: int = 0
## Font size of the tabs + controls hint line (the stats line above it is 18).
const HINT_FONT_SIZE: int = 14
const SLEEP_BANNER_RECT: Rect2 = Rect2(300.0, 320.0, 680.0, 140.0)

var market_modal: Panel = null
var market_label: Label = null
var resolution_modal: Panel = null
var resolution_label: Label = null
var sfx_players: Array[AudioStreamPlayer] = []
var drone_player: AudioStreamPlayer = null
var market_highlight: ColorRect = null
## Focus bars (rows) and zone frames, built in _build_readouts.
var sidebar_focus_bar: ColorRect = null
var resolution_focus_bar: ColorRect = null
var settings_focus_bar: ColorRect = null
var focus_frames: Dictionary = {}
## Accent stripes down the left edge of the dark modals.
var _modal_stripes: Array[ColorRect] = []
## Per-voice bookkeeping for stealing: play order and whether it carries a priority sound.
var _voice_order: Array[int] = []
var _voice_priority: Array[bool] = []
var _voice_counter: int = 0

## Fixed seed for tests and replays: start_new_run() with no argument uses it, so
## headless callers stay deterministic. A real new game does NOT: _ready() asks
## initial_run_seed() instead (D10).
const DEFAULT_RUN_SEED: int = 84
## Environment override for the first run's seed (reproducible manual play).
const RUN_SEED_ENV: String = "AGORA_RUN_SEED"
## Chapter 11 resolution modal; the collapse screens use the larger market modal rect.
const RESOLUTION_RECT: Rect2 = Rect2(340.0, 240.0, 600.0, 320.0)
## Voices for routine UI feedback. PRIORITY_VOICES more are reserved for alarms and
## market bells, which may also steal the oldest routine voice if all are busy.
const SFX_POLYPHONY: int = 4
const PRIORITY_VOICES: int = 2

## Controls hint shown under the header readout (translation key, see controls_hint()).
const CONTROLS_HINT_KEY: String = "HUD_CONTROLS_HINT"
## The Map tab has no orders, so its hint offers A as depart instead (#111). Under
## way no order can be placed, so the short transit hint replaces both.
const CONTROLS_HINT_MAP_KEY: String = "HUD_CONTROLS_HINT_MAP"
const CONTROLS_HINT_TRANSIT_KEY: String = "HUD_CONTROLS_HINT_TRANSIT"

var is_initialized: bool = false

## Accessibility (#37): text scale, palette, bindings, language. Persisted next to
## the profile once enable_persistence() runs; headless runs never write them.
var settings: AccessibilitySettings = AccessibilitySettings.new()
var settings_menu: SettingsMenu = null
var settings_modal: Panel = null
var settings_label: Label = null
## Colour strips beside the ladder rows (bid / ask), tinted from Palette.
var _ladder_swatches: Array[ColorRect] = []
## The sidebar text sits in a clipping view. It only scrolls (an auto marquee, like
## the GalNet ticker) when the text is taller than the view, which at 100% never
## happens and at larger text sizes only with several crises active.
var sidebar_clip: Control = null
var _sidebar_scroll_t: float = 0.0
const SIDEBAR_VIEW: Vector2 = Vector2(400.0, 656.0)
const SIDEBAR_DWELL_TOP: float = 4.0
const SIDEBAR_DWELL_BOTTOM: float = 2.5
const SIDEBAR_SCROLL_SPEED: float = 36.0
## Rows in the sidebar ladder as last rendered: [asks, bids].
var _ladder_shape: Array[int] = [0, 0]
## Label metadata key holding the font size at 100% text scale.
const BASE_SIZE_META: String = "base_font_size"
## Label metadata flag: this label may be taller than its view and then scrolls
## (set while the text scale is above 100%; at 100% the text must simply fit).
const SCROLLS_META: String = "scrolls_vertically"
## Font size of the tactical map's station names at 100% text scale.
const MAP_FONT_SIZE: int = 14
const TICKER_FONT_SIZE: int = 16

## Persistence (#35). Null until enable_persistence(); headless runs (tests,
## smoke) never enable it, so they never touch the real user:// directory.
var save_store: SaveStore = null
## The marble bags backing bad-luck protection; saved and restored with the run.
var bags: Bags = null
var _loaded_profile: MetaProfile = null
## Steam achievement/stat hooks (#27); a no-op layer when Steam is absent.
var steam_hooks: SteamHooks = null
var _saved_profile_dict: Dictionary = {}


func _init() -> void:
	custom_minimum_size = VIEWPORT_SIZE
	settings_menu = SettingsMenu.new(settings)
	settings.changed.connect(_on_settings_changed)
	initialize_systems()


## Controls hint shown under the header readout, in the current locale.
func controls_hint() -> String:
	if loop != null and controller != null:
		if controller.is_in_transit():
			return tr(CONTROLS_HINT_TRANSIT_KEY)
		if loop.tab == M0Loop.Tab.MAP:
			return tr(CONTROLS_HINT_MAP_KEY)
	return tr(CONTROLS_HINT_KEY)


func _ready() -> void:
	Loc.apply_env()
	_resolve_child_nodes()
	_setup_crt_pipeline()
	if save_store == null and DisplayServer.get_name() != "headless":
		enable_persistence(SaveStore.new())
	if controller == null:
		# Resume the autosaved run when there is a usable one, else start fresh.
		if not continue_saved_run():
			start_new_run(initial_run_seed())
	_build_readouts()
	_setup_audio()
	_refresh_readouts()


## Advances the SimClock at the selected speed; pause (or an overlay) stops it.
func _process(delta: float) -> void:
	if loop == null:
		return
	# The settings screen freezes the sim, as an overlay would.
	if settings_menu != null and settings_menu.is_open:
		_refresh_readouts()
		return
	# A wake-sized raw delta must not drive the ticker or anything else either.
	if SimClock.is_wake_delta(delta):
		loop.advance(delta)
		_refresh_readouts()
		return
	loop.advance(delta)
	_sidebar_scroll_t += delta
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
	if settings_menu != null:
		if settings_menu.is_open:
			return settings_menu.handle_event(event)
		if InputMap.has_action(InputRemap.ACT_SETTINGS) and event.is_action_pressed(InputRemap.ACT_SETTINGS) and not event.is_echo():
			settings_menu.open()
			return true
	return loop != null and loop.handle_input(event)


## Seed for a brand-new game's first run: AGORA_RUN_SEED when set to an integer,
## otherwise a real random source (RandomNumberGenerator.randomize()), so every
## new game gets a different Sol instead of always DEFAULT_RUN_SEED (D10).
static func initial_run_seed() -> int:
	var env: String = OS.get_environment(RUN_SEED_ENV)
	if env.is_valid_int():
		return int(env)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return rng.randi() & 0x7FFFFFFF


## Creates a fresh RunController and binds it to the HUD, loop and clock.
func start_new_run(p_seed: int = DEFAULT_RUN_SEED) -> RunController:
	var rc := RunController.new(_loaded_profile, p_seed)
	rc.world = Barons.for_new_run()  # Epic 3: the sector barons make the books
	bags = Bags.new("m0", null, p_seed)
	initialize_systems(rc)
	return rc


# --- Persistence (#35) ---

## Turns on autosave (each round advance, profile changes, quit) and loads the
## persisted MetaProfile so the next new run starts with its perks.
func enable_persistence(store: SaveStore) -> void:
	save_store = store
	store.cloud = SteamService.shared()
	SteamService.shared().attach_store(store)
	_load_settings()
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
	# profile.json is written whenever the profile changes (perk buys, filings),
	# the run slot's embedded copy only at round autosaves, so after a crash the
	# file is the newer one: it wins, and the run is re-pointed at it (D3).
	if _loaded_profile != null:
		rc.profile = _loaded_profile
	bags = r["bags"]
	initialize_systems(rc, false)
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
## The run slot embeds a profile copy too, so refresh it in the same step (D3):
## a crash before the next round autosave must not leave a stale embedded profile.
func _on_action_handled(_action: String) -> void:
	# The language action cycles Loc directly: keep the saved setting in step.
	if settings.locale != Loc.current():
		settings.locale = Loc.current()
		_save_settings()
	if controller != null and controller.profile.to_dict() != _saved_profile_dict:
		save_all()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_all()
	# Secondary wake triggers (mobile/minimise, focus loss): same path as the delta spike.
	elif what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		handle_suspend_notification("pause")
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		handle_suspend_notification("resume")


## Routes a platform pause/resume/focus notification into the loop's wake handling.
func handle_suspend_notification(source: String) -> void:
	if loop != null:
		loop.handle_wake(source)


## p_dock_start: a new run starts docked at Mars; a loaded one stays wherever it was saved.
func initialize_systems(p_controller: RunController = null, p_dock_start: bool = true) -> void:
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
	apply_alert_settings()
	if loop == null:
		loop = M0Loop.new(hud)
	else:
		loop.rebind_controller()
	# A new run starts docked at Mars (Arcadia Foundries); a loaded run keeps its dock or voyage.
	if p_dock_start:
		loop.dock_at(M0Loop.M0_STATION)
	else:
		loop.sync_hud_to_ship()
	_bind_steam_hooks()
	if not loop.woke_from_sleep.is_connected(_on_woke_from_sleep):
		loop.woke_from_sleep.connect(_on_woke_from_sleep)
	if not loop.run_restarted.is_connected(_on_run_restarted):
		loop.run_restarted.connect(_on_run_restarted)
	is_initialized = true


## The collapse flow replaced the run: follow the loop's new controller.
func _on_run_restarted(rc: RunController) -> void:
	controller = rc
	_bind_steam_hooks()
	bags = Bags.new("m0", null, rc.run_seed)
	tactical_map = hud.tactical_map
	trading_overlay = hud.trading_overlay
	vector_orrery = hud.vector_orrery


func _bind_steam_hooks() -> void:
	if steam_hooks == null:
		steam_hooks = SteamHooks.new()
	steam_hooks.bind(controller)


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


func _on_woke_from_sleep(_source: String) -> void:
	rearm_audio()


## Wake recovery: stop every player (flushing stale buffers and any stuck tone) and
## restart the drone so the audio server gets fresh streams.
func rearm_audio() -> void:
	audio_rearm_count += 1
	for p in sfx_players:
		p.stop()
	for i in _voice_order.size():
		_voice_order[i] = 0
		_voice_priority[i] = false
	if drone_player != null:
		drone_player.stop()
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


# --- Accessibility settings (#37) ---

## Loads settings.json (defaults when absent) and applies them to InputMap,
## Palette and, unless the environment pins one, the language.
func _load_settings() -> void:
	settings.changed.disconnect(_on_settings_changed)
	var fresh: AccessibilitySettings = AccessibilitySettings.load_from(save_store)
	settings.text_scale = fresh.text_scale
	settings.palette = fresh.palette
	settings.locale = fresh.locale
	settings.crt_filter = fresh.crt_filter
	settings.alert_volume = fresh.alert_volume
	settings.alert_mute = fresh.alert_mute
	settings.bindings = fresh.bindings
	var env_locale: bool = OS.get_environment(Loc.PSEUDO_ENV) in ["1", "true", "yes"] or OS.get_environment(Loc.LOCALE_ENV) != ""
	if env_locale:
		settings.locale = Loc.current()
	settings.apply_all(not env_locale)
	settings.changed.connect(_on_settings_changed)
	apply_text_scale()
	set_crt_enabled(settings.crt_filter)
	apply_alert_settings()


## Pushes the saved alert volume and mute onto the Alerts bus (via the audio model,
## which syncs the AudioServer bus when inside the tree).
func apply_alert_settings() -> void:
	if tactile_audio == null:
		return
	tactile_audio.set_alert_volume(settings.alert_volume)
	tactile_audio.set_alert_mute(settings.alert_mute)


func _save_settings() -> void:
	if save_store != null and settings.save(save_store) != OK:
		push_warning("settings save failed")


func _on_settings_changed() -> void:
	settings.locale = Loc.current()
	apply_text_scale()
	set_crt_enabled(settings.crt_filter)
	apply_alert_settings()
	_save_settings()


## Font size for a label drawn at `base` px at 100%, under the current scale.
func scaled_size(base: int) -> int:
	return int(round(float(base) * settings.text_scale))


## Height of one text line of a label at its current font size (Label.get_line_height()
## lags a font-size override until the label is in the tree).
func _line_height(label: Label) -> float:
	var font: Font = label.get_theme_default_font()
	return ceilf(font.get_height(label.get_theme_font_size("font_size"))) + float(label.get_theme_constant("line_spacing"))


## Height the label's text needs at its width (Label.get_line_count() reads 1 until the
## label is in the tree, so measure with the font directly).
func _text_height(label: Label) -> float:
	var font: Font = label.get_theme_default_font()
	var fs: int = label.get_theme_font_size("font_size")
	var flags: int = TextServer.BREAK_MANDATORY
	var width: float = -1.0
	if label.autowrap_mode != TextServer.AUTOWRAP_OFF:
		width = label.size.x
		flags |= TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	var h: float = font.get_multiline_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, width, fs, -1, flags).y
	var lines: int = int(round(h / maxf(1.0, font.get_height(fs))))
	return h + float(maxi(0, lines - 1) * label.get_theme_constant("line_spacing"))


## Marquee offset (px) for content `overflow` px taller than its view, `t` seconds
## into the cycle: dwell at the top, scroll down, dwell at the bottom, jump back.
static func marquee_offset(t: float, overflow: float) -> float:
	if overflow <= 0.0:
		return 0.0
	var run: float = overflow / SIDEBAR_SCROLL_SPEED
	var cycle: float = SIDEBAR_DWELL_TOP + run + SIDEBAR_DWELL_BOTTOM
	var m: float = fposmod(t, cycle)
	if m < SIDEBAR_DWELL_TOP:
		return 0.0
	return minf(overflow, (m - SIDEBAR_DWELL_TOP) * SIDEBAR_SCROLL_SPEED)


## Sizes the sidebar label to its text and applies the marquee when it overflows.
func _update_sidebar_scroll() -> void:
	if sidebar_label == null:
		return
	var content: float = maxf(SIDEBAR_VIEW.y, _text_height(sidebar_label))
	sidebar_label.size.y = content
	var overflow: float = content - SIDEBAR_VIEW.y
	sidebar_label.position.y = -marquee_offset(_sidebar_scroll_t, overflow)


## True when the sidebar text is taller than its view (so it is scrolling).
func sidebar_overflow() -> float:
	if sidebar_label == null:
		return 0.0
	return maxf(0.0, sidebar_label.size.y - SIDEBAR_VIEW.y)


func _fit_height(label: Label, minimum: float) -> float:
	var font: Font = label.get_theme_default_font()
	return maxf(minimum, ceilf(font.get_height(label.get_theme_font_size("font_size"))))


## Applies the text scale to every readout and re-lays the rows that grow with it.
func apply_text_scale() -> void:
	if header_label == null:
		return
	for l in _scaled_labels():
		l.add_theme_font_size_override("font_size", scaled_size(int(l.get_meta(BASE_SIZE_META))))
	sidebar_label.set_meta(SCROLLS_META, settings.text_scale > 1.0)
	header_label.size.y = _fit_height(header_label, 28.0)
	hint_label.position.y = header_label.position.y + header_label.size.y + 2.0
	hint_label.size.y = _fit_height(hint_label, 26.0)
	var lh: float = _fit_height(ticker_labels[0], 24.0)
	for i in ticker_labels.size():
		ticker_labels[i].position.y = float(i) * lh
		ticker_labels[i].size.y = lh
	ticker_clip.size.y = maxf(52.0, lh * float(ticker_labels.size()))
	map_label.size.y = ceilf(168.0 * settings.text_scale)
	if tactical_map_panel != null:
		tactical_map_panel.queue_redraw()


func _scaled_labels() -> Array[Label]:
	var out: Array[Label] = [header_label, hint_label, map_label, sidebar_label, market_label, resolution_label, sleep_label, settings_label]
	out.append_array(ticker_labels)
	return out


## Strips beside the ladder: asks above the spread line, bids below.
func _update_ladder_swatches() -> void:
	if sidebar_label == null or sidebar_clip == null:
		return
	var rows: int = _ladder_shape[0] + _ladder_shape[1]
	while _ladder_swatches.size() < rows:
		var r := ColorRect.new()
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Ink contour: a slightly larger ink rect drawn behind the colour strip.
		var ink := ColorRect.new()
		ink.color = HudTheme.INK
		ink.show_behind_parent = true
		ink.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ink.position = Vector2(-2, -2)
		ink.size = Vector2(13, 12)
		r.add_child(ink)
		sidebar_clip.add_child(r)
		_ladder_swatches.append(r)
	var lh: float = _line_height(sidebar_label)
	for i in _ladder_swatches.size():
		var r: ColorRect = _ladder_swatches[i]
		r.visible = i < rows
		if not r.visible:
			continue
		var is_ask: bool = i < _ladder_shape[0]
		# Layout: title, blank, asks, spread, bids.
		var line: int = 2 + i if is_ask else 3 + i
		r.color = Palette.ask_color() if is_ask else Palette.bid_color()
		r.position = Vector2(5.0, sidebar_label.position.y + lh * float(line) + 3.0)
		r.size = Vector2(9.0, maxf(4.0, lh - 6.0))


# --- Readouts ---

func _make_label(parent: Control, rect: Rect2, size: int = 16) -> Label:
	var l := Label.new()
	l.position = rect.position
	l.size = rect.size
	l.add_theme_font_size_override("font_size", size)
	l.set_meta(BASE_SIZE_META, size)
	l.add_theme_color_override("font_color", HUD_TEXT_COLOR)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Text arrives already translated via tr(); stop Label translating it a second
	# time (which would pseudolocalize twice).
	l.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	parent.add_child(l)
	return l


func _build_readouts() -> void:
	if hud_container == null or header_label != null:
		return
	header_label = _make_label(header_panel, Rect2(16, 4, 1248, 28), 18)
	hint_label = _make_label(header_panel, Rect2(16, 34, 1248, 26), HINT_FONT_SIZE)
	# Tab strip and control hints are the longest single line: narrow the width axis to 90 (fit rule).
	hint_label.add_theme_font_override("font", HudTheme.role_font(HudTheme.ROLE_HINT, 90))
	hint_label.add_theme_color_override("font_color", HudTheme.BONE_DIM)
	map_label = _make_label(tactical_map_panel, Rect2(16, 8, 848, 168), 16)
	map_label.add_theme_color_override("font_color", PAPER_TEXT_COLOR)
	sidebar_clip = Control.new()
	sidebar_clip.position = Vector2(0, 8)
	sidebar_clip.size = SIDEBAR_VIEW
	sidebar_clip.clip_contents = true
	sidebar_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sidebar_panel.add_child(sidebar_clip)
	sidebar_focus_bar = HudTheme.make_focus_bar(sidebar_clip, FOCUS_BAR_PAPER_FILL, FOCUS_BAR_PAPER_EDGE)
	sidebar_label = _make_label(sidebar_clip, Rect2(16, 0, 368, 656), 16)
	sidebar_label.add_theme_color_override("font_color", PAPER_TEXT_COLOR)
	sidebar_label.set_meta(SCROLLS_META, false)
	# Translated lines can be wider than the panel: wrap instead of spilling out (#40).
	sidebar_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ticker_clip = Control.new()
	ticker_clip.position = Vector2(16, 6)
	ticker_clip.size = Vector2(OrbitalHUD.TICKER_VIEW_WIDTH, 52)
	ticker_clip.clip_contents = true
	ticker_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ticker_panel.add_child(ticker_clip)
	for i in OrbitalHUD.TICKER_VISIBLE_LINES:
		var tl := _make_label(ticker_clip, Rect2(0, i * 24, 4096, 24), TICKER_FONT_SIZE)
		tl.autowrap_mode = TextServer.AUTOWRAP_OFF
		ticker_labels.append(tl)
	tactical_map_panel.clip_contents = true
	tactical_map_panel.draw.connect(_draw_map)
	market_modal = Panel.new()
	HudTheme.style_panel(market_modal, "ModalPanel")
	market_modal.position = OrbitalHUD.MODAL_OVERLAY_RECT.position
	market_modal.size = OrbitalHUD.MODAL_OVERLAY_RECT.size
	hud_container.add_child(market_modal)
	_add_modal_stripe(market_modal)
	market_highlight = HudTheme.make_focus_bar(market_modal, FOCUS_BAR_DARK_FILL, FOCUS_BAR_DARK_EDGE)
	market_highlight.visible = true
	market_label = _make_label(market_modal, Rect2(20, 16, OrbitalHUD.MODAL_OVERLAY_RECT.size.x - 40.0, OrbitalHUD.MODAL_OVERLAY_RECT.size.y - 32.0), 16)
	# The quote board is the densest text on screen: narrow the width axis (100 to 85, the
	# design system's fit rule) so pseudo-locale rows fit before anything wraps.
	market_label.add_theme_font_override("font", HudTheme.role_font(HudTheme.ROLE_BODY, 85))
	resolution_modal = Panel.new()
	HudTheme.style_panel(resolution_modal, "ModalPanel")
	resolution_modal.position = RESOLUTION_RECT.position
	resolution_modal.size = RESOLUTION_RECT.size
	hud_container.add_child(resolution_modal)
	_add_modal_stripe(resolution_modal)
	resolution_focus_bar = HudTheme.make_focus_bar(resolution_modal, FOCUS_BAR_DARK_FILL, FOCUS_BAR_DARK_EDGE)
	resolution_label = _make_label(resolution_modal, Rect2(20, 16, 560, 288), 20)
	# Body text keeps the shared HUD bone colour (_make_label). A red override here
	# was unreadable on the dark panel once the CRT aberration split its channels.
	resolution_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sleep_modal = Panel.new()
	HudTheme.style_panel(sleep_modal, "BannerPanel")
	sleep_modal.position = SLEEP_BANNER_RECT.position
	sleep_modal.size = SLEEP_BANNER_RECT.size
	hud_container.add_child(sleep_modal)
	sleep_label = _make_label(sleep_modal, Rect2(20, 12, SLEEP_BANNER_RECT.size.x - 40.0, SLEEP_BANNER_RECT.size.y - 24.0), 22)
	sleep_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sleep_modal.visible = false
	settings_modal = Panel.new()
	HudTheme.style_panel(settings_modal, "ModalPanel")
	settings_modal.position = OrbitalHUD.MODAL_OVERLAY_RECT.position
	settings_modal.size = OrbitalHUD.MODAL_OVERLAY_RECT.size
	hud_container.add_child(settings_modal)
	_add_modal_stripe(settings_modal)
	settings_focus_bar = HudTheme.make_focus_bar(settings_modal, FOCUS_BAR_DARK_FILL, FOCUS_BAR_DARK_EDGE)
	settings_label = _make_label(settings_modal, Rect2(20, 16, OrbitalHUD.MODAL_OVERLAY_RECT.size.x - 40.0, OrbitalHUD.MODAL_OVERLAY_RECT.size.y - 32.0), 18)
	settings_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	settings_modal.visible = false
	_build_focus_frames()
	apply_text_scale()


## Accent stripe down the left edge of a dark modal: a flat ochre band, ink outlined.
func _add_modal_stripe(modal: Panel) -> void:
	var stripe := ColorRect.new()
	stripe.color = HudTheme.OCHRE
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stripe.position = Vector2(HudTheme.OUTLINE_PANEL, HudTheme.OUTLINE_PANEL)
	stripe.size = Vector2(8.0, modal.size.y - 2.0 * HudTheme.OUTLINE_PANEL)
	modal.add_child(stripe)
	_modal_stripes.append(stripe)


## One coloured frame per focusable zone, shown only on the zone the gamepad is in.
func _build_focus_frames() -> void:
	var specs: Array = [
		[GamepadFocus.Zone.TACTICAL_MAP, tactical_map_panel, "FocusFrameRust"],
		[GamepadFocus.Zone.ORDER_BOOK, sidebar_panel, "FocusFrameRust"],
		[GamepadFocus.Zone.TRADING_OVERLAY, market_modal, "FocusFrameOchre"],
		[GamepadFocus.Zone.SYSTEM_BAR, header_panel, "FocusFrameOchre"],
	]
	for spec in specs:
		var host: Panel = spec[1]
		var frame := Panel.new()
		HudTheme.style_panel(frame, str(spec[2]))
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.position = Vector2.ZERO
		frame.size = host.size
		frame.visible = false
		host.add_child(frame)
		focus_frames[int(spec[0])] = frame


## True while a full-screen modal (settings, collapse, Chapter 11, crisis, sleep banner) owns input.
func _modal_has_focus() -> bool:
	return settings_modal.visible or resolution_modal.visible or sleep_modal.visible


## Frames follow the gamepad zone; the trading overlay frame only shows while it is up.
func _update_focus_frames() -> void:
	var zone: int = int(hud.gamepad_focus.current_zone)
	if _modal_has_focus():
		zone = -1
	for z in focus_frames:
		var frame: Panel = focus_frames[z]
		var host: Control = frame.get_parent() as Control
		frame.size = host.size
		frame.visible = int(z) == zone and (int(z) != GamepadFocus.Zone.TRADING_OVERLAY or market_modal.visible)


func _draw_map() -> void:
	if tactical_map == null or tactical_map_panel == null:
		return
	var origin: Vector2 = OrbitalHUD.TACTICAL_MAP_RECT.position
	var round_num: int = controller.get_current_round() if controller != null else 0
	var center: Vector2 = SolTacticalMap.MAP_CENTER - origin
	# The panel clips to its own rect; the projection is sized to fit it. Flat ligne claire:
	# ink orbit rings, then flat filled nodes with ink contours and a hard shadow cut.
	var stations: Array = tactical_map.get_stations()
	for st in stations:
		var pos: Vector2 = tactical_map.get_station_screen_pos(st, round_num) - origin
		var ring_active: bool = st == hud.active_station
		tactical_map_panel.draw_arc(center, pos.distance_to(center), 0.0, TAU, 96, HudTheme.RUST if ring_active else HudTheme.INK, HudTheme.OUTLINE_RING + (1.0 if ring_active else 0.0), true)
	HudTheme.draw_flat_disc(tactical_map_panel, center, SolTacticalMap.SOL_NODE_RADIUS_PX, HudTheme.OCHRE, HudTheme.OCHRE_DARK)
	var font: Font = ThemeDB.fallback_font
	var fs: int = scaled_size(MAP_FONT_SIZE)
	var label_texts: Dictionary = {}
	for st in stations:
		label_texts[st] = Loc.station(st).to_upper()
	var label_offsets: Dictionary = tactical_map.get_label_offsets(round_num, fs, label_texts)
	for st in stations:
		var pos: Vector2 = tactical_map.get_station_screen_pos(st, round_num) - origin
		var active: bool = st == hud.active_station
		var fill: Color = HudTheme.RUST if active else HudTheme.TEAL
		var cut: Color = HudTheme.RUST_DARK if active else HudTheme.TEAL_DARK
		HudTheme.draw_flat_disc(tactical_map_panel, pos, SolTacticalMap.STATION_NODE_RADIUS_PX, fill, cut)
		var label_pos: Vector2 = pos + Vector2(label_offsets[st])
		var text: String = str(label_texts[st])
		tactical_map_panel.draw_string_outline(font, label_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, HudTheme.PAPER)
		tactical_map_panel.draw_string(font, label_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, HudTheme.RUST_DARK if active else HudTheme.INK)
	_draw_player_ship(origin, round_num, font)


## The player's ship on its lane, drawn over the stations: a dashed ink lane
## (rust across the belt), a small ochre hull and a YOU tag. While docked, an
## ochre ring marks the home station.
func _draw_player_ship(origin: Vector2, round_num: int, font: Font) -> void:
	var voyage: Dictionary = tactical_map.get_player_transit(round_num)
	if voyage.is_empty():
		if controller != null and controller.docked_at != "":
			var home: Vector2 = tactical_map.get_station_screen_pos(controller.docked_at, round_num) - origin
			tactical_map_panel.draw_arc(home, SolTacticalMap.STATION_NODE_RADIUS_PX + 6.0, 0.0, TAU, 32, HudTheme.OCHRE_DARK, 3.0, true)
		return
	var a: Vector2 = Vector2(voyage["start_pos"]) - origin
	var b: Vector2 = Vector2(voyage["end_pos"]) - origin
	var lane: Color = HudTheme.RUST if bool(voyage["is_belt"]) else HudTheme.INK
	tactical_map_panel.draw_dashed_line(a, b, lane, 3.0, 10.0, true)
	var ship: Vector2 = Vector2(voyage["pos"]) - origin
	HudTheme.draw_flat_disc(tactical_map_panel, ship, 9.0, HudTheme.OCHRE, HudTheme.OCHRE_DARK)
	var fs: int = scaled_size(MAP_FONT_SIZE)
	var tag: String = tr("MAP_SHIP_TAG")
	var tag_pos: Vector2 = ship + Vector2(-12.0, 28.0)
	tactical_map_panel.draw_string_outline(font, tag_pos, tag, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, HudTheme.PAPER)
	tactical_map_panel.draw_string(font, tag_pos, tag, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, HudTheme.RUST_DARK)


func _refresh_readouts() -> void:
	if header_label == null or hud == null or loop == null:
		return
	var h: Dictionary = hud.get_header_telemetry()
	var secs: int = int(h["ticks_remaining"]) / DoomsdayClock.DEFAULT_TICKS_PER_SECOND
	var tabs: PackedStringArray = []
	for i in M0Loop.TAB_NAMES.size():
		tabs.append("[%s]" % Loc.tab(i) if i == int(loop.tab) else Loc.tab(i))
	var top: PackedStringArray = [
		tr("HUD_TITLE"),
		tr("HUD_CR") % _fmt(int(h["cr"])),
		tr("HUD_DEBT") % _fmt(int(h["total_debt"])),
		tr("HUD_DOOMSDAY") % [secs / 60, secs % 60, Loc.stage(str(h["stage_name"]))],
		tr("HUD_SPEED") % h["speed_label"],
		tr("HUD_LANG") % Loc.locale_label()]
	header_label.text = "   ".join(top)
	# Under way, the second header line carries the voyage: line one has no room for it
	# (it overflows the 1248 px label in the pseudo-localised audit), and with the ship
	# between stations there is little to press anyway.
	var tail: String = controls_hint()
	if bool(h["in_transit"]):
		tail = "%s     %s" % [tr("HUD_TRANSIT") % [Loc.station(str(h["transit_destination"])), _rounds_text(int(h["transit_eta_rounds"]))], tail]
	hint_label.text = "%s     %s" % ["  ".join(tabs), tail]
	map_label.text = _fleet_text() if loop.tab == M0Loop.Tab.FLEET else _map_text()
	sidebar_label.text = _sidebar_text()
	_update_sidebar_scroll()
	_refresh_ticker()
	market_modal.visible = hud.is_trading_overlay_open() and loop.overlay_state == M0Loop.OVERLAY_NONE
	market_label.text = _board_text() if market_modal.visible else ""
	_update_market_highlight()
	resolution_modal.visible = loop.overlay_state != M0Loop.OVERLAY_NONE
	_style_resolution_modal()
	# A paused game wears an ochre header contour.
	var header_variation: String = "HeaderPanelPaused" if controller.sim_clock.paused else "HeaderPanel"
	if String(header_panel.theme_type_variation) != header_variation:
		HudTheme.style_panel(header_panel, header_variation)
	var big: bool = loop.overlay_state == M0Loop.OVERLAY_COLLAPSED or loop.overlay_state == M0Loop.OVERLAY_CRISIS or loop.overlay_state == M0Loop.OVERLAY_CONTRACT
	resolution_modal.position = OrbitalHUD.MODAL_OVERLAY_RECT.position if big else RESOLUTION_RECT.position
	resolution_modal.size = OrbitalHUD.MODAL_OVERLAY_RECT.size if big else RESOLUTION_RECT.size
	resolution_label.size = resolution_modal.size - Vector2(40, 32)
	resolution_label.text = _resolution_text() if resolution_modal.visible else ""
	sleep_modal.visible = loop.sleep_pause_active and controller.sim_clock.paused
	sleep_label.text = "%s\n%s" % [tr("SLEEP_NOTICE"), tr("SLEEP_PRESS_START")] if sleep_modal.visible else ""
	settings_modal.visible = settings_menu.is_open
	if settings_modal.visible:
		var lh: float = _line_height(settings_label)
		# Title, blank, blank, hint and the scroll line take 5 lines; the rest are rows.
		settings_label.text = settings_menu.text(int(settings_label.size.y / lh) - 5)
	else:
		settings_label.text = ""
	_update_ladder_swatches()
	_update_focus_bars()
	_update_focus_frames()
	_update_modal_stripes()
	tactical_map_panel.queue_redraw()


## Alarm-coloured plate for the collapse summary and Chapter 11, the plain modal plate otherwise.
func _style_resolution_modal() -> void:
	var alarm: bool = loop.overlay_state == M0Loop.OVERLAY_CHAPTER_11 or (loop.overlay_state == M0Loop.OVERLAY_COLLAPSED and loop.collapse_phase != M0Loop.PHASE_PERKS)
	var variation: String = "AlertPanel" if alarm else "ModalPanel"
	if String(resolution_modal.theme_type_variation) != variation:
		HudTheme.style_panel(resolution_modal, variation)


func _update_modal_stripes() -> void:
	for stripe in _modal_stripes:
		var modal: Control = stripe.get_parent() as Control
		stripe.size = Vector2(8.0, modal.size.y - 2.0 * HudTheme.OUTLINE_PANEL)


## Places the focus bar of each list: the ladder cursor, the perk cursor, the settings cursor.
func _update_focus_bars() -> void:
	var f: GamepadFocus = hud.gamepad_focus
	# Ladder: asks print best-last above the spread, bids below it.
	var on_ladder: bool = f.current_zone == GamepadFocus.Zone.ORDER_BOOK and _ladder_shape[0] + _ladder_shape[1] > 0 and not _modal_has_focus()
	sidebar_focus_bar.visible = on_ladder
	if on_ladder:
		var buying: bool = f.active_side == GamepadFocus.OrderSide.BUY
		var line: int = 2 + (_ladder_shape[0] - 1 - f.ladder_index) if buying else 3 + _ladder_shape[0] + f.ladder_index
		var lh: float = _line_height(sidebar_label)
		HudTheme.place_focus_bar(sidebar_focus_bar, Rect2(8.0, sidebar_label.position.y + lh * float(line), SIDEBAR_VIEW.x - 16.0, lh))
	# Golden Parachutes list.
	var perks: bool = resolution_modal.visible and loop.overlay_state == M0Loop.OVERLAY_COLLAPSED and loop.collapse_phase == M0Loop.PHASE_PERKS
	resolution_focus_bar.visible = perks
	if perks:
		var lh2: float = _line_height(resolution_label)
		HudTheme.place_focus_bar(resolution_focus_bar, Rect2(resolution_label.position.x - 4.0, resolution_label.position.y + lh2 * float(2 + loop.perk_cursor), resolution_label.size.x + 4.0, lh2))
	# Settings list.
	settings_focus_bar.visible = settings_modal.visible
	if settings_modal.visible:
		var lh3: float = _line_height(settings_label)
		var max_rows: int = int(settings_label.size.y / lh3) - 5
		HudTheme.place_focus_bar(settings_focus_bar, Rect2(settings_label.position.x - 4.0, settings_label.position.y + lh3 * float(settings_menu.cursor_line(max_rows)), settings_label.size.x + 4.0, lh3))


## Draws the newest GalNet lines; a line wider than the panel scrolls sideways.
func _refresh_ticker() -> void:
	if ticker_labels.is_empty():
		return
	var font: Font = ticker_labels[0].get_theme_default_font()
	var measure := func(t: String) -> float: return font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, scaled_size(TICKER_FONT_SIZE)).x
	var lines: Array = hud.get_ticker_lines(measure)
	for i in ticker_labels.size():
		var tl: Label = ticker_labels[i]
		if i < lines.size():
			tl.text = lines[i]["text"]
			tl.add_theme_color_override("font_color", HudTheme.ticker_color(str(lines[i]["severity"])))
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
	out.append("%s  %s" % [Loc.station(hud.active_station).to_upper(), Loc.commodity(hud.active_commodity)])
	out.append("")
	var asks: Array = ladder["asks"]
	_ladder_shape = [asks.size(), (ladder["bids"] as Array).size()]
	for i in range(asks.size() - 1, -1, -1):
		out.append(tr("SIDE_ASK_ROW") % [">" if buying and i == f.ladder_index else " ", asks[i]["price"], asks[i]["quantity"]] + _maker_tag(asks[i]))
	out.append(tr("SIDE_SPREAD") % float(ladder["spread"]))
	var bids: Array = ladder["bids"]
	for i in bids.size():
		out.append(tr("SIDE_BID_ROW") % [">" if not buying and i == f.ladder_index else " ", bids[i]["price"], bids[i]["quantity"]] + _maker_tag(bids[i]))
	out.append("")
	out.append(tr("SIDE_ORDER") % [tr("ORDER_BUY") if buying else tr("ORDER_SELL"), f.order_qty])
	out.append(tr("SIDE_HELD") % [hud.get_cargo_qty(hud.active_commodity), Loc.commodity(hud.active_commodity), controller.get_total_cargo(), controller.cargo_capacity])
	var priv_lines: Array = []
	for line in [loop.pipeline_tag(hud.active_station, hud.active_commodity), loop.squeeze_tag(hud.active_station, hud.active_commodity), loop.hoard_tag(hud.active_station, hud.active_commodity), loop.toll_line(hud.active_station), _contract_sidebar_line()]:
		if line != "":
			priv_lines.append(line)
	priv_lines.append_array(loop.auction_lines(hud.active_station, hud.active_commodity))
	if not priv_lines.is_empty():
		out.append_array(PackedStringArray(priv_lines))
	var crisis_lines: Array = _crisis_sidebar_lines()
	if not crisis_lines.is_empty():
		out.append("")
		out.append_array(PackedStringArray(crisis_lines))
	if f.last_rejection_reason != "":
		out.append(tr("SIDE_REJECTED") % f.get_rejection_message())
	elif not f.last_executed_order.is_empty():
		var o: Dictionary = f.last_executed_order
		var who: String = _maker_name(str(o.get("counterparty_id", ""))) if str(o.get("counterparty_id", "")) != "" else str(o.get("counterparty", ""))
		out.append(tr("SIDE_FILLED") % [tr("ORDER_" + str(o["side"]).to_upper()), o["qty"], o["price"], tr("SIDE_FILLED_VS") % who if who != "" else "", tr("SIDE_FILLED_FEE") % int(o["fee"]) if int(o.get("fee", 0)) > 0 else ""])
	return "\n".join(out)


## A book maker's display name, through Loc: the default Ares Heavy or a baron
## from the attached world's registry.
func _maker_name(id: String) -> String:
	var english: String = ""
	if loop.market.world != null:
		english = str(loop.market.world.def(id).get("name", "")).to_upper()
	return Loc.maker(id, english)


## Ladder row suffix naming the level's maker (e.g. "  TITAN"). Only with a
## world attached: without one every level is Ares Heavy's and the tag is noise.
func _maker_tag(row: Dictionary) -> String:
	var id: String = str(row.get("maker", ""))
	if id == "" or loop.market.world == null:
		return ""
	return tr("SIDE_ROW_TAG") % Loc.maker_tag(id, _maker_name(id))


func _board_text() -> String:
	var out: PackedStringArray = [tr("BOARD_TITLE") % [Loc.station(hud.active_station).to_upper(), _maker_name(loop.market.maker_for(hud.active_station))], ""]
	for c in Transit.COMMODITIES:
		var key_prefix: String = "%s %-10s" % [">" if c == hud.active_commodity else " ", Loc.commodity(c)]
		if loop.market.has_book(hud.active_station, c):
			var lad: Dictionary = loop.market.ladder(hud.active_station, c, 1)
			var tag: String = loop.crisis_deck.tag_for(hud.active_station, c) if loop.crisis_deck != null else ""
			# A squeezed (or hoarded) book shows SQUEEZE (or its hoard tag) in place of its pipeline tag (the row has no room
			# for both in the pseudo locale); the sidebar still lists the pipeline.
			var pipe: String = loop.squeeze_tag(hud.active_station, c)
			if pipe == "":
				pipe = loop.hoard_tag(hud.active_station, c)
			if pipe == "":
				pipe = loop.auction_tag(hud.active_station, c)
			if pipe == "":
				pipe = loop.pipeline_tag(hud.active_station, c)
			if pipe != "":
				tag = pipe if tag == "" else "%s, %s" % [pipe, tag]
			out.append(tr("BOARD_ROW_LIVE") % [key_prefix, lad["best_bid"], lad["best_ask"], "   [%s]" % tag if tag != "" else ""])
		else:
			out.append(tr("BOARD_ROW_BASE") % [key_prefix, Transit.BASE_PRICES[hud.active_station][c]])
	out.append("")
	out.append(tr("BOARD_HINT"))
	return "\n".join(out)


## Index of the selected commodity's row in the board text (title + blank + rows).
func market_row_line() -> int:
	return 2 + maxi(0, Transit.COMMODITIES.find(hud.active_commodity))


func _update_market_highlight() -> void:
	if market_highlight == null or market_label == null or hud == null:
		return
	var lh: float = float(market_label.get_line_height() + market_label.get_theme_constant("line_spacing"))
	HudTheme.place_focus_bar(market_highlight, Rect2(market_label.position + Vector2(-4.0, lh * float(market_row_line())), Vector2(market_label.size.x, lh)))


## "1 round" / "N rounds".
static func _rounds_text(n: int) -> String:
	return Loc.t("ROUNDS_ONE") if n == 1 else Loc.t("ROUNDS_MANY") % n


## Map panel text: where the ship is, and either the route the selection would
## take (docked) or the voyage's ETA (in transit).
func _map_text() -> String:
	var out: PackedStringArray = []
	if controller.is_in_transit():
		var info: Dictionary = controller.transit_info()
		out.append(tr("MAP_TRANSIT") % [Loc.station(str(info["origin"])), Loc.station(str(info["destination"]))])
		out.append(tr("MAP_TRANSIT_ETA") % _rounds_text(int(info["eta_rounds"])))
		return "\n".join(out)
	out.append(tr("HUD_MAP_DOCKED") % Loc.station(controller.docked_at))
	var plan: Dictionary = controller.can_depart(hud.active_station)
	var dest_name: String = Loc.station(hud.active_station)
	if str(plan["reason"]) == "SAME_STATION":
		out.append(tr("MAP_PICK"))
	elif int(plan["rounds"]) > 0:
		if int(plan["toll"]) > 0:
			out.append(tr("MAP_ROUTE_TOLL") % [dest_name, _rounds_text(int(plan["rounds"])), int(plan["toll"])])
		else:
			out.append(tr("MAP_ROUTE") % [dest_name, _rounds_text(int(plan["rounds"]))])
	var refusal: String = loop.depart_message()
	if refusal != "":
		out.append(refusal)
	var open: Dictionary = loop.open_contract()
	if not open.is_empty():
		out.append(tr("MAP_CONTRACT") % [int(open["qty"]), Loc.commodity(str(open["commodity"])), Loc.station(str(controller.world.def(str(open["baron"])).get("anchor", ""))), int(open["due_round"])])
	return "\n".join(out)


func _fleet_text() -> String:
	var parts: PackedStringArray = [tr("FLEET_HEADER") % controller.ships.size()]
	for c in controller.cargo:
		parts.append(tr("FLEET_CARGO") % [Loc.commodity(c), int(controller.cargo[c])])
	return "\n".join(parts)


func _resolution_text() -> String:
	if loop.overlay_state == M0Loop.OVERLAY_CRISIS:
		return _crisis_text()
	if loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
		return _contract_text()
	if loop.overlay_state == M0Loop.OVERLAY_CHAPTER_11:
		var a: Dictionary = controller.assess()
		return "%s\n\n%s\n%s\n\n%s" % [tr("CH11_TITLE"), tr("CH11_INSOLVENT") % [_fmt(int(a["total_debt"])), _fmt(int(a["liquidation_value"]))], tr("CH11_HALTED"), tr("CH11_PRESS_X")]
	if loop.collapse_phase == M0Loop.PHASE_PERKS:
		return _perks_text()
	return _summary_text()


func _crisis_text() -> String:
	var c: Dictionary = loop.current_crisis()
	if c.is_empty():
		return ""
	var tier_label: String = Loc.tier_label(str(c["tier"]), str(loop.crisis_deck.data.get("tiers", {}).get(str(c["tier"]), {}).get("label", c["tier"])))
	var out: PackedStringArray = [tr("CRISIS_TITLE") % [tier_label, Loc.crisis_name(c).to_upper()], "", Loc.crisis_text(c), ""]
	out.append(tr("CRISIS_DURATION") % [int(c["rounds"]), int(c["expires_round"])])
	for line in CrisisDeck.describe(c):
		out.append("  - " + str(line))
	out.append("")
	out.append(tr("CRISIS_ACK"))
	return "\n".join(out)


## The defense contract offer modal (Epic 3 task 4): what is asked, what it pays,
## what a miss costs, and when Ares squeezes. A accepts, B declines.
func _contract_text() -> String:
	var o: Dictionary = loop.current_offer()
	if o.is_empty():
		return ""
	var w: Barons = controller.world
	var id: String = str(o["baron"])
	var p: Dictionary = w.def(id).get("params", {})
	var com: String = Loc.commodity(str(o["commodity"]))
	var qty: int = int(o["qty"])
	var value: int = qty * int(o["unit_px"])
	var out: PackedStringArray = [
		tr("CONTRACT_TITLE") % _maker_name(id), "",
		tr("CONTRACT_BODY") % [qty, com, Loc.station(str(w.def(id).get("anchor", ""))), int(o["due_round"])],
		tr("CONTRACT_PAY") % [int(o["unit_px"]), value],
		tr("CONTRACT_PENALTY") % (value * int(p.get("contract_penalty_bps", 0)) / 10000),
		tr("CONTRACT_SQUEEZE") % [int(p.get("squeeze_window_rounds", 0)), qty, com, int(p.get("squeeze_price_bps_max", 0)) / 100],
		"", tr("CONTRACT_KEYS")]
	return "\n".join(out)


## One sidebar line for the accepted contract ("" when none).
func _contract_sidebar_line() -> String:
	var c: Dictionary = loop.open_contract()
	if c.is_empty():
		return ""
	return tr("SIDE_CONTRACT") % [int(c["qty"]), Loc.commodity(str(c["commodity"])), int(c["due_round"])]


func _crisis_sidebar_lines() -> Array:
	var out: Array = []
	if loop == null or loop.crisis_deck == null:
		return out
	var round_num: int = controller.get_current_round()
	for c in loop.crisis_deck.active:
		out.append(tr("CRISIS_SIDEBAR") % [Loc.crisis_name(c).to_upper(), maxi(0, int(c["expires_round"]) - round_num)])
		for line in CrisisDeck.describe(c, true):
			out.append("  " + str(line))
	return out


func _summary_text() -> String:
	var r: Dictionary = loop.run_summary()
	return "%s\n\n%s\n\n%s\n%s\n%s\n%s\n\n%s" % [
		tr("SUM_TITLE"), tr("SUM_CAUSE") % _cause_text(str(r["reason"])),
		tr("SUM_NET_WORTH") % _fmt(int(r["net_worth"])), tr("SUM_PEAK") % _fmt(int(r["peak_net_worth"])),
		tr("SUM_ROUNDS") % int(r["rounds_survived"]), tr("SUM_SEVERANCE") % [int(r["severance_awarded"]), int(r["severance_balance"])],
		tr("SUM_PRESS_A")]


## Why the run ended, from RunController.end_reason ("collapse", "bankruptcy", "manual").
static func _cause_text(reason: String) -> String:
	match reason:
		"bankruptcy":
			return Loc.t("SUM_CAUSE_BANKRUPTCY")
		"manual":
			return Loc.t("SUM_CAUSE_MANUAL")
	return Loc.t("SUM_CAUSE_COLLAPSE")


func _perks_text() -> String:
	var rows: Array = loop.perk_rows()
	var out: PackedStringArray = [tr("PERKS_TITLE") % controller.profile.severance_points, ""]
	for i in rows.size():
		var row: Dictionary = rows[i]
		var tag: String = tr("PERK_OWNED") if bool(row["owned"]) else ("%d" % int(row["cost"]) if bool(row["can_buy"]) else tr("PERK_LOCKED") % int(row["cost"]))
		out.append(tr("PERK_ROW") % [">" if i == loop.perk_cursor else " ", int(row["tier"]), Loc.perk_name(row), Loc.perk_branch(str(row["branch"])), tag])
	out.append("%s %s" % [">" if loop.perk_cursor >= rows.size() else " ", tr("PERK_START")])
	out.append("")
	out.append(tr("PERK_HINT"))
	return "\n".join(out)


static func _fmt(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out
