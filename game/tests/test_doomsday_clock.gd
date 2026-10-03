extends RefCounted
## Tests for DoomsdayClock (res://core/doomsday_clock.gd) Sol System collapse countdown & debt burn.
## Verifies stage progression (NORMAL -> UNSTABLE -> CRITICAL -> IMMINENT -> COLLAPSED),
## non-linear debt burn escalation, stabilization tributes, SimClock interrupt hook integration,
## debt service priority, and full state serialization roundtrip.

func test_init_defaults() -> String:
	var clock := DoomsdayClock.new()
	if clock.stage != DoomsdayClock.Stage.NORMAL:
		return "expected stage NORMAL (0), got %d" % clock.stage
	if not is_equal_approx(clock.total_time, 600.0):
		return "expected total_time 600.0, got %f" % clock.total_time
	if not is_equal_approx(clock.time_remaining, 600.0):
		return "expected time_remaining 600.0, got %f" % clock.time_remaining
	if not is_equal_approx(clock.principal_debt, 50000.0):
		return "expected principal_debt 50000, got %f" % clock.principal_debt
	if clock.accumulated_interest != 0.0:
		return "expected accumulated_interest 0.0, got %f" % clock.accumulated_interest
	if not is_equal_approx(clock.get_time_ratio(), 1.0):
		return "expected time ratio 1.0, got %f" % clock.get_time_ratio()
	return "ok"

func test_stage_progression_across_thresholds() -> String:
	# Total time 100s for easy mental math:
	# > 75s: NORMAL
	# <= 75s: UNSTABLE
	# <= 40s: CRITICAL
	# <= 15s: IMMINENT
	# <= 0s: COLLAPSED
	var clock := DoomsdayClock.new(100.0, 10000.0, 10.0, 0.0)

	# 1. Advance to 80s remaining -> still NORMAL
	clock.step(20.0)
	if clock.stage != DoomsdayClock.Stage.NORMAL:
		return "at 80s remaining, expected NORMAL, got %d" % clock.stage
	if clock.should_auto_pause():
		return "should not trigger auto-pause without stage change"

	# 2. Advance to 74s remaining -> UNSTABLE
	clock.step(6.0)
	if clock.stage != DoomsdayClock.Stage.UNSTABLE:
		return "at 74s remaining, expected UNSTABLE, got %d" % clock.stage
	if not clock.should_auto_pause():
		return "expected auto-pause interrupt on transition to UNSTABLE"
	if clock.should_auto_pause():
		return "should_auto_pause flag should clear after read"

	# 3. Advance to 39s remaining -> CRITICAL
	clock.step(35.0)
	if clock.stage != DoomsdayClock.Stage.CRITICAL:
		return "at 39s remaining, expected CRITICAL, got %d" % clock.stage
	if not clock.should_auto_pause():
		return "expected auto-pause interrupt on transition to CRITICAL"

	# 4. Advance to 14s remaining -> IMMINENT
	clock.step(25.0)
	if clock.stage != DoomsdayClock.Stage.IMMINENT:
		return "at 14s remaining, expected IMMINENT, got %d" % clock.stage
	if not clock.should_auto_pause():
		return "expected auto-pause interrupt on transition to IMMINENT"

	# 5. Advance to 0s remaining -> COLLAPSED
	clock.step(20.0)
	if clock.stage != DoomsdayClock.Stage.COLLAPSED:
		return "at 0s remaining, expected COLLAPSED, got %d" % clock.stage
	if not is_equal_approx(clock.time_remaining, 0.0):
		return "expected time_remaining clamped to 0.0, got %f" % clock.time_remaining
	if not clock.should_auto_pause():
		return "expected auto-pause interrupt on terminal COLLAPSE"

	# Stepping further after collapse should have zero effect
	var debt_before := clock.get_total_debt()
	clock.step(10.0)
	if not is_equal_approx(clock.get_total_debt(), debt_before):
		return "collapsed clock should not accrue further burn"

	return "ok"

