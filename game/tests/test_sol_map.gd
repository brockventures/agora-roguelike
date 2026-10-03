extends RefCounted
## Unit tests for SolTacticalMap projection and coordinate simulation (#21).

func test_init_defaults() -> String:
	var m := SolTacticalMap.new()
	if m.current_round != 0 or not m.selected_station.is_empty():
		return "initial round or selected station should be default"
	if m.MAP_CENTER != Vector2(640.0, 400.0) or m.AU_SCALE_PX != 130.0:
		return "map center or scale mismatch"
	if m.get_stations() != Transit.STATIONS:
		return "stations list must match Transit.STATIONS"
	return "ok"

func test_station_screen_projection_bounds() -> String:
	var m := SolTacticalMap.new()
	for st in Transit.STATIONS:
		var pos := m.get_station_screen_pos(st, 0)
		if pos.x < 0.0 or pos.x > 1280.0 or pos.y < 0.0 or pos.y > 800.0:
			return "station %s out of 1280x800 bounds: %s" % [st, str(pos)]

	# Ceres at 2.767 AU should be ~359.7 px from center
	var ceres_r := m.get_orbit_radius_px("ceres")
	if absf(ceres_r - (2.767 * 130.0)) > 0.01:
		return "ceres orbit radius incorrect: %f" % ceres_r

	# Earth at 1.0 AU should be 130.0 px from center
	var earth_r := m.get_orbit_radius_px("earth")
	if absf(earth_r - 130.0) > 0.01:
		return "earth orbit radius incorrect: %f" % earth_r

	# Luna must have visual screen separation from Earth (32px) to prevent 14px node overlap
	var earth_pos := m.get_station_screen_pos("earth", 0)
	var luna_pos := m.get_station_screen_pos("luna", 0)
	var luna_sep := earth_pos.distance_to(luna_pos)
	if absf(luna_sep - SolTacticalMap.LUNA_SCREEN_SEPARATION_PX) > 0.01:
		return "luna screen separation wrong: %f vs %f" % [luna_sep, SolTacticalMap.LUNA_SCREEN_SEPARATION_PX]

	return "ok"

func test_orbital_motion_across_rounds() -> String:
	var m := SolTacticalMap.new()
	var pos_r0 := m.get_station_screen_pos("mars", 0)
	var pos_r6 := m.get_station_screen_pos("mars", 6)
	var pos_r12 := m.get_station_screen_pos("mars", 12)
	var pos_r24 := m.get_station_screen_pos("mars", 24)

	# Mars has period of 24 rounds, so r24 must equal r0
	if pos_r0.distance_to(pos_r24) > 0.01:
		return "mars orbit period 24 failed to return to start: %s vs %s" % [str(pos_r0), str(pos_r24)]

	# r0 and r12 are opposite sides of the orbit (distance ~ 2 * 1.524 * 130 = 396.24 px)
	var opp_dist := pos_r0.distance_to(pos_r12)
	if absf(opp_dist - (2.0 * 1.524 * 130.0)) > 0.1:
		return "mars opposition distance wrong: %f" % opp_dist

	# Luna orbits Earth with period 4, and Earth orbits Sol with period 12.
	# Luna returns to its exact initial spatial coordinate at lcm(4, 12) = 12 rounds.
	var luna_r0 := m.get_station_screen_pos("luna", 0)
	var luna_r12 := m.get_station_screen_pos("luna", 12)
	if luna_r0.distance_to(luna_r12) > 0.01:
		return "luna period 12 failed to match: %s vs %s" % [str(luna_r0), str(luna_r12)]

	return "ok"

func test_route_endpoints_and_alignment() -> String:
	var m := SolTacticalMap.new()
	var route_data := m.get_route_screen_endpoints("earth:mars", 0)
	if route_data.is_empty():
		return "route data should not be empty"
	if route_data["origin"] != "earth" or route_data["destination"] != "mars":
		return "origin or destination mismatch"
	if bool(route_data["is_belt_route"]):
		return "earth:mars is not a belt route"

	# Earth-Ceres is a belt route
	var belt_data := m.get_route_screen_endpoints("earth:ceres", 0)
	if not bool(belt_data["is_belt_route"]):
		return "earth:ceres must be flagged as belt route"

	# Earth-Mars alignment window is open at round 4-5
	var aligned_data := m.get_route_screen_endpoints("earth:mars", 4)
	if not bool(aligned_data["alignment_active"]):
		return "earth:mars must be alignment active at round 4"

	var unaligned_data := m.get_route_screen_endpoints("earth:mars", 0)
	if bool(unaligned_data["alignment_active"]):
		return "earth:mars must not be alignment active at round 0"

	# Invalid route key returns empty
	var bad_data := m.get_route_screen_endpoints("earth:jupiter", 0)
	if not bad_data.is_empty():
		return "invalid station should yield empty route dict"

	return "ok"

