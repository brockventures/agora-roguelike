extends RefCounted
## Epic 3 task 0 (#111): the travel loop. Depart from the docked station, spend the
## route's time in sim ticks, arrive and dock; the book, the toll, the no-trade
## rule, the save round trip, and the gamepad path with real input events.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FRAME: float = 1.0 / 60.0 + 0.0001
const TMP_ROOT := "user://test_tmp_travel"

## RunSave.state_hash of a run that never travels (seed 84, two trades' worth of play),
## measured on main before the travel loop existed. Travel must not move it.
const NEVER_TRAVELS_HASH := "b30e7504c6f13e8c33288f628cc2337e913462b52f0d7193e635ffa5ddd65afc"


## A docked run on a short round (30 ticks) so a voyage is a few hundred frames.
func _loop(p_seed: int = 21, station: String = "mars") -> Dictionary:
	var rc := RunController.new(null, p_seed, null, {}, 30)
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at(station)
	return {"rc": rc, "hud": hud, "loop": lp}


## Steps the loop n ticks, acknowledging any crisis that stops the clock.
func _run_ticks(lp: M0Loop, rc: RunController, n: int) -> void:
	var target: int = rc.sim_clock.total_ticks + n
	var guard: int = n * 4 + 100
	while rc.sim_clock.total_ticks < target and guard > 0:
		guard -= 1
		if lp.overlay_state == M0Loop.OVERLAY_CRISIS:
			lp.acknowledge_crisis()
		elif lp.overlay_state == M0Loop.OVERLAY_CONTRACT:
			lp.decline_contract()
		lp.advance(FRAME)


func _axis(axis: int, value: float) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = value
	return e


func _btn(index: int) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = index
	e.pressed = true
	return e


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


# --- Hash invariance ---

func test_run_that_never_travels_keeps_its_save_hash() -> String:
	var s := Replay.Session.new(84)
	s.dispatch(M0Loop.ACT_TAB_NEXT)
	s.advance_frames(40)
	s.dispatch(M0Loop.ACT_RIGHT)
	s.dispatch(M0Loop.ACT_SUBMIT)
	s.advance_frames(2000)
	var h: String = s.state_hash()
	if h != NEVER_TRAVELS_HASH:
		return "state hash moved for a run that never travels: %s" % h
	if s.controller.to_dict().has("transit"):
		return "a docked run must not serialise a transit key"
	if s.loop.market.books.size() != 10:
		return "stations other than earth and mars were seeded without travel (%d books)" % s.loop.market.books.size()
	return "ok"


# --- Depart / arrive ---

func test_departure_and_arrival_take_the_routes_time_in_ticks() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	var arrivals: Array = []
	rc.transit_arrived.connect(func(info): arrivals.append(info))
	var want_rounds: int = Transit.calculate_trip_rounds("mars", "earth", 0, 0)
	var res: Dictionary = rc.depart("earth")
	if not bool(res["ok"]):
		return "departure refused: %s" % res["reason"]
	var want_ticks: int = want_rounds * 30
	if int(rc.transit["arrive_tick"]) - int(rc.transit["depart_tick"]) != want_ticks:
		return "voyage is %d ticks, route says %d rounds = %d" % [int(rc.transit["arrive_tick"]) - int(rc.transit["depart_tick"]), want_rounds, want_ticks]
	if rc.docked_at != "" or not rc.is_in_transit():
		return "should be undocked and in transit, docked_at='%s'" % rc.docked_at
	_run_ticks(lp, rc, want_ticks - 1)
	if not rc.is_in_transit() or rc.docked_at != "":
		return "arrived early, one tick short of %d" % want_ticks
	_run_ticks(lp, rc, 1)
	if rc.is_in_transit() or rc.docked_at != "earth":
		return "should have docked at earth after %d ticks, docked_at='%s'" % [want_ticks, rc.docked_at]
	if arrivals.size() != 1 or str(arrivals[0]["destination"]) != "earth":
		return "expected one arrival at earth, got %s" % str(arrivals)
	if rc.sim_clock.total_ticks != want_ticks:
		return "arrived on tick %d, not %d" % [rc.sim_clock.total_ticks, want_ticks]
	return "ok"


