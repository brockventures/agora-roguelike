class_name Transit
extends RefCounted
## Orbital coordinates, route physics, transit time ticks, and alignment corridor math.
## Ported from market-sandbox Python referee (agora/spatial.py at commit 587b07f).
##
## Features:
##   - Canonical Sol system stations: earth, luna, mars, ceres.
##   - Orbital radii, 2D coordinates, and Euclidean spatial distance.
##   - Discrete transit rounds, fuel burns, and route specifications.
##   - Orbital alignment corridors (synodic windows cutting transit rounds and fuel).
##   - Asteroid belt route toll booths (25 CR) and perishable cargo decay (5%/round).
##   - Engine tier speed cuts (tier 1: 3+ rounds -1) and fuel cuts (tier 2: 40%).
##   - Discrete simulation tick conversions.

const STATIONS: Array[String] = ["earth", "luna", "mars", "ceres"]
const COMMODITIES: Array[String] = ["FRAG", "FUEL", "FOOD", "ORE", "MACHINERY"]

const COMMODITY_ALIASES: Dictionary = {
	"ORGANICS": "FOOD",
	"BANANA": "FRAG",
	"PARTS": "MACHINERY",
	"TECH": "MACHINERY",
}

const PERISHABLE_COMMODITIES: Array[String] = ["FOOD", "ORGANICS"]

## Equilibrium price surface per station and commodity.
const BASE_PRICES: Dictionary = {
	"earth": {"FRAG": 20.2, "FUEL": 14.5, "FOOD": 10.2, "ORE": 27.5, "MACHINERY": 18.5},
	"luna":  {"FRAG": 15.8, "FUEL": 8.5,  "FOOD": 22.0, "ORE": 21.5, "MACHINERY": 23.0},
	"mars":  {"FRAG": 12.8, "FUEL": 16.5, "FOOD": 17.5, "ORE": 16.5, "MACHINERY": 13.8},
	"ceres": {"FRAG": 11.2, "FUEL": 24.5, "FOOD": 27.5, "ORE": 11.5, "MACHINERY": 29.5},
}

## Base orbital transit distances, discrete rounds, and fuel burn requirements.
const ROUTES: Dictionary = {
	"earth:luna":  {"rounds": 1, "fuel": 5},
	"luna:earth":  {"rounds": 1, "fuel": 5},
	"earth:mars":  {"rounds": 2, "fuel": 15},
	"mars:earth":  {"rounds": 2, "fuel": 15},
	"luna:mars":   {"rounds": 2, "fuel": 15},
	"mars:luna":   {"rounds": 2, "fuel": 15},
	"mars:ceres":  {"rounds": 2, "fuel": 20},
	"ceres:mars":  {"rounds": 2, "fuel": 20},
	"earth:ceres": {"rounds": 3, "fuel": 30},
	"ceres:earth": {"rounds": 3, "fuel": 30},
	"luna:ceres":  {"rounds": 3, "fuel": 30},
	"ceres:luna":  {"rounds": 3, "fuel": 30},
}

## Asteroid belt routes subject to Belt Authority toll and cargo decay.
const BELT_ROUTES: Array[String] = [
	"earth:ceres", "ceres:earth",
	"luna:ceres",  "ceres:luna",
	"mars:ceres",  "ceres:mars",
]

const BELT_TOLL_CR: int = 25
const BELT_CARGO_DECAY_RATE: float = 0.05

## Semi-major orbital radii from the Sun in Astronomical Units (AU).
const ORBITAL_RADII: Dictionary = {
	"earth": 1.0,
	"luna": 1.0,
	"mars": 1.524,
	"ceres": 2.767,
}

## Orbital periods in rounds for spatial coordinate simulation.
const ORBITAL_PERIODS: Dictionary = {
	"earth": 12,
	"luna": 12,
	"mars": 24,
	"ceres": 48,
}

## Orbital alignment corridors (synodic windows).
const ALIGNMENT_WINDOWS: Array[Dictionary] = [
	{
		"corridor_id": "earth_mars",
		"name": "Earth-Mars Perihelion Opposition",
		"routes": [["earth", "mars"], ["mars", "earth"], ["luna", "mars"], ["mars", "luna"]],
		"period_rounds": 8,
		"window_offsets": [4, 5],
		"transit_reduction_pct": 0.50,
		"fuel_reduction_pct": 0.33,
		"description": "Synodic opposition opens the Hohmann launch corridor, halving transit time to 1 round."
	},
	{
		"corridor_id": "mars_ceres",
		"name": "Martian-Ceres Belt Opposition",
		"routes": [["mars", "ceres"], ["ceres", "mars"]],
		"period_rounds": 10,
		"window_offsets": [5, 6],
		"transit_reduction_pct": 0.50,
		"fuel_reduction_pct": 0.40,
		"description": "Inner Asteroid Belt orbital alignment provides gravitational assist, halving transit rounds."
	},
	{
		"corridor_id": "earth_ceres",
		"name": "Sol Direct Corridor",
		"routes": [["earth", "ceres"], ["ceres", "earth"], ["luna", "ceres"], ["ceres", "luna"]],
		"period_rounds": 12,
		"window_offsets": [6, 7],
		"transit_reduction_pct": 0.33,
		"fuel_reduction_pct": 0.40,
		"description": "Deep belt gravitational slingshot corridor cutting transit time and propellant burn."
	}
]

