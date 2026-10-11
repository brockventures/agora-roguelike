extends RefCounted
## Unit tests for SolTacticalMap projection and coordinate simulation (#21).

func test_init_defaults() -> String:
	var m := SolTacticalMap.new()
	if m.current_round != 0 or not m.selected_station.is_empty():
		return "initial round or selected station should be default"
	if m.MAP_CENTER != Vector2(440.0, 400.0) or m.AU_SCALE_PX != 112.0:
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

	# Display radii (SolTacticalMap.DISPLAY_RADIUS_PX), not AU-linear: Ceres keeps 310.
	if absf(m.get_orbit_radius_px("ceres") - 310.0) > 0.01 or absf(m.get_orbit_radius_px("earth") - 165.0) > 0.01:
		return "display orbit radii wrong"
	for st in ["earth", "mars", "ceres"]:
		var d: float = m.get_station_screen_pos(st, 0).distance_to(SolTacticalMap.MAP_CENTER)
		if absf(d - m.get_orbit_radius_px(st)) > 0.01:
			return "%s is not on its display ring: %f" % [st, d]

	# Luna's orbit is a true circle in panel px, big enough to clear Earth's disc.
	var luna_sep := _panel_dist(m.get_station_screen_pos("earth", 0), m.get_station_screen_pos("luna", 0))
	if absf(luna_sep - SolTacticalMap.LUNA_ORBIT_PX) > 0.01:
		return "luna panel separation wrong: %f vs %f" % [luna_sep, SolTacticalMap.LUNA_ORBIT_PX]

	return "ok"


func _panel_dist(a: Vector2, b: Vector2) -> float:
	var d: Vector2 = a - b
	return Vector2(d.x * HudLayout.MAP_STRETCH.x, d.y * HudLayout.MAP_STRETCH.y).length()

func test_orbital_motion_across_rounds() -> String:
	var m := SolTacticalMap.new()
	var pos_r0 := m.get_station_screen_pos("mars", 0)
	var pos_r6 := m.get_station_screen_pos("mars", 6)
	var pos_r12 := m.get_station_screen_pos("mars", 12)
	var pos_r24 := m.get_station_screen_pos("mars", 24)

	# Mars has period of 24 rounds, so r24 must equal r0
	if pos_r0.distance_to(pos_r24) > 0.01:
		return "mars orbit period 24 failed to return to start: %s vs %s" % [str(pos_r0), str(pos_r24)]

	# r0 and r12 are opposite sides of the orbit (twice its display radius)
	var opp_dist := pos_r0.distance_to(pos_r12)
	if absf(opp_dist - 2.0 * 237.5) > 0.1:
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

	# Live smoothed attachment test: route endpoints must attach to live station positions
	var clock := DoomsdayClock.new(36000, 0, 0, 0)
	var rc := RunController.new(null, 42, clock, {}, 60)
	m.bind_controller(rc)
	for i in 30:
		rc.advance(1.0 / 60.0)
	if absf(m.round_progress - 0.5) > 0.001:
		return "round_progress should be exactly 0.5"
	var live_route := m.get_route_screen_endpoints("earth:mars")
	var live_earth := m.get_station_screen_pos("earth")
	var live_mars := m.get_station_screen_pos("mars")
	if live_route["start_pos"].distance_to(live_earth) > 0.01:
		return "live route start_pos must attach to live earth pos"
	if live_route["end_pos"].distance_to(live_mars) > 0.01:
		return "live route end_pos must attach to live mars pos"

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

	# Live smoothed vessel interpolation test
	var clock := DoomsdayClock.new(36000, 0, 0, 0)
	var rc := RunController.new(null, 42, clock, {}, 60)
	m.bind_controller(rc)
	for i in 30:
		rc.advance(1.0 / 60.0)
	if absf(m.round_progress - 0.5) > 0.001:
		return "round_progress should be exactly 0.5"
	var live_start := m.get_station_screen_pos("earth")
	var live_end := m.get_station_screen_pos("mars")
	var live_mid := m.get_transit_vessel_screen_pos("earth", "mars", 0.5)
	if live_mid.distance_to((live_start + live_end) * 0.5) > 0.01:
		return "live vessel mid must match live station midpoint"
	# Explicit round override snaps to round 0
	var snapped_mid := m.get_transit_vessel_screen_pos("earth", "mars", 0.5, 0)
	if snapped_mid.distance_to(p_mid) > 0.01:
		return "explicit round 0 should snap vessel position"

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
	var rc := RunController.new(null, 1, d, {}, 60)
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
	if d["viewport"] != [1280.0, 800.0] or d["map_center"] != [440.0, 400.0]:
		return "viewport or center mismatch"
	var stations: Dictionary = d["stations"]
	if stations.size() != 4 or not stations.has("mars"):
		return "station dictionary serialization missing entries"
	if not bool(stations["mars"]["selected"]):
		return "mars should be marked selected"

	return "ok"

