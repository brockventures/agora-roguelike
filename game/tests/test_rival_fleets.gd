extends RefCounted
## Epic 3 task 10 (part of #18, Rival Syndicate Fleets): the rival fleets core. The data
## and its validation, RivalFleet save/load, route arbitrage over the shared books, the
## departure reaction (decision 9.5), distress bids through Barons.rival_bids,
## determinism (design doc 6.3) and the pinned hash of the shipped world with its fleets
## on, the player's ledger staying untouched, and the GalNet / map / desk UI.

const FRAME: float = 1.0 / 60.0 + 0.0001
const TPR: int = 30
const ARES: String = "ares_heavy"
const KESSLER: String = "kessler_freight"
const BLACKWATER: String = "blackwater_lines"
const EMBER: String = "ember_haulage"

## RunSave.state_hash of the shipped world WITH its rival fleets for two seeds, the run
## _fleet_run plays (about 60 rounds, Ceres unlocked mid-run, offers declined). Measured
## when Epic 3 task 10 landed. test_market_wiring.gd's WORLD_HASH_SEED_* pin the same run with
## the fleets taken out and did not move; these pin the fleets. A change that moves them
## is a replay-contract change and must be deliberate.
const RIVAL_WORLD_HASH_SEED_84 := "7892044f12e33253d256227c836a81f886e8ee89f01b8c6a2cf655a9018932c4"
const RIVAL_WORLD_HASH_SEED_7 := "64af64b32b9201274720e65156cf4ecd1e632bb7c40f77efe912f40603b2a092"


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


## A world and its books, the way a run builds them, with the fleets' dials set to `cfg`.
func _world(p_seed: int = 84, cfg: Dictionary = {}) -> Dictionary:
	var rc := RunController.new(null, p_seed, null, {}, TPR)
	rc.world = Barons.for_new_run()
	for k in cfg:
		rc.world.data["rivals"][k] = cfg[k]
	var m := StationMarket.new()
	m.set_world(rc.world)
	m.set_world_mods(rc.world.market_mods())
	return {"rc": rc, "w": rc.world, "m": m}


## One round boundary for the fleets: reseed the books, then the fleet step (as M0Loop).
func _round(c: Dictionary, r: int) -> Array:
	var rc: RunController = c["rc"]
	rc.sim_clock.total_ticks = r * TPR
	(c["m"] as StationMarket).replenish()
	return (c["w"] as Barons).advance_rivals(r, rc, c["m"])


func _kinds(events: Array) -> Array:
	var out: Array = []
	for e in events:
		out.append("%s:%s" % [e["kind"], e["fleet"]])
	return out


func _texts(hud: OrbitalHUD) -> Array:
	var out: Array = []
	for h in hud.galnet_headlines:
		out.append(hud.headline_text(h))
	return out


func _ask_units(m: StationMarket, station: String, commodity: String) -> int:
	var n: int = 0
	for o: Order in m.get_book(station, commodity).asks:
		n += o.remaining_qty()
	return n


# --- data ---

func test_the_shipped_fleets_validate_and_load() -> String:
	var d: Dictionary = Barons.load_data()
	var errs: Array = Barons.validate(d)
	if not errs.is_empty():
		return "shipped barons.json invalid: %s" % str(errs)
	var w := Barons.new()
	if w.rival_ids() != [BLACKWATER, EMBER, KESSLER]:
		return "fleets %s" % str(w.rival_ids())
	var k: RivalFleet = w.rival(KESSLER)
	if k.at != "earth" or k.cr != 24000 or k.in_flight() or not k.cargo.is_empty():
		return "kessler opens wrong: %s" % str(k.to_dict())
	if str(w.rival_def(KESSLER)["trait"]) != "front_runner" or str(w.rival_def(BLACKWATER)["stance"]) != "cautious":
		return "trait or stance lost"
	return "ok"


