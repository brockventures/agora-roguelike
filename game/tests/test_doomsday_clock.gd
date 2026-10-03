extends RefCounted
## Tests for Sol System Doomsday Clock & Debt Burn Engine (PR 1 of #9).

func test_init_defaults() -> String:
	var clock := DoomsdayClock.new()
	if clock.total_ticks != 36000:
		return "expected 36000 default total ticks, got %d" % clock.total_ticks
	if clock.ticks_remaining != 36000:
		return "expected 36000 default ticks remaining, got %d" % clock.ticks_remaining
	if clock.ticks_per_second != 60:
		return "expected 60 ticks per second, got %d" % clock.ticks_per_second
	if clock.stage != DoomsdayClock.Stage.NORMAL:
		return "expected Stage.NORMAL initially, got %d" % clock.stage
	if clock.principal_debt != 50000:
		return "expected 50000 principal debt, got %d" % clock.principal_debt
	if clock.accrued_burn != 0:
		return "expected 0 accrued burn, got %d" % clock.accrued_burn
	if clock.accrued_interest != 0:
		return "expected 0 accrued interest, got %d" % clock.accrued_interest
	if clock.get_total_debt() != 50000:
		return "expected 50000 total debt, got %d" % clock.get_total_debt()
	if clock.base_burn_per_second != 25:
		return "expected 25 base burn rate, got %d" % clock.base_burn_per_second
	if clock.interest_rate_bps_per_minute != 300:
		return "expected 300 bps interest rate, got %d" % clock.interest_rate_bps_per_minute
	return "ok"

func test_stage_progression_across_exact_tick_thresholds() -> String:
	# Total ticks: 10,000 for clean percentage verification
	# NORMAL: > 7500 ticks
	# UNSTABLE: <= 7500 ticks (<= 75%)
	# CRITICAL: <= 4000 ticks (<= 40%)
	# IMMINENT: <= 1500 ticks (<= 15%)
	# COLLAPSED: <= 0 ticks
	var clock := DoomsdayClock.new(10000, 1000, 10, 0, 100)

	# 1. Step to 7,501 ticks remaining -> still NORMAL
	clock.step_ticks(2499)
	if clock.ticks_remaining != 7501:
		return "expected 7501 ticks, got %d" % clock.ticks_remaining
	if clock.stage != DoomsdayClock.Stage.NORMAL:
		return "at 7501 ticks, expected NORMAL, got %d" % clock.stage
	if clock.should_auto_pause():
		return "should not auto-pause when remaining in NORMAL"

	# Exactly 1 more tick -> 7,500 ticks remaining -> UNSTABLE boundary hit
	clock.step_ticks(1)
	if clock.ticks_remaining != 7500:
		return "expected 7500 ticks, got %d" % clock.ticks_remaining
	if clock.stage != DoomsdayClock.Stage.UNSTABLE:
		return "at 7500 ticks, expected UNSTABLE, got %d" % clock.stage
	if not clock.should_auto_pause():
		return "expected auto-pause interrupt on transition to UNSTABLE"

	# 2. Advance to 4,001 ticks -> still UNSTABLE
	clock.step_ticks(3499)
	if clock.stage != DoomsdayClock.Stage.UNSTABLE:
		return "at 4001 ticks, expected UNSTABLE, got %d" % clock.stage

	# 1 more tick -> 4,000 ticks -> CRITICAL
	clock.step_ticks(1)
	if clock.ticks_remaining != 4000:
		return "expected 4000 ticks, got %d" % clock.ticks_remaining
	if clock.stage != DoomsdayClock.Stage.CRITICAL:
		return "at 4000 ticks, expected CRITICAL, got %d" % clock.stage
	if not clock.should_auto_pause():
		return "expected auto-pause interrupt on transition to CRITICAL"

	# 3. Advance to 1,500 ticks -> IMMINENT
	clock.step_ticks(2500)
	if clock.ticks_remaining != 1500:
		return "expected 1500 ticks, got %d" % clock.ticks_remaining
	if clock.stage != DoomsdayClock.Stage.IMMINENT:
		return "at 1500 ticks, expected IMMINENT, got %d" % clock.stage
	if not clock.should_auto_pause():
		return "expected auto-pause interrupt on transition to IMMINENT"

	# 4. Advance to 0 ticks -> COLLAPSED
	clock.step_ticks(1500)
	if clock.ticks_remaining != 0:
		return "expected 0 ticks, got %d" % clock.ticks_remaining
	if clock.stage != DoomsdayClock.Stage.COLLAPSED:
		return "at 0 ticks, expected COLLAPSED, got %d" % clock.stage
	if not clock.should_auto_pause():
		return "expected auto-pause interrupt on terminal COLLAPSE"

	# Stepping further after collapse should have zero effect
	var debt_before := clock.get_total_debt()
	clock.step_ticks(500)
	if clock.ticks_remaining != 0:
		return "collapsed clock should remain clamped at 0 ticks"
	if clock.get_total_debt() != debt_before:
		return "collapsed clock should not accrue further burn"

	return "ok"

