extends RefCounted
## Draw-level golden fixtures (#5, checklist 5d): bag, hazard, piracy and spatial draws.
##
## Every fixture in tests/golden/draws/ (tools/golden/gen_draws.py) holds, per call, the input, the
## ordered draw log recorded from the Python referee, the output and the marble-bag state after
## the call. This file replays each call through the GDScript port (bag.gd, hazards.gd, piracy.gd)
## with a ReplayDrawSource carrying that call's draws, and asserts:
##   - the output is identical,
##   - the draws are consumed in the recorded order and count (ReplayDrawSource fails on a
##     mismatch, an extra draw, or a missing draw),
##   - the bag state after the call matches row for row (marbles, refills, credit, draws, hits).
##
## Pending, never silently passing:
##   PENDING_CASES       the whole engine comparison waits for a port that does not exist yet
##                       (fixture shape is still checked); each prints a PENDING line.
##   KNOWN_DIVERGENCES   a single output field where the port is known to differ from the
##                       referee. Draws, order, count and bag state are still asserted for the
##                       case; only the named field is skipped, with a DIVERGENCE line.

const Loader = preload("res://tests/golden/golden_loader.gd")

const BAG_CASES := [
	"bag_one_in_four_refills",
	"bag_three_in_ten_runs",
	"bag_p_change_rebuilds_bag",
	"bag_fleets_are_isolated",
	"bag_varying_credit",
	"bag_non_bag_odds_use_credit",
	"bag_edge_odds_no_draw",
]
const HAZARD_CASES := [
	"hazard_roll_both_types",
	"hazard_roll_delay_only",
	"hazard_roll_loss_only",
	"hazard_roll_upgrade_factors",
	"hazard_roll_zero_cargo",
	"hazard_roll_certain_odds",
	"hazard_roll_ships_isolated",
	"hazard_roll_disabled",
]
const PIRACY_CASES := [
	"piracy_hot_station_windows",
	"piracy_raid_roll_miss",
	"piracy_raid_roll_hit",
	"piracy_raid_roll_escorted",
	"piracy_raid_roll_certain",
	"piracy_zero_cargo_no_raid_draw",
	"piracy_disabled_no_draw",
	"piracy_respond_pay",
	"piracy_respond_surrender",
	"piracy_respond_fight_escaped",
	"piracy_respond_fight_lost",
	"piracy_respond_rejects_draw_nothing",
	"piracy_privateer_trace_hit",
	"piracy_privateer_trace_miss",
]
const SPATIAL_CASES := [
	"spatial_price_walk_gauss",
]

## case -> reason. The engine comparison is not run for these.
const PENDING_CASES := {
	"spatial_price_walk_gauss": "no GDScript port of agora.spatial.StationPriceEngine (the mean-reverting price "
		+ "walk, one gauss(0, vol) per station and commodity) exists in core/; transit.gd carries the "
		+ "deterministic routes and base prices only",
}

## case -> {field -> reason}. Only that output field is skipped; everything else is asserted.
const KNOWN_DIVERGENCES := {
	"piracy_respond_surrender": {
		"fenced_at": "referee stores the fence account ('depot_ceres' when depots are on, null when off, "
			+ "_fence_account in piracy.py); piracy.gd always writes the station name 'ceres'",
	},
	"piracy_respond_fight_lost": {
		"fenced_at": "referee stores the fence account ('depot_ceres' when depots are on, null when off, "
			+ "_fence_account in piracy.py); piracy.gd always writes the station name 'ceres'",
	},
}

const ODDS_TOLERANCE := 1e-9


func _case(name: String) -> Dictionary:
	return Loader.load_fixture(Loader.DRAWS_DIR.path_join(name + ".json"))["data"]


func _all_cases() -> Array:
	var out: Array = []
	out.append_array(BAG_CASES)
	out.append_array(HAZARD_CASES)
	out.append_array(PIRACY_CASES)
	out.append_array(SPATIAL_CASES)
	return out


func _draw_case_files() -> Array:
	var names: Array = []
	for p in Loader.list_fixtures(Loader.DRAWS_DIR):
		var base: String = p.get_file().get_basename()
		if base == "sample":
			continue  # the 5b recorder sample, a bare array, not a draw case
		names.append(base)
	return names