func test_transit_time_follows_the_route_table_and_alignment_windows() -> String:
	# earth:luna is 1 round, mars:ceres 2, earth:ceres 3 (outside any window at round 0).
	for pair in [["earth", "luna", 1], ["mars", "ceres", 2], ["earth", "ceres", 3]]:
		var ctx := _loop(21, str(pair[0]))
		var rc: RunController = ctx["rc"]
		var res: Dictionary = rc.depart(str(pair[1]))
		if int(res["rounds"]) != int(pair[2]) or int(res["ticks"]) != int(pair[2]) * 30:
			return "%s -> %s: %d rounds / %d ticks, want %d rounds" % [pair[0], pair[1], int(res["rounds"]), int(res["ticks"]), int(pair[2])]
	# Inside the Earth-Mars window (round 4) the same trip is halved to one round.
	var ctx2 := _loop(21, "mars")
	var rc2: RunController = ctx2["rc"]
	rc2.sim_clock.total_ticks = 4 * 30
	var aligned: Dictionary = rc2.can_depart("earth")
	if int(aligned["rounds"]) != 1:
		return "aligned mars -> earth should be 1 round, got %d" % int(aligned["rounds"])
	return "ok"


func test_departure_refusals_change_nothing() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	if rc.depart("mars")["reason"] != "SAME_STATION":
		return "departing for the docked station should be refused"
	if rc.depart("pluto")["reason"] != "NO_ROUTE":
		return "unknown station should have no route"
	if rc.is_in_transit() or rc.docked_at != "mars":
		return "a refused departure moved the ship"
	rc.depart("earth")
	var before: Dictionary = rc.transit.duplicate()
	if rc.depart("luna")["reason"] != "IN_TRANSIT":
		return "second departure while under way should be refused"
	if rc.transit != before:
		return "second departure replaced the voyage"
	return "ok"


# --- Books ---

func test_arrival_switches_the_hud_to_the_new_stations_book() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	if lp.market.has_book("luna", "ORE"):
		return "luna must not have books before the player has a reason to go there"
	var mars_ladder: Dictionary = hud.get_order_book_ladder()
	hud.set_station("luna")
	if not bool(hud.get_order_book_ladder()["synthetic"]):
		return "an unvisited station should show the synthetic ladder"
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "depart for luna refused: %s" % lp.last_depart_reason
	if not lp.market.has_book("luna", "ORE"):
		return "departure should unlock luna's books"
	_run_ticks(lp, rc, 2 * 30)
	if rc.docked_at != "luna" or hud.active_station != "luna":
		return "docked '%s' active '%s', want luna" % [rc.docked_at, hud.active_station]
	var live: Dictionary = hud.get_order_book_ladder()
	if bool(live["synthetic"]):
		return "luna ladder is still synthetic after arrival"
	var direct: Dictionary = lp.market.ladder("luna", "ORE", hud.order_book_depth_levels)
	if live["best_bid"] != direct["best_bid"] or live["best_ask"] != direct["best_ask"]:
		return "HUD ladder is not luna's book"
	if live["best_ask"] == mars_ladder["best_ask"] and live["best_bid"] == mars_ladder["best_bid"]:
		return "luna quotes equal mars quotes: the book did not switch"
	if hud.get_market_quote()["station"] != "luna":
		return "market quote still names %s" % hud.get_market_quote()["station"]
	# The unlocked books refill through the normal round path.
	var book: OrderBook = lp.market.get_book("luna", "ORE")
	lp.market.execute("luna", "ORE", "BUY", 5, 1000.0)
	var thinned: int = (book.asks[0] as Order).remaining_qty()
	lp.market.replenish()
	var refilled: int = (lp.market.get_book("luna", "ORE").asks[0] as Order).remaining_qty()
	if refilled <= thinned:
		return "replenish() did not refill luna's book (%d -> %d)" % [thinned, refilled]
	return "ok"


func test_trading_works_at_the_new_station_after_arrival() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	hud.set_station("earth")
	lp.dispatch_action(M0Loop.ACT_SUBMIT)
	_run_ticks(lp, rc, 2 * 30)
	lp.set_tab(M0Loop.Tab.MARKET)
	var f: GamepadFocus = hud.gamepad_focus
	f.set_quantity(2)
	f.snap_depth_level(0)
	f.active_side = GamepadFocus.OrderSide.BUY
	var cr0: int = rc.cr
	var res: Dictionary = f.execute_focused_order()
	if not bool(res.get("ok", false)) or str(res["station"]) != "earth" or rc.cr >= cr0:
		return "buy at earth after arriving failed: %s" % str(res)
	return "ok"


# --- Toll ---

