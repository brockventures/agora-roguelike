class_name BaronState
extends RefCounted
## Runtime state of one sector baron (Epic 3, docs/design/epic3-barons.md 3.1).
##
## Integers and strings only, so to_dict()/from_dict() round-trip through JSON the
## way CrisisDeck does (Godot parses every JSON number as a float, so every read
## goes through int()). Nothing here decides anything yet: later Epic 3 tasks
## read and change these fields, this class only holds and persists them.

var id: String = ""
var treasury_cr: int = 0
## Shares of the float the baron still holds itself (the rest is outside).
var treasury_shares: int = 0
var inventory: Dictionary = {}
var margin_debt_cr: int = 0
var debt_cr: int = 0
## Consecutive insolvent rounds.
var strain: int = 0
## Decaying player market impact per commodity, in bps.
var pressure_bps: Dictionary = {}
## Player-caused heat (docs 6.2).
var heat: int = 0
## "" while the baron runs itself, "player" or a rival id once taken.
var holder: String = ""
## Shares held by outsiders, by holder id.
var shares: Dictionary = {}
## Archetype scratch fields (squeeze countdown, hoard age, auction buffer, ...).
var scratch: Dictionary = {}


func _init(p_id: String = "") -> void:
	id = p_id


## Opening state of a baron from its barons.json entry.
static func from_def(def: Dictionary) -> BaronState:
	var s := BaronState.new(str(def.get("id", "")))
	s.treasury_cr = int(def.get("treasury_cr", 0))
	s.treasury_shares = int(def.get("treasury_shares", 0))
	s.margin_debt_cr = int(def.get("margin_debt_cr", 0))
	var inv = def.get("inventory", {})
	if inv is Dictionary:
		for k in inv:
			s.inventory[str(k)] = int(inv[k])
	return s


func to_dict() -> Dictionary:
	return {
		"id": id,
		"treasury_cr": treasury_cr,
		"treasury_shares": treasury_shares,
		"inventory": _int_map(inventory),
		"margin_debt_cr": margin_debt_cr,
		"debt_cr": debt_cr,
		"strain": strain,
		"pressure_bps": _int_map(pressure_bps),
		"heat": heat,
		"holder": holder,
		"shares": _int_map(shares),
		"scratch": scratch.duplicate(true),
	}


static func from_dict(d: Dictionary) -> BaronState:
	var s := BaronState.new(str(d.get("id", "")))
	s.treasury_cr = int(d.get("treasury_cr", 0))
	s.treasury_shares = int(d.get("treasury_shares", 0))
	s.inventory = _read_int_map(d.get("inventory", {}))
	s.margin_debt_cr = int(d.get("margin_debt_cr", 0))
	s.debt_cr = int(d.get("debt_cr", 0))
	s.strain = int(d.get("strain", 0))
	s.pressure_bps = _read_int_map(d.get("pressure_bps", {}))
	s.heat = int(d.get("heat", 0))
	s.holder = str(d.get("holder", ""))
	s.shares = _read_int_map(d.get("shares", {}))
	var sc = d.get("scratch", {})
	s.scratch = (sc as Dictionary).duplicate(true) if sc is Dictionary else {}
	return s


## Copy with keys sorted, so the saved form never depends on insertion order.
static func _int_map(m: Dictionary) -> Dictionary:
	var keys: Array = m.keys()
	keys.sort()
	var out: Dictionary = {}
	for k in keys:
		out[str(k)] = int(m[k])
	return out


static func _read_int_map(v: Variant) -> Dictionary:
	var out: Dictionary = {}
	if v is Dictionary:
		for k in v:
			out[str(k)] = int(v[k])
	return out