# ------------------------------------------------------------------ shape and coverage

func test_fixtures_present() -> String:
	var found := _draw_case_files()
	for c in _all_cases():
		if not found.has(c):
			return "missing fixture '%s' (found %s)" % [c, found]
	return "ok"


func test_every_fixture_loads_and_validates() -> String:
	for name in _draw_case_files():
		var res := Loader.load_fixture(Loader.DRAWS_DIR.path_join(name + ".json"))
		if res["error"] != "":
			return res["error"]
		var err := Loader.validate_draw_case(res["data"])
		if err != "":
			return "%s: %s" % [name, err]
		if res["data"]["case"] != name:
			return "%s: case name '%s' does not match file name" % [name, res["data"]["case"]]
	return "ok"


func test_golden_draws_coverage() -> String:
	var on_disk := _draw_case_files()
	var expected := _all_cases()
	for f in on_disk:
		if not expected.has(f):
			return "fixture '%s' is not in a *_CASES list; add it and a replay" % f
	for n in expected:
		if not on_disk.has(n):
			return "expected fixture '%s' has no .json under %s" % [n, Loader.DRAWS_DIR]
	for n in PENDING_CASES:
		if not expected.has(n):
			return "PENDING_CASES names unknown case '%s'" % n
	for n in KNOWN_DIVERGENCES:
		if not expected.has(n) or PENDING_CASES.has(n):
			return "KNOWN_DIVERGENCES names '%s', which is unknown or already pending" % n
	return "ok"


func test_edge_odds_cases_make_no_draw() -> String:
	# Zero-draw steps are the contract of p <= 0, p >= 1, a disabled desk and a zero-cargo raid roll.
	var edge := _case("bag_edge_odds_no_draw")
	var bag: Array = edge["steps"]
	for i in range(8):
		if not bag[i]["draws"].is_empty():
			return "bag_edge_odds_no_draw step %d drew" % i
		if bag[i]["bag_after"] != edge["bag_start"]:
			return "bag_edge_odds_no_draw step %d changed bag state" % i
	for name in ["hazard_roll_disabled", "piracy_disabled_no_draw"]:
		for step in _case(name)["steps"]:
			if not step["draws"].is_empty():
				return "%s drew with the desk off" % name
	var zero := _case("piracy_zero_cargo_no_raid_draw")
	var calls: Array = []
	for d in zero["steps"][0]["draws"]:
		calls.append(d["call"])
	if calls != ["choice"] or not zero["bag_end"].is_empty():
		return "a zero-cargo raid roll should draw only the hot-station choice, got %s" % [calls]
	return "ok"


# ------------------------------------------------------------------ replay

func test_replay_bag_cases() -> String:
	for name in BAG_CASES:
		var err := _replay_bag(name)
		if err != "":
			return "%s: %s" % [name, err]
	return "ok"


func test_replay_hazard_cases() -> String:
	for name in HAZARD_CASES:
		var err := _replay_hazards(name)
		if err != "":
			return "%s: %s" % [name, err]
	return "ok"


func test_replay_piracy_cases() -> String:
	for name in PIRACY_CASES:
		var err := _replay_piracy(name)
		if err != "":
			return "%s: %s" % [name, err]
	return "ok"


func test_pending_cases_are_reported_and_shape_checked() -> String:
	for name in PENDING_CASES:
		var data := _case(name)
		var draws := 0
		for step in data["steps"]:
			for d in step["draws"]:
				if d["call"] != "gauss":
					return "%s: expected only gauss draws, got %s" % [name, d["call"]]
				draws += 1
		if draws == 0:
			return "%s: no draws recorded" % name
		print("PENDING %s: %s" % [name, PENDING_CASES[name]])
	return "ok"


# ------------------------------------------------------------------ bag

