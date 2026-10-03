extends RefCounted
## Settlement and ledger golden fixtures (#5, checklist 5c): shape and
## double-entry checks.
##
## No GDScript settlement or ledger code exists in core/ yet (the referee port
## is still to come), so the engine comparison is pending, same as 5a's
## REFEREE_LEVEL cases. test_golden_settlement_coverage fails when a fixture is
## unclassified; once REFEREE_SCRIPT exists it also requires REFEREE_TEST to call
## _replay_settlement_fixture("<name>", ...) for every case. A later PR satisfies
## that by adding the calls; it never needs to edit this file.

const Loader = preload("res://tests/golden/golden_loader.gd")

## Cases the generator (tools/golden/gen_settlement.py) must produce.
const EXPECTED_CASES := [
	"simple_trade",
	"multi_party_sweep",
	"two_ship_ledger",
	"self_cross_ledger",
	"reject_insufficient_balance",
	"stock_exchange_fee",
	"idle_fee",
	"transit_hazard_loss_and_pay_ransom",
	"piracy_surrender",
	"piracy_fight_escape_bag",
	"transit_no_hit",
]

## Cases whose settlement draws from the marble bag (bag_start != bag_end).
const BAG_CASES := [
	"transit_hazard_loss_and_pay_ransom",
	"piracy_surrender",
	"piracy_fight_escape_bag",
	"transit_no_hit",
]

const REFEREE_SCRIPT := "res://core/referee.gd"
const REFEREE_TEST := "res://tests/test_referee_settlement.gd"


func _case(name: String) -> Dictionary:
	return Loader.load_fixture(Loader.SETTLEMENT_DIR.path_join(name + ".json"))["data"]


func test_fixtures_present() -> String:
	var found: Array = []
	for p in Loader.list_fixtures(Loader.SETTLEMENT_DIR):
		found.append(p.get_file().get_basename())
	for c in EXPECTED_CASES:
		if not found.has(c):
			return "missing fixture '%s' (found %s)" % [c, found]
	return "ok"


func test_every_fixture_loads_and_validates() -> String:
	var paths := Loader.list_fixtures(Loader.SETTLEMENT_DIR)
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
		if not res["data"]["final_invariants_ok"]:
			return "%s: referee reported a ledger invariant failure" % p.get_file()
	return "ok"


func test_trade_ledger_moves_cr_and_goods() -> String:
	var entries: Array = _case("simple_trade")["steps"][1]["ledger_entries"]
	if entries.size() != 4:
		return "a single trade writes 4 ledger entries, got %d" % entries.size()
	var by_key := {}
	for e in entries:
		by_key["%s:%s" % [e["agent_id"], e["instrument"]]] = int(e["delta"])
	var want := {"marvin:CR": -65, "amos:CR": 65, "marvin/1:FRAG": 5, "amos/1:FRAG": -5}
	for k in want:
		if not by_key.has(k) or by_key[k] != want[k]:
			return "expected %s = %d, got %s" % [k, want[k], by_key]
	return "ok"


func test_rejects_write_no_ledger_entries() -> String:
	var data := _case("reject_insufficient_balance")
	var rejects := 0
	for step in data["steps"]:
		if step["response"]["kind"] == "reject":
			rejects += 1
			if step["response"]["payload"]["reason"] != "insufficient_balance":
				return "unexpected reject reason %s" % step["response"]["payload"]["reason"]
		if not step["ledger_entries"].is_empty():
			return "a step wrote ledger entries in a reject case"
	if rejects != 2:
		return "expected 2 rejects, got %d" % rejects
	return "ok"


func test_bag_cases_advance_the_bag_and_record_draws() -> String:
	for name in BAG_CASES:
		var data := _case(name)
		if data["bag_start"] == data["bag_end"]:
			return "%s: bag state did not change" % name
		var draws := 0
		for step in data["steps"]:
			draws += step["draws"].size()
		if draws == 0:
			return "%s: no draws recorded" % name
	return "ok"


func test_non_bag_cases_leave_the_bag_alone() -> String:
	for name in EXPECTED_CASES:
		if BAG_CASES.has(name):
			continue
		var data := _case(name)
		if data["bag_start"] != data["bag_end"]:
			return "%s: bag state changed in a case with no draws" % name
		for step in data["steps"]:
			if not step["draws"].is_empty():
				return "%s: unexpected draws" % name
	return "ok"


func test_validator_rejects_malformed() -> String:
	if Loader.validate_settlement({}) == "":
		return "empty fixture should not validate"
	var data := _case("simple_trade").duplicate(true)
	data["steps"][1]["ledger_entries"][0]["delta"] = int(data["steps"][1]["ledger_entries"][0]["delta"]) + 1
	if Loader.validate_settlement(data) == "":
		return "a ledger that does not sum to 0 should not validate"
	var bad := _case("simple_trade").duplicate(true)
	bad["referee_commit"] = "deadbee"
	if Loader.validate_settlement(bad) == "":
		return "wrong referee_commit should not validate"
	return "ok"


func test_golden_settlement_coverage() -> String:
	var on_disk: Array = []
	for p in Loader.list_fixtures(Loader.SETTLEMENT_DIR):
		on_disk.append(p.get_file().get_basename())
	for f in on_disk:
		if not EXPECTED_CASES.has(f):
			return "fixture '%s' is not in EXPECTED_CASES; add it and a replay" % f
	for n in EXPECTED_CASES:
		if not on_disk.has(n):
			return "expected fixture '%s' has no .json under %s" % [n, Loader.SETTLEMENT_DIR]
	# Engine comparison is pending until the referee port exists at REFEREE_SCRIPT.
	if ResourceLoader.exists(REFEREE_SCRIPT):
		return _require_calls(REFEREE_TEST, "_replay_settlement_fixture", EXPECTED_CASES)
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
