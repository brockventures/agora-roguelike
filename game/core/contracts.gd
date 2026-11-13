class_name Contracts
extends RefCounted
## Timed station-to-station delivery contracts engine (#216), ported from agora/contracts.py.
##
## Stations post freight charters asking the active corporation to haul `qty` units of `commodity`
## from `origin` to `destination` on or before `deadline_round` for an integer `reward_cr` payout.
## At most `max_active()` (default 2) contracts may be active at once. Docking at `destination`
## with the required cargo fulfills the contract (paying `reward_cr` and consuming the delivered
## units from the hold; optional partial delivery scales payout and remaining penalty pro-rata).
## Any active contract still unfulfilled once `current_round > deadline_round` expires overdue
## and assesses `penalty_cr` (25% novice rate on a corp's first lapse, 50% thereafter per #162).
## A Chapter 11 bankruptcy clears the failed corp's active contracts so a new corp starts clean.

const DATA_PATH: String = "res://data/contracts.json"
const BPS: int = 10000

const DEFAULT_POST_EVERY_ROUNDS: int = 4
const DEFAULT_MAX_ACTIVE: int = 2
const DEFAULT_MAX_OFFERS: int = 3
const DEFAULT_FIRST_PENALTY_BPS: int = 2500
const DEFAULT_PENALTY_BPS: int = 5000
const DEFAULT_OVERSIZED_PROB_BPS: int = 3500

const MAX_LOADED_ROUND: int = 1000000
const MAX_LOADED_QTY: int = 1000000
const MAX_LOADED_CR: int = 1 << 40
const MAX_LOADED_CONTRACTS: int = 64

const LOT_STANDARD: String = "standard"
const LOT_OVERSIZED: String = "oversized"

const STATUS_AVAILABLE: String = "available"
const STATUS_ACTIVE: String = "active"
const STATUS_FULFILLED: String = "fulfilled"
const STATUS_EXPIRED: String = "expired"

static var _cache: Dictionary = {}

## Open board offers awaiting acceptance.
var available: Array[Dictionary] = []
## Contracts accepted by the active corporation and not yet fulfilled or expired.
var active: Array[Dictionary] = []
## Contracts fulfilled by the active corporation during this corp's lifetime.
var fulfilled_count: int = 0
## Contracts allowed to expire overdue by the active corporation (drives first-lapse discount).
var expired_count: int = 0
## Monotonic sequence counter for deterministic contract IDs.
var next_seq: int = 1
## When true, RunController round ticks also auto-post seeded board offers every post_every_rounds().
var auto_post_offers: bool = false


static func reset_cache() -> void:
	_cache = {}


static func load_data(path: String = DATA_PATH) -> Dictionary:
	if path == DATA_PATH and not _cache.is_empty():
		return _cache
	var loaded: Dictionary = {}
	if FileAccess.file_exists(path):
		var raw: String = FileAccess.get_file_as_string(path)
		var parsed = JSON.parse_string(raw)
		if parsed is Dictionary and (parsed as Dictionary).get("contracts") is Array:
			loaded = parsed
	if loaded.is_empty():
		loaded = _fallback()
	if path == DATA_PATH:
		_cache = loaded
	return loaded


