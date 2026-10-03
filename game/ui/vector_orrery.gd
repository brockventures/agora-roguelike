class_name VectorOrrery
extends RefCounted
## Vector Orbital Orrery Radar for Agora Roguelike (#23).
##
## Stylized retro-futuristic CRT vector display and planetary radar projection
## optimized for Steam Deck 1280x800 resolution:
## - Concentric vector orbit rings (Sol, Earth, Luna, Mars, Ceres)
## - Continuous rotating radar sweep beam with angular velocity & cycle telemetry
## - Dynamic blip illumination & phosphor decay tracking upon beam intersection
## - Synodic alignment corridor vectors connecting aligned celestial nodes
## - Phosphor color presets (Amber P1, Green P31, Cyan Mil-Spec, Mono White)
## - Configurable CRT shader uniform generation for Godot ShaderMaterial

signal sweep_completed(cycle_count: int)
signal blip_detected(blip_id: String, position: Vector2)
signal preset_changed(preset_name: String)

const VIEWPORT_WIDTH: float = 1280.0
const VIEWPORT_HEIGHT: float = 800.0

## Default center matching the 880x672 tactical map panel in OrbitalHUD
const DEFAULT_CENTER: Vector2 = Vector2(440.0, 400.0)

## Radar radius in screen pixels, bounded to the tactical panel (covers Ceres ~360px)
const RADAR_MAX_RANGE_PX: float = 380.0

## Default sweep speed: 1 full 360-degree rotation per 6.0 seconds (TAU / 6.0)
const DEFAULT_SWEEP_SPEED_RAD_PER_SEC: float = 1.0471975512
const RADAR_BEAM_WIDTH_RAD: float = 0.15

## Phosphor decay duration in seconds
const PHOSPHOR_DECAY_TIME_SEC: float = 2.5

## Supported Color Presets
const PRESET_GREEN_P31: String = "GREEN_P31"
const PRESET_AMBER_P1: String = "AMBER_P1"
const PRESET_CYAN_MIL_SPEC: String = "CYAN_MIL_SPEC"
const PRESET_MONOCHROME_WHITE: String = "MONOCHROME_WHITE"

const PRESETS: Array[String] = [
	PRESET_GREEN_P31,
	PRESET_AMBER_P1,
	PRESET_CYAN_MIL_SPEC,
	PRESET_MONOCHROME_WHITE
]

var tactical_map: SolTacticalMap = null
var controller: RunController = null

var center: Vector2 = DEFAULT_CENTER
var radar_range_px: float = RADAR_MAX_RANGE_PX
var sweep_angle_rad: float = 0.0
var sweep_speed_rad_per_sec: float = DEFAULT_SWEEP_SPEED_RAD_PER_SEC
var sweep_cycle_count: int = 0

var current_preset: String = PRESET_GREEN_P31
var crt_enabled: bool = true

## Tracking blip illumination levels [0.0..1.0] and decay
var blip_illuminations: Dictionary = {}

## Custom CRT uniform overrides
var crt_param_overrides: Dictionary = {}

func _init(p_tactical_map: SolTacticalMap = null, p_controller: RunController = null) -> void:
	if p_tactical_map != null:
		bind_tactical_map(p_tactical_map)
	if p_controller != null:
		bind_controller(p_controller)

	# Initialize default blip illuminations for all stations + Sol
	blip_illuminations["sol"] = 1.0
	for st in Transit.STATIONS:
		blip_illuminations[st] = 0.2

func bind_tactical_map(tm: SolTacticalMap) -> void:
	tactical_map = tm

func unbind_tactical_map() -> void:
	tactical_map = null

func bind_controller(rc: RunController) -> void:
	controller = rc

func unbind_controller() -> void:
	controller = null

## Sets the active phosphor color palette preset.
func set_preset(preset_name: String) -> bool:
	var up := preset_name.to_upper().strip_edges()
	if not PRESETS.has(up):
		return false
	if current_preset == up:
		return true
	current_preset = up
	preset_changed.emit(current_preset)
	return true

