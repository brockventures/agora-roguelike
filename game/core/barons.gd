class_name Barons
extends RefCounted
## The sector barons: the world object Epic 3 hangs rivals on (docs/design/epic3-barons.md 3.1).
##
## This task (Epic 3 task 1, part of #15 Baron Framework design) is data, load,
## validate and save only. It holds the parsed res://data/barons.json and one
## BaronState per baron, and does nothing to any market yet.
##
## Like the crisis deck, the world is attached to a RunController (`world`) and
## saved under RunSave key `world` only when attached, so a run with no
## barons.json loaded hashes exactly as before. The data file is content and is
## not saved: a save carries the states, and from_dict() re-reads the file.

const DEFAULT_PATH: String = "res://data/barons.json"
const VERSION: int = 1
const ARCHETYPES: Array[String] = ["short_squeezer", "hoarder", "auctioneer"]
const LEAK_MODES: Array[String] = ["full", "delayed"]
## Required `params` keys per archetype and the kind each must be.
const PARAM_KINDS: Dictionary = {
	"short_squeezer": {
		"squeeze_window_rounds": "int", "squeeze_price_bps_max": "int", "squeeze_depth_bps": "int",
		"contract_every_rounds": "int", "contract_qty": "range", "contract_bid_bps": "int",
		"contract_penalty_bps": "int",
	},
	"hoarder": {
		"float_commodities": "commodities", "hoard_trigger_depth_bps": "int", "hoard_cap_qty": "int",
		"release_after_rounds": "int", "corner_premium_bps": "int",
	},
	"auctioneer": {
		"auction_every_rounds": "int", "rig_bps_max": "int", "indicative_leak": "leak",
	},
}

var data: Dictionary = {}
## BaronState by baron id.
var states: Dictionary = {}


func _init(p_data: Dictionary = {}) -> void:
	data = p_data if not p_data.is_empty() else Barons.load_data()
	for def in data.get("barons", []):
		var s: BaronState = BaronState.from_def(def)
		states[s.id] = s


