class_name RescueProject
extends RefCounted
## The Sol System Rescue Project (#32, docs/design/rescue-project.md): four phases, each at a
## named station, each needing a bill of commodities from the hold plus a CR fee.
##
## This is the core only (task 1): the data, the phase state machine, deposits, saves and the
## stabiliser-field tick count. The clock gate, win, UI and loop wiring are tasks 2 to 4.
##
## Rules (section 3.2 and 8):
##  - Phases run strictly in order; only the open phase accepts deliveries.
##  - A deposit moves min(held, still needed) of each needed commodity out of the hold and
##    charges the fee pro rata: the fee due for U units delivered of a phase's N total is
##    ceil(cr x U / N) CR, and a deposit pays the difference from what was already paid. That
##    is "rounded up, whole CR" per deposit without the rounding drifting over many deposits:
##    a finished phase has always cost exactly its `cr`.
##  - Refusals leave everything untouched: NOT_OPEN, WRONG_SITE, NO_CARGO, NO_CR, WOULD_BANKRUPT.
##  - Progress is monotonic: nothing here withdraws, decays or seizes a delivered unit.
##
## No RNG anywhere. All money and units are integers; every dictionary is walked in sorted
## key order. State is integers and strings only, so it round-trips through JSON and hashes
## stably; every read goes through int() because JSON numbers come back as floats.

const VERSION: int = 1
const DEFAULT_PATH: String = "res://data/rescue.json"
const FULL_SPEED_BPS: int = 10000

const R_NOT_OPEN: String = "NOT_OPEN"
const R_WRONG_SITE: String = "WRONG_SITE"
const R_NO_CARGO: String = "NO_CARGO"
const R_NO_CR: String = "NO_CR"
const R_WOULD_BANKRUPT: String = "WOULD_BANKRUPT"

var data: Dictionary = {}
## Index of the open phase; phases.size() when every phase is finished.
var phase: int = 0
## Units delivered to the open phase so far, {commodity: int}.
var deposits: Dictionary = {}
## CR paid toward the open phase's fee.
var fee_paid: int = 0
## Finished phases in order, [phase id, round finished].
var completed: Array = []
## Share of sim ticks that count against the doomsday clock (the Stabiliser Field).
var keep_bps: int = FULL_SPEED_BPS
var opened_round: int = 0


func _init(p_data: Dictionary = {}) -> void:
	data = p_data if not p_data.is_empty() else RescueProject.load_data()


