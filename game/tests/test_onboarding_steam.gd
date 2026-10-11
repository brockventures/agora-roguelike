extends RefCounted
## The Steam side of the first-hour tutorial (#36 First-Hour Onboarding Flow, task 6, design
## section 12 and Question 5): the max-stat `onboarding_step` and the ORIENTATION_COMPLETE
## achievement, driven by Onboarding.beat_completed. Read-only: nothing here touches run state.


func _rig() -> Dictionary:
	var fake := SteamFake.new()
	var svc := SteamService.new()
	svc.initialize(fake)
	var ob := Onboarding.new(AccessibilitySettings.new())
	var hooks := SteamHooks.new(svc)
	hooks.bind_onboarding(ob)
	return {"svc": svc, "ob": ob, "hooks": hooks}


func _ev(type: String, extra: Dictionary = {}) -> Dictionary:
	var e: Dictionary = {"type": type}
	e.merge(extra)
	return e


func test_definitions_are_in_the_data_file() -> String:
	var svc := SteamService.new()
	if not svc.stat_defs.has("onboarding_step"):
		return "onboarding_step missing from achievements.json"
	if not svc.achievement_defs.has("ORIENTATION_COMPLETE"):
		return "ORIENTATION_COMPLETE missing from achievements.json"
	if str(svc.achievement_defs["ORIENTATION_COMPLETE"]["name"]) != "Orientation Complete":
		return "wrong achievement name"
	return "ok"


func test_the_step_follows_the_highest_core_beat_and_the_last_one_unlocks() -> String:
	var r := _rig()
	var svc: SteamService = r["svc"]
	var ob: Onboarding = r["ob"]
	if svc.get_stat("onboarding_step") != 0:
		return "stat should start at 0"
	ob.handle(_ev("tab_changed", {"tab": "MARKET"}))
	if svc.get_stat("onboarding_step") != 1:
		return "tabs done should be step 1, got %d" % svc.get_stat("onboarding_step")
	ob.handle(_ev("order_executed", {"side": "BUY", "station": "luna"}))
	if svc.get_stat("onboarding_step") != 2:
		return "order done should be step 2, got %d" % svc.get_stat("onboarding_step")
	if svc.is_unlocked("ORIENTATION_COMPLETE"):
		return "achievement unlocked before the last core beat"
	ob.settings.mark_tutorial_seen("debt")
	ob.settings.mark_tutorial_seen("leave")
	ob.handle(_ev("transit_arrived"))
	ob.handle(_ev("order_executed", {"side": "SELL", "station": "ceres"}))
	if svc.get_stat("onboarding_step") != 5 or not svc.is_unlocked("ORIENTATION_COMPLETE"):
		return "finishing sell: step %d, unlocked %s" % [svc.get_stat("onboarding_step"), str(svc.is_unlocked("ORIENTATION_COMPLETE"))]
	return "ok"


func test_conditional_beats_do_not_move_the_step() -> String:
	var r := _rig()
	var ob: Onboarding = r["ob"]
	ob.handle(_ev("bankruptcy_filed"))
	ob.handle(_ev("corridor_raid"))
	ob.handle(_ev("round_advanced"))
	ob.handle(_ev("round_advanced"))
	var svc: SteamService = r["svc"]
	if svc.get_stat("onboarding_step") != 0 or svc.is_unlocked("ORIENTATION_COMPLETE"):
		return "a conditional beat reported step %d" % svc.get_stat("onboarding_step")
	return "ok"


func test_a_replay_never_lowers_the_stat() -> String:
	var r := _rig()
	var ob: Onboarding = r["ob"]
	var svc: SteamService = r["svc"]
	ob.handle(_ev("tab_changed", {"tab": "MARKET"}))
	ob.set_enabled(false)
	ob.set_enabled(true)
	ob.handle(_ev("tab_changed", {"tab": "MARKET"}))
	return "ok" if svc.get_stat("onboarding_step") == 1 else "step %d after replay" % svc.get_stat("onboarding_step")


func test_binding_a_saved_tutorial_reports_its_progress() -> String:
	var s := AccessibilitySettings.new()
	for id in ["tabs", "order", "debt", "leave", "sell"]:
		s.mark_tutorial_seen(id)
	var fake := SteamFake.new()
	var svc := SteamService.new()
	svc.initialize(fake)
	var hooks := SteamHooks.new(svc)
	hooks.bind_onboarding(Onboarding.new(s))
	if svc.get_stat("onboarding_step") != 5 or not svc.is_unlocked("ORIENTATION_COMPLETE"):
		return "saved progress not reported: step %d" % svc.get_stat("onboarding_step")
	return "ok"


func test_unbind_stops_reporting() -> String:
	var r := _rig()
	var hooks: SteamHooks = r["hooks"]
	hooks.unbind_onboarding()
	(r["ob"] as Onboarding).handle(_ev("tab_changed", {"tab": "MARKET"}))
	return "ok" if (r["svc"] as SteamService).get_stat("onboarding_step") == 0 else "still reporting after unbind"