func test_belt_routes_charge_the_toll_on_departure_and_others_do_not() -> String:
	var belt := _loop(21, "mars")
	var rc: RunController = belt["rc"]
	var cr0: int = rc.cr
	var res: Dictionary = rc.depart("ceres")
	if not bool(res["ok"]) or int(res["toll"]) != Transit.BELT_TOLL_CR:
		return "mars -> ceres should owe the %d CR belt toll: %s" % [Transit.BELT_TOLL_CR, str(res)]
	if rc.cr != cr0 - Transit.BELT_TOLL_CR:
		return "CR went %d -> %d, expected -%d" % [cr0, rc.cr, Transit.BELT_TOLL_CR]
	var inner := _loop(21, "mars")
	var rc2: RunController = inner["rc"]
	var cr1: int = rc2.cr
	rc2.depart("earth")
	if rc2.cr != cr1:
		return "an inner-system route was charged: %d -> %d" % [cr1, rc2.cr]
	return "ok"


func test_departure_is_refused_when_the_toll_cannot_be_paid() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	rc.cr = Transit.BELT_TOLL_CR - 1
	hud.set_station("ceres")
	if lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "departure should be refused without the toll"
	if lp.last_depart_reason != "INSUFFICIENT_CR" or rc.is_in_transit() or rc.cr != Transit.BELT_TOLL_CR - 1:
		return "refusal changed state: %s cr=%d" % [lp.last_depart_reason, rc.cr]
	if lp.depart_message().find(str(Transit.BELT_TOLL_CR)) < 0:
		return "refusal message does not name the toll: %s" % lp.depart_message()
	return "ok"


# --- No trading in transit ---

func test_no_trades_in_transit() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	rc.cargo = {"ORE": 3}
	rc.depart("earth")
	lp.set_tab(M0Loop.Tab.MARKET)
	var f: GamepadFocus = hud.gamepad_focus
	for station in ["mars", "earth"]:
		hud.set_station(station)
		var cr0: int = rc.cr
		var cargo0: Dictionary = rc.cargo.duplicate()
		for side in [GamepadFocus.OrderSide.BUY, GamepadFocus.OrderSide.SELL]:
			f.active_side = side
			if lp.dispatch_action(M0Loop.ACT_SUBMIT):
				return "an order filled in transit at %s" % station
			if f.last_rejection_reason != "IN_TRANSIT":
				return "rejection at %s was '%s', want IN_TRANSIT" % [station, f.last_rejection_reason]
		if rc.cr != cr0 or rc.cargo != cargo0:
			return "a rejected order changed CR or cargo"
	if GamepadFocus.rejection_message("IN_TRANSIT", f.last_rejection_payload).find("Kennedy Elevator") < 0:
		return "rejection text does not name the destination: %s" % GamepadFocus.rejection_message("IN_TRANSIT", f.last_rejection_payload)
	return "ok"


func test_cargo_carries_across() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	rc.cargo = {"ORE": 7, "FRAG": 2}
	rc.depart("earth")
	_run_ticks(lp, rc, 2 * 30)
	if rc.docked_at != "earth" or rc.cargo != {"ORE": 7, "FRAG": 2}:
		return "cargo changed in transit: %s at '%s'" % [str(rc.cargo), rc.docked_at]
	return "ok"


# --- Replay ---

func test_a_recording_that_travels_replays_to_the_same_hash() -> String:
	var s := Replay.start_recording(77, {}, Replay.DEFAULT_FRAME_DELTA, 30)
	s.advance_frames(10)
	s.dispatch(M0Loop.ACT_STATION_NEXT)  # mars -> ceres
	s.dispatch(M0Loop.ACT_SUBMIT)  # A on the Map tab departs
	s.advance_frames(3 * 30 + 20)
	if s.controller.docked_at != "ceres":
		return "the recorded session never docked at ceres ('%s')" % s.controller.docked_at
	var rec: Dictionary = _json(s.to_recording())
	var res: Dictionary = Replay.replay(rec)
	if not bool(res["ok"]):
		return "replay of a voyage failed: %s" % str(res)
	return "ok"


# --- Save / load ---

