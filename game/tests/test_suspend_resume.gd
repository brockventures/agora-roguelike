extends RefCounted
## Steam Deck suspend/resume lifecycle (#41): raw-delta wake detection, tick purge,
## auto-pause, audio re-arm and focus re-anchoring.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FRAME: float = 1.0 / 60.0 + 0.0001


func _loop(p_seed: int = 7) -> Dictionary:
	var rc := RunController.new(null, p_seed)
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	return {"rc": rc, "hud": hud, "loop": lp}


func test_threshold_is_named_constant() -> String:
	if SimClock.SUSPEND_THRESHOLD != 1.0:
		return "SUSPEND_THRESHOLD should be 1.0, got %f" % SimClock.SUSPEND_THRESHOLD
	if SimClock.is_wake_delta(1.0) or not SimClock.is_wake_delta(1.01):
		return "threshold boundary wrong"
	if SimClock.is_wake_delta(INF) or SimClock.is_wake_delta(NAN):
		return "non-finite deltas must not count as a wake"
	return "ok"


func test_30s_delta_advances_zero_ticks_and_zeroes_accumulator() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	rc.advance(0.01)
	var ticks0: int = rc.sim_clock.total_ticks
	var dd0: int = rc.doomsday.ticks_remaining
	var n: int = lp.advance(30.0)
	if n != 0:
		return "30s delta executed %d ticks" % n
	if rc.sim_clock.total_ticks != ticks0 or rc.doomsday.ticks_remaining != dd0:
		return "sim or doomsday advanced across the wake"
	if rc.sim_clock.accumulator != 0.0:
		return "accumulator should be 0.0, got %f" % rc.sim_clock.accumulator
	if not rc.sim_clock.paused or not lp.sleep_pause_active:
		return "wake should auto-pause with the sleep flag set"
	return "ok"


func test_wake_while_overlay_up_or_already_paused_still_purges() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	rc.sim_clock.accumulator = 0.01
	rc.sim_clock.pause()
	lp.advance(30.0)
	if rc.sim_clock.accumulator != 0.0:
		return "accumulator not zeroed when already paused"
	if lp.sleep_pause_active:
		return "a deliberate player pause should not get the sleep banner"
	if lp.wake_count != 1:
		return "wake must still be handled when paused"
	return "ok"


func test_normal_deltas_unaffected_and_clamp_band_still_clamps() -> String:
	var clock := SimClock.new()
	if clock.step(FRAME) != 1:
		return "normal frame should run 1 tick"
	if clock.paused:
		return "normal frame must not pause"
	var c2 := SimClock.new()
	var n: int = c2.step(0.6)
	if n != 15:
		return "0.6s should clamp to 0.25s = 15 ticks, got %d" % n
	if c2.paused:
		return "delta below the wake threshold must not pause"
	var c3 := SimClock.new()
	if c3.step(1.0) != 15 or c3.paused:
		return "exactly 1.0s is still a clamped long frame"
	return "ok"


func test_wake_emits_signal_and_hooks_audio_rearm() -> String:
	var ctx := _loop()
	var lp: M0Loop = ctx["loop"]
	var seen: Array = []
	lp.woke_from_sleep.connect(func(src: String) -> void: seen.append(src))
	lp.advance(5.0)
	if seen != ["delta"]:
		return "expected one woke_from_sleep('delta'), got %s" % str(seen)
	return "ok"


func test_main_scene_wake_rearms_audio_and_shows_banner() -> String:
	var main: MainScene = load(MAIN_SCENE_PATH).instantiate()
	main.start_new_run()
	main._setup_audio()
	var before: int = main.audio_rearm_count
	main.loop.advance(30.0)
	if main.audio_rearm_count != before + 1:
		return "audio not re-armed on delta wake"
	if main.drone_player == null or main.sfx_players.is_empty():
		return "audio players missing"
	for p in main.sfx_players:
		if p.playing:
			return "sfx voice still playing after re-arm"
	if not main.controller.sim_clock.paused:
		return "sim not paused after wake"
	main.free()
	return "ok"


func test_notification_path_triggers_same_handling() -> String:
	var main: MainScene = load(MAIN_SCENE_PATH).instantiate()
	main.start_new_run()
	main._setup_audio()
	main.controller.sim_clock.accumulator = 0.01
	var before: int = main.audio_rearm_count
	main._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	if not main.controller.sim_clock.paused or main.controller.sim_clock.accumulator != 0.0:
		return "APPLICATION_PAUSED should pause and zero the accumulator"
	main.controller.sim_clock.resume()
	main._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	if not main.controller.sim_clock.paused:
		return "APPLICATION_RESUMED should leave the sim paused"
	if main.audio_rearm_count != before + 2:
		return "expected audio re-armed by both notifications, got %d" % (main.audio_rearm_count - before)
	main._notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	if main.audio_rearm_count != before + 3:
		return "window focus-out should take the same path"
	main.free()
	return "ok"


func test_focus_reanchors_to_open_modal() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	rc.doomsday.ticks_remaining = 1
	rc.advance(0.5)
	lp.rebind_controller()
	lp.advance(0.0001)
	lp.overlay_state = M0Loop.OVERLAY_CHAPTER_11
	lp.advance(30.0)
	if lp.focus_anchor != M0Loop.OVERLAY_CHAPTER_11:
		return "focus should stay anchored to the open modal, got '%s'" % lp.focus_anchor
	lp.overlay_state = M0Loop.OVERLAY_NONE
	lp.set_tab(M0Loop.Tab.MARKET)
	ctx["hud"].gamepad_focus.set_zone(GamepadFocus.Zone.TACTICAL_MAP)
	lp.advance(30.0)
	if lp.focus_anchor != M0Loop.FOCUS_ANCHOR_PAUSE:
		return "focus should anchor to the pause state, got '%s'" % lp.focus_anchor
	if ctx["hud"].gamepad_focus.current_zone != GamepadFocus.Zone.ORDER_BOOK:
		return "gamepad zone not re-anchored to the Market order book"
	return "ok"


func test_resume_clears_banner_and_ticks_continue() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	lp.advance(30.0)
	lp.toggle_pause()
	if lp.sleep_pause_active:
		return "banner flag should clear on resume"
	if lp.advance(FRAME) < 1:
		return "sim should tick again after the player resumes"
	return "ok"
