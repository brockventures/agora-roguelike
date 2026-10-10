extends RefCounted
## The optional Steam layer (#27, Integrate godot-steam SDK; part of #26, Epic 5).
## Everything here runs with no GodotSteam and no Steam client: the "backend" is
## SteamFake, and the unavailable path is the real one.

const TMP_ROOT := "user://test_tmp"
var _counter: int = 0


func _dir() -> String:
	_counter += 1
	return "%s/steam_%d_%d" % [TMP_ROOT, Time.get_ticks_usec(), _counter]


func _rm_rf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(TMP_ROOT)


func _online() -> Array:
	var fake := SteamFake.new()
	var svc := SteamService.new()
	svc.initialize(fake)
	return [svc, fake]


# --- No Steam: everything degrades to a logged no-op ---

func test_unavailable_without_extension() -> String:
	if SteamService.detect_backend() != null:
		return "a GodotSteam singleton is present in the test environment"
	var svc := SteamService.new()
	if svc.initialize():
		return "initialize() claimed success with no backend"
	if svc.available or svc.backend != null:
		return "service should be unavailable"
	return "ok"


func test_every_call_is_a_logged_noop_when_unavailable() -> String:
	var svc := SteamService.new()
	svc.initialize()
	svc.log_lines.clear()
	svc.set_stat("crises_survived", 1)
	svc.cloud_push("profile.json", "{}")
	svc.cloud_delete("profile.json")
	if svc.cloud_restore("user://test_tmp/none.json") or svc.cloud_enabled():
		return "cloud must be off"
	if svc.input_init("x.vdf") or not svc.poll_input()["pressed"].is_empty():
		return "input must be off"
	svc.run_callbacks()
	if svc.log_lines.size() < 3:
		return "no-ops were not logged: %s" % str(svc.log_lines)
	return "ok"


func test_app_id_defaults_to_spacewar() -> String:
	if OS.get_environment(SteamService.ENV_APP_ID) != "":
		return "ok"  # an operator override is set; the default is not observable
	if SteamService.load_app_id() != 480 or SteamService.DEFAULT_APP_ID != 480:
		return "expected 480, got %d" % SteamService.load_app_id()
	return "ok"


# --- Init against a fake backend ---

func test_init_success_and_failure() -> String:
	var fake := SteamFake.new()
	var svc := SteamService.new()
	if not svc.initialize(fake) or not svc.available:
		return "fake backend should initialise"
	var bad := SteamFake.new()
	bad.init_status = 2
	var svc2 := SteamService.new()
	if svc2.initialize(bad) or svc2.available:
		return "a failed init must leave the service unavailable"
	return "ok"


# --- Achievements and the local mirror ---

func test_data_file_is_consistent() -> String:
	var svc := SteamService.new()
	if svc.achievement_defs.size() < 5 or svc.stat_defs.size() < 3:
		return "definitions did not load"
	for id in SteamHooks.EVENT_ACHIEVEMENTS:
		if not svc.achievement_defs.has(id):
			return "hook achievement %s missing from achievements.json" % id
	for id in svc.achievement_defs:
		var a: Dictionary = svc.achievement_defs[id]
		if a.has("stat") and not svc.stat_defs.has(str(a["stat"])):
			return "%s names unknown stat %s" % [id, a["stat"]]
		if not a.has("stat") and not a.has("hook"):
			return "%s has neither a stat threshold nor a hook" % id
	return "ok"


func test_unlock_updates_mirror_once_without_steam() -> String:
	var svc := SteamService.new()
	if not svc.unlock("FIRST_CHAPTER_11") or not svc.is_unlocked("FIRST_CHAPTER_11"):
		return "first unlock should record"
	if svc.unlock("FIRST_CHAPTER_11"):
		return "second unlock should be a no-op"
	if svc.unlock("NOT_A_REAL_ID"):
		return "unknown id must not unlock"
	return "ok"


func test_unlock_reaches_backend_when_online() -> String:
	var o := _online()
	var svc: SteamService = o[0]
	var fake: SteamFake = o[1]
	svc.unlock("WITNESS_COLLAPSE")
	if not fake.achievements.has("WITNESS_COLLAPSE") or fake.store_calls < 1:
		return "backend did not get the unlock and storeStats"
	return "ok"


func test_stat_thresholds_unlock_achievements() -> String:
	var svc := SteamService.new()
	svc.max_stat("peak_net_worth", 30000)
	if not svc.is_unlocked("NET_WORTH_25K") or svc.is_unlocked("NET_WORTH_100K"):
		return "25K only expected, got %s" % str(svc.unlocked.keys())
	svc.max_stat("peak_net_worth", 10)
	if svc.get_stat("peak_net_worth") != 30000:
		return "max_stat must never lower a stat"
	svc.add_stat("crises_survived", 1)
	if not svc.is_unlocked("CRISIS_FIRST"):
		return "first crisis achievement missing"
	return "ok"


