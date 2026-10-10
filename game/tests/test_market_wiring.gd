extends RefCounted
## Epic 3 task 2 (part of #15, Baron Framework design): market wiring. A station's
## book is made by its anchoring baron (maker_for), world_mods fold before
## crisis_mods in a fixed order (golden fixture tests/fixtures/world/fold_order.json),
## ask_price_bps moves only the ask ladder, execute_as takes any participant, the
## ladder rows carry a `maker` tag, and counterparty_name reads the world registry.
## No archetype behaviour yet (tasks 4-6): the world emits only the pipelines (task 3).

const FIXTURE := "res://tests/fixtures/world/fold_order.json"
const TPR: int = 30
const TMP_ROOT := "user://test_tmp_wiring"

## RunSave.state_hash of a baron-world run (see _world_run) for two seeds, measured
## when this task landed, and re-pinned by Epic 3 task 3 (baron privileges): the supply
## pipelines are ask-side world mods, so every world book is seeded differently from the
## first frame. Not the arrival toll: this run teleports with dock_at and never arrives. They pin the whole world path: makers per station, the
## per-round world-mods step, the Ceres book unlocked mid-run. A change that moves
## them is a replay-contract change and must be deliberate.
const WORLD_HASH_SEED_84 := "4b1464a8efc518458d138a930d7aa68ce54739157ea36a445061d5fe2520333a"
const WORLD_HASH_SEED_7 := "3911b0ea99ec566004d6f0092b9fe69a98421d41634c3fadcf7b5a1c52a44625"


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


func _fixture() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))


func _world_market() -> StationMarket:
	var m := StationMarket.new()
	m.unlock_station("ceres")
	m.unlock_station("luna")
	m.set_world(Barons.new())
	return m


# --- maker_for ---

func test_no_world_every_station_is_made_by_ares_heavy() -> String:
	var m := StationMarket.new()
	m.unlock_station("ceres")
	for st in Transit.STATIONS:
		if m.maker_for(st) != StationMarket.MAKER_ID:
			return "%s maker is %s with no world" % [st, m.maker_for(st)]
	for key in m.books:
		var b: OrderBook = m.books[key]
		for o: Order in b.bids + b.asks:
			if o.agent_id != StationMarket.MAKER_ID:
				return "%s has a %s order with no world" % [key, o.agent_id]
	if m.counterparty_name("titan_cryo_hydro") != "":
		return "a baron id must not resolve without a world"
	return "ok"


func test_attaching_no_world_changes_nothing() -> String:
	var a := StationMarket.new()
	var b := StationMarket.new()
	b.set_world(null)
	b.set_world_mods([])
	if RunSave.canonical(a.to_dict()) != RunSave.canonical(b.to_dict()):
		return "set_world(null) / set_world_mods([]) moved the books"
	return "ok"


func test_stations_are_made_by_their_anchoring_baron() -> String:
	var m := _world_market()
	var want := {"mars": "ares_heavy", "ceres": "titan_cryo_hydro", "earth": "sol_central", "luna": StationMarket.MAKER_ID}
	for st in want:
		if m.maker_for(st) != want[st]:
			return "%s maker is %s, want %s" % [st, m.maker_for(st), want[st]]
		for c in Transit.COMMODITIES:
			var b: OrderBook = m.get_book(st, c)
			for o: Order in b.bids + b.asks:
				if o.agent_id != want[st]:
					return "%s:%s holds an order from %s, want %s" % [st, c, o.agent_id, want[st]]
	return "ok"


func test_luna_is_unanchored_and_keeps_the_default_maker() -> String:
	# The doc (3.2): unanchored stations keep ares_heavy. No baron anchors Luna.
	var w := Barons.new()
	if w.baron_at("luna") != "":
		return "barons.json anchors Luna to %s; this test (and the doc) assume it does not" % w.baron_at("luna")
	return "ok" if _world_market().maker_for("luna") == "ares_heavy" else "Luna lost the default maker"


