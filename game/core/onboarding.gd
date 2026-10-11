class_name Onboarding
extends RefCounted
## First-hour tutorial model (#36, docs/design/onboarding.md): the beat table as data
## (data/onboarding.json, validated here) and the pure transitions "event in, active beat out".
##
## Pure and display-free. It reads nothing from the sim, calls nothing on it, draws from no
## stream and writes no clock or run state; Main (task 2) feeds it events and context. Its only
## persisted state is `tutorial_enabled` / `tutorial_seen` on AccessibilitySettings
## (settings.json), so nothing here reaches RunSave, a replay or a hash.
##
## Events are Dictionaries with a "type" in EVENTS plus type-specific fields:
##   tab_changed {tab}            order_executed {side, station}     round_advanced
##   transit_departed             transit_arrived                    corridor_raid / corridor_hazard
##   bankruptcy_filed             perk_screen_opened / _closed       run_ended
## Context (set_context, also updated by events) is what the HUD can show right now:
##   tab, fills, hold_empty, route_card, in_transit. It is runtime only, recomputed on load.
##
## A beat is "seen" once done. Done events complete a beat even if it never showed ("a player
## who does the thing first marks the beat done without ever seeing it"); an event count above 1
## only advances while the beat is the active one. At most one beat is active: the lowest
## numbered that can show, never preempted. Core beats need `tutorial_enabled`; conditional
## beats ignore it. A beat with `holds` true is one whose text needs reading; a later Main-level
## freeze may hold the game while it is up. Nothing here implements that freeze.

## Emitted once when a beat is marked done (after the settings changed). Read-only for
## listeners: SteamHooks (the onboarding_step stat, the Orientation Complete achievement).
signal beat_completed(id: String)

const PATH := "res://data/onboarding.json"
const VERSION: int = 1
const KIND_CORE := "core"
const KIND_CONDITIONAL := "conditional"
const MAX_BEATS: int = 32
const MAX_LINES: int = 3
const EVENTS: Array[String] = [
	"tab_changed", "order_executed", "round_advanced", "transit_departed", "transit_arrived",
	"corridor_raid", "corridor_hazard", "bankruptcy_filed", "perk_screen_opened",
	"perk_screen_closed", "run_ended",
]
## Context keys and the type each must hold.
const CONTEXT_TYPES: Dictionary = {
	"tab": TYPE_STRING, "fills": TYPE_INT, "hold_empty": TYPE_BOOL,
	"route_card": TYPE_BOOL, "in_transit": TYPE_BOOL,
}
const BEAT_KEYS: Array[String] = ["id", "kind", "holds", "title_key", "line_keys", "fires", "done", "disables_on_done"]
const FIRES_KEYS: Array[String] = ["on", "requires", "context"]
const DONE_KEYS: Array[String] = ["on", "match", "count", "away_from_buy"]

static var _shipped: Dictionary = {}

var settings: AccessibilitySettings
var beats: Array = []
var load_error: String = ""
var _ctx: Dictionary = {"tab": "MAP", "fills": 0, "hold_empty": true, "route_card": false, "in_transit": false}
var _pending: Array[String] = []
var _count: Dictionary = {}
var _buy_stations: Dictionary = {}
var _active: String = ""


## `data` is a loaded table ({"ok", "beats"}); empty means the shipped data/onboarding.json.
func _init(p_settings: AccessibilitySettings = null, data: Dictionary = {}) -> void:
	settings = p_settings if p_settings != null else AccessibilitySettings.new()
	var d: Dictionary = data if not data.is_empty() else shipped()
	if bool(d.get("ok", false)):
		beats = (d["beats"] as Array).duplicate(true)
	else:
		load_error = str(d.get("error", "no data"))
	_refresh()


# ---- data: loader and validator -------------------------------------------------------

## Reads and validates a table. {"ok": bool, "error": String, "beats": Array}.
static func load_data(path: String = PATH) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "cannot open %s" % path, "beats": []}
	var parsed = JSON.parse_string(f.get_as_text())
	var errs: Array[String] = validate(parsed)
	if not errs.is_empty():
		return {"ok": false, "error": "; ".join(errs), "beats": []}
	return {"ok": true, "error": "", "beats": (parsed as Dictionary)["beats"]}


static func shipped() -> Dictionary:
	if _shipped.is_empty():
		_shipped = load_data()
	return _shipped


