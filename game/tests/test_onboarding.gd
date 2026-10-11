extends RefCounted
## Tests for the first-hour tutorial model (#36 First-Hour Onboarding Flow, task 1): the beat
## table and its validator, the transitions, the settings persistence, and the proof that a
## tutorial listening to a live session cannot move the run hash.

const TMP_ROOT := "user://test_tmp"
static var _counter: int = 0


func _store() -> SaveStore:
	_counter += 1
	return SaveStore.new("%s/onb_%d_%d" % [TMP_ROOT, Time.get_ticks_usec(), _counter])


func _cleanup(store: SaveStore) -> void:
	load("res://tests/test_save_load.gd")._rm_rf(store.dir)
	DirAccess.remove_absolute(TMP_ROOT)


func _ob() -> Onboarding:
	return Onboarding.new(AccessibilitySettings.new())


func _ev(type: String, extra: Dictionary = {}) -> Dictionary:
	var e: Dictionary = {"type": type}
	e.merge(extra)
	return e


func _valid_table() -> Dictionary:
	return {"version": 1, "beats": [{
		"id": "a", "kind": "core", "holds": true, "title_key": "ONB_A_T", "line_keys": ["ONB_A_1"],
		"fires": {"context": {"tab": "MAP"}}, "done": {"on": ["tab_changed"]}}]}


# ---- data ----

func test_shipped_table_loads_and_validates() -> String:
	var r: Dictionary = Onboarding.load_data()
	if not bool(r["ok"]):
		return "shipped table invalid: %s" % r["error"]
	var ids: Array[String] = Onboarding.beat_ids()
	if ids != ["tabs", "order", "debt", "leave", "sell", "raid", "chapter11", "perks"]:
		return "unexpected beat ids: %s" % str(ids)
	for b in r["beats"]:
		var core: bool = b["kind"] == "core"
		if bool(b["holds"]) != core:
			return "holds should be true exactly for core beats: %s" % b["id"]
	return "ok"


func test_validator_accepts_a_minimal_table() -> String:
	var errs: Array[String] = Onboarding.validate(_valid_table())
	return "ok" if errs.is_empty() else str(errs)


func test_validator_rejects_hostile_tables() -> String:
	var bad: Array = []
	bad.append("string")
	bad.append(null)
	bad.append({})
	bad.append({"version": 2, "beats": _valid_table()["beats"]})
	bad.append({"version": 1, "beats": "nope"})
	bad.append({"version": 1, "beats": []})
	var t := _valid_table()
	t["beats"][0]["id"] = "Bad Id"
	bad.append(t)
	t = _valid_table()
	t["beats"][0]["holds"] = "yes"
	bad.append(t)
	t = _valid_table()
	t["beats"][0]["kind"] = "optional"
	bad.append(t)
	t = _valid_table()
	t["beats"][0]["line_keys"] = ["ONB_1", "ONB_2", "ONB_3", "ONB_4"]
	bad.append(t)
	t = _valid_table()
	t["beats"][0]["title_key"] = "plain text"
	bad.append(t)
	t = _valid_table()
	t["beats"][0]["done"]["on"] = ["not_an_event"]
	bad.append(t)
	t = _valid_table()
	t["beats"][0]["done"]["count"] = 0
	bad.append(t)
	t = _valid_table()
	t["beats"][0]["fires"] = {"requires": ["later"]}
	bad.append(t)
	t = _valid_table()
	t["beats"][0]["fires"]["context"] = {"tab": 5}
	bad.append(t)
	t = _valid_table()
	t["beats"][0]["fires"]["context"] = {"mood": "sad"}
	bad.append(t)
	t = _valid_table()
	t["beats"][0]["surprise"] = 1
	bad.append(t)
	t = _valid_table()
	t["beats"].append(t["beats"][0].duplicate(true))
	bad.append(t)
	for i in bad.size():
		if Onboarding.validate(bad[i]).is_empty():
			return "hostile table %d was accepted: %s" % [i, str(bad[i])]
	return "ok"


func test_an_invalid_table_leaves_the_model_inert() -> String:
	var ob := Onboarding.new(AccessibilitySettings.new(), {"ok": false, "error": "broken", "beats": []})
	ob.handle(_ev("tab_changed", {"tab": "MARKET"}))
	if ob.load_error != "broken" or ob.active_id() != "" or not ob.beats.is_empty():
		return "invalid table should give an inert model"
	return "ok"


