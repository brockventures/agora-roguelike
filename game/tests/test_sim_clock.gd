extends RefCounted
## Tests for SimClock (res://core/sim_clock.gd) deterministic simulation clock.
## Verifies accumulator timing, multi-speed sub-ticks, 30/60/120 FPS parity,
## pause freezing, sleep/wake auto-pause with accumulator zeroing, lag clamping,
## atomic interrupt hooks with zeroed accumulator (anti-burst), and serialization.

func test_init_defaults() -> String:
	var clock := SimClock.new()
	if not is_equal_approx(clock.tick_delta, 1.0 / 60.0):
		return "expected tick_delta ~= 1/60, got %f" % clock.tick_delta
	if clock.speed != 1:
		return "expected default speed 1, got %d" % clock.speed
	if clock.paused != false:
		return "expected paused == false"
	if clock.accumulator != 0.0:
		return "expected accumulator == 0.0"
	if clock.total_ticks != 0:
		return "expected total_ticks == 0"
	return "ok"

func test_speed_controls() -> String:
	var clock := SimClock.new()
	if not clock.set_speed(2):
		return "set_speed(2) failed"
	if clock.speed != 2:
		return "expected speed == 2"

	if not clock.set_speed(5):
		return "set_speed(5) failed"
	if clock.speed != 5:
		return "expected speed == 5"

	# Invalid speeds should be rejected and leave current speed unchanged
	if clock.set_speed(3):
		return "set_speed(3) should have failed"
	if clock.speed != 5:
		return "speed should remain 5 after invalid set_speed"

	if clock.set_speed(0) or clock.set_speed(-1) or clock.set_speed(10):
		return "invalid speeds 0, -1, 10 should have failed"
	return "ok"

func test_fps_parity_30_60_120() -> String:
	# Running 1 second of simulation time across 30, 60, and 120 FPS render loops
	# must produce identical tick counts (exactly 60 ticks).
	var c30 := SimClock.new()
	var t30 := 0
	for i in range(30):
		t30 += c30.step(1.0 / 30.0)

	var c60 := SimClock.new()
	var t60 := 0
	for i in range(60):
		t60 += c60.step(1.0 / 60.0)

	var c120 := SimClock.new()
	var t120 := 0
	for i in range(120):
		t120 += c120.step(1.0 / 120.0)

	if t30 != 60:
		return "30 FPS loop produced %d ticks, expected 60" % t30
	if t60 != 60:
		return "60 FPS loop produced %d ticks, expected 60" % t60
	if t120 != 60:
		return "120 FPS loop produced %d ticks, expected 60" % t120
	if c30.total_ticks != 60 or c60.total_ticks != 60 or c120.total_ticks != 60:
		return "total_ticks mismatch across FPS loops"
	return "ok"

func test_deck_refresh_rates_parity() -> String:
	# Simulates Steam Deck relevant refresh rates (40, 45, 60, 90, 144 Hz)
	# Verifies that rates produce expected ticks within 1 tick (constant phase lag, no drift).
	var rates := [40, 45, 60, 90, 144]
	for fps in rates:
		var c := SimClock.new()
		var ticks := 0
		var delta := 1.0 / float(fps)
		for i in range(fps):
			ticks += c.step(delta)
		# Over 1.0s, rates give either 60 or 59 ticks (exact or at most 1 tick phase lag)
		if abs(ticks - 60) > 1:
			return "FPS %d produced %d ticks over 1s, expected 59 or 60" % [fps, ticks]
	return "ok"

func test_speed_multipliers_sub_ticks() -> String:
	# 1x executes 60 sub-ticks over 1.0s
	var c1 := SimClock.new(1.0 / 60.0, 1)
	var t1 := 0
	for i in range(60):
		t1 += c1.step(1.0 / 60.0)
	if t1 != 60:
		return "1x speed produced %d ticks, expected 60" % t1

	# 2x executes 120 sub-ticks over 1.0s (2 discrete sub-ticks per fixed step)
	var c2 := SimClock.new(1.0 / 60.0, 2)
	var t2 := 0
	for i in range(60):
		t2 += c2.step(1.0 / 60.0)
	if t2 != 120:
		return "2x speed produced %d ticks, expected 120" % t2

	# 5x executes 300 sub-ticks over 1.0s (5 discrete sub-ticks per fixed step)
	var c5 := SimClock.new(1.0 / 60.0, 5)
	var t5 := 0
	for i in range(60):
		t5 += c5.step(1.0 / 60.0)
	if t5 != 300:
		return "5x speed produced %d ticks, expected 300" % t5

	return "ok"

