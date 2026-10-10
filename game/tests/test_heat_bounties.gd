extends RefCounted
## Epic 3 task 11 (part of #18, Rival Syndicate Fleets): front-running, privateer bounties,
## per-baron heat and the consequence events it queues (docs/design/epic3-barons.md 6.1,
## 6.2, 6.3 and 7, decision 9.4). The data and its validation, the front-run (a depth mod
## on arrival plus one GalNet line, reacting only to the player's departure), the bounty
## through Piracy.hire under the doc's conditions, heat (raised by a lever that fires,
## decaying, reset by a filing), the `origin` field, the lethal guard on random events,
## consequence events bypassing Bags and never touching doomsday ticks, determinism, and the
## UI. Whole-world replay goldens are task 12 and are NOT here.

const TPR: int = 30
const ARES: String = "ares_heavy"
const SOL: String = "sol_central"
const KESSLER: String = "kessler_freight"
const BLACKWATER: String = "blackwater_lines"


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


## A world, its books and a crisis deck on a 30-tick round, docked at Mars.
func _ctx(p_seed: int = 21, cr: int = 100000, cfg: Dictionary = {}) -> Dictionary:
	var rc := RunController.new(null, p_seed, null, {}, TPR)
	rc.world = Barons.for_new_run()
	for k in cfg:
		rc.world.data["rivals"][k] = cfg[k]
	rc.crisis_deck = CrisisDeck.new(p_seed)
	rc.cr = cr
	rc.docked_at = "mars"
	var m := StationMarket.new()
	m.set_world(rc.world)
	m.set_world_mods(rc.world.market_mods())
	return {"rc": rc, "w": rc.world, "m": m, "deck": rc.crisis_deck}


## One round boundary as M0Loop runs it: the world step, its mods, the reseed, the fleets.
func _boundary(c: Dictionary, r: int) -> Array:
	var rc: RunController = c["rc"]
	var m: StationMarket = c["m"]
	rc.sim_clock.total_ticks = r * TPR
	var ev: Array = (c["w"] as Barons).advance_round(r, rc, m)
	m.set_world_mods((c["w"] as Barons).market_mods())
	m.replenish()
	ev.append_array((c["w"] as Barons).advance_rivals(r, rc, m))
	return ev


func _kinds(events: Array) -> Array:
	var out: Array = []
	for e in events:
		out.append(str(e["kind"]))
	return out


func _depart(c: Dictionary, origin: String, dest: String, cargo: Dictionary) -> Array:
	var rc: RunController = c["rc"]
	rc.cargo = cargo
	var rounds: int = int(Transit.get_route(origin, dest, 0)["rounds"])
	return (c["w"] as Barons).react_to_departure(rc, c["m"], {"origin": origin, "destination": dest, "rounds": rounds})


func _bid_units(m: StationMarket, station: String, com: String) -> int:
	var n: int = 0
	for o: Order in m.get_book(station, com).bids:
		n += o.remaining_qty()
	return n


func _principal(rc: RunController) -> int:
	return rc.doomsday.principal_debt


# --- data ---

func test_the_shipped_data_validates_and_new_keys_are_checked() -> String:
	var errs: Array = Barons.validate(Barons.load_data())
	if not errs.is_empty():
		return "barons.json invalid: %s" % str(errs)
	var w := Barons.new()
	var h: Dictionary = Heat.settings(w)
	if int(h["retaliation_at"]) != 6 or int(h["corner_round"]) != 2 or Heat.random_event_bps(w) != 0:
		return "heat settings wrong: %s" % str(h)
	var cases := {
		"heat key": func(d: Dictionary): d["heat"]["warp"] = 1,
		"heat value": func(d: Dictionary): d["heat"]["corner_round"] = -1,
		"random bps": func(d: Dictionary): d["consequence"]["random_event_bps"] = 10001,
		"rival setting": func(d: Dictionary): d["rivals"]["front_run_depth_bps"] = 10001,
		"rival unknown": func(d: Dictionary): d["rivals"]["bounty_warp"] = 1,
	}
	for name in cases:
		var d: Dictionary = _json(Barons.load_data())
		(cases[name] as Callable).call(d)
		if Barons.validate(d).is_empty():
			return "a bad %s passed validation" % name
	return "ok"


func test_crises_json_carries_origin_and_a_default_of_random() -> String:
	var data: Dictionary = CrisisDeck.load_data()
	var cons: int = 0
	var rnd: int = 0
	for d in data["crises"]:
		var origin: String = str(d.get("origin", "random"))
		if not (origin in Heat.ORIGINS):
			return "%s: origin '%s'" % [d["id"], origin]
		if str(d["tier"]) == "baron":
			if str(d["kind"]) != "baron_event" or not d["effects"].has("fine_bps") or not (str(d["baron_archetype"]) in Barons.ARCHETYPES):
				return "baron entry %s is malformed" % d["id"]
			cons += 1 if origin == "consequence" else 0
			rnd += 1 if origin == "random" else 0
		elif d.has("origin"):
			return "the old random crises should not need an origin: %s" % d["id"]
	if cons != 3 or rnd != 3:
		return "want a consequence and a random entry per archetype, got %d and %d" % [cons, rnd]
	for a in Barons.ARCHETYPES:
		if Heat.event_def(data, a, "consequence").is_empty() or Heat.event_def(data, a, "random").is_empty():
			return "no entry for %s" % a
	return "ok"


func test_a_baron_event_is_never_in_the_weighted_pool() -> String:
	var deck := CrisisDeck.new(5)
	for tier in ["early", "mid", "endgame", "baron"]:
		for band in CrisisDeck.BAND_ORDER:
			for d in deck.eligible(tier, band):
				if str(d.get("origin", "random")) != "random" or str(d["tier"]) == "baron":
					return "%s/%s drew a baron event: %s" % [tier, band, d["id"]]
	return "ok"


# --- hash safety ---

