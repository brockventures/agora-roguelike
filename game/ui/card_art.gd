class_name CardArt
extends RefCounted
## 4:3 Encounter Deck card illustrations for Agora Roguelike (#73).
##
## Looks up illustrated 4:3 card textures from `res://assets/card_art/`.
## Gracefully returns null if the texture is missing, allowing the HUD
## to fall back to the hatched paper plate so the game never depends
## on art assets being present on disk.

const DIR: String = "res://assets/card_art/"
const VESSEL_DIR: String = "res://assets/map_icons/"

## Canonical vessel hull ID to map icon stem mapping (#220).
const VESSELS: Dictionary = {
	"HAULER": "vessel_hauler",
	"INTERCEPTOR": "vessel_interceptor",
	"FREIGHTER": "vessel_freighter",
	"SCOUT": "vessel_scout",
	"SCRAP_BARGE": "vessel_scrap_barge",
	"hauler": "vessel_hauler",
	"interceptor": "vessel_interceptor",
	"freighter": "vessel_freighter",
	"scout": "vessel_scout",
	"scrap_barge": "vessel_scrap_barge",
	"vessel_hauler": "vessel_hauler",
	"vessel_interceptor": "vessel_interceptor",
	"vessel_freighter": "vessel_freighter",
	"vessel_scout": "vessel_scout",
	"vessel_scrap_barge": "vessel_scrap_barge",
	"hull_hauler": "vessel_hauler",
	"hull_interceptor": "vessel_interceptor",
	"hull_freighter": "vessel_freighter",
	"hull_scout": "vessel_scout",
	"hull_scrap_barge": "vessel_scrap_barge",
}

## Canonical crisis ID to texture stem mapping.
## Covers all 11 crises in game/data/crises.json and spatial hazard outcomes.
const CARDS: Dictionary = {
	"antitrust_audit": "antitrust_audit",
	"emergency_antitrust_sweep": "emergency_antitrust_sweep",
	"localized_shortage": "localized_shortage",
	"supply_chain_shortage": "supply_chain_shortage",
	"systemic_margin_collapse": "systemic_margin_collapse",
	"ares_retaliation": "ares_retaliation",
	"titan_retaliation": "titan_retaliation",
	"sol_retaliation": "sol_retaliation",
	"ares_opportunistic_squeeze": "ares_opportunistic_squeeze",
	"titan_opportunistic_hoard": "titan_opportunistic_hoard",
	"sol_opportunistic_levy": "sol_opportunistic_levy",
	# Special / Hazard / Salvage encounter cards (#220)
	"cme_flare": "cme_flare",
	"cme_relay_blackout": "cme_flare",
	"solar_storm": "cme_flare",
	"storm_delay": "cme_flare",
	"hull_breach": "cme_flare",
	"salvage_beacon": "supply_chain_shortage",
	"salvage_beacons": "supply_chain_shortage",
	"derelict_salvage": "supply_chain_shortage",
	"salvage_recovered": "supply_chain_shortage",
	"salvage_hazard": "cme_flare",
	"pirate_raid": "ares_retaliation",
	"dark_run": "titan_opportunistic_hoard",
	"shortage_dilemma": "localized_shortage",
	# Station Overview Deck (Subtasks 6.3 / 6.6)
	"card_ceres": "card_ceres",
	"card_earth": "card_earth",
	"card_luna": "card_luna",
	"card_mars": "card_mars",
	"station_ceres": "card_ceres",
	"station_earth": "card_earth",
	"station_luna": "card_luna",
	"station_mars": "card_mars",
	"ceres": "card_ceres",
	"earth": "card_earth",
	"luna": "card_luna",
	"mars": "card_mars",
}

static var _cache: Dictionary = {}


static func _load_png(path: String) -> Texture2D:
	var abs_path: String = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(abs_path):
		var img := Image.load_from_file(abs_path)
		if img != null and not img.is_empty():
			return ImageTexture.create_from_image(img)
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null


## Returns the Texture2D for a crisis ID or card ID, or null if missing.
static func texture(card_id: String) -> Texture2D:
	if card_id.is_empty():
		return null
	var norm_id: String = card_id.strip_edges()
	if norm_id.is_empty():
		return null
	if _cache.has(norm_id):
		return _cache[norm_id]
	var lower_id: String = norm_id.to_lower().replace("-", "_")
	var stem: String = str(CARDS.get(norm_id, CARDS.get(lower_id, norm_id)))
	var path: String = "%s%s.png" % [DIR, stem]
	var tex: Texture2D = _load_png(path)
	_cache[norm_id] = tex
	return tex


## Returns the Texture2D for a vessel hull archetype at the given icon size (128 or 256), or null if missing (#220).
static func vessel_texture(hull_id: String, size: int = 256) -> Texture2D:
	var raw: String = hull_id.strip_edges()
	if raw.is_empty():
		return null
	var norm: String = raw.to_lower().replace(" ", "_").replace("-", "_")
	var stem: String = ""
	if VESSELS.has(raw):
		stem = str(VESSELS[raw])
	elif VESSELS.has(norm):
		stem = str(VESSELS[norm])
	elif VESSELS.has(norm.to_upper()):
		stem = str(VESSELS[norm.to_upper()])
	else:
		return null
	var resolved_size: int = 128 if size == 128 else 256
	var cache_key: String = "vessel:%s:%d" % [stem, resolved_size]
	if _cache.has(cache_key):
		return _cache[cache_key]
	var path: String = "%s%s_%d.png" % [VESSEL_DIR, stem, resolved_size]
	var tex: Texture2D = _load_png(path)
	if tex == null:
		tex = _load_png("%s%s_256.png" % [VESSEL_DIR, stem])
	if tex == null:
		tex = _load_png("%s%s.png" % [VESSEL_DIR, stem])
	_cache[cache_key] = tex
	return tex


## Returns true if a vessel texture exists for the specified hull ID (#220).
static func has_vessel_art(hull_id: String, size: int = 256) -> bool:
	return vessel_texture(hull_id, size) != null


## Clears the texture cache (useful for tests or hot-reloading).
static func clear_cache() -> void:
	_cache.clear()


## Returns true if an art asset exists for the specified card ID.
static func has_art(card_id: String) -> bool:
	return texture(card_id) != null