func test_escalating_burn_multipliers() -> String:
	# Total: 10,000 ticks, 60 tps. Base burn 10 credits/sec.
	# Multipliers:
	# NORMAL (1.0x): 10 CR/sec -> 10 CR per 60 ticks
	# UNSTABLE (1.5x): 15 CR/sec -> 15 CR per 60 ticks
	# CRITICAL (2.5x): 25 CR/sec -> 25 CR per 60 ticks
	# IMMINENT (5.0x): 50 CR/sec -> 50 CR per 60 ticks
	var clock := DoomsdayClock.new(10000, 0, 10, 0, 60)

	# In NORMAL (1.0x): 60 ticks = exactly 10 CR burn
	clock.step_ticks(60)
	if clock.accrued_burn != 10:
		return "expected 10 accrued burn in NORMAL after 60 ticks, got %d" % clock.accrued_burn
	if clock.total_burn_accrued != 10:
		return "expected 10 total burn accrued, got %d" % clock.total_burn_accrued

	# Advance into UNSTABLE (rem <= 7500): step 2440 ticks to reach 7500
	clock.step_ticks(2440)
	if clock.stage != DoomsdayClock.Stage.UNSTABLE:
		return "expected UNSTABLE stage, got %d" % clock.stage

	var burn_at_unstable_start := clock.accrued_burn
	# At UNSTABLE (1.5x): step 60 ticks -> exactly 15 CR burn
	clock.step_ticks(60)
	var burn_delta_unstable := clock.accrued_burn - burn_at_unstable_start
	if burn_delta_unstable != 15:
		return "expected 15 CR burn in UNSTABLE over 60 ticks, got %d" % burn_delta_unstable

	# Advance into CRITICAL (rem <= 4000): step 3440 ticks to reach 4000
	clock.step_ticks(3440)
	if clock.stage != DoomsdayClock.Stage.CRITICAL:
		return "expected CRITICAL stage, got %d" % clock.stage

	var burn_at_critical_start := clock.accrued_burn
	# At CRITICAL (2.5x): step 60 ticks -> exactly 25 CR burn
	clock.step_ticks(60)
	var burn_delta_critical := clock.accrued_burn - burn_at_critical_start
	if burn_delta_critical != 25:
		return "expected 25 CR burn in CRITICAL over 60 ticks, got %d" % burn_delta_critical

	# Advance into IMMINENT (rem <= 1500): step 2440 ticks to reach 1500
	clock.step_ticks(2440)
	if clock.stage != DoomsdayClock.Stage.IMMINENT:
		return "expected IMMINENT stage, got %d" % clock.stage

	var burn_at_imminent_start := clock.accrued_burn
	# At IMMINENT (5.0x): step 60 ticks -> exactly 50 CR burn
	clock.step_ticks(60)
	var burn_delta_imminent := clock.accrued_burn - burn_at_imminent_start
	if burn_delta_imminent != 50:
		return "expected 50 CR burn in IMMINENT over 60 ticks, got %d" % burn_delta_imminent

	return "ok"

