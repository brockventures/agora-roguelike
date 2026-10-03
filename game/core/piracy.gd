class_name Piracy
extends RefCounted
## Space lanes piracy, privateer ambushes, extortion demands, and escort protection.
## Ported from market-sandbox Python referee (agora/piracy.py at commit 587b07f / e7fb174).
##
## Mechanics:
## 1. Route Risk: Belt route trips (tolled) carry P_BELT (0.15) risk; inner routes carry P_INNER (0.04).
## 2. Hot Station: Every HOT_EVERY (20) rounds, a seeded station is hot (HOT_MULT = 2.0x risk).
## 3. Value Scaling: Raid chance scales by cargo value / VALUE_REF (10,000 CR), stepped to 0.25, clamped to 0.5x..2.0x.
## 4. Escorts: Escorts cost ESCORT_PCT (4%) of cargo value and cut raid chance by ESCORT_CUT (75%).
## 5. Extortion Demands: A raid hit generates a pending demand with ransom (RANSOM_PCT = 15%) or surrender (SURRENDER_PCT = 25%).
## 6. Response Choices: pay, surrender (fenced at Ceres depot), or fight (FIGHT_ESCAPE = 50% escape, else FIGHT_LOSS = 50% lost + delay).
## 7. Privateers: Sponsoring raids against targets for PRIV_ROUNDS (20) adds PRIV_ADD (+0.15) to victim's raid odds.

const DEFAULT_P_BELT: float = 0.15
const DEFAULT_P_INNER: float = 0.04
const HOT_EVERY: int = 20
const HOT_MULT: float = 2.0
const VALUE_REF: int = 10000
const VALUE_MULT: Array[float] = [0.5, 2.0]
const VALUE_STEP: float = 0.25
const BAG_ROUND_TOL: float = 0.01
const ESCORT_PCT: float = 0.04
const ESCORT_CUT: float = 0.75
const RANSOM_PCT: float = 0.15
const SURRENDER_PCT: float = 0.25
const FIGHT_ESCAPE: float = 0.5
const FIGHT_LOSS: float = 0.5
const FIGHT_DELAY: Array[int] = [1, 2]
const PRIV_ROUNDS: int = 20
const PRIV_COST: int = 750
const PRIV_ADD: float = 0.15
const PRIV_SHARE: float = 1.0
const PRIV_TRACE: float = 0.10
const PRIV_FINE: int = 2
const FENCE_STATION: String = "ceres"
const CHOICES: Array[String] = ["pay", "surrender", "fight"]

## Reference commodity prices averaged across the 4 stations (matching agora.spatial.BASE_PRICES).
const REF_PRICE: Dictionary = {
	"FRAG": 15.0,
	"FUEL": 16.0,
	"FOOD": 19.3,
	"ORE": 19.25,
	"MACHINERY": 21.2,
}

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

## Python round-half-to-even (banker's rounding) to 4 decimal places matching Python round(x, 4).
static func py_round4(val: float) -> float:
	var scaled: float = val * 10000.0
	var rounded := roundi(scaled)
	var fl: int = int(floor(scaled))
	var diff: float = scaled - float(fl)
	if absf(diff - 0.5) < 1e-9:
		var tie_int: int = fl if (fl % 2 == 0) else (fl + 1)
		return float(tie_int) / 10000.0
	return float(rounded) / 10000.0

## Parses piracy odds configuration from various representations.
## Matches agora/piracy.py:parse_piracy.
## Supported inputs:
## - null / false / "0" / "off" / "false" / "no" -> null
## - true / "1" / "on" / "true" / "yes" -> [0.15, 0.04]
## - "0.15,0.04" -> [0.15, 0.04]
## - [0.15, 0.04] -> [0.15, 0.04]
## - {"belt": 0.15, "inner": 0.04} -> [0.15, 0.04]
static func parse_piracy(v: Variant) -> Variant:
	if v == null:
		return null
	if typeof(v) == TYPE_BOOL:
		return [DEFAULT_P_BELT, DEFAULT_P_INNER] if bool(v) else null

	var b_val: Variant = null
	var i_val: Variant = null

	if typeof(v) == TYPE_DICTIONARY:
		var d_dict: Dictionary = v
		b_val = d_dict.get("belt", 0)
		i_val = d_dict.get("inner", 0)
	elif typeof(v) == TYPE_STRING:
		var s: String = str(v).strip_edges().to_lower()
		if s in ["", "0", "off", "false", "no"]:
			return null
		if s in ["1", "on", "true", "yes"]:
			return [DEFAULT_P_BELT, DEFAULT_P_INNER]
		var parts := s.replace(" ", "").split(",")
		var non_empty: Array[String] = []
		for p in parts:
			if not p.is_empty():
				non_empty.append(p)
		if non_empty.size() >= 2:
			b_val = non_empty[0]
			i_val = non_empty[1]
		else:
			return null
	elif typeof(v) == TYPE_ARRAY:
		var arr: Array = v
		if arr.size() >= 2:
			b_val = arr[0]
			i_val = arr[1]
		else:
			return null
	else:
		return null

	var b_num = _to_valid_float(b_val)
	var i_num = _to_valid_float(i_val)
	if b_num == null or i_num == null:
		return null

	var b: float = clampf(float(b_num), 0.0, 1.0)
	var i: float = clampf(float(i_num), 0.0, 1.0)
	if b > 0.0 or i > 0.0:
		return [b, i]
	return null