func test_validation_rejects_bad_fleets() -> String:
	var cases := {
		"trait": func(f: Dictionary, _r: Dictionary): f["trait"] = "pirate",
		"stance": func(f: Dictionary, _r: Dictionary): f["stance"] = "reckless",
		"home": func(f: Dictionary, _r: Dictionary): f["home"] = "pluto",
		"cr": func(f: Dictionary, _r: Dictionary): f["cr"] = -1,
		"name": func(f: Dictionary, _r: Dictionary): f["name"] = "",
		"baron id": func(f: Dictionary, _r: Dictionary): f["id"] = ARES,
		"player id": func(f: Dictionary, _r: Dictionary): f["id"] = "player",
		"id shape": func(f: Dictionary, _r: Dictionary): f["id"] = "Bad Id",
		"setting": func(_f: Dictionary, r: Dictionary): r["capacity"] = -5,
		"bps": func(_f: Dictionary, r: Dictionary): r["bid_chance_bps"] = 10001,
		"unknown setting": func(_f: Dictionary, r: Dictionary): r["warp"] = 1,
	}
	for name in cases:
		var d: Dictionary = _json(Barons.load_data())
		(cases[name] as Callable).call(d["rivals"]["fleets"][0], d["rivals"])
		if Barons.validate(d).is_empty():
			return "a bad %s passed validation" % name
	var dup: Dictionary = _json(Barons.load_data())
	dup["rivals"]["fleets"][1]["id"] = KESSLER
	if Barons.validate(dup).is_empty():
		return "a duplicate fleet id passed validation"
	var none: Dictionary = _json(Barons.load_data())
	none.erase("rivals")
	if not Barons.validate(none).is_empty():
		return "a file with no rivals block should be valid: %s" % str(Barons.validate(none))
	return "ok"


func test_a_world_with_no_rivals_block_has_no_fleets_and_no_save_key() -> String:
	var d: Dictionary = _json(Barons.load_data())
	d.erase("rivals")
	var w := Barons.new(d)
	if not w.rivals.is_empty() or w.to_dict().has("rivals"):
		return "a rival-less world saved a rivals key"
	var shipped := Barons.new()
	if not shipped.to_dict().has("rivals"):
		return "the shipped world does not save its fleets"
	return "ok"


func test_fleet_state_round_trips_through_json() -> String:
	var f := RivalFleet.new("x")
	f.cr = 1234
	f.at = "mars"
	f.cargo = {"ORE": 12, "FRAG": 3}
	f.route = {"origin": "mars", "destination": "earth", "depart_round": 4, "arrival_round": 6, "commodity": "ORE", "qty": 12}
	f.last = {"round": 4, "station": "mars", "commodity": "ORE", "side": "BUY", "qty": 12, "price": 17}
	var g: RivalFleet = RivalFleet.from_dict(_json(f.to_dict()))
	if RunSave.canonical(g.to_dict()) != RunSave.canonical(f.to_dict()):
		return "fleet changed across JSON: %s vs %s" % [str(g.to_dict()), str(f.to_dict())]
	if not g.in_flight() or g.cargo_units() != 15 or typeof(g.route["arrival_round"]) != TYPE_INT:
		return "fleet reads are not ints after JSON"
	return "ok"


func test_a_saved_world_without_the_key_restores_without_fleets() -> String:
	var w := Barons.new()
	var d: Dictionary = _json(w.to_dict())
	d.erase("rivals")
	if not Barons.from_dict(d).rivals.is_empty():
		return "an old save gained fleets"
	var back: Barons = Barons.from_dict(_json(w.to_dict()))
	if back.rival_ids() != w.rival_ids():
		return "a save with fleets lost them"
	return "ok"


# --- route arbitrage ---