static func beat_ids() -> Array[String]:
	var out: Array[String] = []
	for b in shipped().get("beats", []):
		out.append(str((b as Dictionary)["id"]))
	return out


## Every problem with a parsed table, empty when it is sound. Never throws on hostile input.
static func validate(data: Variant) -> Array[String]:
	var errs: Array[String] = []
	if not (data is Dictionary):
		errs.append("table is not an object")
		return errs
	var d: Dictionary = data
	if not _is_whole(d.get("version", null)) or int(d["version"]) != VERSION:
		errs.append("version must be %d" % VERSION)
	var arr = d.get("beats", null)
	if not (arr is Array) or (arr as Array).is_empty() or (arr as Array).size() > MAX_BEATS:
		errs.append("beats must be a list of 1..%d" % MAX_BEATS)
		return errs
	var seen_ids: Array[String] = []
	for i in (arr as Array).size():
		var b = (arr as Array)[i]
		var label := "beat %d" % i
		if not (b is Dictionary):
			errs.append("%s is not an object" % label)
			continue
		var bd: Dictionary = b
		var id = bd.get("id", null)
		if not (id is String) or not _matches(id, "^[a-z0-9_]+$"):
			errs.append("%s: bad id" % label)
			continue
		label = "beat %s" % id
		if seen_ids.has(id):
			errs.append("%s: duplicate id" % label)
		for k in bd.keys():
			if not BEAT_KEYS.has(str(k)):
				errs.append("%s: unknown key %s" % [label, str(k)])
		if not [KIND_CORE, KIND_CONDITIONAL].has(bd.get("kind", null)):
			errs.append("%s: kind must be core or conditional" % label)
		if not (bd.get("holds", null) is bool):
			errs.append("%s: holds must be a bool" % label)
		if bd.has("disables_on_done") and not (bd["disables_on_done"] is bool):
			errs.append("%s: disables_on_done must be a bool" % label)
		if not _is_key(bd.get("title_key", null)):
			errs.append("%s: bad title_key" % label)
		var lines = bd.get("line_keys", null)
		if not (lines is Array) or (lines as Array).is_empty() or (lines as Array).size() > MAX_LINES:
			errs.append("%s: line_keys must hold 1..%d keys" % [label, MAX_LINES])
		else:
			for lk in lines:
				if not _is_key(lk):
					errs.append("%s: bad line key" % label)
		_validate_fires(bd.get("fires", null), seen_ids, label, errs)
		_validate_done(bd.get("done", null), label, errs)
		seen_ids.append(id)
	return errs


static func _validate_fires(f: Variant, earlier: Array[String], label: String, errs: Array[String]) -> void:
	if not (f is Dictionary):
		errs.append("%s: fires must be an object" % label)
		return
	var fd: Dictionary = f
	for k in fd.keys():
		if not FIRES_KEYS.has(str(k)):
			errs.append("%s: unknown fires key %s" % [label, str(k)])
	var has_trigger := false
	if fd.has("on"):
		if _event_list_ok(fd["on"]):
			has_trigger = true
		else:
			errs.append("%s: fires.on must be a non-empty list of known events" % label)
	if fd.has("requires"):
		if not (fd["requires"] is Array):
			errs.append("%s: fires.requires must be a list" % label)
		else:
			for r in fd["requires"]:
				if not (r is String) or not earlier.has(r):
					errs.append("%s: fires.requires names an unknown or later beat" % label)
	if fd.has("context"):
		var c = fd["context"]
		if not (c is Dictionary):
			errs.append("%s: fires.context must be an object" % label)
		else:
			for k in (c as Dictionary).keys():
				if not CONTEXT_TYPES.has(str(k)):
					errs.append("%s: unknown context key %s" % [label, str(k)])
				elif not _type_ok((c as Dictionary)[k], int(CONTEXT_TYPES[str(k)])):
					errs.append("%s: context %s has the wrong type" % [label, str(k)])
			if not (c as Dictionary).is_empty():
				has_trigger = true
	if not has_trigger:
		errs.append("%s: fires needs an event list or a context" % label)


