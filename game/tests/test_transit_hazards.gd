class_name TestTransitHazards
extends RefCounted
## Golden-file parity tests for Transit, Hazards, and Piracy (Issue #4, PR 5).
## Verifies that GDScript engine logic has zero drift against Python referee fixtures
## at commit 587b07f (e7fb174).

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

func test_hazards_constants_and_quotes_parity() -> String:
	var data := _load_fixture()
	var hazards: Dictionary = data.get("hazards", {})

	if Hazards.DEFAULT_P_DELAY != float(hazards.get("default_p_delay", 0)):
		return "DEFAULT_P_DELAY mismatch"
	if Hazards.DEFAULT_P_LOSS != float(hazards.get("default_p_loss", 0)):
		return "DEFAULT_P_LOSS mismatch"

	# CME corridor helper check: true for earth-mars, mars-earth, luna-mars, mars-luna
	var cme_pairs: Array[String] = ["earth:mars", "mars:earth", "luna:mars", "mars:luna"]
	for o in Transit.STATIONS:
		for d in Transit.STATIONS:
			if o == d:
				continue
			var act_cme := Hazards.is_cme_corridor(o, d)
			var pair_key := "%s:%s" % [o, d]
			var exp_cme := pair_key in cme_pairs
			if act_cme != exp_cme:
				return "is_cme_corridor(%s, %s) mismatch: act=%s exp=%s" % [o, d, act_cme, exp_cme]

	# Quotes parity
	var engine := Hazards.new([0.10, 0.05], null, null, 7)
	for q_case in hazards.get("quotes", []):
		var df: float = float(q_case["delay_factor"])
		var lf: float = float(q_case["loss_factor"])
		var qty: int = int(q_case["total_qty"])
		var exp_q: Dictionary = q_case["quote"]

		var act_q := engine.quote(df, lf, 1.0, "", qty)
		if absf(float(act_q["p_delay"]) - float(exp_q["p_delay"])) > 1e-4:
			return "quote p_delay mismatch"
		if absf(float(act_q["p_loss"]) - float(exp_q["p_loss"])) > 1e-4:
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
		var c_act := desk.chance(
			cs["agent"], cs["origin"], cs["dest"], bool(cs["tolled"]),
			cs["comm"], int(cs["qty"]), bool(cs["escort"]), 1,
			null, false, 1.0, 0, 1.0, 0, false, hot_override
		)

		if absf(float(c_act["odds"]) - float(c_exp["odds"])) > 1e-4:
			return "chance odds mismatch for %s->%s %s: act=%f exp=%f" % [
				cs["origin"], cs["dest"], cs["comm"], c_act["odds"], c_exp["odds"]
			]
		if absf(float(c_act["base"]) - float(c_exp["base"])) > 1e-4:
			return "chance base mismatch"
		if int(c_act["value"]) != int(c_exp["value"]):
			return "chance cargo value mismatch"
		if absf(float(c_act["value_mult"]) - float(c_exp["value_mult"])) > 1e-4:
			return "chance value_mult mismatch: act=%f exp=%f" % [c_act["value_mult"], c_exp["value_mult"]]
		if bool(c_act["escort"]) != bool(c_exp["escort"]):
			return "chance escort mismatch"

	return "ok"