func _replay_bag(name: String) -> String:
	var data := _case(name)
	var setup: Dictionary = data["setup"]
	var bags := Bags.new(str(setup["ns"]), null, int(setup["seed"]))
	var err := _bag_diff(bags, data["bag_start"])
	if err != "":
		return "bag_start: %s" % err
	var i := 0
	for step in data["steps"]:
		var rep := ReplayDrawSource.new(step["draws"])
		bags.draw_source = rep
		var inp: Dictionary = step["input"]
		var hit: bool
		if step["call"] == "draw":
			hit = bags.draw(str(inp["event"]), str(inp["fleet"]), float(inp["p"]))
		else:
			hit = bags.draw_varying(str(inp["event"]), str(inp["fleet"]), float(inp["p"]))
		var label := "step %d (%s %s/%s p=%s)" % [i, step["call"], inp["event"], inp["fleet"], inp["p"]]
		err = _draws_failure(rep, label)
		if err != "":
			return err
		if hit != bool(step["output"]["result"]):
			return "%s: result %s, expected %s" % [label, hit, step["output"]["result"]]
		err = _bag_diff(bags, step["bag_after"])
		if err != "":
			return "%s: bag state: %s" % [label, err]
		i += 1
	return _bag_diff(bags, data["bag_end"])


# ------------------------------------------------------------------ hazards

func _replay_hazards(name: String) -> String:
	var data := _case(name)
	var setup: Dictionary = data["setup"]
	var odds: Variant = setup["odds"]
	var engine := Hazards.new(odds, null, null, int(setup["seed"]))
	var i := 0
	for step in data["steps"]:
		var rep := ReplayDrawSource.new(step["draws"])
		engine.draw_source = rep
		engine.bags.draw_source = rep
		var inp: Dictionary = step["input"]
		var total_qty: Variant = inp["total_qty"]
		if total_qty != null:
			total_qty = int(total_qty)
		var res: Dictionary = engine.roll(int(inp["cargo_qty"]), float(inp["delay_factor"]),
			float(inp["loss_factor"]), float(inp["loss_size_factor"]), str(inp["agent_id"]), total_qty)
		var label := "step %d (roll %s qty %s)" % [i, inp["agent_id"], inp["cargo_qty"]]
		var err := _draws_failure(rep, label)
		if err != "":
			return err
		var want: Dictionary = step["output"]
		if int(res["delay"]) != int(want["delay"]) or int(res["lost"]) != int(want["lost"]) \
				or str(res["note"]) != str(want["note"]):
			return "%s: output %s, expected %s" % [label, res, want]
		err = _bag_diff(engine.bags, step["bag_after"])
		if err != "":
			return "%s: bag state: %s" % [label, err]
		i += 1
	return _bag_diff(engine.bags, data["bag_end"])


# ------------------------------------------------------------------ piracy

func _replay_piracy(name: String) -> String:
	var data := _case(name)
	var setup: Dictionary = data["setup"]
	var desk := Piracy.new(setup["piracy"], null, null, int(setup["seed"]))
	for op in setup["prep"]:
		if op["op"] == "hire":
			var hired: Dictionary = desk.hire(str(op["sponsor"]), str(op["target"]), int(op["round"]))
			if hired["kind"] != "privateer_hire_ok":
				return "prep hire failed: %s" % [hired]
		# op 'initiate_transit' only put the ship in flight in the referee; roll_departure takes
		# the trip details from the step input.
	var skips: Dictionary = KNOWN_DIVERGENCES.get(name, {})
	var i := 0
	for step in data["steps"]:
		var rep := ReplayDrawSource.new(step["draws"])
		desk.draw_source = rep
		desk.bags.draw_source = rep
		var label := "step %d (%s)" % [i, step["call"]]
		var err := ""
		match step["call"]:
			"hot_station":
				var station: String = desk.hot_station(int(step["input"]["round"]))
				if station != str(step["output"]["station"]):
					err = "%s: hot station %s, expected %s" % [label, station, step["output"]["station"]]
			"roll_departure":
				err = _check_roll(desk, step, label)
			"respond":
				err = _check_respond(desk, step, label, skips)
			_:
				err = "%s: unknown call" % label
		if err != "":
			return err
		err = _draws_failure(rep, label)
		if err != "":
			return err
		err = _bag_diff(desk.bags, step["bag_after"])
		if err != "":
			return "%s: bag state: %s" % [label, err]
		i += 1
	for field in skips:
		print("DIVERGENCE %s.%s skipped: %s" % [name, field, skips[field]])
	return _bag_diff(desk.bags, data["bag_end"])