static func _validate_done(f: Variant, label: String, errs: Array[String]) -> void:
	if not (f is Dictionary):
		errs.append("%s: done must be an object" % label)
		return
	var dd: Dictionary = f
	for k in dd.keys():
		if not DONE_KEYS.has(str(k)):
			errs.append("%s: unknown done key %s" % [label, str(k)])
	if not _event_list_ok(dd.get("on", null)):
		errs.append("%s: done.on must be a non-empty list of known events" % label)
	if dd.has("match"):
		var m = dd["match"]
		if not (m is Dictionary):
			errs.append("%s: done.match must be an object" % label)
		else:
			for v in (m as Dictionary).values():
				if not (v is String or v is bool or v is int or v is float):
					errs.append("%s: done.match values must be scalars" % label)
	if dd.has("count") and (not _is_whole(dd["count"]) or int(dd["count"]) < 1 or int(dd["count"]) > 100):
		errs.append("%s: done.count must be a whole number 1..100" % label)
	if dd.has("away_from_buy"):
		if not (dd["away_from_buy"] is bool):
			errs.append("%s: done.away_from_buy must be a bool" % label)
		elif not (dd.get("on", []) is Array and (dd["on"] as Array).has("order_executed")):
			errs.append("%s: away_from_buy needs order_executed" % label)


static func _event_list_ok(v: Variant) -> bool:
	if not (v is Array) or (v as Array).is_empty():
		return false
	for e in v:
		if not (e is String) or not EVENTS.has(e):
			return false
	return true


static func _is_whole(v: Variant) -> bool:
	return (v is int) or (v is float and is_finite(v) and v == floorf(v))


static func _is_key(v: Variant) -> bool:
	return v is String and _matches(v, "^ONB_[A-Z0-9_]+$")


static func _matches(s: String, pattern: String) -> bool:
	var re := RegEx.new()
	re.compile(pattern)
	return re.search(s) != null


static func _type_ok(v: Variant, t: int) -> bool:
	if t == TYPE_INT:
		return _is_whole(v)
	return typeof(v) == t


