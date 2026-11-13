class_name FleetView
extends RefCounted
## Read-only view model for the Fleet tab (Epic 6 #122). Presentation only: nothing here
## writes sim state, saves or hashes.
##
## The core has one corp-level voyage (RunController.transit / docked_at) and one corp-level
## hold (RunController.cargo / cargo_capacity), so every hull's location and ETA derive from
## those; no per-hull position or per-hull cargo is invented. Archetype, hull integrity and
## shield integrity are DISPLAY-ONLY optional keys on a ship Dictionary, read here with
## defaults ("archetype": HAULER, "hull_pct": 100, "shield_pct": 100). Nothing in the core
## writes or lowers them (no damage mechanic exists), so a stock ship dict is unchanged,
## saves are unchanged and no hash pin moves. A future damage mechanic only has to write the
## keys.

const HAULER: String = "HAULER"
const INTERCEPTOR: String = "INTERCEPTOR"
const FREIGHTER: String = "FREIGHTER"
const SCOUT: String = "SCOUT"
const SCRAP_BARGE: String = "SCRAP_BARGE"
const ARCHETYPES: Array[String] = [HAULER, INTERCEPTOR, FREIGHTER, SCOUT, SCRAP_BARGE]

## Archetype id -> string key (literal keys so the CSV reachability lint sees them).
const ARCHETYPE_KEYS: Dictionary = {
	HAULER: "FLEET_ARCH_HAULER",
	INTERCEPTOR: "FLEET_ARCH_INTERCEPTOR",
	FREIGHTER: "FLEET_ARCH_FREIGHTER",
	SCOUT: "FLEET_ARCH_SCOUT",
	SCRAP_BARGE: "FLEET_ARCH_SCRAP_BARGE",
}

const STATE_DOCKED: String = "docked"
const STATE_TRANSIT: String = "transit"


## The ship's archetype id (HAULER when the key is absent or unknown).
static func archetype_of(ship) -> String:
	if ship is Dictionary:
		var a: String = str(ship.get("archetype", HAULER)).to_upper().replace(" ", "_")
		if ARCHETYPES.has(a):
			return a
	return HAULER


## The translated archetype label for a ship.
static func archetype_label(ship) -> String:
	return Loc.t(str(ARCHETYPE_KEYS[archetype_of(ship)]))


## Hull integrity, 0..100 (100 when the ship carries no value).
static func hull_pct(ship) -> int:
	return _pct(ship, "hull_pct")


## Shield integrity, 0..100 (100 when the ship carries no value).
static func shield_pct(ship) -> int:
	return _pct(ship, "shield_pct")


static func _pct(ship, key: String) -> int:
	if ship is Dictionary:
		return clampi(int(ship.get(key, 100)), 0, 100)
	return 100


## Where the fleet is: {state, station, destination, eta_rounds}. station is the docked
## station id ("" in transit); destination and eta_rounds are only set in transit.
static func status_of(rc: RunController) -> Dictionary:
	if rc.is_in_transit():
		var info: Dictionary = rc.transit_info()
		return {
			"state": STATE_TRANSIT,
			"station": "",
			"destination": str(info.get("destination", "")),
			"eta_rounds": int(info.get("eta_rounds", 0)),
		}
	return {"state": STATE_DOCKED, "station": rc.docked_at, "destination": "", "eta_rounds": 0}


## One step of the fleet cursor, clamped (no wrap) to [0, count - 1].
static func step_cursor(cursor: int, delta: int, count: int) -> int:
	if count <= 0:
		return 0
	return clampi(cursor + delta, 0, count - 1)


## First visible row of a window of `rows` over `count` hulls that keeps `cursor` in view.
static func window_start(cursor: int, count: int, rows: int) -> int:
	return clampi(cursor - rows + 1, 0, maxi(0, count - rows)) if cursor >= rows else 0


## Shipyard drydock upgrade catalog annotated for `rc`'s current round and owned tiers (#215).
static func upgrade_catalog(rc: RunController) -> Array[Dictionary]:
	if rc == null:
		var empty: Array[Dictionary] = []
		return empty
	var tiers: Dictionary = rc.upgrades.tiers if rc.upgrades != null else {}
	return Upgrades.catalog_for(rc.get_current_round(), tiers)


## Eligibility check for fitting the next tier of `kind` on `rc` right now (#215).
static func can_buy_upgrade(rc: RunController, kind: String) -> Dictionary:
	if rc == null:
		return Upgrades.can_buy_for({}, kind, 0, 0, false, true)
	var tiers: Dictionary = rc.upgrades.tiers if rc.upgrades != null else {}
	var docked: bool = not rc.is_in_transit() and rc.docked_at != ""
	var over: bool = rc.is_run_over() or rc.pending_bankruptcy
	return Upgrades.can_buy_for(tiers, kind, rc.get_current_round(), rc.cr, docked, over)


## One step of the drydock upgrade cursor, clamped (no wrap) across Upgrades.ids().
static func step_upgrade_cursor(cursor: int, delta: int) -> int:
	return step_cursor(cursor, delta, Upgrades.ids().size())
