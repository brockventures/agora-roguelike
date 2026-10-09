extends RefCounted
## Tests for atomic save/load and the persistent meta profile (#35).

const TMP_ROOT := "user://test_tmp"
const FRAME: float = 1.0 / 60.0 + 0.0001
var _counter: int = 0


func _store() -> SaveStore:
	_counter += 1
	var dir := "%s/save_%d_%d" % [TMP_ROOT, Time.get_ticks_usec(), _counter]
	return SaveStore.new(dir)


func _cleanup(store: SaveStore) -> void:
	_rm_rf(store.dir)
	DirAccess.remove_absolute(TMP_ROOT)  # only succeeds once empty


static func _rm_rf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		_rm_rf(path.path_join(sub))
	DirAccess.remove_absolute(path)


## JSON text round trip, as a real save file would do to the data.
static func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


func _busy_run() -> Dictionary:
	var s := Replay.Session.new(11)
	s.dispatch(M0Loop.ACT_TAB_NEXT)
	s.advance_frames(40)
	s.dispatch(M0Loop.ACT_RIGHT)
	s.dispatch(M0Loop.ACT_SUBMIT)
	s.controller.cargo["ORE"] = 12
	s.controller.cr -= 345
	s.advance_frames(1000)
	return {"s": s}


func test_layout_is_fixed_and_documented() -> String:
	var st := SaveStore.new("user://saves")
	if st.profile_path() != "user://saves/profile.json" or st.run_path() != "user://saves/run_slot_0.json":
		return "unexpected layout: %s %s" % [st.profile_path(), st.run_path()]
	if SaveStore.SCHEMA_VERSION < 1:
		return "schema version missing"
	return "ok"


func test_profile_roundtrip_with_perks() -> String:
	var st := _store()
	var p := MetaProfile.new()
	p.add_patent("hull_a")
	p.add_unlock("seed_capital")
	p.add_contract("c1")
	p.severance_points = 7
	p.runs_completed = 2
	p.bankruptcies_filed = 1
	if st.save_profile(p) != OK:
		_cleanup(st)
		return "save_profile failed"
	var q := st.load_profile()
	_cleanup(st)
	if q == null or q.to_dict() != p.to_dict():
		return "profile did not roundtrip: %s" % str(q.to_dict() if q != null else null)
	return "ok"


func test_missing_profile_loads_null() -> String:
	var st := _store()
	if st.load_profile() != null:
		return "no file should give null"
	return "ok"


func test_sim_and_doomsday_clock_roundtrip() -> String:
	var s: Replay.Session = _busy_run()["s"]
	var rc: RunController = s.controller
	var c2 := SimClock.from_dict(_json(rc.sim_clock.to_dict()))
	if RunSave.canonical(c2.to_dict()) != RunSave.canonical(rc.sim_clock.to_dict()):
		return "SimClock differs"
	var d2 := DoomsdayClock.from_dict(_json(rc.doomsday.to_dict()))
	if RunSave.canonical(d2.to_dict()) != RunSave.canonical(rc.doomsday.to_dict()):
		return "DoomsdayClock differs"
	if rc.sim_clock.total_ticks <= 0:
		return "fixture should have advanced the clock"
	return "ok"


func test_station_market_roundtrip_after_trading() -> String:
	var m := StationMarket.new()
	var r: Dictionary = m.execute("mars", "ORE", "BUY", 30, 99999.0)
	if int(r["filled"]) <= 0:
		return "fixture trade did not fill"
	var m2 := StationMarket.from_dict(_json(m.to_dict()))
	if RunSave.canonical(m2.to_dict()) != RunSave.canonical(m.to_dict()):
		return "market differs after roundtrip"
	if m2.books.size() != m.books.size():
		return "book count differs"
	# Behaviour matches, not just the dict: the same sweep gives the same quote.
	var qa: Dictionary = m.sweep_quote("mars", "ORE", "BUY", 50, 99999.0)
	var qb: Dictionary = m2.sweep_quote("mars", "ORE", "BUY", 50, 99999.0)
	if qa != qb:
		return "sweep differs: %s vs %s" % [str(qa), str(qb)]
	return "ok"


