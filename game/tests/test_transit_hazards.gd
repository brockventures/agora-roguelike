class_name TestTransitHazards
extends RefCounted
## Golden-file deterministic surface parity tests for Transit, Hazards, and Piracy (Issue #4, PR 5).
## Verifies that GDScript deterministic formulas (routes, alignment windows, fuel burn,
## food decay, hazard quotes, and piracy odds tables) have zero drift against Python
## referee fixtures at commit 587b07f (e7fb174).
##
## Note: Seeded marble-bag RNG stream recording and replay validation are part of Task 5d (#5).

const FIXTURE_PATH := "res://tests/golden/transit_hazards/transit_hazards_golden.json"

func _load_fixture() -> Dictionary:
	if not FileAccess.file_exists(FIXTURE_PATH):
		return {}
	var text := FileAccess.get_file_as_string(FIXTURE_PATH)
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}

func test_fixture_loads_and_has_valid_keys() -> String:
	var data := _load_fixture()
	if data.is_empty():
		return "Failed to load golden fixture from %s" % FIXTURE_PATH
	if data.get("referee_commit") != "587b07f":
		return "expected referee_commit '587b07f', got '%s'" % str(data.get("referee_commit"))
	if not data.has("spatial") or not data.has("hazards") or not data.has("piracy"):
		return "fixture missing required sections (spatial, hazards, piracy)"
	return "ok"

func test_spatial_constants_and_routes_parity() -> String:
	var data := _load_fixture()
	var spatial: Dictionary = data.get("spatial", {})

	# Stations and commodities
	if Transit.STATIONS != spatial.get("stations", []):
		return "Transit.STATIONS mismatch"
	if Transit.COMMODITIES != spatial.get("commodities", []):
		return "Transit.COMMODITIES mismatch"
	if Transit.BELT_TOLL_CR != int(spatial.get("belt_toll_cr", 0)):
		return "Transit.BELT_TOLL_CR mismatch"

	# Commodity aliases
	var aliases: Dictionary = spatial.get("commodity_aliases", {})
	for a in aliases:
		var norm := Transit.normalize_commodity(str(a))
		if norm != aliases[a]:
			return "normalize_commodity('%s') returned '%s', expected '%s'" % [a, norm, aliases[a]]

	# Perishables
	for p in spatial.get("perishables", []):
		if not Transit.is_perishable(str(p)):
			return "is_perishable('%s') should be true" % p

	# Base prices
	var base_prices: Dictionary = spatial.get("base_prices", {})
	for st in base_prices:
		for comm in base_prices[st]:
			var exp_price: float = float(base_prices[st][comm])
			var act_price: float = float(Transit.BASE_PRICES[st][comm])
			if absf(act_price - exp_price) > 1e-6:
				return "BASE_PRICES[%s][%s] mismatch: act=%f exp=%f" % [st, comm, act_price, exp_price]

	return "ok"

