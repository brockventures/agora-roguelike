class_name TestDemoMode
extends RefCounted
## Verifies Steam Next Fest 3-quarter demo run limit and completion handling (#39).

func test_demo_detection_and_rules() -> String:
	DemoMode.set_forced_mode(0)
	if DemoMode.is_demo():
		DemoMode.set_forced_mode(-1)
		return "expected is_demo() to be false when forced 0"
	if DemoMode.get_max_rounds() != DemoMode.FULL_RUN_ROUNDS:
		DemoMode.set_forced_mode(-1)
		return "expected full run rounds %d, got %d" % [DemoMode.FULL_RUN_ROUNDS, DemoMode.get_max_rounds()]
	if DemoMode.is_round_limit_reached(90):
		DemoMode.set_forced_mode(-1)
		return "round limit should not be reached at 90 when demo is disabled"

	DemoMode.set_forced_mode(1)
	if not DemoMode.is_demo():
		DemoMode.set_forced_mode(-1)
		return "expected is_demo() to be true when forced 1"
	if DemoMode.get_max_rounds() != DemoMode.DEMO_MAX_ROUNDS:
		DemoMode.set_forced_mode(-1)
		return "expected demo max rounds %d, got %d" % [DemoMode.DEMO_MAX_ROUNDS, DemoMode.get_max_rounds()]
	if not DemoMode.is_round_limit_reached(90):
		DemoMode.set_forced_mode(-1)
		return "expected round limit reached at round 90"
	if DemoMode.is_round_limit_reached(89):
		DemoMode.set_forced_mode(-1)
		return "round limit should not be reached at round 89"

	DemoMode.set_forced_mode(-1)
	return "ok"


func test_run_controller_demo_completion() -> String:
	DemoMode.set_forced_mode(1)
	var clock := DoomsdayClock.new(360000, 0, 0, 0)
	var rc := RunController.new(null, 42, clock, {}, 10)
	rc.policies = null
	rc.crisis_deck = null
	var completed_emitted: Array = []
	rc.demo_completed.connect(func(): completed_emitted.append(true))

	# Step until round 90 (900 ticks total)
	var target_ticks: int = DemoMode.DEMO_MAX_ROUNDS * rc.ticks_per_round
	var guard: int = 0
	while rc.sim_clock.total_ticks < target_ticks and not rc.is_run_over() and guard < 200:
		guard += 1
		rc.sim_clock.paused = false
		rc.advance(0.25)

	DemoMode.set_forced_mode(-1)

	if completed_emitted.is_empty():
		return "demo_completed signal was not emitted"
	if not rc.is_demo_completed():
		return "expected is_demo_completed() to be true"
	if not rc.is_run_over():
		return "expected is_run_over() to be true"
	if rc.end_reason != "demo_limit":
		return "expected end_reason 'demo_limit', got '%s'" % rc.end_reason
	if rc.rounds_survived_award != 90:
		return "expected 90 rounds survived award, got %d" % rc.rounds_survived_award
	if rc.severance_award <= 0:
		return "expected severance award > 0, got %d" % rc.severance_award

	return "ok"


func test_m0_loop_demo_overlay_flow() -> String:
	DemoMode.set_forced_mode(1)
	var rc := RunController.new()
	var hud := OrbitalHUD.new(rc)
	var loop := M0Loop.new(hud)

	# Trigger demo completion
	rc.end_run("demo_limit")

	if loop.overlay_state != M0Loop.OVERLAY_DEMO_COMPLETE:
		DemoMode.set_forced_mode(-1)
		return "expected loop overlay OVERLAY_DEMO_COMPLETE, got '%s'" % loop.overlay_state

	# Submit / continue advances to summary
	var ok: bool = loop.dispatch_action(M0Loop.ACT_SUBMIT)
	DemoMode.set_forced_mode(-1)

	if not ok:
		return "expected ACT_SUBMIT to handle demo complete overlay"
	if loop.overlay_state != M0Loop.OVERLAY_COLLAPSED:
		return "expected loop overlay OVERLAY_COLLAPSED after acknowledge, got '%s'" % loop.overlay_state
	if loop.collapse_phase != M0Loop.PHASE_SUMMARY:
		return "expected collapse_phase PHASE_SUMMARY, got '%s'" % loop.collapse_phase

	return "ok"