## Calculates market cargo reference value in credits.
## Matches agora/piracy.py:cargo_value.
static func cargo_value(commodity: String, qty: int) -> int:
	var c := commodity.strip_edges().to_upper()
	if not REF_PRICE.has(c):
		return 0
	var price: float = REF_PRICE[c]
	var val: float = float(maxi(0, qty)) * price
	return Transit.py_round(val) if val > 0.0 else 0

## Calculates escort hiring fee in credits.
## Matches agora/piracy.py:PiracyDesk.escort_fee.
static func escort_fee(commodity: String, qty: int) -> int:
	return int(float(cargo_value(commodity, qty)) * ESCORT_PCT)

## Approximates exact odds p as a marble bag fraction k/n (n <= Bags.MAX_N)
## within BAG_ROUND_TOL of p, matching Python Fraction(p).limit_denominator(200).
## Matches agora/piracy.py:PiracyDesk.bag_odds.
static func bag_odds(p: float) -> float:
	if p <= 0.0 or p >= 1.0:
		return p
	var best_k: int = 0
	var best_n: int = 1
	var best_diff: float = 1e9
	for d in range(1, Bags.MAX_N + 1):
		var k: int = int(round(p * float(d)))
		var diff: float = absf(float(k) / float(d) - p)
		if diff < best_diff:
			best_diff = diff
			best_k = k
			best_n = d
			if diff < 1e-15:
				break
	if best_n > 0 and best_k > 0:
		var q: float = float(best_k) / float(best_n)
		if q > 0.0 and absf(q - p) <= BAG_ROUND_TOL * p:
			return q
	return p

## Constructs ship and condition isolated marble bag key for raid draws.
## Matches agora/piracy.py:PiracyDesk.raid_key.
static func raid_key(vessel_id: String, c: Dictionary) -> String:
	var surge_tag: String = "|surge" if c.get("salvage_surge", false) else ""
	var tolled_str: String = "belt" if c.get("tolled", false) else "inner"
	var hot_str: String = "hot" if c.get("hot", false) else "cool"
	var priv_str: String = "priv" if c.get("privateers", false) else "free"
	var escort_str: String = "escort" if c.get("escort", false) else "bare"
	var vm_str: String = "v%s" % str(c.get("value_mult", 1.0))
	var a_tier: int = int(c.get("armor_tier", 0))
	var s_tier: int = int(c.get("stealth_tier", 0))
	return "%s|%s|%s|%s|%s|a%d|s%d%s|%s" % [
		vessel_id, tolled_str, hot_str, vm_str, priv_str, a_tier, s_tier, surge_tag, escort_str
	]

## Calculates the round when the current hot station window ends.
## Matches agora/piracy.py:PiracyDesk.hot_until.
static func hot_until(round_num: int) -> int:
	return (round_num / HOT_EVERY + 1) * HOT_EVERY

# ==============================================================================
# PiracyDesk Instance Implementation
# ==============================================================================

var odds: Variant = null
var seed_val: int = 0
var draw_source: DrawSource = null
var bags: Bags = null
var _raids: Dictionary = {}          # transit_id -> raid dict
var _privateers: Dictionary = {}     # contract_id -> contract dict
var _looted: Dictionary = {}         # "agent:comm" -> qty
var _tributes: Dictionary = {}       # tribute_id -> tribute dict
var _tribute_counter: int = 0

func _init(p_odds: Variant = null, p_draw_source: DrawSource = null, p_bags: Bags = null, p_seed: int = 0) -> void:
	odds = parse_piracy(p_odds) if (typeof(p_odds) == TYPE_STRING or typeof(p_odds) == TYPE_DICTIONARY or typeof(p_odds) == TYPE_BOOL) else p_odds
	seed_val = p_seed
	if p_draw_source != null:
		draw_source = p_draw_source
	else:
		draw_source = NativeDrawSource.new(hash("piracy-%d" % p_seed))

	if p_bags != null:
		bags = p_bags
	else:
		bags = Bags.new("piracy", draw_source, p_seed)
	_raids = {}
	_privateers = {}
	_looted = {}
	_tributes = {}
	_tribute_counter = 0

