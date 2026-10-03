extends RefCounted
## Tests for Transit (res://core/transit.gd) orbital coordinates and route physics.
## Verifies route specifications, alignment corridors, asteroid belt tolls,
## perishable cargo decay with cap, speed multipliers, fuel rounding, and refinery_loop.

func test_stations_and_commodity_normalization() -> String:
	if Transit.STATIONS.size() != 4:
		return "expected 4 stations, got %d" % Transit.STATIONS.size()
	if Transit.normalize_commodity("banana") != "FRAG":
		return "expected banana to normalize to FRAG"
	if Transit.normalize_commodity("organics") != "FOOD":
		return "expected organics to normalize to FOOD"
	if Transit.normalize_commodity("tech") != "MACHINERY":
		return "expected tech to normalize to MACHINERY"
	if not Transit.is_perishable("FOOD"):
		return "FOOD should be perishable"
	if not Transit.is_perishable("organics"):
		return "organics should be perishable"
	if Transit.is_perishable("FRAG"):
		return "FRAG should not be perishable"
	return "ok"

func test_base_routes_at_round_zero() -> String:
	var r_el = Transit.get_route("earth", "luna", 0)
	if r_el["rounds"] != 1 or r_el["fuel"] != 5 or r_el["is_aligned"]:
		return "earth->luna wrong: %s" % [var_to_str(r_el)]

	var r_em = Transit.get_route("earth", "mars", 0)
	if r_em["rounds"] != 2 or r_em["fuel"] != 15 or r_em["is_aligned"]:
		return "earth->mars wrong: %s" % [var_to_str(r_em)]

	var r_mc = Transit.get_route("mars", "ceres", 0)
	if r_mc["rounds"] != 2 or r_mc["fuel"] != 20 or r_mc["is_aligned"] or not r_mc["is_belt_route"]:
		return "mars->ceres wrong: %s" % [var_to_str(r_mc)]

	var r_ec = Transit.get_route("earth", "ceres", 0)
	if r_ec["rounds"] != 3 or r_ec["fuel"] != 30 or r_ec["is_aligned"] or not r_ec["is_belt_route"]:
		return "earth->ceres wrong: %s" % [var_to_str(r_ec)]

	var r_same = Transit.get_route("mars", "mars", 0)
	if r_same["rounds"] != 0 or r_same["fuel"] != 0:
		return "same station route wrong: %s" % [var_to_str(r_same)]

	var r_invalid = Transit.get_route("earth", "jupiter", 0)
	if r_invalid != null:
		return "invalid station should return null"
	return "ok"

func test_orbital_windows_lifecycle() -> String:
	# Round 0: all corridors inactive
	var windows_r0 = Transit.get_alignment_windows(0)
	if windows_r0.size() != 3:
		return "expected 3 windows, got %d" % windows_r0.size()
	for w in windows_r0:
		if w["is_active"]:
			return "window %s should be inactive at round 0" % w["corridor_id"]
	if Transit.get_active_window_for_route("earth", "mars", 0) != null:
		return "active window for earth-mars should be null at round 0"

	# Round 4: Earth-Mars Opposition active (2 -> 1 round, 15 -> 10 fuel)
	var windows_r4 = Transit.get_alignment_windows(4)
	var em_w = null
	for w in windows_r4:
		if w["corridor_id"] == "earth_mars":
			em_w = w
			break
	if em_w == null or not em_w["is_active"]:
		return "earth_mars window should be active at round 4"
	if em_w["rounds_remaining"] != 2:
		return "earth_mars rounds_remaining should be 2 at round 4, got %d" % em_w["rounds_remaining"]

	var r_em_4 = Transit.get_route("earth", "mars", 4)
	if not r_em_4["is_aligned"] or r_em_4["rounds"] != 1 or r_em_4["fuel"] != 10:
		return "earth-mars route at round 4 wrong: %s" % [var_to_str(r_em_4)]

	# Round 5: Earth-Mars still active, Mars-Ceres also active (2 -> 1 round, 20 -> 12 fuel)
	var r_em_5 = Transit.get_route("earth", "mars", 5)
	if not r_em_5["is_aligned"] or r_em_5["rounds"] != 1:
		return "earth-mars route at round 5 wrong: %s" % [var_to_str(r_em_5)]

	var r_mc_5 = Transit.get_route("mars", "ceres", 5)
	if not r_mc_5["is_aligned"] or r_mc_5["rounds"] != 1 or r_mc_5["fuel"] != 12:
		return "mars-ceres route at round 5 wrong: %s" % [var_to_str(r_mc_5)]

	# Round 6: Earth-Ceres active (3 -> 2 rounds, 30 -> 18 fuel)
	var r_ec_6 = Transit.get_route("earth", "ceres", 6)
	if not r_ec_6["is_aligned"] or r_ec_6["rounds"] != 2 or r_ec_6["fuel"] != 18:
		return "earth-ceres route at round 6 wrong: %s" % [var_to_str(r_ec_6)]

	# Round 12: Earth-Mars synodic period 8 repeats (12 % 8 = 4)
	var r_em_12 = Transit.get_route("earth", "mars", 12)
	if not r_em_12["is_aligned"] or r_em_12["rounds"] != 1:
		return "earth-mars route at round 12 should be aligned"
	return "ok"

