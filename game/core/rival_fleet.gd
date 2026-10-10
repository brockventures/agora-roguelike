class_name RivalFleet
extends RefCounted
## Runtime state of one rival syndicate fleet (Epic 3 task 10, docs/design/epic3-barons.md 6.1).
##
## A fleet is abstract: CR, a cargo map, where it is, and the voyage it is on. It has
## no ship array and no private rules; the logic that moves it is Rivals, and it trades
## through StationMarket.execute_as exactly as the player does. Integers and strings only,
## so to_dict()/from_dict() round-trip through JSON (every read goes through int()).
## The fixed facts (name, home, trait, stance) live in barons.json and are not saved.

var id: String = ""
var cr: int = 0
var cargo: Dictionary = {}
## Where the fleet is docked, or the origin of its voyage while it flies.
var at: String = ""
## {} while idle, otherwise {origin, destination, depart_round, arrival_round, commodity, qty}.
var route: Dictionary = {}
## The last fill, for the desk tag: {round, station, commodity, side, qty, price}. {} before any.
var last: Dictionary = {}


func _init(p_id: String = "") -> void:
	id = p_id


static func from_def(def: Dictionary) -> RivalFleet:
	var f := RivalFleet.new(str(def.get("id", "")))
	f.cr = int(def.get("cr", 0))
	f.at = str(def.get("home", ""))
	return f


func in_flight() -> bool:
	return not route.is_empty()


func cargo_units() -> int:
	var n: int = 0
	for c in cargo:
		n += maxi(0, int(cargo[c]))
	return n


func to_dict() -> Dictionary:
	return {
		"id": id,
		"cr": cr,
		"cargo": _int_map(cargo),
		"at": at,
		"route": _int_or_str_map(route),
		"last": _int_or_str_map(last),
	}


static func from_dict(d: Dictionary) -> RivalFleet:
	var f := RivalFleet.new(str(d.get("id", "")))
	f.cr = int(d.get("cr", 0))
	f.cargo = _read_int_map(d.get("cargo", {}))
	f.at = str(d.get("at", ""))
	f.route = _read_mixed_map(d.get("route", {}))
	f.last = _read_mixed_map(d.get("last", {}))
	return f


## Copy with keys sorted, so the saved form never depends on insertion order.
static func _int_map(m: Dictionary) -> Dictionary:
	var keys: Array = m.keys()
	keys.sort()
	var out: Dictionary = {}
	for k in keys:
		out[str(k)] = int(m[k])
	return out


static func _int_or_str_map(m: Dictionary) -> Dictionary:
	var keys: Array = m.keys()
	keys.sort()
	var out: Dictionary = {}
	for k in keys:
		out[str(k)] = m[k] if m[k] is String else int(m[k])
	return out


static func _read_int_map(v: Variant) -> Dictionary:
	var out: Dictionary = {}
	if v is Dictionary:
		for k in v:
			out[str(k)] = int(v[k])
	return out


static func _read_mixed_map(v: Variant) -> Dictionary:
	var out: Dictionary = {}
	if v is Dictionary:
		for k in v:
			out[str(k)] = str(v[k]) if v[k] is String else int(v[k])
	return out