func test_map_fits_tactical_panel_at_every_round() -> String:
	var m := SolTacticalMap.new()
	var panel := SolTacticalMap.PANEL_RECT
	# Model-space check on the node centre (the drawn map foreshortens y by 0.56 and has its own
	# label bounds), so the margin is the old half-node, not the larger drawn-disc radius.
	var margin := 14.0
	for r in 24:
		for st in Transit.STATIONS:
			var pos := m.get_station_screen_pos(st, r)
			if not panel.grow(-margin).has_point(pos):
				return "%s at round %d is at %s, outside the %s panel" % [st, r, str(pos), str(panel)]
		var ring := m.get_orbit_radius_px("ceres")
		if not panel.grow(-margin).has_point(SolTacticalMap.MAP_CENTER + Vector2(0, -ring)):
			return "ceres orbit ring leaves the panel"
	if SolTacticalMap.PANEL_RECT != OrbitalHUD.TACTICAL_MAP_RECT:
		return "PANEL_RECT drifted from OrbitalHUD.TACTICAL_MAP_RECT"
	return "ok"

func test_station_labels_do_not_overprint_at_round_zero() -> String:
	var m := SolTacticalMap.new()
	var rects: Dictionary = {}
	for st in Transit.STATIONS:
		var pos := m.get_station_screen_pos(st, 0) + SolTacticalMap.get_label_offset(st)
		# Label box: ~9px per glyph at 14pt, 14px tall; the offset is the baseline origin.
		rects[st] = Rect2(pos + Vector2(0, -12), Vector2(9.0 * StationMarket.station_name(st).length(), 14.0))
	for a in Transit.STATIONS:
		for b in Transit.STATIONS:
			if a < b and rects[a].intersects(rects[b]):
				return "labels %s and %s overprint at round 0: %s vs %s" % [a, b, str(rects[a]), str(rects[b])]
		# No label may sit on another station's node either.
		for b in Transit.STATIONS:
			if a != b:
				var node := Rect2(m.get_station_screen_pos(b, 0) - Vector2.ONE * 14.0, Vector2.ONE * 28.0)
				if rects[a].intersects(node):
					return "label %s covers the %s node at round 0" % [a, b]
	return "ok"


## Label boxes the way main.gd draws them: baseline origin at node + offset.
func _label_boxes(m: SolTacticalMap, r: int, fs: int) -> Dictionary:
	var font: Font = ThemeDB.fallback_font
	var offs: Dictionary = m.get_label_offsets(r, fs)
	var boxes: Dictionary = {}
	for st in Transit.STATIONS:
		var text: String = StationMarket.station_name(st).to_upper()
		var sz: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		boxes[st] = Rect2(m.get_station_screen_pos(st, r) + Vector2(offs[st]) + Vector2(0.0, -font.get_ascent(fs)), Vector2(sz.x, font.get_ascent(fs) + font.get_descent(fs)))
	return boxes


func _circle_rect(c: Vector2, rad: float, rect: Rect2) -> bool:
	var n := Vector2(clampf(c.x, rect.position.x, rect.end.x), clampf(c.y, rect.position.y, rect.end.y))
	return n.distance_to(c) < rad


func test_labels_avoid_bodies_and_each_other_every_round() -> String:
	var m := SolTacticalMap.new()
	for fs in [14, 18]:
		for r in 48:
			var boxes: Dictionary = _label_boxes(m, r, fs)
			for a in Transit.STATIONS:
				if not SolTacticalMap.PANEL_RECT.encloses(boxes[a]):
					return "label %s leaves the panel at round %d (size %d): %s" % [a, r, fs, str(boxes[a])]
				if _circle_rect(SolTacticalMap.MAP_CENTER, SolTacticalMap.SOL_NODE_RADIUS_PX, boxes[a]):
					return "label %s covers the Sun at round %d (size %d)" % [a, r, fs]
				for b in Transit.STATIONS:
					if _circle_rect(m.get_station_screen_pos(b, r), SolTacticalMap.STATION_NODE_RADIUS_PX, boxes[a]):
						return "label %s covers the %s disc at round %d (size %d)" % [a, b, r, fs]
					if a < b and boxes[a].intersects(boxes[b]):
						return "labels %s and %s overprint at round %d (size %d)" % [a, b, r, fs]
	return "ok"


func test_earth_label_clears_luna_at_round_one() -> String:
	# Regression: at round 1 Luna sits straight above Earth and its disc covered
	# "KENNEDY ELEVATOR", which the fixed offset put one row above Earth.
	var m := SolTacticalMap.new()
	var box: Rect2 = _label_boxes(m, 1, 14)["earth"]
	if _circle_rect(m.get_station_screen_pos("luna", 1), SolTacticalMap.STATION_NODE_RADIUS_PX, box):
		return "Earth's label still sits under Luna at round 1: %s" % str(box)
	return "ok"