static func _fallback() -> Dictionary:
	return {
		"version": 1,
		"post_every_rounds": DEFAULT_POST_EVERY_ROUNDS,
		"max_active": DEFAULT_MAX_ACTIVE,
		"max_offers": DEFAULT_MAX_OFFERS,
		"standard_qty": [25, 65],
		"oversized_qty": [90, 180],
		"standard_deadline_rounds": [6, 10],
		"oversized_deadline_rounds": [10, 16],
		"standard_premium_bps": [13000, 16000],
		"oversized_premium_bps": [15000, 18500],
		"oversized_prob_bps": DEFAULT_OVERSIZED_PROB_BPS,
		"first_penalty_bps": DEFAULT_FIRST_PENALTY_BPS,
		"penalty_bps": DEFAULT_PENALTY_BPS,
		"contracts": [
			{
				"id": "ceres_earth_ore",
				"name": "Bulk Ore Charter",
				"name_key": "CONTRACT_CERES_EARTH_ORE_NAME",
				"desc": "Haul raw asteroid ore from Ceres extraction yards to Earth orbital foundries.",
				"desc_key": "CONTRACT_CERES_EARTH_ORE_DESC",
				"commodity": "ORE",
				"origin": "ceres",
				"destination": "earth",
				"lot_type": LOT_STANDARD,
				"qty": 50,
				"qty_range": [35, 75],
				"deadline_rounds": 8,
				"lead_rounds": [7, 10],
				"premium_bps": [13000, 15500],
				"reward_cr": 1950,
				"penalty_cr": 487,
			},
			{
				"id": "earth_ceres_food",
				"name": "Belt Ration Run",
				"name_key": "CONTRACT_EARTH_CERES_FOOD_NAME",
				"desc": "Deliver sealed hydroponic rations from Earth to Ceres before belt spoilage mounts.",
				"desc_key": "CONTRACT_EARTH_CERES_FOOD_DESC",
				"commodity": "FOOD",
				"origin": "earth",
				"destination": "ceres",
				"lot_type": LOT_STANDARD,
				"qty": 45,
				"qty_range": [30, 65],
				"deadline_rounds": 9,
				"lead_rounds": [7, 11],
				"premium_bps": [14000, 16500],
				"reward_cr": 1890,
				"penalty_cr": 472,
			},
			{
				"id": "luna_ceres_fuel",
				"name": "Deep-Belt Propellant Tender",
				"name_key": "CONTRACT_LUNA_CERES_FUEL_NAME",
				"desc": "Ferry refined He-3 propellant from Lunar cracking domes out to Ceres.",
				"desc_key": "CONTRACT_LUNA_CERES_FUEL_DESC",
				"commodity": "FUEL",
				"origin": "luna",
				"destination": "ceres",
				"lot_type": LOT_STANDARD,
				"qty": 50,
				"qty_range": [35, 70],
				"deadline_rounds": 8,
				"lead_rounds": [7, 10],
				"premium_bps": [13500, 16000],
				"reward_cr": 1800,
				"penalty_cr": 450,
			},
			{
				"id": "mars_ceres_machinery",
				"name": "Belt Tooling Shipment",
				"name_key": "CONTRACT_MARS_CERES_MACHINERY_NAME",
				"desc": "Ship heavy drilling assemblies from Mars manufactories to Ceres.",
				"desc_key": "CONTRACT_MARS_CERES_MACHINERY_DESC",
				"commodity": "MACHINERY",
				"origin": "mars",
				"destination": "ceres",
				"lot_type": LOT_STANDARD,
				"qty": 40,
				"qty_range": [25, 60],
				"deadline_rounds": 7,
				"lead_rounds": [6, 9],
				"premium_bps": [13000, 16000],
				"reward_cr": 1720,
				"penalty_cr": 430,
			},
			{
				"id": "ceres_earth_frag",
				"name": "Inner-System Salvage Haul",
				"name_key": "CONTRACT_CERES_EARTH_FRAG_NAME",
				"desc": "Move recovered belt hull fragments from Ceres breakers to Earth recyclers.",
				"desc_key": "CONTRACT_CERES_EARTH_FRAG_DESC",
				"commodity": "FRAG",
				"origin": "ceres",
				"destination": "earth",
				"lot_type": LOT_STANDARD,
				"qty": 55,
				"qty_range": [35, 75],
				"deadline_rounds": 8,
				"lead_rounds": [7, 10],
				"premium_bps": [13500, 16000],
				"reward_cr": 1650,
				"penalty_cr": 412,
			},
			{
				"id": "luna_mars_fuel",
				"name": "Ares Corridor Tanker",
				"name_key": "CONTRACT_LUNA_MARS_FUEL_NAME",
				"desc": "Supply Lunar propellant to Mars orbital staging depots.",
				"desc_key": "CONTRACT_LUNA_MARS_FUEL_DESC",
				"commodity": "FUEL",
				"origin": "luna",
				"destination": "mars",
				"lot_type": LOT_STANDARD,
				"qty": 45,
				"qty_range": [30, 65],
				"deadline_rounds": 7,
				"lead_rounds": [6, 9],
				"premium_bps": [13000, 15500],
				"reward_cr": 1080,
				"penalty_cr": 270,
			},
			{
				"id": "earth_luna_food",
				"name": "Cislunar Commissary Lift",
				"name_key": "CONTRACT_EARTH_LUNA_FOOD_NAME",
				"desc": "Short-hop agricultural freight from Earth spaceports to Luna.",
				"desc_key": "CONTRACT_EARTH_LUNA_FOOD_DESC",
				"commodity": "FOOD",
				"origin": "earth",
				"destination": "luna",
				"lot_type": LOT_STANDARD,
				"qty": 45,
				"qty_range": [30, 60],
				"deadline_rounds": 6,
				"lead_rounds": [6, 8],
				"premium_bps": [13000, 15000],
				"reward_cr": 1395,
				"penalty_cr": 348,
			},
			{
				"id": "mars_luna_machinery",
				"name": "Lunar Yard Heavy Freight",
				"name_key": "CONTRACT_MARS_LUNA_MACHINERY_NAME",
				"desc": "Oversized multi-bay machinery charter from Mars to Lunar shipyards.",
				"desc_key": "CONTRACT_MARS_LUNA_MACHINERY_DESC",
				"commodity": "MACHINERY",
				"origin": "mars",
				"destination": "luna",
				"lot_type": LOT_OVERSIZED,
				"qty": 130,
				"qty_range": [100, 160],
				"deadline_rounds": 12,
				"lead_rounds": [10, 15],
				"premium_bps": [15000, 18500],
				"reward_cr": 4940,
				"penalty_cr": 1235,
			},
			{
				"id": "ceres_luna_ore",
				"name": "Orbital Smelter Convoy",
				"name_key": "CONTRACT_CERES_LUNA_ORE_NAME",
				"desc": "Oversized bulk ore convoy from Ceres to Lunar zero-g smelters.",
				"desc_key": "CONTRACT_CERES_LUNA_ORE_DESC",
				"commodity": "ORE",
				"origin": "ceres",
				"destination": "luna",
				"lot_type": LOT_OVERSIZED,
				"qty": 140,
				"qty_range": [100, 180],
				"deadline_rounds": 13,
				"lead_rounds": [10, 16],
				"premium_bps": [15000, 18500],
				"reward_cr": 5040,
				"penalty_cr": 1260,
			},
		],
	}