func test_a_random_crisis_instance_and_a_quiet_world_carry_no_new_keys() -> String:
	var deck := CrisisDeck.new(5)
	var def: Dictionary = {}
	for d in deck.data["crises"]:
		if str(d["id"]) == "localized_shortage":
			def = d
	var inst: Dictionary = deck._instantiate(def, 3, 9000, "mid", NativeDrawSource.new(1))
	if inst.has("origin") or inst.has("baron"):
		return "a random crisis gained keys: %s" % str(inst.keys())
	var back: Dictionary = CrisisDeck._sanitise(inst)
	if back.has("origin") or back.has("baron"):
		return "sanitise added keys to a random crisis"
	var w := Barons.new()
	var d: Dictionary = w.to_dict()
	if d.has("bounties"):
		return "a world nobody hired against saves bounties"
	for id in w.rival_ids():
		if (w.rival(id).to_dict() as Dictionary).has("front"):
			return "a fleet that never front-ran saves a front key"
	for id in w.ids():
		if w.state(id).heat != 0 or w.state(id).scratch.has("retaliate"):
			return "a baron opens with heat"
	return "ok"


func test_nothing_the_player_does_not_start_raises_heat_or_hires_a_bounty() -> String:
	var c := _ctx(84, 50000, {"decide_chance_bps": 10000})
	var w: Barons = c["w"]
	for r in range(1, 41):
		_boundary(c, r)
	for id in w.ids():
		if w.state(id).heat != 0:
			return "%s heat %d in a run the player did not touch" % [id, w.state(id).heat]
	if not w.bounty_on_player(40).is_empty() or not (c["deck"] as CrisisDeck).active.filter(func(x): return x.has("origin")).is_empty():
		return "a bounty or consequence appeared unprompted"
	return "ok"


# --- front-running ---

func test_a_front_runner_sails_to_the_destination_and_dents_its_book_on_arrival() -> String:
	var c := _ctx(21, 50000, {"front_run_chance_bps": 10000, "decide_chance_bps": 0})
	var w: Barons = c["w"]
	var m: StationMarket = c["m"]
	var f: RivalFleet = w.rival(KESSLER)
	var cr0: int = f.cr
	var fresh_bids: int = _bid_units(m, "mars", "ORE")
	var ev: Array = _depart(c, "earth", "mars", {"ORE": 80})  # 80 x 19.25 = 1540 CR, 2 rounds
	if not f.in_flight() or int(f.route.get("front", 0)) != 1 or str(f.route["destination"]) != "mars" or str(f.route["commodity"]) != "ORE":
		return "kessler did not pre-position: %s %s" % [str(f.route), str(_kinds(ev))]
	if int(f.route["arrival_round"]) != 2 or f.cr >= cr0:
		return "arrival %d or fuel not paid (cr %d -> %d)" % [int(f.route["arrival_round"]), cr0, f.cr]
	if _kinds(ev).has("rival_frontrun") or not w.market_mods().filter(func(x): return int(x.get("depth_bps", 10000)) != 10000).is_empty():
		return "the dent or the line came at departure; both belong to the arrival"
	var ev1: Array = _boundary(c, 1)
	if _kinds(ev1).has("rival_frontrun"):
		return "front-run line a round early"
	var ev2: Array = _boundary(c, 2)
	var line: Dictionary = {}
	for e in ev2:
		if str(e["kind"]) == "rival_frontrun":
			line = e
	if line.is_empty() or str(line["fleet"]) != KESSLER or str(line["station"]) != "mars" or not bool(line["arrived"]):
		return "no arrival line at round 2: %s" % str(_kinds(ev2))
	if f.front.is_empty() or f.in_flight() or f.at != "mars" or int(f.front["until_round"]) != 4:
		return "front state after arrival: %s at %s" % [str(f.front), f.at]
	var mods: Array = w.market_mods()
	var last: Dictionary = mods[mods.size() - 1]
	if str(last["station"]) != "mars" or str(last["commodity"]) != "ORE" or int(last["depth_bps"]) != 6000:
		return "the dent is not the last mod: %s" % str(last)
	var dented: int = _bid_units(m, "mars", "ORE")
	if dented >= fresh_bids:
		return "the Mars ORE bids were not dented (%d vs %d)" % [dented, fresh_bids]
	_boundary(c, 3)
	if f.front.is_empty() or _bid_units(m, "mars", "ORE") >= fresh_bids:
		return "the dent did not last the second round"
	_boundary(c, 4)
	if not f.front.is_empty():
		return "the dent outlived its %d rounds" % int(Rivals.settings(w)["front_run_rounds"])
	return "ok"


func test_the_front_run_line_reaches_galnet_and_the_desk_tags_the_book() -> String:
	var rc := RunController.new(null, 21, null, {}, TPR)
	rc.world = Barons.for_new_run()
	rc.world.data["rivals"]["front_run_chance_bps"] = 10000
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("earth")
	rc.cargo = {"ORE": 80}
	rc.sim_clock.total_ticks = 0
	lp.market.unlock_station("mars")
	lp._on_transit_departed({"origin": "earth", "destination": "mars", "rounds": 2, "toll": 0})
	if rc.world.rival(KESSLER).front.is_empty() and int(rc.world.rival(KESSLER).route.get("front", 0)) != 1:
		return "kessler did not front-run through the loop"
	rc.sim_clock.total_ticks = 2 * TPR
	lp._on_round_advanced(2)
	var found: String = ""
	for h in hud.galnet_headlines:
		if hud.headline_text(h).contains("front-runs"):
			found = hud.headline_text(h)
	if found == "" or not found.contains("KESSLER") or not found.contains("ORE") or not found.contains("ARCADIA FOUNDRIES"):
		return "the front-run line is missing or wrong: %s" % found
	if lp.rival_tag("mars", "ORE") != "KESSLER FRONT-RUN -40% DEPTH":
		return "tag '%s'" % lp.rival_tag("mars", "ORE")
	if lp.rival_tag("mars", "FRAG").contains("FRONT"):
		return "the tag shows on a book it did not dent"
	return "ok"