func test_label_offsets_are_deterministic_and_keep_the_round_zero_layout() -> String:
	var m := SolTacticalMap.new()
	if m.get_label_offsets(5, 14) != SolTacticalMap.new().get_label_offsets(5, 14):
		return "same round gave different offsets"
	var zero: Dictionary = m.get_label_offsets(0, 14)
	for st in Transit.STATIONS:
		if zero[st] != SolTacticalMap.get_label_offset(st):
			return "round 0 moved %s's label off its designed spot: %s" % [st, str(zero[st])]
	return "ok"


func test_body_sizes_order_sol_then_earth_and_mars_then_luna_and_ceres() -> String:
	if MapIcons.disc_px("sol") <= MapIcons.disc_px("earth") * 1.5:
		return "Sol is not clearly the biggest body"
	if absf(MapIcons.disc_px("earth") - MapIcons.disc_px("mars")) > 0.01:
		return "Earth and Mars discs differ"
	for small in ["luna", "ceres"]:
		if MapIcons.disc_px(small) >= MapIcons.disc_px("earth"):
			return "%s is not smaller than Earth and Mars" % small
	if MapIcons.depth_scale(-1.0) >= MapIcons.depth_scale(1.0) or MapIcons.depth_scale(1.0) != 1.0:
		return "far bodies must draw slightly smaller than near ones"
	return "ok"


func test_display_phase_spreads_the_bodies_without_touching_the_simulation() -> String:
	var m := SolTacticalMap.new()
	if _panel_dist(m.get_station_screen_pos("earth", 0), m.get_station_screen_pos("mars", 0)) < 100.0:
		return "earth and mars still stack at round 0"
	# Transit (the simulation's positions) stays at its original round-0 angle 0 and AU radius.
	if Transit.get_station_position("mars", 0.0) != Vector2(Transit.ORBITAL_RADII["mars"], 0.0):
		return "Transit positions changed"
	return "ok"


## Panel-space ellipse distance from a point (relative to the Sun) to a display ring.
func _ring_gap(panel_pos: Vector2, ring: String) -> float:
	var r: float = SolTacticalMap.DISPLAY_RADIUS_PX[ring]
	var a: float = r * HudLayout.MAP_STRETCH.x
	var b: float = r * HudLayout.MAP_STRETCH.y
	var f: float = panel_pos.x * panel_pos.x / (a * a) + panel_pos.y * panel_pos.y / (b * b) - 1.0
	return absf(f) / (2.0 * Vector2(panel_pos.x / (a * a), panel_pos.y / (b * b)).length())


func _panel(m: SolTacticalMap, st: String, r: float) -> Vector2:
	var d: Vector2 = m.get_station_screen_pos(st, int(r)) - SolTacticalMap.MAP_CENTER
	return Vector2(d.x * HudLayout.MAP_STRETCH.x, d.y * HudLayout.MAP_STRETCH.y)


func test_discs_and_luna_keep_clear_over_96_rounds() -> String:
	var m := SolTacticalMap.new()
	var radius := {"earth": 22.0, "mars": 22.0, "ceres": 15.0, "luna": 14.0}
	var sun_r: float = 42.0
	for r in 96:
		var pos: Dictionary = {}
		for st in ["earth", "mars", "ceres", "luna"]:
			pos[st] = _panel(m, st, r)
		for a in pos:
			if (pos[a] as Vector2).length() < sun_r + float(radius[a]):
				return "%s overlaps the Sun at round %d" % [a, r]
			for b in pos:
				if a < b and (pos[a] as Vector2).distance_to(pos[b]) < float(radius[a]) + float(radius[b]) + 2.0:
					return "%s and %s discs overlap at round %d (%f px)" % [a, b, r, (pos[a] as Vector2).distance_to(pos[b])]
		# Luna never touches Mars's drawn ring, at any angle (top and bottom included).
		if _ring_gap(pos["luna"], "mars") < float(radius["luna"]):
			return "luna touches Mars's ring at round %d (gap %f)" % [r, _ring_gap(pos["luna"], "mars")]
		# Earth's ring clears the Sun's frame (about 70 px) plus Earth's disc.
		if (pos["earth"] as Vector2).length() < 70.0 + float(radius["earth"]):
			return "earth ring runs into the Sun's frame at round %d" % r
	return "ok"


func test_luna_never_draws_over_the_sun() -> String:
	var m := SolTacticalMap.new()
	for r in 96:
		var d: Vector2 = m.get_station_screen_pos("luna", r) - SolTacticalMap.MAP_CENTER
		if Vector2(d.x * HudLayout.MAP_STRETCH.x, d.y * HudLayout.MAP_STRETCH.y).length() < SolTacticalMap.LUNA_SOL_CLEARANCE_PX - 0.01:
			return "luna crosses the Sun at round %d" % r
	return "ok"
