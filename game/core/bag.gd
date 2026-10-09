class_name Bags
extends RefCounted
## Marble-bag RNG engine for bounded bad-luck streak protection and varying-p rolls.
## Ported from market-sandbox Python referee (agora/bag.py at commit 587b07f).
##
## Fixed-p rolls (draw):
##   Draws without replacement from a finite bag of k hits and n-k misses (n <= 200).
##   Laying out the bag as k runs with 1 hit each guarantees that streak bounds
##   are at most 2 hits in a row (for p <= 0.5) and at most 2*(ceil(n/k) - 1) misses.
##
## Varying-p rolls (draw_varying):
##   Deficit accumulator for odds that vary per roll or have no denominator <= 200.
##   Maintains a credit buffer: credit += p; if credit >= threshold, hits and credit -= 1.0.
##   Threshold is held until a hit, since the cycle/seed only advances on a hit.
##
## Random draws are routed through DrawSource (NativeDrawSource at runtime,
## ReplayDrawSource for golden tests), keyed per (ns, seed, event, fleet, refill)
## so one fleet's draws never bleed into another's.

const MAX_N: int = 200
const EPS: float = 1e-9
const SEED_EVENT: String = "__seed__"

var ns: String = ""
var seed: int = 0
var draw_source: DrawSource = null
var draw_sources: Dictionary = {}

## Internal state per (event, fleet). Key: "event:fleet".
## Value: { "seed": int, "p": float, "marbles": String, "refills": int, "credit": float, "draws": int, "hits": int }
var _bags: Dictionary = {}

## Forced outcomes queue per event: event -> Array[bool]
var _forced: Dictionary = {}

func _init(p_ns: String = "default", p_draw_source: DrawSource = null, p_seed: int = 0) -> void:
	ns = p_ns
	seed = p_seed
	draw_source = p_draw_source
	draw_sources = {}
	_bags = {}
	_forced = {}

## (hits, bag size) for p, or null when no bag of <= MAX_N marbles holds p.
static func composition(p: float) -> Variant:
	if p <= 0.0 or p >= 1.0:
		return null
	var best_k: int = 0
	var best_n: int = 1
	var best_diff: float = 1e9
	for d in range(1, MAX_N + 1):
		var k: int = int(round(p * d))
		var diff: float = abs(float(k) / float(d) - p)
		if diff < best_diff:
			best_diff = diff
			best_k = k
			best_n = d
			if diff < 1e-15:
				break
	if best_k <= 0 or best_k >= best_n or best_diff > EPS:
		return null
	return [best_k, best_n]

## Reset the desk for a new game with a given seed.
func reset(p_seed: int = 0, p_draw_source: DrawSource = null) -> void:
	seed = p_seed
	_forced.clear()
	_bags.clear()
	if p_draw_source != null:
		draw_source = p_draw_source

## Force the next draw(s) of event (any fleet) to return these outcomes.
func force(event: String, outcome: Variant) -> void:
	if not _forced.has(event):
		_forced[event] = []
	if outcome is Array:
		for o in outcome:
			_forced[event].append(bool(o))
	else:
		_forced[event].append(bool(outcome))

## Returns an RNG stream for (event, fleet, refills) to preserve isolation.
func _rng(event: String, fleet: String, refills: int, override_source: DrawSource = null) -> DrawSource:
	if override_source != null:
		return override_source
	var stream_key := "bag-%s-%d-%s-%s-%d" % [ns, seed, event, fleet, refills]
	if draw_sources.has(stream_key):
		return draw_sources[stream_key]
	var fleet_key := "%s:%s" % [event, fleet]
	if draw_sources.has(fleet_key):
		return draw_sources[fleet_key]
	if draw_source != null and not (draw_source is NativeDrawSource):
		return draw_source
	return NativeDrawSource.new(hash(stream_key))

