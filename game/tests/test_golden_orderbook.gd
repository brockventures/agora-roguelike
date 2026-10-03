extends RefCounted
## Order-book golden fixtures (#5, checklist 5a): shape checks.
##
## Parity coverage (#3): test_golden_fixture_coverage fails when a fixture is
## unclassified or a BOOK_LEVEL fixture is not replayed in test_order_book.gd.

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

## Fixtures replayed at the order-book level by test_order_book.gd.
const BOOK_LEVEL := [
	"cancel_resting",
	"partial_fill_remainder",
	"price_time_priority",
	"rest_no_cross",
	"self_cross",
	"sweep_multi_level",
	"two_ship_settlement",  # only the steps that need no funding check (steps 0-1)
]

## Fixtures with steps that need referee funding checks (reject_unfunded_ask,
## reject_insufficient_cr_bid). two_ship_settlement is listed here too: its
## funding-reject step needs the referee, so the order book alone cannot replay it.
const REFEREE_LEVEL := [
	"reject_unfunded_ask",
	"reject_insufficient_cr_bid",
	"two_ship_settlement",
]

const BOOK_TEST := "res://tests/test_order_book.gd"
const REFEREE_SCRIPT := "res://core/referee.gd"


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


func test_golden_fixture_coverage() -> String:
	# Every fixture file must be classified, every listed name must exist on disk.
	var on_disk: Array = []
	for p in Loader.list_fixtures():
		on_disk.append(p.get_file().get_basename())
	var listed: Array = BOOK_LEVEL + REFEREE_LEVEL
	for f in on_disk:
		if not listed.has(f):
			return "fixture '%s' is in neither BOOK_LEVEL nor REFEREE_LEVEL; classify it and add a replay" % f
	for n in listed:
		if not on_disk.has(n):
			return "listed fixture '%s' has no .json under %s" % [n, Loader.ORDERBOOK_DIR]
	# Book-level: test_order_book.gd must actually replay each fixture. Match the call
	# form _replay_golden_fixture("<name>" followed by "," or ")", so a bare string
	# mention (comment, fixture path, unrelated array) does not count. Leading
	# whitespace is allowed inside the parens; commented-out calls are rejected below.
	var f := FileAccess.open(BOOK_TEST, FileAccess.READ)
	if f == null:
		return "cannot read %s" % BOOK_TEST
	var code_lines: Array = []
	for line in f.get_as_text().split("\n"):
		if not line.strip_edges().begins_with("#"):
			code_lines.append(line)
	var code := "\n".join(code_lines)
	for n in BOOK_LEVEL:
		var re := RegEx.create_from_string('_replay_golden_fixture\\(\\s*"%s"\\s*[,)]' % n)
		if re.search(code) == null:
			return "BOOK_LEVEL fixture '%s' has no _replay_golden_fixture(\"%s\"...) call in %s" % [n, n, BOOK_TEST]
	# Referee-level: nothing to replay against until the referee port exists.
	if ResourceLoader.exists(REFEREE_SCRIPT):
		return "%s now exists: add the referee-level replay for %s in that PR, then drop this guard branch" % [REFEREE_SCRIPT, REFEREE_LEVEL]
	return "ok"