static func post_every_rounds() -> int:
	return maxi(1, int(load_data().get("post_every_rounds", DEFAULT_POST_EVERY_ROUNDS)))


static func max_active() -> int:
	return maxi(1, int(load_data().get("max_active", DEFAULT_MAX_ACTIVE)))


static func max_offers() -> int:
	return maxi(1, int(load_data().get("max_offers", DEFAULT_MAX_OFFERS)))


static func first_penalty_bps() -> int:
	return clampi(int(load_data().get("first_penalty_bps", DEFAULT_FIRST_PENALTY_BPS)), 0, BPS)


static func penalty_bps() -> int:
	return clampi(int(load_data().get("penalty_bps", DEFAULT_PENALTY_BPS)), 0, BPS)


static func oversized_prob_bps() -> int:
	return clampi(int(load_data().get("oversized_prob_bps", DEFAULT_OVERSIZED_PROB_BPS)), 0, BPS)


## Novice survival (#162): first overdue contract costs first_penalty_bps (25%), later ones penalty_bps (50%).
static func penalty_bps_for_lapses(prior_lapses: int) -> int:
	return penalty_bps() if prior_lapses > 0 else first_penalty_bps()


static func penalty_for_reward(reward_cr: int, prior_lapses: int = 0) -> int:
	if reward_cr <= 0:
		return 0
	var rate: int = penalty_bps_for_lapses(prior_lapses)
	if rate <= 0:
		return 0
	return maxi(1, reward_cr * rate / BPS)


static func ids() -> Array[String]:
	var id_list: Array[String] = []
	var rows = load_data().get("contracts", [])
	if rows is Array:
		for row in rows:
			if row is Dictionary and str(row.get("id", "")) != "":
				id_list.append(str(row["id"]))
	return id_list


static func canonical_id(template_id: String) -> String:
	var k: String = template_id.strip_edges().to_lower()
	if k == "":
		return ""
	return k if ids().has(k) else ""


static func _raw_entry(canon: String) -> Dictionary:
	if canon == "":
		return {}
	var rows = load_data().get("contracts", [])
	if rows is Array:
		for row in rows:
			if row is Dictionary and str(row.get("id", "")) == canon:
				return row
	return {}


static func entry(template_id: String) -> Dictionary:
	var row: Dictionary = _raw_entry(canonical_id(template_id))
	return row.duplicate(true) if not row.is_empty() else {}


static func contract_name(template_id: String) -> String:
	var canon: String = canonical_id(template_id)
	var row: Dictionary = _raw_entry(canon)
	if row.is_empty():
		return ""
	return Loc.data_text(str(row.get("name_key", "")), str(row.get("name", canon)))


static func contract_summary(template_id: String) -> String:
	var canon: String = canonical_id(template_id)
	var row: Dictionary = _raw_entry(canon)
	if row.is_empty():
		return ""
	return Loc.data_text(str(row.get("desc_key", "")), str(row.get("desc", "")))


static func catalog() -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	for canon in ids():
		var row: Dictionary = entry(canon)
		row["display_name"] = contract_name(canon)
		row["summary"] = contract_summary(canon)
		items.append(row)
	return items


## Lowest equilibrium base-price station for `commodity` (matching agora/contracts.py:_post_locked).
static func cheapest_station_for(commodity: String) -> String:
	var canon_comm: String = Transit.normalize_commodity(commodity)
	var best_station: String = Transit.STATIONS[0]
	var best_px: float = INF
	for st in Transit.STATIONS:
		var px: float = float(Transit.BASE_PRICES.get(st, {}).get(canon_comm, INF))
		if px < best_px:
			best_px = px
			best_station = st
	return best_station


