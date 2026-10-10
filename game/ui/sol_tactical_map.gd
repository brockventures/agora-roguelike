class_name SolTacticalMap
extends RefCounted
## 1280x800 Astrodynamics Tactical Map projection for Agora Roguelike (#21).
##
## Projects the Sol System simulation (planets, stations, shipping lanes,
## alignment corridors, and fleet transit positions) into a 1280x800 native
## Steam Deck screen space.
##
## Binds to RunController (#10, PR 2) to observe simulation rounds and progress.

signal station_selected(station_id: String)
signal station_hovered(station_id: String)
signal round_advanced(round_num: int)

const VIEWPORT_WIDTH: float = 1280.0
const VIEWPORT_HEIGHT: float = 800.0
## Tactical panel rectangle in screen space (matches OrbitalHUD.TACTICAL_MAP_RECT;
## kept literal so this model does not depend on the HUD script).
const PANEL_RECT: Rect2 = Rect2(0.0, 64.0, 880.0, 672.0)
## Centre of the panel: the Sun, and the origin of the projection.
const MAP_CENTER: Vector2 = Vector2(440.0, 400.0)

## Scale factor converting AU coordinates to screen pixels.
## Ceres at 2.767 AU projects to ~310px, so its orbit ring plus node (324px) fits the
## panel's 336px vertical half-height and cannot overdraw the header or ticker.
const AU_SCALE_PX: float = 112.0

## Visual radius in pixels for celestial body / station icons.
const STATION_NODE_RADIUS_PX: float = 14.0
const SOL_NODE_RADIUS_PX: float = 24.0

## Minimum screen separation for Luna to prevent visual overlap and hit-test ambiguity with Earth.
const LUNA_SCREEN_SEPARATION_PX: float = 32.0

var controller: RunController = null
var current_round: int = 0
var round_progress: float = 0.0
var selected_station: String = ""
var smooth_orbit: bool = true

var _sub_tick_callable: Callable
var _round_callable: Callable

func _init(p_controller: RunController = null, p_initial_round: int = 0) -> void:
	current_round = maxi(0, p_initial_round)
	if p_controller != null:
		bind_controller(p_controller)

func bind_controller(rc: RunController) -> void:
	unbind_controller()
	controller = rc
	if controller != null:
		_sub_tick_callable = Callable(self, "_on_controller_sub_ticked")
		_round_callable = Callable(self, "_on_controller_round_advanced")
		if controller.sim_clock != null:
			controller.sim_clock.sub_ticked.connect(_sub_tick_callable)
		controller.round_advanced.connect(_round_callable)
		current_round = controller.get_current_round()
		round_progress = controller.get_round_progress()

func unbind_controller() -> void:
	if controller != null:
		if controller.sim_clock != null and _sub_tick_callable.is_valid() and controller.sim_clock.sub_ticked.is_connected(_sub_tick_callable):
			controller.sim_clock.sub_ticked.disconnect(_sub_tick_callable)
		if _round_callable.is_valid() and controller.round_advanced.is_connected(_round_callable):
			controller.round_advanced.disconnect(_round_callable)
	controller = null

func _on_controller_sub_ticked(_total_ticks: int) -> void:
	if controller != null:
		round_progress = controller.get_round_progress()

func _on_controller_round_advanced(r: int) -> void:
	set_round(r)

func set_round(round_num: int) -> void:
	var old_round := current_round
	current_round = maxi(0, round_num)
	if current_round != old_round:
		round_advanced.emit(current_round)

## Returns screen pixel position for a given station.
## If round_num is negative, uses current simulation state (with smooth interpolation if enabled).
func get_station_screen_pos(station_id: String, round_num: int = -1) -> Vector2:
	var st := station_id.to_lower().strip_edges()
	var effective_r: float
	if round_num >= 0:
		effective_r = float(round_num)
	elif smooth_orbit and controller != null:
		effective_r = float(current_round) + round_progress
	else:
		effective_r = float(current_round)

	if st == "luna":
		var earth_screen := get_station_screen_pos("earth", round_num)
		var lunar_angle: float = (fposmod(effective_r, 4.0) / 4.0) * TAU
		return earth_screen + Vector2(cos(lunar_angle), -sin(lunar_angle)) * LUNA_SCREEN_SEPARATION_PX

	var au_pos := Transit.get_station_position(st, effective_r)
	return MAP_CENTER + Vector2(au_pos.x * AU_SCALE_PX, -au_pos.y * AU_SCALE_PX)

## Offset from a station node to its label origin. Earth, Luna and Mars sit within
## 70px of each other at round 0 and the station names are long, so labels are
## stacked in separate rows instead of all going right: Earth one row above its
## node, Mars two rows above, Luna below, Ceres right.
static func get_label_offset(station_id: String) -> Vector2:
	match station_id.to_lower():
		"earth":
			return Vector2(-24.0, -24.0)
		"luna":
			return Vector2(-8.0, 34.0)
		"mars":
			return Vector2(-8.0, -46.0)
		_:
			return Vector2(18.0, 5.0)

## Returns orbital radius in screen pixels for drawing concentric orbital track rings.
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

	var start_pos := get_station_screen_pos(origin, round_num)
	var end_pos := get_station_screen_pos(destination, round_num)
	var distance_px: float = start_pos.distance_to(end_pos)

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
func get_transit_vessel_screen_pos(origin: String, destination: String, progress_ratio: float, round_num: int = -1) -> Vector2:
	var start_pos := get_station_screen_pos(origin, round_num)
	var end_pos := get_station_screen_pos(destination, round_num)
	var t := clampf(progress_ratio, 0.0, 1.0)
	return start_pos.lerp(end_pos, t)

## The player's own voyage for drawing: {} while docked, otherwise origin,
## destination, progress (0..1), the ship's screen position on its lane, and
## whether the lane crosses the belt (#111). round_num as in get_station_screen_pos.
func get_player_transit(round_num: int = -1) -> Dictionary:
	if controller == null or not controller.is_in_transit():
		return {}
	var info: Dictionary = controller.transit_info()
	var origin: String = str(info["origin"])
	var destination: String = str(info["destination"])
	var progress: float = float(info["progress"])
	return {
		"origin": origin,
		"destination": destination,
		"progress": progress,
		"eta_rounds": int(info["eta_rounds"]),
		"is_belt": bool(info["is_belt"]),
		"pos": get_transit_vessel_screen_pos(origin, destination, progress, round_num),
		"start_pos": get_station_screen_pos(origin, round_num),
		"end_pos": get_station_screen_pos(destination, round_num),
	}

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
## Luna is tested first to prevent Earth's hitbox from absorbing Luna clicks.
func hit_test_station(screen_pos: Vector2, tolerance_px: float = 16.0) -> String:
	# Prioritize Luna since it orbits close to Earth
	var luna_pos := get_station_screen_pos("luna")
	if luna_pos.distance_to(screen_pos) <= tolerance_px:
		return "luna"

	for st in Transit.STATIONS:
		if st == "luna":
			continue
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
		"round_progress": round_progress,
		"selected_station": selected_station,
		"viewport": [VIEWPORT_WIDTH, VIEWPORT_HEIGHT],
		"map_center": [MAP_CENTER.x, MAP_CENTER.y],
		"au_scale_px": AU_SCALE_PX,
		"stations": station_nodes,
	}