func test_escalating_burn_multipliers() -> String:
	# Base burn 10 credits/sec
	var clock := DoomsdayClock.new(100.0, 0.0, 10.0, 0.0)

	# In NORMAL (1.0x): 10 sec = 100 credits burn
	clock.step(10.0)
	if not is_equal_approx(clock.total_burn_accrued, 100.0):
		return "expected 100 burn in NORMAL, got %f" % clock.total_burn_accrued

	# Step directly into UNSTABLE (ratio <= 0.75, so step to 70s remaining)
	clock.step(20.0)
	# At stage UNSTABLE (1.5x): burn rate should be 15 credits/sec
	if not is_equal_approx(clock.get_current_burn_rate(), 15.0):
		return "expected burn rate 15.0 in UNSTABLE, got %f" % clock.get_current_burn_rate()

	# Step into CRITICAL (ratio <= 0.40, step to 35s remaining)
	clock.step(35.0)
	# At stage CRITICAL (2.5x): burn rate should be 25 credits/sec
	if not is_equal_approx(clock.get_current_burn_rate(), 25.0):
		return "expected burn rate 25.0 in CRITICAL, got %f" % clock.get_current_burn_rate()

	# Step into IMMINENT (ratio <= 0.15, step to 10s remaining)
	clock.step(25.0)
	# At stage IMMINENT (5.0x): burn rate should be 50 credits/sec
	if not is_equal_approx(clock.get_current_burn_rate(), 50.0):
		return "expected burn rate 50.0 in IMMINENT, got %f" % clock.get_current_burn_rate()

	return "ok"

func test_tribute_extends_clock_and_deescalates_stage() -> String:
	var clock := DoomsdayClock.new(100.0, 10000.0, 10.0, 0.0)
	# Advance to 35s remaining (CRITICAL)
	clock.step(65.0)
	if clock.stage != DoomsdayClock.Stage.CRITICAL:
		return "expected CRITICAL at 35s, got %d" % clock.stage
	clock.should_auto_pause()  # Clear flag

	# Pay 800 credits tribute at 0.05s/credit = +40s time added -> 75s remaining
	var time_added := clock.apply_tribute(800, 0.05)
	if not is_equal_approx(time_added, 40.0):
		return "expected 40.0s added, got %f" % time_added
	if not is_equal_approx(clock.time_remaining, 75.0):
		return "expected 75.0s remaining, got %f" % clock.time_remaining

	# De-escalated back to UNSTABLE (ratio 75/100 <= 0.75, but > 0.40)
	if clock.stage != DoomsdayClock.Stage.UNSTABLE:
		return "expected de-escalation to UNSTABLE after tribute, got %d" % clock.stage
	if not clock.should_auto_pause():
		return "expected interrupt on stage de-escalation"

	return "ok"

func test_debt_service_interest_priority() -> String:
	# Principal: 1000, 0 interest initially
	var clock := DoomsdayClock.new(100.0, 1000.0, 10.0, 0.0)
	# Step 10s: adds 100 burn to accumulated_interest
	clock.step(10.0)
	if not is_equal_approx(clock.accumulated_interest, 100.0):
		return "expected 100 interest/burn, got %f" % clock.accumulated_interest
	if not is_equal_approx(clock.principal_debt, 1000.0):
		return "expected 1000 principal, got %f" % clock.principal_debt

	# Pay 60 credits: pays interest only
	var paid1 := clock.service_debt(60)
	if paid1 != 60:
		return "expected 60 paid, got %d" % paid1
	if not is_equal_approx(clock.accumulated_interest, 40.0):
		return "expected 40 remaining interest, got %f" % clock.accumulated_interest
	if not is_equal_approx(clock.principal_debt, 1000.0):
		return "expected principal unchanged, got %f" % clock.principal_debt

	# Pay 140 credits: pays remaining 40 interest, then 100 principal
	var paid2 := clock.service_debt(140)
	if paid2 != 140:
		return "expected 140 paid, got %d" % paid2
	if not is_equal_approx(clock.accumulated_interest, 0.0):
		return "expected 0 interest, got %f" % clock.accumulated_interest
	if not is_equal_approx(clock.principal_debt, 900.0):
		return "expected 900 remaining principal, got %f" % clock.principal_debt

	return "ok"