## Parses rescue.json; {} when missing or malformed.
static func load_data(path: String = DEFAULT_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("RescueProject: file not found: %s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("RescueProject: not a JSON object: %s" % path)
		return {}
	return parsed


## A freshly opened project (phase 1 open) from the shipped data or `p_data`, or null when
## the data is missing or invalid.
static func open_new(round_num: int, p_data: Dictionary = {}) -> RescueProject:
	var d: Dictionary = p_data if not p_data.is_empty() else RescueProject.load_data()
	if not RescueProject.validate(d).is_empty():
		return null
	var p := RescueProject.new(d)
	p.opened_round = maxi(0, round_num)
	return p


# --- Reads ---

func phases() -> Array:
	var ph = data.get("phases", [])
	return ph if ph is Array else []


func phase_count() -> int:
	return phases().size()


## True while a phase is still open (not yet won).
func is_open() -> bool:
	return phase < phase_count()


func is_complete() -> bool:
	return phase >= phase_count()


func phases_done() -> int:
	return mini(phase, phase_count())


## The open phase's definition, {} once the project is complete.
func current() -> Dictionary:
	if not is_open():
		return {}
	var ph = phases()[phase]
	return ph if ph is Dictionary else {}


## Total units a phase needs.
static func phase_units(ph: Dictionary) -> int:
	var n: int = 0
	var needs = ph.get("needs", {})
	if needs is Dictionary:
		for c in needs:
			n += maxi(0, int(needs[c]))
	return n


## Units of each commodity still needed by the open phase, {commodity: int}, only non-zero.
func remaining() -> Dictionary:
	var out: Dictionary = {}
	var ph: Dictionary = current()
	var needs = ph.get("needs", {})
	if not (needs is Dictionary):
		return out
	var keys: Array = needs.keys()
	keys.sort()
	for c in keys:
		var left: int = int(needs[c]) - int(deposits.get(c, 0))
		if left > 0:
			out[c] = left
	return out


func units_delivered() -> int:
	var n: int = 0
	for c in deposits:
		n += int(deposits[c])
	return n


## The cumulative fee due once `units` of the open phase are in: ceil(cr x units / phase units).
func fee_for_units(units: int) -> int:
	var ph: Dictionary = current()
	var total: int = RescueProject.phase_units(ph)
	if total <= 0:
		return 0
	return (int(ph.get("cr", 0)) * maxi(0, units) + total - 1) / total


## CR still owed on the open phase.
func fee_left() -> int:
	return maxi(0, int(current().get("cr", 0)) - fee_paid)


## The Stabiliser Field (design 5.1): does absolute sim tick `total` count against the
## doomsday clock? A pure integer Bresenham count of `keep_bps`, no accumulator to save.
## 10000 counts every tick; 0 counts none.
func counts_tick(total: int) -> bool:
	return total * keep_bps / FULL_SPEED_BPS != (total - 1) * keep_bps / FULL_SPEED_BPS


# --- Win, loss and the rent bonus (task 2) ---

## Rent multiplier in bps while a phase is open (rent_multiplier_bps), 10000 once the project is
## done. Barons.rent_bonus_bps carries it; RunController.sync_rent_bonus decides when it applies.
func rent_bonus_bps() -> int:
	return maxi(FULL_SPEED_BPS, int(data.get("rent_multiplier_bps", FULL_SPEED_BPS))) if is_open() else FULL_SPEED_BPS


## Severance a won run adds: win.severance_base + win.severance_per_round_left x clock-rounds left.
func win_severance(clock_rounds_left: int) -> int:
	var win: Dictionary = data.get("win", {})
	return maxi(0, int(win.get("severance_base", 0))) + maxi(0, int(win.get("severance_per_round_left", 0))) * maxi(0, clock_rounds_left)


## Severance a lost run adds for what was built: win.phase_consolation per finished phase (Q3 b).
func consolation_severance() -> int:
	return maxi(0, int(data.get("win", {}).get("phase_consolation", 0))) * phases_done()


## Does the hold carry goods the open phase still wants (design 8, the raid rule)? Sorted keys,
## integer only. Always false once the project is complete.
func hold_carries_project_goods(rc: RunController) -> bool:
	for c in remaining():
		if int(rc.cargo.get(c, 0)) > 0:
			return true
	return false


# --- Deposit ---

## What a deposit from this hold at `site` would do, without doing it:
## {"ok", "reason", "units": {commodity: n}, "fee": cr}. Pure.
func preview(rc: RunController, site: String) -> Dictionary:
	if not is_open():
		return {"ok": false, "reason": R_NOT_OPEN, "units": {}, "fee": 0}
	var ph: Dictionary = current()
	if site != str(ph.get("site", "")):
		return {"ok": false, "reason": R_WRONG_SITE, "units": {}, "fee": 0}
	var units: Dictionary = {}
	var total: int = 0
	var need: Dictionary = remaining()
	var keys: Array = need.keys()
	keys.sort()
	for c in keys:
		var n: int = mini(int(need[c]), maxi(0, int(rc.cargo.get(c, 0))))
		if n > 0:
			units[c] = n
			total += n
	if total == 0:
		return {"ok": false, "reason": R_NO_CARGO, "units": {}, "fee": 0}
	var fee: int = maxi(0, fee_for_units(units_delivered() + total) - fee_paid)
	if fee > rc.cr:
		return {"ok": false, "reason": R_NO_CR, "units": units, "fee": fee}
	# The project must never push the player into Chapter 11 by itself.
	var snap: Dictionary = rc.snapshot()
	var cargo: Dictionary = snap["cargo"]
	for c in units:
		cargo[c] = int(cargo.get(c, 0)) - int(units[c])
		if int(cargo[c]) <= 0:
			cargo.erase(c)
	snap["cr"] = rc.cr - fee
	if bool(Chapter11.assess(snap, rc.haircut_bps())["insolvent"]) and not bool(rc.assess()["insolvent"]):
		return {"ok": false, "reason": R_WOULD_BANKRUPT, "units": units, "fee": fee}
	return {"ok": true, "reason": "", "units": units, "fee": fee}


## Delivers what the hold can give the open phase at `site` in round `round_num`.
## Returns the preview dictionary plus, on success, "phase_complete" (this deposit finished
## the phase), "phase_id" and "won" (it was the last phase). Nothing changes on a refusal.
func deposit(rc: RunController, site: String, round_num: int) -> Dictionary:
	var res: Dictionary = preview(rc, site)
	if not bool(res["ok"]):
		return res
	res["phase_id"] = str(current().get("id", ""))
	var units: Dictionary = res["units"]
	for c in units:
		rc.cargo[c] = int(rc.cargo.get(c, 0)) - int(units[c])
		if int(rc.cargo[c]) <= 0:
			rc.cargo.erase(c)
		deposits[c] = int(deposits.get(c, 0)) + int(units[c])
	rc.cr -= int(res["fee"])
	fee_paid += int(res["fee"])
	res["phase_complete"] = remaining().is_empty()
	res["won"] = false
	if bool(res["phase_complete"]):
		_finish_phase(round_num)
		res["won"] = is_complete()
	return res


func _finish_phase(round_num: int) -> void:
	var ph: Dictionary = current()
	completed.append([str(ph.get("id", "")), maxi(0, round_num)])
	keep_bps = clampi(int(ph.get("keep_bps", FULL_SPEED_BPS)), 0, FULL_SPEED_BPS)
	phase += 1
	deposits = {}
	fee_paid = 0


# --- Saves ---

func to_dict() -> Dictionary:
	var dep: Dictionary = {}
	var keys: Array = deposits.keys()
	keys.sort()
	for c in keys:
		dep[c] = int(deposits[c])
	return {
		"phase": phase,
		"deposits": dep,
		"fee_paid": fee_paid,
		"completed": completed.duplicate(true),
		"keep_bps": keep_bps,
		"opened_round": opened_round,
	}


## Defensive: arbitrary save data always yields a consistent project (the phase is clamped,
## only the open phase's needed commodities are kept, each capped at its need, the fee at the
## phase's cr). null when the shipped data is invalid.
static func from_dict(d: Dictionary, p_data: Dictionary = {}) -> RescueProject:
	var src: Dictionary = p_data if not p_data.is_empty() else RescueProject.load_data()
	if not RescueProject.validate(src).is_empty():
		return null
	var p := RescueProject.new(src)
	p.phase = clampi(_int_or(d.get("phase", 0)), 0, p.phase_count())
	p.opened_round = maxi(0, _int_or(d.get("opened_round", 0)))
	var raw_done = d.get("completed", [])
	if raw_done is Array:
		for e in raw_done:
			if e is Array and (e as Array).size() == 2 and e[0] is String:
				p.completed.append([str(e[0]), maxi(0, _int_or(e[1]))])
	var kb = d.get("keep_bps", null)
	p.keep_bps = clampi(_int_or(kb), 0, FULL_SPEED_BPS) if (kb is int or kb is float) else FULL_SPEED_BPS
	if p.is_open():
		var ph: Dictionary = p.current()
		var needs: Dictionary = ph.get("needs", {})
		var raw_dep = d.get("deposits", {})
		if raw_dep is Dictionary:
			var keys: Array = (raw_dep as Dictionary).keys()
			keys.sort()
			for c in keys:
				if needs.has(c):
					var n: int = clampi(_int_or(raw_dep[c]), 0, int(needs[c]))
					if n > 0:
						p.deposits[c] = n
		p.fee_paid = clampi(_int_or(d.get("fee_paid", 0)), 0, int(ph.get("cr", 0)))
	return p


static func _int_or(v: Variant, fallback: int = 0) -> int:
	if typeof(v) == TYPE_INT:
		return v
	if typeof(v) == TYPE_FLOAT and is_finite(v):
		return int(v)
	return fallback


# --- Validation ---

static func _is_int(v: Variant) -> bool:
	if typeof(v) == TYPE_INT:
		return true
	return typeof(v) == TYPE_FLOAT and is_finite(v) and v == floorf(v)


## Every problem with a parsed rescue.json, as readable lines; empty = valid.
static func validate(d: Dictionary) -> Array:
	var errs: Array = []
	if d.is_empty():
		return ["empty or unreadable rescue data"]
	if not _is_int(d.get("version", null)) or int(d["version"]) != VERSION:
		errs.append("version must be %d" % VERSION)
	if str(d.get("unlock", "")) != "monopoly":
		errs.append("unlock must be \"monopoly\"")
	if not _is_int(d.get("rent_multiplier_bps", null)) or int(d["rent_multiplier_bps"]) < 10000:
		errs.append("rent_multiplier_bps must be a whole number >= 10000")
	var win = d.get("win", null)
	if not (win is Dictionary):
		errs.append("win must be an object")
	else:
		for k in ["severance_base", "severance_per_round_left", "phase_consolation"]:
			if not _is_int(win.get(k, null)) or int(win[k]) < 0:
				errs.append("win.%s must be a whole number >= 0" % k)
	var phs = d.get("phases", null)
	if not (phs is Array) or (phs as Array).is_empty():
		errs.append("phases must be a non-empty array")
		return errs
	var seen: Dictionary = {}
	var prev_keep: int = FULL_SPEED_BPS
	for i in (phs as Array).size():
		var ph = phs[i]
		var where: String = "phases[%d]" % i
		if not (ph is Dictionary):
			errs.append("%s must be an object" % where)
			continue
		var id: String = str(ph.get("id", ""))
		if id.is_empty() or not Barons._is_id(id):
			errs.append("%s.id must be lowercase letters, digits and underscores" % where)
		elif seen.has(id):
			errs.append("%s: duplicate id %s" % [where, id])
		else:
			seen[id] = true
			where = "phase %s" % id
		if str(ph.get("name", "")).is_empty():
			errs.append("%s: name is required" % where)
		if not Transit.STATIONS.has(str(ph.get("site", ""))):
			errs.append("%s: site is not a station" % where)
		var needs = ph.get("needs", null)
		if not (needs is Dictionary) or (needs as Dictionary).is_empty():
			errs.append("%s: needs must be a non-empty object" % where)
		else:
			for c in needs:
				if not Transit.COMMODITIES.has(str(c)):
					errs.append("%s: needs.%s is not a commodity" % [where, str(c)])
				elif not _is_int(needs[c]) or int(needs[c]) <= 0:
					errs.append("%s: needs.%s must be a positive whole number" % [where, str(c)])
		if not _is_int(ph.get("cr", null)) or int(ph["cr"]) < 0:
			errs.append("%s: cr must be a whole number >= 0" % where)
		var kb = ph.get("keep_bps", null)
		if not _is_int(kb) or int(kb) < 0 or int(kb) > 10000:
			errs.append("%s: keep_bps must be 0..10000" % where)
		elif int(kb) > prev_keep:
			errs.append("%s: keep_bps must not rise from the phase before" % where)
		else:
			prev_keep = int(kb)
	return errs