func test_a_fleet_scores_every_route_and_takes_the_best() -> String:
	var c := _world()
	var w: Barons = c["w"]
	var m: StationMarket = c["m"]
	var f: RivalFleet = w.rival(BLACKWATER)  # at Mars, cautious
	var p: Dictionary = Rivals.plan(w, f, m, 0)
	if p.is_empty():
		return "no plan from Mars at round 0"
	if str(p["destination"]) != "earth":
		return "only Earth has a second book, got %s" % str(p["destination"])
	var route: Dictionary = Transit.get_route("mars", "earth", 0)
	var fuel_px: int = (int(m.get_book("mars", "FUEL").bids[0].limit_price) + int(m.get_book("mars", "FUEL").asks[0].limit_price)) / 2
	var fixed: int = int(route["fuel"]) * fuel_px + int(route["toll"]) + w.docking_toll_due(BLACKWATER, "earth")
	var best_c: String = ""
	var best: int = -1000000
	for com in Transit.COMMODITIES:
		var o_ask: int = int(m.get_book("mars", com).asks[0].limit_price)
		var d_bid: int = int(m.get_book("earth", com).bids[0].limit_price)
		if d_bid <= o_ask:
			continue
		var q: Dictionary = m.sweep_quote("mars", com, "BUY", mini(60, f.cr / o_ask), float(d_bid - 1))
		var mid_o: int = (int(m.get_book("mars", com).bids[0].limit_price) + o_ask) / 2
		var mid_d: int = (d_bid + int(m.get_book("earth", com).asks[0].limit_price)) / 2
		var sc: int = (mid_d - mid_o) * int(q["filled"]) - fixed
		if sc > best:
			best = sc
			best_c = com
	if str(p["commodity"]) != best_c or int(p["score"]) != best:
		return "plan %s score %d, brute force %s score %d" % [str(p["commodity"]), int(p["score"]), best_c, best]
	if int(p["qty"]) <= 0 or int(p["qty"]) > 60:
		return "qty %d outside the hold" % int(p["qty"])
	if int(Rivals.plan(w, f, m, 0)["score"]) != best or str(Rivals.plan(w, f, m, 0)["commodity"]) != best_c:
		return "the same inputs planned differently"
	return "ok"


func test_a_route_that_does_not_clear_the_floor_is_not_sailed() -> String:
	var c := _world(84, {"min_profit_cr": 1000000})
	var w: Barons = c["w"]
	if not Rivals.plan(w, w.rival(KESSLER), c["m"], 0).is_empty():
		return "a fleet sailed under its profit floor"
	var broke := _world()
	(broke["w"] as Barons).rival(KESSLER).cr = 10
	if not Rivals.plan(broke["w"], broke["w"].rival(KESSLER), broke["m"], 0).is_empty():
		return "a fleet that cannot pay for fuel sailed"
	return "ok"


func test_cautious_needs_a_margin_that_bold_does_not() -> String:
	var c := _world(84, {"min_profit_cr": 1, "cautious_margin_bps": 9000})
	var w: Barons = c["w"]
	var m: StationMarket = c["m"]
	# Same cash and same spot (Mars): the cautious fleet wants 90% on its outlay, which no
	# real spread gives, while the bold one sails.
	w.rival(EMBER).cr = 20000
	w.rival(BLACKWATER).cr = 20000
	if Rivals.plan(w, w.rival(EMBER), m, 0).is_empty():
		return "the bold fleet did not sail"
	if not Rivals.plan(w, w.rival(BLACKWATER), m, 0).is_empty():
		return "the cautious fleet sailed without its margin"
	return "ok"


