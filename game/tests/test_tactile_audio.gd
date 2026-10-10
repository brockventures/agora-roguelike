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
	if snap["drone_freq_hz"] != TactileAudio.PAD_BASE_HZ:
		return "Default pad frequency should be the 220 Hz base"
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

	# Wait past cooldown in real time (30ms)
	OS.delay_msec(30)
	if not audio.play_sfx(TactileAudio.KEY_CLICK_DOWN):
		return "Play after 30ms wall-clock cooldown should succeed"

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

	OS.delay_msec(30)
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
	if audio.current_drone_freq != TactileAudio.DRONE_STAGE_HZ[1]:
		return "UNSTABLE pad freq should be %f Hz, got %f" % [TactileAudio.DRONE_STAGE_HZ[1], audio.current_drone_freq]

	audio.update_doomsday_stage(3)
	if audio.current_drone_freq != TactileAudio.DRONE_STAGE_HZ[3]:
		return "IMMINENT pad freq should be %f Hz, got %f" % [TactileAudio.DRONE_STAGE_HZ[3], audio.current_drone_freq]

	audio.update_doomsday_stage(4)
	if audio.current_drone_freq >= TactileAudio.DRONE_STAGE_HZ[0]:
		return "COLLAPSED pad should drop below the NORMAL pitch"

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

	# Test ambient pad waveform (looped, 22050 samples = one second, whole cycles of every partial)
	var drone_wav := audio.get_or_generate_waveform(TactileAudio.DRONE_TENSION)
	if drone_wav == null:
		return "Failed to generate DRONE_TENSION waveform"
	if drone_wav.loop_mode != AudioStreamWAV.LOOP_FORWARD:
		return "DRONE_TENSION waveform should have LOOP_FORWARD mode"
	if drone_wav.loop_end != 22050:
		return "DRONE_TENSION loop_end should be 22050 samples, got %d" % drone_wav.loop_end
	if drone_wav.data.size() != 44100:
		return "DRONE_TENSION 16-bit PCM byte size should be 44100, got %d" % drone_wav.data.size()

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

	# 2. Commodity cycle triggers NAV_TICK (using real wall-clock delay, no manual advance_time)
	OS.delay_msec(30)
	hud.cycle_commodity(1)
	if not played_sounds.has(TactileAudio.NAV_TICK):
		return "cycle_commodity did not trigger NAV_TICK"

	# 3. Trading overlay toggle triggers MODAL_OPEN
	OS.delay_msec(30)
	hud.open_trading_overlay()
	if not played_sounds.has(TactileAudio.MODAL_OPEN):
		return "open_trading_overlay did not trigger MODAL_OPEN"

	# 4. Emergency alert triggers ALARM_CRITICAL
	OS.delay_msec(30)
	hud.post_headline("MAJOR CME DISRUPTION DETECTED", "HAZARDS", "CRITICAL")
	if not played_sounds.has(TactileAudio.ALARM_CRITICAL):
		return "Critical headline did not trigger ALARM_CRITICAL"

	# 5. Snapshot serialization
	var snap: Dictionary = hud.to_dict()
	if not snap.has("tactile_audio"):
		return "OrbitalHUD to_dict missing tactile_audio snapshot"

	return "ok"

func test_hud_unstepped_realtime_cooldown() -> String:
	var hud := OrbitalHUD.new()
	var played_nav_ticks: Array = []
	hud.tactile_audio.sound_played.connect(func(id, bus, db, p):
		if id == TactileAudio.NAV_TICK:
			played_nav_ticks.append(id)
	)

	# 1. First trigger plays immediately
	hud.set_commodity("FOOD")
	if played_nav_ticks.size() != 1:
		return "First set_commodity did not trigger NAV_TICK (count=%d)" % played_nav_ticks.size()

	# 2. Immediate second trigger in the same tick is throttled by real-time cooldown (<25ms)
	hud.set_commodity("FUEL")
	if played_nav_ticks.size() != 1:
		return "Immediate second set_commodity was not throttled by cooldown (count=%d)" % played_nav_ticks.size()

	# 3. Wait 30ms in wall-clock real time without calling advance_time()
	OS.delay_msec(30)

	# 4. Third trigger plays because 30ms real time has elapsed
	hud.set_commodity("ORE")
	if played_nav_ticks.size() != 2:
		return "Third set_commodity after 30ms real delay did not play NAV_TICK (count=%d)" % played_nav_ticks.size()

	return "ok"
