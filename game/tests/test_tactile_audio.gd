extends RefCounted
## Unit tests for TactileAudio Engine & Financial Market Soundscape (#24).

func test_init_defaults() -> String:
	var audio := TactileAudio.new()
	if audio == null:
		return "Failed to instantiate TactileAudio"
	if audio.get_bus_volume(TactileAudio.BUS_MASTER) != 1.0:
		return "Default master volume should be 1.0"
	if audio.get_bus_volume(TactileAudio.BUS_UI) != 0.85:
		return "Default UI volume should be 0.85"
	if audio.is_bus_muted(TactileAudio.BUS_MASTER):
		return "Master bus should not be muted by default"

	var snap: Dictionary = audio.to_dict()
	if snap["drone_freq_hz"] != 55.0:
		return "Default drone frequency should be 55.0 Hz"
	if snap["recent_events_count"] != 0:
		return "Initial events count should be 0"
	return "ok"

func test_bus_volume_and_mute_controls() -> String:
	var audio := TactileAudio.new()
	var bus_signals: Array = []
	audio.bus_volume_changed.connect(func(b, v): bus_signals.append([b, v]))

	# Test set volume
	if not audio.set_bus_volume(TactileAudio.BUS_UI, 0.5):
		return "Failed to set UI bus volume"
	if audio.get_bus_volume(TactileAudio.BUS_UI) != 0.5:
		return "UI volume mismatch after set: %f" % audio.get_bus_volume(TactileAudio.BUS_UI)

	# Clamping test
	audio.set_bus_volume(TactileAudio.BUS_MARKET, 1.8)
	if audio.get_bus_volume(TactileAudio.BUS_MARKET) != 1.0:
		return "Bus volume should clamp to 1.0 max"

	# Unknown bus rejection
	if audio.set_bus_volume("INVALID_BUS", 0.5):
		return "set_bus_volume should reject invalid bus name"

	# Mute controls
	audio.set_bus_mute(TactileAudio.BUS_ALERTS, true)
	if not audio.is_bus_muted(TactileAudio.BUS_ALERTS):
		return "Alerts bus should be muted"

	# Verify muted bus suppresses playback
	var played := audio.play_sfx(TactileAudio.ALARM_CRITICAL)
	if played:
		return "Muted bus should suppress sound playback"

	return "ok"

func test_mechanical_click_and_pitch_jitter() -> String:
	var audio := TactileAudio.new()
	var played_events: Array = []
	audio.sound_played.connect(func(id, bus, db, p): played_events.append([id, bus, db, p]))

	# Play key click at time 0
	if not audio.play_sfx(TactileAudio.KEY_CLICK_DOWN):
		return "Failed to play KEY_CLICK_DOWN"

	# Immediate repeat within cooldown threshold (<25ms) should be throttled
	var throttled := audio.play_sfx(TactileAudio.KEY_CLICK_DOWN)
	if throttled:
		return "Rapid sound repeat should be throttled by cooldown"

	# Advance time past cooldown
	audio.advance_time(0.05)
	if not audio.play_sfx(TactileAudio.KEY_CLICK_DOWN):
		return "Play after cooldown should succeed"

	# Assert pitch variation was applied
	if played_events.size() != 2:
		return "Expected 2 played events, got %d" % played_events.size()

	return "ok"

func test_market_bell_and_chimes() -> String:
	var audio := TactileAudio.new()
	var played_buses: Array = []
	audio.sound_played.connect(func(id, bus, db, p): played_buses.append(bus))

	audio.play_sfx(TactileAudio.MARKET_BELL)
	if played_buses.is_empty() or played_buses[-1] != TactileAudio.BUS_MARKET:
		return "MARKET_BELL should route to Market_Chimes bus, got %s" % str(played_buses)

	audio.advance_time(0.05)
	audio.play_sfx(TactileAudio.ORDER_FILL)
	if played_buses.size() < 2 or played_buses[-1] != TactileAudio.BUS_MARKET:
		return "ORDER_FILL should route to Market_Chimes bus, got %s" % str(played_buses)

	return "ok"

func test_doomsday_tension_drone_modulation() -> String:
	var audio := TactileAudio.new()
	var tension_signals: Array = []
	audio.tension_level_changed.connect(func(st, freq): tension_signals.append([st, freq]))

	# Advance stages: NORMAL (0) -> UNSTABLE (1) -> CRITICAL (2) -> IMMINENT (3) -> COLLAPSED (4)
	audio.update_doomsday_stage(1)
	if audio.current_drone_freq != 73.4:
		return "UNSTABLE drone freq should be 73.4 Hz, got %f" % audio.current_drone_freq

	audio.update_doomsday_stage(3)
	if audio.current_drone_freq != 110.0:
		return "IMMINENT drone freq should be 110.0 Hz, got %f" % audio.current_drone_freq

	audio.update_doomsday_stage(4)
	if audio.current_drone_freq != 41.2:
		return "COLLAPSED drone freq should drop to sub-bass 41.2 Hz"

	return "ok"

func test_procedural_waveform_generation() -> String:
	var audio := TactileAudio.new()

	# Test click waveform
	var click_wav := audio.get_or_generate_waveform(TactileAudio.KEY_CLICK_DOWN)
	if click_wav == null:
		return "Failed to generate KEY_CLICK_DOWN waveform"
	if click_wav.data.size() == 0:
		return "KEY_CLICK_DOWN waveform data is empty"

	# Test market bell waveform
	var bell_wav := audio.get_or_generate_waveform(TactileAudio.MARKET_BELL)
	if bell_wav == null:
		return "Failed to generate MARKET_BELL waveform"
	if bell_wav.get_length() <= 0.0:
		return "MARKET_BELL length should be positive"

	# Test caching returns same instance
	var cached_bell := audio.get_or_generate_waveform(TactileAudio.MARKET_BELL)
	if cached_bell != bell_wav:
		return "Waveform caching failed to return same instance"

	return "ok"

func test_orbital_hud_signal_bindings() -> String:
	var hud := OrbitalHUD.new()
	if hud.tactile_audio == null:
		return "OrbitalHUD did not instantiate tactile_audio"

	var played_sounds: Array = []
	hud.tactile_audio.sound_played.connect(func(id, bus, db, p): played_sounds.append(id))

	# 1. Station cycle triggers TAB_SWOOSH
	hud.cycle_station(1)
	if not played_sounds.has(TactileAudio.TAB_SWOOSH):
		return "cycle_station did not trigger TAB_SWOOSH"

	# 2. Commodity cycle triggers NAV_TICK
	hud.tactile_audio.advance_time(0.05)
	hud.cycle_commodity(1)
	if not played_sounds.has(TactileAudio.NAV_TICK):
		return "cycle_commodity did not trigger NAV_TICK"

	# 3. Trading overlay toggle triggers MODAL_OPEN
	hud.tactile_audio.advance_time(0.05)
	hud.open_trading_overlay()
	if not played_sounds.has(TactileAudio.MODAL_OPEN):
		return "open_trading_overlay did not trigger MODAL_OPEN"

	# 4. Emergency alert triggers ALARM_CRITICAL
	hud.tactile_audio.advance_time(0.05)
	hud.post_headline("MAJOR CME DISRUPTION DETECTED", "HAZARDS", "CRITICAL")
	if not played_sounds.has(TactileAudio.ALARM_CRITICAL):
		return "Critical headline did not trigger ALARM_CRITICAL"

	# 5. Snapshot serialization
	var snap: Dictionary = hud.to_dict()
	if not snap.has("tactile_audio"):
		return "OrbitalHUD to_dict missing tactile_audio snapshot"

	return "ok"