# ---- settings persistence ----

func test_tutorial_keys_default_and_round_trip() -> String:
	var plain := AccessibilitySettings.from_dict({})
	if not plain.tutorial_enabled or not plain.tutorial_seen.is_empty():
		return "defaults wrong: %s" % str(plain.to_dict())
	var store := _store()
	var s := AccessibilitySettings.new()
	s.set_tutorial_enabled(false)
	s.mark_tutorial_seen("order")
	s.mark_tutorial_seen("tabs")
	s.mark_tutorial_seen("tabs")
	s.save(store)
	var back := AccessibilitySettings.load_from(store)
	var err := ""
	if back.tutorial_enabled or back.tutorial_seen != ["order", "tabs"]:
		err = "round trip lost state: %s" % str(back.to_dict())
	elif AccessibilitySettings.from_dict(plain.to_dict()).to_dict() != plain.to_dict():
		err = "defaults do not round trip"
	_cleanup(store)
	return "ok" if err == "" else err


func test_hostile_settings_fall_back_to_defaults() -> String:
	var cases: Array = [
		{"tutorial_enabled": "false", "tutorial_seen": 7},
		{"tutorial_enabled": 0, "tutorial_seen": "tabs"},
		{"tutorial_enabled": null, "tutorial_seen": {"tabs": true}},
		{"tutorial_enabled": [true], "tutorial_seen": [1, null, {}, ["tabs"], "nope", "../etc"]},
	]
	for c in cases:
		var store := _store()
		store.save_settings(c)
		var s := AccessibilitySettings.load_from(store)
		_cleanup(store)
		if not s.tutorial_enabled or not s.tutorial_seen.is_empty():
			return "hostile %s gave %s" % [str(c), str(s.to_dict())]
	var mixed := AccessibilitySettings.from_dict({"tutorial_enabled": false, "tutorial_seen": ["sell", "tabs", "tabs", 3, "bogus", "order"]})
	if mixed.tutorial_enabled or mixed.tutorial_seen != ["order", "sell", "tabs"]:
		return "mixed list not cleaned: %s" % str(mixed.to_dict())
	var s2 := AccessibilitySettings.new()
	if s2.mark_tutorial_seen("bogus") or not s2.tutorial_seen.is_empty():
		return "unknown beat id accepted"
	return "ok"


func test_reset_defaults_leaves_the_tutorial_alone() -> String:
	var s := AccessibilitySettings.new()
	s.set_tutorial_enabled(false)
	s.mark_tutorial_seen("tabs")
	s.reset_defaults()
	Palette.set_current(Palette.DEFAULT)
	return "ok" if (not s.tutorial_enabled and s.tutorial_seen == ["tabs"]) else "reset touched the tutorial"


# ---- transitions ----

func test_fresh_player_starts_on_the_tabs_beat() -> String:
	var ob := _ob()
	if ob.active_id() != "tabs":
		return "expected tabs, got '%s'" % ob.active_id()
	var b: Dictionary = ob.active_beat()
	if int(b["index"]) != 0 or int(b["total"]) != 8 or not ob.holds_now():
		return "active_beat wrong: %s" % str(b)
	return "ok"


func test_core_loop_walks_beats_one_to_five() -> String:
	var ob := _ob()
	if ob.handle(_ev("tab_changed", {"tab": "MARKET"})) != "order" or not ob.is_seen("tabs"):
		return "tab to MARKET should finish tabs and show order"
	if ob.handle(_ev("order_executed", {"side": "BUY", "station": "Mars"})) != "" or not ob.is_seen("order"):
		return "first fill should finish order"
	if ob.handle(_ev("round_advanced")) != "debt":
		return "round after the first fill should show debt"
	if ob.handle(_ev("round_advanced")) != "debt":
		return "debt needs two more rounds"
	if ob.handle(_ev("round_advanced")) != "" or not ob.is_seen("debt"):
		return "debt should finish after two more rounds"
	ob.handle(_ev("tab_changed", {"tab": "MAP"}))
	if ob.set_context({"hold_empty": false, "route_card": true}) != "leave":
		return "hold plus route card on MAP should show leave"
	if ob.handle(_ev("transit_departed")) != "" or not ob.is_seen("leave"):
		return "departing should finish leave"
	if ob.handle(_ev("transit_arrived")) != "sell":
		return "arrival should show sell"
	if ob.handle(_ev("order_executed", {"side": "SELL", "station": "Mars"})) != "sell":
		return "selling back at the buy station must not finish sell"
	if ob.handle(_ev("order_executed", {"side": "SELL", "station": "Ceres"})) != "":
		return "selling elsewhere should finish sell"
	if ob.is_enabled():
		return "finishing sell should switch the core tutorial off"
	return "ok"