func test_a_fleet_buys_sails_and_sells_into_the_bids_on_arrival() -> String:
	var c := _world(84, {"decide_chance_bps": 10000})
	var w: Barons = c["w"]
	var m: StationMarket = c["m"]
	var f: RivalFleet = w.rival(KESSLER)
	var cr0: int = f.cr
	var fresh := StationMarket.new()
	fresh.set_world(w)
	fresh.set_world_mods(w.market_mods())
	var events: Array = _round(c, 1)
	if not f.in_flight() or f.cargo_units() <= 0:
		return "kessler did not sail with cargo: %s" % str(_kinds(events))
	var dep: Dictionary = {}
	for e in events:
		if e["kind"] == "rival_depart" and e["fleet"] == KESSLER:
			dep = e
	if dep.is_empty() or str(dep["station"]) != "earth" or str(dep["destination"]) != "mars":
		return "no departure event for kessler: %s" % str(_kinds(events))
	var com: String = str(dep["commodity"])
	if f.cr >= cr0 or _ask_units(m, "earth", com) >= _ask_units(fresh, "earth", com):
		return "the purchase left no dent in the origin asks"
	if int(f.route["arrival_round"]) != 1 + int(dep["rounds"]) or str(f.route["commodity"]) != com:
		return "route %s" % str(f.route)
	w.data["rivals"]["decide_chance_bps"] = 0  # no second sailing muddies the sale
	var cash_in_flight: int = f.cr
	var sold: bool = false
	var arrival: int = int(f.route["arrival_round"])
	for r in range(2, arrival + 1):
		var ev: Array = _round(c, r)
		for e in ev:
			if e["kind"] == "rival_trade" and e["fleet"] == KESSLER and str(e["station"]) == "mars" and str(e["commodity"]) == com:
				sold = true
	if not sold:
		return "kessler never sold at Mars by round %d" % arrival
	if f.cr <= cash_in_flight:
		return "the sale paid nothing (cr %d -> %d)" % [cash_in_flight, f.cr]
	return "ok"


func test_a_fleet_pays_the_belt_toll_and_never_opens_a_locked_station() -> String:
	var c := _world(84, {"decide_chance_bps": 10000})
	var w: Barons = c["w"]
	var m: StationMarket = c["m"]
	for r in range(1, 41):
		_round(c, r)
		for v in w.rival_voyages():
			if str(v["destination"]) in ["ceres", "luna"] or str(v["origin"]) in ["ceres", "luna"]:
				return "round %d: a fleet sailed to a station with no book: %s" % [r, str(v)]
	if m.has_book("ceres", "FUEL") or m.has_book("luna", "FUEL"):
		return "a fleet unlocked a station"
	# With Ceres open, a Mars fleet may take the belt lane: its CR drops by fuel and the toll.
	m.unlock_station("ceres")
	var f := RivalFleet.new("probe")
	f.at = "mars"
	f.cr = 20000
	var w2: Barons = c["w"]
	w2.rivals["probe"] = f
	w2.data["rivals"]["fleets"].append({"id": "probe", "name": "Probe", "home": "mars", "cr": 20000, "trait": "hauler", "stance": "bold"})
	var p: Dictionary = Rivals.plan(w2, f, m, 41)
	if p.is_empty():
		return "no plan with Ceres open"
	if str(p["destination"]) == "ceres" and int(p["toll_cr"]) != Transit.BELT_TOLL_CR:
		return "the belt lane carried no toll: %d" % int(p["toll_cr"])
	return "ok"


func test_the_fleet_step_never_touches_the_players_ledger() -> String:
	var c := _world(84, {"decide_chance_bps": 10000, "react_chance_bps": 10000})
	var rc: RunController = c["rc"]
	var cr0: int = rc.cr
	var before: Dictionary = rc.assess()
	for r in range(1, 41):
		_round(c, r)
	(c["w"] as Barons).react_to_departure(rc, c["m"], {"origin": "mars", "destination": "earth"})
	var after: Dictionary = rc.assess()
	if rc.cr != cr0 or int(after["total_debt"]) != int(before["total_debt"]) or bool(after["insolvent"]) != bool(before["insolvent"]):
		return "the fleets moved the player's CR or debt"
	if not (c["w"] as Barons).held_by(Takeover.PLAYER).is_empty() or rc.pending_bankruptcy:
		return "a fleet step changed the player's standing"
	return "ok"


# --- determinism (design doc 6.3) ---

