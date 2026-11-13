class_name Upgrades
extends RefCounted
## Mid-run ship upgrades engine (#214), ported from agora/upgrades.py.
##
## Bought with integer CR while docked at any station, one tier at a time and in order, on a
## staggered round-unlock schedule across the 120-round run. Each tier replaces the previous
## tier's factor (never compounding on top of earlier tiers of the same line) and capitalizes
## into corporate hull value (50% liquidation recovery under default Chapter 11 haircut).
## A Chapter 11 bankruptcy forfeits the failed corp's ship and its fitted upgrades.
##
## Four core roguelike ship upgrade lines (data/upgrades.json):
##   1. cargo_hold   - Cargo Hold Expansion (+50 / +125 / +250 cargo capacity above base)
##   2. bulkheads    - Reinforced Bulkheads (x0.75 / x0.45 / x0.25 hazard odds; tier 2+ also
##                     cuts hull-breach cargo loss size by 30%)
##   3. thrusters    - Thruster Overdrive (x0.85 / x0.70 / x0.55 transit ticks; tier 1+ trims
##                     1 round off 3+ round routes; tier 2+ cuts route fuel burn by 40%)
##   4. transponders - Decoy Transponders (x0.70 / x0.45 / x0.25 piracy raid odds)

const DATA_PATH: String = "res://data/upgrades.json"
const BPS: int = 10000
const DEFAULT_CAPITAL_BPS: int = 5000
const MAX_LOADED_ROUND: int = 1000000

const ID_CARGO_HOLD: String = "cargo_hold"
const ID_BULKHEADS: String = "bulkheads"
const ID_THRUSTERS: String = "thrusters"
const ID_TRANSPONDERS: String = "transponders"

static var _cache: Dictionary = {}

## Owned upgrade tiers for the active corporation: canonical_id -> int (1..max_tier).
var tiers: Dictionary = {}
## Round when the current tier of each owned upgrade was fitted: canonical_id -> int (>= 0).
var purchased_rounds: Dictionary = {}


static func reset_cache() -> void:
	_cache = {}


static func load_data(path: String = DATA_PATH) -> Dictionary:
	if path == DATA_PATH and not _cache.is_empty():
		return _cache
	var loaded: Dictionary = {}
	if FileAccess.file_exists(path):
		var raw: String = FileAccess.get_file_as_string(path)
		var parsed = JSON.parse_string(raw)
		if parsed is Dictionary and (parsed as Dictionary).get("upgrades") is Array:
			loaded = parsed
	if loaded.is_empty():
		loaded = _fallback()
	if path == DATA_PATH:
		_cache = loaded
	return loaded


