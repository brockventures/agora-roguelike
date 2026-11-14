extends RefCounted
## Unit tests for CardArt encounter deck card illustration integration (#73).

func test_missing_or_empty_id_returns_null() -> String:
	CardArt.clear_cache()
	if CardArt.texture("") != null:
		return "empty card id should return null"
	if CardArt.texture("nonexistent_crisis_9999") != null:
		return "nonexistent card id should return null"
	if CardArt.has_art(""):
		return "has_art('') should return false"
	if CardArt.has_art("nonexistent_crisis_9999"):
		return "has_art for unknown id should return false"
	return "ok"


func test_antitrust_audit_card_art_loads_and_has_4x3_aspect() -> String:
	CardArt.clear_cache()
	var path: String = "res://assets/card_art/antitrust_audit.png"
	if not ResourceLoader.exists(path):
		return "antitrust_audit.png art asset must exist at %s" % path
	var tex: Texture2D = CardArt.texture("antitrust_audit")
	if tex == null:
		return "CardArt.texture('antitrust_audit') returned null"
	if not CardArt.has_art("antitrust_audit"):
		return "CardArt.has_art('antitrust_audit') returned false"
	var w: float = float(tex.get_width())
	var h: float = float(tex.get_height())
	if h <= 0.0 or w <= 0.0:
		return "invalid texture dimensions: %s x %s" % [w, h]
	var aspect: float = w / h
	if absf(aspect - 4.0 / 3.0) > 0.02:
		return "card art aspect ratio must be 4:3 (got %f from %s x %s)" % [aspect, w, h]
	return "ok"


func test_cme_flare_card_art_loads_and_has_4x3_aspect() -> String:
	CardArt.clear_cache()
	var path: String = "res://assets/card_art/cme_flare.png"
	if not ResourceLoader.exists(path):
		return "cme_flare.png art asset must exist at %s" % path
	var tex: Texture2D = CardArt.texture("cme_flare")
	if tex == null:
		return "CardArt.texture('cme_flare') returned null"
	var w: float = float(tex.get_width())
	var h: float = float(tex.get_height())
	var aspect: float = w / h
	if absf(aspect - 4.0 / 3.0) > 0.02:
		return "cme flare aspect ratio must be 4:3 (got %f from %s x %s)" % [aspect, w, h]
	return "ok"


func test_plate_texture_field_and_hatch_toggle() -> String:
	var plate := HudKit.Plate.new()
	if plate.texture != null:
		return "default plate texture should be null"
	var tex := CardArt.texture("antitrust_audit")
	plate.texture = tex
	if plate.texture != tex:
		return "plate texture assignment failed"
	plate.hatch = (plate.texture == null)
	if plate.hatch:
		return "plate hatch should be false when texture is assigned"
	plate.texture = null
	plate.hatch = (plate.texture == null)
	if not plate.hatch:
		return "plate hatch should be true when texture is null"
	return "ok"


func test_cache_and_clear_cache() -> String:
	CardArt.clear_cache()
	var tex1: Texture2D = CardArt.texture("antitrust_audit")
	var tex2: Texture2D = CardArt.texture("antitrust_audit")
	if tex1 != tex2:
		return "CardArt should return cached texture on repeated calls"
	CardArt.clear_cache()
	var tex3: Texture2D = CardArt.texture("antitrust_audit")
	if tex3 == null:
		return "CardArt should reload cleanly after clear_cache"
	return "ok"

func test_all_eleven_crisis_deck_cards_load_and_have_4x3_aspect() -> String:
	var crisis_ids: Array[String] = [
		"antitrust_audit",
		"emergency_antitrust_sweep",
		"localized_shortage",
		"supply_chain_shortage",
		"systemic_margin_collapse",
		"ares_retaliation",
		"titan_retaliation",
		"sol_retaliation",
		"ares_opportunistic_squeeze",
		"titan_opportunistic_hoard",
		"sol_opportunistic_levy",
	]
	for cid in crisis_ids:
		if not CardArt.has_art(cid):
			return "CardArt.has_art('%s') returned false" % cid
		var tex: Texture2D = CardArt.texture(cid)
		if tex == null:
			return "CardArt.texture('%s') returned null" % cid
		var w: float = float(tex.get_width())
		var h: float = float(tex.get_height())
		if w <= 0.0 or h <= 0.0:
			return "invalid dimensions for '%s': %sx%s" % [cid, w, h]
		var aspect: float = w / h
		if absf(aspect - 4.0 / 3.0) > 0.02:
			return "'%s' aspect ratio must be 4:3 (got %f from %sx%s)" % [cid, aspect, w, h]
	return "ok"