func test_bags_mid_streak_survives_save_load() -> String:
	var a := Bags.new("n", null, 77)
	var b_hits: Array = []
	# Mid-bag, plus a varying-p stream with a live credit accumulator.
	for i in 13:
		a.draw("piracy", "f1", 0.1)
		a.draw("hazard", "f1", 0.0123456)
	a.force("piracy", [true, false])
	var b := Bags.new()
	b.from_dict(_json(a.to_dict()))
	if RunSave.canonical(b.to_dict()) != RunSave.canonical(a.to_dict()):
		return "bags dict differs after roundtrip"
	for i in 120:
		var x: bool = a.draw("piracy", "f1", 0.1)
		var y: bool = b.draw("piracy", "f1", 0.1)
		var x2: bool = a.draw("hazard", "f1", 0.0123456)
		var y2: bool = b.draw("hazard", "f1", 0.0123456)
		if x != y or x2 != y2:
			return "draw %d diverged after restore" % i
		b_hits.append(x)
	if a.stats("piracy", "f1") != b.stats("piracy", "f1"):
		return "stats diverged"
	if not b_hits.has(true):
		return "fixture drew no hits"
	return "ok"


func test_bags_streak_bound_holds_across_a_save() -> String:
	# p=0.1 -> bag of 10 with one hit per run: never more than 18 misses in a row,
	# even when a save/load lands in the middle of the streak.
	var a := Bags.new("n", null, 5)
	var run_len: int = 0
	var worst: int = 0
	for i in 400:
		if i % 7 == 0:
			var b := Bags.new()
			b.from_dict(_json(a.to_dict()))
			a = b
		if a.draw("e", "f", 0.1):
			run_len = 0
		else:
			run_len += 1
			worst = maxi(worst, run_len)
	if worst > 18:
		return "streak of %d misses breaks the bad-luck bound" % worst
	return "ok"


func test_full_run_roundtrip_through_file() -> String:
	var st := _store()
	var s: Replay.Session = _busy_run()["s"]
	for i in 20:
		s.bags.draw("piracy", "f1", 0.2)
	var before: String = s.state_hash()
	if st.save_run(s.controller, s.loop.market, s.bags) != OK:
		_cleanup(st)
		return "save_run failed"
	var r: Dictionary = st.load_run()
	_cleanup(st)
	if not bool(r["ok"]):
		return "load_run failed: %s" % str(r["error"])
	var after: String = RunSave.state_hash(r["controller"], r["market"], r["bags"])
	if before != after:
		return "state hash changed across save/load"
	var rc: RunController = r["controller"]
	if rc.cr != s.controller.cr or rc.cargo.get("ORE", 0) != 12 or rc.sim_clock.total_ticks != s.controller.sim_clock.total_ticks:
		return "ledger/cargo/clock mismatch"
	# The restored run keeps ticking identically.
	s.controller.advance(0.5)
	rc.advance(0.5)
	if RunSave.canonical(s.controller.to_dict()) != RunSave.canonical(rc.to_dict()):
		return "restored run diverged when advanced"
	return "ok"


func test_save_leaves_no_temp_file() -> String:
	var st := _store()
	var p := MetaProfile.new()
	if st.save_profile(p) != OK:
		_cleanup(st)
		return "save failed"
	var tmp_exists := FileAccess.file_exists(st.profile_path() + SaveStore.TMP_SUFFIX)
	_cleanup(st)
	return "temp file left behind" if tmp_exists else "ok"


func test_failed_write_keeps_previous_save() -> String:
	var st := _store()
	var p := MetaProfile.new()
	p.severance_points = 5
	if st.save_profile(p) != OK:
		_cleanup(st)
		return "first save failed"
	var original := FileAccess.get_file_as_string(st.profile_path())
	p.severance_points = 99
	st.simulate_write_failure = true
	var err: Error = st.save_profile(p)
	st.simulate_write_failure = false
	var now := FileAccess.get_file_as_string(st.profile_path())
	var tmp_left := FileAccess.file_exists(st.profile_path() + SaveStore.TMP_SUFFIX)
	var loaded := st.load_profile()
	_cleanup(st)
	if err == OK:
		return "failed write reported OK"
	if now != original:
		return "failed write damaged the existing save"
	if tmp_left:
		return "failed write left a temp file"
	if loaded == null or loaded.severance_points != 5:
		return "old save no longer loads"
	return "ok"


func test_failed_run_write_keeps_previous_run() -> String:
	var st := _store()
	var s: Replay.Session = _busy_run()["s"]
	st.save_run(s.controller, s.loop.market, s.bags)
	var original := FileAccess.get_file_as_string(st.run_path())
	s.advance_frames(300)
	st.simulate_write_failure = true
	var err: Error = st.save_run(s.controller, s.loop.market, s.bags)
	var same := FileAccess.get_file_as_string(st.run_path()) == original
	_cleanup(st)
	return "ok" if (err != OK and same) else "run save not atomic (err=%d same=%s)" % [err, str(same)]