static func _fallback() -> Dictionary:
	return {
		"version": 1,
		"capital_bps": DEFAULT_CAPITAL_BPS,
		"upgrades": [
			{
				"id": ID_CARGO_HOLD,
				"name": "Cargo Hold Expansion",
				"name_key": "UPG_CARGO_HOLD_NAME",
				"desc": "Expands cargo hold capacity for larger freight runs.",
				"desc_key": "UPG_CARGO_HOLD_DESC",
				"prices": [2500, 5500, 10000],
				"unlock_rounds": [0, 30, 65],
				"tier_names": ["Modular Cargo Pods", "Pressurized Freight Bays", "Orbital Bulk Hold"],
				"tier_name_keys": ["UPG_CARGO_HOLD_T1", "UPG_CARGO_HOLD_T2", "UPG_CARGO_HOLD_T3"],
				"cargo_bonus": [50, 125, 250],
			},
			{
				"id": ID_BULKHEADS,
				"name": "Reinforced Bulkheads",
				"name_key": "UPG_BULKHEADS_NAME",
				"desc": "Lowers transit hazard odds and cuts hull-breach cargo losses from tier 2.",
				"desc_key": "UPG_BULKHEADS_DESC",
				"prices": [3000, 7000, 14000],
				"unlock_rounds": [0, 35, 75],
				"tier_names": ["Just-in-Time Hold Pods", "Supply Chain Optimization Bays", "Vertical Integration Storage"],
				"tier_name_keys": ["UPG_BULKHEADS_T1", "UPG_BULKHEADS_T2", "UPG_BULKHEADS_T3"],
				"hazard_odds_bps": [7500, 4500, 2500],
				"delay_odds_bps": [8500, 6000, 3500],
				"loss_size_bps": [10000, 7000, 7000],
			},
			{
				"id": ID_THRUSTERS,
				"name": "Thruster Overdrive",
				"name_key": "UPG_THRUSTERS_NAME",
				"desc": "Cuts transit ticks across Sol lanes, trims 3-round voyages and lowers fuel burn at higher tiers.",
				"desc_key": "UPG_THRUSTERS_DESC",
				"prices": [4000, 9000, 16000],
				"unlock_rounds": [10, 45, 85],
				"tier_names": ["Turnaround Thrusters", "Hyper-Growth Propellant Loops", "Overdrive Fusion Torch"],
				"tier_name_keys": ["UPG_THRUSTERS_T1", "UPG_THRUSTERS_T2", "UPG_THRUSTERS_T3"],
				"transit_ticks_bps": [8500, 7000, 5500],
				"engine_tier": [1, 2, 2],
			},
			{
				"id": ID_TRANSPONDERS,
				"name": "Decoy Transponders",
				"name_key": "UPG_TRANSPONDERS_NAME",
				"desc": "Masks ship transponders to evade corridor piracy and privateer raids.",
				"desc_key": "UPG_TRANSPONDERS_DESC",
				"prices": [3500, 8000, 15000],
				"unlock_rounds": [0, 40, 80],
				"tier_names": ["Synergy Plating", "Hostile Takeover Countermeasures", "Ghost-Signal Transponder Array"],
				"tier_name_keys": ["UPG_TRANSPONDERS_T1", "UPG_TRANSPONDERS_T2", "UPG_TRANSPONDERS_T3"],
				"piracy_odds_bps": [7000, 4500, 2500],
			},
		],
		"aliases": {
			"bulk_storage": ID_CARGO_HOLD,
			"cargo_hold_expansion": ID_CARGO_HOLD,
			"hold": ID_BULKHEADS,
			"shielding": ID_BULKHEADS,
			"reinforced_bulkheads": ID_BULKHEADS,
			"engines": ID_THRUSTERS,
			"thruster_overdrive": ID_THRUSTERS,
			"armor": ID_TRANSPONDERS,
			"stealth_drives": ID_TRANSPONDERS,
			"decoy_transponders": ID_TRANSPONDERS,
		},
	}


static func capital_bps() -> int:
	return clampi(int(load_data().get("capital_bps", DEFAULT_CAPITAL_BPS)), 0, BPS)


static func ids() -> Array[String]:
	var id_list: Array[String] = []
	var rows = load_data().get("upgrades", [])
	if rows is Array:
		for row in rows:
			if row is Dictionary and str(row.get("id", "")) != "":
				id_list.append(str(row["id"]))
	return id_list


static func aliases() -> Dictionary:
	var raw = load_data().get("aliases", {})
	return (raw as Dictionary).duplicate() if raw is Dictionary else {}


static func canonical_id(kind: String) -> String:
	var k: String = kind.strip_edges().to_lower()
	if k == "":
		return ""
	var valid_ids: Array[String] = ids()
	if valid_ids.has(k):
		return k
	var alias_map: Dictionary = aliases()
	if alias_map.has(k):
		var mapped: String = str(alias_map[k]).strip_edges().to_lower()
		if valid_ids.has(mapped):
			return mapped
	return ""


static func _raw_entry(canon: String) -> Dictionary:
	if canon == "":
		return {}
	var rows = load_data().get("upgrades", [])
	if rows is Array:
		for row in rows:
			if row is Dictionary and str(row.get("id", "")) == canon:
				return row
	return {}


static func entry(kind: String) -> Dictionary:
	var row: Dictionary = _raw_entry(canonical_id(kind))
	return row.duplicate(true) if not row.is_empty() else {}