## Convenience factory for constructing a canonical station-to-station delivery contract Dictionary.
static func make_contract(
	commodity: String,
	qty: int,
	origin: String,
	destination: String,
	reward_cr: int,
	penalty_cr: int,
	deadline_round: int,
	contract_id: String = "",
	posted_round: int = 0,
	lot_type: String = LOT_STANDARD
) -> Dictionary:
	var raw: Dictionary = {
		"id": contract_id,
		"commodity": commodity,
		"qty": qty,
		"origin": origin,
		"destination": destination,
		"reward_cr": reward_cr,
		"penalty_cr": penalty_cr,
		"deadline_round": deadline_round,
		"posted_round": posted_round,
		"lot_type": lot_type,
	}
	return sanitize_contract(raw)


## Validates and normalizes an untrusted contract Dictionary; returns {} if invalid.
static func sanitize_contract(raw, prior_lapses: int = 0) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var d: Dictionary = raw
	var comm: String = Transit.normalize_commodity(str(d.get("commodity", "")))
	if not Transit.COMMODITIES.has(comm):
		return {}
	var orig: String = str(d.get("origin", "")).strip_edges().to_lower()
	var dest: String = str(d.get("destination", "")).strip_edges().to_lower()
	if not Transit.STATIONS.has(orig) or not Transit.STATIONS.has(dest) or orig == dest:
		return {}
	var raw_qty = d.get("qty", 0)
	if not (raw_qty is int or raw_qty is float):
		return {}
	var total_qty: int = clampi(int(raw_qty), 0, MAX_LOADED_QTY)
	if total_qty <= 0:
		return {}
	var delivered: int = 0
	if d.has("qty_delivered") and (d["qty_delivered"] is int or d["qty_delivered"] is float):
		delivered = clampi(int(d["qty_delivered"]), 0, total_qty - 1)
	elif d.has("qty_remaining") and (d["qty_remaining"] is int or d["qty_remaining"] is float):
		var rem_in: int = clampi(int(d["qty_remaining"]), 1, total_qty)
		delivered = total_qty - rem_in
	var remaining: int = total_qty - delivered

	var raw_deadline = d.get("deadline_round", -1)
	if not (raw_deadline is int or raw_deadline is float):
		return {}
	var deadline: int = clampi(int(raw_deadline), -1, MAX_LOADED_ROUND)
	if deadline < 0:
		return {}

	var raw_reward = d.get("reward_cr", 0)
	if not (raw_reward is int or raw_reward is float):
		return {}
	var reward: int = clampi(int(raw_reward), 0, MAX_LOADED_CR)

	var pen: int = 0
	if d.has("penalty_cr"):
		var raw_pen = d.get("penalty_cr", 0)
		if not (raw_pen is int or raw_pen is float):
			return {}
		pen = clampi(int(raw_pen), 0, MAX_LOADED_CR)
	else:
		pen = penalty_for_reward(reward, prior_lapses)

	var posted: int = clampi(_int_or(d.get("posted_round", 0), 0), 0, deadline)
	var accepted: int = clampi(_int_or(d.get("accepted_round", 0), 0), 0, MAX_LOADED_ROUND)
	var lot: String = LOT_OVERSIZED if str(d.get("lot_type", "")).strip_edges().to_lower() == LOT_OVERSIZED else LOT_STANDARD
	var cid: String = str(d.get("id", "")).strip_edges()
	var st_raw: String = str(d.get("status", STATUS_AVAILABLE)).strip_edges().to_lower()
	var status: String = st_raw if st_raw in [STATUS_AVAILABLE, STATUS_ACTIVE, STATUS_FULFILLED, STATUS_EXPIRED] else STATUS_AVAILABLE

	var norm: Dictionary = {
		"id": cid,
		"commodity": comm,
		"qty": total_qty,
		"qty_delivered": delivered,
		"qty_remaining": remaining,
		"origin": orig,
		"destination": dest,
		"reward_cr": reward,
		"penalty_cr": pen,
		"deadline_round": deadline,
		"posted_round": posted,
		"accepted_round": accepted,
		"lot_type": lot,
		"status": status,
	}
	var tmpl: String = canonical_id(str(d.get("template_id", "")))
	if tmpl != "":
		norm["template_id"] = tmpl
	return norm


static func _int_or(v, fallback: int = 0) -> int:
	return int(v) if (v is int or v is float) else fallback


static func _pair_bounds(data: Dictionary, key: String, fallback_lo: int, fallback_hi: int) -> Vector2i:
	var raw = data.get(key, [])
	if raw is Array and (raw as Array).size() >= 2:
		var a: int = _int_or((raw as Array)[0], fallback_lo)
		var b: int = _int_or((raw as Array)[1], fallback_hi)
		return Vector2i(mini(a, b), maxi(a, b))
	return Vector2i(fallback_lo, fallback_hi)