func test_zero_time_on_pause() -> String:
	# Ryan Rule: in single-player, time NEVER advances while paused.
	var clock := SimClock.new()
	var executed := clock.step(1.0 / 60.0)
	if executed != 1:
		return "expected 1 tick initially"

	clock.pause()
	if not clock.paused:
		return "expected clock to be paused"

	# Stepping while paused returns 0 and does not accumulate
	for i in range(10):
		var p_exec := clock.step(1.0 / 60.0)
		if p_exec != 0:
			return "clock executed %d ticks while paused, expected 0" % p_exec

	if clock.total_ticks != 1:
		return "total_ticks advanced while paused: %d" % clock.total_ticks
	if clock.accumulator != 0.0:
		return "accumulator accrued delta while paused: %f" % clock.accumulator

	clock.resume()
	if clock.paused:
		return "expected clock to be resumed"

	var r_exec := clock.step(1.0 / 60.0)
	if r_exec != 1:
		return "clock failed to resume ticking: got %d" % r_exec
	if clock.total_ticks != 2:
		return "expected total_ticks == 2 after resume, got %d" % clock.total_ticks

	return "ok"

func test_suspend_wake_detection_before_clamp() -> String:
	# Marvin Finding: If raw frame delta > 1.0s, treat as a process wake from sleep
	# (e.g. Steam Deck sleep freeze): trigger auto-pause immediately and reset
	# accumulator remainder to 0.0s so missed sleep time is discarded completely.
	var clock := SimClock.new()
	clock.step(0.01)
	if clock.accumulator <= 0.0:
		return "expected positive accumulator remainder"

	# Simulate 2.5s device sleep suspend wake
	var res := clock.step(2.5)
	if res != 0:
		return "expected 0 ticks on suspend wake, got %d" % res
	if not clock.paused:
		return "expected clock to auto-pause on suspend wake"
	if clock.auto_paused_reason != "system_suspend":
		return "expected auto_paused_reason == 'system_suspend', got '%s'" % clock.auto_paused_reason
	if clock.accumulator != 0.0:
		return "expected accumulator to be reset to 0.0s on sleep wake, got %f" % clock.accumulator
	if clock.total_ticks != 0:
		return "expected total_ticks == 0, got %d" % clock.total_ticks

	return "ok"

func test_spiral_of_death_clamp() -> String:
	# Frame delta > 0.25s clamped to 0.25s max to prevent simulation lag cascades
	var clock := SimClock.new()
	# Delta of 0.6s should clamp to 0.25s (15 ticks at 60Hz: 0.25 / (1/60) = 15)
	var executed := clock.step(0.6)
	if executed != 15:
		return "expected 15 ticks from clamped 0.25s, got %d" % executed
	if clock.total_ticks != 15:
		return "expected total_ticks == 15, got %d" % clock.total_ticks
	if not is_zero_approx(clock.accumulator):
		return "expected zero accumulator remainder after exact 15 ticks, got %f" % clock.accumulator

	return "ok"

