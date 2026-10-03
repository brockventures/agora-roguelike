class_name Hazards
extends RefCounted
## Space weather, corridor hazards, and Coronal Mass Ejection (CME) relay disruption.
## Ported from market-sandbox Python referee (agora/hazards.py at commit 587b07f / e7fb174).
##
## Mechanics:
## 1. P_DELAY: solar storm or propulsion fault adds 1-3 rounds to transit (DELAY_ROUNDS).
## 2. P_LOSS: hull breach or containment leak loses 10-20% of cargo (LOSS_FRACTION).
## 3. Marble-Bag Integration: Rolls draw without replacement from finite marble bags via Bags (res://core/bag.gd),
##    enforcing bad-luck streak protection and per-ship luck isolation.
## 4. CME Relay Blackout: Solar storm interference blinds remote quote depth and order relay across Earth/Luna/Mars.

const DEFAULT_P_DELAY: float = 0.20
const DEFAULT_P_LOSS: float = 0.25
const DELAY_ROUNDS: Array[int] = [1, 3]
const LOSS_FRACTION: Array[float] = [0.10, 0.20]

const CME_RELAY_CORRIDORS: Array = [
	["earth", "mars"], ["mars", "earth"],
	["luna", "mars"], ["mars", "luna"]
]
const CME_STATIONS: Array[String] = ["earth", "luna", "mars"]

## Helper to safely validate and parse numeric float values, returning null on invalid input.
## Mirrors Python's try: float(x) except (TypeError, ValueError).
static func _to_valid_float(v: Variant) -> Variant:
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	if typeof(v) == TYPE_STRING:
		var s := str(v).strip_edges()
		if s.is_valid_float():
			return float(s)
	return null

## Parses hazard configuration from various input representations.
## Matches agora/hazards.py:parse_hazards.
## Supported inputs:
## - null / false / "0" / "off" / "false" / "no" -> null
## - "1" / "on" / "true" / "yes" -> [0.20, 0.25]
## - "0.2,0.1" -> [0.2, 0.1]
## - [0.2, 0.1] -> [0.2, 0.1]
## - {"delay": 0.2, "loss": 0.1} -> [0.2, 0.1]
static func parse_hazards(v: Variant) -> Variant:
	if v == null:
		return null
	if typeof(v) == TYPE_BOOL and not bool(v):
		return null
	var d_val: Variant = null
	var l_val: Variant = null

	if typeof(v) == TYPE_DICTIONARY:
		var d_dict: Dictionary = v
		d_val = d_dict.get("delay", 0)
		l_val = d_dict.get("loss", 0)
	elif typeof(v) == TYPE_STRING:
		var s: String = str(v).strip_edges().to_lower()
		if s in ["", "0", "off", "false", "no"]:
			return null
		if s in ["1", "on", "true", "yes"]:
			return [DEFAULT_P_DELAY, DEFAULT_P_LOSS]
		var parts := s.replace(" ", "").split(",")
		var non_empty: Array[String] = []
		for p in parts:
			if not p.is_empty():
				non_empty.append(p)
		if non_empty.size() >= 2:
			d_val = non_empty[0]
			l_val = non_empty[1]
		else:
			return null
	elif typeof(v) == TYPE_ARRAY:
		var arr: Array = v
		if arr.size() >= 2:
			d_val = arr[0]
			l_val = arr[1]
		else:
			return null
	else:
		return null

	var d_num = _to_valid_float(d_val)
	var l_num = _to_valid_float(l_val)
	if d_num == null or l_num == null:
		return null

	var d: float = clampf(float(d_num), 0.0, 1.0)
	var l: float = clampf(float(l_num), 0.0, 1.0)
	if d > 0.0 or l > 0.0:
		return [d, l]
	return null

## Engine helper: checks if an origin-destination corridor is subject to CME relay blackout.
## Note: agora/hazards.py defines CME_RELAY_CORRIDORS as reference constants without a direct caller;
## this helper exposes corridor membership checks for game clients and UI route indicators.
static func is_cme_corridor(origin: String, destination: String) -> bool:
	var o := origin.to_lower().strip_edges()
	var d := destination.to_lower().strip_edges()
	return [o, d] in CME_RELAY_CORRIDORS