func _check_roll(desk: Piracy, step: Dictionary, label: String) -> String:
	var a: Dictionary = step["input"]
	var out: Variant = desk.roll_departure(
		str(a["transit_id"]), str(a["agent"]), str(a["origin"]), str(a["dest"]), bool(a["tolled"]),
		str(a["commodity"]), int(a["qty"]), bool(a["escort"]), int(a["round"]), str(a["vessel_id"]),
		int(a["hold_value"]), int(a["total_qty"]))
	var want: Dictionary = step["output"]
	if want["result"] == null:
		return "" if out == null else "%s: expected no result (desk off), got %s" % [label, out]
	if out == null:
		return "%s: roll_departure returned null, expected %s" % [label, want["result"]]
	var res: Dictionary = want["result"]
	for k in res:
		if not _same_value(out.get(k), res[k]):
			return "%s: result.%s is %s, expected %s" % [label, k, out.get(k), res[k]]
	var demand: Variant = out.get("demand")
	if want["demand"] == null:
		if demand != null:
			return "%s: unexpected demand %s" % [label, demand]
		return ""
	if demand == null:
		return "%s: expected a demand, got none" % label
	var wd: Dictionary = want["demand"]
	for k in wd:
		if not _same_value(demand.get(k), wd[k]):
			return "%s: demand.%s is %s, expected %s" % [label, k, demand.get(k), wd[k]]
	return ""


func _check_respond(desk: Piracy, step: Dictionary, label: String, skips: Dictionary) -> String:
	var a: Dictionary = step["input"]
	var resp: Dictionary = desk.respond(str(a["agent_id"]), str(a["transit_id"]), str(a["choice"]),
		int(a["available_cr"]))
	var want: Dictionary = step["output"]
	if resp["kind"] != want["kind"]:
		return "%s: kind %s, expected %s" % [label, resp["kind"], want["kind"]]
	if want["kind"] == "reject":
		if resp["payload"]["reason"] != want["reason"]:
			return "%s: reject reason %s, expected %s" % [label, resp["payload"]["reason"], want["reason"]]
		return ""
	var raid: Dictionary = want["raid"]
	for k in raid:
		if skips.has(k):
			continue
		if not _same_value(resp["payload"].get(k), raid[k]):
			return "%s: raid.%s is %s, expected %s" % [label, k, resp["payload"].get(k), raid[k]]
	return ""


# ------------------------------------------------------------------ helpers

func _same_value(a: Variant, b: Variant) -> bool:
	var a_num := typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT
	var b_num := typeof(b) == TYPE_INT or typeof(b) == TYPE_FLOAT
	if a_num and b_num:
		return absf(float(a) - float(b)) <= ODDS_TOLERANCE
	return typeof(a) == typeof(b) and a == b


## "" when the replay consumed exactly the recorded draws, in order; else the first failure.
func _draws_failure(rep: ReplayDrawSource, label: String) -> String:
	rep.assert_exhausted()
	if rep.ok():
		return ""
	return "%s: draw log %s: %s" % [label, rep.failure.get("reason", "?"), JSON.stringify(rep.failure)]


## "" when the port's bag rows equal the fixture rows (the __seed__ row is not recorded).
func _bag_diff(bags: Bags, rows: Array) -> String:
	var have: Dictionary = bags._bags
	if have.size() != rows.size():
		return "%d bag rows, fixture has %d (%s)" % [have.size(), rows.size(), have.keys()]
	for row in rows:
		var key := "%s:%s" % [row["event"], row["fleet"]]
		if not have.has(key):
			return "missing bag row %s (have %s)" % [key, have.keys()]
		var got: Dictionary = have[key]
		if str(got["marbles"]) != str(row["marbles"]):
			return "%s marbles '%s', expected '%s'" % [key, got["marbles"], row["marbles"]]
		for k in ["seed", "refills", "draws", "hits"]:
			if int(got[k]) != int(row[k]):
				return "%s %s is %s, expected %s" % [key, k, got[k], row[k]]
		for k in ["p", "credit"]:
			if absf(float(got[k]) - float(row[k])) > ODDS_TOLERANCE:
				return "%s %s is %s, expected %s" % [key, k, got[k], row[k]]
	return ""
