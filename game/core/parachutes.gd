class_name Parachutes
extends RefCounted
## Golden Parachutes: data-driven meta-progression perk tree (#11, PR 1).
##
## No perk content lives in code. The tree is game/data/parachutes.json; every
## perk there is placeholder content for Ryan to rename or replace. This class
## loads and validates the tree, checks purchase eligibility, buys perks into
## MetaProfile.unlocks, and folds owned perks into one modifiers dictionary.
##
## Perk shape: {id, name, tier, cost, requires: [ids], requires_any: [ids],
## enabled, effects: [{stat, op, value}]}. requires is AND (all owned);
## requires_any is OR (at least one owned, when non-empty). enabled:false perks
## (default true) validate but cannot be bought and add no modifiers.
## Ops (integer math only):
##   add      value is added to the stat's base
##   mul_bps  value is a basis-point multiplier, 10000 = x1.0
## All values must be integers.
##
## Modifiers dict (from modifiers()): stat -> {"add": int, "mul_bps": int}, only
## for stats some owned perk touches. Resolve a base with apply_stat():
##   result = (base + add) * mul_bps / 10000   (integer division)
## Perks fold in sorted-id order, so the result never depends on purchase order.
##
## Stats and who consumes them (STATS below), all LIVE as of #11 PR 2:
##   starting_cr, fresh_start_cr, interest_bps, burn_rate, liquidation_haircut_bps:
##     applied by RunController.
##   fuel_discount_bps: Transit.calculate_fuel_burn(..., fuel_discount_bps), read
##     via RunController.fuel_discount_bps() (0..10000).
##   hazard_odds_bps: Hazards.quote/roll(..., odds_bps), via
##     RunController.hazard_odds_bps() (base 10000 = x1.0).
##   bankruptcy_grace_ticks: RunController waits this many sim ticks of continued
##     insolvency before automatic Chapter 11 filing (base 0).
##   piracy_odds_bps: Piracy.chance/roll_departure(..., odds_bps), via
##     RunController.piracy_odds_bps() (base 10000 = x1.0).
##   takeover_threshold_shares: Takeover.threshold_for cuts the shares the player needs
##     to take a baron (base 501); its presence also unlocks tender offers
##     (Takeover.tender_unlocked), via RunController.modifiers (Hostile Buyout Line, -50).
## RunController derives modifiers from the profile's owned perks when none are
## passed, and banks Severance at run end (RunController.end_run).

const DEFAULT_PATH := "res://data/parachutes.json"
const OPS: Array[String] = ["add", "mul_bps"]
const BPS: int = 10000

## stat -> "live" (has a consumer) | "pending" (stored, no consumer yet)
const STATS: Dictionary = {
	"starting_cr": "live",
	"fresh_start_cr": "live",
	"interest_bps": "live",
	"burn_rate": "live",
	"liquidation_haircut_bps": "live",   # the share of asset value KEPT in liquidation (50% base)
	"fuel_discount_bps": "live",
	"hazard_odds_bps": "live",
	"piracy_odds_bps": "live",
	"bankruptcy_grace_ticks": "live",
	"takeover_threshold_shares": "live",  # Epic 3 task 8: Takeover.threshold_for (the player's 501 less the perk)
}

## Severance formula, placeholder constants (Ryan may overrule).
## points = filings * SEVERANCE_PER_FILING + peak_net_worth * SEVERANCE_NET_WORTH_BPS / 10000
const SEVERANCE_PER_FILING: int = 100
const SEVERANCE_NET_WORTH_BPS: int = 50   # 0.5% of peak net worth

var perks: Dictionary = {}          # id -> perk Dictionary (first occurrence wins)
var _duplicate_ids: Array[String] = []
var _load_errors: Array[String] = []

static func load(path: String = DEFAULT_PATH) -> Parachutes:
	var tree := Parachutes.new()
	if not FileAccess.file_exists(path):
		tree._load_errors.append("file not found: %s" % path)
		return tree
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		tree._load_errors.append("not a JSON object: %s" % path)
		return tree
	return load_from_dict(parsed)