func test_a_front_runner_only_reacts_to_a_departure_that_it_can_beat() -> String:
	# A trip it cannot beat: Mars to Ceres is 2 rounds, Earth to Ceres is 3.
	var c := _ctx(21, 50000, {"front_run_chance_bps": 10000})
	(c["m"] as StationMarket).unlock_station("ceres")
	_depart(c, "mars", "ceres", {"ORE": 80})
	var f: RivalFleet = (c["w"] as Barons).rival(KESSLER)
	if int(f.route.get("front", 0)) == 1 or not f.front.is_empty():
		return "kessler front-ran a trip it could not beat"
	# A hold worth less than the floor.
	var c2 := _ctx(21, 50000, {"front_run_chance_bps": 10000})
	_depart(c2, "earth", "mars", {"ORE": 10})
	if int((c2["w"] as Barons).rival(KESSLER).route.get("front", 0)) == 1:
		return "kessler front-ran a hold under the floor"
	# An empty purse.
	var c3 := _ctx(21, 50000, {"front_run_chance_bps": 10000})
	(c3["w"] as Barons).rival(KESSLER).cr = 500
	_depart(c3, "earth", "mars", {"ORE": 80})
	if int((c3["w"] as Barons).rival(KESSLER).route.get("front", 0)) == 1:
		return "kessler front-ran without the cash"
	# The chance is its own draw: at 0 it never fires, and the ordinary reaction is untouched.
	var c4 := _ctx(21, 50000, {"front_run_chance_bps": 0, "react_chance_bps": 10000})
	_depart(c4, "earth", "mars", {"ORE": 80})
	var k: RivalFleet = (c4["w"] as Barons).rival(KESSLER)
	if int(k.route.get("front", 0)) == 1 or not k.front.is_empty():
		return "a zero-chance front-run fired"
	if not k.in_flight():
		return "the ordinary reaction did not run when the front-run declined"
	# Only the trait front_run: the other fleets never do.
	var c5 := _ctx(21, 50000, {"front_run_chance_bps": 10000})
	_depart(c5, "earth", "mars", {"ORE": 80})
	for id in [BLACKWATER, "ember_haulage"]:
		var o: RivalFleet = (c5["w"] as Barons).rival(id)
		if int(o.route.get("front", 0)) == 1 or not o.front.is_empty():
			return "%s is not a front_runner" % id
	return "ok"


func test_no_front_run_without_a_departure() -> String:
	# It cannot read resting orders (the player has none) and has no other trigger: the
	# round step alone, with the hold full, never front-runs.
	var c := _ctx(84, 50000, {"decide_chance_bps": 10000, "front_run_chance_bps": 10000, "react_chance_bps": 10000})
	(c["rc"] as RunController).cargo = {"ORE": 100}
	var w: Barons = c["w"]
	for r in range(1, 41):
		_boundary(c, r)
		for id in w.rival_ids():
			if int(w.rival(id).route.get("front", 0)) == 1 or not w.rival(id).front.is_empty():
				return "round %d: %s front-ran with no departure" % [r, id]
	return "ok"


func test_a_fleet_already_docked_at_the_destination_starts_at_once() -> String:
	var c := _ctx(21, 50000, {"front_run_chance_bps": 10000})
	var w: Barons = c["w"]
	var f: RivalFleet = w.rival(KESSLER)
	f.at = "mars"
	var cr0: int = f.cr
	var ev: Array = _depart(c, "earth", "mars", {"ORE": 80})
	if not _kinds(ev).has("rival_frontrun") or f.in_flight() or f.front.is_empty() or f.cr != cr0:
		return "docked fleet: %s front %s cr %d" % [str(_kinds(ev)), str(f.front), f.cr]
	if int(f.front["until_round"]) != 3:
		return "the dent should cover the next two reseeds, until round 3: %s" % str(f.front)
	return "ok"


func test_front_run_state_round_trips_and_is_deterministic() -> String:
	var a := _ctx(21, 50000, {"front_run_chance_bps": 10000})
	var b := _ctx(21, 50000, {"front_run_chance_bps": 10000})
	_depart(a, "earth", "mars", {"ORE": 80})
	_depart(b, "earth", "mars", {"ORE": 80})
	for r in range(1, 4):
		_boundary(a, r)
		_boundary(b, r)
	var wa: Barons = a["w"]
	if RunSave.canonical(wa.to_dict()) != RunSave.canonical((b["w"] as Barons).to_dict()):
		return "two identical runs differ"
	var back: Barons = Barons.from_dict(_json(wa.to_dict()))
	if RunSave.canonical(back.to_dict()) != RunSave.canonical(wa.to_dict()):
		return "the world changed across JSON"
	if typeof(back.rival(KESSLER).front["until_round"]) != TYPE_INT or back.market_mods() != wa.market_mods():
		return "the restored world emits other mods or non-int fields"
	return "ok"


# --- privateer bounties ---

func test_a_privateer_sponsor_hires_through_piracy_hire_on_a_valuable_belt_haul() -> String:
	var c := _ctx(21, 50000, {"bounty_chance_bps": 10000, "react_chance_bps": 0, "decide_chance_bps": 0})
	var w: Barons = c["w"]
	var f: RivalFleet = w.rival(BLACKWATER)
	var cr0: int = f.cr
	(c["m"] as StationMarket).unlock_station("ceres")
	var ev: Array = _depart(c, "mars", "ceres", {"MACHINERY": 80})  # 80 x 21.2 = 1696 CR, a belt lane
	var hire: Dictionary = {}
	for e in ev:
		if str(e["kind"]) == "rival_bounty":
			hire = e
	if hire.is_empty() or str(hire["fleet"]) != BLACKWATER:
		return "no bounty event: %s" % str(_kinds(ev))
	if f.cr != cr0 - Piracy.PRIV_COST:
		return "the sponsor paid %d, want %d" % [cr0 - f.cr, Piracy.PRIV_COST]
	var k: Dictionary = w.bounty_on_player(0)
	if k.is_empty() or str(k["sponsor"]) != BLACKWATER or str(k["target"]) != "player" or int(k["expires_round"]) != Piracy.PRIV_ROUNDS:
		return "contract %s" % str(k)
	if not w.bounty_on_player(Piracy.PRIV_ROUNDS).is_empty():
		return "the contract outlived its 20 rounds"
	if w.bounty_raid_odds_bps(5) != 1500 or w.bounty_raid_odds_bps(Piracy.PRIV_ROUNDS + 1) != 0:
		return "raid odds add %d" % w.bounty_raid_odds_bps(5)
	# One contract per sponsor and per target: a second departure hires nothing more.
	var cr1: int = f.cr
	var ev2: Array = (c["w"] as Barons).react_to_departure(c["rc"], c["m"], {"origin": "mars", "destination": "ceres", "rounds": 2})
	if _kinds(ev2).has("rival_bounty") or f.cr != cr1:
		return "a second contract was hired"
	return "ok"