## Engine tier upgrades: (minimum trip length in rounds, rounds cut).
const ENGINE_CUTS: Array = [[3, 1], [0, 0]]

## Engine tier fuel burn cuts (tier 0, 1, 2).
const ENGINE_FUEL_CUTS: Array[float] = [0.0, 0.0, 0.40]

## Normalize commodity name/alias to canonical symbol.
static func normalize_commodity(name: String) -> String:
	if name.is_empty():
		return ""
	var upper := name.strip_edges().to_upper()
	return str(COMMODITY_ALIASES.get(upper, upper))

## Checks if a commodity is perishable.
static func is_perishable(commodity: String) -> bool:
	var canon := normalize_commodity(commodity)
	return canon in PERISHABLE_COMMODITIES

## Route key helper.
static func route_key(origin: String, destination: String) -> String:
	return "%s:%s" % [origin.to_lower().strip_edges(), destination.to_lower().strip_edges()]

## Returns orbital radius in AU for a station.
static func get_station_orbital_radius(station_id: String) -> float:
	var st := station_id.to_lower().strip_edges()
	return float(ORBITAL_RADII.get(st, 1.0))

## Computes 2D position in AU coordinates at a given round number.
static func get_station_position(station_id: String, round_num: int = 0) -> Vector2:
	var st := station_id.to_lower().strip_edges()
	var radius: float = float(ORBITAL_RADII.get(st, 1.0))
	var period: int = int(ORBITAL_PERIODS.get(st, 12))
	var angle: float = (float(round_num % period) / float(period)) * TAU

	if st == "luna":
		# Luna orbits Earth at a slight offset
		var earth_pos := get_station_position("earth", round_num)
		var lunar_angle: float = (float(round_num % 4) / 4.0) * TAU
		return earth_pos + Vector2(cos(lunar_angle), sin(lunar_angle)) * 0.05

	return Vector2(cos(angle), sin(angle)) * radius

## Returns Euclidean distance in AU between two stations at round_num.
static func get_orbital_distance(origin: String, destination: String, round_num: int = 0) -> float:
	var pos1 := get_station_position(origin, round_num)
	var pos2 := get_station_position(destination, round_num)
	return pos1.distance_to(pos2)

## Returns status and schedules for all orbital alignment windows at round_num.
static func get_alignment_windows(round_num: int = 0) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for w in ALIGNMENT_WINDOWS:
		var period: int = int(w["period_rounds"])
		var offsets: Array = w["window_offsets"]
		var mod_rnd: int = round_num % period
		var is_active: bool = mod_rnd in offsets
		var rounds_remaining: int = 0
		var rounds_until_next: int = 0

		if is_active:
			var idx: int = offsets.find(mod_rnd)
			rounds_remaining = offsets.size() - idx
			rounds_until_next = 0
		else:
			rounds_remaining = 0
			var first_offset: int = int(offsets[0])
			if mod_rnd < first_offset:
				rounds_until_next = first_offset - mod_rnd
			else:
				rounds_until_next = (period - mod_rnd) + first_offset

		results.append({
			"corridor_id": w["corridor_id"],
			"name": w["name"],
			"routes": w["routes"],
			"period_rounds": period,
			"is_active": is_active,
			"rounds_remaining": rounds_remaining,
			"rounds_until_next": rounds_until_next,
			"transit_reduction_pct": float(w["transit_reduction_pct"]),
			"fuel_reduction_pct": float(w["fuel_reduction_pct"]),
			"description": w["description"]
		})
	return results

## Checks if an active alignment window applies to the specified route at round_num.
static func get_active_window_for_route(origin: String, destination: String, round_num: int = 0) -> Variant:
	var orig := origin.to_lower().strip_edges()
	var dest := destination.to_lower().strip_edges()
	var windows := get_alignment_windows(round_num)
	for w in windows:
		if w["is_active"]:
			for r in w["routes"]:
				if r[0] == orig and r[1] == dest:
					return w
	return null