static func load_from_dict(d: Dictionary) -> Parachutes:
	var tree := Parachutes.new()
	var raw = d.get("perks", [])
	if not (raw is Array):
		tree._load_errors.append("perks is not an array")
		return tree
	for item in raw:
		if not (item is Dictionary):
			tree._load_errors.append("perk entry is not an object")
			continue
		var perk := _normalise(item)
		var id: String = perk["id"]
		if id.is_empty():
			tree._load_errors.append("perk with missing or non-string id")
			continue
		if tree.perks.has(id):
			if not tree._duplicate_ids.has(id):
				tree._duplicate_ids.append(id)
			continue
		tree.perks[id] = perk
	return tree

## JSON numbers parse as floats; integral floats become ints. Anything else
## non-integer is left as-is so validate() can report it.
static func _int_or_self(v):
	if v is float and v == floor(v) and absf(v) < 9.0e15:
		return int(v)
	return v

static func _normalise(src: Dictionary) -> Dictionary:
	var effects: Array = []
	var raw_fx = src.get("effects", [])
	if raw_fx is Array:
		for e in raw_fx:
			if e is Dictionary:
				effects.append({"stat": e.get("stat"), "op": e.get("op"), "value": _int_or_self(e.get("value"))})
			else:
				effects.append({"stat": null, "op": null, "value": null})
	var req: Array = []
	var raw_req = src.get("requires", [])
	if raw_req is Array:
		req = raw_req.duplicate()
	var req_any: Array = []
	var raw_any = src.get("requires_any", [])
	if raw_any is Array:
		req_any = raw_any.duplicate()
	var id = src.get("id", "")
	return {
		"id": id if id is String else "",
		"name": str(src.get("name", "")),
		"branch": str(src.get("branch", "")),
		"tier": _int_or_self(src.get("tier", 1)),
		"cost": _int_or_self(src.get("cost", 0)),
		"requires": req,
		"requires_any": req_any,
		"enabled": bool(src.get("enabled", true)),
		"effects": effects,
		"placeholder": bool(src.get("placeholder", false)),
	}

## All structural problems, empty when the tree is sound.
func validate() -> Array[String]:
	var errors: Array[String] = []
	errors.append_array(_load_errors)
	for id in _duplicate_ids:
		errors.append("duplicate id: %s" % id)
	var ids: Array = perks.keys()
	ids.sort()
	for id in ids:
		var perk: Dictionary = perks[id]
		var cost = perk["cost"]
		if not (cost is int):
			errors.append("%s: cost is not an integer" % id)
		elif cost < 0:
			errors.append("%s: negative cost" % id)
		if not (perk["tier"] is int):
			errors.append("%s: tier is not an integer" % id)
		for r in perk["requires"]:
			if not (r is String) or not perks.has(r):
				errors.append("%s: unknown requires id %s" % [id, str(r)])
		for r in perk["requires_any"]:
			if not (r is String) or not perks.has(r):
				errors.append("%s: unknown requires_any id %s" % [id, str(r)])
		for e in perk["effects"]:
			var stat = e["stat"]
			var op = e["op"]
			if not (stat is String) or not STATS.has(stat):
				errors.append("%s: unknown stat %s" % [id, str(stat)])
			if not (op is String) or not OPS.has(op):
				errors.append("%s: unknown op %s" % [id, str(op)])
			elif not (e["value"] is int):
				errors.append("%s: effect value for %s is not an integer" % [id, str(stat)])
			elif op == "mul_bps" and e["value"] < 0:
				errors.append("%s: negative mul_bps for %s" % [id, str(stat)])
	var cycle := _find_cycle(ids)
	if not cycle.is_empty():
		errors.append("requires cycle: %s" % " -> ".join(cycle))
	return errors

## First dependency cycle found (as a path of ids), or [] when acyclic.
func _find_cycle(sorted_ids: Array) -> Array:
	var state := {}   # id -> 1 visiting, 2 done
	for start in sorted_ids:
		var found := _dfs(start, state, [])
		if not found.is_empty():
			return found
	return []