func test_transit_vessel_interpolation() -> String:
	var m := SolTacticalMap.new()
	var start_pos := m.get_station_screen_pos("earth", 0)
	var end_pos := m.get_station_screen_pos("mars", 0)

	var p0 := m.get_transit_vessel_screen_pos("earth", "mars", 0.0, 0)
	var p1 := m.get_transit_vessel_screen_pos("earth", "mars", 1.0, 0)
	var p_mid := m.get_transit_vessel_screen_pos("earth", "mars", 0.5, 0)

	if p0.distance_to(start_pos) > 0.01:
		return "progress 0.0 must match start position"
	if p1.distance_to(end_pos) > 0.01:
		return "progress 1.0 must match end position"
	if p_mid.distance_to((start_pos + end_pos) * 0.5) > 0.01:
		return "progress 0.5 must match midpoint"

	return "ok"

func test_station_selection_and_hit_test() -> String:
	var m := SolTacticalMap.new()
	var selected: Array = []
	m.station_selected.connect(func(s): selected.append(s))

	if not m.select_station("ceres"):
		return "select_station(ceres) failed"
	if m.selected_station != "ceres" or selected != ["ceres"]:
		return "selected_station or signal mismatch"

	# Hit test on ceres screen pos
	var ceres_pos := m.get_station_screen_pos("ceres")
	var hit := m.hit_test_station(ceres_pos)
	if hit != "ceres":
		return "hit_test failed at ceres pos, got: %s" % hit

	# Hit test on Earth and Luna independently (32px separation guarantees distinct hits)
	var earth_pos := m.get_station_screen_pos("earth")
	var luna_pos := m.get_station_screen_pos("luna")
	if m.hit_test_station(earth_pos) != "earth":
		return "hit_test on earth pos did not return earth"
	if m.hit_test_station(luna_pos) != "luna":
		return "hit_test on luna pos did not return luna"

	# Hit test far away in empty space
	var empty_hit := m.hit_test_station(Vector2(50.0, 50.0), 10.0)
	if not empty_hit.is_empty():
		return "empty space hit should return empty string"

	m.clear_selection()
	if not m.selected_station.is_empty():
		return "clear_selection failed"

	return "ok"

func test_run_controller_binding() -> String:
	var d := DoomsdayClock.new(36000, 0, 0, 0)
	# 60 ticks per round -> 60 ticks at 1/60s step is 1 round
	var rc := RunController.new(null, 1, d, 60)
	var m := SolTacticalMap.new(rc)

	if m.current_round != 0:
		return "initial round should be 0"

	# Advance 60 sub-ticks at 1/60 delta -> exactly 1 round
	for i in 60:
		rc.advance(1.0 / 60.0)

	if rc.get_current_round() != 1 or m.current_round != 1:
		return "map round failed to track controller round: %d vs %d" % [m.current_round, rc.get_current_round()]

	# Advance 30 sub-ticks -> round 1 with 0.5 progress
	for i in 30:
		rc.advance(1.0 / 60.0)

	if m.current_round != 1 or absf(m.round_progress - 0.5) > 0.05:
		return "map round_progress mismatch: %f" % m.round_progress

	m.unbind_controller()
	var saved_round := m.current_round
	for i in 60:
		rc.advance(1.0 / 60.0)

	if m.current_round != saved_round:
		return "unbound map should not advance with controller"

	return "ok"

func test_to_dict_serialization() -> String:
	var m := SolTacticalMap.new(null, 5)
	m.select_station("mars")
	var d := m.to_dict()

	if d["current_round"] != 5 or d["selected_station"] != "mars":
		return "serialization fields wrong"
	if d["viewport"] != [1280.0, 800.0] or d["map_center"] != [640.0, 400.0]:
		return "viewport or center mismatch"
	var stations: Dictionary = d["stations"]
	if stations.size() != 4 or not stations.has("mars"):
		return "station dictionary serialization missing entries"
	if not bool(stations["mars"]["selected"]):
		return "mars should be marked selected"

	return "ok"