func test_prices_and_depth_do_not_depend_on_the_maker() -> String:
	# Only the maker id differs: the world with no mods reshapes nothing else.
	var plain := StationMarket.new()
	plain.unlock_station("ceres")
	var m := StationMarket.new()
	m.unlock_station("ceres")
	m.set_world(Barons.new())
	for st in ["earth", "mars", "ceres"]:
		for c in Transit.COMMODITIES:
			var a: Dictionary = plain.ladder(st, c, 5)
			var b: Dictionary = m.ladder(st, c, 5)
			for side in ["bids", "asks"]:
				for i in (a[side] as Array).size():
					if a[side][i]["price"] != b[side][i]["price"] or a[side][i]["quantity"] != b[side][i]["quantity"]:
						return "%s:%s %s level %d differs from the plain book" % [st, c, side, i]
	return "ok"


func test_detaching_the_world_restores_ares_everywhere() -> String:
	var m := _world_market()
	m.set_world(null)
	for st in ["earth", "mars", "ceres"]:
		if m.maker_for(st) != StationMarket.MAKER_ID or (m.get_book(st, "ORE").asks[0] as Order).agent_id != StationMarket.MAKER_ID:
			return "%s still baron-made after detaching" % st
	return "ok"


func test_unlocking_a_station_after_attach_uses_its_baron() -> String:
	var m := StationMarket.new()
	m.set_world(Barons.new())
	m.unlock_station("ceres")
	if (m.get_book("ceres", "FUEL").asks[0] as Order).agent_id != "titan_cryo_hydro":
		return "a station unlocked after attach was not made by its baron"
	return "ok"


# --- ladder maker tags, counterparty registry, execute_as ---

func test_ladder_rows_carry_the_maker() -> String:
	var m := _world_market()
	var want := {"mars": "ares_heavy", "ceres": "titan_cryo_hydro", "earth": "sol_central"}
	for st in want:
		var l: Dictionary = m.ladder(st, "FUEL", 5)
		for side in ["bids", "asks"]:
			for row in l[side]:
				if str(row["maker"]) != want[st]:
					return "%s %s row maker is '%s'" % [st, side, row["maker"]]
	return "ok"


func test_a_level_with_two_makers_has_no_single_maker() -> String:
	var m := StationMarket.new()
	var b: OrderBook = m.get_book("mars", "ORE")
	var px: int = (b.asks[0] as Order).limit_price
	b.insert_order(Order.new("rival-1", "rival_a", "ORE", "ask", 5, px, 99))
	var row: Dictionary = m.ladder("mars", "ORE", 5)["asks"][0]
	if str(row["maker"]) != "":
		return "mixed level reports maker '%s'" % row["maker"]
	return "ok"


func test_counterparty_name_reads_the_registry() -> String:
	var m := _world_market()
	var want := {"ares_heavy": "ARES HEAVY", "titan_cryo_hydro": "TITAN CRYO-HYDRO", "sol_central": "SOL CENTRAL", "nobody": ""}
	for id in want:
		if m.counterparty_name(id) != want[id]:
			return "counterparty_name(%s) = '%s'" % [id, m.counterparty_name(id)]
	return "ok"


func test_fills_announce_the_station_baron() -> String:
	var m := _world_market()
	var want := {"mars": "ARES HEAVY", "ceres": "TITAN CRYO-HYDRO", "earth": "SOL CENTRAL"}
	for st in want:
		var r: Dictionary = m.execute(st, "ORE", "BUY", 1, 9999.0)
		if int(r["filled"]) != 1 or r["counterparty"] != want[st]:
			return "%s fill: %s" % [st, str(r)]
	return "ok"


func test_execute_as_runs_the_sweep_for_any_participant() -> String:
	var a := _world_market()
	var b := _world_market()
	var ra: Dictionary = a.execute("ceres", "FUEL", "BUY", 12, 9999.0)
	var rb: Dictionary = b.execute_as("player", "ceres", "FUEL", "BUY", 12, 9999.0)
	if RunSave.canonical(a.to_dict()) != RunSave.canonical(b.to_dict()) or ra["cost"] != rb["cost"]:
		return "execute is not execute_as(player)"
	var r: Dictionary = a.execute_as("rival_x", "ceres", "FUEL", "BUY", 5, 9999.0)
	if int(r["filled"]) != 5 or r["counterparty_id"] != "titan_cryo_hydro":
		return "rival fill: %s" % str(r)
	for t: Order.Trade in r["trades"]:
		if t.buyer_id != "rival_x":
			return "trade buyer is %s, want rival_x" % t.buyer_id
	for o: Order in a.get_book("ceres", "FUEL").bids:
		if o.agent_id == "rival_x":
			return "an IOC rival order was left resting"
	# A rival sale lands on the baron's bid (the book does not check stock; that is the caller's job).
	var s: Dictionary = a.execute_as("rival_x", "ceres", "FUEL", "SELL", 1, 0.0)
	if int(s["filled"]) != 1 or s["counterparty_id"] != "titan_cryo_hydro":
		return "rival sale: %s" % str(s)
	return "ok"