# ==============================================================================
# Instance State & Deterministic Contract Lifecycle
# ==============================================================================

func is_empty() -> bool:
	return active.is_empty() and available.is_empty() and fulfilled_count == 0 and expired_count == 0 and not auto_post_offers


func has_any() -> bool:
	return not is_empty()


func has_active() -> bool:
	return not active.is_empty()


func has_offers() -> bool:
	return not available.is_empty()


func penalty_rate_bps() -> int:
	return penalty_bps_for_lapses(expired_count)


func active_contracts() -> Array[Dictionary]:
	var snap: Array[Dictionary] = []
	for c in active:
		snap.append(c.duplicate(true))
	return snap


func available_contracts() -> Array[Dictionary]:
	var snap: Array[Dictionary] = []
	for o in available:
		snap.append(o.duplicate(true))
	return snap


func get_active(contract_id: String) -> Dictionary:
	var target: String = contract_id.strip_edges()
	if target == "":
		return {}
	for c in active:
		if str(c.get("id", "")) == target:
			return c.duplicate(true)
	return {}


func get_offer(contract_id: String) -> Dictionary:
	var target: String = contract_id.strip_edges()
	if target == "":
		return {}
	for o in available:
		if str(o.get("id", "")) == target:
			return o.duplicate(true)
	return {}


func _alloc_id(prefix: String = "c") -> String:
	while true:
		var candidate: String = "%s_%d" % [prefix, next_seq]
		next_seq += 1
		if not _id_in_use(candidate):
			return candidate
	return "%s_%d" % [prefix, next_seq]


func _id_in_use(cid: String) -> bool:
	for c in active:
		if str(c.get("id", "")) == cid:
			return true
	for o in available:
		if str(o.get("id", "")) == cid:
			return true
	return false


## Instantiates a concrete offer Dictionary from a contracts.json archetype id and posts it to `available`.
func post_from_template(template_id: String, current_round: int = 0) -> Dictionary:
	var canon: String = canonical_id(template_id)
	var row: Dictionary = _raw_entry(canon)
	if row.is_empty():
		return {}
	var rnd: int = clampi(current_round, 0, MAX_LOADED_ROUND)
	var lead: int = maxi(1, _int_or(row.get("deadline_rounds", 8), 8))
	var reward: int = maxi(1, _int_or(row.get("reward_cr", 1000), 1000))
	var pen: int = penalty_for_reward(reward, expired_count)
	var cid: String = _alloc_id("k_%s_r%d" % [canon, rnd])
	var offer: Dictionary = sanitize_contract({
		"id": cid,
		"template_id": canon,
		"commodity": str(row.get("commodity", "")),
		"qty": _int_or(row.get("qty", 40), 40),
		"origin": str(row.get("origin", "")),
		"destination": str(row.get("destination", "")),
		"reward_cr": reward,
		"penalty_cr": pen,
		"deadline_round": rnd + lead,
		"posted_round": rnd,
		"lot_type": str(row.get("lot_type", LOT_STANDARD)),
		"status": STATUS_AVAILABLE,
	}, expired_count)
	if offer.is_empty():
		return {}
	_push_offer(offer)
	return offer.duplicate(true)


## Posts an explicit contract offer Dictionary onto `available`. Returns the normalized copy or {}.
func post_offer(raw_offer: Dictionary, current_round: int = 0) -> Dictionary:
	var norm: Dictionary = sanitize_contract(raw_offer, expired_count)
	if norm.is_empty():
		return {}
	var rnd: int = clampi(current_round, 0, MAX_LOADED_ROUND)
	if int(norm["deadline_round"]) < rnd:
		return {}
	if str(norm["id"]) == "" or _id_in_use(str(norm["id"])):
		norm["id"] = _alloc_id("offer")
	norm["status"] = STATUS_AVAILABLE
	if not raw_offer.has("posted_round"):
		norm["posted_round"] = mini(rnd, int(norm["deadline_round"]))
	_push_offer(norm)
	return norm.duplicate(true)


func _push_offer(offer: Dictionary) -> void:
	available.append(offer)
	var cap: int = max_offers()
	while available.size() > cap:
		available.pop_front()


