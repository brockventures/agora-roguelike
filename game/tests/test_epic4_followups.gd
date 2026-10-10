extends RefCounted
## Epic 4 steering follow-ups (#104, part of #20): ambient pad in place of the
## sub-bass drone, one-shot alerts, alert volume and mute in settings, the
## collapse -> summary -> perks -> new run flow driven only by gamepad events,
## the cause line on the summary, and control hints that match the shipped scheme.

const MainScript := preload("res://scenes/main.gd")
const FRAME: float = 1.0 / 60.0 + 0.0001
const TMP_ROOT := "user://test_tmp"
var _counter: int = 0


func _store() -> SaveStore:
	_counter += 1
	return SaveStore.new("%s/e4f_%d_%d" % [TMP_ROOT, Time.get_ticks_usec(), _counter])


func _cleanup(store: SaveStore) -> void:
	load("res://tests/test_save_load.gd")._rm_rf(store.dir)
	DirAccess.remove_absolute(TMP_ROOT)


func _btn(index: int) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = index
	e.pressed = true
	return e


func _act(name: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	return e


## Peak absolute sample (16-bit) of a generated stream.
func _peak(stream: AudioStreamWAV) -> int:
	var peak := 0
	var d: PackedByteArray = stream.data
	for i in range(0, d.size() - 1, 2):
		var v: int = d[i] | (d[i + 1] << 8)
		if v >= 32768:
			v -= 65536
		peak = maxi(peak, absi(v))
	return peak


# --- Audio: mid-range pad, one-shot alerts ---

func test_pad_replaces_the_sub_bass_drone() -> String:
	var audio := TactileAudio.new()
	for stage in TactileAudio.DRONE_STAGE_HZ.size():
		audio.update_doomsday_stage(stage)
		if audio.current_drone_freq < 150.0 or audio.current_drone_freq > 500.0:
			return "stage %d pad root %.1f Hz is not mid-range (150-500 Hz)" % [stage, audio.current_drone_freq]
	if absf(TactileAudio.DRONE_STAGE_HZ[0] - TactileAudio.PAD_BASE_HZ) > 0.01 or audio.get_drone_pitch_scale() <= 0.5:
		return "pad scale should be relative to the 220 Hz base"
	var pad: AudioStreamWAV = audio.get_or_generate_waveform(TactileAudio.DRONE_TENSION)
	if pad.loop_mode != AudioStreamWAV.LOOP_FORWARD:
		return "the pad is the one sound that loops"
	var peak: int = _peak(pad)
	if peak < 4000 or peak > 20000:
		return "pad level %d outside the soft range" % peak
	# Seamless loop: the sample after the last must continue the first. With whole
	# cycles per second the first sample is 0 and the last is close to it.
	var first: int = pad.data[0] | (pad.data[1] << 8)
	var n: int = pad.data.size()
	var last: int = pad.data[n - 2] | (pad.data[n - 1] << 8)
	if last >= 32768:
		last -= 65536
	if absi(first) > 50 or absi(last) > 2500:
		return "pad loop seam jumps (first %d, last %d)" % [first, last]
	return "ok"


func test_alerts_are_one_shots_that_never_loop() -> String:
	var audio := TactileAudio.new()
	for id in TactileAudio.ALERT_SOUNDS:
		var w: AudioStreamWAV = audio.get_or_generate_waveform(id)
		if w.loop_mode != AudioStreamWAV.LOOP_DISABLED:
			return "%s must not loop" % id
		if w.get_length() <= 0.05 or w.get_length() > 1.0:
			return "%s length %.2f s is not a short one-shot" % [id, w.get_length()]
		if not audio.is_alert_sound(id) or audio.get_sound_bus(id) != TactileAudio.BUS_ALERTS:
			return "%s should be an Alerts-bus alert" % id
	# Every generated sound except the pad is a one-shot.
	for id in [TactileAudio.KEY_CLICK_DOWN, TactileAudio.NAV_TICK, TactileAudio.MARKET_BELL, TactileAudio.TICKER_BLIP]:
		if audio.get_or_generate_waveform(id).loop_mode != AudioStreamWAV.LOOP_DISABLED:
			return "%s must not loop" % id
	var warn: AudioStreamWAV = audio.get_or_generate_waveform(TactileAudio.ALARM_WARNING)
	var crit: AudioStreamWAV = audio.get_or_generate_waveform(TactileAudio.ALARM_CRITICAL)
	if warn.data == crit.data:
		return "warning and critical alerts should sound different"
	return "ok"


func test_one_alert_event_plays_one_alert() -> String:
	var hud := OrbitalHUD.new(RunController.new(null, 7))
	var heard: Array = []
	hud.tactile_audio.sound_played.connect(func(id, _bus, _db, _p): heard.append(id))
	hud.post_headline("Piracy on the Ceres lane", "HAZARD", "WARNING")
	hud.tactile_audio.advance_time(1.0)
	hud.post_headline("Insolvency imminent", "INSOLVENCY", "CRITICAL")
	if heard != [TactileAudio.ALARM_WARNING, TactileAudio.ALARM_CRITICAL]:
		return "each alert headline should play exactly one alert sound, got %s" % str(heard)
	return "ok"


func test_alert_mute_silences_alerts_only() -> String:
	var audio := TactileAudio.new()
	audio.set_alert_mute(true)
	if audio.play_sfx(TactileAudio.ALARM_CRITICAL) or audio.play_sfx(TactileAudio.ALARM_WARNING):
		return "muted alerts must not play"
	if not audio.play_sfx(TactileAudio.TICKER_BLIP) or not audio.play_sfx(TactileAudio.KEY_CLICK_DOWN):
		return "muting alerts must leave the ticker and UI sounds alone"
	audio.set_alert_mute(false)
	audio.set_alert_volume(0.34)
	if absf(audio.get_bus_volume(TactileAudio.BUS_ALERTS) - 0.3) > 0.001:
		return "alert volume should snap to tenths, got %f" % audio.get_bus_volume(TactileAudio.BUS_ALERTS)
	return "ok"


# --- Settings: alert volume + mute ---

func test_alert_settings_persist_and_validate() -> String:
	var store := _store()
	var s := AccessibilitySettings.new()
	if s.alert_volume != 1.0 or s.alert_mute:
		return "defaults should be full volume, not muted"
	s.set_alert_volume(0.4)
	s.set_alert_mute(true)
	if s.save(store) != OK:
		return "save failed"
	var back := AccessibilitySettings.load_from(store)
	var err := ""
	if absf(back.alert_volume - 0.4) > 0.001 or not back.alert_mute:
		err = "alert settings did not round-trip through settings.json: %s" % str(back.to_dict())
	var bad := AccessibilitySettings.from_dict({"alert_volume": "loud", "alert_mute": "yes"})
	if err == "" and (bad.alert_volume != 1.0 or bad.alert_mute):
		err = "bad stored values should fall back to defaults"
	var hi := AccessibilitySettings.from_dict({"alert_volume": 7})
	if err == "" and hi.alert_volume != 1.0:
		err = "out-of-range volume should clamp to 1.0"
	var old := AccessibilitySettings.from_dict({"text_scale": 1.3})
	if err == "" and (old.alert_volume != 1.0 or old.alert_mute or old.text_scale != 1.3):
		err = "a settings.json from before #104 should load with alert defaults"
	s.reset_defaults()
	if err == "" and (s.alert_volume != 1.0 or s.alert_mute):
		err = "reset should restore alert defaults"
	_cleanup(store)
	return "ok" if err == "" else err


func test_settings_menu_alert_rows_are_gamepad_reachable() -> String:
	var menu := SettingsMenu.new(AccessibilitySettings.new())
	menu.open()
	var vol_row := -1
	var mute_row := -1
	for i in menu.rows().size():
		match int(menu.rows()[i]["kind"]):
			SettingsMenu.Row.ALERT_VOLUME:
				vol_row = i
			SettingsMenu.Row.ALERT_MUTE:
				mute_row = i
	if vol_row < 0 or mute_row != vol_row + 1:
		return "alert volume and mute rows missing: %d / %d" % [vol_row, mute_row]
	# D-pad down reaches the volume row; left lowers, right raises (clamped).
	for i in vol_row:
		menu.handle_event(_act("ui_down"))
	if menu.cursor != vol_row:
		return "D-pad did not reach the volume row"
	menu.handle_event(_act("ui_left"))
	menu.handle_event(_act("ui_left"))
	if absf(menu.settings.alert_volume - 0.8) > 0.001:
		return "Left x2 should give 80%%, got %f" % menu.settings.alert_volume
	if menu.row_text(vol_row, menu.rows()[vol_row]).find("80%") < 0 or menu.row_text(vol_row, menu.rows()[vol_row]).find("Alert volume") < 0:
		return "volume row text wrong: %s" % menu.row_text(vol_row, menu.rows()[vol_row])
	menu.handle_event(_act("ui_right"))
	menu.handle_event(_act("ui_right"))
	if menu.settings.alert_volume != 1.0:
		return "volume should clamp at 100%"
	# A on the volume row wraps past 100% to silence so A alone reaches every step.
	menu.handle_event(_act("ui_accept"))
	if menu.settings.alert_volume != 0.0:
		return "A at 100%% should wrap to 0%%, got %f" % menu.settings.alert_volume
	menu.handle_event(_act("ui_down"))
	menu.handle_event(_act("ui_accept"))
	if not menu.settings.alert_mute or menu.row_text(mute_row, menu.rows()[mute_row]).find("On") < 0:
		return "A on the mute row should turn mute on"
	menu.handle_event(_act("ui_left"))
	if menu.settings.alert_mute:
		return "Left/Right should toggle mute back off"
	return "ok"


func test_main_applies_alert_settings_to_the_alerts_bus_and_saves() -> String:
	var store := _store()
	var m: MainScene = MainScript.new()
	m.enable_persistence(store)
	m.start_new_run(5)
	m.settings.set_alert_volume(0.5)
	m.settings.set_alert_mute(true)
	var err := ""
	if absf(m.tactile_audio.get_bus_volume(TactileAudio.BUS_ALERTS) - 0.5) > 0.001 or not m.tactile_audio.is_bus_muted(TactileAudio.BUS_ALERTS):
		err = "settings did not reach the audio model's Alerts bus"
	if err == "" and m.tactile_audio.play_sfx(TactileAudio.ALARM_CRITICAL):
		err = "muted setting should silence alerts in the live model"
	if err == "":
		var saved: Dictionary = store.load_settings()
		if absf(float(saved.get("alert_volume", -1.0)) - 0.5) > 0.001 or saved.get("alert_mute", false) != true:
			err = "settings.json missing the alert fields: %s" % str(saved)
	m.free()
	# A fresh Main reading the same store comes up with the saved alert settings.
	if err == "":
		var m2: MainScene = MainScript.new()
		m2.enable_persistence(store)
		m2.start_new_run(5)
		if absf(m2.tactile_audio.get_bus_volume(TactileAudio.BUS_ALERTS) - 0.5) > 0.001 or not m2.tactile_audio.is_bus_muted(TactileAudio.BUS_ALERTS):
			err = "a new session did not restore the alert volume and mute"
		m2.free()
	_cleanup(store)
	return "ok" if err == "" else err


# --- Collapse flow, gamepad only ---

func test_collapse_to_new_run_driven_by_gamepad_buttons_only() -> String:
	var m: MainScene = MainScript.new()
	m.start_new_run(5)
	var lp: M0Loop = m.loop
	var rc: RunController = m.controller
	for i in 40:
		lp.advance(FRAME)
	rc.profile.severance_points = 100
	rc.doomsday.ticks_remaining = 1
	lp.advance(FRAME)
	var err := ""
	if lp.overlay_state != M0Loop.OVERLAY_COLLAPSED or lp.collapse_phase != M0Loop.PHASE_SUMMARY:
		err = "collapse should open the summary"
	# Summary: all four numbers plus the cause, and the prompt for A.
	var sum_text: String = m._resolution_text()
	if err == "":
		for needle in ["SOVEREIGN DEFAULT", "NET WORTH", "PEAK NET WORTH", "ROUNDS SURVIVED", "SEVERANCE BANKED", "CAUSE", "The Doomsday Clock ran out", "Press A for Golden Parachutes"]:
			if sum_text.find(needle) < 0:
				err = "summary missing '%s': %s" % [needle, sum_text]
				break
	# Only A advances the summary; a stray D-pad press must not.
	if err == "" and lp.handle_input(_btn(JOY_BUTTON_DPAD_DOWN)):
		err = "D-pad must not advance the summary"
	if err == "" and (not lp.handle_input(_btn(JOY_BUTTON_A)) or lp.collapse_phase != M0Loop.PHASE_PERKS):
		err = "A on the summary should open Golden Parachutes"
	if err == "" and m._resolution_text().find("GOLDEN PARACHUTES") < 0:
		err = "perk screen text missing"
	# A buys the focused perk; D-pad down walks to START NEW RUN.
	var pick := ""
	if err == "":
		var rows: Array = lp.perk_rows()
		if lp.perk_cursor >= rows.size():
			err = "perk cursor should start on a buyable perk"
		else:
			pick = str(rows[lp.perk_cursor]["id"])
			if not lp.handle_input(_btn(JOY_BUTTON_A)) or not rc.profile.has_unlock(pick):
				err = "A did not buy perk %s" % pick
	if err == "":
		var guard := 0
		while lp.perk_cursor < lp.perk_rows().size() and guard < 40:
			lp.handle_input(_btn(JOY_BUTTON_DPAD_DOWN))
			guard += 1
		if lp.perk_cursor != lp.perk_rows().size():
			err = "D-pad down never reached START NEW RUN"
	if err == "" and (not lp.handle_input(_btn(JOY_BUTTON_A)) or m.controller == rc):
		err = "A on START NEW RUN did not start a new run"
	if err == "":
		var rc2: RunController = m.controller
		if lp.overlay_state != M0Loop.OVERLAY_NONE or lp.collapse_phase != M0Loop.PHASE_NONE or rc2.is_collapsed():
			err = "new run should be live with no overlay"
		elif not rc2.profile.has_unlock(pick):
			err = "the bought perk did not carry into the new run"
		elif lp.advance(FRAME) == 0:
			err = "new run does not tick"
	m.free()
	return "ok" if err == "" else err


func test_summary_names_the_cause() -> String:
	if MainScene._cause_text("collapse").find("Doomsday Clock") < 0:
		return "collapse cause text"
	if MainScene._cause_text("bankruptcy").find("Chapter 11") < 0 or MainScene._cause_text("manual").find("player") < 0:
		return "bankruptcy / manual cause text"
	if MainScene._cause_text("something-new") != MainScene._cause_text("collapse"):
		return "an unknown reason should fall back to the collapse wording"
	return "ok"


# --- Control hints match the shipped scheme ---

func test_control_hint_matches_the_shipped_scheme() -> String:
	var hint: String = Loc.t("HUD_CONTROLS_HINT")
	for needle in ["LB/RB tab", "LT/RT station", "R-stick commodity"]:
		if hint.find(needle) < 0:
			return "control hint missing '%s': %s" % [needle, hint]
	# And the hint agrees with project.godot: bumpers = tabs, triggers = stations, right stick = commodity.
	var want := {
		"m0_tab_prev": JOY_BUTTON_LEFT_SHOULDER, "m0_tab_next": JOY_BUTTON_RIGHT_SHOULDER,
	}
	for a in want:
		var ok := false
		for ev in InputMap.action_get_events(a):
			if ev is InputEventJoypadButton and int(ev.button_index) == int(want[a]):
				ok = true
		if not ok:
			return "%s is not on the bumper the hint names" % a
	var axes := {"m0_station_prev": JOY_AXIS_TRIGGER_LEFT, "m0_station_next": JOY_AXIS_TRIGGER_RIGHT, "m0_commodity_prev": JOY_AXIS_RIGHT_X, "m0_commodity_next": JOY_AXIS_RIGHT_X}
	for a in axes:
		var ok2 := false
		for ev in InputMap.action_get_events(a):
			if ev is InputEventJoypadMotion and int(ev.axis) == int(axes[a]):
				ok2 = true
		if not ok2:
			return "%s is not on the trigger/stick the hint names" % a
	return "ok"
