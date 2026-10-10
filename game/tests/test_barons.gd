extends RefCounted
## Epic 3 task 1 (part of #15, Baron Framework design): barons.json, the Barons
## loader/validator, BaronState and Barons save/load, and the `world` RunSave key
## that exists only when a world is attached.

const TMP_ROOT := "user://test_tmp_barons"


func _data() -> Dictionary:
	return Barons.load_data()


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


## Validation errors of a mutated deep copy of the shipped data.
func _errs(mutate: Callable) -> Array:
	var d: Dictionary = _data().duplicate(true)
	mutate.call(d)
	return Barons.validate(d)


func _has(errs: Array, needle: String) -> bool:
	for e in errs:
		if str(e).contains(needle):
			return true
	return false


# --- barons.json ---

func test_shipped_data_is_valid() -> String:
	var errs: Array = Barons.validate(_data())
	if not errs.is_empty():
		return "barons.json invalid: %s" % str(errs)
	return "ok"


func test_three_barons_anchored_where_the_design_says() -> String:
	var w := Barons.new()
	if w.ids() != ["ares_heavy", "sol_central", "titan_cryo_hydro"]:
		return "unexpected baron ids %s" % str(w.ids())
	var want := {"ares_heavy": "mars", "titan_cryo_hydro": "ceres", "sol_central": "earth"}
	for id in want:
		if str(w.def(id)["anchor"]) != want[id] or w.baron_at(want[id]) != id:
			return "%s not anchored at %s" % [id, want[id]]
	var arche := {"ares_heavy": "short_squeezer", "titan_cryo_hydro": "hoarder", "sol_central": "auctioneer"}
	for id in arche:
		if str(w.def(id)["archetype"]) != arche[id]:
			return "%s has the wrong archetype" % id
	if w.baron_at("luna") != "":
		return "luna should have no baron"
	return "ok"


func test_takeover_and_victory_follow_the_decisions() -> String:
	var w := Barons.new()
	if w.float_shares() != 1000 or w.threshold_shares() != 501:
		return "float/threshold are %d/%d, decided 1000/501" % [w.float_shares(), w.threshold_shares()]
	if str(w.data["victory"]["barons_required"]) != "all":
		return "victory must require every baron"
	return "ok"


func test_opening_states_come_from_the_data() -> String:
	var w := Barons.new()
	var a: BaronState = w.state("ares_heavy")
	if a.treasury_cr != 60000 or a.treasury_shares != 600 or a.margin_debt_cr != 9000:
		return "ares_heavy opening state wrong: %s" % str(a.to_dict())
	if a.inventory != {"ORE": 300, "MACHINERY": 200}:
		return "ares_heavy inventory wrong: %s" % str(a.inventory)
	if a.holder != "" or a.debt_cr != 0 or a.strain != 0 or a.heat != 0:
		return "a fresh baron must be free of debt, strain and heat and held by nobody"
	if w.state("nobody") != null:
		return "unknown id should give null"
	return "ok"


# --- Validator ---