func test_transit_survives_a_json_save_round_trip() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	rc.depart("ceres")
	_run_ticks(lp, rc, 20)
	var bags := Bags.new("m0", null, 21)
	var data: Dictionary = _json(RunSave.capture(rc, lp.market, bags))
	var r: Dictionary = RunSave.restore(data)
	if not bool(r["ok"]):
		return "restore failed: %s" % r["error"]
	var rc2: RunController = r["controller"]
	if not rc2.is_in_transit() or rc2.docked_at != "":
		return "loaded run lost its voyage (docked_at='%s')" % rc2.docked_at
	for k in ["origin", "destination", "depart_tick", "arrive_tick", "rounds", "toll"]:
		if str(rc2.transit[k]) != str(rc.transit[k]):
			return "transit.%s %s != %s" % [k, str(rc2.transit[k]), str(rc.transit[k])]
	if RunSave.state_hash(rc2, r["market"], r["bags"]) != RunSave.state_hash(rc, lp.market, bags):
		return "hash changed across the save round trip"
	return "ok"


func test_a_save_taken_mid_voyage_replays_like_one_that_never_stopped() -> String:
	# Run A saves in transit, loads, flies on; run B just keeps flying. They must agree.
	var a := _loop(33)
	var b := _loop(33)
	for ctx in [a, b]:
		ctx["rc"].depart("ceres")
		_run_ticks(ctx["loop"], ctx["rc"], 40)
	var bags_a := Bags.new("m0", null, 33)
	var loaded: Dictionary = RunSave.restore(_json(RunSave.capture(a["rc"], a["loop"].market, bags_a)))
	var rc_a: RunController = loaded["controller"]
	var hud_a := OrbitalHUD.new(rc_a)
	var lp_a := M0Loop.new(hud_a)
	lp_a.set_market(loaded["market"])
	# The loaded run keeps its place: rebinding must not re-dock it.
	if not rc_a.is_in_transit() or rc_a.docked_at != "":
		return "binding a loaded run moved the ship (docked_at='%s')" % rc_a.docked_at
	_run_ticks(lp_a, rc_a, 3 * 30)
	_run_ticks(b["loop"], b["rc"], 3 * 30)
	if rc_a.docked_at != "ceres" or b["rc"].docked_at != "ceres":
		return "did not arrive: %s / %s" % [rc_a.docked_at, b["rc"].docked_at]
	# Controller, bags, crisis deck and the raw market (order ids included) must all
	# match exactly: StationMarket saves and refills in canonical order, so a JSON
	# save/load no longer changes which order gets which id.
	var da: Dictionary = RunSave.capture(rc_a, lp_a.market, loaded["bags"])
	var db: Dictionary = RunSave.capture(b["rc"], b["loop"].market, bags_a)
	for key in ["controller", "bags", "crisis", "market"]:
		if RunSave.canonical(da[key]) != RunSave.canonical(db[key]):
			return "%s diverged between the saved-mid-voyage run and the one that kept flying" % key
	return "ok"


func test_continue_saved_run_resumes_a_voyage_and_a_dock_elsewhere() -> String:
	var dir := "%s/s_%d" % [TMP_ROOT, Time.get_ticks_usec()]
	var store := SaveStore.new(dir)
	var m: MainScene = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	m.start_new_run(9)
	m.enable_persistence(store)
	m.hud.set_station("earth")
	m.loop.dispatch_action(M0Loop.ACT_SUBMIT)
	m.save_all()
	var dest_book_ok: bool = m.loop.market.has_book("earth", "ORE")
	m.free()
	var m2: MainScene = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	m2.enable_persistence(SaveStore.new(dir))
	var ok: bool = m2.continue_saved_run()
	var r: String = "ok"
	if not ok:
		r = "continue_saved_run found no run"
	elif not m2.controller.is_in_transit() or m2.controller.docked_at != "":
		r = "resumed run is not in transit (docked_at='%s')" % m2.controller.docked_at
	elif str(m2.controller.transit["destination"]) != "earth" or m2.hud.active_station != "earth":
		r = "resumed voyage/selection wrong: %s / %s" % [str(m2.controller.transit), m2.hud.active_station]
	elif not dest_book_ok:
		r = "earth book missing"
	else:
		# Fly on to arrival, save again, and resume docked at Earth rather than Mars.
		m2.controller.sim_clock.set_paused(false)
		for i in 2 * m2.controller.ticks_per_round + 5:
			m2.loop.advance(FRAME)
			if m2.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
				m2.loop.acknowledge_crisis()
			elif m2.loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
				m2.loop.decline_contract()
			if not m2.controller.is_in_transit():
				break
		if m2.controller.docked_at != "earth":
			r = "never arrived (docked_at='%s')" % m2.controller.docked_at
		else:
			m2.save_all()
			var m3: MainScene = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
			m3.enable_persistence(SaveStore.new(dir))
			m3.continue_saved_run()
			if m3.controller.docked_at != "earth" or m3.hud.active_station != "earth":
				r = "a run saved docked at earth resumed at '%s' / '%s'" % [m3.controller.docked_at, m3.hud.active_station]
			m3.free()
	m2.free()
	_rm_rf(dir)
	DirAccess.remove_absolute(TMP_ROOT)
	return r


