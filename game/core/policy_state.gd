class_name PolicyState
extends RefCounted
## The run-only corporate policies a run has been granted and adopted (#160 section 6, part of
## Corporate policies). Held as RunController.policies; null when not attached, exactly like
## `world` and `rescue`, so a run that never attaches one grants nothing and hashes as before.
##
## A grant is a counter (`earned += 1`), never a draw: nothing here depends on the run seed.
## Four sources: the rounds in policies.json `milestones` (20, 50, 80), and the first baron
## takeover (`takeover_pick`). A Chapter 11 filing grants nothing and rescinds everything
## (section 7): see reset_for_new_corp().
##
## The tree is the policies.json `Parachutes` instance, so requires / excludes / enabled are the
## data's, not re-stated here. Picks are mandatory (no decline), and offers() lists every node
## the player can take now, in file order.

## Owned policy ids, in pick order.
var picks: Array[String] = []
## Picks granted so far (this corp).
var earned: int = 0
## How many `milestones` have fired. Survives a filing: milestones ride the run clock.
var milestones_done: int = 0
## The one takeover pick is spent (this corp).
var takeover_granted: bool = false

var _tree: Parachutes = null


func _init(p_tree: Parachutes = null) -> void:
	_tree = p_tree if p_tree != null else Parachutes.load_policies()


func tree() -> Parachutes:
	return _tree


## Picks granted and not yet adopted.
func pending() -> int:
	return maxi(0, earned - picks.size())


## True once anything has ever been granted. RunSave writes the `policies` key from then on,
## and not before, so a run that never reached its first grant hashes as it did without
## policies. (`earned` alone is not enough: a filing zeroes it but keeps milestones_done, and
## a reload that forgot the milestones would grant them again.)
func has_granted() -> bool:
	return earned > 0 or milestones_done > 0 or takeover_granted


## Fires every milestone at or before `round_num` that has not fired. Returns how many picks it
## granted (0 mostly). Catches up if several are due at once.
func on_round(round_num: int) -> int:
	var granted := 0
	var ms: Array[int] = _tree.milestones
	while milestones_done < ms.size() and round_num >= ms[milestones_done]:
		milestones_done += 1
		earned += 1
		granted += 1
	return granted


## The player took a baron. Grants the one takeover pick per corp; false when it is spent or the
## data switches it off.
func on_takeover() -> bool:
	if not _tree.takeover_pick or takeover_granted:
		return false
	takeover_granted = true
	earned += 1
	return true


## Every node the player can take now, in the tree's file order: not owned, enabled, every
## `requires` owned, at least one `requires_any` owned (when it has any), and nothing owned
## excludes it or is excluded by it.
func offers() -> Array[String]:
	var out: Array[String] = []
	for id in _tree.perks:
		if _can_take(str(id), picks):
			out.append(str(id))
	return out


## True when `id` is not owned, is enabled, and an owned policy forecloses it (either side lists
## the other in `excludes`). The pick modal shows these as unavailable rather than hiding them.
func excluded_by_owned(id: String) -> bool:
	if picks.has(id) or not _tree.perks.has(id) or not bool(_tree.perks[id]["enabled"]):
		return false
	for owned in picks:
		if (_tree.perks[id]["excludes"] as Array).has(owned):
			return true
		if _tree.perks.has(owned) and (_tree.perks[owned]["excludes"] as Array).has(id):
			return true
	return false


## Adopt `id`: needs a pending grant and `id` in offers(). Picks are mandatory and final.
func pick(id: String) -> bool:
	if pending() <= 0 or not offers().has(id):
		return false
	picks.append(id)
	return true


## True when `id` has been adopted into picks.
func has_pick(id: String) -> bool:
	return picks.has(id)


func has_policy(id: String) -> bool:
	return picks.has(id)


## A filing rescinds every policy (section 7). Call after the filing is settled. The picks and
## the earned count go, the takeover pick is available to the new corp; milestones_done stays.
func reset_for_new_corp() -> void:
	picks = []
	earned = 0
	takeover_granted = false


func to_dict() -> Dictionary:
	return {
		"picks": picks.duplicate(),
		"earned": earned,
		"milestones_done": milestones_done,
		"takeover_granted": takeover_granted,
	}


## Trusts nothing (section 8): unknown or disabled ids and repeats are dropped, picks that break
## `requires` or `excludes` are dropped (the earlier pick of a forbidden pair wins), `earned` is
## clamped to the number of grants the data can make, and the picks to `earned`.
static func from_dict(d: Dictionary, p_tree: Parachutes = null) -> PolicyState:
	var s := PolicyState.new(p_tree)
	var t: Parachutes = s._tree
	var max_earned: int = t.milestones.size() + (1 if t.takeover_pick else 0)
	s.earned = clampi(_int_or(d.get("earned", 0)), 0, max_earned)
	s.milestones_done = clampi(_int_or(d.get("milestones_done", 0)), 0, t.milestones.size())
	var tg = d.get("takeover_granted", false)
	s.takeover_granted = (tg is bool and tg) and t.takeover_pick
	var raw = d.get("picks", [])
	var wanted: Array[String] = []
	if raw is Array:
		for v in raw:
			if v is String and t.perks.has(v) and not wanted.has(v):
				wanted.append(v)
	# Keep a pick once its prerequisites are held, retrying so the saved order cannot matter
	# (a capstone listed before its root is still legal). The first of an excluded pair wins.
	var kept: Array[String] = []
	var progress := true
	while progress:
		progress = false
		for id in wanted:
			if not kept.has(id) and s._can_take(id, kept):
				kept.append(id)
				progress = true
	s.picks = kept.slice(0, s.earned)
	return s


func _can_take(id: String, held: Array[String]) -> bool:
	if held.has(id) or not _tree.perks.has(id):
		return false
	var node: Dictionary = _tree.perks[id]
	if not bool(node["enabled"]):
		return false
	for r in node["requires"]:
		if not held.has(r):
			return false
	var any: Array = node["requires_any"]
	if not any.is_empty():
		var has_any := false
		for r in any:
			if held.has(r):
				has_any = true
				break
		if not has_any:
			return false
	for owned in held:
		if (node["excludes"] as Array).has(owned):
			return false
		if _tree.perks.has(owned) and (_tree.perks[owned]["excludes"] as Array).has(id):
			return false
	return true


static func _int_or(v) -> int:
	return int(v) if (v is int or v is float) else 0