func _dfs(id: String, state: Dictionary, path: Array) -> Array:
	var s: int = state.get(id, 0)
	if s == 2:
		return []
	if s == 1:
		var i := path.find(id)
		var cyc: Array = path.slice(i)
		cyc.append(id)
		return cyc
	state[id] = 1
	path.append(id)
	var reqs: Array = []
	for r in perks[id]["requires"] + perks[id]["requires_any"]:
		if r is String and perks.has(r):
			reqs.append(r)
	reqs.sort()
	for r in reqs:
		var found := _dfs(r, state, path)
		if not found.is_empty():
			return found
	path.pop_back()
	state[id] = 2
	return []

func has_perk(id: String) -> bool:
	return perks.has(id)

## {"ok": bool, "reasons": Array[String]}. Reasons are stable codes with detail:
## unknown_perk, already_owned, missing_requires:<ids>, insufficient_points.
func can_buy(profile: MetaProfile, id: String) -> Dictionary:
	var reasons: Array[String] = []
	if not perks.has(id):
		reasons.append("unknown_perk")
		return {"ok": false, "reasons": reasons}
	var perk: Dictionary = perks[id]
	if not bool(perk["enabled"]):
		reasons.append("disabled")
	if profile.has_unlock(id):
		reasons.append("already_owned")
	var missing: Array[String] = []
	for r in perk["requires"]:
		if not profile.has_unlock(str(r)):
			missing.append(str(r))
	if not missing.is_empty():
		missing.sort()
		reasons.append("missing_requires:%s" % ",".join(missing))
	var any: Array = perk["requires_any"]
	if not any.is_empty():
		var has_any := false
		for r in any:
			if profile.has_unlock(str(r)):
				has_any = true
		if not has_any:
			var names: Array[String] = []
			for r in any:
				names.append(str(r))
			names.sort()
			reasons.append("missing_requires_any:%s" % ",".join(names))
	if profile.severance_points < int(perk["cost"]):
		reasons.append("insufficient_points")
	return {"ok": reasons.is_empty(), "reasons": reasons}

## Deducts severance points and adds the perk to profile.unlocks. Rejected
## purchases change nothing. Returns the can_buy() shape.
func buy(profile: MetaProfile, id: String) -> Dictionary:
	var check := can_buy(profile, id)
	if not bool(check["ok"]):
		return check
	profile.severance_points -= int(perks[id]["cost"])
	profile.add_unlock(id)
	return check

## Fold owned perks into one modifiers dictionary (see header). Unknown ids in
## profile.unlocks (e.g. non-parachute unlocks) are ignored. Perks with invalid
## effects are skipped, so a broken tree never crashes a run.
func modifiers(profile: MetaProfile) -> Dictionary:
	var out := {}
	var owned: Array = []
	for id in profile.unlocks:
		if perks.has(id) and bool(perks[id]["enabled"]):
			owned.append(id)
	owned.sort()
	for id in owned:
		for e in perks[id]["effects"]:
			var stat = e["stat"]
			var op = e["op"]
			var v = e["value"]
			if not (stat is String) or not STATS.has(stat) or not (v is int):
				continue
			if not out.has(stat):
				out[stat] = {"add": 0, "mul_bps": BPS}
			if op == "add":
				out[stat]["add"] += v
			elif op == "mul_bps" and v >= 0:
				out[stat]["mul_bps"] = out[stat]["mul_bps"] * v / BPS
	return out

## Resolve a base value through a modifiers dict. Missing stat returns base.
static func apply_stat(mods: Dictionary, stat: String, base: int) -> int:
	var m = mods.get(stat)
	if not (m is Dictionary):
		return base
	return (base + int(m.get("add", 0))) * int(m.get("mul_bps", BPS)) / BPS

## Bank Severance points for a finished run into the profile; returns the award.
## Negative inputs count as zero.
static func award_severance(profile: MetaProfile, filings: int, peak_net_worth: int) -> int:
	var award: int = maxi(0, filings) * SEVERANCE_PER_FILING + maxi(0, peak_net_worth) * SEVERANCE_NET_WORTH_BPS / BPS
	profile.severance_points += award
	return award