func test_doing_it_first_marks_the_beat_done_silently() -> String:
	var ob := _ob()
	ob.handle(_ev("order_executed", {"side": "BUY", "station": "Mars"}))
	if not ob.is_seen("order"):
		return "a fill before the beat showed should mark it done"
	ob.handle(_ev("tab_changed", {"tab": "MARKET"}))
	if ob.active_id() != "":
		return "order is done, nothing should show on MARKET, got '%s'" % ob.active_id()
	return "ok"


func test_lower_numbered_beat_wins_and_nothing_is_preempted() -> String:
	var ob := _ob()
	ob.handle(_ev("tab_changed", {"tab": "MARKET"}))
	ob.handle(_ev("order_executed", {"side": "BUY", "station": "Mars"}))
	ob.handle(_ev("corridor_raid"))
	if ob.active_id() != "raid":
		return "raid should show once nothing else is active, got '%s'" % ob.active_id()
	ob.handle(_ev("round_advanced"))
	if ob.active_id() != "raid":
		return "an active beat must not be preempted by a later one"
	# Raid needs two rounds; the first counted above, the debt latch came from the same round.
	ob.handle(_ev("round_advanced"))
	if ob.active_id() != "debt":
		return "queued debt should show after raid, got '%s'" % ob.active_id()
	return "ok"


func test_conditional_beats_ignore_enabled_and_core_beats_obey_it() -> String:
	var ob := _ob()
	ob.set_enabled(false)
	if ob.active_id() != "":
		return "disabled tutorial should show no core beat"
	ob.handle(_ev("tab_changed", {"tab": "MARKET"}))
	if ob.active_id() != "":
		return "core beat showed while disabled"
	if ob.handle(_ev("bankruptcy_filed")) != "chapter11":
		return "conditional beat should still show while disabled"
	ob.handle(_ev("round_advanced"))
	ob.handle(_ev("round_advanced"))
	if ob.active_id() != "" or not ob.is_seen("chapter11"):
		return "chapter11 should finish after two rounds"
	ob.handle(_ev("perk_screen_opened"))
	if ob.active_id() != "perks":
		return "perks should show on first perk screen"
	ob.handle(_ev("perk_screen_closed"))
	if not ob.is_seen("perks") or ob.holds_now():
		return "perks should finish on leaving the screen"
	return "ok"


func test_turning_it_back_on_replays_core_beats_only() -> String:
	var ob := _ob()
	ob.handle(_ev("tab_changed", {"tab": "MARKET"}))
	ob.handle(_ev("order_executed", {"side": "BUY", "station": "Mars"}))
	ob.handle(_ev("corridor_hazard"))
	ob.handle(_ev("round_advanced"))
	ob.handle(_ev("round_advanced"))
	ob.set_enabled(false)
	ob.set_enabled(true)
	var seen: Array[String] = ob.settings.tutorial_seen
	if seen != ["raid"]:
		return "replay should clear core beats and keep conditional ones, got %s" % str(seen)
	ob.handle(_ev("tab_changed", {"tab": "MAP"}))
	ob.set_context({"fills": 0})
	if ob.active_id() != "tabs":
		return "replay should restart at tabs, got '%s'" % ob.active_id()
	return "ok"


func test_run_end_switches_the_tutorial_off() -> String:
	var ob := _ob()
	ob.handle(_ev("run_ended"))
	if ob.is_enabled() or ob.active_id() != "":
		return "first run end should disable the core tutorial"
	return "ok"