## Deterministically generates and posts one station-to-station contract offer for `(run_seed, current_round)`.
## Mirrors agora/contracts.py:_post_locked using StableHash + NativeDrawSource so saves never need RNG state.
func generate_offer(run_seed: int, current_round: int = 0) -> Dictionary:
	var data: Dictionary = load_data()
	var rnd: int = clampi(current_round, 0, MAX_LOADED_ROUND)
	var seq_num: int = maxi(1, next_seq)
	var draw := NativeDrawSource.new(StableHash.hash32("contracts-%d-%d-%d" % [run_seed, rnd, seq_num]))

	var comm: String = str(draw.choice(Transit.COMMODITIES))
	var orig: String = cheapest_station_for(comm)
	var dest_choices: Array[String] = []
	for st in Transit.STATIONS:
		if st != orig:
			dest_choices.append(st)
	var dest: String = str(draw.choice(dest_choices))

	var is_oversized: bool = draw.randint(0, BPS - 1) < oversized_prob_bps()
	var qty_bounds: Vector2i = _pair_bounds(
		data,
		"oversized_qty" if is_oversized else "standard_qty",
		90 if is_oversized else 25,
		180 if is_oversized else 65
	)
	var dl_bounds: Vector2i = _pair_bounds(
		data,
		"oversized_deadline_rounds" if is_oversized else "standard_deadline_rounds",
		10 if is_oversized else 6,
		16 if is_oversized else 10
	)
	var prem_bounds: Vector2i = _pair_bounds(
		data,
		"oversized_premium_bps" if is_oversized else "standard_premium_bps",
		15000 if is_oversized else 13000,
		18500 if is_oversized else 16000
	)

	var qty: int = draw.randint(qty_bounds.x, qty_bounds.y)
	var lead_rounds: int = draw.randint(dl_bounds.x, dl_bounds.y)
	var prem_bps: int = draw.randint(prem_bounds.x, prem_bounds.y)
	var base_px: float = float(Transit.BASE_PRICES.get(dest, {}).get(comm, 10.0))
	var unit_px: int = maxi(1, Transit.py_round(base_px * float(prem_bps) / float(BPS)))
	var reward: int = qty * unit_px
	var pen: int = penalty_for_reward(reward, expired_count)
	var cid: String = _alloc_id("k_r%d_%s" % [rnd, dest.substr(0, 2)])

	var offer: Dictionary = sanitize_contract({
		"id": cid,
		"commodity": comm,
		"qty": qty,
		"origin": orig,
		"destination": dest,
		"reward_cr": reward,
		"penalty_cr": pen,
		"deadline_round": rnd + lead_rounds,
		"posted_round": rnd,
		"lot_type": LOT_OVERSIZED if is_oversized else LOT_STANDARD,
		"status": STATUS_AVAILABLE,
	}, expired_count)
	_push_offer(offer)
	return offer.duplicate(true)


## Posts a scheduled board offer on cadence rounds (`round_num > 0 and round_num % post_every_rounds() == 0`).
func post_round_offers(round_num: int, run_seed: int = 0) -> Array[Dictionary]:
	var posted_list: Array[Dictionary] = []
	if round_num > 0 and (round_num % post_every_rounds()) == 0:
		var offer: Dictionary = generate_offer(run_seed, round_num)
		if not offer.is_empty():
			posted_list.append(offer)
	return posted_list


## Pure eligibility check for accepting `contract_or_id` (an offer ID in `available`, a template ID,
## or a contract Dictionary) at `current_round`.
## Refusal reasons: RUN_OVER, NOT_FOUND, INVALID_CONTRACT, ALREADY_ACTIVE, EXPIRED, MAX_ACTIVE.
func can_accept(contract_or_id, current_round: int = 0, run_over: bool = false) -> Dictionary:
	var res: Dictionary = {
		"ok": false,
		"reason": "",
		"contract": {},
	}
	if run_over:
		res["reason"] = "RUN_OVER"
		return res

	var candidate: Dictionary = {}
	if contract_or_id is String:
		var key: String = (contract_or_id as String).strip_edges()
		if key == "":
			res["reason"] = "NOT_FOUND"
			return res
		for c_act in active:
			if str(c_act.get("id", "")) == key:
				res["reason"] = "ALREADY_ACTIVE"
				return res
		for o in available:
			if str(o.get("id", "")) == key:
				candidate = o.duplicate(true)
				break
		if candidate.is_empty():
			res["reason"] = "NOT_FOUND"
			return res
	elif contract_or_id is Dictionary:
		candidate = sanitize_contract(contract_or_id, expired_count)
		if candidate.is_empty():
			res["reason"] = "INVALID_CONTRACT"
			return res
		var cid: String = str(candidate.get("id", ""))
		if cid != "":
			for c_act in active:
				if str(c_act.get("id", "")) == cid:
					res["reason"] = "ALREADY_ACTIVE"
					return res
	else:
		res["reason"] = "INVALID_CONTRACT"
		return res

	if int(candidate["deadline_round"]) < current_round:
		res["reason"] = "EXPIRED"
		res["contract"] = candidate
		return res
	if active.size() >= max_active():
		res["reason"] = "MAX_ACTIVE"
		res["contract"] = candidate
		return res

	res["ok"] = true
	res["contract"] = candidate
	return res


