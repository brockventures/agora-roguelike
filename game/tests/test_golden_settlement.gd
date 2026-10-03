extends RefCounted
## Settlement and ledger golden fixtures (#5, checklist 5c): schema and
## zero-sum checks. There is no GDScript settlement port yet, so nothing is
## replayed.
##
## Coverage: test_settlement_fixture_coverage fails when a fixture file is
## unclassified. Every settlement fixture is REFEREE_LEVEL (settlement, escrow,
## fees and bag draws all live in the referee, not the order book). Replay is
## pending until res://core/referee.gd exists; from then on
## res://tests/test_referee.gd must call _replay_settlement_fixture("<name>", ...)
## for every listed fixture, the same rule test_golden_orderbook.gd applies to
## its REFEREE_LEVEL list. A later PR satisfies it by adding the calls; it never
## needs to edit this file.

const Loader = preload("res://tests/golden/golden_loader.gd")

## Cases the generator (tools/golden/gen_settlement.py) must produce.
const EXPECTED_CASES := [
	"simple_fill",
	"non_default_ship_fill",
	"partial_fill_two_rounds",
	"equity_fee",
	"escorted_departure_raid_paid",
	"hazard_round_trip_bags",
]

## Every settlement fixture replays at referee level.
const REFEREE_LEVEL := [
	"simple_fill",
	"non_default_ship_fill",
	"partial_fill_two_rounds",
	"equity_fee",
	"escorted_departure_raid_paid",
	"hazard_round_trip_bags",
]

## Fixtures whose cases draw marbles, so their rng_bags rows must change.
const BAG_CASES := ["escorted_departure_raid_paid", "hazard_round_trip_bags"]

const REFEREE_SCRIPT := "res://core/referee.gd"
const REFEREE_TEST := "res://tests/test_referee.gd"


func _paths() -> Array:
	return Loader.list_fixtures(Loader.SETTLEMENT_DIR)


func _case(name: String) -> Dictionary:
	return Loader.load_fixture(Loader.SETTLEMENT_DIR.path_join(name + ".json"))["data"]


func _all_ledger(data: Dictionary) -> Array:
	var rows: Array = []
	rows.append_array(data["prep_ledger"])
	for step in data["steps"]:
		rows.append_array(step["ledger"])
	return rows


func test_settlement_fixtures_present() -> String:
	var found: Array = []
	for p in _paths():
		found.append(p.get_file().get_basename())
	for c in EXPECTED_CASES:
		if not found.has(c):
			return "missing settlement fixture '%s' (found %s)" % [c, found]
	return "ok"


func test_every_settlement_fixture_loads_and_validates() -> String:
	var paths := _paths()
	if paths.is_empty():
		return "no fixtures found in %s" % Loader.SETTLEMENT_DIR
	for p in paths:
		var res := Loader.load_fixture(p)
		if res["error"] != "":
			return res["error"]
		var err := Loader.validate_settlement(res["data"])
		if err != "":
			return "%s: %s" % [p.get_file(), err]
		if res["data"]["case"] != p.get_file().get_basename():
			return "%s: case name '%s' does not match file name" % [p.get_file(), res["data"]["case"]]
	return "ok"


func test_every_txn_sums_to_zero_per_instrument() -> String:
	for p in _paths():
		var data: Dictionary = Loader.load_fixture(p)["data"]
		var rows := _all_ledger(data)
		if rows.is_empty():
			return "%s: no ledger rows" % p.get_file()
		var sums := Loader.txn_sums(rows)
		for key in sums:
			if sums[key] != 0:
				return "%s: txn|instrument %s sums to %d, not 0" % [p.get_file(), key, sums[key]]
	return "ok"


func test_bag_rows_present_at_start_and_end() -> String:
	for p in _paths():
		var data: Dictionary = Loader.load_fixture(p)["data"]
		for key in ["rng_bags_start", "rng_bags_end"]:
			var seeds := 0
			for r in data[key]:
				if r["event"] == "__seed__":
					seeds += 1
					if int(r["seed"]) != int(data["setup"]["seed"]):
						return "%s %s: seed row %s != case seed %s" % [p.get_file(), key, r["seed"], data["setup"]["seed"]]
			if seeds == 0:
				return "%s %s: no __seed__ row" % [p.get_file(), key]
	return "ok"