func test_asteroid_belt_tolls() -> String:
	# Belt routes: 25 CR toll
	var toll_cm = Transit.calculate_toll("ceres", "mars")
	if toll_cm != 25:
		return "expected 25 toll for ceres->mars, got %d" % toll_cm

	var toll_ec = Transit.calculate_toll("earth", "ceres")
	if toll_ec != 25:
		return "expected 25 toll for earth->ceres, got %d" % toll_ec

	# Non-belt route: 0 toll
	var toll_em = Transit.calculate_toll("earth", "mars")
	if toll_em != 0:
		return "expected 0 toll for earth->mars, got %d" % toll_em

	# Corporate discount
	var toll_disc = Transit.calculate_toll("ceres", "mars", 0.20)
	if toll_disc != 20:
		return "expected 20 toll with 20%% discount, got %d" % toll_disc
	return "ok"

func test_perishable_cargo_decay_and_cap() -> String:
	# Durable cargo has 0 decay
	var decay_frag = Transit.calculate_decay("FRAG", 100, 3, "earth", "ceres")
	if decay_frag != 0:
		return "expected 0 decay for durable scrap, got %d" % decay_frag

	# Perishable cargo on belt route (5% * 3 rounds = 15% decay)
	var decay_food_full = Transit.calculate_decay("FOOD", 100, 3, "earth", "ceres")
	if decay_food_full != 15:
		return "expected 15 decayed for 100 FOOD over 3 belt rounds, got %d" % decay_food_full

	# Mid-transit projected decay
	var decay_proj_1 = Transit.calculate_decay("FOOD", 100, 1, "earth", "ceres")
	if decay_proj_1 != 5:
		return "expected 5 projected decay after 1 round, got %d" % decay_proj_1

	var decay_proj_2 = Transit.calculate_decay("FOOD", 100, 2, "earth", "ceres")
	if decay_proj_2 != 10:
		return "expected 10 projected decay after 2 rounds, got %d" % decay_proj_2

	# Decay cap: decay cannot exceed cargo_qty (e.g. 30 rounds * 5% = 150%)
	var decay_capped = Transit.calculate_decay("FOOD", 100, 30, "earth", "ceres")
	if decay_capped != 100:
		return "expected decay capped at 100, got %d" % decay_capped

	# Non-belt route has 0 decay even for perishable cargo
	var decay_em = Transit.calculate_decay("FOOD", 100, 2, "earth", "mars")
	if decay_em != 0:
		return "expected 0 decay on non-belt route, got %d" % decay_em
	return "ok"