## Checks if piracy system is enabled with valid odds.
func is_enabled() -> bool:
	return odds != null

## Resets RNG and marble bags to new seed value.
## Matches agora/piracy.py:PiracyDesk.reset (resets RNG and bags, leaving records intact).
func reset(new_seed: int) -> void:
	seed_val = new_seed
	if draw_source is NativeDrawSource:
		draw_source = NativeDrawSource.new(hash("piracy-%d" % new_seed))
	if bags != null:
		bags.reset(new_seed)

## Returns the active hot station for a given round window.
## Matches agora/piracy.py:PiracyDesk.hot_station.
func hot_station(round_num: int, override_station: String = "") -> String:
	if not override_station.is_empty():
		return override_station
	var key := "piracy-hot-%d-%d" % [seed_val, round_num / HOT_EVERY]
	var rng := NativeDrawSource.new(hash(key))
	var st = rng.choice(Transit.STATIONS)
	return str(st) if st != null else "earth"

## Returns the active privateer contract targeting target_agent at round_num, or null.
## Matches agora/piracy.py:PiracyDesk.active_contract.
func active_contract(target_agent: String, round_num: int) -> Variant:
	var target_norm := target_agent.strip_edges().to_lower()
	var matching: Array[Dictionary] = []
	for cid in _privateers:
		var c: Dictionary = _privateers[cid]
		if c.get("target") == target_norm and int(c.get("start_round", 0)) <= round_num and int(c.get("expires_round", 0)) > round_num:
			matching.append(c)
	if matching.is_empty():
		return null
	matching.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("start_round", 0)) < int(b.get("start_round", 0))
	)
	return matching[0]

## Calculates raid chance and parameter breakdown for a transit trip.
## Matches agora/piracy.py:PiracyDesk.chance.
func chance(
	agent: String,
	origin: String,
	dest: String,
	tolled: bool,
	commodity: String,
	qty: int,
	escort: bool,
	round_num: int,
	hold_value: Variant = null,
	for_quote: bool = false,
	armor_factor: float = 1.0,
	armor_tier: int = 0,
	stealth_factor: float = 1.0,
	stealth_tier: int = 0,
	salvage_surge: bool = false
) -> Dictionary:
	var value: int = int(hold_value) if hold_value != null else cargo_value(commodity, qty)
	if odds == null or value <= 0:
		var res: Dictionary = {
			"odds": 0.0,
			"exact_odds": 0.0,
			"base": 0.0,
			"hot": false,
			"value": value,
			"value_mult": 0.0,
			"privateers": false,
			"escort": bool(escort),
			"armor": 1.0,
			"armor_tier": 0,
			"stealth": 1.0,
			"stealth_tier": 0,
			"tolled": bool(tolled),
			"salvage_surge": false,
		}
		if for_quote:
			res["excludes"] = ["privateers"]
			res["privateer_add"] = PRIV_ADD
		return res

	var p_belt: float = float(odds[0])
	var p_inner: float = float(odds[1])
	var base: float = p_belt if tolled else p_inner
	var current_hot: String = hot_station(round_num)
	var hot: bool = (current_hot == origin or current_hot == dest)

	var vm: float = clampf(float(value) / float(VALUE_REF), VALUE_MULT[0], VALUE_MULT[1])
	var rounded_steps: int = Transit.py_round(vm / VALUE_STEP)
	vm = clampf(float(rounded_steps) * VALUE_STEP, VALUE_MULT[0], VALUE_MULT[1])

	var p: float = base * (HOT_MULT if hot else 1.0) * vm
	var priv: bool = false if for_quote else (active_contract(agent, round_num) != null)
	if priv:
		p += PRIV_ADD
	if escort:
		p *= (1.0 - ESCORT_CUT)

	p *= armor_factor
	p *= stealth_factor

	# Belt Salvage Surge: doubles raid odds along Ceres / belt corridors
	if salvage_surge:
		var k := "%s:%s" % [origin.to_lower(), dest.to_lower()]
		if tolled or origin == "ceres" or dest == "ceres" or (k in Transit.BELT_ROUTES):
			p = minf(1.0, p * 2.0)

	var exact_p: float = minf(1.0, p)
	var final_odds: float = py_round4(exact_p)

	var out: Dictionary = {
		"odds": final_odds,
		"exact_odds": exact_p,
		"base": base,
		"hot": hot,
		"value": value,
		"value_mult": roundf(vm * 1000.0) / 1000.0,
		"privateers": priv,
		"escort": bool(escort),
		"armor": armor_factor,
		"armor_tier": armor_tier,
		"stealth": stealth_factor,
		"stealth_tier": stealth_tier,
		"tolled": bool(tolled),
		"salvage_surge": salvage_surge,
	}
	if for_quote:
		out["excludes"] = ["privateers"]
		out["privateer_add"] = PRIV_ADD
	return out