func test_offline_progress_is_pushed_when_steam_arrives() -> String:
	var svc := SteamService.new()
	svc.unlock("CRISIS_FIRST")
	svc.set_stat("crises_survived", 1)
	var fake := SteamFake.new()
	svc.initialize(fake)
	if not fake.achievements.has("CRISIS_FIRST") or int(fake.stat_values.get("crises_survived", 0)) != 1:
		return "mirror was not synced to Steam on init"
	return "ok"


func test_mirror_persists_and_merges_through_savestore() -> String:
	var store := SaveStore.new(_dir())
	var a := SteamService.new()
	a.attach_store(store)
	a.unlock("FIRST_CHAPTER_11")
	a.set_stat("runs_completed", 3)
	var b := SteamService.new()
	b.set_stat("runs_completed", 9)
	b.attach_store(store)
	var ok: bool = b.is_unlocked("FIRST_CHAPTER_11") and b.get_stat("runs_completed") == 9
	_rm_rf(store.dir)
	return "ok" if ok else "merge lost progress: %s" % str(b.to_dict())


# --- Gameplay hooks ---

func _filed_controller() -> RunController:
	var rc := RunController.new(MetaProfile.new(), 5)
	rc.cr = -999999
	rc.pending_bankruptcy = true
	return rc


func test_hook_chapter_11_filing_unlocks() -> String:
	var svc := SteamService.new()
	var hooks := SteamHooks.new(svc)
	var rc := _filed_controller()
	hooks.bind(rc)
	if rc.file_bankruptcy().is_empty():
		return "test setup: bankruptcy did not file"
	if not svc.is_unlocked("FIRST_CHAPTER_11"):
		return "filing did not unlock FIRST_CHAPTER_11"
	if svc.get_stat("bankruptcies_filed") != 1 or svc.get_stat("runs_completed") != 1:
		return "stats not mirrored: %s" % str(svc.stats)
	return "ok"


func test_hook_collapse_unlocks() -> String:
	var svc := SteamService.new()
	var hooks := SteamHooks.new(svc)
	var rc := RunController.new(MetaProfile.new(), 1)
	hooks.bind(rc)
	rc.run_collapsed.emit()
	return "ok" if svc.is_unlocked("WITNESS_COLLAPSE") else "collapse did not unlock"


func test_hook_crisis_expiry_counts_survived() -> String:
	var svc := SteamService.new()
	var hooks := SteamHooks.new(svc)
	var rc := RunController.new(MetaProfile.new(), 1)
	rc.crisis_deck = CrisisDeck.new(1)
	hooks.bind(rc)
	rc.crisis_deck.crisis_expired.emit({"uid": 1})
	rc.crisis_deck.crisis_expired.emit({"uid": 2})
	if svc.get_stat("crises_survived") != 2 or not svc.is_unlocked("CRISIS_FIRST"):
		return "crises_survived=%d" % svc.get_stat("crises_survived")
	return "ok"


func test_hook_round_tracks_peak_net_worth() -> String:
	var svc := SteamService.new()
	var hooks := SteamHooks.new(svc)
	var rc := RunController.new(MetaProfile.new(), 1)
	hooks.bind(rc)
	rc.peak_net_worth = 120000
	rc.round_advanced.emit(1)
	if not svc.is_unlocked("NET_WORTH_100K"):
		return "100K threshold not reached"
	return "ok"


func test_unbind_stops_events() -> String:
	var svc := SteamService.new()
	var hooks := SteamHooks.new(svc)
	var rc := RunController.new(MetaProfile.new(), 1)
	hooks.bind(rc)
	hooks.unbind()
	rc.run_collapsed.emit()
	return "ok" if not svc.is_unlocked("WITNESS_COLLAPSE") else "event reached an unbound hook"


# --- Cloud saves ---

func test_savestore_unchanged_with_unavailable_service() -> String:
	var plain := SaveStore.new(_dir())
	var wired := SaveStore.new(_dir())
	wired.cloud = SteamService.new()  # unavailable
	var p := MetaProfile.new()
	p.severance_points = 12
	if plain.save_profile(p) != OK or wired.save_profile(p) != OK:
		return "save failed"
	var a := FileAccess.get_file_as_string(plain.profile_path())
	var b := FileAccess.get_file_as_string(wired.profile_path())
	var loaded := wired.load_profile()
	var ok: bool = a == b and loaded != null and loaded.severance_points == 12
	_rm_rf(plain.dir)
	_rm_rf(wired.dir)
	return "ok" if ok else "bytes differ or round trip broke"