# --- mods: fold order, ask_price_bps ---

func _market_with(world_mods: Array, crisis_mods: Array) -> StationMarket:
	var m := StationMarket.new()
	m.crisis_mods = crisis_mods.duplicate(true)
	m.world_mods = world_mods.duplicate(true)
	m.replenish()
	return m


func test_golden_fold_order() -> String:
	var fx: Dictionary = _fixture()
	var m := _market_with(fx["world_mods"], fx["crisis_mods"])
	var swapped := _market_with(fx["crisis_mods"], fx["world_mods"])
	var any_order_matters: bool = false
	for c in fx["cases"]:
		var st: String = c["station"]
		var com: String = c["commodity"]
		var got: Dictionary = m._mods_for(st, com)
		for k in c["world_then_crisis"]:
			if int(got[k]) != int(c["world_then_crisis"][k]):
				return "%s:%s %s folded to %d, golden says %d" % [st, com, k, got[k], c["world_then_crisis"][k]]
		# The same two groups in the other order must give the golden's other answer.
		var sw: Dictionary = swapped._mods_for(st, com)
		for k in c["crisis_then_world"]:
			if int(sw[k]) != int(c["crisis_then_world"][k]):
				return "%s:%s swapped %s folded to %d, golden says %d" % [st, com, k, sw[k], c["crisis_then_world"][k]]
		if RunSave.canonical(c["world_then_crisis"]) != RunSave.canonical(c["crisis_then_world"]):
			any_order_matters = true
		var lad: Dictionary = m.ladder(st, com, 5)
		var want: Dictionary = c["ladder_world_then_crisis"]
		for side in ["asks", "bids"]:
			for i in 5:
				if int(lad[side][i]["price"]) != int(want[side][i][0]) or int(lad[side][i]["quantity"]) != int(want[side][i][1]):
					return "%s:%s %s level %d is %s x%s, golden says %s" % [st, com, side, i, lad[side][i]["price"], lad[side][i]["quantity"], str(want[side][i])]
	if not any_order_matters:
		return "the fixture no longer distinguishes the two fold orders"
	return "ok"


func test_set_world_mods_reseeds_and_reverts() -> String:
	var fx: Dictionary = _fixture()
	var m := StationMarket.new()
	var before: Dictionary = m.ladder("mars", "ORE", 5)
	m.set_world_mods(fx["world_mods"])
	var during: Dictionary = m.ladder("mars", "ORE", 5)
	if during == before:
		return "world mods did not reach the book"
	if m.ladder("mars", "ORE", 5)["asks"][0]["maker"] != "ares_heavy":
		return "a modded book lost its maker"
	m.set_world_mods([])
	var after: Dictionary = m.ladder("mars", "ORE", 5)
	if after != before:
		return "clearing the world mods did not restore the book"
	return "ok"


func test_ask_price_bps_moves_only_the_ask_ladder() -> String:
	var plain := StationMarket.new()
	var m := StationMarket.new()
	m.set_world_mods([{"station": "mars", "commodity": "ORE", "ask_price_bps": 1000}])
	var a: Dictionary = plain.ladder("mars", "ORE", 5)
	var b: Dictionary = m.ladder("mars", "ORE", 5)
	if b["bids"] != a["bids"]:
		return "ask_price_bps moved the bids"
	for i in 5:
		if float(b["asks"][i]["price"]) <= float(a["asks"][i]["price"]):
			return "ask level %d did not get dearer: %s vs %s" % [i, b["asks"][i]["price"], a["asks"][i]["price"]]
		if b["asks"][i]["quantity"] != a["asks"][i]["quantity"]:
			return "ask_price_bps changed the depth"
	# Other books are untouched, and a mod without the field is byte-identical to before.
	if m.ladder("mars", "FUEL", 5) != plain.ladder("mars", "FUEL", 5):
		return "ask_price_bps leaked to another commodity"
	var legacy := StationMarket.new()
	legacy.crisis_mods = [{"station": "mars", "commodity": "ORE", "depth_bps": 8000, "price_bps": 200, "spread_bps": 12000}]
	legacy.replenish()
	var legacy_ask: float = float(legacy.ladder("mars", "ORE", 5)["asks"][0]["price"])
	var m2 := StationMarket.new()
	m2.crisis_mods = [{"station": "mars", "commodity": "ORE", "depth_bps": 8000, "price_bps": 200, "spread_bps": 12000, "ask_price_bps": 0}]
	m2.replenish()
	if float(m2.ladder("mars", "ORE", 5)["asks"][0]["price"]) != legacy_ask:
		return "ask_price_bps 0 differs from absent"
	return "ok"