func test_station_overview_cards_load_and_have_4x3_aspect() -> String:
	var stations: Array[String] = ["ceres", "earth", "luna", "mars"]
	for st in stations:
		var card_key: String = "station_%s" % st
		if not CardArt.has_art(card_key):
			return "CardArt.has_art('%s') returned false" % card_key
		var tex: Texture2D = CardArt.texture(card_key)
		if tex == null:
			return "CardArt.texture('%s') returned null" % card_key
		var w: float = float(tex.get_width())
		var h: float = float(tex.get_height())
		if w <= 0.0 or h <= 0.0:
			return "invalid dimensions for station card '%s': %sx%s" % [card_key, w, h]
		var aspect: float = w / h
		if absf(aspect - 4.0 / 3.0) > 0.02:
			return "'%s' aspect ratio must be 4:3 (got %f from %sx%s)" % [card_key, aspect, w, h]
	return "ok"


func test_vessel_hull_textures_and_aliases() -> String:
	CardArt.clear_cache()
	if CardArt.vessel_texture("") != null:
		return "empty hull_id should return null"
	if CardArt.vessel_texture("nonexistent_hull_9999") != null:
		return "unknown hull_id should return null"
	if CardArt.has_vessel_art("nonexistent_hull_9999"):
		return "has_vessel_art for unknown hull should return false"

	var hulls: Array[String] = [
		"hauler",
		"interceptor",
		"freighter",
		"scout",
		"scrap_barge",
	]
	for h_id in hulls:
		var tex256: Texture2D = CardArt.vessel_texture(h_id, 256)
		if tex256 == null:
			return "CardArt.vessel_texture('%s', 256) returned null" % h_id
		if tex256.get_width() != 256 or tex256.get_height() != 256:
			return "expected 256x256 for '%s', got %dx%d" % [h_id, tex256.get_width(), tex256.get_height()]
		var tex128: Texture2D = CardArt.vessel_texture(h_id, 128)
		if tex128 == null:
			return "CardArt.vessel_texture('%s', 128) returned null" % h_id
		if tex128.get_width() != 128 or tex128.get_height() != 128:
			return "expected 128x128 for '%s', got %dx%d" % [h_id, tex128.get_width(), tex128.get_height()]
		var tex_upper: Texture2D = CardArt.vessel_texture(h_id.to_upper(), 256)
		var tex_prefixed: Texture2D = CardArt.vessel_texture("vessel_" + h_id, 256)
		var tex_hull_prefix: Texture2D = CardArt.vessel_texture("hull-" + h_id, 256)
		if tex_upper != tex256 or tex_prefixed != tex256 or tex_hull_prefix != tex256:
			return "vessel_texture aliases should resolve to cached 256px texture for '%s'" % h_id
	return "ok"


func test_salvage_and_hazard_encounter_aliases_load_4x3_art() -> String:
	CardArt.clear_cache()
	var aliases: Array[String] = [
		"cme_relay_blackout",
		"solar_storm",
		"storm_delay",
		"hull_breach",
		"salvage_beacon",
		"salvage_beacons",
		"derelict_salvage",
		"salvage_recovered",
		"salvage_hazard",
		"pirate_raid",
		"dark_run",
		"shortage_dilemma",
	]
	for aid in aliases:
		if not CardArt.has_art(aid):
			return "CardArt.has_art('%s') returned false" % aid
		var tex: Texture2D = CardArt.texture(aid)
		if tex == null:
			return "CardArt.texture('%s') returned null" % aid
		var aspect: float = float(tex.get_width()) / float(tex.get_height())
		if absf(aspect - 4.0 / 3.0) > 0.02:
			return "encounter alias '%s' must be 4:3 aspect (got %f)" % [aid, aspect]
	return "ok"