func test_fuel_burn_rounding_and_refinery_loop() -> String:
	# Amos review catch: Sol Direct corridor (Earth-Ceres, round 6) with engines tier 2
	# Route base fuel = 18. Engines tier 2 cut = 40%.
	# 18 * 0.6 = 10.8 -> roundi(10.8) must be 11 FUEL (not truncated 10)
	var fuel_sol_direct = Transit.calculate_fuel_burn("earth", "ceres", 6, 2, false, 0.0)
	if fuel_sol_direct != 11:
		return "Sol Direct corridor with engines tier 2 expected 11 fuel (18*0.6=10.8 -> 11), got %d" % fuel_sol_direct

	# With refinery_loop: extra 20% cut before rounding
	# 18 * 0.6 * 0.8 = 8.64 -> roundi(8.64) = 9 FUEL
	var fuel_refinery = Transit.calculate_fuel_burn("earth", "ceres", 6, 2, true, 0.0)
	if fuel_refinery != 9:
		return "Sol Direct corridor with refinery_loop expected 9 fuel (8.64 -> 9), got %d" % fuel_refinery

	# With 10% corporate discount on top of refinery:
	# int(9 * 0.90) = 8 FUEL
	var fuel_corp = Transit.calculate_fuel_burn("earth", "ceres", 6, 2, true, 0.10)
	if fuel_corp != 8:
		return "Sol Direct corridor with corp discount expected 8 fuel, got %d" % fuel_corp
	return "ok"

func test_speed_multipliers_and_engine_upgrades() -> String:
	# Base 3-round route: Earth -> Ceres
	# Tier 0: 3 rounds, 30 fuel
	var t0_rounds = Transit.calculate_trip_rounds("earth", "ceres", 0, 0)
	var t0_fuel = Transit.calculate_fuel_burn("earth", "ceres", 0, 0)
	if t0_rounds != 3 or t0_fuel != 30:
		return "tier 0 should be 3 rounds, 30 fuel; got %d, %d" % [t0_rounds, t0_fuel]

	# Tier 1: 3+ round trips cut 1 round -> 2 rounds
	var t1_rounds = Transit.calculate_trip_rounds("earth", "ceres", 0, 1)
	if t1_rounds != 2:
		return "tier 1 should cut 3 rounds to 2, got %d" % t1_rounds

	# Tier 1 on 2-round trip (Earth -> Mars): no cut (requires 3+ rounds)
	var t1_em_rounds = Transit.calculate_trip_rounds("earth", "mars", 0, 1)
	if t1_em_rounds != 2:
		return "tier 1 on 2-round trip should stay 2 rounds, got %d" % t1_em_rounds

	# Tier 2: 40% fuel cut on all trips (30 * 0.6 = 18 fuel)
	var t2_fuel = Transit.calculate_fuel_burn("earth", "ceres", 0, 2)
	if t2_fuel != 18:
		return "tier 2 should cut 30 fuel to 18, got %d" % t2_fuel

	# Corporate fuel discount on top of engine tier (18 * 0.90 = 16.2 -> int is 16)
	var corp_fuel = Transit.calculate_fuel_burn("earth", "ceres", 0, 2, false, 0.10)
	if corp_fuel != 16:
		return "corp fuel discount should be 16, got %d" % corp_fuel

	# Trip rounds clamped at 1
	var min_rounds = Transit.calculate_trip_rounds("earth", "luna", 0, 1)
	if min_rounds != 1:
		return "minimum trip rounds should be clamped to 1, got %d" % min_rounds
	return "ok"

func test_orbital_coordinates_and_distance() -> String:
	var r_earth = Transit.get_station_orbital_radius("earth")
	var r_mars = Transit.get_station_orbital_radius("mars")
	var r_ceres = Transit.get_station_orbital_radius("ceres")

	if abs(r_earth - 1.0) > 1e-4 or abs(r_mars - 1.524) > 1e-4 or abs(r_ceres - 2.767) > 1e-4:
		return "orbital radii mismatch"

	var pos_earth = Transit.get_station_position("earth", 0)
	var pos_mars = Transit.get_station_position("mars", 0)
	var dist_em = Transit.get_orbital_distance("earth", "mars", 0)

	if dist_em <= 0.0:
		return "orbital distance should be positive, got %f" % dist_em
	if abs(dist_em - pos_earth.distance_to(pos_mars)) > 1e-4:
		return "get_orbital_distance diverged from Vector2 distance_to"
	return "ok"

func test_transit_simulation_ticks() -> String:
	var ticks_1 = Transit.calculate_transit_ticks(2, 1)
	if ticks_1 != 2:
		return "expected 2 ticks, got %d" % ticks_1

	var ticks_5 = Transit.calculate_transit_ticks(2, 5)
	if ticks_5 != 10:
		return "expected 10 ticks (2 rounds * 5 sub-ticks), got %d" % ticks_5
	return "ok"