func test_bag_cases_change_bag_state_and_others_do_not() -> String:
	for p in _paths():
		var name: String = p.get_file().get_basename()
		var data: Dictionary = Loader.load_fixture(p)["data"]
		var changed: bool = JSON.stringify(data["rng_bags_start"]) != JSON.stringify(data["rng_bags_end"])
		if BAG_CASES.has(name) and not changed:
			return "%s: expected rng_bags to change over the case" % name
		if not BAG_CASES.has(name) and changed:
			return "%s: rng_bags changed but the case is not listed in BAG_CASES" % name
	return "ok"


func test_ledger_rows_reference_balanced_ship_accounts() -> String:
	# A non-default ship's goods settle on the named vessel's account.
	var d := _case("non_default_ship_fill")
	var sale_goods: Array = []
	for r in d["steps"][1]["ledger"]:
		if r["instrument"] == "FRAG":
			sale_goods.append(r["agent_id"])
	sale_goods.sort()
	if sale_goods != ["amos/2", "marvin/1"]:
		return "sale must settle FRAG on amos/2 and marvin/1, got %s" % [sale_goods]
	return "ok"


func test_equity_fee_is_its_own_txn() -> String:
	var fee_rows := 0
	for r in _all_ledger(_case("equity_fee")):
		if str(r["txn_id"]).begins_with("exchange-fee-"):
			fee_rows += 1
	if fee_rows != 4:
		return "expected 4 exchange-fee ledger rows, got %d" % fee_rows
	return "ok"


func test_validator_rejects_malformed() -> String:
	if Loader.validate_settlement({}) == "":
		return "empty fixture should not validate"
	var d := _case("simple_fill").duplicate(true)
	d["rng_bags_end"] = []
	if Loader.validate_settlement(d) == "":
		return "empty rng_bags_end should not validate"
	d = _case("simple_fill").duplicate(true)
	d["steps"][0]["ledger"] = [{"txn_id": "x"}]
	if Loader.validate_settlement(d) == "":
		return "ledger row without delta should not validate"
	var sums := Loader.txn_sums([
		{"txn_id": "t", "instrument": "CR", "delta": -5},
		{"txn_id": "t", "instrument": "CR", "delta": 4}])
	if sums["t|CR"] == 0:
		return "an unbalanced txn must not sum to zero"
	return "ok"


func test_settlement_fixture_coverage() -> String:
	var on_disk: Array = []
	for p in _paths():
		on_disk.append(p.get_file().get_basename())
	for f in on_disk:
		if not REFEREE_LEVEL.has(f):
			return "settlement fixture '%s' is not in REFEREE_LEVEL; classify it and add a replay" % f
	for n in REFEREE_LEVEL:
		if not on_disk.has(n):
			return "listed fixture '%s' has no .json under %s" % [n, Loader.SETTLEMENT_DIR]
	# Pending until the referee port exists; then test_referee.gd must replay each one.
	if ResourceLoader.exists(REFEREE_SCRIPT):
		var err := _require_calls(REFEREE_TEST, "_replay_settlement_fixture", REFEREE_LEVEL)
		return err if err != "" else "ok"
	return "ok"


## Returns "" when every name in `names` appears as a real `fn_name("<name>"` call
## (followed by "," or ")") in a non-comment line of `path`, else a failure message.
func _require_calls(path: String, fn_name: String, names: Array) -> String:
	if not FileAccess.file_exists(path):
		return "%s does not exist; it must call %s(...) for %s" % [path, fn_name, names]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "cannot read %s" % path
	var code_lines: Array = []
	for line in f.get_as_text().split("\n"):
		if not line.strip_edges().begins_with("#"):
			code_lines.append(line)
	var code := "\n".join(code_lines)
	for n in names:
		var re := RegEx.create_from_string('%s\\(\\s*"%s"\\s*[,)]' % [fn_name, n])
		if re.search(code) == null:
			return "fixture '%s' has no %s(\"%s\"...) call in %s" % [n, fn_name, n, path]
	return ""