## Returns palette color mappings for rendering and shader uniforms.
func get_palette(preset_name: String = "") -> Dictionary:
	var target := current_preset if preset_name.is_empty() else preset_name.to_upper()
	match target:
		PRESET_AMBER_P1:
			return {
				"name": PRESET_AMBER_P1,
				"primary": Color(1.0, 0.72, 0.12, 1.0),
				"primary_dim": Color(0.55, 0.38, 0.06, 0.6),
				"background": Color(0.04, 0.03, 0.01, 1.0),
				"grid": Color(0.35, 0.22, 0.04, 0.35),
				"sweep_beam": Color(1.0, 0.88, 0.35, 0.9),
				"alert": Color(1.0, 0.25, 0.15, 1.0),
				"phosphor_tint": [1.0, 0.82, 0.4, 1.0]
			}
		PRESET_CYAN_MIL_SPEC:
			return {
				"name": PRESET_CYAN_MIL_SPEC,
				"primary": Color(0.18, 0.88, 1.0, 1.0),
				"primary_dim": Color(0.08, 0.42, 0.52, 0.6),
				"background": Color(0.01, 0.03, 0.05, 1.0),
				"grid": Color(0.06, 0.28, 0.38, 0.35),
				"sweep_beam": Color(0.55, 0.95, 1.0, 0.9),
				"alert": Color(1.0, 0.25, 0.2, 1.0),
				"phosphor_tint": [0.65, 0.92, 1.0, 1.0]
			}
		PRESET_MONOCHROME_WHITE:
			return {
				"name": PRESET_MONOCHROME_WHITE,
				"primary": Color(0.92, 0.95, 0.98, 1.0),
				"primary_dim": Color(0.45, 0.48, 0.52, 0.6),
				"background": Color(0.02, 0.02, 0.03, 1.0),
				"grid": Color(0.25, 0.28, 0.32, 0.35),
				"sweep_beam": Color(1.0, 1.0, 1.0, 0.9),
				"alert": Color(1.0, 0.3, 0.25, 1.0),
				"phosphor_tint": [0.95, 0.97, 1.0, 1.0]
			}
		_:
			# Default GREEN_P31
			return {
				"name": PRESET_GREEN_P31,
				"primary": Color(0.25, 1.0, 0.45, 1.0),
				"primary_dim": Color(0.12, 0.52, 0.22, 0.6),
				"background": Color(0.01, 0.04, 0.02, 1.0),
				"grid": Color(0.08, 0.36, 0.16, 0.35),
				"sweep_beam": Color(0.65, 1.0, 0.72, 0.9),
				"alert": Color(1.0, 0.25, 0.2, 1.0),
				"phosphor_tint": [0.72, 1.0, 0.8, 1.0]
			}

## Advance radar sweep beam and update blip detections and phosphor decay.
func advance_sweep(delta_sec: float) -> float:
	if delta_sec <= 0.0:
		return sweep_angle_rad

	var old_angle: float = sweep_angle_rad
	var swept: float = sweep_speed_rad_per_sec * delta_sec
	var laps: int = floori((old_angle + swept) / TAU)
	if laps > 0:
		sweep_cycle_count += laps
		sweep_completed.emit(sweep_cycle_count)
	sweep_angle_rad = fposmod(old_angle + swept, TAU)

	# Phosphor illumination decay
	var decay_factor: float = clampf(delta_sec / PHOSPHOR_DECAY_TIME_SEC, 0.0, 1.0)
	for key in blip_illuminations.keys():
		var min_level: float = 0.3 if key == "sol" else 0.15
		blip_illuminations[key] = maxf(min_level, blip_illuminations[key] - (decay_factor * 0.85))

	# Check intersections with celestial blips (full sweep covers all blips)
	var full_sweep: bool = (swept >= TAU)
	var blips := get_celestial_blips()
	for b in blips:
		var b_angle: float = fposmod(float(b["angle_rad"]), TAU)
		if full_sweep or _is_angle_between(b_angle, old_angle, sweep_angle_rad):
			var b_id: String = b["id"]
			blip_illuminations[b_id] = 1.0
			blip_detected.emit(b_id, b["screen_pos"])

	return sweep_angle_rad

func set_sweep_angle(angle_rad: float) -> void:
	sweep_angle_rad = fposmod(angle_rad, TAU)

func _is_angle_between(target: float, start: float, end: float) -> bool:
	if start <= end:
		return target >= start and target <= end
	else:
		# Wrapped past TAU
		return target >= start or target <= end

## Generates concentric vector orbit tracks for all Sol System stations.
func get_orbit_rings() -> Array[Dictionary]:
	var rings: Array[Dictionary] = []
	var palette := get_palette()
	for st in Transit.STATIONS:
		var au_radius: float = Transit.get_station_orbital_radius(st)
		var scale_px: float = SolTacticalMap.AU_SCALE_PX if tactical_map == null else tactical_map.AU_SCALE_PX
		var r_px: float = au_radius * scale_px
		rings.append({
			"station_id": st,
			"radius_px": r_px,
			"center": center,
			"color": palette["grid"],
			"width": 1.2,
			"segments": 64
		})
	return rings

## Generates concentric range rings with distance labels.
func get_range_rings(count: int = 4) -> Array[Dictionary]:
	var rings: Array[Dictionary] = []
	var palette := get_palette()
	var step: float = radar_range_px / float(count)
	for i in range(1, count + 1):
		var r: float = step * float(i)
		var au_equiv: float = r / (SolTacticalMap.AU_SCALE_PX if tactical_map == null else tactical_map.AU_SCALE_PX)
		rings.append({
			"ring_index": i,
			"radius_px": r,
			"center": center,
			"au_label": "%.2f AU" % au_equiv,
			"color": palette["grid"],
			"width": 1.0 if i < count else 1.8
		})
	return rings