static func max_tier(kind: String) -> int:
	var row: Dictionary = _raw_entry(canonical_id(kind))
	var prices = row.get("prices", [])
	return (prices as Array).size() if prices is Array else 0


static func price_for_tier(kind: String, tier_num: int) -> int:
	var row: Dictionary = _raw_entry(canonical_id(kind))
	var prices = row.get("prices", [])
	if not (prices is Array) or tier_num < 1 or tier_num > (prices as Array).size():
		return 0
	return maxi(0, int((prices as Array)[tier_num - 1]))


static func unlock_round(kind: String, tier_num: int = 1) -> int:
	var row: Dictionary = _raw_entry(canonical_id(kind))
	var unlocks = row.get("unlock_rounds", [])
	if not (unlocks is Array) or tier_num < 1 or tier_num > (unlocks as Array).size():
		return 0
	return maxi(0, int((unlocks as Array)[tier_num - 1]))


static func upgrade_name(kind: String) -> String:
	var canon: String = canonical_id(kind)
	var row: Dictionary = _raw_entry(canon)
	if row.is_empty():
		return ""
	return Loc.data_text(str(row.get("name_key", "")), str(row.get("name", canon)))


static func upgrade_summary(kind: String) -> String:
	var canon: String = canonical_id(kind)
	var row: Dictionary = _raw_entry(canon)
	if row.is_empty():
		return ""
	return Loc.data_text(str(row.get("desc_key", "")), str(row.get("desc", "")))


static func tier_name(kind: String, tier_num: int) -> String:
	var canon: String = canonical_id(kind)
	var row: Dictionary = _raw_entry(canon)
	if row.is_empty() or tier_num < 1:
		return ""
	var names = row.get("tier_names", [])
	var keys = row.get("tier_name_keys", [])
	var fallback: String = "%s T%d" % [canon.to_upper(), tier_num]
	if names is Array and tier_num <= (names as Array).size():
		fallback = str((names as Array)[tier_num - 1])
	var key: String = ""
	if keys is Array and tier_num <= (keys as Array).size():
		key = str((keys as Array)[tier_num - 1])
	return Loc.data_text(key, fallback)


static func _tier_int(row: Dictionary, field: String, tier_num: int, default_val: int) -> int:
	if row.is_empty() or tier_num <= 0:
		return default_val
	var vals = row.get(field, [])
	if not (vals is Array) or (vals as Array).is_empty():
		return default_val
	var arr: Array = vals
	var idx: int = mini(tier_num - 1, arr.size() - 1)
	return int(arr[idx])


## Pure purchase eligibility check for `kind` at `current_round` with `available_cr`.
## Refusal reasons mirror RunController.can_depart() uppercase codes:
##   RUN_OVER, UNKNOWN_UPGRADE, IN_TRANSIT, MAX_TIER, LOCKED, INSUFFICIENT_CR.
static func can_buy_for(
	current_tiers: Dictionary,
	kind: String,
	current_round: int,
	available_cr: int,
	is_docked: bool = true,
	run_over: bool = false
) -> Dictionary:
	var canon: String = canonical_id(kind)
	var max_t: int = max_tier(canon) if canon != "" else 0
	var cur_t: int = clampi(int(current_tiers.get(canon, 0)), 0, max_t) if canon != "" else 0
	var eval_t: int = cur_t + 1 if cur_t < max_t else max_t
	var req_round: int = unlock_round(canon, eval_t) if (canon != "" and eval_t > 0) else 0
	var req_price: int = price_for_tier(canon, eval_t) if (canon != "" and cur_t < max_t) else 0
	var res: Dictionary = {
		"ok": false,
		"reason": "",
		"id": canon,
		"tier": eval_t,
		"current_tier": cur_t,
		"max_tier": max_t,
		"price": req_price,
		"unlock_round": req_round,
	}
	if run_over:
		res["reason"] = "RUN_OVER"
	elif canon == "":
		res["reason"] = "UNKNOWN_UPGRADE"
	elif not is_docked:
		res["reason"] = "IN_TRANSIT"
	elif cur_t >= max_t:
		res["reason"] = "MAX_TIER"
	elif current_round < req_round:
		res["reason"] = "LOCKED"
	elif available_cr < req_price:
		res["reason"] = "INSUFFICIENT_CR"
	else:
		res["ok"] = true
	return res


