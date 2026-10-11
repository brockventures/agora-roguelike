extends RefCounted
## #138: departing burns fuel. The burn goes through Transit.calculate_fuel_burn (corridor cut
## and the fuel_hedge discount), is paid from FUEL in the hold first, then bought at the
## departure station's live FUEL asks (denting the book), and is refused, never put into
## debt, when cash plus cargo cannot cover it.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const TPR: int = 30


func _owned(ids: Array) -> MetaProfile:
	var p := MetaProfile.new()
	for id in ids:
		p.add_unlock(str(id))
	return p


## A controller docked at Earth with `cr` credits, at the start of `round_num`.
func _rc(perks: Array = [], cr: int = 5000, round_num: int = 0) -> RunController:
	var rc := RunController.new(_owned(perks), 1, DoomsdayClock.new(36000, 0, 0, 0), {}, TPR)
	rc.cr = cr
	rc.sim_clock.total_ticks = round_num * TPR
	return rc


func _ask_qty(m: StationMarket, station: String) -> int:
	var n: int = 0
	for o in m.get_book(station, "FUEL").asks:
		n += (o as Order).remaining_qty()
	return n


func test_a_bare_controller_charges_no_fuel() -> String:
	var rc := _rc()
	var cr0: int = rc.cr
	var res: Dictionary = rc.depart("mars")
	if not bool(res["ok"]) or rc.cr != cr0 or int(res["fuel_units"]) != 0:
		return "no market, no fuel: cr %d -> %d, fuel %d" % [cr0, rc.cr, int(res["fuel_units"])]
	return "ok"


func test_departure_burns_the_route_fuel_from_the_hold() -> String:
	var m := StationMarket.new()
	var rc := _rc()
	rc.cargo = {"FUEL": 40, "ORE": 5}
	var cr0: int = rc.cr
	var asks0: int = _ask_qty(m, "earth")
	var res: Dictionary = rc.depart("mars", m)
	if not bool(res["ok"]):
		return "refused: %s" % str(res["reason"])
	if int(res["fuel_units"]) != 15 or int(rc.cargo["FUEL"]) != 25 or int(rc.cargo["ORE"]) != 5:
		return "Earth -> Mars burns 15: res %s cargo %s" % [str(res["fuel_units"]), str(rc.cargo)]
	if rc.cr != cr0 or _ask_qty(m, "earth") != asks0:
		return "a hold-paid burn touched cash or the book (cr %d -> %d)" % [cr0, rc.cr]
	if int(rc.transit["fuel_burned"]) != 15 or int(rc.transit["fuel_hold"]) != 15 or int(rc.transit["fuel_bought"]) != 0:
		return "voyage does not record the burn: %s" % str(rc.transit)
	return "ok"


func test_the_hedge_perk_cuts_the_burn_by_ten_percent() -> String:
	var m := StationMarket.new()
	var plain := _rc()
	var hedged := _rc(["fuel_hedge"])
	plain.cargo = {"FUEL": 40}
	hedged.cargo = {"FUEL": 40}
	var a: Dictionary = plain.depart("mars", m)
	var b: Dictionary = hedged.depart("mars", m)
	if int(a["fuel_units"]) != 15 or int(b["fuel_units"]) != 13:
		return "burn %d plain, %d hedged (want 15 and 13)" % [int(a["fuel_units"]), int(b["fuel_units"])]
	if int(b["fuel_bps"]) != 1000 or int(a["fuel_bps"]) != 0:
		return "fuel_bps %d / %d" % [int(a["fuel_bps"]), int(b["fuel_bps"])]
	if int(hedged.cargo["FUEL"]) != 27:
		return "hedged hold %d, want 27" % int(hedged.cargo["FUEL"])
	return "ok"


func test_an_open_corridor_cuts_the_burn_and_stacks_with_the_hedge() -> String:
	var m := StationMarket.new()
	# Round 4: the Earth-Mars opposition is open (15 -> 10 fuel).
	var plain := _rc([], 5000, 4)
	var hedged := _rc(["fuel_hedge"], 5000, 4)
	plain.cargo = {"FUEL": 40}
	hedged.cargo = {"FUEL": 40}
	var a: Dictionary = plain.depart("mars", m)
	var b: Dictionary = hedged.depart("mars", m)
	if int(a["fuel_units"]) != 10 or int(b["fuel_units"]) != 9:
		return "corridor burn %d plain, %d hedged (want 10 and 9)" % [int(a["fuel_units"]), int(b["fuel_units"])]
	if int(a["fuel_units"]) != Transit.calculate_fuel_burn("earth", "mars", 4):
		return "departure does not go through Transit.calculate_fuel_burn"
	return "ok"


