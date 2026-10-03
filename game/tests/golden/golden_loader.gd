extends RefCounted
## Loads and validates golden fixture files generated from the Python referee
## (tools/golden/gen_*.py, #5). Shape checks only: this file knows nothing about
## the GDScript engine.
##
## Fixture `qty` (in book bids/asks) means REMAINING quantity: the Python book's
## to_dict writes Order.remaining_qty into `qty`, unlike Order.to_dict, which
## writes the original qty. The order as submitted is in each step's `input`.

## `setup.prep` op `mint_cr` writes CR through the referee's internal
## `fleet._move`, not any public API. A GDScript replay must reproduce that
## starting state with its own setup step (credit the agent, debit SYSTEM)
## rather than expecting a public call to do it.

const REFEREE_COMMIT := "587b07f"
const ORDERBOOK_DIR := "res://tests/golden/orderbook"
const SETTLEMENT_DIR := "res://tests/golden/settlement"
const DRAWS_DIR := "res://tests/golden/draws"

const REQUIRED_KEYS := ["case", "referee_commit", "station_id", "instrument", "initial_accounts", "initial_ship_accounts", "steps"]
const REQUIRED_STEP_KEYS := ["call", "input", "response", "fills", "book", "balances", "ship_accounts"]
const REQUIRED_BOOK_KEYS := ["bids", "asks"]
const REQUIRED_BOOK_ORDER_KEYS := ["order_id", "agent_id", "side", "qty", "limit_price"]
const REQUIRED_FILL_KEYS := ["trade_id", "buyer_id", "seller_id", "price", "qty"]

## Settlement and ledger fixtures (tools/golden/gen_settlement.py, 5c).
const REQUIRED_SETTLEMENT_KEYS := ["case", "description", "referee_commit", "setup", "initial_accounts", "bag_start", "steps", "bag_end", "final_invariants_ok"]
const REQUIRED_SETTLEMENT_STEP_KEYS := ["call", "input", "response", "ledger_entries", "ledger_txns", "ledger_sum", "balances", "bag_after", "draws", "invariants_ok", "invariant_errors"]
const REQUIRED_LEDGER_ENTRY_KEYS := ["txn_id", "seq", "agent_id", "instrument", "delta"]
const REQUIRED_BAG_ROW_KEYS := ["ns", "event", "fleet", "seed", "p", "marbles", "refills", "credit", "draws", "hits"]
const REQUIRED_DRAW_KEYS := ["call", "args", "result"]

## Draw-level fixtures (tools/golden/gen_draws.py, 5d). draws/sample.json is the 5b recorder
## sample (a bare array), not a draw case; list_fixtures(DRAWS_DIR) returns it too, so callers
## skip it by name.
const REQUIRED_DRAW_CASE_KEYS := ["case", "module", "description", "referee_commit", "setup", "bag_start", "steps", "bag_end"]
const REQUIRED_DRAW_STEP_KEYS := ["call", "input", "draws", "output", "bag_after"]
const DRAW_MODULES := ["bag", "hazards", "piracy", "spatial"]


## Fixture file paths in a directory, sorted. Empty when the directory is missing.
static func list_fixtures(dir_path: String = ORDERBOOK_DIR) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	var names: Array = Array(dir.get_files())
	names.sort()
	for f in names:
		if f.ends_with(".json"):
			out.append(dir_path.path_join(f))
	return out


## Parse a fixture file. Returns {"data": Dictionary, "error": String}; error is
## "" on success. Does not validate shape (see validate).
static func load_fixture(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"data": {}, "error": "%s: file not found" % path}
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		return {"data": {}, "error": "%s: not a JSON object" % path}
	return {"data": parsed, "error": ""}


## Shape check. Returns "" when the fixture is well formed, else a message.
static func validate(data: Dictionary) -> String:
	for k in REQUIRED_KEYS:
		if not data.has(k):
			return "missing key '%s'" % k
	if data["referee_commit"] != REFEREE_COMMIT:
		return "referee_commit is '%s', expected '%s'" % [data["referee_commit"], REFEREE_COMMIT]
	if not (data["initial_accounts"] is Array) or data["initial_accounts"].is_empty():
		return "initial_accounts must be a non-empty array"
	if not (data["steps"] is Array) or data["steps"].is_empty():
		return "steps must be a non-empty array"
	var i := 0
	for step in data["steps"]:
		if not (step is Dictionary):
			return "step %d is not an object" % i
		for k in REQUIRED_STEP_KEYS:
			if not step.has(k):
				return "step %d missing key '%s'" % [i, k]
		var book = step["book"]
		if not (book is Dictionary):
			return "step %d book is not an object" % i
		for k in REQUIRED_BOOK_KEYS:
			if not book.has(k) or not (book[k] is Array):
				return "step %d book missing array '%s'" % [i, k]
			for o in book[k]:
				for ok in REQUIRED_BOOK_ORDER_KEYS:
					if not (o is Dictionary) or not o.has(ok):
						return "step %d book.%s entry missing '%s'" % [i, k, ok]
		if not (step["fills"] is Array):
			return "step %d fills is not an array" % i
		for f in step["fills"]:
			for fk in REQUIRED_FILL_KEYS:
				if not (f is Dictionary) or not f.has(fk):
					return "step %d fill missing '%s'" % [i, fk]
		i += 1
	return ""


