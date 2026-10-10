extends RefCounted
## Unit tests for VectorOrrery Radar and CRT Retro Shaders (#23).

func test_init_defaults() -> String:
	var orrery := VectorOrrery.new()
	if orrery == null:
		return "Failed to instantiate VectorOrrery"
	if orrery.current_preset != VectorOrrery.PRESET_GREEN_P31:
		return "Default preset should be GREEN_P31, got %s" % orrery.current_preset
	if orrery.center != VectorOrrery.DEFAULT_CENTER:
		return "Default center mismatch: %s" % str(orrery.center)
	if orrery.radar_range_px != VectorOrrery.RADAR_MAX_RANGE_PX:
		return "Default radar_range_px mismatch: %f" % orrery.radar_range_px
	if orrery.sweep_angle_rad != 0.0:
		return "Initial sweep_angle_rad should be 0.0"
	if orrery.crt_enabled:
		return "CRT filter should be off by default (#105)"

	var snap: Dictionary = orrery.to_dict()
	if snap["current_preset"] != "GREEN_P31":
		return "to_dict snapshot mismatch on preset"
	if snap["viewport"] != [1280.0, 800.0]:
		return "Viewport should be 1280x800"
	return "ok"

func test_presets_and_palettes() -> String:
	var orrery := VectorOrrery.new()
	var signal_received: Array = []
	orrery.preset_changed.connect(func(p): signal_received.append(p))

	# Test Amber P1
	if not orrery.set_preset("AMBER_P1") or orrery.current_preset != "AMBER_P1":
		return "Failed to switch to AMBER_P1 preset"
	var pal_amber := orrery.get_palette()
	if pal_amber["name"] != "AMBER_P1":
		return "Palette name mismatch for AMBER_P1"
	if pal_amber["primary"] != Color(1.0, 0.72, 0.12, 1.0):
		return "Amber primary color mismatch"

	# Test Cyan Mil-Spec
	if not orrery.set_preset("cyan_mil_spec") or orrery.current_preset != "CYAN_MIL_SPEC":
		return "Failed to switch to CYAN_MIL_SPEC preset (case-insensitive)"
	var pal_cyan := orrery.get_palette()
	if pal_cyan["name"] != "CYAN_MIL_SPEC":
		return "Palette name mismatch for CYAN_MIL_SPEC"

	# Test Monochrome White
	if not orrery.set_preset("MONOCHROME_WHITE"):
		return "Failed to switch to MONOCHROME_WHITE"

	# Test invalid preset rejection
	if orrery.set_preset("MAGENTA_VAPORWAVE"):
		return "set_preset should reject unsupported preset"
	if orrery.current_preset != "MONOCHROME_WHITE":
		return "Preset should not change on rejected preset"

	if signal_received != ["AMBER_P1", "CYAN_MIL_SPEC", "MONOCHROME_WHITE"]:
		return "preset_changed signal sequence mismatch: %s" % str(signal_received)
	return "ok"

func test_orbit_rings_generation() -> String:
	var orrery := VectorOrrery.new()
	var rings := orrery.get_orbit_rings()
	if rings.size() != Transit.STATIONS.size():
		return "Expected %d orbit rings, got %d" % [Transit.STATIONS.size(), rings.size()]

	# Earth, Luna, Mars, Ceres radii must increase monotonically (except Luna which shares Earth orbit)
	var station_radii: Dictionary = {}
	for r in rings:
		station_radii[r["station_id"]] = r["radius_px"]
		if r["radius_px"] <= 0.0:
			return "Orbit ring radius must be positive: %s" % str(r)
		if r["center"] != orrery.center:
			return "Orbit ring center must match orrery center"

	if station_radii["mars"] <= station_radii["earth"]:
		return "Mars orbit radius must be greater than Earth orbit radius"
	if station_radii["ceres"] <= station_radii["mars"]:
		return "Ceres orbit radius must be greater than Mars orbit radius"
	return "ok"