func test_tribute_extends_clock_and_deescalates_stage() -> String:
	# Total ticks: 10,000, 60 tps
	var clock := DoomsdayClock.new(10000, 10000, 10, 0, 60)
	# Advance to 3500 ticks remaining (CRITICAL, <= 4000)
	clock.step_ticks(6500)
	if clock.stage != DoomsdayClock.Stage.CRITICAL:
		return "expected CRITICAL at 3500 ticks, got %d" % clock.stage
	clock.should_auto_pause()  # Clear pending interrupt flag

	# Pay 1500 credits tribute at 3 ticks/credit = +4500 ticks -> 8000 ticks remaining (> 7500 = NORMAL)
	var ticks_added := clock.apply_tribute(1500, 3)
	if ticks_added != 4500:
		return "expected 4500 ticks added, got %d" % ticks_added
	if clock.ticks_remaining != 8000:
		return "expected 8000 ticks remaining, got %d" % clock.ticks_remaining

	# De-escalated all the way back to NORMAL
	if clock.stage != DoomsdayClock.Stage.NORMAL:
		return "expected de-escalation to NORMAL after tribute, got %d" % clock.stage
	if not clock.should_auto_pause():
		return "expected interrupt on stage de-escalation"

	return "ok"

func test_debt_service_priority_and_exact_integer_accounting() -> String:
	# Principal: 1000 CR, 60 tps, 10 CR/s burn, 300 bps interest (3%/min)
	var clock := DoomsdayClock.new(10000, 1000, 10, 300, 60)

	# Advance 3600 ticks (1 full minute):
	# Interest: 1000 * 300 bps = exactly 30 CR interest accrued
	# Burn: in NORMAL (10 CR/s), 60 seconds = 600 CR burn accrued
	clock.step_ticks(3600)

	if clock.accrued_interest != 30:
		return "expected 30 accrued interest after 1 min, got %d" % clock.accrued_interest
	if clock.accrued_burn != 600:
		return "expected 600 accrued burn after 1 min, got %d" % clock.accrued_burn
	if clock.principal_debt != 1000:
		return "expected 1000 principal debt, got %d" % clock.principal_debt
	if clock.get_total_debt() != 1630:
		return "expected total debt 1630 (1000 + 600 + 30), got %d" % clock.get_total_debt()

	# 1. Partial payment: Pay 20 CR (pays portion of interest)
	var paid1 := clock.service_debt(20)
	if paid1 != 20:
		return "expected 20 paid, got %d" % paid1
	if clock.accrued_interest != 10:
		return "expected 10 remaining interest, got %d" % clock.accrued_interest
	if clock.accrued_burn != 600:
		return "burn should remain 600, got %d" % clock.accrued_burn
	if clock.principal_debt != 1000:
		return "principal should remain 1000, got %d" % clock.principal_debt

	# 2. Pay 110 CR: pays remaining 10 interest, then 100 burn
	var paid2 := clock.service_debt(110)
	if paid2 != 110:
		return "expected 110 paid, got %d" % paid2
	if clock.accrued_interest != 0:
		return "expected 0 remaining interest, got %d" % clock.accrued_interest
	if clock.accrued_burn != 500:
		return "expected 500 remaining burn, got %d" % clock.accrued_burn
	if clock.principal_debt != 1000:
		return "principal should remain 1000, got %d" % clock.principal_debt

	# 3. Pay 700 CR: pays remaining 500 burn, then 200 principal
	var paid3 := clock.service_debt(700)
	if paid3 != 700:
		return "expected 700 paid, got %d" % paid3
	if clock.accrued_interest != 0:
		return "interest should be 0, got %d" % clock.accrued_interest
	if clock.accrued_burn != 0:
		return "burn should be 0, got %d" % clock.accrued_burn
	if clock.principal_debt != 800:
		return "expected 800 remaining principal, got %d" % clock.principal_debt

	if clock.get_total_debt() != 800:
		return "expected total debt 800, got %d" % clock.get_total_debt()
	if clock.total_debt_serviced != 830:
		return "expected 830 total debt serviced (20+110+700), got %d" % clock.total_debt_serviced

	return "ok"