static func _rm_rf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		_rm_rf(path.path_join(sub))
	DirAccess.remove_absolute(path)


func test_old_saves_and_tampered_voyages_load_safely() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var d: Dictionary = _json(rc.to_dict())
	if d.has("transit"):
		return "docked run saved a transit key"
	# A save from before travel: no transit key at all.
	var old: RunController = RunController.from_dict(d)
	if old.docked_at != "mars" or old.is_in_transit():
		return "pre-travel save loaded wrong: '%s'" % old.docked_at
	# Docked_at blank but no voyage: fall back to a real station, never stay undocked forever.
	d["docked_at"] = ""
	if RunController.from_dict(d).docked_at != "earth":
		return "blank dock without a voyage should fall back to earth"
	for bad in [
		{"origin": "mars", "destination": "mars", "depart_tick": 0, "arrive_tick": 10},
		{"origin": "mars", "destination": "pluto", "depart_tick": 0, "arrive_tick": 10},
		{"origin": "mars", "destination": "earth", "depart_tick": 10, "arrive_tick": 5},
		{"origin": "mars", "destination": "earth", "depart_tick": 0, "arrive_tick": 99999999},
		{"origin": "mars", "destination": "earth"},
		"nonsense",
	]:
		d["transit"] = bad
		d["docked_at"] = "mars"
		var t: RunController = RunController.from_dict(d)
		if t.is_in_transit() or t.docked_at != "mars":
			return "tampered voyage %s was accepted" % str(bad)
	return "ok"


func test_filing_chapter_11_mid_voyage_keeps_the_voyage() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	rc.depart("earth")
	rc.pending_bankruptcy = true
	if rc.file_bankruptcy().is_empty():
		return "filing did not happen"
	if not rc.is_in_transit() or rc.docked_at != "":
		return "filing mid-voyage stranded the new corp: docked_at='%s'" % rc.docked_at
	return "ok"


# --- HUD ---

func test_header_and_map_show_the_voyage() -> String:
	var m: MainScene = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	m.start_new_run(4)
	m._resolve_child_nodes()
	m._build_readouts()
	m.controller.sim_clock.pause()
	m._refresh_readouts()
	var docked_header: String = m.panel_text(m.ticket_panel)
	var r: String = "ok"
	if docked_header.find("IN TRANSIT") >= 0:
		r = "header claims transit while docked"
	m.hud.set_station("ceres")
	m.loop.dispatch_action(M0Loop.ACT_SUBMIT)
	m._refresh_readouts()
	if r == "ok" and (m.panel_text(m.ticket_panel).find("IN TRANSIT to Ceres, ETA 2 rounds") < 0):
		r = "ticket lacks the destination and ETA: %s" % m.panel_text(m.ticket_panel)
	if r == "ok" and m.panel_text(m.ticket_panel).find("Depart") >= 0:
		r = "prompts still offer Depart in transit"
	var voyage: Dictionary = m.tactical_map.get_player_transit()
	if r == "ok" and (voyage.is_empty() or str(voyage["destination"]) != "ceres" or not bool(voyage["is_belt"])):
		r = "tactical map has no belt voyage to ceres: %s" % str(voyage)
	if r == "ok" and not m.hud.get_recent_headlines(8).any(func(h): return m.hud.headline_text(h).find("DEPARTS") >= 0):
		r = "no departure headline on the ticker"
	if r == "ok" and not m.hud.get_recent_headlines(9).any(func(h): return m.hud.headline_text(h).find("BELT AUTHORITY") >= 0):
		r = "no belt toll headline on the ticker"
	if r == "ok":
		m.loop.set_tab(M0Loop.Tab.MAP)
		m.controller.transit = {}
		m.controller.docked_at = "mars"
		m._refresh_readouts()
		if m.panel_text(m.ticket_panel).find("Depart") < 0:
			r = "docked Map tab prompts should offer Depart: %s" % m.panel_text(m.ticket_panel)
	m.free()
	return r