func test_the_hired_contract_is_the_existing_plus_point_one_five_raid_odds() -> String:
	var c := _ctx(21, 50000, {"bounty_chance_bps": 10000, "react_chance_bps": 0, "decide_chance_bps": 0})
	var w: Barons = c["w"]
	(c["m"] as StationMarket).unlock_station("ceres")
	_depart(c, "mars", "ceres", {"MACHINERY": 80})
	var desk := Piracy.new([0.10, 0.10], null, null, 1)
	desk.load_privateer_contracts(_json(w.desk().privateer_contracts()))
	var with_c: Dictionary = desk.chance("player", "mars", "ceres", true, "MACHINERY", 80, false, 3)
	var plain := Piracy.new([0.10, 0.10], null, null, 1)
	var without: Dictionary = plain.chance("player", "mars", "ceres", true, "MACHINERY", 80, false, 3)
	if not bool(with_c["privateers"]) or bool(without["privateers"]):
		return "the desk does not see the contract: %s" % str(with_c)
	if absf(float(with_c["odds"]) - float(without["odds"]) - Piracy.PRIV_ADD) > 0.0002:
		return "odds %f vs %f, want +%f" % [float(with_c["odds"]), float(without["odds"]), Piracy.PRIV_ADD]
	return "ok"


func test_the_bounty_conditions_each_hold() -> String:
	# Not a belt lane.
	var a := _ctx(21, 50000, {"bounty_chance_bps": 10000, "react_chance_bps": 0, "decide_chance_bps": 0})
	_depart(a, "earth", "mars", {"MACHINERY": 80})
	if not (a["w"] as Barons).bounty_on_player(0).is_empty():
		return "a bounty on a non-belt lane"
	# A hold under the floor (1500 CR placeholder).
	var b := _ctx(21, 50000, {"bounty_chance_bps": 10000, "react_chance_bps": 0, "decide_chance_bps": 0})
	(b["m"] as StationMarket).unlock_station("ceres")
	_depart(b, "mars", "ceres", {"MACHINERY": 50})  # 1060 CR
	if not (b["w"] as Barons).bounty_on_player(0).is_empty():
		return "a bounty on a hold under the floor"
	# A sponsor that cannot afford PRIV_COST.
	var d := _ctx(21, 50000, {"bounty_chance_bps": 10000, "react_chance_bps": 0, "decide_chance_bps": 0})
	(d["m"] as StationMarket).unlock_station("ceres")
	(d["w"] as Barons).rival(BLACKWATER).cr = Piracy.PRIV_COST - 1
	_depart(d, "mars", "ceres", {"MACHINERY": 80})
	if not (d["w"] as Barons).bounty_on_player(0).is_empty():
		return "a sponsor without PRIV_COST hired"
	# Only a privateer_sponsor: with Blackwater out, nobody hires.
	var e := _ctx(21, 50000, {"bounty_chance_bps": 10000, "react_chance_bps": 0, "decide_chance_bps": 0})
	(e["m"] as StationMarket).unlock_station("ceres")
	(e["w"] as Barons).rival(BLACKWATER).cr = 0
	(e["w"] as Barons).rival("ember_haulage").cr = 100000
	(e["w"] as Barons).rival(KESSLER).cr = 100000
	_depart(e, "mars", "ceres", {"MACHINERY": 80})
	if not (e["w"] as Barons).bounty_on_player(0).is_empty():
		return "a fleet without the trait hired"
	# The chance is its own draw.
	var g := _ctx(21, 50000, {"bounty_chance_bps": 0})
	(g["m"] as StationMarket).unlock_station("ceres")
	_depart(g, "mars", "ceres", {"MACHINERY": 80})
	if not (g["w"] as Barons).bounty_on_player(0).is_empty():
		return "a zero-chance bounty fired"
	return "ok"


func test_heat_lowers_the_value_floor_rival_targeting_reads() -> String:
	var cold := _ctx(21, 50000, {"bounty_chance_bps": 10000, "react_chance_bps": 0, "decide_chance_bps": 0})
	(cold["m"] as StationMarket).unlock_station("ceres")
	_depart(cold, "mars", "ceres", {"MACHINERY": 60})  # 1272 CR, under the 1500 floor
	if not (cold["w"] as Barons).bounty_on_player(0).is_empty():
		return "a bounty with no heat on a thin hold"
	var hot := _ctx(21, 50000, {"bounty_chance_bps": 10000, "react_chance_bps": 0, "decide_chance_bps": 0})
	(hot["m"] as StationMarket).unlock_station("ceres")
	(hot["w"] as Barons).raise_heat(ARES, 4)  # floor 1500 - 4 x 150 = 900
	_depart(hot, "mars", "ceres", {"MACHINERY": 60})
	if (hot["w"] as Barons).bounty_on_player(0).is_empty():
		return "heat did not lower the floor"
	return "ok"


func test_a_bounty_is_secret_until_it_is_traced() -> String:
	var c := _ctx(21, 50000, {"bounty_chance_bps": 10000, "bounty_trace_bps": 0})
	var w: Barons = c["w"]
	(c["m"] as StationMarket).unlock_station("ceres")
	_depart(c, "mars", "ceres", {"MACHINERY": 80})
	var seen: bool = false
	for r in range(1, 21):
		if _kinds(w.advance_round(r, c["rc"], c["m"])).has("rival_bounty_traced"):
			seen = true
	if seen or int(w.bounty_on_player(5).get("traced", 0)) != 0:
		return "traced at 0 bps"
	var c2 := _ctx(21, 50000, {"bounty_chance_bps": 10000, "bounty_trace_bps": 10000})
	var w2: Barons = c2["w"]
	(c2["m"] as StationMarket).unlock_station("ceres")
	_depart(c2, "mars", "ceres", {"MACHINERY": 80})
	var ev2: Array = w2.advance_round(1, c2["rc"], c2["m"])
	if not _kinds(ev2).has("rival_bounty_traced") or int(w2.bounty_on_player(1)["traced"]) != 1:
		return "not traced at 10000 bps: %s" % str(_kinds(ev2))
	if _kinds(w2.advance_round(2, c2["rc"], c2["m"])).has("rival_bounty_traced"):
		return "traced twice"
	return "ok"


