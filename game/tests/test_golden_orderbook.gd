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
	# Once the engine exists this placeholder must be replaced by real parity
	# assertions in the same PR (#3); failing here stops a vacuous pass.
	return "core/order_book.gd exists but the parity test is not implemented yet (#3 must add it)"