## Returns route specifications (rounds, fuel, alignment, toll, decay rate) between two stations.
static func get_route(origin: String, destination: String, round_num: int = 0) -> Variant:
	var orig := origin.to_lower().strip_edges()
	var dest := destination.to_lower().strip_edges()
	if orig == dest:
		return {"rounds": 0, "fuel": 0}

	var k := route_key(orig, dest)
	if not ROUTES.has(k):
		return null
	var base: Dictionary = ROUTES[k]

	var window = get_active_window_for_route(orig, dest, round_num)
	var rounds: int = int(base["rounds"])
	var fuel: int = int(base["fuel"])
	var is_aligned: bool = false
	var window_name = null
	var rounds_remaining: int = 0

	if window != null and window.get("is_active", false):
		rounds = maxi(1, int(round(float(base["rounds"]) * (1.0 - float(window["transit_reduction_pct"])))))
		fuel = maxi(1, int(float(base["fuel"]) * (1.0 - float(window["fuel_reduction_pct"]))))
		is_aligned = true
		window_name = window["name"]
		rounds_remaining = int(window["rounds_remaining"])

	var is_belt: bool = k in BELT_ROUTES
	var toll: int = BELT_TOLL_CR if is_belt else 0
	var decay_rate: float = BELT_CARGO_DECAY_RATE if is_belt else 0.0

	return {
		"rounds": rounds,
		"fuel": fuel,
		"base_rounds": int(base["rounds"]),
		"base_fuel": int(base["fuel"]),
		"is_aligned": is_aligned,
		"window_name": window_name,
		"rounds_remaining": rounds_remaining,
		"is_belt_route": is_belt,
		"toll": toll,
		"decay_rate": decay_rate
	}

## Calculates rounds cut by engines upgrade tier.
static func engine_cut(engine_tier: int, rounds: int) -> int:
	var cut: int = 0
	var max_tier: int = mini(engine_tier, ENGINE_CUTS.size())
	for i in range(max_tier):
		var rule: Array = ENGINE_CUTS[i]
		var need: int = int(rule[0])
		var c: int = int(rule[1])
		if need > 0 and rounds >= need:
			cut += c
	return cut

## Calculates fuel cut by engines upgrade tier.
static func engine_fuel_discount(engine_tier: int) -> float:
	var idx := mini(maxi(0, engine_tier), ENGINE_FUEL_CUTS.size() - 1)
	return ENGINE_FUEL_CUTS[idx]

## Calculates effective trip rounds accounting for alignment corridors and engine cuts.
static func calculate_trip_rounds(origin: String, destination: String, round_num: int = 0, engine_tier: int = 0) -> int:
	var r = get_route(origin, destination, round_num)
	if r == null:
		return 0
	var route_rounds: int = int(r["rounds"])
	if route_rounds <= 0:
		return 0
	var cut := engine_cut(engine_tier, route_rounds)
	return maxi(1, route_rounds - cut)

## Calculates required fuel accounting for alignment corridors, engine tier, and corporate discount.
static func calculate_fuel_burn(
	origin: String,
	destination: String,
	round_num: int = 0,
	engine_tier: int = 0,
	corp_fuel_discount: float = 0.0
) -> int:
	var r = get_route(origin, destination, round_num)
	if r == null:
		return 0
	var base_fuel: int = int(r["fuel"])
	if base_fuel <= 0:
		return 0

	# Apply engine fuel cut (e.g. 40% at tier 2)
	var fuel_discount := engine_fuel_discount(engine_tier)
	var required_fuel := maxi(1, int(float(base_fuel) * (1.0 - fuel_discount)))

	# Apply corporate fuel discount
	if corp_fuel_discount > 0.0:
		required_fuel = maxi(1, int(float(required_fuel) * (1.0 - corp_fuel_discount)))

	return required_fuel

## Calculates Belt Authority toll with optional corporate opex discount.
static func calculate_toll(origin: String, destination: String, corp_opex_discount: float = 0.0) -> int:
	var k := route_key(origin, destination)
	if not (k in BELT_ROUTES):
		return 0
	var toll: int = BELT_TOLL_CR
	if corp_opex_discount > 0.0:
		toll = int(float(toll) * (1.0 - corp_opex_discount))
	return toll

## Calculates projected cargo decay mid-transit or on arrival.
static func calculate_decay(
	commodity: String,
	cargo_qty: int,
	elapsed_rounds: int,
	origin: String,
	destination: String,
	perishable_override: Variant = null
) -> int:
	if cargo_qty <= 0 or elapsed_rounds <= 0:
		return 0
	var k := route_key(origin, destination)
	if not (k in BELT_ROUTES):
		return 0
	var is_perish: bool = bool(perishable_override) if perishable_override != null else is_perishable(commodity)
	if not is_perish:
		return 0
	var total_decay_pct: float = BELT_CARGO_DECAY_RATE * float(elapsed_rounds)
	return int(floor(float(cargo_qty) * total_decay_pct))

## Converts discrete transit rounds into game simulation ticks.
static func calculate_transit_ticks(rounds: int, ticks_per_round: int = 1) -> int:
	return maxi(0, rounds * maxi(1, ticks_per_round))