## Returns all celestial and station blip positions, vectors, and illumination.
func get_celestial_blips() -> Array[Dictionary]:
	var blips: Array[Dictionary] = []
	var cur_round: int = controller.get_current_round() if controller != null else (tactical_map.current_round if tactical_map != null else 0)

	# Sol Beacon
	blips.append({
		"id": "sol",
		"name": "SOL",
		"type": "STAR",
		"screen_pos": center,
		"angle_rad": 0.0,
		"distance_px": 0.0,
		"illumination": blip_illuminations.get("sol", 1.0),
		"is_selected": false
	})

	for st in Transit.STATIONS:
		var pos: Vector2
		if tactical_map != null:
			# Shift tactical map position relative to custom center if needed
			var raw_pos := tactical_map.get_station_screen_pos(st)
			pos = center + (raw_pos - SolTacticalMap.MAP_CENTER)
		else:
			var au_pos := Transit.get_station_position(st, float(cur_round))
			pos = center + Vector2(au_pos.x * SolTacticalMap.AU_SCALE_PX, -au_pos.y * SolTacticalMap.AU_SCALE_PX)

		var delta := pos - center
		var dist: float = delta.length()
		var angle: float = fposmod(atan2(delta.y, delta.x), TAU)
		var is_sel: bool = (tactical_map != null and tactical_map.selected_station == st)

		blips.append({
			"id": st,
			"name": st.to_upper(),
			"type": "MOON" if st == "luna" else "PLANET",
			"screen_pos": pos,
			"angle_rad": angle,
			"distance_px": dist,
			"illumination": blip_illuminations.get(st, 0.2),
			"is_selected": is_sel
		})

	return blips

## Generates active synodic alignment corridor vectors.
func get_alignment_corridor_vectors() -> Array[Dictionary]:
	var corridors: Array[Dictionary] = []
	var cur_round: int = controller.get_current_round() if controller != null else (tactical_map.current_round if tactical_map != null else 0)
	var windows := Transit.get_alignment_windows(cur_round)
	var palette := get_palette()

	var blip_map: Dictionary = {}
	for b in get_celestial_blips():
		blip_map[b["id"]] = b["screen_pos"]

	for w in windows:
		if bool(w.get("is_active", false)):
			var routes: Array = w.get("routes", [])
			for pair in routes:
				if pair.size() == 2:
					var o: String = pair[0]
					var d: String = pair[1]
					if blip_map.has(o) and blip_map.has(d):
						corridors.append({
							"origin": o,
							"destination": d,
							"start_pos": blip_map[o],
							"end_pos": blip_map[d],
							"color": palette["sweep_beam"],
							"width": 2.0,
							"pulse_active": true
						})
	return corridors

## Returns geometry describing the rotating radar sweep line and beam cone.
func get_radar_sweep_beam() -> Dictionary:
	var palette := get_palette()
	var dir := Vector2(cos(sweep_angle_rad), sin(sweep_angle_rad))
	var end_p := center + (dir * radar_range_px)
	return {
		"origin": center,
		"end_pos": end_p,
		"angle_rad": sweep_angle_rad,
		"beam_width_rad": RADAR_BEAM_WIDTH_RAD,
		"length_px": radar_range_px,
		"color": palette["sweep_beam"],
		"width": 2.0
	}

## Compiles dictionary of CRT shader uniforms ready for ShaderMaterial.
func get_crt_shader_uniforms() -> Dictionary:
	var pal := get_palette()
	var uniforms: Dictionary = {
		"enabled": crt_enabled,
		"scanline_count": 400.0,
		"scanline_intensity": 0.25,
		"curvature": 0.03,
		"vignette_intensity": 0.4,
		"vignette_opacity": 0.5,
		"aberration_amount": 0.003,
		"phosphor_glow": 0.18,
		"flicker_speed": 15.0,
		"flicker_intensity": 0.012,
		"phosphor_tint": pal["phosphor_tint"]
	}

	# Apply overrides
	for k in crt_param_overrides.keys():
		uniforms[k] = crt_param_overrides[k]

	return uniforms

func set_crt_param(param_name: String, value: Variant) -> void:
	crt_param_overrides[param_name] = value

func reset_crt_params() -> void:
	crt_param_overrides.clear()

## Export snapshot state for telemetry, tests, or inspection.
func to_dict() -> Dictionary:
	return {
		"viewport": [VIEWPORT_WIDTH, VIEWPORT_HEIGHT],
		"center": [center.x, center.y],
		"radar_range_px": radar_range_px,
		"sweep_angle_rad": sweep_angle_rad,
		"sweep_cycle_count": sweep_cycle_count,
		"current_preset": current_preset,
		"palette": get_palette(),
		"crt_enabled": crt_enabled,
		"crt_shader_uniforms": get_crt_shader_uniforms(),
		"orbit_rings_count": get_orbit_rings().size(),
		"range_rings_count": get_range_rings().size(),
		"celestial_blips": get_celestial_blips(),
		"alignment_corridors_count": get_alignment_corridor_vectors().size(),
		"sweep_beam": get_radar_sweep_beam()
	}