func test_sim_clock_atomic_interrupt_on_doomsday_transition() -> String:
	# SimClock fixed-step execution integrated with DoomsdayClock ticks
	var sim := SimClock.new(1.0 / 60.0, 1)
	var doomsday := DoomsdayClock.new(600, 1000, 10, 0, 60)

	# Register doomsday auto-pause predicate with sim clock
	sim.register_interrupt_hook(Callable(doomsday, "should_auto_pause"))

	# Step 1.0s real time: advances 60 sub-ticks
	var ticks := 0
	for i in range(60):
		# Advance doomsday clock 1 tick per sim sub-tick
		doomsday.step_ticks(1)
		ticks += sim.step(1.0 / 60.0)

	if sim.paused:
		return "sim should not pause during normal progression"
	if ticks != 60:
		return "expected 60 ticks in first second, got %d" % ticks

	# Force doomsday into UNSTABLE transition (rem <= 450 ticks, current is 540)
	# Advance 91 ticks -> rem = 449 ticks (<= 75% of 600) -> triggers stage transition
	doomsday.step_ticks(91)
	if not doomsday.stage_transition_pending_interrupt:
		return "expected pending interrupt on doomsday clock"

	# Next sim step should evaluate the hook, auto-pause, and zero accumulator
	sim.step(1.0 / 60.0)
	if not sim.paused:
		return "expected sim_clock to auto-pause when doomsday stage changes"
	if sim.auto_paused_reason != "interrupt":
		return "expected auto_paused_reason == 'interrupt', got %s" % sim.auto_paused_reason
	if sim.accumulator != 0.0:
		return "expected accumulator zeroed on interrupt, got %f" % sim.accumulator

	return "ok"

func test_non_positive_and_boundary_ticks() -> String:
	var clock := DoomsdayClock.new(1000, 1000, 10, 0, 60)
	clock.step_ticks(-10)
	clock.step_ticks(0)

	if clock.ticks_remaining != 1000:
		return "non-positive ticks should not advance time"
	if clock.accrued_burn != 0:
		return "non-positive ticks should not accrue burn"
	return "ok"

func test_serialization_roundtrip_and_stage_recomputation() -> String:
	var clock := DoomsdayClock.new(36000, 75000, 50, 300, 60)
	clock.step_ticks(12000) # Advanced to 24000 ticks remaining (UNSTABLE: <= 27000)
	clock.service_debt(500)
	clock.apply_tribute(200, 3)

	var d := clock.to_dict()

	# Non-blocking point 3: Corrupt the saved stage to Stage.NORMAL while ticks_remaining is at 5%
	d["ticks_remaining"] = 1800  # 1800 / 36000 = 5% (should be IMMINENT)
	d["stage"] = int(DoomsdayClock.Stage.NORMAL) # False stage in dict

	var restored := DoomsdayClock.from_dict(d)

	# Verify from_dict recomputes stage strictly from ticks_remaining
	if restored.stage != DoomsdayClock.Stage.IMMINENT:
		return "from_dict should recompute stage to IMMINENT at 5%% time left, got %d" % restored.stage

	# Test standard roundtrip
	var d2 := clock.to_dict()
	var restored2 := DoomsdayClock.from_dict(d2)

	if restored2.total_ticks != clock.total_ticks:
		return "total_ticks mismatch"
	if restored2.ticks_remaining != clock.ticks_remaining:
		return "ticks_remaining mismatch"
	if restored2.ticks_per_second != clock.ticks_per_second:
		return "ticks_per_second mismatch"
	if restored2.stage != clock.stage:
		return "stage mismatch"
	if restored2.principal_debt != clock.principal_debt:
		return "principal_debt mismatch"
	if restored2.accrued_burn != clock.accrued_burn:
		return "accrued_burn mismatch"
	if restored2.accrued_interest != clock.accrued_interest:
		return "accrued_interest mismatch"
	if restored2.total_burn_accrued != clock.total_burn_accrued:
		return "total_burn_accrued mismatch"
	if restored2.total_interest_accrued != clock.total_interest_accrued:
		return "total_interest_accrued mismatch"
	if restored2.total_debt_serviced != clock.total_debt_serviced:
		return "total_debt_serviced mismatch"
	if restored2.total_ticks_added_by_tributes != clock.total_ticks_added_by_tributes:
		return "total_ticks_added_by_tributes mismatch"
	if restored2.base_burn_per_second != clock.base_burn_per_second:
		return "base_burn_per_second mismatch"
	if restored2.interest_rate_bps_per_minute != clock.interest_rate_bps_per_minute:
		return "interest_rate_bps_per_minute mismatch"

	return "ok"