func test_bounty_contracts_survive_a_save() -> String:
	var c := _ctx(21, 50000, {"bounty_chance_bps": 10000, "react_chance_bps": 0, "decide_chance_bps": 0})
	var w: Barons = c["w"]
	(c["m"] as StationMarket).unlock_station("ceres")
	_depart(c, "mars", "ceres", {"MACHINERY": 80})
	var d: Dictionary = w.to_dict()
	if not d.has("bounties"):
		return "the contract is not saved"
	var back: Barons = Barons.from_dict(_json(d))
	if RunSave.canonical(back.to_dict()) != RunSave.canonical(d):
		return "the world changed across JSON"
	var k: Dictionary = back.bounty_on_player(3)
	if k.is_empty() or typeof(k["expires_round"]) != TYPE_INT or int(k["fee"]) != Piracy.PRIV_COST:
		return "restored contract %s" % str(k)
	return "ok"


func test_the_player_can_sponsor_a_bounty_against_a_rival_and_it_heats_the_dock() -> String:
	var c := _ctx(21, 5000)
	var rc: RunController = c["rc"]
	var w: Barons = c["w"]
	var res: Dictionary = w.sponsor_bounty(rc, KESSLER)  # Kessler is docked at Earth: Sol Central's
	if not bool(res["ok"]) or rc.cr != 5000 - Piracy.PRIV_COST or str(res["baron"]) != SOL:
		return "sponsor %s cr %d" % [str(res), rc.cr]
	if w.heat_of(SOL) != 3 or w.heat_of(ARES) != 0:
		return "heat sol %d ares %d" % [w.heat_of(SOL), w.heat_of(ARES)]
	var again: Dictionary = w.sponsor_bounty(rc, KESSLER)
	if bool(again["ok"]) or rc.cr != 5000 - Piracy.PRIV_COST:
		return "a second contract was hired: %s" % str(again)
	rc.cr = 100
	if bool(w.sponsor_bounty(rc, BLACKWATER)["ok"]) or rc.cr != 100:
		return "hired without the CR"
	if bool(w.sponsor_bounty(rc, "nobody")["ok"]):
		return "hired against a fleet that does not exist"
	return "ok"


# --- heat ---

func test_a_corner_round_raises_heat_and_it_decays_a_round() -> String:
	var c := _ctx(21)
	var rc: RunController = c["rc"]
	var w: Barons = c["w"]
	rc.cargo = {"ORE": 60}
	_boundary(c, 1)
	if w.heat_of(ARES) != 1:  # +2 for the corner round, -1 decay
		return "heat %d after one corner round, want 1" % w.heat_of(ARES)
	_boundary(c, 2)
	if w.heat_of(ARES) != 2:
		return "heat %d after two, want 2" % w.heat_of(ARES)
	rc.cargo = {}
	_boundary(c, 3)
	_boundary(c, 4)
	if w.heat_of(ARES) != 0:
		return "heat %d two rounds after the corner ended, want 0" % w.heat_of(ARES)
	for id in [SOL, "titan_cryo_hydro"]:
		if w.heat_of(id) != 0:
			return "%s took heat for a corner it was not in" % id
	return "ok"


func test_a_sale_alone_raises_no_heat_but_the_margin_call_it_causes_does() -> String:
	var c := _ctx(21)
	var w: Barons = c["w"]
	w.record_trade("mars", "ORE", "SELL", 50)
	if w.heat_of(ARES) != 0:
		return "pressure accrual raised heat"
	var ev: Array = _boundary(c, 1)
	if not _kinds(ev).has("lever_margin"):
		return "no margin call: %s" % str(_kinds(ev))
	if w.heat_of(ARES) != 2:  # +3 for the call, -1 decay
		return "heat %d after the call, want 2" % w.heat_of(ARES)
	return "ok"


func test_the_credit_line_and_its_default_raise_heat() -> String:
	var c := _ctx(21)
	var rc: RunController = c["rc"]
	var w: Barons = c["w"]
	w.state(ARES).treasury_cr = 1000  # pressed
	var res: Dictionary = w.open_credit(rc, "mars")
	if not bool(res["ok"]) or w.heat_of(ARES) != 1:
		return "open: %s heat %d" % [str(res), w.heat_of(ARES)]
	w.state(ARES).treasury_cr = 0
	var due: int = int(res["due_round"])
	for r in range(1, due + 1):
		_boundary(c, r)
	if w.state(ARES).debt_cr <= 0:
		return "the line did not default"
	if w.heat_of(ARES) != 2:  # +3 for the default, -1 decay
		return "heat %d after a default, want 2" % w.heat_of(ARES)
	return "ok"


func test_a_missed_contract_raises_heat() -> String:
	var c := _ctx(21)
	var rc: RunController = c["rc"]
	var w: Barons = c["w"]
	var res: Dictionary = AresHeavy._miss(w, ARES, {"commodity": "ORE", "qty": 40, "unit_px": 20}, rc, 9)
	if w.heat_of(ARES) != 4 or not bool(res.has("penalty")):
		return "heat %d after a missed contract" % w.heat_of(ARES)
	return "ok"


func test_a_held_baron_takes_no_heat() -> String:
	var c := _ctx(21)
	var w: Barons = c["w"]
	w.state(ARES).holder = "player"
	if w.raise_heat(ARES, 5) != 0 or w.heat_of(ARES) != 0:
		return "a held baron took heat"
	w.state(ARES).holder = ""
	w.raise_heat(ARES, 5)
	w.state(ARES).holder = "kessler_freight"
	_boundary(c, 1)
	if w.heat_of(ARES) != 0:
		return "heat survived a takeover"
	return "ok"


