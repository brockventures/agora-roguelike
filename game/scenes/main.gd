class_name MainScene
extends Control
## Root Scene Controller for Agora Roguelike (M0 Vertical Slice #83).
##
## Assembles the decoupled presentation models and CRT retro shader pipeline
## into a unified 1280x800 Steam Deck viewport using SubViewportContainer.
##
## HUD v3 "command deck" (design system frame 3a, part of #73 Epic 6: Visual Identity):
## the tactical map is the root; a stacked-chip header sits above it; below it the
## deck holds the order ladder (depth bars), the order ticket and the crisis card; the
## GalNet ticker runs along the map's foot; modals wear the title-band variant. The
## layout rects are in HudLayout, the component builders in HudKit.

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
## The order ladder (depth bars), left deck column. Node name stays "SidebarPanel".
var sidebar_panel: Panel = null
var ticket_panel: Panel = null
var card_panel: Panel = null
var ticker_panel: Panel = null

## The component kit; every HUD text node is a Label it made and registered, built in
## _build_readouts (a scene instantiated outside the tree, as the unit tests do, never
## creates them).
var kit: HudKit = HudKit.new()
var wordmark_label: Label = null
var ticker_labels: Array[Label] = []
var ticker_chips: Array = []
var map_label: Label = null
## Shared readable palette: every HUD label and every opaque modal body uses these.
const HUD_TEXT_COLOR := HudTheme.BONE
const MODAL_BG_COLOR := Color(0.1725, 0.2078, 0.2314, 1.0)
## Text on the light paper panels (map, ladder).
const PAPER_TEXT_COLOR := HudTheme.INK
## Gamepad focus, in the new style (#105): the focused zone gets a heavy coloured frame
## (rust on the paper panels, ochre on the slate ones) and the focused row a flat bar with
## an ink or ochre outline. The row marker glyph stays, so focus never depends on colour alone.
const FOCUS_BAR_PAPER_FILL := HudTheme.OCHRE
const FOCUS_BAR_PAPER_EDGE := HudTheme.INK
const FOCUS_BAR_DARK_FILL := HudTheme.RUST_DARK
const FOCUS_BAR_DARK_EDGE := HudTheme.OCHRE

## "PAUSED - resumed from sleep" banner, shown while a wake-pause is active.
var sleep_modal: Panel = null
var sleep_label: Label = null
## How many times audio has been re-armed after a wake (read by tests).
var audio_rearm_count: int = 0

## The Market tab's quote board (a paper panel over the map).
var market_modal: Panel = null
var resolution_modal: Panel = null
## Body text of the Chapter 11 / crisis / contract modals.
var resolution_label: Label = null
var sfx_players: Array[AudioStreamPlayer] = []
var drone_player: AudioStreamPlayer = null
var market_highlight: ColorRect = null
## Focus bars (rows) and zone frames, built in _build_readouts.
var sidebar_focus_bar: ColorRect = null
var resolution_focus_bar: ColorRect = null
var settings_focus_bar: ColorRect = null
var focus_frames: Dictionary = {}
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
## Voices for routine UI feedback. PRIORITY_VOICES more are reserved for alarms and
## market bells, which may also steal the oldest routine voice if all are busy.
const SFX_POLYPHONY: int = 4
const PRIORITY_VOICES: int = 2

var is_initialized: bool = false

## Accessibility (#37): text scale, palette, bindings, language. Persisted next to
## the profile once enable_persistence() runs; headless runs never write them.
var settings: AccessibilitySettings = AccessibilitySettings.new()
var settings_menu: SettingsMenu = null
var settings_modal: Panel = null
var settings_label: Label = null
## Label metadata key holding the font size at 100% text scale.
const BASE_SIZE_META: String = HudKit.BASE_SIZE_META
## Label metadata flag: this label sits in a view that scrolls when its content is taller
## (set while the text scale is above 100%; at 100% the text must simply fit).
const SCROLLS_META: String = "scrolls_vertically"
## Marquee timing for the views that scroll vertically (the deck notes, a modal body).
const SIDEBAR_DWELL_TOP: float = 4.0
const SIDEBAR_DWELL_BOTTOM: float = 2.5
const SIDEBAR_SCROLL_SPEED: float = 36.0
## Font size of the tactical map's station names at 100% text scale.
const MAP_FONT_SIZE: int = 14

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
	_scroll_t += delta
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
		if hud_container.has_node("TicketPanel"):
			ticket_panel = hud_container.get_node("TicketPanel") as Panel
		if hud_container.has_node("CardPanel"):
			card_panel = hud_container.get_node("CardPanel") as Panel
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
		"header_rect": HudLayout.HEADER_RECT,
		"tactical_map_rect": HudLayout.MAP_RECT,
		"sidebar_rect": HudLayout.LADDER_RECT,
		"ticket_rect": HudLayout.TICKET_RECT,
		"card_rect": HudLayout.CARD_RECT,
		"ticker_rect": HudLayout.TICKER_RECT,
		"modal_overlay_rect": HudLayout.BOARD_RECT,
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



# --- Text scale, change gating, scrolling views ---

## Font size for a label drawn at `base` px at 100%, under the current scale.
func scaled_size(base: int) -> int:
	return int(round(float(base) * settings.text_scale))


## Per-section change gate: true (and remembered) when `value` differs from the last call
## for `key`. The readouts refresh every frame; a section re-lays out only when it changed.
var _sig: Dictionary = {}
func _changed(key: String, value: Variant) -> bool:
	var s: String = var_to_str(value)
	if _sig.get(key, "") == s:
		return false
	_sig[key] = s
	return true


## Seconds into the scroll cycle shared by every vertically scrolling view.
var _scroll_t: float = 0.0
## Views that scroll when their content is taller: [{"clip": Control, "content": Control}].
var _scrollers: Array = []


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


func _make_scroller(parent: Control, name: String) -> Dictionary:
	var clip := Control.new()
	clip.name = name
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(clip)
	var content := Control.new()
	content.name = name + "Content"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip.add_child(content)
	var view: Dictionary = {"clip": clip, "content": content}
	_scrollers.append(view)
	return view


## Px by which a scrolling view's content outgrows its clip (0 when it fits).
func scroll_overflow(view: Dictionary) -> float:
	return maxf(0.0, (view["content"] as Control).size.y - (view["clip"] as Control).size.y)


func _update_scrollers() -> void:
	for view in _scrollers:
		(view["content"] as Control).position.y = -marquee_offset(_scroll_t, scroll_overflow(view))


## Applies the text scale to every readout and re-lays the sections that grow with it.
func apply_text_scale() -> void:
	if wordmark_label == null:
		return
	kit.apply_scale(settings.text_scale)
	_sig.clear()
	for l in kit.labels:
		if l.has_meta(SCROLLS_META):
			l.set_meta(SCROLLS_META, settings.text_scale > 1.0)
	if tactical_map_panel != null:
		tactical_map_panel.queue_redraw()
	if loop != null and controller != null and hud != null:
		_refresh_readouts()


## Every HUD text Label (the registry the fit and localization tests walk).
func text_labels() -> Array[Label]:
	return kit.labels


## The text of the visible labels under `root`, one per line, in node order: what a
## player reads on that part of the screen.
func panel_text(root: Node) -> String:
	var out: PackedStringArray = []
	_collect_text(root, out)
	return "\n".join(out)


func _collect_text(n: Node, out: PackedStringArray) -> void:
	for c in n.get_children():
		if c is CanvasItem and not (c as CanvasItem).visible:
			continue
		if c is Label and (c as Label).text != "":
			out.append((c as Label).text)
		_collect_text(c, out)


## Whether a registry label is on screen: it and every ancestor up to the HUD container visible.
func label_shown(l: Label) -> bool:
	var n: Node = l
	while n != null and n != hud_container:
		if n is CanvasItem and not (n as CanvasItem).visible:
			return false
		n = n.get_parent()
	return true


# --- Building the HUD ---

func _build_readouts() -> void:
	if hud_container == null or wordmark_label != null:
		return
	kit.text_scale = settings.text_scale
	_build_header()
	_build_map_overlay()
	_build_ladder()
	_build_ticket()
	_build_card()
	_build_ticker()
	_build_board()
	_build_fleet()
	_build_modals()
	_build_focus_frames()
	apply_text_scale()


func _make_panel(name: String, rect: Rect2, variation: String) -> Panel:
	var p := Panel.new()
	p.name = name
	HudTheme.style_panel(p, variation)
	p.position = rect.position
	p.size = rect.size
	return p


# --- Header: wordmark, paper tabs, stacked stat chips ---

var _hdr: Dictionary = {}

