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
