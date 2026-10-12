extends RefCounted
## Unit tests for MapIcons celestial and vessel transit marker illustrations (#73).

func test_celestial_textures_load_for_all_stations_and_sol() -> String:
	MapIcons.clear_cache()
	var bodies: Array[String] = ["sol", "earth", "mars", "luna", "ceres"]
	for b in bodies:
		var tex: Texture2D = MapIcons.texture(b)
		if tex == null:
			return "MapIcons.texture('%s') returned null" % b
		if tex.get_width() <= 0 or tex.get_height() <= 0:
			return "invalid dimensions for celestial body '%s'" % b
	return "ok"


func test_vessel_textures_load_for_all_five_archetypes() -> String:
	MapIcons.clear_cache()
	var archetypes: Array[String] = [
		FleetView.HAULER,
		FleetView.INTERCEPTOR,
		FleetView.FREIGHTER,
		FleetView.SCOUT,
		FleetView.SCRAP_BARGE,
	]
	for a in archetypes:
		var tex: Texture2D = MapIcons.vessel_texture(a)
		if tex == null:
			return "MapIcons.vessel_texture('%s') returned null" % a
		var w: int = tex.get_width()
		var h: int = tex.get_height()
		if w <= 0 or h <= 0:
			return "invalid dimensions for vessel archetype '%s': %dx%d" % [a, w, h]
		if w != h:
			return "vessel transit marker must be 1:1 aspect ratio, got %dx%d for '%s'" % [w, h, a]
	return "ok"


func test_vessel_texture_case_insensitivity_and_alias() -> String:
	MapIcons.clear_cache()
	var tex_upper: Texture2D = MapIcons.vessel_texture("FREIGHTER")
	var tex_lower: Texture2D = MapIcons.vessel_texture("freighter")
	if tex_upper == null or tex_lower == null:
		return "failed to load freighter textures"
	if tex_upper != tex_lower:
		return "vessel_texture should return identical cached resource for case variants"
	return "ok"


func test_vessel_texture_missing_or_unknown_fallback() -> String:
	MapIcons.clear_cache()
	var tex_unknown: Texture2D = MapIcons.vessel_texture("UNKNOWN_SHIP")
	# Unknown archetypes gracefully resolve to default hauler texture
	if tex_unknown == null:
		return "unknown archetype should fall back to hauler texture"
	var tex_hauler: Texture2D = MapIcons.vessel_texture(FleetView.HAULER)
	if tex_unknown != tex_hauler:
		return "unknown archetype must fall back to HAULER"
	return "ok"


func test_cache_and_clear_cache() -> String:
	MapIcons.clear_cache()
	var tex1: Texture2D = MapIcons.vessel_texture("HAULER")
	var tex2: Texture2D = MapIcons.vessel_texture("HAULER")
	if tex1 != tex2:
		return "MapIcons should return cached vessel texture on repeated calls"
	MapIcons.clear_cache()
	var tex3: Texture2D = MapIcons.vessel_texture("HAULER")
	if tex3 == null:
		return "MapIcons should reload cleanly after clear_cache"
	return "ok"
