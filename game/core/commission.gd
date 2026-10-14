class_name Commission
extends RefCounted
## The Commission cycle (#149, PR 1a): Skeletons earned by Rescue wins, and the
## commissioners a player retains with them. Data lives in data/commission.json.
## Pure functions over a MetaProfile; no favours, UI or localisation yet.

const DEFAULT_PATH := "res://data/commission.json"
const CHAIR := "chair"

static var _data: Dictionary = {}
static var _loaded: bool = false

static func _fallback() -> Dictionary:
	return {
		"skeletons_per_rescue": 1,
		"commissioners": [
			{"id": "enforcement", "cost": 1, "unstable_ratio_bps": 7000},
			{"id": "customs", "cost": 1},
			{"id": "treasury", "cost": 1},
			{"id": "press", "cost": 1},
			{"id": "chair", "cost": 1},
		],
	}

static func _load() -> Dictionary:
	if _loaded:
		return _data
	_loaded = true
	var parsed = null
	if FileAccess.file_exists(DEFAULT_PATH):
		parsed = JSON.parse_string(FileAccess.get_file_as_string(DEFAULT_PATH))
	var ok: bool = parsed is Dictionary and parsed.get("commissioners") is Array and not (parsed.get("commissioners") as Array).is_empty()
	_data = parsed if ok else _fallback()
	return _data

static func _entries() -> Array:
	return _load().get("commissioners", [])

static func ids() -> Array[String]:
	var out: Array[String] = []
	for e in _entries():
		if e is Dictionary and e.get("id") is String:
			out.append(e["id"])
	return out

static func cost(id: String) -> int:
	for e in _entries():
		if e is Dictionary and e.get("id") == id:
			return int(e.get("cost", 0))
	return 0

static func has_favour(profile: MetaProfile, id: String) -> bool:
	return profile != null and id != CHAIR and ids().has(id) and profile.consultants.has(id)

static func param(id: String, key: String, default_value: int) -> int:
	for e in _entries():
		if e is Dictionary and e.get("id") == id:
			return int(e.get(key, default_value))
	return default_value

static func skeletons_per_rescue() -> int:
	return int(_load().get("skeletons_per_rescue", 1))

static func can_retain(profile: MetaProfile, id: String) -> Dictionary:
	if not ids().has(id):
		return {"ok": false, "reason": "UNKNOWN_COMMISSIONER"}
	if profile.consultants.has(id):
		return {"ok": false, "reason": "ALREADY_RETAINED"}
	if id == CHAIR:
		for other in ids():
			if other != CHAIR and not profile.consultants.has(other):
				return {"ok": false, "reason": "CHAIR_LAST"}
	if profile.skeletons < cost(id):
		return {"ok": false, "reason": "INSUFFICIENT_SKELETONS"}
	return {"ok": true, "reason": ""}

static func retain(profile: MetaProfile, id: String) -> Dictionary:
	var res: Dictionary = can_retain(profile, id)
	if res["ok"]:
		profile.skeletons -= cost(id)
		profile.consultants.append(id)
	return res

static func capture_pct(profile: MetaProfile) -> int:
	var all: Array[String] = ids()
	var n: int = 0
	for c in profile.consultants:
		if all.has(c):
			n += 1
	return n * 100 / all.size()

static func dissolution_fails(profile: MetaProfile) -> bool:
	for id in ids():
		if not profile.consultants.has(id):
			return false
	return true