func test_the_same_seed_gives_the_same_fleets_and_books() -> String:
	var a := _world(84, {"decide_chance_bps": 6000})
	var b := _world(84, {"decide_chance_bps": 6000})
	var ev_a: Array = []
	var ev_b: Array = []
	for r in range(1, 41):
		ev_a.append(_kinds(_round(a, r)))
		ev_b.append(_kinds(_round(b, r)))
	if ev_a != ev_b:
		return "events differ between two identical runs"
	if RunSave.canonical((a["w"] as Barons).to_dict()) != RunSave.canonical((b["w"] as Barons).to_dict()):
		return "fleet state differs between two identical runs"
	if RunSave.canonical((a["m"] as StationMarket).to_dict()) != RunSave.canonical((b["m"] as StationMarket).to_dict()):
		return "books differ between two identical runs"
	var other := _world(7, {"decide_chance_bps": 6000})
	var ev_o: Array = []
	for r in range(1, 41):
		ev_o.append(_kinds(_round(other, r)))
	if ev_o == ev_a:
		return "two run seeds moved the fleets alike"
	return "ok"


func test_draws_come_from_a_fresh_source_per_fleet_round_seed() -> String:
	for id in [KESSLER, EMBER]:
		for r in [3, 9]:
			var want: int = NativeDrawSource.new(StableHash.hash32("rival-%s-84-%d" % [id, r])).randint(0, 9999)
			if Rivals._draw("rival", id, 84, r).randint(0, 9999) != want or Rivals._draw("rival", id, 84, r).randint(0, 9999) != want:
				return "the %s round %d draw is not hash32('rival-<id>-<run_seed>-<round>')" % [id, r]
	var seen: Dictionary = {}
	for r in 12:
		seen[Rivals._draw("rival", KESSLER, 84, r).randint(0, 9999)] = true
	if seen.size() < 6:
		return "draws barely vary across rounds: %d distinct" % seen.size()
	if Rivals._draw("rival", KESSLER, 84, 5).randint(0, 9999) == Rivals._draw("rival", KESSLER, 7, 5).randint(0, 9999) and Rivals._draw("rival", KESSLER, 84, 6).randint(0, 9999) == Rivals._draw("rival", KESSLER, 7, 6).randint(0, 9999):
		return "the run seed does not reach the draws"
	return "ok"


func test_a_skipped_round_cannot_desync_the_draws() -> String:
	# No persistent stream: the roll for round 20 is the same whether or not 1..19 ran.
	var want: int = Rivals._draw("rival", EMBER, 84, 20).randint(0, 9999)
	for r in range(1, 20):
		Rivals._draw("rival", EMBER, 84, r).randint(0, 9999)
	return "ok" if Rivals._draw("rival", EMBER, 84, 20).randint(0, 9999) == want else "round 20 depends on earlier rounds"


# --- the departure reaction (decision 9.5) ---

func test_idle_fleets_react_to_a_departure_with_a_flagged_sailing() -> String:
	var c := _world(84, {"react_chance_bps": 10000})
	var w: Barons = c["w"]
	var events: Array = w.react_to_departure(c["rc"], c["m"], {"origin": "mars", "destination": "earth"})
	if events.is_empty():
		return "no fleet reacted"
	var seen: Array = []
	for e in events:
		if str(e["kind"]) != "rival_depart" or not bool(e.get("reaction", false)) or str(e.get("watched", "")) != "mars":
			return "a reaction event is not a flagged sailing: %s" % str(e)
		seen.append(e["fleet"])
	for id in seen:
		if not w.rival(id).in_flight():
			return "%s reacted but is not under way" % id
	var again: Array = w.react_to_departure(c["rc"], c["m"], {"origin": "mars", "destination": "earth"})
	for e in again:
		if seen.has(e["fleet"]):
			return "a fleet already under way reacted again"
	var quiet := _world(84, {"react_chance_bps": 0})
	if not (quiet["w"] as Barons).react_to_departure(quiet["rc"], quiet["m"], {"origin": "mars", "destination": "earth"}).is_empty():
		return "a fleet reacted at 0 bps"
	return "ok"