## Rolls piracy encounter at transit departure.
## Matches agora/piracy.py:PiracyDesk.roll_departure_locked.
func roll_departure(
	transit_id: String,
	agent: String,
	origin: String,
	dest: String,
	tolled: bool,
	commodity: String,
	qty: int,
	escort: bool,
	round_num: int,
	vessel_id: String = "",
	hold_value: Variant = null,
	total_qty: Variant = null,
	armor_factor: float = 1.0,
	armor_tier: int = 0,
	stealth_factor: float = 1.0,
	stealth_tier: int = 0,
	salvage_surge: bool = false
) -> Variant:
	if odds == null:
		return null

	var c := chance(
		agent, origin, dest, tolled, commodity, qty, escort, round_num,
		hold_value, false, armor_factor, armor_tier, stealth_factor, stealth_tier, salvage_surge
	)
	var fee: int = escort_fee(commodity, qty) if escort else 0
	var out: Dictionary = {
		"odds": c["odds"],
		"hot_station": hot_station(round_num),
		"hot_route": c["hot"],
		"cargo_value": c["value"],
		"escort": bool(escort),
		"escort_fee": fee,
		"raided": false,
		"demand": null,
	}

	var ship_id: String = vessel_id if not vessel_id.is_empty() else ("%s/1" % agent)
	var key := raid_key(ship_id, c)
	var effective_qty: int = int(total_qty) if total_qty != null else qty

	if effective_qty <= 0:
		return out

	var draw_p := bag_odds(float(c["exact_odds"]))
	if not bags.draw("raid", key, draw_p):
		return out

	var ransom: int = int(float(c["value"]) * RANSOM_PCT)
	var surrender: int = int(float(effective_qty) * SURRENDER_PCT)
	var contract = active_contract(agent, round_num)
	var sponsor: Variant = contract.get("sponsor") if contract != null else null
	var contract_id: Variant = contract.get("contract_id") if contract != null else null
	var traced: int = 0
	var fine: int = 0

	if contract != null:
		contract["raids"] = int(contract.get("raids", 0)) + 1
		if bags.draw("trace", str(sponsor), PRIV_TRACE):
			traced = 1
			fine = int(contract.get("fee", PRIV_COST)) * PRIV_FINE
			contract["traced"] = 1
			contract["fines"] = int(contract.get("fines", 0)) + fine

	var demand: Dictionary = {
		"transit_id": transit_id,
		"agent_id": agent,
		"round": round_num,
		"origin": origin,
		"destination": dest,
		"commodity": commodity,
		"cargo_qty": effective_qty,
		"cargo_value": c["value"],
		"odds": c["odds"],
		"escorted": int(escort),
		"ransom": ransom,
		"surrender_qty": surrender,
		"status": "pending",
		"choice": null,
		"timed_out": 0,
		"cr_taken": 0,
		"qty_taken": 0,
		"delay": 0,
		"fenced_at": null,
		"contract_id": contract_id,
		"sponsor": sponsor,
		"traced": traced,
		"fine": fine,
	}
	_raids[transit_id] = demand
	out["raided"] = true
	out["demand"] = demand
	return out