## Full shipyard catalog annotated for `current_round` and `current_tiers`.
static func catalog_for(current_round: int = 0, current_tiers: Dictionary = {}) -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	for canon in ids():
		var row: Dictionary = _raw_entry(canon)
		var prices: Array = (row.get("prices", []) as Array).duplicate()
		var unlocks: Array = (row.get("unlock_rounds", []) as Array).duplicate()
		var max_t: int = prices.size()
		var cur_t: int = clampi(int(current_tiers.get(canon, 0)), 0, max_t)
		var next_t: int = cur_t + 1 if cur_t < max_t else 0
		var next_price: int = int(prices[next_t - 1]) if next_t > 0 else 0
		var next_unlock: int = int(unlocks[next_t - 1]) if (next_t > 0 and next_t <= unlocks.size()) else 0
		var tier_rows: Array[Dictionary] = []
		for i in range(max_t):
			var t_num: int = i + 1
			var u_rnd: int = int(unlocks[i]) if i < unlocks.size() else 0
			tier_rows.append({
				"tier": t_num,
				"name": tier_name(canon, t_num),
				"price": int(prices[i]),
				"unlock_round": u_rnd,
				"locked": u_rnd > current_round,
				"owned": cur_t >= t_num,
			})
		items.append({
			"id": canon,
			"kind": canon,
			"name": upgrade_name(canon),
			"summary": upgrade_summary(canon),
			"current_tier": cur_t,
			"max_tier": max_t,
			"tiers": max_t,
			"next_tier": next_t,
			"next_price": next_price,
			"next_unlock_round": next_unlock,
			"unlock_round": int(unlocks[0]) if not unlocks.is_empty() else 0,
			"locked": next_t > 0 and current_round < next_unlock,
			"maxed": cur_t >= max_t,
			"prices": prices,
			"unlock_rounds": unlocks,
			"tier_detail": tier_rows,
		})
	return items


## Tiers newly unlocked on `round_num` (round_num > 0; round-0 tiers are open from the start).
static func unlocked_at_round(round_num: int) -> Array[Dictionary]:
	var unlocked: Array[Dictionary] = []
	if round_num <= 0:
		return unlocked
	for canon in ids():
		var max_t: int = max_tier(canon)
		for t_num in range(1, max_t + 1):
			if unlock_round(canon, t_num) == round_num:
				unlocked.append({
					"id": canon,
					"tier": t_num,
					"name": tier_name(canon, t_num),
					"price": price_for_tier(canon, t_num),
				})
	return unlocked


static func cargo_bonus_for_tier(tier_num: int) -> int:
	return _tier_int(_raw_entry(ID_CARGO_HOLD), "cargo_bonus", tier_num, 0)


# ==============================================================================
# Instance State & Deterministic Effect Queries
# ==============================================================================

func has_any() -> bool:
	return not tiers.is_empty()


func tier(kind: String) -> int:
	var canon: String = canonical_id(kind)
	if canon == "":
		return 0
	return clampi(int(tiers.get(canon, 0)), 0, max_tier(canon))


func purchased_round(kind: String) -> int:
	var canon: String = canonical_id(kind)
	if canon == "" or not tiers.has(canon):
		return -1
	return int(purchased_rounds.get(canon, 0))


func holdings() -> Dictionary:
	var snap: Dictionary = {}
	for canon in ids():
		var t: int = int(tiers.get(canon, 0))
		if t > 0:
			snap[canon] = t
	return snap


func catalog(current_round: int = 0) -> Array[Dictionary]:
	return catalog_for(current_round, tiers)


## Extra cargo capacity in units added by Cargo Hold Expansion (0 when unowned).
func cargo_bonus() -> int:
	return _tier_int(_raw_entry(ID_CARGO_HOLD), "cargo_bonus", tier(ID_CARGO_HOLD), 0)