func test_sim_clock_atomic_interrupt_on_doomsday_transition() -> String:
	# Verify seamless integration with SimClock fixed-step execution
	var sim := SimClock.new(1.0 / 60.0, 1)
	var doomsday := DoomsdayClock.new(10.0, 1000.0, 10.0, 0.0)

	# Register doomsday auto-pause predicate with sim clock
	sim.register_interrupt_hook(Callable(doomsday, "should_auto_pause"))

	# Step 1.0s real time: advances 60 sub-ticks
	var ticks := 0
	for i in range(60):
		# Advance doomsday clock alongside sim clock
		doomsday.step(1.0 / 60.0)
		ticks += sim.step(1.0 / 60.0)

	if sim.paused:
		return "sim should not pause during normal progression"
	if ticks != 60:
		return "expected 60 ticks in first second, got %d" % ticks

	# Force doomsday into UNSTABLE transition (rem <= 7.5s, current is 9.0s)
	doomsday.step(2.0) # rem = 7.0s -> triggers stage transition
	if not doomsday.stage_transition_pending_interrupt:
		return "expected pending interrupt on doomsday clock"

	# Next sim step should evaluate the hook, auto-pause, and zero accumulator
	var interrupt_ticks := sim.step(1.0 / 60.0)
	if not sim.paused:
		return "expected sim_clock to auto-pause when doomsday stage changes"
	if sim.auto_paused_reason != "interrupt":
		return "expected auto_paused_reason == 'interrupt', got %s" % sim.auto_paused_reason
	if sim.accumulator != 0.0:
		return "expected accumulator zeroed on interrupt, got %f" % sim.accumulator

	return "ok"

func test_non_finite_deltas() -> String:
	var clock := DoomsdayClock.new(100.0, 1000.0, 10.0, 0.0)
	clock.step(NAN)
	clock.step(INF)
	clock.step(-INF)
	clock.step(-5.0)
	clock.step(0.0)

	if not is_equal_approx(clock.time_remaining, 100.0):
		return "non-finite or non-positive delta should not advance time"
	if clock.accumulated_interest != 0.0:
		return "non-finite delta should not accrue burn"
	return "ok"

func test_serialization_roundtrip() -> String:
	var clock := DoomsdayClock.new(300.0, 75000.0, 50.0, 0.001)
	clock.step(100.0) # Advanced to 200s remaining (UNSTABLE)
	clock.service_debt(500)
	clock.apply_tribute(200, 0.05)

	var d := clock.to_dict()
	var restored := DoomsdayClock.from_dict(d)

	if not is_equal_approx(restored.total_time, clock.total_time):
		return "total_time mismatch"
	if not is_equal_approx(restored.time_remaining, clock.time_remaining):
		return "time_remaining mismatch"
	if restored.stage != clock.stage:
		return "stage mismatch"
	if not is_equal_approx(restored.principal_debt, clock.principal_debt):
		return "principal_debt mismatch"
	if not is_equal_approx(restored.accumulated_interest, clock.accumulated_interest):
		return "accumulated_interest mismatch"
	if not is_equal_approx(restored.total_burn_accrued, clock.total_burn_accrued):
		return "total_burn_accrued mismatch"
	if not is_equal_approx(restored.total_debt_serviced, clock.total_debt_serviced):
		return "total_debt_serviced mismatch"
	if not is_equal_approx(restored.total_time_added_by_tributes, clock.total_time_added_by_tributes):
		return "total_time_added_by_tributes mismatch"
	if not is_equal_approx(restored.base_burn_rate, clock.base_burn_rate):
		return "base_burn_rate mismatch"
	if not is_equal_approx(restored.interest_rate, clock.interest_rate):
		return "interest_rate mismatch"

	return "ok"