func test_atomic_interrupt_hooks_and_no_resume_burst() -> String:
	# Marvin & Amos Finding: An interrupt must zero the accumulator so resuming
	# does not fire an aggressive burst (e.g. 75 sub-ticks at 5x).
	var clock := SimClock.new(1.0 / 60.0, 5) # 5x speed
	var hook_counter := [0]
	var stop_predicate := func() -> bool:
		hook_counter[0] += 1
		return hook_counter[0] >= 4

	clock.register_interrupt_hook(stop_predicate)

	# Step with 0.25s clamped delta (would normally produce 15 * 5 = 75 sub-ticks)
	var executed := clock.step(0.25)
	if executed != 4:
		return "expected interrupt to halt execution at exactly 4 sub-ticks, got %d" % executed
	if not clock.paused:
		return "expected clock to be paused by interrupt"
	if clock.accumulator != 0.0:
		return "expected accumulator to be zeroed on interrupt to prevent resume burst, got %f" % clock.accumulator

	# Unregister hook and resume
	clock.unregister_interrupt_hook(stop_predicate)
	clock.resume()

	# Stepping with 1 standard frame (1/60s) after resume must NOT burst
	var resume_executed := clock.step(1.0 / 60.0)
	if resume_executed != 5:
		return "expected clean resume with exactly 5 sub-ticks (1 frame), got %d (resume burst defect)" % resume_executed

	return "ok"

func test_nan_inf_delta_guards() -> String:
	var clock := SimClock.new()
	# NaN delta must be rejected and not poison accumulator
	var nan_res := clock.step(NAN)
	if nan_res != 0:
		return "expected 0 ticks on NaN delta, got %d" % nan_res
	if is_nan(clock.accumulator):
		return "accumulator was poisoned with NaN"

	# Negative or zero delta
	if clock.step(0.0) != 0 or clock.step(-0.5) != 0:
		return "expected 0 ticks on non-positive delta"

	# Normal delta still works after NaN
	var ok_res := clock.step(1.0 / 60.0)
	if ok_res != 1:
		return "expected clock to advance normally after rejected NaN"

	return "ok"

func test_reset_emits_paused_changed() -> String:
	var clock := SimClock.new()
	clock.pause()
	if not clock.paused:
		return "pause() failed"

	var signal_received := [false]
	var on_paused_changed := func(is_paused: bool) -> void:
		signal_received[0] = (is_paused == false)

	clock.paused_changed.connect(on_paused_changed)
	clock.reset()

	if clock.paused != false:
		return "expected paused == false after reset()"
	if not signal_received[0]:
		return "reset() did not emit paused_changed(false)"

	return "ok"

func test_interpolation_alpha() -> String:
	var clock := SimClock.new()
	if clock.get_interpolation_alpha() != 0.0:
		return "expected initial alpha == 0.0"

	# Add half of a tick_delta (0.5 * 1/60s = 1/120s)
	clock.step(1.0 / 120.0)
	var alpha := clock.get_interpolation_alpha()
	if not is_equal_approx(alpha, 0.5):
		return "expected alpha ~= 0.5, got %f" % alpha

	return "ok"

func test_to_dict_from_dict_roundtrip() -> String:
	var clock := SimClock.new(1.0 / 60.0, 2)
	clock.step(0.05)
	clock.auto_paused_reason = "hazard"
	clock.paused = true

	var d := clock.to_dict()
	var restored := SimClock.from_dict(d)

	if not is_equal_approx(restored.tick_delta, clock.tick_delta):
		return "tick_delta mismatch in roundtrip"
	if restored.speed != clock.speed:
		return "speed mismatch in roundtrip"
	if restored.paused != clock.paused:
		return "paused mismatch in roundtrip"
	if not is_equal_approx(restored.accumulator, clock.accumulator):
		return "accumulator mismatch in roundtrip"
	if restored.total_ticks != clock.total_ticks:
		return "total_ticks mismatch in roundtrip"
	if restored.auto_paused_reason != clock.auto_paused_reason:
		return "auto_paused_reason mismatch in roundtrip"

	# Test from_dict hardening against corrupted values
	var corrupt := {
		"speed": 99,
		"accumulator": 500.0,
		"total_ticks": -10,
	}
	var hardened := SimClock.from_dict(corrupt)
	if hardened.speed != 1:
		return "corrupted speed was not sanitized to 1"
	if hardened.accumulator > 0.25:
		return "corrupted accumulator was not clamped to 0.25"
	if hardened.total_ticks < 0:
		return "corrupted total_ticks was not clamped to >= 0"

	return "ok"