func test_barons_emit_only_pipeline_mods_so_far() -> String:
	# Privileges (task 3) emit supply pipelines; archetype behaviour is tasks 4-6.
	# Every mod the world emits today is an ask-side pipeline mod (tests/test_privileges.gd).
	for m in Barons.new().market_mods():
		if not m.has("ask_depth_bps") or m.has("depth_bps") or m.has("price_bps") or m.has("spread_bps"):
			return "the world emits a mod that is not a pipeline: %s" % str(m)
	return "ok"


# --- wiring into a run ---

func test_a_new_run_attaches_the_world() -> String:
	var scene = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	scene.start_new_run(84)
	var ok: bool = scene.controller.world != null and scene.loop.market.world == scene.controller.world \
		and scene.loop.market.maker_for("mars") == "ares_heavy" and scene.loop.market.maker_for("earth") == "sol_central"
	var mars_ok: bool = (scene.loop.market.get_book("earth", "ORE").asks[0] as Order).agent_id == "sol_central"
	scene.free()
	return "ok" if ok and mars_ok else "start_new_run did not wire the barons into the market"


func test_the_next_run_after_collapse_keeps_a_world() -> String:
	var s := Replay.Session.new(31, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	var rc: RunController = s.loop.start_next_run()
	if rc == null or rc.world == null:
		return "the follow-up run has no world"
	if s.loop.market.world != rc.world or s.loop.market.maker_for("earth") != "sol_central":
		return "the follow-up run's market is not baron-made"
	return "ok"


func test_a_plain_session_has_no_world() -> String:
	var s := Replay.Session.new(31, {}, Replay.DEFAULT_FRAME_DELTA, TPR)
	if s.controller.world != null or s.loop.market.world != null or s.loop.market.maker_for("earth") != "ares_heavy":
		return "a session built without a world picked one up"
	var next: RunController = s.loop.start_next_run()
	if next.world != null:
		return "a no-world run's successor gained a world"
	return "ok"


func test_the_board_and_sidebar_name_the_baron() -> String:
	Loc.set_locale(Loc.LOCALE_EN)
	var scene = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	scene.start_new_run(84)
	scene.hud.set_station("ceres")
	scene.loop.market.unlock_station("ceres")
	var board: String = scene._board_text()
	var side: String = scene._sidebar_text()
	var plain: String = ""
	scene.hud.set_station("mars")
	plain = scene._board_text()
	scene.free()
	if not board.contains("TITAN CRYO-HYDRO"):
		return "the Ceres board does not name Titan: %s" % board
	if not side.contains("TITAN"):
		return "the Ceres ladder has no maker tag: %s" % side
	if not plain.contains("ARES HEAVY") or plain.contains("TITAN"):
		return "the Mars board is not Ares Heavy's: %s" % plain
	return "ok"


# --- determinism: hash goldens, save/load/continue ---

## A baron-world run: dock at Ceres mid-run so a Titan-made book exists, buy at
## the dock, then run many rounds so the per-round world step fires.
func _world_run(p_seed: int) -> Replay.Session:
	var s := Replay.Session.new(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	s.dispatch(M0Loop.ACT_TAB_NEXT)
	s.advance_frames(40)
	s.dispatch(M0Loop.ACT_RIGHT)
	s.dispatch(M0Loop.ACT_SUBMIT)
	s.advance_frames(300)
	s.loop.dock_at("ceres")
	s.dispatch(M0Loop.ACT_SUBMIT)
	_advance(s, 1500)
	return s


## Frames, acknowledging any crisis that stops the clock (it would stall otherwise).
func _advance(s: Replay.Session, n: int) -> void:
	for i in n:
		if s.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			s.loop.acknowledge_crisis()
		s.advance()


func test_golden_hash_for_two_seeds() -> String:
	var got := {84: _world_run(84).state_hash(), 7: _world_run(7).state_hash()}
	if got[84] != WORLD_HASH_SEED_84:
		return "seed 84 world hash moved: %s" % got[84]
	if got[7] != WORLD_HASH_SEED_7:
		return "seed 7 world hash moved: %s" % got[7]
	if got[84] == got[7]:
		return "two seeds hashed alike"
	return "ok"


func test_world_run_is_repeatable_and_makers_survive_rounds() -> String:
	var a := _world_run(84)
	var b := _world_run(84)
	if a.state_hash() != b.state_hash():
		return "the same world run hashed twice differently"
	var m: StationMarket = a.loop.market
	if a.controller.get_current_round() < 5:
		return "run only reached round %d" % a.controller.get_current_round()
	if (m.get_book("ceres", "FUEL").asks[0] as Order).agent_id != "titan_cryo_hydro" \
			or (m.get_book("earth", "FRAG").asks[0] as Order).agent_id != "sol_central":
		return "a round boundary reseeded the books with the wrong maker"
	return "ok"


func test_save_load_then_continue_equals_the_uninterrupted_run() -> String:
	for p_seed in [84, 7]:
		var whole := _world_run(p_seed)
		var split := Replay.Session.new(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
		split.dispatch(M0Loop.ACT_TAB_NEXT)
		split.advance_frames(40)
		split.dispatch(M0Loop.ACT_RIGHT)
		split.dispatch(M0Loop.ACT_SUBMIT)
		split.advance_frames(300)
		split.loop.dock_at("ceres")
		split.dispatch(M0Loop.ACT_SUBMIT)
		_advance(split, 700)
		# Save mid-run through JSON, rebuild a loop around the restored objects, continue.
		var cap: Dictionary = RunSave.capture(split.controller, split.loop.market, split.bags)
		# Through JSON (the file): the hash must survive it. The continue then runs from the
		# in-memory capture, because JSON text carries only ~15 significant digits and the
		# sim clock's float accumulator would drift by an ulp, which is not the world's doing.
		var via_json: Dictionary = RunSave.restore(_json(cap))
		if not bool(via_json["ok"]) or RunSave.state_hash(via_json["controller"], via_json["market"], via_json["bags"]) != split.state_hash():
			return "seed %d: the save file round trip changed the hash" % p_seed
		var r: Dictionary = RunSave.restore(cap.duplicate(true))
		if not bool(r["ok"]):
			return "seed %d restore failed: %s" % [p_seed, r["error"]]
		var rc: RunController = r["controller"]
		if rc.world == null or (r["market"] as StationMarket).world != rc.world:
			return "seed %d: restore did not wire the world into the market" % p_seed
		if RunSave.state_hash(rc, r["market"], r["bags"]) != split.state_hash():
			return "seed %d: hash changed across the save" % p_seed
		var hud := OrbitalHUD.new(rc)
		var lp := M0Loop.new(hud)
		lp.set_market(r["market"])
		lp.sync_hud_to_ship()
		hud.set_station(rc.docked_at)
		for i in 800:
			if lp.overlay_state == M0Loop.OVERLAY_CRISIS:
				lp.acknowledge_crisis()
			lp.advance(Replay.DEFAULT_FRAME_DELTA)
		if RunSave.state_hash(rc, lp.market, r["bags"]) != whole.state_hash():
			return "seed %d: save/load/continue diverged from the uninterrupted run" % p_seed
	return "ok"


func test_a_world_recording_replays_to_the_same_hash() -> String:
	var s: Replay.Session = Replay.start_recording(84, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	s.dispatch(M0Loop.ACT_TAB_NEXT)
	s.advance_frames(40)
	s.dispatch(M0Loop.ACT_RIGHT)
	s.dispatch(M0Loop.ACT_SUBMIT)
	s.advance_frames(400)
	var rec: Dictionary = _json(s.to_recording())
	if not bool(rec.get("world", false)):
		return "a world session's recording does not say so"
	var res: Dictionary = Replay.replay(rec)
	if not bool(res["ok"]):
		return "world replay failed: %s" % res["error"]
	var plain: Dictionary = Replay.start_recording(84, {}, Replay.DEFAULT_FRAME_DELTA, TPR).to_recording()
	return "ok" if not plain.has("world") else "a plain recording gained a world key"