## A stored `tutorial_seen` made safe: known ids only, unique, sorted. Anything else is [].
static func sanitize_seen(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if not (v is Array):
		return out
	var known: Array[String] = beat_ids()
	for e in v:
		if e is String and known.has(e) and not out.has(e):
			out.append(e)
	out.sort()
	return out


# ---- queries -------------------------------------------------------------------------

func is_enabled() -> bool:
	return settings.tutorial_enabled


## The highest core beat completed, 1-based in table order (0 when none): the Steam
## `onboarding_step` stat (design section 12). Beats can finish out of order, so this is the
## highest seen, not a count.
func core_step() -> int:
	var step: int = 0
	var n: int = 0
	for b in beats:
		if str((b as Dictionary)["kind"]) != KIND_CORE:
			continue
		n += 1
		if is_seen(str((b as Dictionary)["id"])):
			step = n
	return step


## The last core beat in the table (the one that finishes the core loop), "" with no table.
func last_core_id() -> String:
	var out: String = ""
	for b in beats:
		if str((b as Dictionary)["kind"]) == KIND_CORE:
			out = str((b as Dictionary)["id"])
	return out


func is_seen(id: String) -> bool:
	return settings.tutorial_seen.has(id)


func beat(id: String) -> Dictionary:
	for b in beats:
		if str((b as Dictionary)["id"]) == id:
			return b
	return {}


## The active beat id, or "" for none.
func active_id() -> String:
	return _active


## The active beat's data plus "index" (0-based) and "total", or {} for none.
func active_beat() -> Dictionary:
	if _active == "":
		return {}
	var b: Dictionary = beat(_active).duplicate(true)
	b["index"] = _index_of(_active)
	b["total"] = beats.size()
	return b


## True when the active beat needs reading (its `holds` flag). Data only; nothing is frozen here.
func holds_now() -> bool:
	return _active != "" and bool(beat(_active).get("holds", false))


func context() -> Dictionary:
	return _ctx.duplicate()


# ---- transitions ---------------------------------------------------------------------

## Folds one event in and returns the active beat id. Unknown or malformed events are ignored.
func handle(event: Dictionary) -> String:
	var t = event.get("type", null)
	if not (t is String) or not EVENTS.has(t):
		return _active
	_apply_done(t, event)
	_update_context(t, event)
	if t == "run_ended" and settings.tutorial_enabled:
		settings.set_tutorial_enabled(false)
	_latch(t)
	_refresh()
	return _active


## Merges HUD-derived context (what is on screen now); the way to resync after a load.
## Keys outside CONTEXT_TYPES or of the wrong type are ignored.
func set_context(ctx: Dictionary) -> String:
	for k in ctx.keys():
		if CONTEXT_TYPES.has(k) and _type_ok(ctx[k], int(CONTEXT_TYPES[k])):
			_ctx[k] = int(ctx[k]) if int(CONTEXT_TYPES[k]) == TYPE_INT else ctx[k]
	_refresh()
	return _active


## The tutorial switch. Turning it on from off replays the core beats (their seen marks are cleared).
func set_enabled(on: bool) -> void:
	if on == settings.tutorial_enabled:
		return
	if on:
		var core_ids: Array[String] = []
		for b in beats:
			if str((b as Dictionary)["kind"]) == KIND_CORE:
				core_ids.append(str((b as Dictionary)["id"]))
		settings.clear_tutorial_seen(core_ids)
		for id in core_ids:
			_pending.erase(id)
			_count.erase(id)
		_buy_stations.clear()
	settings.set_tutorial_enabled(on)
	_refresh()


func _apply_done(t: String, event: Dictionary) -> void:
	for b in beats:
		var id: String = str(b["id"])
		if is_seen(id) or not _eligible(b):
			continue
		var dn: Dictionary = b["done"]
		if not (dn["on"] as Array).has(t) or not _match_ok(dn.get("match", {}), event):
			continue
		if bool(dn.get("away_from_buy", false)) and _buy_stations.has(str(event.get("station", ""))):
			continue
		var need: int = int(dn.get("count", 1))
		if need > 1:
			if id != _active:
				continue
			_count[id] = int(_count.get(id, 0)) + 1
			if int(_count[id]) < need:
				continue
		_complete(b)


func _complete(b: Dictionary) -> void:
	var id: String = str(b["id"])
	_pending.erase(id)
	_count.erase(id)
	if _active == id:
		_active = ""
	settings.mark_tutorial_seen(id)
	if bool(b.get("disables_on_done", false)) and settings.tutorial_enabled:
		settings.set_tutorial_enabled(false)
	beat_completed.emit(id)


func _update_context(t: String, event: Dictionary) -> void:
	match t:
		"tab_changed":
			_ctx["tab"] = str(event.get("tab", _ctx["tab"]))
		"order_executed":
			_ctx["fills"] = int(_ctx["fills"]) + 1
			if str(event.get("side", "")) == "BUY":
				_buy_stations[str(event.get("station", ""))] = true
		"transit_departed":
			_ctx["in_transit"] = true
		"transit_arrived":
			_ctx["in_transit"] = false


## Event-triggered beats latch when their event arrives with their prerequisites met.
func _latch(t: String) -> void:
	for b in beats:
		var id: String = str(b["id"])
		var fr: Dictionary = b["fires"]
		if is_seen(id) or _pending.has(id) or not _eligible(b):
			continue
		if (fr.get("on", []) as Array).has(t) and _requires_ok(fr):
			_pending.append(id)


func _refresh() -> void:
	if _active != "" and not _can_show(beat(_active)):
		_active = ""
	if _active == "":
		for b in beats:
			if _can_show(b):
				_active = str(b["id"])
				_count[_active] = 0
				break


func _can_show(b: Dictionary) -> bool:
	if b.is_empty():
		return false
	var id: String = str(b["id"])
	if is_seen(id) or not _eligible(b):
		return false
	if _pending.has(id):
		return true
	var fr: Dictionary = b["fires"]
	var cx: Dictionary = fr.get("context", {})
	return not cx.is_empty() and _requires_ok(fr) and _context_ok(cx)


func _eligible(b: Dictionary) -> bool:
	return str(b["kind"]) == KIND_CONDITIONAL or settings.tutorial_enabled


func _requires_ok(fr: Dictionary) -> bool:
	for r in fr.get("requires", []):
		if not is_seen(str(r)):
			return false
	return true


func _context_ok(cx: Dictionary) -> bool:
	for k in cx.keys():
		if not _eq(_ctx.get(k, null), cx[k]):
			return false
	return true


func _match_ok(m: Dictionary, event: Dictionary) -> bool:
	for k in m.keys():
		if not event.has(k) or not _eq(event[k], m[k]):
			return false
	return true


static func _eq(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	return typeof(a) == typeof(b) and a == b


func _index_of(id: String) -> int:
	for i in beats.size():
		if str((beats[i] as Dictionary)["id"]) == id:
			return i
	return -1