func test_spatial_route_cases_parity() -> String:
	var data := _load_fixture()
	var route_cases: Array = data.get("spatial", {}).get("route_cases", [])
	if route_cases.is_empty():
		return "route_cases array is empty"

	for c in route_cases:
		var origin: String = c["origin"]
		var dest: String = c["dest"]
		var r_num: int = int(c["round"])
		var exp_route: Dictionary = c["route"]

		var act_route = Transit.get_route(origin, dest, r_num)
		if act_route == null:
			return "get_route('%s', '%s', %d) returned null" % [origin, dest, r_num]

		if int(act_route["rounds"]) != int(exp_route["rounds"]):
			return "rounds mismatch for %s->%s at r%d: act=%d exp=%d" % [
				origin, dest, r_num, act_route["rounds"], exp_route["rounds"]
			]
		if int(act_route["fuel"]) != int(exp_route["fuel"]):
			return "fuel mismatch for %s->%s at r%d: act=%d exp=%d" % [
				origin, dest, r_num, act_route["fuel"], exp_route["fuel"]
			]
		if bool(act_route["is_aligned"]) != bool(exp_route["is_aligned"]):
			return "is_aligned mismatch for %s->%s at r%d" % [origin, dest, r_num]
		if int(act_route["toll"]) != int(exp_route["toll"]):
			return "toll mismatch for %s->%s at r%d" % [origin, dest, r_num]
		if int(act_route["rounds_remaining"]) != int(exp_route["rounds_remaining"]):
			return "rounds_remaining mismatch for %s->%s at r%d: act=%d exp=%d" % [
				origin, dest, r_num, act_route["rounds_remaining"], exp_route["rounds_remaining"]
			]
		if absf(float(act_route["decay_rate"]) - float(exp_route["decay_rate"])) > 1e-6:
			return "decay_rate mismatch for %s->%s at r%d: act=%f exp=%f" % [
				origin, dest, r_num, act_route["decay_rate"], exp_route["decay_rate"]
			]

		var exp_wname = exp_route.get("window_name")
		var act_wname = act_route.get("window_name")
		if exp_wname == null:
			if act_wname != null:
				return "expected null window_name for %s->%s at r%d, got %s" % [origin, dest, r_num, str(act_wname)]
		else:
			if str(act_wname) != str(exp_wname):
				return "window_name mismatch for %s->%s at r%d: act=%s exp=%s" % [origin, dest, r_num, str(act_wname), str(exp_wname)]

		# Active window check
		var act_win = Transit.get_active_window_for_route(origin, dest, r_num)
		var exp_win = c["active_window"]
		if exp_win == null:
			if act_win != null:
				return "expected null active_window for %s->%s at r%d" % [origin, dest, r_num]
		else:
			if act_win == null:
				return "expected active_window for %s->%s at r%d, got null" % [origin, dest, r_num]
			if act_win["corridor_id"] != exp_win["corridor_id"]:
				return "corridor_id mismatch: act=%s exp=%s" % [act_win["corridor_id"], exp_win["corridor_id"]]

	return "ok"

func test_spatial_fuel_burn_parity() -> String:
	var data := _load_fixture()
	var fuel_cases: Array = data.get("spatial", {}).get("fuel_cases", [])
	if fuel_cases.is_empty():
		return "fuel_cases is empty"

	for fc in fuel_cases:
		var orig: String = fc["origin"]
		var dest: String = fc["dest"]
		var r_num: int = int(fc["round"])
		var engine_tier: int = int(fc["engine_tier"])
		var r_loop: bool = bool(fc["has_refinery_loop"])
		var corp_discount: float = float(fc["corp_fuel_discount"])
		var exp_fuel: int = int(fc["expected_fuel"])

		var act_fuel := Transit.calculate_fuel_burn(orig, dest, r_num, engine_tier, r_loop, corp_discount)
		if act_fuel != exp_fuel:
			return "calculate_fuel_burn(%s->%s, r%d, t%d, r_loop=%s, corp=%f) mismatch: act=%d exp=%d" % [
				orig, dest, r_num, engine_tier, str(r_loop), corp_discount, act_fuel, exp_fuel
			]
	return "ok"

func test_spatial_food_decay_parity() -> String:
	var data := _load_fixture()
	var decay_cases: Array = data.get("spatial", {}).get("decay_cases", [])
	if decay_cases.is_empty():
		return "decay_cases is empty"

	for dc in decay_cases:
		var comm: String = dc["commodity"]
		var orig: String = dc["origin"]
		var dest: String = dc["dest"]
		var qty: int = int(dc["qty"])
		var elapsed: int = int(dc["elapsed_rounds"])
		var exp_arrival: int = int(dc["arrival_decay"])
		var exp_projected: int = int(dc["projected_decay"])

		var act_arrival := Transit.calculate_arrival_decay(comm, qty, elapsed, orig, dest)
		if act_arrival != exp_arrival:
			return "arrival_decay(%s, qty=%d, el=%d, %s->%s) mismatch: act=%d exp=%d" % [
				comm, qty, elapsed, orig, dest, act_arrival, exp_arrival
			]

		var act_projected := Transit.calculate_projected_decay(comm, qty, elapsed, orig, dest)
		if act_projected != exp_projected:
			return "projected_decay(%s, qty=%d, el=%d, %s->%s) mismatch: act=%d exp=%d" % [
				comm, qty, elapsed, orig, dest, act_projected, exp_projected
			]
	return "ok"