## Checks if a remote quote or order depth request is subject to CME relay interference.
## Matches agora/hazards.py:check_cme_relay_interference.
static func check_cme_relay_interference(
	cme_active: bool,
	agent_id: Variant,
	target_station: String,
	origin_station: Variant = null,
	docked_stations: Array = [],
	has_hardened_comm: bool = false
) -> Dictionary:
	if not cme_active:
		return {"active": false, "interfered": false, "reason": "no_cme"}

	# Admin bypasses (exact comparison matching Python hazards.py:177: agent_id in ("admin", None))
	if agent_id == null or str(agent_id) == "admin":
		return {"active": true, "interfered": false, "reason": "admin_or_system"}

	# Docked locally at target_station -> direct station LAN / hardwire bypasses relay blackout.
	# Note: Station IDs in Agora are canonical lowercase strings. Exact match mirrors Python referee.
	if target_station in docked_stations:
		return {"active": true, "interfered": false, "reason": "local_docked"}

	# Hardened communication suite upgrade bypasses CME interference
	if has_hardened_comm:
		return {"active": true, "interfered": false, "reason": "hardened_comm"}

	# CME impacts Earth-Mars corridor stations
	var origin_s: String = str(origin_station) if origin_station != null else ""
	if target_station in CME_STATIONS or (not origin_s.is_empty() and origin_s in CME_STATIONS):
		return {
			"active": true,
			"interfered": true,
			"corridor": "earth_mars",
			"reason": "cme_relay_blackout",
			"detail": "Coronal Mass Ejection has disrupted comms relay to '%s'. Depth/quotes blinded by fog." % target_station,
			"latency_rounds": 1,
			"mitigation": "Install hardened_comm upgrade or dock at local station",
		}

	return {"active": true, "interfered": false, "reason": "outside_corridor"}

## Python round-half-to-even (banker's rounding) to 4 decimal places matching Python round(x, 4).
## Uses Dekker's TwoProduct to decide half-integer ties on the exact product x * 10000.0 without floating-point error.
static func py_round4(x: float) -> float:
	var s := x * 10000.0
	var c := 134217729.0 * x
	var xh := c - (c - x)
	var xl := x - xh
	var c2 := 134217729.0 * 10000.0
	var yh := c2 - (c2 - 10000.0)
	var yl := 10000.0 - yh
	var e := ((xh * yh - s) + xh * yl + xl * yh) + xl * yl
	var fl := floorf(s)
	var k: float
	if s - fl == 0.5:
		k = fl + 1.0 if e > 0.0 else (fl if e < 0.0 else (fl if fmod(fl, 2.0) == 0.0 else fl + 1.0))
	else:
		k = floorf(s + 0.5)
	return k / 10000.0


# ==============================================================================
# HazardEngine Instance Implementation
# ==============================================================================

var odds: Variant = null
var bags: Bags = null
var draw_source: DrawSource = null
var seed_val: int = 0
var _records: Array[Dictionary] = []

func _init(p_odds: Variant = null, p_draw_source: DrawSource = null, p_bags: Bags = null, p_seed: int = 0) -> void:
	odds = parse_hazards(p_odds) if (typeof(p_odds) == TYPE_STRING or typeof(p_odds) == TYPE_DICTIONARY) else p_odds
	seed_val = p_seed
	if p_draw_source != null:
		draw_source = p_draw_source
	else:
		draw_source = NativeDrawSource.new(hash("hazards-%d" % p_seed))

	if p_bags != null:
		bags = p_bags
	else:
		bags = Bags.new("hazards", draw_source, p_seed)
	_records = []

## Resets RNG and marble bags to new seed value.
## Matches agora/hazards.py:HazardEngine.reset (resets RNG and bags, leaving records intact).
func reset(new_seed: int) -> void:
	seed_val = new_seed
	if draw_source is NativeDrawSource:
		draw_source = NativeDrawSource.new(hash("hazards-%d" % new_seed))
	if bags != null:
		bags.reset(new_seed)

