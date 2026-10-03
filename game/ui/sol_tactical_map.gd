class_name SolTacticalMap
extends RefCounted
## 1280x800 Astrodynamics Tactical Map projection for Agora Roguelike (#21).
##
## Projects the Sol System simulation (planets, stations, shipping lanes,
## alignment corridors, and fleet transit positions) into a 1280x800 native
## Steam Deck screen space.
##
## Binds to RunController (#10, PR 2) to observe simulation ticks and station states.

signal station_selected(station_id: String)
signal station_hovered(station_id: String)
signal round_advanced(round_num: int)

const VIEWPORT_WIDTH: float = 1280.0
const VIEWPORT_HEIGHT: float = 800.0
const MAP_CENTER: Vector2 = Vector2(640.0, 400.0)

## Scale factor converting AU coordinates to screen pixels.
## Ceres at 2.767 AU projects to ~359.7px, comfortably within the 400px vertical half-height.
const AU_SCALE_PX: float = 130.0

## Visual radius in pixels for celestial body / station icons.
const STATION_NODE_RADIUS_PX: float = 14.0
const SOL_NODE_RADIUS_PX: float = 24.0

var controller: RunController = null
var current_round: int = 0
var selected_station: String = ""

var _tick_callable: Callable

func _init(p_controller: RunController = null, p_initial_round: int = 0) -> void:
	current_round = maxi(0, p_initial_round)
	if p_controller != null:
		bind_controller(p_controller)

func bind_controller(rc: RunController) -> void:
	unbind_controller()
	controller = rc
	if controller != null and controller.sim_clock != null:
		_tick_callable = Callable(self, "_on_clock_ticked")
		controller.sim_clock.sub_ticked.connect(_tick_callable)
		current_round = controller.sim_clock.total_ticks

func unbind_controller() -> void:
	if controller != null and controller.sim_clock != null:
		if _tick_callable.is_valid() and controller.sim_clock.sub_ticked.is_connected(_tick_callable):
			controller.sim_clock.sub_ticked.disconnect(_tick_callable)
	controller = null

func _on_clock_ticked(total_ticks: int) -> void:
	set_round(total_ticks)

func set_round(round_num: int) -> void:
	var old_round := current_round
	current_round = maxi(0, round_num)
	if current_round != old_round:
		round_advanced.emit(current_round)

## Returns screen pixel position for a given station at the current (or specified) round.
func get_station_screen_pos(station_id: String, round_num: int = -1) -> Vector2:
	var r := current_round if round_num < 0 else maxi(0, round_num)
	var au_pos := Transit.get_station_position(station_id, r)
	# Screen Y is inverted from Cartesian space
	return MAP_CENTER + Vector2(au_pos.x * AU_SCALE_PX, -au_pos.y * AU_SCALE_PX)

## Returns the orbital radius in screen pixels for drawing concentric orbital track rings.
func get_orbit_radius_px(station_id: String) -> float:
	var au_radius := Transit.get_station_orbital_radius(station_id)
	return au_radius * AU_SCALE_PX

## Returns all stations present in the active simulation.
func get_stations() -> Array[String]:
	return Transit.STATIONS.duplicate()

## Returns route endpoints and alignment status in screen coordinates.
func get_route_screen_endpoints(route_key: String, round_num: int = -1) -> Dictionary:
	var r := current_round if round_num < 0 else maxi(0, round_num)
	var parts := route_key.to_lower().split(":")
	if parts.size() != 2:
		return {}
	var origin: String = parts[0]
	var destination: String = parts[1]
	if not (origin in Transit.STATIONS) or not (destination in Transit.STATIONS):
		return {}

	var start_pos := get_station_screen_pos(origin, r)
	var end_pos := get_station_screen_pos(destination, r)
	var distance_px: float = start_pos.distance_to(end_pos)

	# Check active alignment corridors
	var alignment_active: bool = is_route_aligned(origin, destination, r)
	var is_belt: bool = (route_key in Transit.BELT_ROUTES)

	return {
		"route_key": route_key,
		"origin": origin,
		"destination": destination,
		"start_pos": start_pos,
		"end_pos": end_pos,
		"distance_px": distance_px,
		"alignment_active": alignment_active,
		"is_belt_route": is_belt,
	}

## Checks if an origin-destination pair is currently within an active synodic alignment window.
func is_route_aligned(origin: String, destination: String, round_num: int = -1) -> bool:
	var r := current_round if round_num < 0 else maxi(0, round_num)
	var windows := Transit.get_alignment_windows(r)
	for w in windows:
		if bool(w.get("is_active", false)):
			var routes: Array = w.get("routes", [])
			for pair in routes:
				if pair.size() == 2 and pair[0] == origin and pair[1] == destination:
					return true
	return false

## Computes the screen position of a transit vessel along a shipping lane.
## progress_ratio is clamped [0.0, 1.0].
func get_transit_vessel_screen_pos(origin: String, destination: String, progress_ratio: float, round_num: int = -1) -> Vector2:
	var start_pos := get_station_screen_pos(origin, round_num)
	var end_pos := get_station_screen_pos(destination, round_num)
	var t := clampf(progress_ratio, 0.0, 1.0)
	return start_pos.lerp(end_pos, t)

## Selects a station for camera focus or opening the trading overlay.
func select_station(station_id: String) -> bool:
	var s := station_id.to_lower().strip_edges()
	if not (s in Transit.STATIONS):
		return false
	selected_station = s
	station_selected.emit(selected_station)
	return true

func clear_selection() -> void:
	selected_station = ""

## Returns true if a screen-space coordinate intersects a station's clickable node radius.
func hit_test_station(screen_pos: Vector2, tolerance_px: float = 20.0) -> String:
	for st in Transit.STATIONS:
		var pos := get_station_screen_pos(st)
		if pos.distance_to(screen_pos) <= tolerance_px:
			return st
	return ""

## Export state representation for serialization or debug inspection.
func to_dict() -> Dictionary:
	var station_nodes: Dictionary = {}
	for st in Transit.STATIONS:
		station_nodes[st] = {
			"screen_pos": [get_station_screen_pos(st).x, get_station_screen_pos(st).y],
			"orbit_radius_px": get_orbit_radius_px(st),
			"selected": (st == selected_station),
		}
	return {
		"current_round": current_round,
		"selected_station": selected_station,
		"viewport": [VIEWPORT_WIDTH, VIEWPORT_HEIGHT],
		"map_center": [MAP_CENTER.x, MAP_CENTER.y],
		"au_scale_px": AU_SCALE_PX,
		"stations": station_nodes,
	}