## Hazard odds multiplier in bps (10000 = x1.0) from Reinforced Bulkheads.
func hazard_odds_bps() -> int:
	return _tier_int(_raw_entry(ID_BULKHEADS), "hazard_odds_bps", tier(ID_BULKHEADS), BPS)


## Flight-delay odds multiplier in bps (10000 = x1.0; Python `shielding` parity).
func delay_odds_bps() -> int:
	return _tier_int(_raw_entry(ID_BULKHEADS), "delay_odds_bps", tier(ID_BULKHEADS), BPS)


## Hull-breach cargo loss size multiplier in bps (10000 = x1.0; 7000 at tier 2+).
func loss_size_bps() -> int:
	return _tier_int(_raw_entry(ID_BULKHEADS), "loss_size_bps", tier(ID_BULKHEADS), BPS)


## Float share of rolled cargo loss left by Reinforced Bulkheads (1.0 at T0/T1, 0.7 at T2/T3).
func loss_size_factor() -> float:
	var bps_val: int = loss_size_bps()
	return 1.0 if bps_val == BPS else float(bps_val) / float(BPS)


## Scales a rolled integer cargo loss by loss_size_bps().
func apply_hazard_loss(rolled_loss: int) -> int:
	if rolled_loss <= 0:
		return 0
	var bps_val: int = loss_size_bps()
	return rolled_loss if bps_val == BPS else maxi(0, rolled_loss * bps_val / BPS)


## Transit tick duration multiplier in bps (10000 = x1.0) from Thruster Overdrive.
func transit_ticks_bps() -> int:
	return _tier_int(_raw_entry(ID_THRUSTERS), "transit_ticks_bps", tier(ID_THRUSTERS), BPS)


## Applies Thruster Overdrive tick scaling to `base_ticks`, floored at 1 tick when positive.
func apply_transit_ticks(base_ticks: int) -> int:
	if base_ticks <= 0:
		return 0
	var bps_val: int = transit_ticks_bps()
	return base_ticks if bps_val == BPS else maxi(1, base_ticks * bps_val / BPS)


## Effective Transit engine tier (0, 1, or 2) conferred by Thruster Overdrive.
func engine_tier() -> int:
	return _tier_int(_raw_entry(ID_THRUSTERS), "engine_tier", tier(ID_THRUSTERS), 0)


## Rounds trimmed off a voyage of `rounds` rounds by Thruster Overdrive (1 off 3+ round routes).
func engine_cut(rounds: int) -> int:
	return Transit.engine_cut(engine_tier(), rounds)


## Fuel burned on a route whose base burn is `base_fuel` after Thruster Overdrive fuel cuts.
func engine_fuel(base_fuel: int) -> int:
	if base_fuel <= 0:
		return base_fuel
	var disc: float = Transit.engine_fuel_discount(engine_tier())
	var burn: float = float(base_fuel) * (1.0 - disc) if disc > 0.0 else float(base_fuel)
	return maxi(1, Transit.py_round(burn))


## Piracy raid odds multiplier in bps (10000 = x1.0) from Decoy Transponders.
func piracy_odds_bps() -> int:
	return _tier_int(_raw_entry(ID_TRANSPONDERS), "piracy_odds_bps", tier(ID_TRANSPONDERS), BPS)


## Python agora/upgrades.py UpgradeDesk.factor() parity helper.
func factor(kind: String) -> float:
	var k: String = kind.strip_edges().to_lower()
	if k == "shielding":
		var d_bps: int = delay_odds_bps()
		return 1.0 if d_bps == BPS else float(d_bps) / float(BPS)
	if k == "engines":
		return 1.0
	var canon: String = canonical_id(k)
	match canon:
		ID_BULKHEADS:
			var h_bps: int = hazard_odds_bps()
			return 1.0 if h_bps == BPS else float(h_bps) / float(BPS)
		ID_TRANSPONDERS:
			var p_bps: int = piracy_odds_bps()
			return 1.0 if p_bps == BPS else float(p_bps) / float(BPS)
		ID_THRUSTERS:
			var t_bps: int = transit_ticks_bps()
			return 1.0 if t_bps == BPS else float(t_bps) / float(BPS)
		_:
			return 1.0