func test_validator_rejects_bad_files() -> String:
	var cases := {
		"empty": [func(d): d.clear(), "empty"],
		"version": [func(d): d["version"] = 2, "version"],
		"no barons": [func(d): d["barons"] = [], "non-empty"],
		"duplicate id": [func(d): d["barons"][1]["id"] = "ares_heavy", "duplicate id"],
		"bad id": [func(d): d["barons"][0]["id"] = "Ares Heavy", "lowercase"],
		"bad archetype": [func(d): d["barons"][0]["archetype"] = "pirate", "archetype"],
		"unknown anchor": [func(d): d["barons"][0]["anchor"] = "pluto", "not a station"],
		"shared anchor": [func(d): d["barons"][1]["anchor"] = "mars", "already taken"],
		"negative treasury": [func(d): d["barons"][0]["treasury_cr"] = -1, "treasury_cr"],
		"fractional treasury": [func(d): d["barons"][0]["treasury_cr"] = 10.5, "treasury_cr"],
		"shares over float": [func(d): d["barons"][0]["treasury_shares"] = 1001, "exceeds the float"],
		"unknown commodity": [func(d): d["barons"][0]["inventory"]["UNOBTANIUM"] = 5, "unknown commodity"],
		"pipeline commodity": [func(d): d["barons"][0]["privileges"]["pipelines"][0]["commodity"] = "GOLD", "pipeline commodity"],
		"pipeline depth": [func(d): d["barons"][0]["privileges"]["pipelines"][0]["depth_bps"] = 0, "depth_bps"],
		"missing param": [func(d): d["barons"][0]["params"].erase("squeeze_depth_bps"), "squeeze_depth_bps"],
		"param range": [func(d): d["barons"][0]["params"]["contract_qty"] = [60, 30], "contract_qty"],
		"hoarder commodities": [func(d): d["barons"][1]["params"]["float_commodities"] = ["GOLD"], "float_commodities"],
		"leak mode": [func(d): d["barons"][2]["params"]["indicative_leak"] = "never", "indicative_leak"],
		"threshold minority": [func(d): d["takeover"]["threshold_shares"] = 500, "strict majority"],
		"threshold over float": [func(d): d["takeover"]["threshold_shares"] = 1001, "strict majority"],
		"discount over 100%": [func(d): d["takeover"]["auction_discount_bps"] = 10001, "auction_discount_bps"],
		"victory count": [func(d): d["victory"]["barons_required"] = 4, "barons_required"],
		"heat": [func(d): d["heat"]["retaliation_at"] = 0, "retaliation_at"],
	}
	for label in cases:
		var c: Array = cases[label]
		var errs: Array = _errs(c[0])
		if errs.is_empty():
			return "'%s' was accepted" % label
		if not _has(errs, str(c[1])):
			return "'%s' reported %s, expected a line naming '%s'" % [label, str(errs), c[1]]
	return "ok"


func test_victory_accepts_a_count() -> String:
	if not _errs(func(d): d["victory"]["barons_required"] = 2).is_empty():
		return "a count of 2 of 3 should validate"
	return "ok"


# --- BaronState / Barons round trips ---

func _worked_world() -> Barons:
	var w := Barons.new()
	var t: BaronState = w.state("titan_cryo_hydro")
	t.treasury_cr = 12345
	t.debt_cr = 700
	t.strain = 3
	t.heat = 4
	t.pressure_bps = {"FOOD": 800, "FUEL": 200}
	t.holder = "player"
	t.shares = {"player": 501, "rival_1": 20}
	t.scratch = {"hoard_age": 2, "state": "hoarding"}
	return w


func test_baron_state_round_trips_through_json() -> String:
	var s: BaronState = _worked_world().state("titan_cryo_hydro")
	var back: BaronState = BaronState.from_dict(_json(s.to_dict()))
	if RunSave.canonical(back.to_dict()) != RunSave.canonical(s.to_dict()):
		return "state changed across JSON: %s vs %s" % [str(back.to_dict()), str(s.to_dict())]
	if typeof(back.treasury_cr) != TYPE_INT or typeof(back.pressure_bps["FOOD"]) != TYPE_INT:
		return "numbers must come back as ints"
	return "ok"


func test_baron_state_reads_missing_fields_with_defaults() -> String:
	var s: BaronState = BaronState.from_dict({"id": "x"})
	if s.id != "x" or s.treasury_cr != 0 or s.holder != "" or not s.inventory.is_empty():
		return "defaults wrong: %s" % str(s.to_dict())
	return "ok"


func test_world_round_trips_and_saved_form_ignores_insertion_order() -> String:
	var w := _worked_world()
	var back: Barons = Barons.from_dict(_json(w.to_dict()))
	if RunSave.canonical(back.to_dict()) != RunSave.canonical(w.to_dict()):
		return "world changed across JSON"
	var t: BaronState = w.state("titan_cryo_hydro")
	var u := Barons.from_dict(w.to_dict())
	var ut: BaronState = u.state("titan_cryo_hydro")
	ut.pressure_bps = {"FUEL": 200, "FOOD": 800}
	ut.shares = {"rival_1": 20, "player": 501}
	if JSON.stringify(ut.to_dict()) != JSON.stringify(t.to_dict()):
		return "to_dict key order depends on insertion order"
	return "ok"