## Fixed-p roll: draws a marble from the fleet's bag for this event.
func draw(event: String, fleet: String, p: float, source: DrawSource = null) -> bool:
	var forced = _pop_forced(event)
	if forced != null:
		return forced
	if p <= 0.0:
		return false
	if p >= 1.0:
		return true

	var comp = composition(p)
	if comp == null:
		return draw_varying(event, fleet, p, source)

	var k: int = int(comp[0])
	var n: int = int(comp[1])
	var row: Dictionary = _load(event, fleet)
	var refills: int = row["refills"]
	var marbles: String = row["marbles"]

	if abs(float(row["p"]) - p) > EPS:
		marbles = ""  # p changed: rebuild the bag for the new odds

	if marbles.is_empty():
		var rng: DrawSource = _rng(event, fleet, refills, source)
		var sizes: Array = []
		var base_size: int = n / k
		var rem: int = n % k
		for i in range(k):
			sizes.append(base_size + (1 if i < rem else 0))
		rng.shuffle(sizes)

		var bag_chars: Array = []
		for sz in sizes:
			var size: int = int(sz)
			var run_chars: Array = []
			run_chars.resize(size)
			run_chars.fill("0")
			var hit_idx: int = rng.randrange(0, size, 1)
			run_chars[hit_idx] = "1"
			bag_chars.append_array(run_chars)
		marbles = "".join(bag_chars)
		refills += 1

	var hit: bool = marbles[0] == "1"
	marbles = marbles.substr(1)
	_save(event, fleet, p, marbles, refills, 0.0, row, hit)
	return hit

## Varying-p roll: the fleet's luck credit for this event.
func draw_varying(event: String, fleet: String, p: float, source: DrawSource = null) -> bool:
	var forced = _pop_forced(event)
	if forced != null:
		return forced
	if p <= 0.0:
		return false
	if p >= 1.0:
		return true

	var row: Dictionary = _load(event, fleet)
	var cycle: int = row["refills"]
	var prev_marbles: String = row["marbles"]
	var credit: float = (float(row["credit"]) if prev_marbles.is_empty() else 0.0) + p

	var rng: DrawSource = _rng(event, fleet, cycle, source)
	var t: float = 1.0 - rng.random()  # in (0, 1] - held until hit advances cycle
	var hit: bool = credit >= t
	if hit:
		credit -= 1.0
		cycle += 1

	_save(event, fleet, p, "", cycle, credit, row, hit)
	return hit

## Stats for an event and fleet.
func stats(event: String, fleet: String) -> Dictionary:
	var row: Dictionary = _load(event, fleet)
	return {"draws": row["draws"], "hits": row["hits"]}

func _pop_forced(event: String) -> Variant:
	if not _forced.has(event):
		return null
	var q: Array = _forced[event]
	if q.is_empty():
		return null
	return q.pop_front()

func _key(event: String, fleet: String) -> String:
	return "%s:%s" % [event, fleet]

func _load(event: String, fleet: String) -> Dictionary:
	var k: String = _key(event, fleet)
	if not _bags.has(k):
		return {
			"seed": seed,
			"p": -1.0,
			"marbles": "",
			"refills": 0,
			"credit": 0.0,
			"draws": 0,
			"hits": 0
		}
	return _bags[k]

func _save(
	event: String,
	fleet: String,
	p: float,
	marbles: String,
	refills: int,
	credit: float,
	row: Dictionary,
	hit: bool
) -> void:
	var k: String = _key(event, fleet)
	_bags[k] = {
		"seed": seed,
		"p": p,
		"marbles": marbles,
		"refills": refills,
		"credit": credit,
		"draws": int(row["draws"]) + 1,
		"hits": int(row["hits"]) + (1 if hit else 0)
	}

func to_dict() -> Dictionary:
	return {
		"ns": ns,
		"seed": seed,
		"bags": _bags.duplicate(true),
		"forced": _forced.duplicate(true)
	}

## Restores streak counters, drawn/remaining marbles and the forced queue.
## Accepts JSON-parsed data (numbers arrive as floats), so every row is rebuilt
## with typed fields; bad-luck protection survives a save/load cycle intact.
func from_dict(d: Dictionary) -> void:
	ns = str(d.get("ns", ns))
	seed = int(d.get("seed", seed))
	_bags = {}
	var raw_bags = d.get("bags", {})
	if raw_bags is Dictionary:
		for k in raw_bags:
			var r = raw_bags[k]
			if not (r is Dictionary):
				continue
			_bags[str(k)] = {
				"seed": int(r.get("seed", seed)),
				"p": float(r.get("p", -1.0)),
				"marbles": str(r.get("marbles", "")),
				"refills": int(r.get("refills", 0)),
				"credit": float(r.get("credit", 0.0)),
				"draws": int(r.get("draws", 0)),
				"hits": int(r.get("hits", 0)),
			}
	_forced = {}
	var raw_forced = d.get("forced", {})
	if raw_forced is Dictionary:
		for e in raw_forced:
			if raw_forced[e] is Array:
				var q: Array = []
				for o in raw_forced[e]:
					q.append(bool(o))
				_forced[str(e)] = q