func test_map_ship_moves_along_its_lane() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	var hud: OrbitalHUD = ctx["hud"]
	if not hud.tactical_map.get_player_transit().is_empty():
		return "docked ship should not be drawn on a lane"
	rc.depart("ceres")
	var p0: float = float(hud.tactical_map.get_player_transit(0)["progress"])
	_run_ticks(lp, rc, 30)
	var v: Dictionary = hud.tactical_map.get_player_transit(0)
	if p0 != 0.0 or absf(float(v["progress"]) - 0.5) > 0.001:
		return "progress %f -> %f, want 0 -> 0.5" % [p0, float(v["progress"])]
	var mid: Vector2 = (Vector2(v["start_pos"]) + Vector2(v["end_pos"])) * 0.5
	if Vector2(v["pos"]).distance_to(mid) > 0.01:
		return "ship is not halfway along its lane"
	return "ok"


# --- Gamepad, real input events ---

func test_gamepad_selects_a_station_and_departs_then_docks() -> String:
	var m: MainScene = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	m.start_new_run(6)
	m.controller.ticks_per_round = 30
	var rc: RunController = m.controller
	rc.sim_clock.set_paused(false)
	# Right trigger (axis 5): the next station after mars is ceres.
	if not m.handle_input(_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)) or m.hud.active_station != "ceres":
		return "RT did not select the next station (active %s)" % m.hud.active_station
	m.handle_input(_axis(JOY_AXIS_TRIGGER_RIGHT, 0.0))
	# Left trigger (axis 4) steps back, then forward again.
	if not m.handle_input(_axis(JOY_AXIS_TRIGGER_LEFT, 1.0)) or m.hud.active_station != "mars":
		return "LT did not select the previous station (active %s)" % m.hud.active_station
	m.handle_input(_axis(JOY_AXIS_TRIGGER_LEFT, 0.0))
	m.handle_input(_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0))
	m.handle_input(_axis(JOY_AXIS_TRIGGER_RIGHT, 0.0))
	var cr0: int = rc.cr
	if not m.handle_input(_btn(JOY_BUTTON_A)):
		return "A on the Map tab did not depart (%s)" % m.loop.last_depart_reason
	if not rc.is_in_transit() or rc.docked_at != "" or rc.cr != cr0 - Transit.BELT_TOLL_CR - int(rc.transit["fuel_cr"]):
		return "A did not put the ship under way with the toll and fuel paid"
	if int(rc.transit["fuel_burned"]) != 20 or int(rc.transit["fuel_bought"]) != 20 or int(rc.transit["fuel_cr"]) <= 0:
		return "Mars -> Ceres should burn and buy 20 FUEL, got %s" % str(rc.transit)
	# Trading keys do nothing useful on the map; the Market tab refuses orders in transit.
	m.handle_input(_btn(JOY_BUTTON_RIGHT_SHOULDER))
	if m.loop.tab_name() != "MARKET":
		return "RB should open the Market tab"
	if m.handle_input(_btn(JOY_BUTTON_A)) or m.hud.gamepad_focus.last_rejection_reason != "IN_TRANSIT":
		return "A on the Market tab in transit should be rejected as IN_TRANSIT, got '%s'" % m.hud.gamepad_focus.last_rejection_reason
	m.handle_input(_btn(JOY_BUTTON_LEFT_SHOULDER))
	# Fly to arrival through the real frame path.
	for i in 3 * 30:
		m._process(FRAME)
		if m.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			m.loop.acknowledge_crisis()
		elif m.loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			m.loop.decline_contract()
		if not rc.is_in_transit():
			break
	var r: String = "ok"
	if rc.docked_at != "ceres" or m.hud.active_station != "ceres":
		r = "did not dock at ceres (docked '%s', active '%s')" % [rc.docked_at, m.hud.active_station]
	m.free()
	return r


func test_pressing_a_for_the_docked_station_does_nothing() -> String:
	var m: MainScene = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	m.start_new_run(6)
	if m.handle_input(_btn(JOY_BUTTON_A)):
		return "A with the docked station selected should not depart"
	var r: String = "ok"
	if m.controller.is_in_transit() or m.loop.last_depart_reason != "SAME_STATION":
		r = "expected a SAME_STATION refusal, got '%s'" % m.loop.last_depart_reason
	m.free()
	return r