func _build_header() -> void:
	var p: Panel = header_panel
	wordmark_label = kit.label(p, "Wordmark", HudTheme.ROLE_TITLE, 22, HudTheme.OCHRE)
	wordmark_label.text = tr("HUD_TITLE")
	_hdr["rule"] = kit.plate(p, Rect2(0, 0, 3, 56), HudTheme.INK)
	_hdr["lb"] = kit.label(p, "PadLB", HudTheme.ROLE_LABEL, 12, HudTheme.BONE_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	_hdr["rb"] = kit.label(p, "PadRB", HudTheme.ROLE_LABEL, 12, HudTheme.BONE_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	var tabs: Array = []
	for i in M0Loop.TAB_NAMES.size():
		var plate: HudKit.Plate = kit.plate(p, Rect2(), HudTheme.PAPER, HudTheme.INK, 3.0)
		var patch: HudKit.Plate = kit.plate(p, Rect2(), HudTheme.PAPER)
		var l: Label = kit.label(p, "Tab%d" % i, HudTheme.ROLE_LABEL, 14, HudTheme.BONE, HORIZONTAL_ALIGNMENT_CENTER)
		tabs.append({"plate": plate, "patch": patch, "label": l})
	_hdr["tabs"] = tabs
	_hdr["view"] = kit.pad_glyph(p, "PadView", tr("HUD_PAD_VIEW"), tr("HUD_PROMPT_MENU"), HudTheme.BONE_DIM)
	var chips: Array = []
	for key in ["LANG", "CREDITS", "DEBT", "SPEED", "DOOMSDAY"]:
		var plate: HudKit.Plate = kit.plate(p, Rect2(), Color(0, 0, 0, 0))
		var edge: HudKit.Plate = kit.plate(p, Rect2(), HudTheme.INK)
		var cap: Label = kit.label(p, "Chip%sLabel" % key, HudTheme.ROLE_LABEL, 12, HudTheme.BONE_DIM)
		var val: Label = kit.label(p, "Chip%sValue" % key, HudTheme.ROLE_READOUT, 20, HudTheme.BONE)
		chips.append({"key": key, "plate": plate, "edge": edge, "label": cap, "value": val})
	_hdr["chips"] = chips


func _refresh_header() -> void:
	var h: Dictionary = hud.get_header_telemetry()
	var secs: int = int(h["ticks_remaining"]) / DoomsdayClock.DEFAULT_TICKS_PER_SECOND
	var stage: String = str(h["stage_name"])
	var texts: Array = [
		[tr("HUD_CHIP_LANG"), Loc.locale_label()],
		[tr("HUD_CHIP_CREDITS"), _fmt(int(h["cr"]))],
		[tr("HUD_CHIP_DEBT"), _fmt(int(h["total_debt"]))],
		[tr("HUD_CHIP_SPEED"), str(h["speed_label"])],
		[tr("HUD_CHIP_DOOMSDAY") % Loc.stage(stage), "%d:%02d" % [secs / 60, secs % 60]],
	]
	var tab_names: Array = []
	for i in M0Loop.TAB_NAMES.size():
		tab_names.append(Loc.tab(i))
	if not _changed("header", [texts, tab_names, int(loop.tab), stage != "NORMAL", Loc.current()]):
		return
	var chips: Array = _hdr["chips"]
	for i in chips.size():
		var c: Dictionary = chips[i]
		(c["label"] as Label).text = texts[i][0]
		(c["value"] as Label).text = texts[i][1]
	var alarm: bool = stage != "NORMAL"
	(chips[4]["label"] as Label).add_theme_color_override("font_color", HudTheme.BONE if alarm else HudTheme.BONE_DIM)
	var dd: HudKit.Plate = chips[4]["plate"]
	dd.fill = HudTheme.RUST_DARK if alarm else Color(0, 0, 0, 0)
	dd.cut = HudTheme.RUST if alarm else Color(0, 0, 0, 0)
	dd.cut_size = 48.0
	_layout_header(tab_names)


func _layout_header(tab_names: Array) -> void:
	# Natural chip widths first: when they cannot share the bar with the tabs, the lowest
	# priority furniture goes (the menu prompt, then the wordmark) before any chip narrows.
	var chips: Array = _hdr["chips"]
	var nat: Array = []
	var total: float = 0.0
	for c in chips:
		var cl: Label = c["label"]
		var cv: Label = c["value"]
		var w: float = maxf(kit.natural_width(cl, cl.text), kit.natural_width(cv, cv.text)) + 32.0
		nat.append(w)
		total += w
	var wl: float = kit.text_width(wordmark_label, wordmark_label.text)
	var lh: float = HudKit.line_height(wordmark_label)
	var lb: Label = _hdr["lb"]
	var rb: Label = _hdr["rb"]
	lb.text = tr("HUD_PAD_LB")
	rb.text = tr("HUD_PAD_RB")
	var tab_h: float = 40.0
	var padw: float = HudKit.text_width(lb, lb.text) + 12.0
	var tabs_w: float = 2.0 * (padw + 2.0) + 14.0
	for i in M0Loop.TAB_NAMES.size():
		var tl: Label = (_hdr["tabs"] as Array)[i]["label"]
		tabs_w += HudKit.text_width(tl, tab_names[i]) + 28.0 + 2.0
	var view: Control = _hdr["view"]
	kit.set_pad_glyph(view, tr("HUD_PAD_VIEW"), tr("HUD_PROMPT_MENU"), HudTheme.BONE_DIM)
	var show_mark: bool = true
	var show_view: bool = true
	var start: float = 20.0 + wl + 20.0 + 3.0 + 12.0
	if start + tabs_w + 16.0 + view.size.x + 16.0 + total > 1276.0:
		show_view = false
	if start + tabs_w + 16.0 + total > 1276.0:
		show_mark = false
		start = 20.0
	wordmark_label.visible = show_mark
	(_hdr["rule"] as CanvasItem).visible = show_mark
	view.visible = show_view
	wordmark_label.position = Vector2(20.0, 4.0 + (56.0 - lh) * 0.5)
	wordmark_label.size = Vector2(wl + 2.0, lh)
	var rule: HudKit.Plate = _hdr["rule"]
	rule.position = Vector2(20.0 + wl + 20.0, 4.0)
	var x: float = start
	lb.position = Vector2(x, 64.0 - tab_h + 3.0)
	lb.size = Vector2(padw, tab_h - 10.0)
	x += padw + 2.0
	var tabs: Array = _hdr["tabs"]
	for i in tabs.size():
		var t: Dictionary = tabs[i]
		var l: Label = t["label"]
		l.text = tab_names[i]
		var w: float = HudKit.text_width(l, l.text) + 28.0
		var selected: bool = i == int(loop.tab)
		var plate: HudKit.Plate = t["plate"]
		var patch: HudKit.Plate = t["patch"]
		plate.visible = selected
		patch.visible = selected
		plate.position = Vector2(x, 64.0 - tab_h)
		plate.size = Vector2(w, tab_h)
		patch.position = Vector2(x + 3.0, 56.0)
		patch.size = Vector2(w - 6.0, 8.0)
		plate.queue_redraw()
		patch.queue_redraw()
		l.add_theme_color_override("font_color", HudTheme.INK if selected else HudTheme.BONE)
		l.position = Vector2(x, 64.0 - tab_h + 3.0)
		l.size = Vector2(w, tab_h - 10.0)
		x += w + 2.0
	rb.position = Vector2(x, 64.0 - tab_h + 3.0)
	rb.size = Vector2(padw, tab_h - 10.0)
	x += padw + 16.0
	view.position = Vector2(x, 4.0 + (56.0 - view.size.y) * 0.5)
	var free_from: float = x + (view.size.x if show_view else 0.0) + 16.0
	# Chips fill from the right edge; narrow them on the width axis if they would meet the tabs.
	var budget: float = 1276.0 - free_from
	var shrink: float = 1.0 if total <= budget else budget / total
	var right: float = 1276.0
	for k in range(chips.size() - 1, -1, -1):
		var c: Dictionary = chips[k]
		var cl: Label = c["label"]
		var cv: Label = c["value"]
		var w: float = float(nat[k]) * shrink
		kit.fit_text(cl, cl.text, w - 32.0)
		kit.fit_text(cv, cv.text, w - 32.0)
		var lh1: float = HudKit.line_height(cl)
		var lh2: float = HudKit.line_height(cv)
		var top: float = 4.0 + (56.0 - lh1 - lh2) * 0.5
		var plate: HudKit.Plate = c["plate"]
		plate.position = Vector2(right - w, 4.0)
		plate.size = Vector2(w, 56.0)
		plate.queue_redraw()
		var edge: HudKit.Plate = c["edge"]
		edge.position = Vector2(right - w, 4.0)
		edge.size = Vector2(3.0 if k == chips.size() - 1 else 2.0, 56.0)
		cl.position = Vector2(right - w + 16.0, top)
		cl.size = Vector2(w - 32.0, lh1)
		cv.position = Vector2(right - w + 16.0, top + lh1)
		cv.size = Vector2(w - 32.0, lh2)
		right -= w



# --- Map: status text over the tactical map ---

func _build_map_overlay() -> void:
	map_label = kit.label(tactical_map_panel, "MapStatus", HudTheme.ROLE_HINT, 14, PAPER_TEXT_COLOR)
	map_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	map_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# A paper halo keeps the text legible where an orbit ring passes behind it.
	map_label.add_theme_constant_override("outline_size", 6)
	map_label.add_theme_color_override("font_outline_color", HudTheme.PAPER)
	tactical_map_panel.clip_contents = true
	tactical_map_panel.draw.connect(_draw_map)


func _refresh_map_status() -> void:
	var text: String = _map_text()
	if not _changed("map_status", [text, Loc.current()]):
		return
	map_label.text = text
	var w: float = 460.0
	map_label.position = Vector2(16.0, 8.0)
	map_label.size = Vector2(w, HudKit.wrapped_height(map_label, text, w))


## Map status text: where the ship is, and either the route the selection would
## take (docked) or the voyage's ETA (in transit), the refusal and the open contract.
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


## "1 round" / "N rounds".
static func _rounds_text(n: int) -> String:
	return Loc.t("ROUNDS_ONE") if n == 1 else Loc.t("ROUNDS_MANY") % n


# --- Ticker: category chip + scrolling body, two lines along the map's foot ---

func _build_ticker() -> void:
	for i in OrbitalHUD.TICKER_VISIBLE_LINES:
		var chip: HudKit.Plate = kit.tag(ticker_panel, "TickerChip%d" % i)
		var view: Dictionary = {"clip": Control.new()}
		var clip: Control = view["clip"]
		clip.name = "TickerClip%d" % i
		clip.clip_contents = true
		clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ticker_panel.add_child(clip)
		var tl: Label = kit.label(clip, "TickerText%d" % i, HudTheme.ROLE_BODY, 14, HudTheme.INK)
		tl.autowrap_mode = TextServer.AUTOWRAP_OFF
		tl.size = Vector2(4096.0, 24.0)
		ticker_labels.append(tl)
		ticker_chips.append(chip)


## Chip colours by severity: ochre for a warning, the dark plates carry bone text at 4.5:1.
static func _severity_chip(severity: String) -> Array:
	match severity.to_upper():
		"CRITICAL":
			return [HudTheme.RUST_DARK, HudTheme.BONE]
		"WARNING":
			return [HudTheme.OCHRE, HudTheme.INK]
	return [HudTheme.TEAL_DARK, HudTheme.BONE]


func _refresh_ticker() -> void:
	if ticker_labels.is_empty():
		return
	var tl0: Label = ticker_labels[0]
	var measure := func(t: String) -> float: return HudKit.text_width(tl0, t)
	# Row height and the shared start of the scrolling text, from the chip widths.
	var raw: Array = hud.get_ticker_lines(measure, 4096.0, true)
	var chip_w: float = 0.0
	for i in ticker_chips.size():
		var chip: HudKit.Plate = ticker_chips[i]
		var line: Dictionary = raw[i] if i < raw.size() else {}
		var colors: Array = _severity_chip(str(line.get("severity", "INFO")))
		kit.set_tag(chip, str(line.get("category", "")), colors[0], colors[1], 220.0)
		chip_w = maxf(chip_w, chip.size.x)
	var row_h: float = maxf(26.0, HudKit.line_height(tl0) + 4.0)
	var chip_h: float = (ticker_chips[0] as HudKit.Plate).size.y
	row_h = maxf(row_h, chip_h + 4.0)
	var strip_h: float = 8.0 + row_h * float(ticker_labels.size())
	ticker_panel.position = Vector2(HudLayout.TICKER_RECT.position.x, HudLayout.TICKER_RECT.end.y - strip_h)
	ticker_panel.size = Vector2(HudLayout.TICKER_RECT.size.x, strip_h)
	var x0: float = 12.0 + chip_w + 10.0
	var view_w: float = ticker_panel.size.x - x0 - 12.0
	var lines: Array = hud.get_ticker_lines(measure, view_w, true)
	for i in ticker_labels.size():
		var chip: HudKit.Plate = ticker_chips[i]
		var tl: Label = ticker_labels[i]
		var clip: Control = tl.get_parent()
		var y: float = 6.0 + row_h * float(i)
		chip.visible = i < lines.size()
		clip.visible = i < lines.size()
		chip.position = Vector2(12.0, y + (row_h - chip.size.y) * 0.5)
		clip.position = Vector2(x0, y)
		clip.size = Vector2(view_w, row_h)
		tl.size = Vector2(4096.0, row_h)
		if i < lines.size():
			tl.text = str(lines[i]["body"])
			tl.position.x = -float(lines[i]["offset"])
		else:
			tl.text = ""
			tl.position.x = 0.0


# --- Order ladder: depth-bar rows with a glyph and a word (colour never alone) ---

var _ladder: Dictionary = {}

func _build_ladder() -> void:
	var p: Panel = sidebar_panel
	sidebar_focus_bar = HudTheme.make_focus_bar(p, FOCUS_BAR_PAPER_FILL, FOCUS_BAR_PAPER_EDGE)
	_ladder["title"] = kit.label(p, "LadderTitle", HudTheme.ROLE_TITLE, 18, PAPER_TEXT_COLOR)
	_ladder["hint"] = kit.label(p, "LadderHint", HudTheme.ROLE_LABEL, 12, HudTheme.RUST_DARK, HORIZONTAL_ALIGNMENT_RIGHT)
	_ladder["rule_top"] = kit.plate(p, Rect2(), HudTheme.INK)
	_ladder["rule_l"] = kit.plate(p, Rect2(), HudTheme.INK)
	_ladder["rule_r"] = kit.plate(p, Rect2(), HudTheme.INK)
	_ladder["spread"] = kit.label(p, "LadderSpread", HudTheme.ROLE_LABEL, 12, PAPER_TEXT_COLOR, HORIZONTAL_ALIGNMENT_CENTER)
	_ladder["more_asks"] = kit.label(p, "LadderMoreAsks", HudTheme.ROLE_LABEL, 12, HudTheme.RUST_DARK)
	_ladder["more_bids"] = kit.label(p, "LadderMoreBids", HudTheme.ROLE_LABEL, 12, HudTheme.TEAL_DARK, HORIZONTAL_ALIGNMENT_RIGHT)
	var rows: Array = []
	for i in GamepadFocus.MAX_LADDER_DEPTH * 2:
		var bar: HudKit.Plate = kit.plate(p, Rect2(), HudTheme.PAPER, HudTheme.INK, 2.0)
		var row: Dictionary = {
			"marker": kit.label(p, "LadderMarker%d" % i, HudTheme.ROLE_LABEL, 14, PAPER_TEXT_COLOR, HORIZONTAL_ALIGNMENT_CENTER),
			"tag": kit.tag(p, "LadderSide%d" % i),
			"price": kit.label(p, "LadderPrice%d" % i, HudTheme.ROLE_READOUT, 17, PAPER_TEXT_COLOR, HORIZONTAL_ALIGNMENT_RIGHT),
			"bar": bar,
			"qty": kit.label(p, "LadderQty%d" % i, HudTheme.ROLE_READOUT, 15, PAPER_TEXT_COLOR, HORIZONTAL_ALIGNMENT_RIGHT),
			"maker": kit.tag(p, "LadderMaker%d" % i),
		}
		rows.append(row)
	_ladder["rows"] = rows
	_ladder["shape"] = [0, 0]


## Text colour for a label sitting on `fill`: ink or bone, whichever contrasts more.
static func _ink_on(fill: Color) -> Color:
	return HudTheme.INK if HudTheme.contrast(HudTheme.INK, fill) >= HudTheme.contrast(HudTheme.BONE, fill) else HudTheme.BONE


## A book maker's display name, through Loc: the default Ares Heavy or a baron
## from the attached world's registry.
func _maker_name(id: String) -> String:
	var english: String = ""
	if loop.market.world != null:
		english = str(loop.market.world.def(id).get("name", "")).to_upper()
	return Loc.maker(id, english)


## Ladder row chip naming the level's maker (e.g. "TITAN"). Only with a world
## attached: without one every level is Ares Heavy's and the tag is noise.
func _maker_chip(row: Dictionary) -> String:
	var id: String = str(row.get("maker", ""))
	if id == "" or loop.market.world == null:
		return ""
	return Loc.maker_tag(id, _maker_name(id))


func _refresh_ladder() -> void:
	var side: Dictionary = hud.get_sidebar_telemetry()
	var ladder: Dictionary = side["order_book_ladder"]
	var asks: Array = ladder["asks"]
	var bids: Array = ladder["bids"]
	var f: GamepadFocus = hud.gamepad_focus
	var buying: bool = f.active_side == GamepadFocus.OrderSide.BUY
	var shape: Array = _ladder["shape"]
	shape[0] = asks.size()
	shape[1] = bids.size()
	var on_ladder: bool = f.current_zone == GamepadFocus.Zone.ORDER_BOOK and asks.size() + bids.size() > 0 and not _modal_has_focus()
	var makers: Array = []
	for r in asks:
		makers.append(_maker_chip(r))
	for r in bids:
		makers.append(_maker_chip(r))
	var maker_name: String = _maker_name(loop.market.maker_for(hud.active_station))
	if not _changed("ladder", [ladder, buying, f.ladder_index, on_ladder, makers, hud.active_station, hud.active_commodity, maker_name, Palette.current(), Loc.current()]):
		return
	var rows: Array = _ladder["rows"]
	var title: Label = _ladder["title"]
	var hint: Label = _ladder["hint"]
	var inner_w: float = sidebar_panel.size.x - 2.0 * HudLayout.BORDER
	var x0: float = HudLayout.BORDER
	# Title row.
	var title_text: String = tr("HUD_LADDER_TITLE") % [Loc.commodity(hud.active_commodity).to_upper(), maker_name]
	hint.text = tr("HUD_LADDER_HINT")
	var hw: float = kit.natural_width(hint, hint.text)
	var tw: float = kit.fit_text(title, title_text, inner_w - 2.0 * HudLayout.PAD - hw - 8.0)
	var title_h: float = maxf(36.0, HudKit.line_height(title) + 12.0)
	title.position = Vector2(x0 + HudLayout.PAD, x0 + (title_h - HudKit.line_height(title)) * 0.5)
	title.size = Vector2(tw + 2.0, HudKit.line_height(title))
	if title.autowrap_mode != TextServer.AUTOWRAP_OFF:
		var tbox: float = inner_w - 2.0 * HudLayout.PAD - hw - 8.0
		var twh: float = HudKit.wrapped_height(title, title_text, tbox)
		title_h = maxf(title_h, twh + 12.0)
		title.position = Vector2(x0 + HudLayout.PAD, x0 + (title_h - twh) * 0.5)
		title.size = Vector2(tbox, twh)
	var hh: float = HudKit.line_height(hint)
	hint.position = Vector2(x0 + inner_w - HudLayout.PAD - hw, x0 + (title_h - hh) * 0.5)
	hint.size = Vector2(hw, hh)
	var rt: HudKit.Plate = _ladder["rule_top"]
	rt.position = Vector2(x0, x0 + title_h)
	rt.size = Vector2(inner_w, 2.0)
	# Row geometry from the text scale: how many levels fit each side of the spread.
	var first: Label = rows[0]["price"]
	var row_h: float = maxf(28.0, HudKit.line_height(first) + 8.0)
	var spread_l: Label = _ladder["spread"]
	var rule_h: float = maxf(22.0, HudKit.line_height(spread_l) + 6.0)
	var y0: float = x0 + title_h + 2.0 + 6.0
	var avail: float = sidebar_panel.size.y - HudLayout.BORDER - 6.0 - y0 - rule_h
	var k: int = clampi(int(floor(avail / (2.0 * (row_h + 2.0)))), 1, GamepadFocus.MAX_LADDER_DEPTH)
	# The window follows the cursor on the active side; the other side shows top of book.
	var off_a: int = maxi(0, mini(f.ladder_index - k + 1, asks.size() - k)) if buying else 0
	var off_b: int = 0 if buying else maxi(0, mini(f.ladder_index - k + 1, bids.size() - k))
	var shown_a: int = clampi(asks.size() - off_a, 0, k)
	var shown_b: int = clampi(bids.size() - off_b, 0, k)
	# Column widths from the widest text in each column.
	var w_tag: float = 0.0
	for s in [Palette.ASK_GLYPH + " " + tr("HUD_SIDE_ASK"), Palette.BID_GLYPH + " " + tr("HUD_SIDE_BID")]:
		w_tag = maxf(w_tag, kit.natural_width(rows[0]["tag"].get_meta("text"), s) + 12.0)
	var w_price: float = kit.natural_width(first, "9999.9")
	var w_qty: float = kit.natural_width(rows[0]["qty"], tr("HUD_LADDER_QTY") % 999)
	var w_maker: float = 0.0
	for m in makers:
		if m != "":
			w_maker = maxf(w_maker, kit.natural_width(rows[0]["maker"].get_meta("text"), m) + 12.0)
	w_maker = minf(w_maker, 96.0)
	var w_mark: float = maxf(14.0, kit.natural_width(rows[0]["marker"], tr("HUD_LADDER_MARKER")) + 2.0)
	var row_x: float = x0 + 4.0
	var row_w: float = inner_w - 8.0
	var gap: float = 8.0
	var cols_w: float = 8.0 + w_mark + gap + w_tag + gap + w_price + gap + w_qty + (gap + w_maker if w_maker > 0.0 else 0.0) + gap + 8.0
	var w_bar: float = maxf(24.0, row_w - cols_w)
	var maxq: float = 1.0
	for r in asks + bids:
		maxq = maxf(maxq, float(r["quantity"]))
	var spread_y: float = y0 + float(k) * (row_h + 2.0)
	for i in rows.size():
		var is_ask: bool = i < GamepadFocus.MAX_LADDER_DEPTH
		var slot: int = i if is_ask else i - GamepadFocus.MAX_LADDER_DEPTH
		var row: Dictionary = rows[i]
		var data: Dictionary = {}
		var absolute: int = -1
		var y: float = 0.0
		if is_ask:
			# Asks print best-last above the spread: slot s from the top shows the (k-1-s)th level.
			var depth: int = k - 1 - slot
			if slot < k and off_a + depth < asks.size() and depth < shown_a:
				absolute = off_a + depth
				data = asks[absolute]
			y = y0 + float(slot) * (row_h + 2.0)
		else:
			if slot < k and off_b + slot < bids.size() and slot < shown_b:
				absolute = off_b + slot
				data = bids[absolute]
			y = spread_y + rule_h + float(slot) * (row_h + 2.0)
		var show: bool = not data.is_empty()
		for key in ["marker", "tag", "price", "bar", "qty", "maker"]:
			(row[key] as CanvasItem).visible = show
		if not show:
			continue
		var col: Color = Palette.ask_color() if is_ask else Palette.bid_color()
		var cursor: bool = absolute == f.ladder_index and (buying == is_ask)
		var x: float = row_x + 8.0
		var mk: Label = row["marker"]
		mk.text = tr("HUD_LADDER_MARKER") if cursor else ""
		mk.position = Vector2(x, y)
		mk.size = Vector2(w_mark, row_h)
		x += w_mark + gap
		var tag: HudKit.Plate = row["tag"]
		var side_text: String = (Palette.ASK_GLYPH + " " + tr("HUD_SIDE_ASK")) if is_ask else (Palette.BID_GLYPH + " " + tr("HUD_SIDE_BID"))
		kit.set_tag(tag, side_text, col, _ink_on(col), w_tag, w_tag)
		tag.position = Vector2(x, y + (row_h - tag.size.y) * 0.5)
		x += w_tag + gap
		var pr: Label = row["price"]
		pr.text = "%.1f" % float(data["price"])
		pr.position = Vector2(x, y)
		pr.size = Vector2(w_price, row_h)
		x += w_price + gap
		var bar: HudKit.Plate = row["bar"]
		bar.position = Vector2(x, y + (row_h - 14.0) * 0.5)
		bar.size = Vector2(w_bar, 14.0)
		bar.bar_frac = float(data["quantity"]) / maxq
		bar.bar_color = col
		bar.queue_redraw()
		x += w_bar + gap
		var q: Label = row["qty"]
		q.text = tr("HUD_LADDER_QTY") % int(data["quantity"])
		q.position = Vector2(x, y)
		q.size = Vector2(w_qty, row_h)
		x += w_qty + gap
		var mt: HudKit.Plate = row["maker"]
		var mtext: String = str(makers[absolute if is_ask else asks.size() + absolute])
		mt.visible = mtext != ""
		if mtext != "":
			kit.set_tag(mt, mtext, HudTheme.SLATE, HudTheme.BONE, w_maker, 0.0)
			mt.position = Vector2(x, y + (row_h - mt.size.y) * 0.5)
		# The cursor row: the focus bar goes under it when the ladder owns the gamepad.
		if cursor:
			_ladder["cursor_rect"] = Rect2(row_x, y, row_w, row_h)
	# The spread rule with the hidden-level counters at its ends.
	var hidden_a: int = asks.size() - (off_a + shown_a)
	var hidden_b: int = bids.size() - (off_b + shown_b)
	var more_a: Label = _ladder["more_asks"]
	var more_b: Label = _ladder["more_bids"]
	more_a.text = tr("HUD_LADDER_MORE_ASKS") % hidden_a if hidden_a > 0 else ""
	more_b.text = tr("HUD_LADDER_MORE_BIDS") % hidden_b if hidden_b > 0 else ""
	spread_l.text = tr("HUD_LADDER_SPREAD") % float(ladder["spread"])
	var sw: float = kit.natural_width(spread_l, spread_l.text)
	var mw: float = maxf(kit.natural_width(more_a, tr("HUD_LADDER_MORE_ASKS") % 99), kit.natural_width(more_b, tr("HUD_LADDER_MORE_BIDS") % 99))
	var lh: float = HudKit.line_height(spread_l)
	var cy: float = spread_y + (rule_h - lh) * 0.5
	more_a.position = Vector2(row_x + 8.0, cy)
	more_a.size = Vector2(mw, lh)
	more_b.position = Vector2(row_x + row_w - 8.0 - mw, cy)
	more_b.size = Vector2(mw, lh)
	spread_l.position = Vector2(row_x + (row_w - sw) * 0.5, cy)
	spread_l.size = Vector2(sw, lh)
	var left_a: float = row_x + 8.0 + mw + 8.0
	var left_b: float = row_x + (row_w - sw) * 0.5 - 8.0
	var rl: HudKit.Plate = _ladder["rule_l"]
	var rr: HudKit.Plate = _ladder["rule_r"]
	rl.position = Vector2(left_a, spread_y + rule_h * 0.5 - 1.0)
	rl.size = Vector2(maxf(0.0, left_b - left_a), 2.0)
	var right_a: float = row_x + (row_w + sw) * 0.5 + 8.0
	var right_b: float = row_x + row_w - 8.0 - mw - 8.0
	rr.position = Vector2(right_a, spread_y + rule_h * 0.5 - 1.0)
	rr.size = Vector2(maxf(0.0, right_b - right_a), 2.0)
	_ladder["on_ladder"] = on_ladder
	_ladder["layout_rows"] = k


## Places the gamepad focus bar under the cursor row.
func _update_ladder_focus() -> void:
	var shape: Array = _ladder["shape"]
	var on: bool = bool(_ladder.get("on_ladder", false)) and shape[0] + shape[1] > 0
	sidebar_focus_bar.visible = on and _ladder.has("cursor_rect")
	if sidebar_focus_bar.visible:
		HudTheme.place_focus_bar(sidebar_focus_bar, _ladder["cursor_rect"])



# --- Order ticket: BUY / SELL, quantity, total and cargo, pad prompts ---

var _ticket: Dictionary = {}

func _build_ticket() -> void:
	var p: Panel = ticket_panel
	_ticket["title"] = kit.label(p, "TicketTitle", HudTheme.ROLE_TITLE, 18, HudTheme.BONE)
	_ticket["lt"] = kit.pad_glyph(p, "PadLT", tr("HUD_PAD_LT"), "", HudTheme.BONE)
	_ticket["rt"] = kit.pad_glyph(p, "PadRT", tr("HUD_PAD_RT"), "", HudTheme.BONE)
	_ticket["station"] = kit.label(p, "TicketStation", HudTheme.ROLE_LABEL, 12, HudTheme.BONE_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	_ticket["seg"] = kit.plate(p, Rect2(), HudTheme.INK, HudTheme.INK, 3.0)
	_ticket["buy"] = kit.plate(p, Rect2(), HudTheme.OCHRE, HudTheme.INK, 2.0)
	_ticket["sell"] = kit.plate(p, Rect2(), HudTheme.INK)
	_ticket["buy_l"] = kit.label(p, "TicketBuy", HudTheme.ROLE_LABEL, 15, HudTheme.INK, HORIZONTAL_ALIGNMENT_CENTER)
	_ticket["sell_l"] = kit.label(p, "TicketSell", HudTheme.ROLE_LABEL, 15, HudTheme.BONE_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	_ticket["qty_l"] = kit.label(p, "TicketQtyLabel", HudTheme.ROLE_LABEL, 12, HudTheme.BONE_DIM)
	_ticket["qty_v"] = kit.label(p, "TicketQtyValue", HudTheme.ROLE_READOUT, 24, HudTheme.BONE)
	_ticket["total_l"] = kit.label(p, "TicketTotalLabel", HudTheme.ROLE_LABEL, 12, HudTheme.BONE_DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	_ticket["total_v"] = kit.label(p, "TicketTotalValue", HudTheme.ROLE_READOUT, 20, HudTheme.BONE, HORIZONTAL_ALIGNMENT_RIGHT)
	var prompts: Array = []
	for i in 4:
		prompts.append(kit.pad_glyph(p, "Prompt%d" % i, "", "", HudTheme.BONE))
	_ticket["prompts"] = prompts


## The pad prompts the ticket shows for the state: [[button, caption], ...]. The shipped
## controls are unchanged; this is only how they are drawn.
func prompts() -> Array:
	var out: Array = []
	var in_transit: bool = controller != null and controller.is_in_transit()
	if not in_transit:
		var depart: bool = loop != null and loop.tab == M0Loop.Tab.MAP
		out.append([tr("HUD_PAD_A"), tr("HUD_PROMPT_DEPART") if depart else tr("HUD_PROMPT_SUBMIT")])
	out.append([tr("HUD_PAD_B"), tr("HUD_PROMPT_BACK")])
	if not in_transit:
		out.append([tr("HUD_PAD_X"), tr("HUD_PROMPT_CH11")])
	out.append([tr("HUD_PAD_Y"), tr("HUD_PROMPT_SPEED")])
	return out


func _refresh_ticket() -> void:
	var f: GamepadFocus = hud.gamepad_focus
	var ladder: Dictionary = hud.get_sidebar_telemetry()["order_book_ladder"]
	var asks: Array = ladder["asks"]
	var bids: Array = ladder["bids"]
	var buying: bool = f.active_side == GamepadFocus.OrderSide.BUY
	var buy_px: float = 0.0
	var sell_px: float = 0.0
	if not asks.is_empty():
		buy_px = float(asks[clampi(f.ladder_index if buying else 0, 0, asks.size() - 1)]["price"])
	if not bids.is_empty():
		sell_px = float(bids[clampi(0 if buying else f.ladder_index, 0, bids.size() - 1)]["price"])
	var total: int = int(round(float(f.order_qty) * (buy_px if buying else sell_px)))
	var station: String = Loc.station(hud.active_station).to_upper()
	var station_text: String = tr("HUD_TICKET_STATION") % station
	if controller.is_in_transit():
		# Under way there is no station to pick: the row shows the voyage instead.
		var voyage: Dictionary = controller.transit_info()
		station_text = tr("HUD_TRANSIT") % [Loc.station(str(voyage["destination"])), _rounds_text(int(voyage["eta_rounds"]))]
	var pr: Array = prompts()
	var cargo: String = "%d/%d" % [controller.get_total_cargo(), controller.cargo_capacity]
	if not _changed("ticket", [buy_px, sell_px, buying, f.order_qty, total, station_text, pr, cargo, Loc.current()]):
		return
	var t: Dictionary = _ticket
	var inner_w: float = ticket_panel.size.x - 2.0 * (HudLayout.BORDER + HudLayout.PAD)
	var x0: float = HudLayout.BORDER + HudLayout.PAD
	var y: float = HudLayout.BORDER + 10.0
	var title: Label = t["title"]
	title.text = tr("HUD_TICKET_TITLE")
	var th: float = HudKit.line_height(title)
	title.position = Vector2(x0, y)
	title.size = Vector2(kit.natural_width(title, title.text) + 2.0, th)
	y += th + 6.0
	# Station row: LT / RT glyphs flank the name (the LT/RT station select).
	var lt: Control = t["lt"]
	var rt: Control = t["rt"]
	kit.set_pad_glyph(lt, tr("HUD_PAD_LT"), "")
	kit.set_pad_glyph(rt, tr("HUD_PAD_RT"), "")
	var st: Label = t["station"]
	var st_w: float = kit.fit_text(st, station_text, inner_w - lt.size.x - rt.size.x - 16.0)
	var sh: float = maxf(HudKit.line_height(st), lt.size.y)
	lt.position = Vector2(x0, y + (sh - lt.size.y) * 0.5)
	rt.position = Vector2(x0 + inner_w - rt.size.x, y + (sh - rt.size.y) * 0.5)
	st.position = Vector2(x0 + lt.size.x + 8.0, y + (sh - HudKit.line_height(st)) * 0.5)
	st.size = Vector2(inner_w - lt.size.x - rt.size.x - 16.0, HudKit.line_height(st))
	st.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if st_w >= inner_w:
		st.autowrap_mode = TextServer.AUTOWRAP_OFF
	if st.autowrap_mode != TextServer.AUTOWRAP_OFF:
		# Still too long on the narrowest axis: wrap, and grow the row to the lines.
		var wh: float = HudKit.wrapped_height(st, station_text, st.size.x)
		sh = maxf(sh, wh)
		st.position.y = y + (sh - wh) * 0.5
		st.size.y = wh
	y += sh + 8.0
	# BUY / SELL segmented control.
	var buy_l: Label = t["buy_l"]
	var sell_l: Label = t["sell_l"]
	var seg_h: float = HudKit.line_height(buy_l) + 18.0
	var cell_w: float = (inner_w - 6.0) * 0.5
	var seg: HudKit.Plate = t["seg"]
	seg.position = Vector2(x0, y)
	seg.size = Vector2(inner_w, seg_h)
	seg.queue_redraw()
	var buy_cell: HudKit.Plate = t["buy"]
	var sell_cell: HudKit.Plate = t["sell"]
	buy_cell.position = Vector2(x0 + 3.0, y + 3.0)
	buy_cell.size = Vector2(cell_w, seg_h - 6.0)
	sell_cell.position = Vector2(x0 + 3.0 + cell_w, y + 3.0)
	sell_cell.size = Vector2(cell_w, seg_h - 6.0)
	var active: HudKit.Plate = buy_cell if buying else sell_cell
	var idle: HudKit.Plate = sell_cell if buying else buy_cell
	active.fill = HudTheme.OCHRE
	active.border = 2.0
	idle.fill = HudTheme.INK
	idle.border = 0.0
	active.queue_redraw()
	idle.queue_redraw()
	kit.fit_text(buy_l, tr("HUD_TICKET_BUY") % ("%.1f" % buy_px), cell_w - 8.0)
	kit.fit_text(sell_l, tr("HUD_TICKET_SELL") % ("%.1f" % sell_px), cell_w - 8.0)
	buy_l.add_theme_color_override("font_color", HudTheme.INK if buying else HudTheme.BONE_DIM)
	sell_l.add_theme_color_override("font_color", HudTheme.BONE_DIM if buying else HudTheme.INK)
	buy_l.position = buy_cell.position
	buy_l.size = buy_cell.size
	sell_l.position = sell_cell.position
	sell_l.size = sell_cell.size
	y += seg_h + 10.0
	# Quantity (left) and total / cargo (right).
	var qty_l: Label = t["qty_l"]
	var qty_v: Label = t["qty_v"]
	var tot_l: Label = t["total_l"]
	var tot_v: Label = t["total_v"]
	qty_l.text = tr("HUD_TICKET_QTY")
	qty_v.text = tr("HUD_TICKET_QTY_VALUE") % f.order_qty
	tot_l.text = tr("HUD_TICKET_TOTAL")
	tot_v.text = tr("HUD_TICKET_TOTAL_VALUE") % [_fmt(total), controller.get_total_cargo(), controller.cargo_capacity]
	var half: float = inner_w * 0.38
	var lh_l: float = HudKit.line_height(qty_l)
	var lh_v: float = HudKit.line_height(qty_v)
	kit.fit_text(qty_l, qty_l.text, half)
	kit.fit_text(qty_v, qty_v.text, half)
	var rw: float = inner_w - half - 8.0
	kit.fit_text(tot_l, tot_l.text, rw)
	kit.fit_text(tot_v, tot_v.text, rw)
	var lh_v2: float = HudKit.line_height(tot_v)
	qty_l.position = Vector2(x0, y)
	qty_l.size = Vector2(half, lh_l)
	qty_v.position = Vector2(x0, y + lh_l)
	qty_v.size = Vector2(half, lh_v)
	tot_l.position = Vector2(x0 + inner_w - rw, y)
	tot_l.size = Vector2(rw, lh_l)
	tot_v.position = Vector2(x0 + inner_w - rw, y + lh_l)
	tot_v.size = Vector2(rw, lh_v2)
	# Pad prompts along the foot, flowing left to right.
	var prompts_nodes: Array = t["prompts"]
	var px: float = x0
	var foot: float = ticket_panel.size.y - HudLayout.BORDER - 10.0
	for i in prompts_nodes.size():
		var host: Control = prompts_nodes[i]
		host.visible = i < pr.size()
		if i >= pr.size():
			continue
		kit.set_pad_glyph(host, pr[i][0], pr[i][1], HudTheme.BONE)
		host.position = Vector2(px, foot - host.size.y)
		px += host.size.x + 14.0


# --- Card: held cargo, the crisis art card and the desk notes ---

var _card: Dictionary = {}

func _build_card() -> void:
	var p: Panel = card_panel
	_card["held"] = kit.label(p, "CardHeld", HudTheme.ROLE_HINT, 14, PAPER_TEXT_COLOR)
	_card["rule"] = kit.plate(p, Rect2(), HudTheme.INK)
	var art: HudKit.Plate = kit.plate(p, Rect2(), HudTheme.PAPER_DEEP, HudTheme.INK, 3.0)
	art.hatch = true
	_card["art"] = art
	_card["art_l"] = kit.label(art, "CardArtLabel", HudTheme.ROLE_LABEL, 12, HudTheme.INK, HORIZONTAL_ALIGNMENT_CENTER)
	var crisis: Dictionary = _make_scroller(p, "CardCrisis")
	_card["crisis"] = crisis
	var cc: Control = crisis["content"]
	_card["eyebrow"] = kit.label(cc, "CrisisEyebrow", HudTheme.ROLE_LABEL, 12, HudTheme.RUST_DARK)
	_card["name"] = kit.label(cc, "CrisisName", HudTheme.ROLE_TITLE, 22, PAPER_TEXT_COLOR)
	var body: Label = kit.label(cc, "CrisisBody", HudTheme.ROLE_HINT, 14, PAPER_TEXT_COLOR)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	body.set_meta(SCROLLS_META, false)
	_card["body"] = body
	_card["notes"] = {"view": _make_scroller(p, "CardNotes"), "chips": [], "lines": []}


## One desk-notes entry for the selected book: baron tags as chips, the rest as lines.
func _card_notes() -> Array:
	var out: Array = []
	var f: GamepadFocus = hud.gamepad_focus
	if f.last_rejection_reason != "":
		out.append({"kind": "line", "text": tr("SIDE_REJECTED") % f.get_rejection_message(), "color": HudTheme.RUST_DARK})
	elif not f.last_executed_order.is_empty():
		var o: Dictionary = f.last_executed_order
		var who: String = _maker_name(str(o.get("counterparty_id", ""))) if str(o.get("counterparty_id", "")) != "" else str(o.get("counterparty", ""))
		out.append({"kind": "line", "text": tr("SIDE_FILLED") % [tr("ORDER_" + str(o["side"]).to_upper()), o["qty"], o["price"], tr("SIDE_FILLED_VS") % who if who != "" else "", tr("SIDE_FILLED_FEE") % int(o["fee"]) if int(o.get("fee", 0)) > 0 else ""], "color": HudTheme.INK})
	var st: String = hud.active_station
	var com: String = hud.active_commodity
	for pair in [[loop.pipeline_tag(st, com), HudTheme.TEAL_DARK, HudTheme.BONE], [loop.squeeze_tag(st, com), HudTheme.RUST_DARK, HudTheme.BONE], [loop.hoard_tag(st, com), HudTheme.RUST_DARK, HudTheme.BONE], [loop.toll_line(st), HudTheme.SLATE, HudTheme.BONE], [_contract_sidebar_line(), HudTheme.OCHRE, HudTheme.INK]]:
		if str(pair[0]) != "":
			out.append({"kind": "chip", "text": pair[0], "bg": pair[1], "fg": pair[2]})
	var auction: Array = loop.auction_lines(st, com)
	for i in auction.size():
		if i == 0:
			out.append({"kind": "chip", "text": auction[i], "bg": HudTheme.OCHRE, "fg": HudTheme.INK})
		else:
			out.append({"kind": "line", "text": auction[i], "color": HudTheme.INK})
	# The baron anchoring this station in distress (shares on offer) or held (task 7).
	var takeover: Array = loop.takeover_lines(st)
	var takeover_held: bool = loop.takeover_state(st) == "held"
	for i in takeover.size():
		if i == 0:
			out.append({"kind": "chip", "text": takeover[i], "bg": HudTheme.TEAL_DARK if takeover_held else HudTheme.RUST_DARK, "fg": HudTheme.BONE})
		else:
			out.append({"kind": "line", "text": takeover[i], "color": HudTheme.INK})
	# Crises beyond the one on the art card.
	var active: Array = _active_crises()
	var round_num: int = controller.get_current_round()
	for i in range(1, active.size()):
		var c: Dictionary = active[i]
		out.append({"kind": "chip", "text": tr("CRISIS_SIDEBAR") % [Loc.crisis_name(c).to_upper(), maxi(0, int(c["expires_round"]) - round_num)], "bg": HudTheme.RUST_DARK, "fg": HudTheme.BONE})
		for line in CrisisDeck.describe(c, true):
			out.append({"kind": "line", "text": str(line), "color": HudTheme.INK})
	return out


func _active_crises() -> Array:
	if loop == null or loop.crisis_deck == null:
		return []
	return loop.crisis_deck.active


## Fills a notes view (pooled chips and wrapping lines) and sizes its content.
func _notes_fill(n: Dictionary, entries: Array, width: float) -> void:
	var content: Control = n["view"]["content"]
	var chips: Array = n["chips"]
	var lines: Array = n["lines"]
	var ci: int = 0
	var li: int = 0
	var y: float = 0.0
	for e in entries:
		if str(e["kind"]) == "chip":
			if ci >= chips.size():
				chips.append(kit.tag(content, "NoteChip%d" % ci))
			var chip: HudKit.Plate = chips[ci]
			ci += 1
			chip.visible = true
			kit.set_tag(chip, str(e["text"]), e["bg"], e["fg"], width)
			chip.position = Vector2(0.0, y)
			y += chip.size.y + 4.0
		else:
			if li >= lines.size():
				var nl: Label = kit.label(content, "NoteLine%d" % li, HudTheme.ROLE_HINT, 14, PAPER_TEXT_COLOR)
				nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				nl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
				nl.set_meta(SCROLLS_META, settings.text_scale > 1.0)
				lines.append(nl)
			var l: Label = lines[li]
			li += 1
			l.visible = true
			l.text = str(e["text"])
			l.add_theme_color_override("font_color", e["color"])
			var h: float = HudKit.wrapped_height(l, l.text, width)
			l.position = Vector2(0.0, y)
			l.size = Vector2(width, h)
			y += h + 4.0
	for i in range(ci, chips.size()):
		(chips[i] as CanvasItem).visible = false
	for i in range(li, lines.size()):
		(lines[i] as CanvasItem).visible = false
	content.size = Vector2(width, maxf(0.0, y - 4.0))


func _refresh_card() -> void:
	var active: Array = _active_crises()
	var crisis: Dictionary = active[0] if not active.is_empty() else {}
	var held: String = tr("HUD_HELD") % [hud.get_cargo_qty(hud.active_commodity), Loc.commodity(hud.active_commodity), controller.get_total_cargo(), controller.cargo_capacity]
	var notes: Array = _card_notes()
	var round_num: int = controller.get_current_round()
	var crisis_sig: Array = []
	if not crisis.is_empty():
		crisis_sig = [crisis.get("uid", 0), crisis["tier"], Loc.crisis_name(crisis), maxi(0, int(crisis["expires_round"]) - round_num), CrisisDeck.describe(crisis, true)]
	if not _changed("card", [held, notes, crisis_sig, Loc.current()]):
		return
	var w: float = card_panel.size.x - 2.0 * (HudLayout.BORDER + HudLayout.PAD)
	var x0: float = HudLayout.BORDER + HudLayout.PAD
	var y: float = HudLayout.BORDER + 8.0
	var hl: Label = _card["held"]
	kit.fit_text(hl, held, w)
	var lh: float = HudKit.line_height(hl)
	hl.position = Vector2(x0, y)
	hl.size = Vector2(w, lh)
	var rule: HudKit.Plate = _card["rule"]
	rule.position = Vector2(HudLayout.BORDER, y + lh + 4.0)
	rule.size = Vector2(card_panel.size.x - 2.0 * HudLayout.BORDER, 2.0)
	var y1: float = y + lh + 4.0 + 2.0 + 8.0
	var bottom: float = card_panel.size.y - HudLayout.BORDER - 8.0
	var art: HudKit.Plate = _card["art"]
	var crisis_view: Dictionary = _card["crisis"]
	var notes_view: Dictionary = _card["notes"]["view"]
	var has_crisis: bool = not crisis.is_empty()
	art.visible = has_crisis
	(crisis_view["clip"] as Control).visible = has_crisis
	if has_crisis:
		var art_h: float = 120.0 if settings.text_scale < 1.1 else (100.0 if settings.text_scale < 1.2 else 84.0)
		art.position = Vector2(x0, y1)
		art.size = Vector2(art_h * 4.0 / 3.0, art_h)
		art.queue_redraw()
		var al: Label = _card["art_l"]
		al.text = tr("HUD_CARD_ART")
		al.position = Vector2.ZERO
		al.size = art.size
		var nx: float = x0 + art.size.x + 12.0
		var notes_clip: Control = notes_view["clip"]
		notes_clip.position = Vector2(nx, y1)
		notes_clip.size = Vector2(x0 + w - nx, art_h)
		_notes_fill(_card["notes"], notes, notes_clip.size.x)
		var cclip: Control = crisis_view["clip"]
		cclip.position = Vector2(x0, y1 + art_h + 6.0)
		cclip.size = Vector2(w, maxf(0.0, bottom - (y1 + art_h + 6.0)))
		var eb: Label = _card["eyebrow"]
		var nm: Label = _card["name"]
		var bd: Label = _card["body"]
		var tier_label: String = Loc.tier_label(str(crisis["tier"]), str(loop.crisis_deck.data.get("tiers", {}).get(str(crisis["tier"]), {}).get("label", crisis["tier"])))
		kit.fit_text(eb, tr("HUD_CRISIS_EYEBROW") % [tier_label, maxi(0, int(crisis["expires_round"]) - round_num)], w)
		kit.fit_text(nm, Loc.crisis_name(crisis), w)
		bd.text = " · ".join(PackedStringArray(CrisisDeck.describe(crisis, true)))
		var eh: float = HudKit.line_height(eb)
		var nh: float = HudKit.line_height(nm)
		var bh: float = HudKit.wrapped_height(bd, bd.text, w)
		eb.position = Vector2(0.0, 0.0)
		eb.size = Vector2(w, eh)
		nm.position = Vector2(0.0, eh)
		nm.size = Vector2(w, nh)
		bd.position = Vector2(0.0, eh + nh)
		bd.size = Vector2(w, bh)
		(crisis_view["content"] as Control).size = Vector2(w, eh + nh + bh)
	else:
		var notes_clip: Control = notes_view["clip"]
		notes_clip.position = Vector2(x0, y1)
		notes_clip.size = Vector2(w, maxf(0.0, bottom - y1))
		_notes_fill(_card["notes"], notes, w)



# --- Market tab: the quote board (a paper panel over the map) ---

var _board: Dictionary = {}

func _build_board() -> void:
	market_modal = _make_panel("BoardPanel", HudLayout.BOARD_RECT, "SidebarPanel")
	hud_container.add_child(market_modal)
	var p: Panel = market_modal
	market_highlight = HudTheme.make_focus_bar(p, FOCUS_BAR_PAPER_FILL, FOCUS_BAR_PAPER_EDGE)
	market_highlight.visible = true
	_board["eyebrow"] = kit.label(p, "BoardEyebrow", HudTheme.ROLE_LABEL, 12, HudTheme.RUST_DARK)
	_board["title"] = kit.label(p, "BoardTitle", HudTheme.ROLE_TITLE, 22, PAPER_TEXT_COLOR)
	_board["hint"] = kit.label(p, "BoardStick", HudTheme.ROLE_LABEL, 12, HudTheme.RUST_DARK, HORIZONTAL_ALIGNMENT_RIGHT)
	_board["rule"] = kit.plate(p, Rect2(), HudTheme.INK)
	_board["col_name"] = kit.label(p, "BoardColName", HudTheme.ROLE_LABEL, 12, PAPER_TEXT_COLOR)
	_board["col_bid"] = kit.label(p, "BoardColBid", HudTheme.ROLE_LABEL, 12, PAPER_TEXT_COLOR, HORIZONTAL_ALIGNMENT_RIGHT)
	_board["col_ask"] = kit.label(p, "BoardColAsk", HudTheme.ROLE_LABEL, 12, PAPER_TEXT_COLOR, HORIZONTAL_ALIGNMENT_RIGHT)
	_board["foot_rule"] = kit.plate(p, Rect2(), HudTheme.INK)
	_board["foot"] = kit.label(p, "BoardHint", HudTheme.ROLE_HINT, 14, PAPER_TEXT_COLOR)
	var rows: Array = []
	for i in Transit.COMMODITIES.size():
		rows.append({
			"marker": kit.label(p, "BoardMarker%d" % i, HudTheme.ROLE_LABEL, 14, PAPER_TEXT_COLOR, HORIZONTAL_ALIGNMENT_CENTER),
			"name": kit.label(p, "BoardName%d" % i, HudTheme.ROLE_TITLE, 17, PAPER_TEXT_COLOR),
			"chip": kit.tag(p, "BoardTag%d" % i),
			"bid": kit.label(p, "BoardBid%d" % i, HudTheme.ROLE_READOUT, 17, PAPER_TEXT_COLOR, HORIZONTAL_ALIGNMENT_RIGHT),
			"ask": kit.label(p, "BoardAsk%d" % i, HudTheme.ROLE_READOUT, 17, PAPER_TEXT_COLOR, HORIZONTAL_ALIGNMENT_RIGHT),
		})
	_board["rows"] = rows


func _refresh_board() -> void:
	var st: String = hud.active_station
	var entries: Array = []
	for c in Transit.COMMODITIES:
		var e: Dictionary = {"c": c, "live": loop.market.has_book(st, c)}
		if e["live"]:
			var lad: Dictionary = loop.market.ladder(st, c, 1)
			e["bid"] = float(lad["best_bid"])
			e["ask"] = float(lad["best_ask"])
			var tag: String = loop.crisis_deck.tag_for(st, c) if loop.crisis_deck != null else ""
			# A squeezed, hoarded or auctioned book shows that tag in place of its pipeline tag
			# (the row has no room for both in the pseudo locale); the notes still list the pipeline.
			var pipe: String = loop.squeeze_tag(st, c)
			if pipe == "":
				pipe = loop.hoard_tag(st, c)
			if pipe == "":
				pipe = loop.auction_tag(st, c)
			if pipe == "":
				pipe = loop.pipeline_tag(st, c)
			if pipe != "":
				tag = pipe if tag == "" else "%s, %s" % [pipe, tag]
			e["tag"] = tag
		else:
			e["base"] = float(Transit.BASE_PRICES[st][c])
			e["tag"] = tr("BOARD_BASE") % float(Transit.BASE_PRICES[st][c])
		entries.append(e)
	var maker: String = _maker_name(loop.market.maker_for(st))
	if not _changed("board", [entries, st, hud.active_commodity, maker, Palette.current(), Loc.current()]):
		_park_below_map_status(market_modal)
		_update_market_highlight()
		return
	var p: Panel = market_modal
	var b: Dictionary = _board
	var x0: float = HudLayout.BORDER + HudLayout.PAD
	var w: float = p.size.x - 2.0 * x0
	var y: float = HudLayout.BORDER + 8.0
	var eb: Label = b["eyebrow"]
	var ti: Label = b["title"]
	var hi: Label = b["hint"]
	hi.text = tr("BOARD_STICK")
	var hw: float = kit.natural_width(hi, hi.text)
	kit.fit_text(eb, tr("BOARD_EYEBROW") % [Loc.station(st).to_upper(), maker], w - hw - 8.0)
	ti.text = tr("BOARD_TITLE")
	var eh: float = HudKit.line_height(eb)
	if eb.autowrap_mode != TextServer.AUTOWRAP_OFF:
		eh = HudKit.wrapped_height(eb, eb.text, w - hw - 8.0)
	var th: float = HudKit.line_height(ti)
	eb.position = Vector2(x0, y)
	eb.size = Vector2(w - hw - 8.0, eh)
	ti.position = Vector2(x0, y + eh)
	ti.size = Vector2(kit.natural_width(ti, ti.text) + 2.0, th)
	hi.position = Vector2(x0 + w - hw, y + (eh + th - HudKit.line_height(hi)) * 0.5)
	hi.size = Vector2(hw, HudKit.line_height(hi))
	y += eh + th + 6.0
	var rule: HudKit.Plate = b["rule"]
	rule.position = Vector2(HudLayout.BORDER, y)
	rule.size = Vector2(p.size.x - 2.0 * HudLayout.BORDER, 2.0)
	y += 2.0 + 6.0
	var w_px: float = 0.0
	var rows: Array = b["rows"]
	for r in rows:
		w_px = maxf(w_px, kit.natural_width(r["bid"], "9999.9"))
	w_px = maxf(w_px, 64.0)
	var cn: Label = b["col_name"]
	var cb: Label = b["col_bid"]
	var ca: Label = b["col_ask"]
	cn.text = tr("BOARD_COL_COMMODITY")
	cb.text = Palette.BID_GLYPH + " " + tr("HUD_SIDE_BID")
	ca.text = Palette.ASK_GLYPH + " " + tr("HUD_SIDE_ASK")
	w_px = maxf(w_px, maxf(kit.natural_width(cb, cb.text), kit.natural_width(ca, ca.text)) + 2.0)
	var ch: float = HudKit.line_height(cn)
	var x_ask: float = x0 + w - 8.0 - w_px
	var x_bid: float = x_ask - 8.0 - w_px
	cn.position = Vector2(x0 + 8.0 + 16.0 + 8.0, y)
	cn.size = Vector2(maxf(0.0, x_bid - cn.position.x - 8.0), ch)
	cb.position = Vector2(x_bid, y)
	cb.size = Vector2(w_px, ch)
	ca.position = Vector2(x_ask, y)
	ca.size = Vector2(w_px, ch)
	y += ch + 4.0
	var mark_w: float = maxf(16.0, kit.natural_width((rows[0] as Dictionary)["marker"], tr("HUD_LADDER_MARKER")) + 2.0)
	var name_x: float = x0 + 8.0 + mark_w + 8.0
	cn.position.x = name_x
	cn.size.x = maxf(0.0, x_bid - name_x - 8.0)
	var name_w: float = x_bid - 8.0 - name_x
	for i in rows.size():
		var r: Dictionary = rows[i]
		var e: Dictionary = entries[i]
		var nm: Label = r["name"]
		kit.fit_text(nm, Loc.commodity(str(e["c"])), name_w)
		var chip: HudKit.Plate = r["chip"]
		var tag: String = str(e["tag"])
		chip.visible = tag != ""
		var rh: float = maxf(32.0, HudKit.line_height(nm) + 10.0)
		var nh: float = HudKit.line_height(nm)
		var chip_h: float = 0.0
		if tag != "":
			var alarm: bool = bool(e["live"])
			kit.set_tag(chip, tag, HudTheme.RUST_DARK if alarm else HudTheme.SLATE, HudTheme.BONE, name_w)
			chip_h = chip.size.y
			rh += chip_h + 2.0
		var mk: Label = r["marker"]
		var sel: bool = str(e["c"]) == hud.active_commodity
		mk.text = tr("HUD_LADDER_MARKER") if sel else ""
		mk.position = Vector2(x0 + 8.0, y)
		mk.size = Vector2(mark_w, maxf(32.0, nh + 10.0))
		nm.position = Vector2(name_x, y + 5.0)
		nm.size = Vector2(name_w, nh)
		if tag != "":
			chip.position = Vector2(nm.position.x, y + 5.0 + nh + 2.0)
		var bidl: Label = r["bid"]
		var askl: Label = r["ask"]
		bidl.text = "%.1f" % float(e["bid"]) if bool(e["live"]) else "—"
		askl.text = "%.1f" % float(e["ask"]) if bool(e["live"]) else "—"
		var vh: float = HudKit.line_height(bidl)
		bidl.position = Vector2(x_bid, y + 5.0)
		bidl.size = Vector2(w_px, vh)
		askl.position = Vector2(x_ask, y + 5.0)
		askl.size = Vector2(w_px, vh)
		if sel:
			_board["sel_rect"] = Rect2(x0, y, w, rh)
		y += rh + 4.0
	var fr: HudKit.Plate = b["foot_rule"]
	fr.position = Vector2(HudLayout.BORDER, y + 2.0)
	fr.size = Vector2(p.size.x - 2.0 * HudLayout.BORDER, 2.0)
	var ft: Label = b["foot"]
	kit.fit_text(ft, tr("BOARD_HINT"), w)
	var fh: float = HudKit.line_height(ft)
	if ft.autowrap_mode != TextServer.AUTOWRAP_OFF:
		fh = HudKit.wrapped_height(ft, ft.text, w)
	ft.position = Vector2(x0, y + 10.0)
	ft.size = Vector2(w, fh)
	p.size.y = y + 10.0 + fh + 10.0
	_park_below_map_status(p)
	_update_market_highlight()


## Floats a map panel just under the map status text (so neither hides the other), kept above the ticker strip.
func _park_below_map_status(p: Panel) -> void:
	var top: float = HudLayout.MAP_RECT.position.y + map_label.position.y + map_label.size.y + 8.0
	var limit: float = ticker_panel.position.y - p.size.y - 6.0
	p.position.y = maxf(top, HudLayout.BOARD_RECT.position.y) if top <= limit else maxf(HudLayout.MAP_RECT.position.y + 4.0, limit)


func _update_market_highlight() -> void:
	if market_highlight == null or not _board.has("sel_rect"):
		return
	HudTheme.place_focus_bar(market_highlight, _board["sel_rect"])


# --- Fleet tab: hulls and cargo, restyled with the same rows ---

var _fleet: Dictionary = {}
var fleet_panel: Panel = null

func _build_fleet() -> void:
	fleet_panel = _make_panel("FleetPanel", HudLayout.FLEET_RECT, "SidebarPanel")
	hud_container.add_child(fleet_panel)
	var p: Panel = fleet_panel
	_fleet["eyebrow"] = kit.label(p, "FleetEyebrow", HudTheme.ROLE_LABEL, 12, HudTheme.RUST_DARK)
	_fleet["title"] = kit.label(p, "FleetTitle", HudTheme.ROLE_TITLE, 22, PAPER_TEXT_COLOR)
	_fleet["rule"] = kit.plate(p, Rect2(), HudTheme.INK)
	var rows: Array = []
	for i in Transit.COMMODITIES.size():
		rows.append({
			"name": kit.label(p, "FleetName%d" % i, HudTheme.ROLE_TITLE, 17, PAPER_TEXT_COLOR),
			"qty": kit.label(p, "FleetQty%d" % i, HudTheme.ROLE_READOUT, 17, PAPER_TEXT_COLOR, HORIZONTAL_ALIGNMENT_RIGHT),
		})
	_fleet["rows"] = rows
	_fleet["foot_rule"] = kit.plate(p, Rect2(), HudTheme.INK)
	_fleet["foot"] = kit.label(p, "FleetCargo", HudTheme.ROLE_HINT, 14, PAPER_TEXT_COLOR)
	fleet_panel.visible = false


func _refresh_fleet() -> void:
	var cargo: Dictionary = controller.cargo
	var names: Array = []
	for c in cargo:
		names.append([c, int(cargo[c])])
	if not _changed("fleet", [controller.ships.size(), names, controller.get_total_cargo(), controller.cargo_capacity, Loc.current()]):
		_park_below_map_status(fleet_panel)
		return
	var p: Panel = fleet_panel
	var x0: float = HudLayout.BORDER + HudLayout.PAD
	var w: float = p.size.x - 2.0 * x0
	var y: float = HudLayout.BORDER + 8.0
	var eb: Label = _fleet["eyebrow"]
	var ti: Label = _fleet["title"]
	kit.fit_text(eb, tr("FLEET_HULLS") % controller.ships.size(), w)
	ti.text = tr("FLEET_TITLE")
	var eh: float = HudKit.line_height(eb)
	var th: float = HudKit.line_height(ti)
	eb.position = Vector2(x0, y)
	eb.size = Vector2(w, eh)
	ti.position = Vector2(x0, y + eh)
	ti.size = Vector2(kit.natural_width(ti, ti.text) + 2.0, th)
	y += eh + th + 6.0
	var rule: HudKit.Plate = _fleet["rule"]
	rule.position = Vector2(HudLayout.BORDER, y)
	rule.size = Vector2(p.size.x - 2.0 * HudLayout.BORDER, 2.0)
	y += 2.0 + 6.0
	var rows: Array = _fleet["rows"]
	for i in rows.size():
		var r: Dictionary = rows[i]
		var show: bool = i < names.size()
		(r["name"] as CanvasItem).visible = show
		(r["qty"] as CanvasItem).visible = show
		if not show:
			continue
		var nm: Label = r["name"]
		var q: Label = r["qty"]
		nm.text = Loc.commodity(str(names[i][0]))
		q.text = tr("FLEET_CARGO_QTY") % int(names[i][1])
		var rh: float = maxf(32.0, HudKit.line_height(nm) + 10.0)
		nm.position = Vector2(x0 + 8.0, y + 5.0)
		nm.size = Vector2(w * 0.6, HudKit.line_height(nm))
		q.position = Vector2(x0 + w - 8.0 - 120.0, y + 5.0)
		q.size = Vector2(120.0, HudKit.line_height(q))
		y += rh + 4.0
	var fr: HudKit.Plate = _fleet["foot_rule"]
	fr.position = Vector2(HudLayout.BORDER, y + 2.0)
	fr.size = Vector2(p.size.x - 2.0 * HudLayout.BORDER, 2.0)
	var ft: Label = _fleet["foot"]
	kit.fit_text(ft, tr("HUD_CARGO_TOTAL") % [controller.get_total_cargo(), controller.cargo_capacity], w)
	ft.position = Vector2(x0, y + 10.0)
	ft.size = Vector2(w, HudKit.line_height(ft))
	p.size.y = y + 10.0 + HudKit.line_height(ft) + 10.0
	_park_below_map_status(p)



# --- Modals: the title-band variant (Modal.dc.html variant A) ---

## Pooled body rows of the resolution modal.
var _res: Dictionary = {}
var _dim: HudKit.Plate = null
var _settings_parts: Dictionary = {}

## Band colours by kind: [fill, text, accent].
const BANDS: Dictionary = {
	"alert": [HudTheme.RUST_DARK, HudTheme.BONE, HudTheme.RUST],
	"ochre": [HudTheme.OCHRE, HudTheme.INK, HudTheme.OCHRE_DARK],
	"teal": [HudTheme.TEAL_DARK, HudTheme.BONE, HudTheme.TEAL],
}


## A modal plate with its title band (eyebrow over title) and an action footer; returns the parts.
func _make_modal(name: String, rect: Rect2) -> Dictionary:
	var panel: Panel = _make_panel(name, rect, "ModalPanel")
	hud_container.add_child(panel)
	var band: HudKit.Plate = kit.plate(panel, Rect2(), BANDS["alert"][0])
	band.cut_size = 56.0
	var eyebrow: Label = kit.label(panel, name + "Eyebrow", HudTheme.ROLE_LABEL, 12, HudTheme.BONE)
	var title: Label = kit.label(panel, name + "Title", HudTheme.ROLE_DISPLAY, 40, HudTheme.BONE)
	var foot: HudKit.Plate = kit.plate(panel, Rect2(), HudTheme.INK)
	var actions: Array = []
	for i in 3:
		actions.append(kit.pad_glyph(panel, "%sAction%d" % [name, i], "", "", HudTheme.BONE))
	return {"panel": panel, "band": band, "eyebrow": eyebrow, "title": title, "foot": foot, "actions": actions}


func _build_modals() -> void:
	_dim = kit.plate(hud_container, Rect2(0.0, 64.0, 1280.0, 736.0), Color(HudTheme.INK.r, HudTheme.INK.g, HudTheme.INK.b, 0.55))
	_dim.name = "ModalDim"
	_dim.visible = false
	var res: Dictionary = _make_modal("ResolutionPanel", HudLayout.MODAL_RECT)
	_res = res
	resolution_modal = res["panel"]
	resolution_focus_bar = HudTheme.make_focus_bar(resolution_modal, FOCUS_BAR_DARK_FILL, FOCUS_BAR_DARK_EDGE)
	var texts: Array = []
	for i in 8:
		var l: Label = kit.label(resolution_modal, "ResolutionText%d" % i, HudTheme.ROLE_BODY, 18, HUD_TEXT_COLOR)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		l.set_meta(SCROLLS_META, false)
		texts.append(l)
	_res["texts"] = texts
	resolution_label = texts[0]
	var kvs: Array = []
	for i in 6:
		kvs.append({
			"key": kit.label(resolution_modal, "ResolutionKey%d" % i, HudTheme.ROLE_LABEL, 12, HudTheme.BONE_DIM),
			"value": kit.label(resolution_modal, "ResolutionValue%d" % i, HudTheme.ROLE_READOUT, 20, HUD_TEXT_COLOR, HORIZONTAL_ALIGNMENT_RIGHT),
		})
	_res["kvs"] = kvs
	var perks: Array = []
	for i in 12:
		perks.append({
			"marker": kit.label(resolution_modal, "PerkMarker%d" % i, HudTheme.ROLE_LABEL, 14, HUD_TEXT_COLOR, HORIZONTAL_ALIGNMENT_CENTER),
			"tier": kit.label(resolution_modal, "PerkTier%d" % i, HudTheme.ROLE_LABEL, 12, HudTheme.BONE_DIM),
			"name": kit.label(resolution_modal, "PerkName%d" % i, HudTheme.ROLE_HINT, 16, HUD_TEXT_COLOR),
			"branch": kit.label(resolution_modal, "PerkBranch%d" % i, HudTheme.ROLE_LABEL, 12, HudTheme.BONE_DIM),
			"tag": kit.label(resolution_modal, "PerkTag%d" % i, HudTheme.ROLE_READOUT, 16, HUD_TEXT_COLOR, HORIZONTAL_ALIGNMENT_RIGHT),
		})
	_res["perks"] = perks
	var sleep: Dictionary = {}
	sleep_modal = _make_panel("SleepBanner", HudLayout.BANNER_RECT, "BannerPanel")
	hud_container.add_child(sleep_modal)
	sleep_label = kit.label(sleep_modal, "SleepText", HudTheme.ROLE_TITLE, 22, HUD_TEXT_COLOR)
	sleep_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sleep_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	sleep_modal.visible = false
	var st: Dictionary = _make_modal("SettingsPanel", HudLayout.MODAL_WIDE_RECT)
	_settings_parts = st
	settings_modal = st["panel"]
	settings_focus_bar = HudTheme.make_focus_bar(settings_modal, FOCUS_BAR_DARK_FILL, FOCUS_BAR_DARK_EDGE)
	settings_label = kit.label(settings_modal, "SettingsText", HudTheme.ROLE_BODY, 18, HUD_TEXT_COLOR)
	settings_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	settings_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	settings_modal.visible = false
	resolution_modal.visible = false


## What the resolution modal shows: {eyebrow, title, band, wide, rows, actions}. A row is
## {"kind": "text"|"muted"|"kv"|"perk"|"start", ...}; an action is [button, caption].
func _resolution_model() -> Dictionary:
	if loop.overlay_state == M0Loop.OVERLAY_CRISIS:
		return _crisis_model()
	if loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
		return _contract_model()
	if loop.overlay_state == M0Loop.OVERLAY_CHAPTER_11:
		var a: Dictionary = controller.assess()
		return {"eyebrow": tr("CH11_EYEBROW"), "title": tr("CH11_TITLE"), "band": "alert", "wide": false,
			"rows": [{"kind": "text", "text": tr("CH11_INSOLVENT") % [_fmt(int(a["total_debt"])), _fmt(int(a["liquidation_value"]))]}, {"kind": "muted", "text": tr("HUD_CLOCK_HALTED")}],
			"actions": [[tr("HUD_PAD_X"), tr("HUD_ACT_FILE")]]}
	if loop.collapse_phase == M0Loop.PHASE_PERKS:
		return _perks_model()
	return _summary_model()


func _crisis_model() -> Dictionary:
	var c: Dictionary = loop.current_crisis()
	if c.is_empty():
		return {"eyebrow": "", "title": "", "band": "alert", "wide": true, "rows": [], "actions": []}
	var tier_label: String = Loc.tier_label(str(c["tier"]), str(loop.crisis_deck.data.get("tiers", {}).get(str(c["tier"]), {}).get("label", c["tier"])))
	var rows: Array = [{"kind": "text", "text": Loc.crisis_text(c)}, {"kind": "muted", "text": tr("CRISIS_DURATION") % [int(c["rounds"]), int(c["expires_round"])]}]
	for line in CrisisDeck.describe(c):
		rows.append({"kind": "text", "text": tr("HUD_BULLET") % str(line)})
	rows.append({"kind": "muted", "text": tr("HUD_CLOCK_HALTED")})
	return {"eyebrow": tr("HUD_CRISIS_MODAL_EYEBROW") % tier_label, "title": Loc.crisis_name(c), "band": "alert", "wide": true, "rows": rows,
		"actions": [[tr("HUD_PAD_A"), tr("HUD_ACT_ACK")]]}


## The defense contract offer modal (Epic 3 task 4): what is asked, what it pays,
## what a miss costs, and when Ares squeezes. A accepts, B declines.
func _contract_model() -> Dictionary:
	var o: Dictionary = loop.current_offer()
	if o.is_empty():
		return {"eyebrow": "", "title": "", "band": "ochre", "wide": true, "rows": [], "actions": []}
	var w: Barons = controller.world
	var id: String = str(o["baron"])
	var p: Dictionary = w.def(id).get("params", {})
	var com: String = Loc.commodity(str(o["commodity"]))
	var qty: int = int(o["qty"])
	var value: int = qty * int(o["unit_px"])
	return {"eyebrow": tr("CONTRACT_EYEBROW"), "title": _maker_name(id), "band": "ochre", "wide": true,
		"rows": [
			{"kind": "text", "text": tr("CONTRACT_BODY") % [qty, com, Loc.station(str(w.def(id).get("anchor", ""))), int(o["due_round"])]},
			{"kind": "text", "text": tr("CONTRACT_PAY") % [int(o["unit_px"]), value]},
			{"kind": "text", "text": tr("CONTRACT_PENALTY") % (value * int(p.get("contract_penalty_bps", 0)) / 10000)},
			{"kind": "text", "text": tr("CONTRACT_SQUEEZE") % [int(p.get("squeeze_window_rounds", 0)), qty, com, int(p.get("squeeze_price_bps_max", 0)) / 100]},
			{"kind": "muted", "text": tr("HUD_CLOCK_HALTED")}],
		"actions": [[tr("HUD_PAD_A"), tr("HUD_ACT_ACCEPT")], [tr("HUD_PAD_B"), tr("HUD_ACT_DECLINE")]]}


func _summary_model() -> Dictionary:
	var r: Dictionary = loop.run_summary()
	return {"eyebrow": tr("SUM_EYEBROW"), "title": tr("SUM_TITLE"), "band": "alert", "wide": true,
		"rows": [
			{"kind": "kv", "key": tr("SUM_CAUSE"), "value": _cause_text(str(r["reason"]))},
			{"kind": "kv", "key": tr("SUM_NET_WORTH"), "value": tr("HUD_CR_VALUE") % _fmt(int(r["net_worth"]))},
			{"kind": "kv", "key": tr("SUM_PEAK"), "value": tr("HUD_CR_VALUE") % _fmt(int(r["peak_net_worth"]))},
			{"kind": "kv", "key": tr("SUM_ROUNDS"), "value": str(int(r["rounds_survived"]))},
			{"kind": "kv", "key": tr("SUM_SEVERANCE"), "value": tr("SUM_SEVERANCE_VALUE") % [int(r["severance_awarded"]), int(r["severance_balance"])]}],
		"actions": [[tr("HUD_PAD_A"), tr("HUD_ACT_PARACHUTES")]]}


func _perks_model() -> Dictionary:
	var rows: Array = []
	var perk_rows: Array = loop.perk_rows()
	for i in perk_rows.size():
		var row: Dictionary = perk_rows[i]
		var tag: String = tr("PERK_OWNED") if bool(row["owned"]) else ("%d" % int(row["cost"]) if bool(row["can_buy"]) else tr("PERK_LOCKED") % int(row["cost"]))
		rows.append({"kind": "perk", "cursor": i == loop.perk_cursor, "tier": tr("HUD_PERK_TIER") % int(row["tier"]), "name": Loc.perk_name(row), "branch": Loc.perk_branch(str(row["branch"])), "tag": tag})
	rows.append({"kind": "start", "cursor": loop.perk_cursor >= perk_rows.size(), "text": tr("PERK_START")})
	return {"eyebrow": tr("PERKS_EYEBROW") % controller.profile.severance_points, "title": tr("PERKS_TITLE"), "band": "teal", "wide": true, "rows": rows,
		"actions": [[tr("HUD_PAD_DPAD"), tr("HUD_ACT_SELECT")], [tr("HUD_PAD_A"), tr("HUD_ACT_BUY")], [tr("HUD_PAD_B"), tr("HUD_ACT_BACK")]]}


## Lays a title band, its footer actions and returns the y where the body starts. `m` is the
## parts of _make_modal; sets the band, eyebrow, title and the pad-glyph actions.
func _layout_band(m: Dictionary, width: float, eyebrow: String, title: String, band: String, actions: Array) -> float:
	var colors: Array = BANDS[band]
	var bd: HudKit.Plate = m["band"]
	var eb: Label = m["eyebrow"]
	var ti: Label = m["title"]
	bd.fill = colors[0]
	bd.cut = colors[2]
	eb.add_theme_color_override("font_color", colors[1])
	ti.add_theme_color_override("font_color", colors[1])
	var pad: float = 24.0
	var inner: float = width - 2.0 * HudLayout.BORDER - 2.0 * pad
	eb.text = eyebrow
	kit.fit_text(eb, eyebrow, inner - 48.0)
	var eh: float = HudKit.line_height(eb)
	if eb.autowrap_mode != TextServer.AUTOWRAP_OFF:
		eh = HudKit.wrapped_height(eb, eyebrow, inner - 48.0)
	var tw: float = kit.fit_text(ti, title, inner - 48.0)
	var th: float = HudKit.line_height(ti)
	if ti.autowrap_mode != TextServer.AUTOWRAP_OFF:
		th = HudKit.wrapped_height(ti, title, inner - 48.0)
	var band_h: float = 12.0 + eh + th + 12.0
	var x0: float = HudLayout.BORDER
	bd.position = Vector2(x0, x0)
	bd.size = Vector2(width - 2.0 * x0, band_h)
	bd.queue_redraw()
	eb.position = Vector2(x0 + pad, x0 + 12.0)
	eb.size = Vector2(inner - 48.0, eh)
	ti.position = Vector2(x0 + pad, x0 + 12.0 + eh)
	ti.size = Vector2(inner - 48.0 if ti.autowrap_mode != TextServer.AUTOWRAP_OFF else tw + 2.0, th)
	return x0 + band_h


## Footer: a rule and the right-aligned pad actions. `y` is the footer top; returns the modal height.
func _layout_footer(m: Dictionary, width: float, y: float, actions: Array) -> float:
	var foot: HudKit.Plate = m["foot"]
	var hosts: Array = m["actions"]
	var total: float = 0.0
	var tallest: float = 22.0
	for i in hosts.size():
		var host: Control = hosts[i]
		host.visible = i < actions.size()
		if i < actions.size():
			kit.set_pad_glyph(host, actions[i][0], actions[i][1], HudTheme.BONE)
			total += host.size.x + (20.0 if total > 0.0 else 0.0)
			tallest = maxf(tallest, host.size.y)
	foot.visible = not actions.is_empty()
	foot.position = Vector2(HudLayout.BORDER, y)
	foot.size = Vector2(width - 2.0 * HudLayout.BORDER, 2.0)
	var x: float = width - HudLayout.BORDER - 24.0 - total
	for i in actions.size():
		var host: Control = hosts[i]
		host.position = Vector2(x, y + 2.0 + 12.0 + (tallest - host.size.y) * 0.5)
		x += host.size.x + 20.0
	return y + 2.0 + 12.0 + tallest + 12.0 + HudLayout.BORDER if not actions.is_empty() else y + HudLayout.BORDER


func _refresh_resolution() -> void:
	resolution_modal.visible = loop.overlay_state != M0Loop.OVERLAY_NONE
	if not resolution_modal.visible:
		resolution_label.text = ""
		_sig.erase("resolution")
		return
	var model: Dictionary = _resolution_model()
	if not _changed("resolution", [model, Loc.current(), Palette.current()]):
		return
	var texts: Array = _res["texts"]
	var kvs: Array = _res["kvs"]
	var perks: Array = _res["perks"]
	var rect: Rect2 = HudLayout.MODAL_WIDE_RECT if bool(model["wide"]) else HudLayout.MODAL_RECT
	var w: float = rect.size.x
	var y: float = _layout_band(_res, w, str(model["eyebrow"]), str(model["title"]), str(model["band"]), model["actions"])
	var x0: float = HudLayout.BORDER + 24.0
	var inner: float = w - 2.0 * x0
	y += 18.0
	var ti: int = 0
	var ki: int = 0
	var pi: int = 0
	var cursor_rect: Rect2 = Rect2()
	for r in model["rows"]:
		match str(r["kind"]):
			"text", "muted":
				if ti >= texts.size():
					continue
				var l: Label = texts[ti]
				ti += 1
				l.visible = true
				l.text = str(r["text"])
				l.add_theme_color_override("font_color", HudTheme.BONE_DIM if str(r["kind"]) == "muted" else HUD_TEXT_COLOR)
				var h: float = HudKit.wrapped_height(l, l.text, inner)
				l.position = Vector2(x0, y)
				l.size = Vector2(inner, h)
				y += h + 8.0
			"kv":
				var kv: Dictionary = kvs[ki]
				ki += 1
				var k: Label = kv["key"]
				var v: Label = kv["value"]
				k.visible = true
				v.visible = true
				k.text = str(r["key"])
				v.text = str(r["value"])
				var vw: float = kit.fit_text(v, v.text, inner * 0.6)
				var kh: float = HudKit.line_height(k)
				var vh: float = HudKit.line_height(v)
				var rh: float = maxf(kh, vh)
				k.position = Vector2(x0, y + (rh - kh) * 0.5 + 2.0)
				k.size = Vector2(inner - vw - 12.0, kh)
				v.position = Vector2(x0 + inner - vw - 2.0, y)
				v.size = Vector2(vw + 2.0, vh)
				y += rh + 8.0
			"perk", "start":
				var pr: Dictionary = perks[pi]
				pi += 1
				for key in ["marker", "tier", "name", "branch", "tag"]:
					(pr[key] as CanvasItem).visible = true
				var mk: Label = pr["marker"]
				var nm: Label = pr["name"]
				var rh: float = maxf(30.0, HudKit.line_height(nm) + 8.0)
				mk.text = tr("HUD_LADDER_MARKER") if bool(r["cursor"]) else ""
				mk.position = Vector2(x0 + 4.0, y)
				var mark_w: float = maxf(16.0, kit.natural_width(mk, tr("HUD_LADDER_MARKER")) + 2.0)
				mk.size = Vector2(mark_w, rh)
				var is_perk: bool = str(r["kind"]) == "perk"
				var tr_l: Label = pr["tier"]
				var br: Label = pr["branch"]
				var tg: Label = pr["tag"]
				tr_l.text = str(r.get("tier", ""))
				br.text = str(r.get("branch", ""))
				tg.text = str(r.get("tag", ""))
				var w_tier: float = maxf(kit.natural_width(tr_l, "T9"), kit.natural_width(tr_l, tr_l.text)) + 8.0 if is_perk else 0.0
				var w_tag: float = maxf(maxf(kit.natural_width(tg, "999 locked"), kit.natural_width(tg, tg.text)), 80.0) if is_perk else 0.0
				var w_branch: float = minf(kit.natural_width(br, br.text) + 8.0, inner * 0.3) if is_perk else 0.0
				var x: float = x0 + 4.0 + mark_w + 8.0
				tr_l.position = Vector2(x, y + (rh - HudKit.line_height(tr_l)) * 0.5)
				tr_l.size = Vector2(w_tier, HudKit.line_height(tr_l))
				x += w_tier + (8.0 if is_perk else 0.0)
				var name_w: float = inner - (x - x0) - w_tag - w_branch - 24.0 if is_perk else inner - (x - x0)
				kit.fit_text(nm, str(r["name"]) if is_perk else str(r["text"]), name_w)
				nm.position = Vector2(x, y + (rh - HudKit.line_height(nm)) * 0.5)
				nm.size = Vector2(name_w, HudKit.line_height(nm))
				br.position = Vector2(x0 + inner - w_tag - w_branch - 12.0, y + (rh - HudKit.line_height(br)) * 0.5)
				br.size = Vector2(w_branch, HudKit.line_height(br))
				tg.position = Vector2(x0 + inner - w_tag - 4.0, y + (rh - HudKit.line_height(tg)) * 0.5)
				tg.size = Vector2(w_tag, HudKit.line_height(tg))
				for key in ["tier", "branch", "tag"]:
					(pr[key] as CanvasItem).visible = is_perk
				if bool(r["cursor"]):
					cursor_rect = Rect2(x0, y, inner, rh)
				y += rh + 4.0
	for i in range(ti, texts.size()):
		(texts[i] as CanvasItem).visible = false
	for i in range(ki, kvs.size()):
		(kvs[i]["key"] as CanvasItem).visible = false
		(kvs[i]["value"] as CanvasItem).visible = false
	for i in range(pi, perks.size()):
		for key in ["marker", "tier", "name", "branch", "tag"]:
			(perks[i][key] as CanvasItem).visible = false
	y += 6.0
	var h_total: float = _layout_footer(_res, w, y, model["actions"])
	resolution_modal.size = Vector2(w, h_total)
	resolution_modal.position = Vector2(rect.position.x, maxf(72.0, 64.0 + (736.0 - h_total) * 0.5))
	var perks_on: bool = loop.overlay_state == M0Loop.OVERLAY_COLLAPSED and loop.collapse_phase == M0Loop.PHASE_PERKS
	resolution_focus_bar.visible = perks_on and cursor_rect.size != Vector2.ZERO
	if resolution_focus_bar.visible:
		HudTheme.place_focus_bar(resolution_focus_bar, cursor_rect)


func _refresh_sleep() -> void:
	sleep_modal.visible = loop.sleep_pause_active and controller.sim_clock.paused
	if not sleep_modal.visible:
		sleep_label.text = ""
		_sig.erase("sleep")
		return
	var text: String = "%s\n%s" % [tr("SLEEP_NOTICE"), tr("SLEEP_PRESS_START")]
	if not _changed("sleep", [text, Loc.current()]):
		return
	sleep_label.text = text
	var w: float = HudLayout.BANNER_RECT.size.x - 40.0
	var h: float = HudKit.wrapped_height(sleep_label, text, w)
	sleep_label.position = Vector2(20.0, 16.0)
	sleep_label.size = Vector2(w, h)
	sleep_modal.size = Vector2(HudLayout.BANNER_RECT.size.x, h + 32.0)


func _refresh_settings() -> void:
	settings_modal.visible = settings_menu.is_open
	if not settings_modal.visible:
		settings_label.text = ""
		settings_focus_bar.visible = false
		return
	var m: Dictionary = _settings_parts
	var w: float = HudLayout.MODAL_WIDE_RECT.size.x
	var y: float = _layout_band(m, w, tr("SET_EYEBROW"), tr("SET_TITLE"), "teal", [])
	var h_total: float = HudLayout.MODAL_WIDE_RECT.size.y + 60.0
	var lh: float = HudKit.line_height(settings_label) + float(settings_label.get_theme_constant("line_spacing"))
	var body_top: float = y + 14.0
	(m["foot"] as CanvasItem).visible = false
	for host in m["actions"]:
		(host as CanvasItem).visible = false
	var body_h: float = h_total - HudLayout.BORDER - 12.0 - body_top
	# Rows, a blank, the hint and the scroll line take 3 lines of the body.
	var max_rows: int = int(body_h / lh) - 3
	var lines: PackedStringArray = settings_menu.text(max_rows).split("\n")
	var body: PackedStringArray = lines.slice(2)
	settings_label.text = "\n".join(body)
	settings_label.position = Vector2(HudLayout.BORDER + 24.0, body_top)
	settings_label.size = Vector2(w - 2.0 * (HudLayout.BORDER + 24.0), body_h)
	settings_modal.size = Vector2(w, h_total)
	settings_modal.position = Vector2(HudLayout.MODAL_WIDE_RECT.position.x, maxf(72.0, 64.0 + (736.0 - h_total) * 0.5))
	settings_focus_bar.visible = true
	HudTheme.place_focus_bar(settings_focus_bar, Rect2(settings_label.position.x - 4.0, settings_label.position.y + lh * float(settings_menu.cursor_line(max_rows) - 2), settings_label.size.x + 4.0, lh))


# --- Focus frames ---

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
	# From the models, not the panels' visibility: the ladder refreshes before the modals do.
	var sleeping: bool = loop != null and controller != null and loop.sleep_pause_active and controller.sim_clock.paused
	return (settings_menu != null and settings_menu.is_open) or (loop != null and loop.overlay_state != M0Loop.OVERLAY_NONE) or sleeping


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



# --- The tactical map, drawn on the map panel ---

## Maps a point of the map model's screen space (SolTacticalMap, circular orbits around
## MAP_CENTER) to map-panel px: the orbit system is foreshortened into the 3a ellipses.
func _map_point(model: Vector2) -> Vector2:
	var d: Vector2 = model - SolTacticalMap.MAP_CENTER
	return HudLayout.MAP_ORIGIN - HudLayout.MAP_RECT.position + Vector2(d.x * HudLayout.MAP_STRETCH.x, d.y * HudLayout.MAP_STRETCH.y)


func _map_center() -> Vector2:
	return _map_point(SolTacticalMap.MAP_CENTER)


## An orbit ring (a circle of the model, an ellipse on screen).
func _draw_orbit(radius: float, color: Color, width: float) -> void:
	var pts := PackedVector2Array()
	var c: Vector2 = _map_center()
	var steps: int = 96
	for i in steps + 1:
		var a: float = TAU * float(i) / float(steps)
		pts.append(c + Vector2(cos(a) * radius * HudLayout.MAP_STRETCH.x, sin(a) * radius * HudLayout.MAP_STRETCH.y))
	tactical_map_panel.draw_polyline(pts, color, width, true)


## A dashed ring (the MapNode "docked" ring: 8 on, 6 off).
func _draw_dashed_ring(center: Vector2, radius: float, color: Color, width: float) -> void:
	var step: float = (8.0 + 6.0) / radius
	var on: float = 8.0 / radius
	var a: float = 0.0
	while a < TAU:
		tactical_map_panel.draw_arc(center, radius, a, minf(a + on, TAU), 6, color, width, true)
		a += step


## Label boxes for the station names on the foreshortened map: the first of eight spots
## around each node that stays inside the panel and clear of every node and earlier label.
func _map_label_offsets(discs: Dictionary, widths: Dictionary, font: Font, fs: int) -> Dictionary:
	var ascent: float = font.get_ascent(fs)
	var height: float = ascent + font.get_descent(fs)
	var bounds := Rect2(Vector2(8.0, 8.0), tactical_map_panel.size - Vector2(16.0, 16.0 + HudLayout.TICKER_RECT.size.y))
	var near: float = SolTacticalMap.STATION_NODE_RADIUS_PX + 4.0
	var placed: Array = []
	var out: Dictionary = {}
	for st in discs:
		var wd: float = float(widths[st])
		var spots: Array = [Vector2(near, 5.0), Vector2(-near - wd, 5.0), Vector2(-wd * 0.5, -near - 6.0), Vector2(-wd * 0.5, near + 16.0),
			Vector2(near - 4.0, -near), Vector2(near - 4.0, near + 14.0), Vector2(-near + 4.0 - wd, -near), Vector2(-near + 4.0 - wd, near + 14.0)]
		for lift in [1, 2, 3]:
			spots.append(Vector2(-wd * 0.5, -near - 6.0 - (height + 2.0) * float(lift)))
			spots.append(Vector2(-wd * 0.5, near + 16.0 + (height + 2.0) * float(lift)))
		out[st] = spots[0]
		var chosen: Rect2 = Rect2()
		for off in spots:
			var b := Rect2(Vector2(discs[st]) + off + Vector2(0.0, -ascent), Vector2(wd, height)).grow(1.0)
			if _map_label_fits(b, st, discs, placed, bounds):
				out[st] = off
				chosen = b
				break
		if chosen.size == Vector2.ZERO:
			chosen = Rect2(Vector2(discs[st]) + Vector2(out[st]) + Vector2(0.0, -ascent), Vector2(wd, height)).grow(1.0)
		placed.append(chosen)
	return out


func _map_label_fits(box: Rect2, own: String, discs: Dictionary, placed: Array, bounds: Rect2) -> bool:
	if not bounds.encloses(box):
		return false
	var r_node: float = SolTacticalMap.STATION_NODE_RADIUS_PX + 1.0
	for st in discs:
		if _circle_hits(Vector2(discs[st]), r_node if st != own else SolTacticalMap.STATION_NODE_RADIUS_PX, box):
			return false
	if _circle_hits(_map_center(), SolTacticalMap.SOL_NODE_RADIUS_PX + 1.0, box):
		return false
	for other in placed:
		if box.intersects(other):
			return false
	return true


static func _circle_hits(center: Vector2, radius: float, rect: Rect2) -> bool:
	var nearest := Vector2(clampf(center.x, rect.position.x, rect.end.x), clampf(center.y, rect.position.y, rect.end.y))
	return nearest.distance_squared_to(center) < radius * radius


func _draw_map() -> void:
	if tactical_map == null or tactical_map_panel == null:
		return
	var round_num: int = controller.get_current_round() if controller != null else 0
	var center: Vector2 = _map_center()
	# Flat ligne claire: ink orbit rings, then flat filled nodes with ink contours and a hard shadow cut.
	var stations: Array = tactical_map.get_stations()
	for st in stations:
		var pos_m: Vector2 = tactical_map.get_station_screen_pos(st, round_num)
		var ring_active: bool = st == hud.active_station
		_draw_orbit(pos_m.distance_to(SolTacticalMap.MAP_CENTER), HudTheme.RUST if ring_active else HudTheme.INK, HudTheme.OUTLINE_RING + (1.0 if ring_active else 0.0))
	HudTheme.draw_flat_disc(tactical_map_panel, center, SolTacticalMap.SOL_NODE_RADIUS_PX, HudTheme.OCHRE, HudTheme.OCHRE_DARK)
	var font: Font = HudTheme.role_font(HudTheme.ROLE_LABEL)
	var fs: int = scaled_size(MAP_FONT_SIZE)
	var docked: String = controller.docked_at if controller != null else ""
	var discs: Dictionary = {}
	var texts: Dictionary = {}
	var widths: Dictionary = {}
	for st in stations:
		discs[st] = _map_point(tactical_map.get_station_screen_pos(st, round_num))
		var t: String = Loc.station(st).to_upper()
		if st == docked:
			t = tr("MAP_DOCKED_TAG") % t
		texts[st] = t
		widths[st] = font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var offsets: Dictionary = _map_label_offsets(discs, widths, font, fs)
	for st in stations:
		var pos: Vector2 = discs[st]
		var active: bool = st == hud.active_station
		HudTheme.draw_flat_disc(tactical_map_panel, pos, SolTacticalMap.STATION_NODE_RADIUS_PX, HudTheme.RUST if active else HudTheme.TEAL, HudTheme.RUST_DARK if active else HudTheme.TEAL_DARK)
		var label_pos: Vector2 = pos + Vector2(offsets[st])
		var text: String = str(texts[st])
		tactical_map_panel.draw_string_outline(font, label_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, HudTheme.PAPER)
		tactical_map_panel.draw_string(font, label_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, HudTheme.RUST_DARK if st == docked or active else HudTheme.INK)
	_draw_player_ship(round_num, font, discs)


## The player's ship on its lane, drawn over the stations: a dashed ink lane
## (rust across the belt), a small ochre hull and a YOU tag. While docked, a dashed
## ochre ring marks the home station.
func _draw_player_ship(round_num: int, font: Font, discs: Dictionary) -> void:
	var voyage: Dictionary = tactical_map.get_player_transit(round_num)
	if voyage.is_empty():
		if controller != null and controller.docked_at != "" and discs.has(controller.docked_at):
			_draw_dashed_ring(Vector2(discs[controller.docked_at]), SolTacticalMap.STATION_NODE_RADIUS_PX + 10.0, HudTheme.OCHRE, 4.0)
		return
	var a: Vector2 = _map_point(Vector2(voyage["start_pos"]))
	var b: Vector2 = _map_point(Vector2(voyage["end_pos"]))
	var lane: Color = HudTheme.RUST if bool(voyage["is_belt"]) else HudTheme.INK
	tactical_map_panel.draw_dashed_line(a, b, lane, 3.0, 10.0, true)
	var ship: Vector2 = _map_point(Vector2(voyage["pos"]))
	HudTheme.draw_flat_disc(tactical_map_panel, ship, 9.0, HudTheme.OCHRE, HudTheme.OCHRE_DARK)
	var fs: int = scaled_size(MAP_FONT_SIZE)
	var tag: String = tr("MAP_SHIP_TAG")
	var tag_pos: Vector2 = ship + Vector2(-12.0, 28.0)
	tactical_map_panel.draw_string_outline(font, tag_pos, tag, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, HudTheme.PAPER)
	tactical_map_panel.draw_string(font, tag_pos, tag, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, HudTheme.RUST_DARK)


# --- Refresh ---

func _refresh_readouts() -> void:
	if wordmark_label == null or hud == null or loop == null:
		return
	_refresh_header()
	var overlay_none: bool = loop.overlay_state == M0Loop.OVERLAY_NONE
	market_modal.visible = hud.is_trading_overlay_open() and overlay_none
	fleet_panel.visible = loop.tab == M0Loop.Tab.FLEET and overlay_none and not market_modal.visible
	_refresh_map_status()
	_refresh_ladder()
	_refresh_ticket()
	_refresh_card()
	_refresh_ticker()
	if market_modal.visible:
		_refresh_board()
	if fleet_panel.visible:
		_refresh_fleet()
	# A paused game wears an ochre header contour.
	var header_variation: String = "HeaderPanelPaused" if controller.sim_clock.paused else "HeaderPanel"
	if String(header_panel.theme_type_variation) != header_variation:
		HudTheme.style_panel(header_panel, header_variation)
	_refresh_resolution()
	_refresh_sleep()
	_refresh_settings()
	_dim.visible = resolution_modal.visible or settings_modal.visible
	_update_ladder_focus()
	_update_focus_frames()
	_update_scrollers()
	tactical_map_panel.queue_redraw()


## One sidebar line for the accepted contract ("" when none).
func _contract_sidebar_line() -> String:
	var c: Dictionary = loop.open_contract()
	if c.is_empty():
		return ""
	return tr("SIDE_CONTRACT") % [int(c["qty"]), Loc.commodity(str(c["commodity"])), int(c["due_round"])]


## Why the run ended, from RunController.end_reason ("collapse", "bankruptcy", "manual").
static func _cause_text(reason: String) -> String:
	match reason:
		"bankruptcy":
			return Loc.t("SUM_CAUSE_BANKRUPTCY")
		"manual":
			return Loc.t("SUM_CAUSE_MANUAL")
	return Loc.t("SUM_CAUSE_COLLAPSE")


static func _fmt(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out