func test_hazards_constants_and_quotes_parity() -> String:
	var data := _load_fixture()
	var hazards: Dictionary = data.get("hazards", {})

	if Hazards.DEFAULT_P_DELAY != float(hazards.get("default_p_delay", 0)):
		return "DEFAULT_P_DELAY mismatch"
	if Hazards.DEFAULT_P_LOSS != float(hazards.get("default_p_loss", 0)):
		return "DEFAULT_P_LOSS mismatch"

	# Quotes parity
	var engine := Hazards.new([0.10, 0.05], null, null, 7)
	for q_case in hazards.get("quotes", []):
		var df: float = float(q_case["delay_factor"])
		var lf: float = float(q_case["loss_factor"])
		var qty: int = int(q_case["total_qty"])
		var exp_q: Dictionary = q_case["quote"]

		var act_q := engine.quote(df, lf, 1.0, "", qty)
		if float(act_q["p_delay"]) != float(exp_q["p_delay"]):
			return "quote p_delay mismatch"
		if float(act_q["p_loss"]) != float(exp_q["p_loss"]):
			return "quote p_loss mismatch"
		if int(act_q["delay_rounds"][0]) != int(exp_q["delay_rounds"][0]) or int(act_q["delay_rounds"][1]) != int(exp_q["delay_rounds"][1]):
			return "quote delay_rounds mismatch"
		if int(act_q["expected_loss_qty"][0]) != int(exp_q["expected_loss_qty"][0]) or int(act_q["expected_loss_qty"][1]) != int(exp_q["expected_loss_qty"][1]):
			return "quote expected_loss_qty mismatch"

	return "ok"

func test_piracy_ref_prices_and_bag_odds_parity() -> String:
	var data := _load_fixture()
	var piracy: Dictionary = data.get("piracy", {})

	# Reference commodity prices
	var ref_prices: Dictionary = piracy.get("ref_prices", {})
	for comm in ref_prices:
		var exp_p: float = float(ref_prices[comm])
		var act_p: float = float(Piracy.REF_PRICE[comm])
		if absf(act_p - exp_p) > 1e-6:
			return "REF_PRICE[%s] mismatch" % comm

	# Bag odds fraction rounding
	for s in piracy.get("bag_odds_samples", []):
		var p: float = float(s["p"])
		var exp_q: float = float(s["bag_odds"])
		var act_q := Piracy.bag_odds(p)
		if absf(act_q - exp_q) > 1e-6:
			return "bag_odds(%f) mismatch: act=%f exp=%f" % [p, act_q, exp_q]

	return "ok"

func test_piracy_chance_calculations_parity() -> String:
	var data := _load_fixture()
	var chance_samples: Array = data.get("piracy", {}).get("chance_samples", [])
	if chance_samples.is_empty():
		return "chance_samples is empty"

	var desk := Piracy.new([0.15, 0.04], null, null, 42)
	for cs in chance_samples:
		var c_exp: Dictionary = cs["chance"]
		var hot_override: String = str(cs.get("hot_station", ""))
		var r_num: int = int(cs.get("round", 1))
		var c_act := desk.chance(
			cs["agent"], cs["origin"], cs["dest"], bool(cs["tolled"]),
			cs["comm"], int(cs["qty"]), bool(cs["escort"]), r_num,
			null, false, 1.0, 0, 1.0, 0, false, hot_override
		)

		# Exact odds comparison: odds are rounded to 4 decimals, no epsilon tolerance allowed
		if float(c_act["odds"]) != float(c_exp["odds"]):
			return "chance odds mismatch for %s->%s %s (qty %d, escort %s, r%d): act=%f exp=%f" % [
				cs["origin"], cs["dest"], cs["comm"], int(cs["qty"]), str(cs["escort"]), r_num, c_act["odds"], c_exp["odds"]
			]
		if absf(float(c_act["base"]) - float(c_exp["base"])) > 1e-6:
			return "chance base mismatch"
		if bool(c_act["hot"]) != bool(c_exp["hot"]):
			return "chance hot mismatch for %s->%s at r%d (hot_st=%s): act=%s exp=%s" % [
				cs["origin"], cs["dest"], r_num, hot_override, str(c_act["hot"]), str(c_exp["hot"])
			]
		if int(c_act["value"]) != int(c_exp["value"]):
			return "chance cargo value mismatch"
		if absf(float(c_act["value_mult"]) - float(c_exp["value_mult"])) > 1e-6:
			return "chance value_mult mismatch: act=%f exp=%f" % [c_act["value_mult"], c_exp["value_mult"]]
		if bool(c_act["escort"]) != bool(c_exp["escort"]):
			return "chance escort mismatch"

	return "ok"