func test_cloud_write_and_restore_round_trip() -> String:
	var o := _online()
	var svc: SteamService = o[0]
	var fake: SteamFake = o[1]
	var store := SaveStore.new(_dir())
	store.cloud = svc
	var p := MetaProfile.new()
	p.severance_points = 77
	store.save_profile(p)
	if not fake.files.has("profile.json"):
		return "write was not pushed to Steam Cloud"
	if (fake.files["profile.json"] as PackedByteArray).get_string_from_utf8() != FileAccess.get_file_as_string(store.profile_path()):
		return "cloud copy differs from the local file"
	# A second machine: empty local dir, same Cloud.
	var other := SaveStore.new(_dir())
	other.cloud = svc
	var got := other.load_profile()
	var ok: bool = got != null and got.severance_points == 77
	_rm_rf(store.dir)
	_rm_rf(other.dir)
	return "ok" if ok else "profile did not restore from the cloud"


func test_newer_cloud_copy_wins_older_does_not() -> String:
	var o := _online()
	var svc: SteamService = o[0]
	var fake: SteamFake = o[1]
	var store := SaveStore.new(_dir())
	var p := MetaProfile.new()
	p.severance_points = 5
	store.save_profile(p)  # local only, no cloud yet
	var q := MetaProfile.new()
	q.severance_points = 50
	var envelope := {"schema_version": SaveStore.SCHEMA_VERSION, "kind": SaveStore.KIND_PROFILE, "data": q.to_dict()}
	fake.files["profile.json"] = JSON.stringify(envelope).to_utf8_buffer()
	store.cloud = svc
	fake.file_times["profile.json"] = 1  # older than the local file
	if store.load_profile().severance_points != 5:
		return "an older cloud copy overwrote the local save"
	fake.file_times["profile.json"] = 4102444800  # far future
	var ok: bool = store.load_profile().severance_points == 50
	_rm_rf(store.dir)
	return "ok" if ok else "a newer cloud copy did not win"


func test_corrupt_cloud_copy_is_rejected_like_any_save() -> String:
	var o := _online()
	var svc: SteamService = o[0]
	var fake: SteamFake = o[1]
	var store := SaveStore.new(_dir())
	store.cloud = svc
	fake.files["profile.json"] = "not json".to_utf8_buffer()
	fake.file_times["profile.json"] = 4102444800
	var r := store.read(store.profile_path(), SaveStore.KIND_PROFILE)
	_rm_rf(store.dir)
	return "ok" if not bool(r["ok"]) else "corrupt cloud data accepted"


func test_delete_run_removes_cloud_copy() -> String:
	var o := _online()
	var svc: SteamService = o[0]
	var fake: SteamFake = o[1]
	var store := SaveStore.new(_dir())
	store.cloud = svc
	fake.files[SaveStore.RUN_FILE] = PackedByteArray([1])
	store.delete_run()
	return "ok" if not fake.files.has(SaveStore.RUN_FILE) else "cloud run slot survived delete_run"


# --- Steam Input ---

func test_input_edges_use_inputmap_action_names() -> String:
	var o := _online()
	var svc: SteamService = o[0]
	var fake: SteamFake = o[1]
	if not svc.input_init("/depot/game_actions_480.vdf") or fake.manifest != "/depot/game_actions_480.vdf":
		return "manifest not registered"
	fake.digital["m0_submit".hash()] = true
	var e1 := svc.poll_input()
	if e1["pressed"] != ["m0_submit"]:
		return "expected m0_submit pressed, got %s" % str(e1["pressed"])
	if not svc.poll_input()["pressed"].is_empty():
		return "held button re-fired"
	fake.digital["m0_submit".hash()] = false
	if svc.poll_input()["released"] != ["m0_submit"]:
		return "release not reported"
	for action in e1["pressed"]:
		if not InputMap.has_action(action):
			return "%s is not an InputMap action" % action
	return "ok"


# --- Main wiring ---

func test_main_binds_hooks_to_each_new_run() -> String:
	var svc := SteamService.new()
	var prev: SteamService = SteamService.shared()
	SteamService.set_shared(svc)
	var main := MainScene.new()
	main.start_new_run(3)
	main.controller.run_collapsed.emit()
	var first: bool = svc.is_unlocked("WITNESS_COLLAPSE")
	svc.unlocked.clear()
	main.start_new_run(4)
	main.controller.run_collapsed.emit()
	var second: bool = svc.is_unlocked("WITNESS_COLLAPSE")
	SteamService.set_shared(prev)
	main.free()
	if not first or not second:
		return "hooks not live on run 1 (%s) or run 2 (%s)" % [first, second]
	return "ok"


func test_main_persistence_routes_store_through_the_service() -> String:
	var svc := SteamService.new()
	var fake := SteamFake.new()
	svc.initialize(fake)
	var prev: SteamService = SteamService.shared()
	SteamService.set_shared(svc)
	var store := SaveStore.new(_dir())
	var main := MainScene.new()
	main.enable_persistence(store)
	main.start_new_run(5)
	main.save_all()
	SteamService.set_shared(prev)
	var ok: bool = fake.files.has(SaveStore.RUN_FILE) and fake.files.has(SaveStore.PROFILE_FILE)
	main.free()
	_rm_rf(store.dir)
	return "ok" if ok else "autosave did not reach Steam Cloud: %s" % str(fake.files.keys())
