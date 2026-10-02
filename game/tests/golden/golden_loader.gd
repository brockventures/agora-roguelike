extends RefCounted
## Loads and validates golden fixture files generated from the Python referee
## (tools/golden/gen_*.py, #5). Shape checks only: this file knows nothing about
## the GDScript engine.

const REFEREE_COMMIT := "587b07f"
const ORDERBOOK_DIR := "res://tests/golden/orderbook"

const REQUIRED_KEYS := ["case", "referee_commit", "station_id", "instrument", "initial_accounts", "steps"]
const REQUIRED_STEP_KEYS := ["call", "input", "response", "fills", "book", "balances"]
const REQUIRED_BOOK_KEYS := ["bids", "asks"]
const REQUIRED_BOOK_ORDER_KEYS := ["order_id", "agent_id", "side", "qty", "limit_price"]
const REQUIRED_FILL_KEYS := ["trade_id", "buyer_id", "seller_id", "price", "qty"]


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