func test_a_shortfall_is_bought_at_the_asks_and_dents_the_book() -> String:
	var m := StationMarket.new()
	var rc := _rc()
	rc.cargo = {"FUEL": 5}
	var cr0: int = rc.cr
	var asks0: int = _ask_qty(m, "earth")
	var quote: Dictionary = m.sweep_quote("earth", "FUEL", "BUY", 10, 1.0e9)
	var can: Dictionary = rc.can_depart("mars", m)
	if int(can["fuel_hold"]) != 5 or int(can["fuel_buy"]) != 10 or int(can["fuel_cr"]) != int(quote["cost"]):
		return "preview %s vs quote %s" % [str(can), str(quote)]
	var res: Dictionary = rc.depart("mars", m)
	if not bool(res["ok"]):
		return "refused: %s" % str(res["reason"])
	if rc.cr != cr0 - int(quote["cost"]):
		return "paid %d, the sweep priced %d" % [cr0 - rc.cr, int(quote["cost"])]
	if rc.cargo.has("FUEL"):
		return "the hold's FUEL should be spent first and fully: %s" % str(rc.cargo)
	if _ask_qty(m, "earth") != asks0 - 10:
		return "the purchase should eat 10 units off the asks (%d -> %d)" % [asks0, _ask_qty(m, "earth")]
	if int(rc.transit["fuel_bought"]) != 10 or int(rc.transit["fuel_cr"]) != int(quote["cost"]):
		return "voyage record %s" % str(rc.transit)
	return "ok"


func test_a_broke_player_is_refused_not_put_into_debt() -> String:
	var m := StationMarket.new()
	var rc := _rc([], 20)
	rc.cargo = {"FUEL": 5, "ORE": 3}
	var asks0: int = _ask_qty(m, "earth")
	var res: Dictionary = rc.depart("mars", m)
	if bool(res["ok"]) or str(res["reason"]) != "INSUFFICIENT_FUEL":
		return "should refuse with INSUFFICIENT_FUEL, got %s" % str(res)
	if rc.cr != 20 or int(rc.cargo["FUEL"]) != 5 or rc.is_in_transit() or rc.docked_at != "earth":
		return "a refused departure changed state: cr %d cargo %s" % [rc.cr, str(rc.cargo)]
	if _ask_qty(m, "earth") != asks0 or rc.pending_bankruptcy:
		return "a refused departure touched the book or the books"
	# Exactly enough cash goes, and leaves zero, never less.
	var need: int = int(rc.can_depart("mars", m)["fuel_cr"])
	rc.cr = need
	if not bool(rc.depart("mars", m)["ok"]) or rc.cr != 0:
		return "exact cash should sail and leave 0, got cr %d" % rc.cr
	return "ok"


func test_the_belt_toll_and_the_fuel_must_both_be_affordable() -> String:
	var m := StationMarket.new()
	var rc := _rc([], 40)  # Earth -> Ceres: 30 fuel + a 25 CR toll
	var res: Dictionary = rc.can_depart("ceres", m)
	if bool(res["ok"]) or str(res["reason"]) != "INSUFFICIENT_FUEL":
		return "40 CR cannot cover toll and 30 fuel: %s" % str(res)
	rc.cr = 20
	if str(rc.can_depart("ceres", m)["reason"]) != "INSUFFICIENT_CR":
		return "a toll the player cannot pay is still INSUFFICIENT_CR"
	return "ok"


func test_a_drained_fuel_book_refuses_even_with_cash() -> String:
	var m := StationMarket.new()
	m.execute("earth", "FUEL", "BUY", _ask_qty(m, "earth"), 1.0e9)
	var rc := _rc([], 100000)
	var res: Dictionary = rc.depart("mars", m)
	if bool(res["ok"]) or str(res["reason"]) != "INSUFFICIENT_FUEL" or rc.cr != 100000:
		return "no fuel for sale should refuse: %s" % str(res)
	return "ok"


func test_the_player_can_trade_fuel_ahead_of_a_trip() -> String:
	var m := StationMarket.new()
	for st in ["earth", "luna", "mars", "ceres"]:
		m.unlock_station(st)  # books open as a station is reached; the departure station always has them
		if not m.has_book(st, "FUEL") or _ask_qty(m, st) <= 0:
			return "no live FUEL book at %s" % st
	var fill: Dictionary = m.execute("earth", "FUEL", "BUY", 15, 1.0e9)
	if int(fill["filled"]) != 15:
		return "could not buy 15 FUEL ahead of the trip"
	var rc := _rc()
	rc.cargo = {"FUEL": 15}
	var cr0: int = rc.cr
	if not bool(rc.depart("mars", m)["ok"]) or rc.cr != cr0:
		return "pre-bought fuel should pay the whole burn"
	return "ok"