## Responds to a pending pirate extortion demand.
## Matches agora/piracy.py:PiracyDesk.respond.
func respond(agent_id: String, transit_id: String, choice_str: String, available_cr: int = 1000000) -> Dictionary:
	var choice := choice_str.strip_edges().to_lower()
	if not (choice in CHOICES):
		return {"v": 1, "kind": "reject", "payload": {"reason": "invalid_choice", "detail": "choice must be one of %s" % str(CHOICES)}}

	if not _raids.has(transit_id):
		return {"v": 1, "kind": "reject", "payload": {"reason": "no_demand", "detail": "No pirate demand on transit '%s'" % transit_id}}

	var row: Dictionary = _raids[transit_id]
	if row["agent_id"] != agent_id:
		return {"v": 1, "kind": "reject", "payload": {"reason": "unauthorized", "detail": "Transit '%s' is not yours" % transit_id}}

	if row["status"] != "pending":
		return {"v": 1, "kind": "reject", "payload": {"reason": "already_resolved", "detail": "This demand was already settled: %s" % row["status"]}}

	var cr_taken: int = 0
	var qty_taken: int = 0
	var delay: int = 0
	var fenced: Variant = null
	var status: String = ""

	if choice == "pay":
		if available_cr < int(row["ransom"]):
			return {"v": 1, "kind": "reject", "payload": {"reason": "insufficient_credits", "detail": "The ransom is %d CR; available %d" % [row["ransom"], available_cr]}}
		cr_taken = int(row["ransom"])
		status = "paid"
		if row.get("contract_id") != null and _privateers.has(row["contract_id"]):
			_privateers[row["contract_id"]]["loot_cr"] = int(_privateers[row["contract_id"]].get("loot_cr", 0)) + cr_taken
	elif choice == "surrender":
		qty_taken = int(row["surrender_qty"])
		fenced = FENCE_STATION
		status = "surrendered"
		if row.get("contract_id") != null and _privateers.has(row["contract_id"]):
			_privateers[row["contract_id"]]["loot_qty"] = int(_privateers[row["contract_id"]].get("loot_qty", 0)) + qty_taken
	elif choice == "fight":
		var d: int = draw_source.randint(FIGHT_DELAY[0], FIGHT_DELAY[1])
		var ship: String = "%s/1" % agent_id
		if bags.draw("escape", ship, FIGHT_ESCAPE):
			status = "escaped"
		else:
			status = "lost"
			qty_taken = int(float(row["cargo_qty"]) * FIGHT_LOSS)
			delay = d
			fenced = FENCE_STATION
			if row.get("contract_id") != null and _privateers.has(row["contract_id"]):
				_privateers[row["contract_id"]]["loot_qty"] = int(_privateers[row["contract_id"]].get("loot_qty", 0)) + qty_taken

	row["status"] = status
	row["choice"] = choice
	row["cr_taken"] = cr_taken
	row["qty_taken"] = qty_taken
	row["delay"] = delay
	row["fenced_at"] = fenced

	return {"v": 1, "kind": "piracy_respond_ok", "payload": row}

## Hires privateers against a target fleet for PRIV_ROUNDS rounds.
## Matches agora/piracy.py:PiracyDesk.hire.
func hire(sponsor: String, target: String, round_num: int, available_cr: int = 1000000) -> Dictionary:
	var s := sponsor.strip_edges().to_lower()
	var t := target.strip_edges().to_lower()
	if s == t:
		return {"v": 1, "kind": "reject", "payload": {"reason": "invalid_target", "detail": "You cannot send privateers after yourself"}}

	if available_cr < PRIV_COST:
		return {"v": 1, "kind": "reject", "payload": {"reason": "insufficient_credits", "detail": "Privateers cost %d CR; available %d" % [PRIV_COST, available_cr]}}

	# Check active contracts
	for cid in _privateers:
		var c: Dictionary = _privateers[cid]
		if c.get("sponsor") == s and int(c.get("expires_round", 0)) > round_num:
			return {"v": 1, "kind": "reject", "payload": {"reason": "contract_active", "detail": "You already have privateers under contract; one at a time"}}
		if c.get("target") == t and int(c.get("expires_round", 0)) > round_num:
			return {"v": 1, "kind": "reject", "payload": {"reason": "target_taken", "detail": "Raiders are already under contract against %s" % target}}

	var cid := "pv-%d-%s-%s" % [round_num, s, t]
	var contract: Dictionary = {
		"contract_id": cid,
		"sponsor": s,
		"target": t,
		"start_round": round_num,
		"expires_round": round_num + PRIV_ROUNDS,
		"fee": PRIV_COST,
		"raids": 0,
		"loot_cr": 0,
		"loot_qty": 0,
		"traced": 0,
		"fines": 0,
	}
	_privateers[cid] = contract
	return {"v": 1, "kind": "privateer_hire_ok", "payload": contract}

## Returns recent raids sorted descending by round.
## Matches agora/piracy.py:PiracyDesk.recent_raids.
func recent_raids(since_round: int = 0, limit: int = 20) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	for tid in _raids:
		var r: Dictionary = _raids[tid]
		if int(r.get("round", 0)) >= since_round:
			res.append(r)
	res.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["round"]) != int(b["round"]):
			return int(a["round"]) > int(b["round"])
		return str(a["transit_id"]) < str(b["transit_id"])
	)
	if res.size() > limit:
		res = res.slice(0, limit)
	return res

## Compatibility class alias matching Python PiracyDesk.
class PiracyDesk:
	extends Piracy
