extends RefCounted
## Tests for the first-hour tutorial wired into Main (#36 First-Hour Onboarding Flow, task 2):
## the signal translation, the reading hold and its exits, and the proof that the hold and the
## listeners cannot move the run (hash equality on vs off at equal sim ticks, through the real
## Main wiring).

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FRAME: float = 1.0 / 60.0 + 0.0001
const TICKS_PER_ROUND: int = 4


func _btn(index: int) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = index
	e.pressed = true
	return e


func _action(name: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	return e


## A Main with a short-round run, not in the tree (like test_travel). `on` builds the tutorial.
func _main(on: bool, p_seed: int = 11, with_nodes: bool = false) -> MainScene:
	var m: MainScene = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	var rc := RunController.new(null, p_seed, null, {}, TICKS_PER_ROUND)
	m.bags = Bags.new("m0", null, p_seed)
	m.initialize_systems(rc)
	if with_nodes:
		m._resolve_child_nodes()
		m._build_readouts()
	rc.sim_clock.set_paused(false)
	if on:
		m.enable_onboarding()
	return m


func _ticks(m: MainScene) -> int:
	return m.controller.sim_clock.total_ticks


func _hash(m: MainScene) -> String:
	return RunSave.state_hash(m.controller, m.loop.market, m.bags)


func _canon(m: MainScene) -> String:
	return RunSave.canonical(RunSave.capture(m.controller, m.loop.market, m.bags))


# ---- wiring ---------------------------------------------------------------------------

func test_headless_main_has_no_tutorial() -> String:
	var m: MainScene = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	m.start_new_run(5)
	var ok: bool = m.onboarding == null and not m.is_onboarding_held()
	m._process(FRAME)
	ok = ok and _ticks(m) > 0
	m.free()
	return "ok" if ok else "a Main without persistence must not build or hold on a tutorial"


func test_persistence_builds_the_tutorial_and_loads_its_state() -> String:
	var dir := "user://test_tmp/onbw_%d" % Time.get_ticks_usec()
	var seeded := AccessibilitySettings.new()
	seeded.set_tutorial_enabled(false)
	seeded.mark_tutorial_seen("tabs")
	var store := SaveStore.new(dir)
	seeded.save(store)
	var m: MainScene = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	m.start_new_run(5)
	m.enable_persistence(store)
	var built: bool = m.onboarding != null and m.onboarding.settings == m.settings
	var loaded: bool = not m.settings.tutorial_enabled and m.settings.tutorial_seen == ["tabs"]
	m.free()
	SteamService.set_shared(null)
	load("res://tests/test_save_load.gd")._rm_rf(store.dir)
	DirAccess.remove_absolute("user://test_tmp")
	if not built:
		return "enable_persistence did not build the tutorial on Main's settings"
	if not loaded:
		return "the saved tutorial_enabled / tutorial_seen were not loaded into Main's settings"
	return "ok"


func test_events_are_translated_from_the_signals_that_already_fire() -> String:
	var m := _main(true)
	var ob: Onboarding = m.onboarding
	if ob.active_id() != "tabs":
		return "a fresh player starts on the tabs beat, got '%s'" % ob.active_id()
	m.handle_input(_btn(JOY_BUTTON_RIGHT_SHOULDER))  # RB: Market tab
	if not ob.is_seen("tabs") or m.loop.tab_name() != "MARKET":
		return "tab_changed MARKET did not complete the tabs beat"
	if ob.active_id() != "order":
		return "market tab should make the order beat active, got '%s'" % ob.active_id()
	m._onb_update()
	m.handle_input(_btn(JOY_BUTTON_A))  # dismiss the hold
	m.handle_input(_btn(JOY_BUTTON_A))  # the order
	if m.loop.total_fills < 1 or not ob.is_seen("order"):
		return "order_executed did not reach the tutorial (fills %d)" % m.loop.total_fills
	if int(ob.context()["fills"]) != m.loop.total_fills:
		return "context fills drifted from the loop's count"
	# round_advanced from the controller: the debt beat latches after the order beat.
	for i in TICKS_PER_ROUND + 2:
		m._process(FRAME)
	if ob.active_id() != "debt":
		return "round_advanced did not make the debt beat active, got '%s'" % ob.active_id()
	m.free()
	return "ok"


func test_departure_arrival_and_the_sell_beat() -> String:
	var m := _main(true, 11, true)
	var ob: Onboarding = m.onboarding
	var rc: RunController = m.controller
	rc.cargo = {"ORE": 40}
	m.loop.total_fills = 1  # the player has already traded; only the cargo and route matter here
	ob.settings.mark_tutorial_seen("tabs")
	ob.settings.mark_tutorial_seen("order")
	ob.settings.mark_tutorial_seen("debt")
	m.hud.set_station("ceres")
	m._onb_update()
	if ob.active_id() != "leave":
		return "cargo + route card + Map tab should show the leave beat, got '%s'" % ob.active_id()
	m._onb_hold = ""
	rc.depart("ceres")
	if ob.context()["in_transit"] != true or not ob.is_seen("leave"):
		return "transit_departed did not reach the tutorial"
	for i in 12 * TICKS_PER_ROUND:
		m._process(FRAME)
		if not rc.is_in_transit():
			break
	if rc.is_in_transit() or ob.active_id() != "sell":
		return "transit_arrived did not make the sell beat active (active '%s')" % ob.active_id()
	m.free()
	return "ok"


func test_conditional_beats_from_headlines_phases_filing_and_run_end() -> String:
	var m := _main(true)
	var ob: Onboarding = m.onboarding
	ob.set_enabled(false)  # conditional beats ignore it; core beats stop
	for k in ["HL_RIVAL_RAID_PAID", "HL_FILL"]:
		m.hud.headline_emitted.emit({"key": k})
	if ob.active_id() != "":
		return "an unrelated headline must not fire a beat, got '%s'" % ob.active_id()
	m.hud.post_headline_tr("HL_CORRIDOR_DELAY", [{}, {}, 1], "HAZARD", "WARNING")
	if ob.active_id() != "raid":
		return "a corridor hazard headline should fire the raid beat, got '%s'" % ob.active_id()
	m.controller.run_collapsed.emit()  # run_ended: tutorial already off, nothing else changes
	m.loop._set_phase(M0Loop.PHASE_PERKS)
	m.loop._set_phase(M0Loop.PHASE_SUMMARY)
	if not ob.is_seen("perks") and ob.active_id() != "raid":
		return "perk screen open/close should be translated"
	m.free()
	var m2 := _main(true)
	m2.controller.bankruptcy_filed.emit({})
	var filed: bool = m2.onboarding.active_id() == "tabs"  # lowest numbered wins, chapter11 queues
	m2.onboarding.settings.set_tutorial_enabled(false)
	m2.onboarding._refresh()
	filed = filed and m2.onboarding.active_id() == "chapter11"
	m2.free()
	return "ok" if filed else "bankruptcy_filed should queue the chapter11 beat behind the lower-numbered one"


func test_a_new_run_rewires_the_controller_signals() -> String:
	var m := _main(true)
	var old: RunController = m.controller
	m.onboarding.settings.mark_tutorial_seen("tabs")
	m.onboarding.settings.mark_tutorial_seen("order")
	var rc2 := RunController.new(null, 12, null, {}, TICKS_PER_ROUND)
	m.initialize_systems(rc2)
	if old.round_advanced.is_connected(m._onb_on_round_advanced):
		return "the old controller is still connected"
	if not rc2.round_advanced.is_connected(m._onb_on_round_advanced):
		return "the new controller is not connected"
	m.free()
	return "ok"


func test_active_beat_is_recomputed_on_load_without_a_hold() -> String:
	var m := _main(false)
	m.handle_input(_btn(JOY_BUTTON_RIGHT_SHOULDER))  # a loaded game sitting on the Market tab
	m.enable_onboarding()
	m._onb_resume()
	if m.onboarding.active_id() != "order":
		return "the load should resume the order beat, got '%s'" % m.onboarding.active_id()
	m._process(FRAME)
	if m.is_onboarding_held() or _ticks(m) == 0:
		return "a load must not raise a hold; the row is on the card and the clock runs"
	m.free()
	return "ok"


func test_the_row_is_hidden_while_a_modal_owns_the_screen_and_the_hold_waits() -> String:
	var m := _main(true)
	m.onboarding.settings.mark_tutorial_seen("tabs")  # make the order beat the one in question
	m.handle_input(_btn(JOY_BUTTON_RIGHT_SHOULDER))
	m.loop._set_overlay(M0Loop.OVERLAY_CRISIS)
	m._onb_update()
	if m.is_onboarding_held() or not m._onb_notes().is_empty():
		return "no hold and no row while a modal owns the screen"
	m.loop._set_overlay(M0Loop.OVERLAY_NONE)
	if not m.is_onboarding_held():
		return "the hold should be raised when the modal closes"
	m.free()
	return "ok"


# ---- the hold ---------------------------------------------------------------------------

func test_hold_neutrality() -> String:
	var m := _main(true)
	m._process(FRAME)
	if not m.is_onboarding_held():
		return "the tabs beat should hold on its first frame"
	var clock: SimClock = m.controller.sim_clock
	var t0: int = _ticks(m)
	var h0: String = _hash(m)
	var c0: String = JSON.stringify(clock.to_dict())
	var handled := [0]
	m.loop.action_handled.connect(func(_a): handled[0] += 1)
	for i in 120:
		m._process(FRAME)
	if _ticks(m) != t0 or _hash(m) != h0 or JSON.stringify(clock.to_dict()) != c0:
		return "a held game moved: ticks %d -> %d" % [t0, _ticks(m)]
	if clock.paused or clock.auto_paused_reason != "":
		return "the hold wrote the clock (paused=%s reason=%s)" % [str(clock.paused), clock.auto_paused_reason]
	# The confirm press is consumed by Main and reaches no m0_* handler: no departure either.
	m.hud.set_station("ceres")
	var cr0: int = m.controller.cr
	if not m.handle_input(_btn(JOY_BUTTON_A)):
		return "Main should consume the confirm press"
	if handled[0] != 0 or m.controller.is_in_transit() or m.controller.cr != cr0 or m.loop.total_fills != 0:
		return "the dismissal leaked into M0Loop (actions %d)" % handled[0]
	if m.is_onboarding_held():
		return "the dismissal did not end the hold"
	m._process(FRAME)
	if _ticks(m) <= t0:
		return "the sim should run again after the dismissal"
	# And the hold is raised once: the same beat never holds again.
	for i in 20:
		m._process(FRAME)
	if m.is_onboarding_held():
		return "a beat's hold must be raised once"
	m.free()
	return "ok"


func test_hold_exits_start_a_modal_and_view() -> String:
	# Start: ends the hold and still reaches the loop, which pauses through its own path.
	var m := _main(true)
	m._process(FRAME)
	m.handle_input(_action(M0Loop.ACT_PAUSE))
	m._process(FRAME)
	if m.is_onboarding_held() or not m.controller.sim_clock.paused:
		return "Start should end the hold and pause the clock as it always does"
	m.free()
	# A modal: ends the hold.
	var m2 := _main(true)
	m2._process(FRAME)
	m2.loop._set_overlay(M0Loop.OVERLAY_CRISIS)
	m2._process(FRAME)
	if m2.is_onboarding_held():
		return "a modal should end the hold"
	m2.free()
	# View: settings freezes the sim on its own; the hold survives and resumes after.
	var m3 := _main(true)
	m3._process(FRAME)
	var t0: int = _ticks(m3)
	m3.handle_input(_action(InputRemap.ACT_SETTINGS))
	for i in 10:
		m3._process(FRAME)
	if not m3.settings_menu.is_open or not m3.is_onboarding_held() or _ticks(m3) != t0:
		return "View should open settings with the hold still up and the sim still"
	m3.settings_menu.close()
	m3._process(FRAME)
	if not m3.is_onboarding_held() or _ticks(m3) != t0:
		return "returning from settings should return to the hold"
	m3.handle_input(_btn(JOY_BUTTON_A))
	m3._process(FRAME)
	if _ticks(m3) <= t0:
		return "the sim should run after the hold is dismissed"
	m3.free()
	return "ok"


func test_no_hold_when_the_clock_is_already_paused() -> String:
	var m := _main(false)
	m.controller.sim_clock.set_paused(true)
	m.enable_onboarding()
	m._process(FRAME)
	if m.is_onboarding_held():
		return "a beat that shows while the clock is paused holds nothing"
	m.controller.sim_clock.set_paused(false)
	m._process(FRAME)
	if m.is_onboarding_held():
		return "the skipped hold must not be raised later"
	m.free()
	return "ok"


func test_a_non_holding_beat_never_holds() -> String:
	var m := _main(true)
	m.onboarding.set_enabled(false)
	m.hud.post_headline_tr("HL_CORRIDOR_HELD", [], "HAZARD", "WARNING")
	m._process(FRAME)
	if m.onboarding.active_id() != "raid" or m.is_onboarding_held():
		return "raid is a conditional beat with holds=false"
	m.free()
	return "ok"


# ---- the surface (debug-grade) -----------------------------------------------------------

func test_held_state_shows_on_the_speed_chip_and_the_card() -> String:
	var m: MainScene = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	m.start_new_run(11)
	m._resolve_child_nodes()
	m._build_readouts()
	m.controller.sim_clock.set_paused(false)
	m.enable_onboarding()
	m._process(FRAME)
	m._refresh_readouts()
	var chips: Array = m._hdr["chips"]
	var speed: String = (chips[3]["value"] as Label).text
	var notes: Array = m._onb_notes()
	var held_chip: String = str(notes[0]["text"]) if not notes.is_empty() else ""
	var ok: bool = m.is_onboarding_held() and speed == Loc.t("ONB_HELD") and held_chip == "ORIENTATION 1/5 · HELD" and str(notes[1]["text"]) == "A: CONTINUE"
	m.handle_input(_btn(JOY_BUTTON_A))
	m._refresh_readouts()
	var after: String = (chips[3]["value"] as Label).text
	var chip_after: String = str(m._onb_notes()[0]["text"])
	m.free()
	if not ok:
		return "held state not shown: speed '%s' chip '%s'" % [speed, held_chip]
	if after != "1x" or chip_after != "ORIENTATION 1/5":
		return "after the dismissal the chip should read ORIENTATION 1/5 and SPEED 1x, got '%s' / '%s'" % [chip_after, after]
	return "ok"


# ---- determinism ---------------------------------------------------------------------------

## The scripted game: Map -> Market, one order, then rounds of waiting. With `on`, the script
## also sends the hold dismissals (the confirm presses) the tutorial asks for; a held frame
## advances zero ticks, so the two runs are compared after the same number of sim ticks.
func _play(on: bool, target_ticks: int, counters: Dictionary) -> MainScene:
	var m := _main(on)
	m.controller.cr = 20000
	m.controller.round_advanced.connect(func(_r): counters["rounds"] += 1)
	m.hud.gamepad_focus.order_executed.connect(func(_p): counters["fills"] += 1)
	var presses := [0]
	var frames := [0]
	var step := func():
		frames[0] += 1
		if frames[0] > 3000:
			counters["stuck"] = "ticks %d overlay '%s' held %s tab %s" % [_ticks(m), m.loop.overlay_state, str(m.is_onboarding_held()), m.loop.tab_name()]
			return
		if m.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			m.loop.acknowledge_crisis()  # the same in both runs
		m._process(FRAME)
		if on and m.is_onboarding_held():
			presses[0] += 1
			if not m.handle_input(_btn(JOY_BUTTON_A)):
				counters["leaks"] += 1
	while _ticks(m) < 20 and not counters.has("stuck"):
		step.call()
	m.handle_input(_btn(JOY_BUTTON_RIGHT_SHOULDER))  # Market
	step.call()  # the order beat's hold, dismissed when on
	m.handle_input(_btn(JOY_BUTTON_A))  # the order itself
	while _ticks(m) < target_ticks and not counters.has("stuck"):
		step.call()
	counters["presses"] = presses[0]
	return m


func test_tutorial_on_and_off_give_identical_run_hash_through_main() -> String:
	var target: int = 6 * TICKS_PER_ROUND + 3
	var c_off := {"rounds": 0, "fills": 0, "leaks": 0}
	var c_on := {"rounds": 0, "fills": 0, "leaks": 0}
	var off := _play(false, target, c_off)
	var on := _play(true, target, c_on)
	var why := ""
	if c_on.has("stuck") or c_off.has("stuck"):
		why = "script stuck: on %s / off %s" % [str(c_on.get("stuck", "")), str(c_off.get("stuck", ""))]
	elif int(c_on["presses"]) < 3:
		why = "the tutorial-on script should include several hold dismissals, got %d" % int(c_on["presses"])
	elif on.loop.total_fills < 1 or off.loop.total_fills != on.loop.total_fills:
		why = "both runs must place the order (off %d, on %d)" % [off.loop.total_fills, on.loop.total_fills]
	elif _ticks(on) != _ticks(off):
		why = "tick counts differ: %d vs %d" % [_ticks(on), _ticks(off)]
	elif int(c_on["leaks"]) != 0:
		why = "a dismissal was not consumed by Main"
	elif _hash(on) != _hash(off):
		why = "state_hash differs with the tutorial on"
	elif _canon(on) != _canon(off):
		why = "RunSave.capture differs with the tutorial on"
	elif c_on["rounds"] != c_off["rounds"] or c_on["fills"] != c_off["fills"] or int(c_on["rounds"]) < 3:
		why = "signal emission counts differ: %s vs %s" % [str(c_on), str(c_off)]
	elif JSON.stringify(on.controller.sim_clock.to_dict()) != JSON.stringify(off.controller.sim_clock.to_dict()):
		why = "the clock state differs"
	off.free()
	on.free()
	return why if why != "" else "ok"


func test_a_swallowed_confirm_is_what_keeps_the_hash_equal() -> String:
	# Negative control: if the dismissal reached M0Loop on the Map tab it would depart and the
	# hash would differ. Send the press straight to the loop and watch the run diverge.
	var a := _main(false)
	var b := _main(false)
	a.hud.set_station("ceres")
	b.hud.set_station("ceres")
	var went: bool = a.loop.handle_input(_btn(JOY_BUTTON_A)) and a.controller.is_in_transit()
	for i in 10:
		a._process(FRAME)
		b._process(FRAME)
	var diverged: bool = went and not b.controller.is_in_transit() and _hash(a) != _hash(b)
	var reason: String = a.loop.last_depart_reason
	a.free()
	b.free()
	return "ok" if diverged else "the control press should have departed and moved the hash (went %s: %s)" % [str(went), reason]


func test_policy_signals_are_translated() -> String:
	var m := _main(true)
	var rc: RunController = m.controller
	rc.attach_policies()
	var ob: Onboarding = m.onboarding
	ob.settings.set_tutorial_enabled(false)
	rc.policy_pending.emit(1)
	if ob.active_id() != "policy":
		return "policy_pending should activate the policy beat, got '%s'" % ob.active_id()
	rc.policy_adopted.emit("training_module")
	var ok: bool = ob.is_seen("policy") and ob.active_id() == "" and not m.is_onboarding_held()
	m.free()
	return "ok" if ok else "policy_adopted should complete the beat with no hold"