func test_schema_version_mismatch_rejected() -> String:
	var st := _store()
	DirAccess.make_dir_recursive_absolute(st.dir)
	var f := FileAccess.open(st.profile_path(), FileAccess.WRITE)
	f.store_string(JSON.stringify({"schema_version": SaveStore.SCHEMA_VERSION + 1, "kind": "profile", "data": {"severance_points": 3}}))
	f.close()
	var r: Dictionary = st.read(st.profile_path(), SaveStore.KIND_PROFILE)
	var prof := st.load_profile()
	_cleanup(st)
	if bool(r["ok"]):
		return "future schema version was accepted"
	if not str(r["error"]).contains("schema_version"):
		return "error should name schema_version: %s" % str(r["error"])
	if prof != null:
		return "load_profile must not return a profile from a rejected file"
	return "ok"


func test_corrupt_wrong_kind_and_missing_rejected() -> String:
	var st := _store()
	DirAccess.make_dir_recursive_absolute(st.dir)
	var f := FileAccess.open(st.run_path(), FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	var r1: Dictionary = st.load_run()
	st.save_profile(MetaProfile.new())
	var r2: Dictionary = st.read(st.profile_path(), SaveStore.KIND_RUN)
	var r3: Dictionary = st.read(st.dir.path_join("nope.json"), SaveStore.KIND_RUN)
	var f2 := FileAccess.open(st.run_path(), FileAccess.WRITE)
	f2.store_string(JSON.stringify({"schema_version": 1, "kind": "run", "data": {"controller": {}}}))
	f2.close()
	var r4: Dictionary = st.load_run()
	_cleanup(st)
	if bool(r1["ok"]) or not str(r1["error"]).begins_with("corrupt"):
		return "corrupt file not rejected cleanly: %s" % str(r1)
	if bool(r2["ok"]) or not str(r2["error"]).contains("kind"):
		return "wrong kind accepted: %s" % str(r2)
	if bool(r3["ok"]) or r3["error"] != "missing":
		return "missing file: %s" % str(r3)
	if bool(r4["ok"]):
		return "incomplete run data accepted"
	return "ok"


# --- MainScene wiring ---

func test_main_autosaves_each_round_and_resumes() -> String:
	var st := _store()
	var main := MainScene.new()
	main.enable_persistence(st)
	main.start_new_run(21)
	main.controller.cargo["ORE"] = 5
	if st.has_run():
		_cleanup(st)
		return "nothing should be saved before the first round"
	var rpt: int = main.controller.ticks_per_round
	var guard: int = 0
	while main.controller.get_current_round() < 1 and guard < 100:
		main.loop.advance(0.25)
		guard += 1
	if not st.has_run() or FileAccess.file_exists(st.profile_path()) == false:
		_cleanup(st)
		return "round advance did not autosave run and profile (rpt=%d)" % rpt
	var saved_ticks: int = main.controller.sim_clock.total_ticks
	var main2 := MainScene.new()
	main2.enable_persistence(st)
	var ok := main2.continue_saved_run()
	var ticks2: int = main2.controller.sim_clock.total_ticks if ok else -1
	var ore: int = int(main2.controller.cargo.get("ORE", 0)) if ok else -1
	var seed2: int = main2.controller.run_seed if ok else -1
	_cleanup(st)
	main.free()
	main2.free()
	if not ok or ticks2 < rpt or ticks2 > saved_ticks or ore != 5 or seed2 != 21:
		return "resume failed: ok=%s ticks=%d ore=%d seed=%d" % [str(ok), ticks2, ore, seed2]
	return "ok"


func test_main_loads_profile_at_startup_and_saves_on_quit() -> String:
	var st := _store()
	var prof := MetaProfile.new()
	prof.add_unlock("seed_capital")
	prof.severance_points = 4
	st.save_profile(prof)
	var main := MainScene.new()
	main.enable_persistence(st)
	var rc := main.start_new_run(3)
	var has_perk: bool = rc.profile.has_unlock("seed_capital") and rc.profile.severance_points == 4
	rc.profile.severance_points = 9
	main._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	var again := st.load_profile()
	var persisted: bool = again != null and again.severance_points == 9 and again.has_unlock("seed_capital")
	var run_saved := st.has_run()
	_cleanup(st)
	main.free()
	if not has_perk:
		return "profile from disk not applied to the new run"
	if not persisted or not run_saved:
		return "quit did not persist profile and run"
	return "ok"


func test_main_without_persistence_never_writes() -> String:
	var main := MainScene.new()
	main.start_new_run(1)
	var wrote := main.save_all()
	var no_store: bool = main.save_store == null
	main.free()
	return "ok" if (not wrote and no_store) else "save_all without a store must be a no-op"
