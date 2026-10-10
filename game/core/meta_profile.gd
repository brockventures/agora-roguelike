class_name MetaProfile
extends RefCounted
## Everything that survives a Chapter 11 bankruptcy (#10).
##
## Pure data, no engine state. Patents, unlocks and contracts are opaque string
## ids; #11 (Golden Parachutes) will add to this later. Serialisation is
## defensive: from_dict() accepts arbitrary save data and always yields a valid
## profile (non-arrays become empty, non-strings dropped, duplicates removed,
## negative counts clamped to 0).

var patents: Array[String] = []
var unlocks: Array[String] = []
var contracts: Array[String] = []
var bankruptcies_filed: int = 0
## Golden Parachutes currency (#11), banked when a run ends, spent on perks.
var severance_points: int = 0
## Barons broken (held by a corp when it ended), summed over every corp (Epic 3 task 9).
## Saved only when non-zero, so a profile that never broke one hashes as it always did.
var barons_broken: int = 0
## Runs (corps) finished under this profile, bumped when a corp ends.
var runs_completed: int = 0

func add_patent(id: String) -> bool:
	return _add(patents, id)

func has_patent(id: String) -> bool:
	return patents.has(id)

func add_unlock(id: String) -> bool:
	return _add(unlocks, id)

func has_unlock(id: String) -> bool:
	return unlocks.has(id)

func add_contract(id: String) -> bool:
	return _add(contracts, id)

func has_contract(id: String) -> bool:
	return contracts.has(id)

## Appends id unless empty or already present. Returns true if it was added.
func _add(list: Array[String], id: String) -> bool:
	if id.is_empty() or list.has(id):
		return false
	list.append(id)
	return true

func to_dict() -> Dictionary:
	var out: Dictionary = {
		"patents": patents.duplicate(),
		"unlocks": unlocks.duplicate(),
		"contracts": contracts.duplicate(),
		"bankruptcies_filed": bankruptcies_filed,
		"severance_points": severance_points,
		"runs_completed": runs_completed,
	}
	if barons_broken > 0:
		out["barons_broken"] = barons_broken
	return out

static func from_dict(d: Dictionary) -> MetaProfile:
	var p := MetaProfile.new()
	p.patents = _sanitise_ids(d.get("patents", []))
	p.unlocks = _sanitise_ids(d.get("unlocks", []))
	p.contracts = _sanitise_ids(d.get("contracts", []))
	var raw = d.get("bankruptcies_filed", 0)
	p.bankruptcies_filed = maxi(0, int(raw)) if (raw is int or raw is float) else 0
	var sp = d.get("severance_points", 0)
	p.severance_points = maxi(0, int(sp)) if (sp is int or sp is float) else 0
	var rc = d.get("runs_completed", 0)
	p.runs_completed = maxi(0, int(rc)) if (rc is int or rc is float) else 0
	var bb = d.get("barons_broken", 0)
	p.barons_broken = maxi(0, int(bb)) if (bb is int or bb is float) else 0
	return p

static func _sanitise_ids(raw) -> Array[String]:
	var out: Array[String] = []
	if not (raw is Array):
		return out
	for item in raw:
		if item is String and not item.is_empty() and not out.has(item):
			out.append(item)
	return out
