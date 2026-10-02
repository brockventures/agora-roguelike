class_name ReplayDrawSource
extends DrawSource
## Replays a recorded draw sequence: an Array of {call, args, result} dicts
## (see tools/golden/record_draws.py). Every draw must match the next entry's
## method and args exactly, in order. The first problem is stored in `failure`
## and matching stops; later draws return neutral defaults and never crash.
##
## failure is empty while healthy, otherwise
##   {index, reason, expected, actual}
## with reason one of "mismatch", "extra_draw", "missing_draw".
## Call assert_exhausted() at the end of a case to catch missing draws.
##
## shuffle results are permutations: after the shuffle, new[i] = old[result[i]].

var entries: Array
var position: int = 0
var failure: Dictionary = {}

func _init(recorded: Array = []) -> void:
	entries = recorded

func ok() -> bool:
	return failure.is_empty()

## Fails with "missing_draw" if recorded entries remain unconsumed.
func assert_exhausted() -> void:
	if not failure.is_empty():
		return
	if position < entries.size():
		failure = {"index": position, "reason": "missing_draw",
			"expected": entries[position], "actual": null}

func _next(call: String, args: Array) -> Variant:
	## Returns the recorded result, or null on failure (failure is set).
	if not failure.is_empty():
		return null
	var actual := {"call": call, "args": args}
	if position >= entries.size():
		failure = {"index": position, "reason": "extra_draw",
			"expected": null, "actual": actual}
		return null
	var e: Dictionary = entries[position]
	if e.get("call", "") != call or not _same(e.get("args", []), args):
		failure = {"index": position, "reason": "mismatch",
			"expected": {"call": e.get("call"), "args": e.get("args")},
			"actual": actual}
		return null
	position += 1
	return e.get("result")

## Deep equality where 1 and 1.0 are equal (JSON has one number type).
static func _same(a: Variant, b: Variant) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	var a_num := ta == TYPE_INT or ta == TYPE_FLOAT
	var b_num := tb == TYPE_INT or tb == TYPE_FLOAT
	if a_num and b_num:
		return float(a) == float(b)
	if ta != tb:
		return false
	if ta == TYPE_ARRAY:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _same(a[i], b[i]):
				return false
		return true
	if ta == TYPE_DICTIONARY:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not _same(a[k], b[k]):
				return false
		return true
	return a == b

func randint(a: int, b: int) -> int:
	var r = _next("randint", [a, b])
	return int(r) if r != null else 0

func randrange(start: int, stop: int, step: int = 1) -> int:
	var r = _next("randrange", [start, stop, step])
	return int(r) if r != null else 0

func uniform(a: float, b: float) -> float:
	var r = _next("uniform", [a, b])
	return float(r) if r != null else 0.0

func random() -> float:
	var r = _next("random", [])
	return float(r) if r != null else 0.0

func choice(seq: Array) -> Variant:
	var r = _next("choice", [seq])
	if r == null:
		return null
	for item in seq:  # hand back the caller's own element (keeps int vs float)
		if _same(item, r):
			return item
	return r

func gauss(mu: float, sigma: float) -> float:
	var r = _next("gauss", [mu, sigma])
	return float(r) if r != null else 0.0

func shuffle(arr: Array) -> void:
	var before := arr.duplicate(true)
	var perm = _next("shuffle", [before])
	if perm == null:
		return
	if perm.size() != arr.size():
		# Cannot happen after an args match unless the fixture is malformed.
		failure = {"index": position - 1, "reason": "mismatch",
			"expected": {"call": "shuffle", "permutation": perm},
			"actual": {"call": "shuffle", "args": [before]}}
		return
	for i in perm.size():
		arr[i] = before[int(perm[i])]