func test_the_voyage_survives_a_save_and_the_burn_is_deterministic() -> String:
	var runs: Array = []
	for i in 2:
		var m := StationMarket.new()
		var rc := _rc(["fuel_hedge"])
		rc.cargo = {"FUEL": 3}
		rc.depart("ceres", m)
		runs.append({"cr": rc.cr, "transit": rc.transit.duplicate(), "book": JSON.stringify(m.to_dict()), "cargo": rc.cargo.duplicate()})
		var back: RunController = RunController.from_dict(JSON.parse_string(JSON.stringify(rc.to_dict())))
		if int(back.transit.get("fuel_burned", -1)) != int(rc.transit["fuel_burned"]) or int(back.transit.get("fuel_cr", -1)) != int(rc.transit["fuel_cr"]):
			return "the voyage lost its fuel record over a save: %s" % str(back.transit)
	if str(runs[0]) != str(runs[1]):
		return "two identical departures differed"
	if int(runs[0]["transit"]["fuel_burned"]) != 27:
		return "30 fuel less the 10%% hedge is 27, got %d" % int(runs[0]["transit"]["fuel_burned"])
	return "ok"


func test_rival_fleets_refuel_from_the_same_book() -> String:
	var m := StationMarket.new()
	var f := RivalFleet.new("r")
	f.at = "earth"
	var asks0: int = _ask_qty(m, "earth")
	var mid_cr: int = 15 * 14
	var paid: int = Rivals._buy_fuel(f, m, 15, mid_cr)
	if _ask_qty(m, "earth") != asks0 - 15:
		return "the fleet's fuel did not come off the book"
	var quote_cost: int = 0
	var fresh := StationMarket.new()
	quote_cost = int(fresh.sweep_quote("earth", "FUEL", "BUY", 15, 1.0e9)["cost"])
	if paid != quote_cost:
		return "fleet paid %d, book priced %d" % [paid, quote_cost]
	# No FUEL book at the station (a locked one): the old mid-price charge stands.
	var bare := StationMarket.new(["earth"])
	f.at = "ceres"
	if Rivals._buy_fuel(f, bare, 15, 300) != 300:
		return "a station with no book should charge the planning price"
	return "ok"


func test_the_scene_refuses_with_a_message_and_posts_the_burn() -> String:
	var m: MainScene = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	m.start_new_run(6)
	m.controller.ticks_per_round = TPR
	var rc: RunController = m.controller
	m.hud.set_station("ceres")
	rc.cr = 30
	rc.cargo = {}
	var r: String = "ok"
	if m.loop.depart_to_selected():
		r = "30 CR should not buy a 20-fuel trip plus the toll"
	elif m.loop.depart_message().find("FUEL") < 0:
		r = "refusal says nothing about fuel: %s" % m.loop.depart_message()
	elif rc.cr != 30 or rc.is_in_transit():
		r = "refusal changed state"
	else:
		rc.cr = 5000
		if not m.loop.depart_to_selected():
			r = "5000 CR should sail: %s" % m.loop.last_depart_reason
		elif int(rc.transit["fuel_burned"]) != 20:
			r = "Mars -> Ceres should burn 20 FUEL, got %s" % str(rc.transit)
	m.free()
	return r


func test_the_golden_scripted_player_still_sails_every_voyage_and_pays_fuel() -> String:
	var wg = load("res://tools/world_golden.gd")
	for sd in wg.SEEDS:
		var count := {"departures": 0, "burned": 0, "bought": 0, "was_moving": false}
		var obs := func(s: Replay.Session) -> void:
			var moving: bool = not s.controller.transit.is_empty()
			if moving and not bool(count["was_moving"]):
				count["departures"] += 1
				count["burned"] += int(s.controller.transit.get("fuel_burned", 0))
				count["bought"] += int(s.controller.transit.get("fuel_bought", 0))
			count["was_moving"] = moving
		var s: Replay.Session = wg.play(int(sd), obs)
		var voyages: int = (wg.VOYAGES as Dictionary).size()
		if int(count["departures"]) < voyages:
			return "seed %d: the golden player sailed %d of its %d voyages" % [sd, int(count["departures"]), voyages]
		if int(count["burned"]) <= 0:
			return "seed %d: the golden player's voyages burned no fuel" % sd
		if s.controller.cr < 0:
			return "seed %d: the golden player ended in debt" % sd
	return "ok"