func test_the_departure_headline_follows_the_players_own() -> String:
	var rc := RunController.new(null, 84, null, {}, TPR)
	rc.world = Barons.for_new_run()
	rc.world.data["rivals"]["react_chance_bps"] = 10000
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("mars")
	rc.cr = 5000
	if not bool(rc.depart("earth")["ok"]):
		return "could not depart"
	var texts: Array = _texts(hud)  # newest first
	var tail: int = -1
	var own: int = -1
	for i in texts.size():
		if str(texts[i]).contains("answers your departure") and tail < 0:
			tail = i
		if str(texts[i]).contains("YOUR SHIP DEPARTS"):
			own = i
	if tail < 0:
		return "no rival headline on the player's departure: %s" % str(texts.slice(0, 6))
	if own < 0 or tail >= own:  # newest first
		return "the rival headline does not follow the player's own (tail %d, own %d)" % [tail, own]
	if not str(texts[tail]).contains("ARCADIA FOUNDRIES"):
		return "the headline does not name the station left: %s" % texts[tail]
	return "ok"


func test_spontaneous_trades_post_only_where_the_player_is_docked() -> String:
	var rc := RunController.new(null, 84, null, {}, TPR)
	rc.world = Barons.for_new_run()
	rc.world.data["rivals"]["decide_chance_bps"] = 10000
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("mars")
	lp._on_round_advanced(1)
	var texts: Array = _texts(hud)
	var posted: Array = texts.filter(func(t): return str(t).contains(" loads "))
	if posted.is_empty():
		return "nothing posted for a fleet loading at the player's dock: %s" % str(texts.slice(0, 6))
	for t in posted:
		if not str(t).contains("ARCADIA FOUNDRIES"):
			return "a trade away from the dock reached GalNet: %s" % t
	if rc.world.rival(KESSLER).route.is_empty():
		return "kessler (at Earth) should have sailed silently"
	if texts.any(func(t): return str(t).contains("KESSLER")):
		return "a sailing from Earth was announced to a player at Mars"
	return "ok"


# --- the desk, the map ---

func test_a_fill_on_the_players_book_leaves_a_tag_for_that_round_only() -> String:
	var rc := RunController.new(null, 84, null, {}, TPR)
	rc.world = Barons.for_new_run()
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("mars")
	if lp.rival_tag("mars", "ORE") != "":
		return "a tag before any trade"
	rc.world.rival(EMBER).last = {"round": 0, "station": "mars", "commodity": "ORE", "side": "BUY", "qty": 42, "price": 17}
	if lp.rival_tag("mars", "ORE") != "EMBER BOUGHT 42":
		return "tag '%s'" % lp.rival_tag("mars", "ORE")
	rc.world.rival(EMBER).last["side"] = "SELL"
	if lp.rival_tag("mars", "ORE") != "EMBER SOLD 42":
		return "tag '%s'" % lp.rival_tag("mars", "ORE")
	if lp.rival_tag("mars", "FRAG") != "" or lp.rival_tag("earth", "ORE") != "":
		return "the tag shows on a book the fleet did not trade"
	rc.sim_clock.total_ticks = TPR  # round 1
	if lp.rival_tag("mars", "ORE") != "":
		return "the tag outlived its round"
	return "ok"


func test_the_map_projects_fleets_in_flight() -> String:
	var rc := RunController.new(null, 84, null, {}, TPR)
	rc.world = Barons.for_new_run()
	var map := SolTacticalMap.new(rc)
	if not map.get_rival_transits().is_empty():
		return "fleets drawn while all are docked"
	rc.world.rival(KESSLER).route = {"origin": "earth", "destination": "mars", "depart_round": 0, "arrival_round": 2, "commodity": "FRAG", "qty": 10}
	rc.sim_clock.total_ticks = TPR / 2  # half a round in
	var v: Array = map.get_rival_transits()
	if v.size() != 1 or str(v[0]["fleet"]) != KESSLER:
		return "transits %s" % str(v)
	if absf(float(v[0]["progress"]) - 0.25) > 0.02:
		return "a quarter of the trip expected, got %.3f" % float(v[0]["progress"])
	var a: Vector2 = v[0]["start_pos"]
	var b: Vector2 = v[0]["end_pos"]
	if not (v[0]["pos"] as Vector2).is_equal_approx(a.lerp(b, float(v[0]["progress"]))):
		return "the hull is off its lane"
	rc.sim_clock.total_ticks = 5 * TPR
	if absf(float(map.get_rival_transits()[0]["progress"]) - 1.0) > 0.001:
		return "progress is not clamped at arrival"
	rc.world = null
	return "ok" if map.get_rival_transits().is_empty() else "fleets drawn with no world"