func test_range_rings() -> String:
	var orrery := VectorOrrery.new()
	var rings := orrery.get_range_rings(4)
	if rings.size() != 4:
		return "Expected 4 range rings, got %d" % rings.size()

	var prev_r: float = 0.0
	for i in range(rings.size()):
		var r_item = rings[i]
		var r_px: float = r_item["radius_px"]
		if r_px <= prev_r:
			return "Range rings must be strictly expanding: %f <= %f" % [r_px, prev_r]
		prev_r = r_px
		if not r_item.has("au_label") or not r_item["au_label"].ends_with("AU"):
			return "Range ring missing AU label: %s" % str(r_item)
	return "ok"

func test_radar_sweep_advancement_and_cycles() -> String:
	var orrery := VectorOrrery.new()
	var cycle_signals: Array = []
	orrery.sweep_completed.connect(func(c): cycle_signals.append(c))

	# Advance by 3 seconds (half rotation at TAU / 6.0 rad/sec)
	var half_time: float = 3.0
	var angle1 := orrery.advance_sweep(half_time)
	var expected_half: float = VectorOrrery.DEFAULT_SWEEP_SPEED_RAD_PER_SEC * half_time
	if absf(angle1 - expected_half) > 0.01:
		return "Sweep angle after 3.0s should be ~PI (%f), got %f" % [expected_half, angle1]
	if orrery.sweep_cycle_count != 0:
		return "Cycle count should still be 0 before full revolution"

	# Advance another 3.1 seconds (crossing TAU = 6.28318)
	var angle2 := orrery.advance_sweep(3.1)
	if orrery.sweep_cycle_count != 1:
		return "Cycle count should be 1 after crossing TAU, got %d" % orrery.sweep_cycle_count
	if cycle_signals != [1]:
		return "sweep_completed signal not emitted properly"

	return "ok"

func test_blip_detection_and_illumination() -> String:
	# Use round 3 where stations are orbitally dispersed across quadrants
	var tm := SolTacticalMap.new(null, 3)
	var orrery := VectorOrrery.new(tm)
	var detected: Array = []
	orrery.blip_detected.connect(func(id, pos): detected.append(id))

	# 1. Multi-lap suspend/resume delta (18.0s = 3 full revolutions at TAU / 6.0 rad/s)
	# Marvin catch: verify all stations illuminate even when delta spans multiple TAU
	orrery.advance_sweep(18.0)
	if orrery.sweep_cycle_count != 3:
		return "Multi-lap suspend delta should advance sweep_cycle_count to 3, got %d" % orrery.sweep_cycle_count

	for st in Transit.STATIONS:
		if not detected.has(st):
			return "Station %s was not detected during multi-lap sweep" % st
		var illum: float = orrery.blip_illuminations.get(st, 0.0)
		if illum < 0.95:
			return "Station %s illumination should be at peak (1.0), got %f" % [st, illum]

	# 2. Targeted arc test at round 3: verify selective detection
	# Reset orrery to angle 0.0 and clear detections
	orrery.set_sweep_angle(0.0)
	detected.clear()

	# Find a blip with angle > 1.5 rad at round 3
	var blips := orrery.get_celestial_blips()
	var outside_blip_id := ""
	for b in blips:
		if b["id"] != "sol" and float(b["angle_rad"]) > 1.5:
			outside_blip_id = b["id"]
			break

	# Advance small arc [0.0, 0.5] rad (~0.477s)
	orrery.advance_sweep(0.477)
	if not outside_blip_id.is_empty() and detected.has(outside_blip_id):
		return "Blip %s at angle > 1.5 should NOT be detected in [0.0, 0.5] rad arc" % outside_blip_id

	# 3. Phosphor decay test
	var sol_illum: float = float(orrery.blip_illuminations.get("sol", 0.0))
	if sol_illum < 0.3:
		return "Sol beacon illumination decayed below floor"

	return "ok"