## Cumulative CR spent across all fitted upgrade tiers for the active corporation.
func total_spent() -> int:
	var spent: int = 0
	for canon in ids():
		var t: int = tier(canon)
		for i in range(1, t + 1):
			spent += price_for_tier(canon, i)
	return spent


## Capitalized asset book value in CR (50% of total_spent() at default capital_bps = 5000).
func book_value() -> int:
	return total_spent() * capital_bps() / BPS


func can_buy(
	kind: String,
	current_round: int,
	available_cr: int,
	is_docked: bool = true,
	run_over: bool = false
) -> Dictionary:
	return can_buy_for(tiers, kind, current_round, available_cr, is_docked, run_over)


## Fits the next tier of `kind` at `current_round`, returning {id, tier, price, cargo_delta}.
## Returns {} and mutates nothing if `kind` is unknown or already at max tier.
func record_purchase(kind: String, current_round: int = 0) -> Dictionary:
	var canon: String = canonical_id(kind)
	var max_t: int = max_tier(canon)
	if canon == "" or max_t <= 0:
		return {}
	var cur_t: int = tier(canon)
	if cur_t >= max_t:
		return {}
	var old_cargo: int = cargo_bonus()
	var next_t: int = cur_t + 1
	var price: int = price_for_tier(canon, next_t)
	tiers[canon] = next_t
	purchased_rounds[canon] = clampi(current_round, 0, MAX_LOADED_ROUND)
	var new_cargo: int = cargo_bonus()
	return {
		"id": canon,
		"tier": next_t,
		"price": price,
		"cargo_delta": new_cargo - old_cargo,
	}


## Forfeits all fitted upgrades when a Chapter 11 bankruptcy founds a new corporation.
func reset_for_new_corp() -> void:
	tiers.clear()
	purchased_rounds.clear()


func to_dict() -> Dictionary:
	var tiers_copy: Dictionary = {}
	var rounds_copy: Dictionary = {}
	for canon in ids():
		var t: int = tier(canon)
		if t > 0:
			tiers_copy[canon] = t
			rounds_copy[canon] = clampi(int(purchased_rounds.get(canon, 0)), 0, MAX_LOADED_ROUND)
	return {
		"tiers": tiers_copy,
		"purchased_rounds": rounds_copy,
	}


static func from_dict(raw) -> Upgrades:
	var inst := Upgrades.new()
	if not (raw is Dictionary):
		return inst
	var d: Dictionary = raw
	var raw_tiers = d.get("tiers", d)
	var raw_rounds = d.get("purchased_rounds", {})
	if not (raw_tiers is Dictionary):
		return inst
	var tier_keys: Array = (raw_tiers as Dictionary).keys()
	tier_keys.sort_custom(func(a, b): return str(a) < str(b))
	for k in tier_keys:
		if not (k is String):
			continue
		var canon: String = canonical_id(str(k))
		if canon == "":
			continue
		var v = (raw_tiers as Dictionary)[k]
		if not (v is int or v is float):
			continue
		var clamped_t: int = clampi(int(v), 0, max_tier(canon))
		if clamped_t <= 0:
			continue
		# Keep the highest valid tier if both an alias and canonical key appear in tampered input.
		if clamped_t > int(inst.tiers.get(canon, 0)):
			inst.tiers[canon] = clamped_t
	if raw_rounds is Dictionary:
		for k in (raw_rounds as Dictionary):
			if not (k is String):
				continue
			var canon_r: String = canonical_id(str(k))
			if canon_r == "" or not inst.tiers.has(canon_r):
				continue
			var rv = (raw_rounds as Dictionary)[k]
			if rv is int or rv is float:
				inst.purchased_rounds[canon_r] = clampi(int(rv), 0, MAX_LOADED_ROUND)
	for canon in inst.tiers.keys():
		if not inst.purchased_rounds.has(canon):
			inst.purchased_rounds[canon] = 0
	return inst