## Parses the barons JSON; {} when missing or malformed.
static func load_data(path: String = DEFAULT_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("Barons: file not found: %s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("Barons: not a JSON object: %s" % path)
		return {}
	return parsed


## A world for a new run: the shipped barons.json, or null when it is missing or
## invalid (the run then plays as it always did, with no world attached).
static func for_new_run() -> Barons:
	if not Barons.validate(Barons.load_data()).is_empty():
		return null
	return Barons.new()


## Book mods the world emits this round (StationMarket.set_world_mods), in the
## fold order the market relies on: barons by sorted id, then rival fleets by
## sorted id. Today a baron emits its supply pipelines (Epic 3 task 3); archetype
## behaviours (tasks 4-6) and rivals (task 10) add to this.
func market_mods() -> Array:
	var out: Array = []
	for id in ids():
		out.append_array(_mods_of(id))
	return out


## One baron's mods, in its pipelines' file order. A pipeline is two ask-side
## effects on the anchor station's book for that commodity (design doc 3.3):
## `ask_depth_bps` more depth for everyone, and `ask_price_bps` of premium that
## only outsiders pay. The mods are the PLAYER's view of the book: the player is
## an insider only while they hold the baron, so taking it removes the premium
## and keeps the depth. (Rival fleets share the same books; their own insider
## prices arrive with Epic 3 task 10.)
func _mods_of(id: String) -> Array:
	var out: Array = []
	var d: Dictionary = def(id)
	if d.is_empty():
		return out
	var insider: bool = is_insider(StationMarket.PLAYER_ID, id)
	for pipe in d.get("privileges", {}).get("pipelines", []):
		out.append({
			"station": str(d.get("anchor", "")),
			"commodity": str(pipe.get("commodity", "")),
			"ask_depth_bps": int(pipe.get("depth_bps", 10000)),
			"ask_price_bps": 0 if insider else int(pipe.get("outsider_ask_bps", 0)),
		})
	return out


# --- Privileges (Epic 3 task 3, design doc 3.3) ---

## Participant ids a baron treats as insiders: its `toll_exempt` list plus
## whoever holds it ("player" after a takeover, a rival id later).
func insiders(id: String) -> Array:
	var out: Array = []
	for e in def(id).get("privileges", {}).get("toll_exempt", []):
		out.append(str(e))
	var s: BaronState = state(id)
	if s != null and s.holder != "" and not out.has(s.holder):
		out.append(s.holder)
	return out


func is_insider(participant: String, id: String) -> bool:
	return insiders(id).has(participant)


## The docking toll `participant` owes on arriving at `station`: the anchoring
## baron's `docking_toll_cr`, 0 for an insider or an unanchored station.
func docking_toll_due(participant: String, station: String) -> int:
	var id: String = baron_at(station)
	if id == "" or is_insider(participant, id):
		return 0
	return maxi(0, int(def(id).get("privileges", {}).get("docking_toll_cr", 0)))


## What is actually charged: the toll, capped at the CR the participant holds
## (agora/referee.py:2147 caps the same way).
func docking_toll(participant: String, station: String, cr_held: int) -> int:
	return mini(docking_toll_due(participant, station), maxi(0, cr_held))


## The pipeline on a (station, commodity) book as {baron, depth_bps,
## outsider_ask_bps}, {} when none. `viewer` sees base ask prices if an insider.
func pipeline(station: String, commodity: String) -> Dictionary:
	var id: String = baron_at(station)
	if id == "":
		return {}
	for pipe in def(id).get("privileges", {}).get("pipelines", []):
		if str(pipe.get("commodity", "")) == commodity.to_upper():
			return {"baron": id, "depth_bps": int(pipe.get("depth_bps", 0)), "outsider_ask_bps": int(pipe.get("outsider_ask_bps", 0))}
	return {}


## Baron ids in sorted order: the only order anything may iterate them in.
func ids() -> Array:
	var out: Array = states.keys()
	out.sort()
	return out


func state(id: String) -> BaronState:
	return states.get(id, null)


## The barons.json entry for an id, {} if unknown.
func def(id: String) -> Dictionary:
	for d in data.get("barons", []):
		if str(d.get("id", "")) == id:
			return d
	return {}


## The baron id anchored at a station, "" when none is.
func baron_at(station: String) -> String:
	for d in data.get("barons", []):
		if str(d.get("anchor", "")) == station.to_lower():
			return str(d.get("id", ""))
	return ""


func float_shares() -> int:
	return int(data.get("takeover", {}).get("float_shares", 0))


func threshold_shares() -> int:
	return int(data.get("takeover", {}).get("threshold_shares", 0))


# --- Save / load ---

func to_dict() -> Dictionary:
	var out: Dictionary = {}
	for id in ids():
		out[id] = (states[id] as BaronState).to_dict()
	return {"version": VERSION, "barons": out}


## Rebuilds the world from to_dict() output (directly or via JSON). The data
## file is re-read; a saved baron the file no longer lists is dropped, and a
## listed baron the save lacks starts from its opening state.
static func from_dict(d: Dictionary, p_data: Dictionary = {}) -> Barons:
	var w := Barons.new(p_data)
	var saved = d.get("barons", {})
	if saved is Dictionary:
		for id in w.states.keys():
			if saved.has(id) and saved[id] is Dictionary:
				var s: BaronState = BaronState.from_dict(saved[id])
				s.id = str(id)
				w.states[id] = s
	return w


# --- Validation ---

## Every problem with a parsed barons.json, as readable lines; empty = valid.
## Pure: it reads the dictionary and Transit's tables only.
static func validate(d: Dictionary) -> Array:
	var errs: Array = []
	if d.is_empty():
		return ["empty or unreadable barons data"]
	if not _is_int(d.get("version", null)) or int(d["version"]) != VERSION:
		errs.append("version must be %d" % VERSION)
	var barons = d.get("barons", null)
	if not (barons is Array) or (barons as Array).is_empty():
		errs.append("barons must be a non-empty array")
		return errs
	var take = d.get("takeover", null)
	var float_shares: int = 0
	if not (take is Dictionary):
		errs.append("takeover must be an object")
	else:
		for k in ["float_shares", "threshold_shares", "auction_cap", "auction_discount_bps", "bankrupt_rounds"]:
			if not _is_int(take.get(k, null)) or int(take[k]) <= 0:
				errs.append("takeover.%s must be a positive whole number" % k)
		if _is_int(take.get("float_shares", null)):
			float_shares = int(take.get("float_shares", 0))
		if _is_int(take.get("threshold_shares", null)) and float_shares > 0:
			var t: int = int(take["threshold_shares"])
			if t * 2 <= float_shares or t > float_shares:
				errs.append("takeover.threshold_shares must be a strict majority of float_shares")
		if _is_int(take.get("auction_discount_bps", null)) and int(take["auction_discount_bps"]) > 10000:
			errs.append("takeover.auction_discount_bps must be at most 10000")
	var heat = d.get("heat", null)
	if not (heat is Dictionary):
		errs.append("heat must be an object")
	else:
		if not _is_int(heat.get("decay_per_round", null)) or int(heat["decay_per_round"]) < 0:
			errs.append("heat.decay_per_round must be a whole number >= 0")
		if not _is_int(heat.get("retaliation_at", null)) or int(heat["retaliation_at"]) <= 0:
			errs.append("heat.retaliation_at must be a positive whole number")
	var vic = d.get("victory", null)
	if not (vic is Dictionary):
		errs.append("victory must be an object")
	else:
		var req = vic.get("barons_required", null)
		var ok: bool = (req is String and req == "all") or (_is_int(req) and int(req) >= 1 and int(req) <= (barons as Array).size())
		if not ok:
			errs.append("victory.barons_required must be \"all\" or 1..%d" % (barons as Array).size())
	var seen_ids: Dictionary = {}
	var seen_anchors: Dictionary = {}
	for i in (barons as Array).size():
		var b = barons[i]
		var where: String = "barons[%d]" % i
		if not (b is Dictionary):
			errs.append("%s must be an object" % where)
			continue
		var id: String = str(b.get("id", ""))
		if id.is_empty() or not _is_id(id):
			errs.append("%s.id must be lowercase letters, digits and underscores" % where)
		else:
			where = "baron %s" % id
			if seen_ids.has(id):
				errs.append("%s: duplicate id" % where)
			seen_ids[id] = true
		if str(b.get("name", "")).is_empty():
			errs.append("%s: name is required" % where)
		var arch: String = str(b.get("archetype", ""))
		if not ARCHETYPES.has(arch):
			errs.append("%s: archetype must be one of %s" % [where, ", ".join(ARCHETYPES)])
		var anchor: String = str(b.get("anchor", ""))
		if not Transit.STATIONS.has(anchor):
			errs.append("%s: anchor '%s' is not a station" % [where, anchor])
		elif seen_anchors.has(anchor):
			errs.append("%s: anchor '%s' is already taken by %s" % [where, anchor, seen_anchors[anchor]])
		else:
			seen_anchors[anchor] = id
		for k in ["treasury_cr", "treasury_shares", "upkeep_cr_per_round", "margin_debt_cr"]:
			if not _is_int(b.get(k, null)) or int(b[k]) < 0:
				errs.append("%s: %s must be a whole number >= 0" % [where, k])
		if _is_int(b.get("treasury_shares", null)) and float_shares > 0 and int(b["treasury_shares"]) > float_shares:
			errs.append("%s: treasury_shares exceeds the float" % where)
		_check_commodity_map(b.get("inventory", null), "%s: inventory" % where, errs)
		_check_privileges(b.get("privileges", null), where, errs)
		_check_params(b.get("params", null), arch, where, errs)
	return errs


static func _check_commodity_map(v: Variant, label: String, errs: Array) -> void:
	if not (v is Dictionary):
		errs.append("%s must be an object" % label)
		return
	for k in v:
		if not Transit.COMMODITIES.has(str(k)):
			errs.append("%s: unknown commodity '%s'" % [label, str(k)])
		if not _is_int(v[k]) or int(v[k]) < 0:
			errs.append("%s.%s must be a whole number >= 0" % [label, str(k)])


static func _check_privileges(p: Variant, where: String, errs: Array) -> void:
	if not (p is Dictionary):
		errs.append("%s: privileges must be an object" % where)
		return
	if not _is_int(p.get("docking_toll_cr", null)) or int(p["docking_toll_cr"]) < 0:
		errs.append("%s: privileges.docking_toll_cr must be a whole number >= 0" % where)
	var ex = p.get("toll_exempt", null)
	if not (ex is Array):
		errs.append("%s: privileges.toll_exempt must be an array" % where)
	else:
		for e in ex:
			if not (e is String) or (e as String).is_empty():
				errs.append("%s: privileges.toll_exempt holds only participant ids" % where)
				break
	var pipes = p.get("pipelines", null)
	if not (pipes is Array):
		errs.append("%s: privileges.pipelines must be an array" % where)
		return
	var seen: Dictionary = {}
	for pipe in pipes:
		if not (pipe is Dictionary):
			errs.append("%s: each pipeline must be an object" % where)
			continue
		var c: String = str(pipe.get("commodity", ""))
		if not Transit.COMMODITIES.has(c):
			errs.append("%s: pipeline commodity '%s' is unknown" % [where, c])
		elif seen.has(c):
			errs.append("%s: pipeline for %s listed twice" % [where, c])
		seen[c] = true
		if not _is_int(pipe.get("depth_bps", null)) or int(pipe["depth_bps"]) <= 0:
			errs.append("%s: pipeline %s depth_bps must be a positive whole number" % [where, c])
		if not _is_int(pipe.get("outsider_ask_bps", null)) or int(pipe["outsider_ask_bps"]) < 0:
			errs.append("%s: pipeline %s outsider_ask_bps must be a whole number >= 0" % [where, c])


static func _check_params(p: Variant, arch: String, where: String, errs: Array) -> void:
	if not (p is Dictionary):
		errs.append("%s: params must be an object" % where)
		return
	var kinds: Dictionary = PARAM_KINDS.get(arch, {})
	for k in kinds:
		if not p.has(k):
			errs.append("%s: params.%s is required for %s" % [where, k, arch])
			continue
		var v = p[k]
		var ok: bool = true
		match str(kinds[k]):
			"int":
				ok = _is_int(v) and int(v) >= 0
			"range":
				ok = v is Array and (v as Array).size() == 2 and _is_int(v[0]) and _is_int(v[1]) and int(v[0]) >= 1 and int(v[0]) <= int(v[1])
			"commodities":
				ok = v is Array and not (v as Array).is_empty()
				if ok:
					for c in v:
						if not Transit.COMMODITIES.has(str(c)):
							ok = false
			"leak":
				ok = v is String and LEAK_MODES.has(v)
		if not ok:
			errs.append("%s: params.%s is invalid" % [where, k])


## JSON numbers arrive as floats: a whole-valued float counts as an int.
static func _is_int(v: Variant) -> bool:
	if typeof(v) == TYPE_INT:
		return true
	return typeof(v) == TYPE_FLOAT and is_finite(v) and v == floorf(v)


static func _is_id(s: String) -> bool:
	for i in s.length():
		var c: String = s[i]
		if not ((c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_"):
			return false
	return true