## Quotes hazard odds and loss ranges without drawing any marbles.
## Matches agora/hazards.py:HazardEngine.quote.
func quote(
	delay_factor: float = 1.0,
	loss_factor: float = 1.0,
	loss_size_factor: float = 1.0,
	_agent_id: String = "",
	total_qty: Variant = null
) -> Dictionary:
	if odds == null:
		return {
			"p_delay": 0.0,
			"p_loss": 0.0,
			"delay_rounds": [0, 0],
			"loss_fraction": [0.0, 0.0],
			"expected_loss_qty": [0, 0],
			"delay_factor": delay_factor,
			"loss_factor": loss_factor,
			"loss_size_factor": loss_size_factor,
		}
	var p_delay: float = float(odds[0])
	var p_loss: float = float(odds[1])
	var p_delay_adj: float = py_round4(clampf(p_delay * delay_factor, 0.0, 1.0))
	var p_loss_adj: float = py_round4(clampf(p_loss * loss_factor, 0.0, 1.0))
	var effective_qty: int = maxi(0, int(total_qty)) if total_qty != null else 0
	var min_loss: int = int(float(effective_qty) * LOSS_FRACTION[0] * loss_size_factor) if effective_qty > 0 else 0
	var max_loss: int = int(float(effective_qty) * LOSS_FRACTION[1] * loss_size_factor) if effective_qty > 0 else 0
	return {
		"p_delay": p_delay_adj,
		"p_loss": p_loss_adj,
		"delay_rounds": [DELAY_ROUNDS[0], DELAY_ROUNDS[1]],
		"loss_fraction": [LOSS_FRACTION[0], LOSS_FRACTION[1]],
		"expected_loss_qty": [min_loss, max_loss],
		"delay_factor": delay_factor,
		"loss_factor": loss_factor,
		"loss_size_factor": loss_size_factor,
	}

## Rolls hazard outcomes at departure.
## Always draws both delay and loss values so one trip does not desynchronize subsequent trips.
## Matches agora/hazards.py:HazardEngine.roll.
func roll(
	cargo_qty: int,
	delay_factor: float = 1.0,
	loss_factor: float = 1.0,
	loss_size_factor: float = 1.0,
	agent_id: String = "",
	total_qty: Variant = null
) -> Dictionary:
	if odds == null:
		return {"delay": 0, "lost": 0, "note": ""}
	var p_delay: float = float(odds[0])
	var p_loss: float = float(odds[1])
	var d: int = draw_source.randint(DELAY_ROUNDS[0], DELAY_ROUNDS[1])
	var f: float = draw_source.uniform(LOSS_FRACTION[0], LOSS_FRACTION[1])
	var delay_hit: bool = bags.draw("delay", agent_id, p_delay * delay_factor)
	var delay: int = d if delay_hit else 0
	var effective_qty: int = int(total_qty) if total_qty != null else cargo_qty
	var loss_hit: bool = (effective_qty > 0) and bags.draw("loss", agent_id, p_loss * loss_factor)
	var lost: int = int(float(effective_qty) * f * loss_size_factor) if loss_hit else 0
	var notes: Array[String] = []
	if delay > 0:
		notes.append("storm on the route: arrival %d round%s late" % [delay, "s" if delay > 1 else ""])
	if lost > 0:
		notes.append("hull breach: %d of %d units lost" % [lost, effective_qty])
	return {
		"delay": delay,
		"lost": lost,
		"note": "; ".join(notes)
	}

## Tuple helper matching Python (delay, lost, note) return format.
func roll_tuple(
	cargo_qty: int,
	delay_factor: float = 1.0,
	loss_factor: float = 1.0,
	loss_size_factor: float = 1.0,
	agent_id: String = "",
	total_qty: Variant = null
) -> Array:
	var res := roll(cargo_qty, delay_factor, loss_factor, loss_size_factor, agent_id, total_qty)
	return [res["delay"], res["lost"], res["note"]]

## Records an in-flight hazard event into in-memory ledger storage.
func record(transit_id: String, agent_id: String, round_num: int, delay: int, lost: int, commodity: String, note: String) -> void:
	if delay > 0 or lost > 0:
		for i in range(_records.size()):
			if _records[i].get("transit_id") == transit_id:
				_records[i] = {
					"transit_id": transit_id,
					"agent_id": agent_id,
					"round": round_num,
					"delay": delay,
					"lost_qty": lost,
					"commodity": commodity,
					"note": note
				}
				return
		_records.append({
			"transit_id": transit_id,
			"agent_id": agent_id,
			"round": round_num,
			"delay": delay,
			"lost_qty": lost,
			"commodity": commodity,
			"note": note
		})

## Returns recent hazard events occurring at or after since_round, sorted descending.
func recent(since_round: int) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	for r in _records:
		if int(r.get("round", 0)) >= since_round:
			res.append(r)
	res.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["round"]) != int(b["round"]):
			return int(a["round"]) > int(b["round"])
		return str(a["transit_id"]) < str(b["transit_id"])
	)
	return res

## Compatibility class alias matching Python HazardEngine.
class HazardEngine:
	extends Hazards