## Accepts an open contract offer (by ID from `available` or by Dictionary) into `active`.
## Returns {"ok": bool, "reason": String, "contract": Dictionary}; mutates nothing on failure.
func accept_contract(contract_or_id, current_round: int = 0, run_over: bool = false) -> Dictionary:
	var check: Dictionary = can_accept(contract_or_id, current_round, run_over)
	if not bool(check["ok"]):
		return check
	var entry_dict: Dictionary = (check["contract"] as Dictionary).duplicate(true)
	var cid: String = str(entry_dict.get("id", ""))
	if cid == "":
		cid = _alloc_id("c")
		entry_dict["id"] = cid
	else:
		for i in range(available.size() - 1, -1, -1):
			if str(available[i].get("id", "")) == cid:
				available.remove_at(i)
				break
	var rnd: int = clampi(current_round, 0, MAX_LOADED_ROUND)
	entry_dict["accepted_round"] = rnd
	if int(entry_dict.get("posted_round", 0)) > int(entry_dict["deadline_round"]):
		entry_dict["posted_round"] = int(entry_dict["deadline_round"])
	entry_dict["status"] = STATUS_ACTIVE
	active.append(entry_dict)
	return {
		"ok": true,
		"reason": "",
		"contract": entry_dict.duplicate(true),
	}


## Fulfills active contracts whose `destination` matches `station` and `deadline_round >= current_round`,
## deducting delivered units from `cargo` in place.
## By default (`allow_partial == false`), a contract fulfills when `cargo[commodity] >= qty_remaining`.
## When `allow_partial == true`, partial cargo delivers pro-rata (agora/contracts.py oversized haul parity).
func fulfill_at_station(
	station: String,
	cargo: Dictionary,
	current_round: int = 0,
	allow_partial: bool = false
) -> Dictionary:
	var fulfilled_list: Array[Dictionary] = []
	var partial_list: Array[Dictionary] = []
	var total_reward: int = 0
	var st: String = station.strip_edges().to_lower()
	if st == "" or not Transit.STATIONS.has(st) or active.is_empty():
		return {
			"fulfilled": fulfilled_list,
			"partial": partial_list,
			"reward_cr": 0,
			"count": 0,
		}

	var rnd: int = clampi(current_round, 0, MAX_LOADED_ROUND)
	var remaining_active: Array[Dictionary] = []
	for c in active:
		if str(c["destination"]) != st or int(c["deadline_round"]) < rnd:
			remaining_active.append(c)
			continue
		var comm: String = str(c["commodity"])
		var have: int = maxi(0, _int_or(cargo.get(comm, 0), 0))
		var rem: int = maxi(0, int(c["qty_remaining"]))
		if rem <= 0:
			continue
		if have >= rem:
			var left_hold: int = have - rem
			if left_hold > 0:
				cargo[comm] = left_hold
			else:
				cargo.erase(comm)
			var paid: int = maxi(0, int(c["reward_cr"]))
			total_reward += paid
			fulfilled_count += 1
			var done_copy: Dictionary = c.duplicate(true)
			done_copy["qty_delivered"] = int(c["qty"])
			done_copy["qty_remaining"] = 0
			done_copy["status"] = STATUS_FULFILLED
			done_copy["fulfilled_round"] = rnd
			done_copy["reward_paid"] = paid
			fulfilled_list.append(done_copy)
		elif allow_partial and have > 0:
			cargo.erase(comm)
			var paid_part: int = maxi(0, int(c["reward_cr"])) * have / rem
			var pen_part: int = maxi(0, int(c["penalty_cr"])) * have / rem
			c["qty_delivered"] = int(c["qty_delivered"]) + have
			c["qty_remaining"] = rem - have
			c["reward_cr"] = maxi(0, int(c["reward_cr"]) - paid_part)
			c["penalty_cr"] = maxi(0, int(c["penalty_cr"]) - pen_part)
			total_reward += paid_part
			var part_copy: Dictionary = c.duplicate(true)
			part_copy["delivered_now"] = have
			part_copy["reward_paid"] = paid_part
			partial_list.append(part_copy)
			remaining_active.append(c)
		else:
			remaining_active.append(c)

	active = remaining_active
	return {
		"fulfilled": fulfilled_list,
		"partial": partial_list,
		"reward_cr": total_reward,
		"count": fulfilled_list.size(),
	}