func test_world_load_drops_unknown_barons_and_starts_new_ones_fresh() -> String:
	var d: Dictionary = _worked_world().to_dict()
	d["barons"]["ghost"] = BaronState.new("ghost").to_dict()
	d["barons"].erase("sol_central")
	var w: Barons = Barons.from_dict(d)
	if w.state("ghost") != null:
		return "a baron the data no longer lists was kept"
	if w.state("sol_central") == null or w.state("sol_central").treasury_cr != 50000:
		return "a baron missing from the save should start from its opening state"
	if w.state("titan_cryo_hydro").treasury_cr != 12345:
		return "saved state not applied"
	return "ok"


# --- RunSave ---

func _session(p_seed: int = 84) -> Replay.Session:
	return Replay.Session.new(p_seed)


func test_no_world_means_no_key_and_the_same_hash() -> String:
	var s := _session(84)
	s.dispatch(M0Loop.ACT_TAB_NEXT)
	s.advance_frames(40)
	s.dispatch(M0Loop.ACT_RIGHT)
	s.dispatch(M0Loop.ACT_SUBMIT)
	s.advance_frames(2000)
	if s.controller.world != null:
		return "a plain session must not carry a world"
	if RunSave.capture(s.controller, s.loop.market, s.bags).has("world"):
		return "capture added a world key with no world attached"
	var pinned: String = str((load("res://tests/test_travel.gd") as GDScript).get_script_constant_map()["NEVER_TRAVELS_HASH"])
	if s.state_hash() != pinned:
		return "hash of a run with no barons moved: %s" % s.state_hash()
	return "ok"


func test_attached_world_is_saved_hashed_and_restored() -> String:
	var s := _session(7)
	var plain: String = s.state_hash()
	s.controller.world = _worked_world()
	var cap: Dictionary = RunSave.capture(s.controller, s.loop.market, s.bags)
	if not cap.has("world"):
		return "attached world not captured"
	var with_world: String = s.state_hash()
	if with_world == plain:
		return "the hash ignores the world"
	s.controller.world.state("ares_heavy").heat += 1
	if s.state_hash() == with_world:
		return "baron state does not move the hash"
	s.controller.world.state("ares_heavy").heat -= 1
	var r: Dictionary = RunSave.restore(_json(cap))
	if not bool(r["ok"]):
		return "restore failed: %s" % r["error"]
	var rc: RunController = r["controller"]
	if rc.world == null:
		return "restore lost the world"
	if RunSave.state_hash(rc, r["market"], r["bags"]) != with_world:
		return "hash changed across the save round trip"
	return "ok"


func test_restoring_an_old_save_gives_no_world() -> String:
	var s := _session(9)
	var cap: Dictionary = RunSave.capture(s.controller, s.loop.market, s.bags)
	var r: Dictionary = RunSave.restore(_json(cap))
	if not bool(r["ok"]) or r["controller"].world != null:
		return "a save without a world key must load with no world"
	return "ok"


func test_world_survives_the_save_store() -> String:
	var s := _session(11)
	s.controller.world = _worked_world()
	var st := SaveStore.new("%s/w_%d" % [TMP_ROOT, Time.get_ticks_usec()])
	var before: String = s.state_hash()
	var err: Error = st.save_run(s.controller, s.loop.market, s.bags)
	var r: Dictionary = st.load_run()
	DirAccess.remove_absolute(st.run_path())
	if err != OK or not bool(r["ok"]):
		return "save/load failed: %s" % str(r.get("error", err))
	if r["controller"].world == null or RunSave.state_hash(r["controller"], r["market"], r["bags"]) != before:
		return "world did not survive the save store"
	return "ok"