func test_heat_decays_by_the_configured_amount() -> String:
	var c := _ctx(21)
	var w: Barons = c["w"]
	w.raise_heat(ARES, 4)
	var r: int = 0
	for want in [3, 2, 1, 0, 0]:
		r += 1
		_boundary(c, r)
		if w.heat_of(ARES) != want:
			return "round %d: heat %d, want %d" % [r, w.heat_of(ARES), want]
	var w2 := Barons.new()
	w2.data["heat"]["decay_per_round"] = 2
	w2.raise_heat(ARES, 5)
	Heat.advance(w2, 1, null)
	if w2.heat_of(ARES) != 3:
		return "decay of 2 left %d, want 3" % w2.heat_of(ARES)
	return "ok"


func test_a_filing_zeroes_heat_the_queue_the_bounties_and_the_live_retaliation() -> String:
	var c := _ctx(21, 100000, {"bounty_chance_bps": 10000, "react_chance_bps": 0, "decide_chance_bps": 0})
	var rc: RunController = c["rc"]
	var w: Barons = c["w"]
	var deck: CrisisDeck = c["deck"]
	(c["m"] as StationMarket).unlock_station("ceres")
	_depart(c, "mars", "ceres", {"MACHINERY": 80})
	w.raise_heat(ARES, 9)
	_boundary(c, 1)  # queues
	_boundary(c, 2)  # lands
	if deck.active.filter(func(x): return str(x.get("origin", "")) == "consequence").is_empty():
		return "no retaliation to clear"
	w.raise_heat(SOL, 2)
	rc.doomsday.add_principal(10000000)
	var rep: Dictionary = rc.file_bankruptcy()
	if rep.is_empty():
		return "the corp could not file"
	for id in w.ids():
		if w.heat_of(id) != 0 or not Heat.queued(w, id).is_empty():
			return "%s kept its grudge across the filing" % id
	if not w.bounty_on_player(3).is_empty():
		return "the bounty on the failed corp survived"
	if not deck.active.filter(func(x): return str(x.get("origin", "")) == "consequence").is_empty() or deck.has_pending_ack():
		return "the retaliation on the failed corp survived"
	return "ok"


# --- retaliation: the consequence event ---

## A world primed to retaliate: heat at the line, then two boundaries (queue, land).
func _retaliation(p_seed: int = 21, cr: int = 100000) -> Dictionary:
	var c := _ctx(p_seed, cr)
	(c["w"] as Barons).raise_heat(ARES, 9)  # one decay leaves it past retaliation_at
	return c


func test_at_the_threshold_the_baron_queues_then_the_event_lands_next_round() -> String:
	var c := _retaliation()
	var w: Barons = c["w"]
	var deck: CrisisDeck = c["deck"]
	var ev: Array = _boundary(c, 1)
	if not _kinds(ev).has("heat_queued") or Heat.queued(w, ARES).is_empty() or int(Heat.queued(w, ARES)["due"]) != 2:
		return "not queued: %s %s" % [str(_kinds(ev)), str(w.state(ARES).scratch)]
	if not deck.active.is_empty() or w.heat_of(ARES) != 8:
		return "the event landed with the warning, or heat reset early (%d)" % w.heat_of(ARES)
	var principal0: int = _principal(c["rc"])
	var ev2: Array = _boundary(c, 2)
	if not _kinds(ev2).has("retaliation"):
		return "no retaliation at round 2: %s" % str(_kinds(ev2))
	if deck.active.size() != 1 or str(deck.active[0]["id"]) != "ares_retaliation" or str(deck.active[0]["origin"]) != "consequence":
		return "active %s" % str(deck.active)
	var inst: Dictionary = deck.active[0]
	if str(inst["station"]) != "mars" or not deck.has_pending_ack() or deck.draw_count != 0:
		return "instance %s pending %s draws %d" % [str(inst), str(deck.has_pending_ack()), deck.draw_count]
	if w.heat_of(ARES) != 0 or not Heat.queued(w, ARES).is_empty():
		return "heat %d or queue not cleared after the event" % w.heat_of(ARES)
	var fine: int = int(inst["effects"]["fine_cr"])
	if fine <= 0 or _principal(c["rc"]) != principal0 + fine:
		return "the fine %d did not reach the debt (%d -> %d)" % [fine, principal0, _principal(c["rc"])]
	var lines: Array = CrisisDeck.describe(inst)
	if lines.any(func(l): return str(l).contains("*")) or not lines.any(func(l): return str(l).begins_with("Fine: ")):
		return "modal lines %s" % str(lines)
	_boundary(c, 3)
	if not _kinds(_boundary(c, 4)).filter(func(k): return k == "retaliation").is_empty():
		return "it re-fired with no heat"
	return "ok"


func test_the_event_squeezes_the_barons_anchor_book() -> String:
	var c := _retaliation()
	var m: StationMarket = c["m"]
	var w: Barons = c["w"]
	var base_asks: int = 0
	for o: Order in m.get_book("mars", "FRAG").asks:
		base_asks += o.remaining_qty()
	_boundary(c, 1)
	_boundary(c, 2)
	m.set_crisis_mods((c["deck"] as CrisisDeck).market_mods())
	var asks: int = 0
	for o: Order in m.get_book("mars", "FRAG").asks:
		asks += o.remaining_qty()
	if asks >= base_asks:
		return "the retaliation left the Mars book alone (%d vs %d)" % [asks, base_asks]
	var other: int = 0
	for o: Order in m.get_book("earth", "FRAG").asks:
		other += o.remaining_qty()
	var fresh := StationMarket.new()
	fresh.set_world(w)
	fresh.set_world_mods(w.market_mods())
	var e0: int = 0
	for o: Order in fresh.get_book("earth", "FRAG").asks:
		e0 += o.remaining_qty()
	if other != e0:
		return "the event leaked to Earth's book"
	return "ok"