func test_active_beat_is_recomputed_from_live_state_after_a_load() -> String:
	var s := AccessibilitySettings.new()
	s.mark_tutorial_seen("tabs")
	s.mark_tutorial_seen("order")
	var ob := Onboarding.new(AccessibilitySettings.from_dict(s.to_dict()))
	if ob.active_id() != "":
		return "nothing should be active before context arrives"
	ob.set_context({"tab": "MAP", "hold_empty": false, "route_card": true})
	if ob.active_id() != "leave":
		return "leave should be recomputed from the live HUD, got '%s'" % ob.active_id()
	ob.set_context({"route_card": false})
	if ob.active_id() != "":
		return "a context beat should drop when its context goes"
	return "ok"


func test_bad_events_and_context_are_ignored() -> String:
	var ob := _ob()
	var before: String = ob.active_id()
	ob.handle({})
	ob.handle({"type": 5})
	ob.handle({"type": "teleport"})
	ob.set_context({"tab": 9, "fills": "many", "mood": "x", "hold_empty": 1})
	if ob.active_id() != before or ob.context() != _ob().context():
		return "malformed input changed state: %s" % str(ob.context())
	return "ok"


# ---- determinism ----

func _drive(s: Replay.Session) -> void:
	s.advance_frames(30)
	s.dispatch(M0Loop.ACT_TAB_NEXT)
	for i in 3:
		s.dispatch(M0Loop.ACT_RIGHT)
		s.dispatch(M0Loop.ACT_SUBMIT)
		s.advance_frames(400)
	s.dispatch(M0Loop.ACT_SPEED)
	s.advance_frames(500)
	s.dispatch(M0Loop.ACT_DOWN)
	s.dispatch(M0Loop.ACT_SUBMIT)
	s.advance_frames(300)


## Wires a tutorial to the live signals of a session, the way Main will.
func _attach(s: Replay.Session, ob: Onboarding, counts: Dictionary) -> void:
	s.loop.tab_changed.connect(func(tab: String) -> void:
		counts["tab"] = int(counts.get("tab", 0)) + 1
		ob.handle({"type": "tab_changed", "tab": tab}))
	s.hud.gamepad_focus.order_executed.connect(func(p: Dictionary) -> void:
		counts["order"] = int(counts.get("order", 0)) + 1
		ob.handle({"type": "order_executed", "side": p["side"], "station": p["station"]}))
	s.loop.round_completed.connect(func(_n: int) -> void:
		counts["round"] = int(counts.get("round", 0)) + 1
		ob.handle({"type": "round_advanced"}))


func test_tutorial_on_and_off_give_identical_run_hash() -> String:
	var off := Replay.Session.new(36)
	_drive(off)
	var on := Replay.Session.new(36)
	var ob := _ob()
	var counts: Dictionary = {}
	_attach(on, ob, counts)
	_drive(on)
	# The tutorial must have been live, or equality proves nothing.
	if not ob.is_seen("tabs") or int(counts.get("order", 0)) < 1 or int(counts.get("round", 0)) < 1:
		return "tutorial saw nothing: %s seen=%s" % [str(counts), str(ob.settings.tutorial_seen)]
	if on.state_hash() != off.state_hash():
		return "state_hash moved with the tutorial attached"
	var cap_on: String = JSON.stringify(RunSave.capture(on.controller, on.loop.market, on.bags), "", true)
	var cap_off: String = JSON.stringify(RunSave.capture(off.controller, off.loop.market, off.bags), "", true)
	if cap_on != cap_off:
		return "RunSave.capture differs with the tutorial attached"
	if on.controller.sim_clock.total_ticks != off.controller.sim_clock.total_ticks:
		return "sim ticks differ"
	return "ok"


func test_signal_emission_counts_match_with_and_without_the_listener() -> String:
	var plain: Dictionary = {}
	var s1 := Replay.Session.new(36)
	s1.loop.tab_changed.connect(func(_t: String) -> void: plain["tab"] = int(plain.get("tab", 0)) + 1)
	s1.hud.gamepad_focus.order_executed.connect(func(_p: Dictionary) -> void: plain["order"] = int(plain.get("order", 0)) + 1)
	s1.loop.round_completed.connect(func(_n: int) -> void: plain["round"] = int(plain.get("round", 0)) + 1)
	_drive(s1)
	var counts: Dictionary = {}
	var s2 := Replay.Session.new(36)
	_attach(s2, _ob(), counts)
	_drive(s2)
	return "ok" if plain == counts else "emission counts differ: %s vs %s" % [str(plain), str(counts)]