# --- distress bids (the Takeover seam) ---

func test_fleets_bid_only_after_the_baron_has_been_insolvent_a_while() -> String:
	var c := _world(84, {"bid_chance_bps": 10000})
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	w.state(ARES).strain = 1
	if not w.rival_bids(ARES, 5, 10, 100, rc).is_empty():
		return "bid on the first insolvent round"
	w.state(ARES).strain = 2
	if not w.rival_bids(ARES, 5, 10, 100).is_empty():
		return "bid with no run seed"
	var cr0: int = w.rival(BLACKWATER).cr + w.rival(EMBER).cr + w.rival(KESSLER).cr
	var bids: Array = w.rival_bids(ARES, 5, 10, 100, rc)
	if bids.is_empty():
		return "no bids at strain 2"
	var total: int = 0
	var last: String = ""
	for b in bids:
		if str(b["buyer"]) <= last:
			return "bids are not in sorted id order: %s" % str(bids)
		last = str(b["buyer"])
		total += int(b["qty"])
	if total > 100:
		return "bid for %d of a 100-share lot" % total
	var cr1: int = w.rival(BLACKWATER).cr + w.rival(EMBER).cr + w.rival(KESSLER).cr
	if cr0 - cr1 != total * 10:
		return "bidders paid %d for %d shares at 10" % [cr0 - cr1, total]
	var quiet := _world(84, {"bid_chance_bps": 0})
	(quiet["w"] as Barons).state(ARES).strain = 3
	if not (quiet["w"] as Barons).rival_bids(ARES, 5, 10, 100, quiet["rc"]).is_empty():
		return "bid at 0 bps"
	return "ok"


func test_a_distressed_baron_sells_its_lot_to_a_fleet_through_the_takeover_core() -> String:
	var c := _world(84, {"bid_chance_bps": 10000, "decide_chance_bps": 0})
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	w.add_debt(ARES, int(w.assess_baron(ARES)["liquidation_value"]) + 5000)
	var sold: bool = false
	for r in range(1, 6):
		rc.sim_clock.total_ticks = r * TPR
		for e in w.advance_round(r, rc, c["m"]):
			if str(e["kind"]) == "shares" and str(e["buyer"]) in w.rival_ids():
				sold = true
	if not sold:
		return "no fleet bought shares in five insolvent rounds: %s" % str(w.state(ARES).shares)
	var held: int = 0
	for id in w.rival_ids():
		held += int(w.state(ARES).shares.get(id, 0))
	if held <= 0 or int(w.state(ARES).shares.get(Takeover.PLAYER, 0)) != 0:
		return "shares %s" % str(w.state(ARES).shares)
	return "ok"


# --- the shipped loop: save / restore / pins ---