func test_alignment_corridor_vectors() -> String:
	var orrery := VectorOrrery.new()
	var corridors := orrery.get_alignment_corridor_vectors()
	# Corridors should return an Array of dictionaries
	if not (corridors is Array):
		return "corridors should be an Array"

	# In round 0, check if alignment windows exist
	var windows := Transit.get_alignment_windows(0)
	var active_count := 0
	for w in windows:
		if bool(w.get("is_active", false)):
			active_count += w.get("routes", []).size()

	if corridors.size() != active_count:
		return "Alignment corridors count mismatch: expected %d, got %d" % [active_count, corridors.size()]
	return "ok"

func test_crt_shader_uniforms() -> String:
	var orrery := VectorOrrery.new()
	orrery.set_preset("AMBER_P1")
	var u := orrery.get_crt_shader_uniforms()

	var required_keys := [
		"enabled", "scanline_count", "scanline_intensity", "curvature",
		"vignette_intensity", "vignette_opacity", "aberration_amount",
		"phosphor_glow", "flicker_speed", "flicker_intensity", "phosphor_tint"
	]
	for k in required_keys:
		if not u.has(k):
			return "Missing required shader uniform key: %s" % k

	if u["scanline_count"] != 400.0:
		return "Default scanline_count should be 400.0 (800p height target)"
	if u["phosphor_tint"] != [1.0, 0.82, 0.4, 1.0]:
		return "Amber phosphor tint mismatch: %s" % str(u["phosphor_tint"])

	# Test overrides
	orrery.set_crt_param("scanline_intensity", 0.45)
	var u_mod := orrery.get_crt_shader_uniforms()
	if u_mod["scanline_intensity"] != 0.45:
		return "Shader param override failed to apply"

	orrery.reset_crt_params()
	var u_reset := orrery.get_crt_shader_uniforms()
	if u_reset["scanline_intensity"] != 0.25:
		return "reset_crt_params failed to restore default"

	return "ok"

func test_shader_file_integrity() -> String:
	var shader_path := "res://shaders/crt_retro.gdshader"
	if not FileAccess.file_exists(shader_path):
		return "CRT shader file does not exist at %s" % shader_path

	var file := FileAccess.open(shader_path, FileAccess.READ)
	if file == null:
		return "Failed to open shader file %s" % shader_path
	var code := file.get_as_text()
	file.close()

	if not code.begins_with("shader_type canvas_item;"):
		return "Shader must begin with 'shader_type canvas_item;'"
	if not code.contains("uniform float scanline_count"):
		return "Shader missing scanline_count uniform"
	if not code.contains("uniform float curvature"):
		return "Shader missing curvature uniform"
	if not code.contains("uniform float aberration_amount"):
		return "Shader missing aberration_amount uniform"

	# Test Godot resource loader parses the shader successfully
	var res = ResourceLoader.load(shader_path)
	if res == null:
		return "ResourceLoader.load failed to compile %s" % shader_path
	if not (res is Shader):
		return "Loaded resource is not a Godot Shader"

	var mat := ShaderMaterial.new()
	mat.shader = res
	if mat.shader != res:
		return "Failed to bind Shader to ShaderMaterial"

	return "ok"

func test_orbital_hud_integration() -> String:
	var hud := OrbitalHUD.new()
	if hud.vector_orrery == null:
		return "OrbitalHUD did not instantiate vector_orrery"
	if hud.vector_orrery.tactical_map != hud.tactical_map:
		return "vector_orrery tactical_map not bound to hud.tactical_map"

	var snap: Dictionary = hud.to_dict()
	if not snap.has("vector_orrery"):
		return "OrbitalHUD to_dict missing vector_orrery snapshot"
	if snap["crt_preset"] != "GREEN_P31":
		return "OrbitalHUD crt_preset mismatch: %s" % snap.get("crt_preset")

	return "ok"