func test_a_consequence_bypasses_bags_max_active_and_doomsday_ticks() -> String:
	var c := _retaliation()
	var rc: RunController = c["rc"]
	var deck: CrisisDeck = c["deck"]
	deck.data["max_active"] = 1
	deck.active.append({"uid": 99, "id": "antitrust_audit", "kind": "audit", "tier": "mid", "name": "x", "text": "x", "band": "low", "station": "", "commodity": "", "started_round": 0, "expires_round": 50, "rounds": 50, "effects": {"trade_cap_qty": 20}})
	var bags0: Dictionary = deck.bags.to_dict().duplicate(true)
	var ticks0: int = rc.doomsday.ticks_remaining
	var stage0: int = int(rc.doomsday.stage)
	_boundary(c, 1)
	_boundary(c, 2)
	if deck.active.size() != 2:
		return "max_active held a consequence back: %d active" % deck.active.size()
	if RunSave.canonical(deck.bags.to_dict()) != RunSave.canonical(bags0):
		return "a consequence touched the Bags"
	if rc.doomsday.ticks_remaining != ticks0 or int(rc.doomsday.stage) != stage0:
		return "a consequence moved the doomsday clock"
	return "ok"


func test_the_event_needs_no_deck_and_the_fine_still_lands() -> String:
	var c := _retaliation()
	var rc: RunController = c["rc"]
	rc.crisis_deck = null
	var principal0: int = _principal(rc)
	_boundary(c, 1)
	var ev: Array = _boundary(c, 2)
	var r: Dictionary = {}
	for e in ev:
		if str(e["kind"]) == "retaliation":
			r = e
	if r.is_empty() or _principal(rc) != principal0 + int(r["fine"]) or int(r["fine"]) <= 0:
		return "no deck: %s" % str(_kinds(ev))
	return "ok"


func test_a_same_event_still_live_defers_the_next_one() -> String:
	var c := _retaliation()
	var w: Barons = c["w"]
	var deck: CrisisDeck = c["deck"]
	_boundary(c, 1)
	_boundary(c, 2)
	var n: int = deck.active.size()
	w.raise_heat(ARES, 9)
	_boundary(c, 3)  # queues again
	_boundary(c, 4)  # the first is still live (3-4 rounds): the second waits
	if deck.active.filter(func(x): return str(x["id"]) == "ares_retaliation").size() != 1 or deck.active.size() != n:
		return "a duplicate retaliation was injected"
	if Heat.queued(w, ARES).is_empty():
		return "the deferred retaliation was dropped"
	return "ok"


func test_the_injected_event_round_trips_through_a_save() -> String:
	var c := _retaliation()
	_boundary(c, 1)
	_boundary(c, 2)
	var deck: CrisisDeck = c["deck"]
	var back: CrisisDeck = CrisisDeck.from_dict(_json(deck.to_dict()), deck.data)
	if RunSave.canonical(back.to_dict()) != RunSave.canonical(deck.to_dict()):
		return "the deck changed across JSON"
	if str(back.active[0]["origin"]) != "consequence" or str(back.active[0]["baron"]) != ARES:
		return "origin or baron lost: %s" % str(back.active[0])
	if back.drop_consequences() != 1 or not back.active.is_empty() or back.has_pending_ack():
		return "drop_consequences"
	return "ok"


func test_a_consequence_may_force_chapter_11_when_the_players_choices_exposed_them() -> String:
	var c := _retaliation(21, 100)
	var rc: RunController = c["rc"]
	# A hold that is cheap to liquidate at the haircut but dear to mark: a fine of 150% of net worth tips it.
	rc.cargo = {"FRAG": 100}
	(c["deck"] as CrisisDeck).data["crises"].filter(func(d): return str(d["id"]) == "ares_retaliation")[0]["effects"]["fine_bps"] = 15000
	if bool(rc.assess()["insolvent"]):
		return "the setup starts insolvent"
	_boundary(c, 1)
	var ev: Array = _boundary(c, 2)
	var r: Dictionary = {}
	for e in ev:
		if str(e["kind"]) == "retaliation":
			r = e
	if r.is_empty() or str(r["origin"]) != "consequence" or r["clamped"] or not r["forced_ch11"]:
		return "the consequence did not force Chapter 11: %s" % str(r)
	if not bool(rc.assess()["insolvent"]):
		return "assess says solvent"
	return "ok"


# --- the lethal guard on random events ---

func test_a_random_baron_event_is_clamped_and_cannot_make_the_corp_insolvent() -> String:
	var c := _ctx(21, 100)
	var rc: RunController = c["rc"]
	var w: Barons = c["w"]
	rc.cargo = {"FRAG": 100}  # the same cheap-to-liquidate hold
	w.data["consequence"]["random_event_bps"] = 10000
	for d in (c["deck"] as CrisisDeck).data["crises"]:
		if str(d.get("origin", "random")) == "random" and str(d["tier"]) == "baron":
			d["effects"]["fine_bps"] = 10000
	# Each event on its own: net worth stays within random_max_loss_bps of its pre-event value.
	var fired: int = 0
	for id in w.ids():
		var pre: Dictionary = rc.assess()
		var nw0: int = int(pre["liquidation_value"]) - int(pre["total_debt"])
		var e: Dictionary = Heat._fire(w, id, 1, rc, "random")
		if e.is_empty():
			return "no random event for %s" % id
		fired += 1
		var post: Dictionary = rc.assess()
		var nw1: int = int(post["liquidation_value"]) - int(post["total_debt"])
		if bool(post["insolvent"]) or bool(e["forced_ch11"]) or nw1 < nw0 - nw0 * w.random_max_loss_bps() / 10000:
			return "%s: the guard failed, nw %d -> %d, insolvent %s" % [id, nw0, nw1, str(post["insolvent"])]
		if not bool(e["clamped"]) or str(e["origin"]) != "random":
			return "%s: a fine of 100%% of net worth was not clamped: %s" % [id, str(e)]
	# And through the round step: every baron rolls, and the corp is still solvent.
	(c["deck"] as CrisisDeck).active.clear()
	var ev: Array = _boundary(c, 2)
	if not _kinds(ev).has("retaliation") or bool(rc.assess()["insolvent"]):
		return "the round step: %s insolvent %s" % [str(_kinds(ev)), str(rc.assess()["insolvent"])]
	return "ok" if fired == 3 else "fired %d" % fired


func test_the_guard_does_nothing_for_a_player_with_no_net_worth_and_never_goes_below_zero() -> String:
	var c := _ctx(21, 0)
	var rc: RunController = c["rc"]
	var w: Barons = c["w"]
	rc.doomsday.add_principal(5000)
	var res: Dictionary = w.penalize(rc, 100000, "random")
	if int(res["applied"]) != 0 or not bool(res["clamped"]):
		return "a random fine hit an already insolvent corp: %s" % str(res)
	return "ok"