## Shape and self-consistency check for a settlement fixture. Returns "" when well
## formed, else a message. Checks the double-entry invariant (every txn and every
## step sums to 0) and that each recorded draw is {call, args, result}; it knows
## nothing about the GDScript engine.
static func validate_settlement(data: Dictionary) -> String:
	for k in REQUIRED_SETTLEMENT_KEYS:
		if not data.has(k):
			return "missing key '%s'" % k
	if data["referee_commit"] != REFEREE_COMMIT:
		return "referee_commit is '%s', expected '%s'" % [data["referee_commit"], REFEREE_COMMIT]
	if not (data["initial_accounts"] is Array) or data["initial_accounts"].is_empty():
		return "initial_accounts must be a non-empty array"
	if not (data["steps"] is Array) or data["steps"].is_empty():
		return "steps must be a non-empty array"
	for bag_key in ["bag_start", "bag_end"]:
		if not (data[bag_key] is Array):
			return "%s must be an array" % bag_key
		for row in data[bag_key]:
			var err := _check_keys(row, REQUIRED_BAG_ROW_KEYS)
			if err != "":
				return "%s row: %s" % [bag_key, err]
	var i := 0
	for step in data["steps"]:
		if not (step is Dictionary):
			return "step %d is not an object" % i
		for k in REQUIRED_SETTLEMENT_STEP_KEYS:
			if not step.has(k):
				return "step %d missing key '%s'" % [i, k]
		var total := 0
		var by_txn := {}
		for e in step["ledger_entries"]:
			var err := _check_keys(e, REQUIRED_LEDGER_ENTRY_KEYS)
			if err != "":
				return "step %d ledger entry: %s" % [i, err]
			total += int(e["delta"])
			by_txn[e["txn_id"]] = int(by_txn.get(e["txn_id"], 0)) + int(e["delta"])
		if total != 0 or int(step["ledger_sum"]) != 0:
			return "step %d ledger does not sum to 0 (entries %d, recorded %s)" % [i, total, step["ledger_sum"]]
		for txn_id in by_txn:
			if int(by_txn[txn_id]) != 0:
				return "step %d txn '%s' sums to %d, not 0" % [i, txn_id, by_txn[txn_id]]
		if by_txn.size() != step["ledger_txns"].size():
			return "step %d ledger_txns lists %d txns, entries name %d" % [i, step["ledger_txns"].size(), by_txn.size()]
		for row in step["bag_after"]:
			var err := _check_keys(row, REQUIRED_BAG_ROW_KEYS)
			if err != "":
				return "step %d bag_after row: %s" % [i, err]
		for d in step["draws"]:
			var err := _check_keys(d, REQUIRED_DRAW_KEYS)
			if err != "":
				return "step %d draw: %s" % [i, err]
		i += 1
	return ""


static func _check_keys(obj, keys: Array) -> String:
	if not (obj is Dictionary):
		return "not an object"
	for k in keys:
		if not obj.has(k):
			return "missing '%s'" % k
	return ""


## Shape check for a draw-level fixture (5d). Returns "" when well formed, else a message.
## Checks that each recorded draw is {call, args, result} and each bag row is complete; it knows
## nothing about the GDScript engine.
static func validate_draw_case(data: Dictionary) -> String:
	for k in REQUIRED_DRAW_CASE_KEYS:
		if not data.has(k):
			return "missing key '%s'" % k
	if data["referee_commit"] != REFEREE_COMMIT:
		return "referee_commit is '%s', expected '%s'" % [data["referee_commit"], REFEREE_COMMIT]
	if not DRAW_MODULES.has(data["module"]):
		return "unknown module '%s'" % data["module"]
	if not (data["steps"] is Array) or data["steps"].is_empty():
		return "steps must be a non-empty array"
	for bag_key in ["bag_start", "bag_end"]:
		if not (data[bag_key] is Array):
			return "%s must be an array" % bag_key
		for row in data[bag_key]:
			var err := _check_keys(row, REQUIRED_BAG_ROW_KEYS)
			if err != "":
				return "%s row: %s" % [bag_key, err]
	var i := 0
	for step in data["steps"]:
		var step_err := _check_keys(step, REQUIRED_DRAW_STEP_KEYS)
		if step_err != "":
			return "step %d: %s" % [i, step_err]
		if not (step["draws"] is Array):
			return "step %d draws is not an array" % i
		for d in step["draws"]:
			var err := _check_keys(d, REQUIRED_DRAW_KEYS)
			if err != "":
				return "step %d draw: %s" % [i, err]
		for row in step["bag_after"]:
			var err := _check_keys(row, REQUIRED_BAG_ROW_KEYS)
			if err != "":
				return "step %d bag_after row: %s" % [i, err]
		i += 1
	return ""
