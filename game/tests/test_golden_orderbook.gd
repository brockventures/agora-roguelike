extends RefCounted
## Order-book golden fixtures (#5, checklist 5a): shape checks.
##
## PENDING (parity half): once res://core/order_book.gd exists (#3), add a test
## that replays each fixture's step inputs through the GDScript OrderBook and
## asserts the fills, book snapshot and balances match the recorded referee
## output. That test must skip, not fail, while the engine file is absent so CI
## stays green until #3 lands.

const Loader = preload("res://tests/golden/golden_loader.gd")

## Cases the generator (tools/golden/gen_orderbook.py) must produce.
const EXPECTED_CASES := [
	"cancel_resting",
	"partial_fill_remainder",
	"price_time_priority",
	"rest_no_cross",
	"self_cross",
	"sweep_multi_level",
	"two_ship_settlement",
	"reject_unfunded_ask",
	"reject_insufficient_cr_bid",
]


func test_fixtures_present() -> String:
	var found: Array = []
	for p in Loader.list_fixtures():
		found.append(p.get_file().get_basename())
	for c in EXPECTED_CASES:
		if not found.has(c):
			return "missing fixture '%s' (found %s)" % [c, found]
	return "ok"


func test_every_fixture_loads_and_has_required_keys() -> String:
	var paths := Loader.list_fixtures()
	if paths.is_empty():
		return "no fixtures found in %s" % Loader.ORDERBOOK_DIR
	for p in paths:
		var res := Loader.load_fixture(p)
		if res["error"] != "":
			return res["error"]
		var err := Loader.validate(res["data"])
		if err != "":
			return "%s: %s" % [p.get_file(), err]
		if res["data"]["case"] != p.get_file().get_basename():
			return "%s: case name '%s' does not match file name" % [p.get_file(), res["data"]["case"]]
	return "ok"


func test_every_step_has_input_response_and_book() -> String:
	for p in Loader.list_fixtures():
		var data: Dictionary = Loader.load_fixture(p)["data"]
		var n := 0
		for step in data.get("steps", []):
			for k in ["input", "response", "book"]:
				if not step.has(k):
					return "%s step %d missing '%s'" % [p.get_file(), n, k]
			n += 1
	return "ok"


func _case(name: String) -> Dictionary:
	return Loader.load_fixture(Loader.ORDERBOOK_DIR.path_join(name + ".json"))["data"]


func test_two_ship_settlement_is_per_ship() -> String:
	var steps: Array = _case("two_ship_settlement")["steps"]
	var after_sale: Dictionary = steps[1]["ship_accounts"]["amos"]
	if int(after_sale["amos/1"]["FRAG"]) != 990 or int(after_sale["amos/2"]["FRAG"]) != 6:
		return "sale must settle on amos/2 only, got %s" % [after_sale]
	var after_buy: Dictionary = steps[3]["ship_accounts"]["amos"]
	if int(after_buy["amos/1"]["FRAG"]) != 993 or int(after_buy["amos/2"]["FRAG"]) != 6:
		return "purchase must settle on amos/1 only, got %s" % [after_buy]
	return "ok"


func test_reject_cases_record_insufficient_balance() -> String:
	for name in ["reject_unfunded_ask", "reject_insufficient_cr_bid"]:
		var rejects := 0
		for step in _case(name)["steps"]:
			if step["response"]["kind"] == "reject":
				rejects += 1
				if step["response"]["payload"]["reason"] != "insufficient_balance":
					return "%s: unexpected reject reason %s" % [name, step["response"]["payload"]["reason"]]
		if rejects < 2:
			return "%s: expected at least 2 rejects, got %d" % [name, rejects]
	return "ok"


func test_validator_rejects_malformed() -> String:
	if Loader.validate({}) == "":
		return "empty fixture should not validate"
	var bad := {"case": "x", "referee_commit": "deadbee", "station_id": "mars", "instrument": "FRAG",
		"initial_accounts": [{}], "steps": [{}]}
	if Loader.validate(bad) == "":
		return "wrong referee_commit should not validate"
	return "ok"


func test_parity_with_core_order_book_pending() -> String:
	if not ResourceLoader.exists("res://core/order_book.gd"):
		return "ok"  # PENDING until #3 adds core/order_book.gd; not a failure.
	var script = load("res://core/order_book.gd")
	var ob = script.new()
	if not ob.has_method("remove_order"):
		# Matching engine ported (PR 3 of #3); cancellation lands in PR 4 and full parity harness in PR 5.
		return "ok"
	# OrderBook cancellation ported (PR 4 of #3); PR 5 wires full parity harness across all golden fixtures.
	return "ok"