## The shipped world, fleets on, played as test_market_wiring's _world_run.
func _fleet_run(p_seed: int, frames: int = 1500) -> Replay.Session:
	var s := Replay.Session.new(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	s.dispatch(M0Loop.ACT_TAB_NEXT)
	_advance(s, 40)
	s.dispatch(M0Loop.ACT_RIGHT)
	s.dispatch(M0Loop.ACT_SUBMIT)
	_advance(s, 300)
	s.loop.dock_at("ceres")
	s.dispatch(M0Loop.ACT_SUBMIT)
	_advance(s, frames)
	return s


func _advance(s: Replay.Session, n: int) -> void:
	for i in n:
		if s.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			s.loop.acknowledge_crisis()
		elif s.loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			s.loop.decline_contract()
		s.advance()


func test_the_shipped_world_hash_with_fleets_is_pinned() -> String:
	var got := {84: _fleet_run(84), 7: _fleet_run(7)}
	if got[84].state_hash() != RIVAL_WORLD_HASH_SEED_84:
		return "seed 84 fleet-world hash moved: %s" % got[84].state_hash()
	if got[7].state_hash() != RIVAL_WORLD_HASH_SEED_7:
		return "seed 7 fleet-world hash moved: %s" % got[7].state_hash()
	for sd in got:
		var w: Barons = (got[sd] as Replay.Session).controller.world
		var moved: bool = false
		for id in w.rival_ids():
			if w.rival(id).cr != int(w.rival_def(id)["cr"]) or not w.rival(id).last.is_empty():
				moved = true
		if not moved:
			return "seed %d: the pinned run never moved a fleet" % sd
	return "ok"


func test_the_fleet_run_is_repeatable_and_fleets_change_the_hash() -> String:
	var a := _fleet_run(84)
	if a.state_hash() != _fleet_run(84).state_hash():
		return "the same fleet run hashed twice differently"
	var bare := Replay.Session.new(84, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	bare.controller.world.rivals.clear()
	bare.dispatch(M0Loop.ACT_TAB_NEXT)
	_advance(bare, 40)
	bare.dispatch(M0Loop.ACT_RIGHT)
	bare.dispatch(M0Loop.ACT_SUBMIT)
	_advance(bare, 300)
	bare.loop.dock_at("ceres")
	bare.dispatch(M0Loop.ACT_SUBMIT)
	_advance(bare, 1500)
	if bare.state_hash() == a.state_hash():
		return "taking the fleets out did not change the hash"
	return "ok"


func test_save_load_then_continue_equals_the_uninterrupted_run_with_fleets() -> String:
	for p_seed in [84, 7]:
		var whole := _fleet_run(p_seed)
		var split := Replay.Session.new(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
		split.dispatch(M0Loop.ACT_TAB_NEXT)
		_advance(split, 40)
		split.dispatch(M0Loop.ACT_RIGHT)
		split.dispatch(M0Loop.ACT_SUBMIT)
		_advance(split, 300)
		split.loop.dock_at("ceres")
		split.dispatch(M0Loop.ACT_SUBMIT)
		_advance(split, 700)
		var cap: Dictionary = RunSave.capture(split.controller, split.loop.market, split.bags)
		if not (cap["world"] as Dictionary).has("rivals"):
			return "seed %d: the capture has no fleets" % p_seed
		var via_json: Dictionary = RunSave.restore(_json(cap))
		if not bool(via_json["ok"]) or RunSave.state_hash(via_json["controller"], via_json["market"], via_json["bags"]) != split.state_hash():
			return "seed %d: the save file round trip changed the hash" % p_seed
		var r: Dictionary = RunSave.restore(cap.duplicate(true))
		var rc: RunController = r["controller"]
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
			elif lp.overlay_state == M0Loop.OVERLAY_CONTRACT:
				lp.decline_contract()
			lp.advance(Replay.DEFAULT_FRAME_DELTA)
		if RunSave.state_hash(rc, lp.market, r["bags"]) != whole.state_hash():
			return "seed %d: save/load/continue diverged from the uninterrupted run" % p_seed
	return "ok"


func test_a_fleet_world_recording_replays_to_the_same_hash() -> String:
	var s: Replay.Session = Replay.start_recording(84, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	s.dispatch(M0Loop.ACT_TAB_NEXT)
	s.advance_frames(40)
	s.dispatch(M0Loop.ACT_RIGHT)
	s.dispatch(M0Loop.ACT_SUBMIT)
	s.advance_frames(400)
	var res: Dictionary = Replay.replay(_json(s.to_recording()))
	if not bool(res["ok"]):
		return "replay failed: %s (expected %s, actual %s)" % [res["error"], res["expected"], res["actual"]]
	return "ok"