func test_random_events_are_off_in_the_shipped_data_and_do_not_fire_below_the_chance() -> String:
	var c := _ctx(84, 50000)
	var w: Barons = c["w"]
	for r in range(1, 41):
		var ev: Array = _boundary(c, r)
		if _kinds(ev).has("retaliation"):
			return "a random event fired with random_event_bps 0 in round %d" % r
	w.data["consequence"]["random_event_bps"] = 300
	var fired: int = 0
	for r in range(41, 141):
		for e in _boundary(c, r):
			if str(e["kind"]) == "retaliation":
				fired += 1
	# 3 barons x 100 rounds at 3%: a handful, never zero, never everything.
	if fired <= 0 or fired >= 100:
		return "%d random events in 300 baron-rounds at 3%%" % fired
	return "ok"


# --- determinism ---

func _busy_run(p_seed: int) -> Dictionary:
	var c := _ctx(p_seed, 100000, {"front_run_chance_bps": 10000, "bounty_chance_bps": 10000, "decide_chance_bps": 6000})
	(c["m"] as StationMarket).unlock_station("ceres")
	var rc: RunController = c["rc"]
	var w: Barons = c["w"]
	w.data["consequence"]["random_event_bps"] = 400
	_depart(c, "earth", "mars", {"ORE": 80})
	rc.cargo = {"ORE": 60}
	for r in range(1, 41):
		if r == 12:
			_depart(c, "mars", "ceres", {"MACHINERY": 80})
			rc.cargo = {"ORE": 60}
		_boundary(c, r)
		(c["deck"] as CrisisDeck).acknowledge()
	return c


func test_the_same_seed_gives_the_same_heat_front_runs_and_events_and_other_seeds_differ() -> String:
	var a := _busy_run(21)
	var b := _busy_run(21)
	if RunSave.canonical((a["w"] as Barons).to_dict()) != RunSave.canonical((b["w"] as Barons).to_dict()):
		return "world differs between two identical runs"
	if RunSave.canonical((a["deck"] as CrisisDeck).to_dict()) != RunSave.canonical((b["deck"] as CrisisDeck).to_dict()):
		return "deck differs between two identical runs"
	if RunSave.canonical((a["m"] as StationMarket).to_dict()) != RunSave.canonical((b["m"] as StationMarket).to_dict()):
		return "books differ between two identical runs"
	var o := _busy_run(7)
	if RunSave.canonical((o["w"] as Barons).to_dict()) == RunSave.canonical((a["w"] as Barons).to_dict()):
		return "two seeds played alike"
	return "ok"


func test_the_new_draws_use_their_own_prefixes() -> String:
	# Re-deriving the draw by hand: the chance is hash32("<prefix>-<id>-<seed>-<round>").
	for r in [3, 8, 13]:
		var want: bool = NativeDrawSource.new(StableHash.hash32("rival-front-%s-%d-%d" % [KESSLER, 21, r])).randint(0, 9999) < 5000
		var cc := _ctx(21, 50000, {"front_run_chance_bps": 5000})
		(cc["rc"] as RunController).sim_clock.total_ticks = r * TPR
		_depart(cc, "earth", "mars", {"ORE": 80})
		var got: bool = int((cc["w"] as Barons).rival(KESSLER).route.get("front", 0)) == 1
		if got != want:
			return "round %d: the front-run draw is not rival-front-<id>-<seed>-<round>" % r
	return "ok"


# --- the sidebar ---

func test_the_sidebar_shows_heat_the_queued_retaliation_and_a_traced_bounty() -> String:
	var rc := RunController.new(null, 21, null, {}, TPR)
	rc.world = Barons.for_new_run()
	rc.crisis_deck = CrisisDeck.new(21)
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("mars")
	var w: Barons = rc.world
	if not lp.lever_notes("mars").is_empty() or not lp.bounty_notes().is_empty():
		return "notes with nothing in play"
	w.raise_heat(ARES, 3)
	var notes: Array = lp.lever_notes("mars")
	if notes.size() != 2 or str(notes[0]["text"]) != "HEAT" or str(notes[1]["text"]) != "HEAT 3 / 6":
		return "heat notes %s" % str(notes)
	w.state(ARES).scratch["retaliate"] = {"due": 5}
	notes = lp.lever_notes("mars")
	if str(notes[notes.size() - 2]["text"]) != "RETALIATION DUE" or not str(notes[notes.size() - 1]["text"]).contains("ROUND 5"):
		return "queued notes %s" % str(notes)
	# A bounty is secret until traced.
	w.desk().hire(BLACKWATER, "player", 0, 20000)
	if not lp.bounty_notes().is_empty():
		return "an untraced bounty showed"
	w.mark_bounty_traced(str(w.bounty_on_player(0)["contract_id"]))
	var bn: Array = lp.bounty_notes()
	if bn.size() != 2 or str(bn[0]["text"]) != "BOUNTY ON YOU" or not str(bn[1]["text"]).begins_with("BLACKWATER PRIVATEERS: 20 RD LEFT"):
		return "bounty notes %s" % str(bn)
	return "ok"


func test_a_retaliation_posts_its_headline_and_a_forced_filing_posts_the_warning() -> String:
	var rc := RunController.new(null, 21, null, {}, TPR)
	rc.world = Barons.for_new_run()
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("mars")
	rc.world.raise_heat(ARES, 9)
	lp._on_round_advanced(1)
	var texts: Array = hud.galnet_headlines.map(func(h): return hud.headline_text(h))
	if not texts.any(func(t): return str(t).contains("remembers")):
		return "no queued warning: %s" % str(texts.slice(0, 5))
	lp._on_round_advanced(2)
	texts = hud.galnet_headlines.map(func(h): return hud.headline_text(h))
	if not texts.any(func(t): return str(t).contains("RETALIATION: Ares Heavy calls its markers")):
		return "no retaliation headline: %s" % str(texts.slice(0, 5))
	if lp.overlay_state != M0Loop.OVERLAY_CRISIS:
		return "the retaliation did not raise the crisis modal (%s)" % lp.overlay_state
	return "ok"