## Expires overdue contracts (`deadline_round < current_round`).
## Unaccepted board offers in `available` are pruned without penalty; overdue player contracts in
## `active` are removed, increment `expired_count`, and sum their `penalty_cr`.
func expire_overdue(current_round: int) -> Dictionary:
	var expired_list: Array[Dictionary] = []
	var expired_offers: Array[String] = []
	var total_penalty: int = 0
	var rnd: int = clampi(current_round, 0, MAX_LOADED_ROUND)

	var kept_offers: Array[Dictionary] = []
	for o in available:
		if int(o["deadline_round"]) < rnd:
			expired_offers.append(str(o.get("id", "")))
		else:
			kept_offers.append(o)
	available = kept_offers

	var kept_active: Array[Dictionary] = []
	for c in active:
		if int(c["deadline_round"]) < rnd:
			var pen: int = maxi(0, int(c["penalty_cr"]))
			total_penalty += pen
			expired_count += 1
			var exp_copy: Dictionary = c.duplicate(true)
			exp_copy["status"] = STATUS_EXPIRED
			exp_copy["expired_round"] = rnd
			expired_list.append(exp_copy)
		else:
			kept_active.append(c)
	active = kept_active

	return {
		"expired": expired_list,
		"expired_offers": expired_offers,
		"penalty_cr": total_penalty,
		"count": expired_list.size(),
	}


## Clears active corporation obligations when a Chapter 11 bankruptcy founds a new corporation.
func reset_for_new_corp() -> void:
	available.clear()
	active.clear()
	fulfilled_count = 0
	expired_count = 0


static func _serialize_entry(c: Dictionary, forced_status: String) -> Dictionary:
	var entry_out: Dictionary = {
		"id": str(c.get("id", "")),
		"commodity": str(c.get("commodity", "")),
		"qty": int(c.get("qty", 0)),
		"qty_delivered": int(c.get("qty_delivered", 0)),
		"qty_remaining": int(c.get("qty_remaining", 0)),
		"origin": str(c.get("origin", "")),
		"destination": str(c.get("destination", "")),
		"reward_cr": int(c.get("reward_cr", 0)),
		"penalty_cr": int(c.get("penalty_cr", 0)),
		"deadline_round": int(c.get("deadline_round", 0)),
		"posted_round": int(c.get("posted_round", 0)),
		"accepted_round": int(c.get("accepted_round", 0)),
		"lot_type": str(c.get("lot_type", LOT_STANDARD)),
		"status": forced_status,
	}
	var tmpl: String = canonical_id(str(c.get("template_id", "")))
	if tmpl != "":
		entry_out["template_id"] = tmpl
	return entry_out


func to_dict() -> Dictionary:
	var avail_out: Array = []
	for o in available:
		avail_out.append(_serialize_entry(o, STATUS_AVAILABLE))
	var active_out: Array = []
	for c in active:
		active_out.append(_serialize_entry(c, STATUS_ACTIVE))
	var serialized: Dictionary = {
		"available": avail_out,
		"active": active_out,
		"fulfilled_count": clampi(fulfilled_count, 0, MAX_LOADED_ROUND),
		"expired_count": clampi(expired_count, 0, MAX_LOADED_ROUND),
		"next_seq": clampi(next_seq, 1, MAX_LOADED_ROUND),
	}
	if auto_post_offers:
		serialized["auto_post_offers"] = true
	return serialized


static func from_dict(raw) -> Contracts:
	var inst := Contracts.new()
	if not (raw is Dictionary):
		return inst
	var d: Dictionary = raw
	inst.fulfilled_count = clampi(_int_or(d.get("fulfilled_count", 0), 0), 0, MAX_LOADED_ROUND)
	inst.expired_count = clampi(_int_or(d.get("expired_count", 0), 0), 0, MAX_LOADED_ROUND)
	inst.next_seq = clampi(_int_or(d.get("next_seq", 1), 1), 1, MAX_LOADED_ROUND)
	var ap = d.get("auto_post_offers", false)
	inst.auto_post_offers = (ap is bool) and ap

	var seen_ids: Dictionary = {}
	var raw_active = d.get("active", [])
	if raw_active is Array:
		var cap_act: int = max_active()
		for item in raw_active:
			if inst.active.size() >= cap_act:
				break
			var norm_act: Dictionary = sanitize_contract(item, inst.expired_count)
			if norm_act.is_empty():
				continue
			var cid: String = str(norm_act.get("id", ""))
			if cid == "" or seen_ids.has(cid):
				cid = inst._alloc_id("c")
				norm_act["id"] = cid
			seen_ids[cid] = true
			norm_act["status"] = STATUS_ACTIVE
			inst.active.append(norm_act)

	var raw_avail = d.get("available", [])
	if raw_avail is Array:
		for item in raw_avail:
			if inst.available.size() >= MAX_LOADED_CONTRACTS:
				break
			var norm_av: Dictionary = sanitize_contract(item, inst.expired_count)
			if norm_av.is_empty():
				continue
			var oid: String = str(norm_av.get("id", ""))
			if oid == "" or seen_ids.has(oid):
				continue
			seen_ids[oid] = true
			norm_av["status"] = STATUS_AVAILABLE
			inst.available.append(norm_av)
		var offer_cap: int = max_offers()
		while inst.available.size() > offer_cap:
			inst.available.pop_front()

	return inst
