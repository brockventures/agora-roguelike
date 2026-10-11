class_name CardArt
extends RefCounted
## 4:3 Encounter Deck card illustrations for Agora Roguelike (#73).
##
## Looks up illustrated 4:3 card textures from `res://assets/card_art/`.
## Gracefully returns null if the texture is missing, allowing the HUD
## to fall back to the hatched paper plate so the game never depends
## on art assets being present on disk.

const DIR: String = "res://assets/card_art/"

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
	# Special / Hazard cards
	"cme_flare": "cme_flare",
	"cme_relay_blackout": "cme_flare",
}

static var _cache: Dictionary = {}


## Returns the Texture2D for a crisis ID or card ID, or null if missing.
static func texture(card_id: String) -> Texture2D:
	if card_id.is_empty():
		return null
	if _cache.has(card_id):
		return _cache[card_id]
	var stem: String = str(CARDS.get(card_id, card_id))
	var path: String = "%s%s.png" % [DIR, stem]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	_cache[card_id] = tex
	return tex


## Clears the texture cache (useful for tests or hot-reloading).
static func clear_cache() -> void:
	_cache.clear()


## Returns true if an art asset exists for the specified card ID.
static func has_art(card_id: String) -> bool:
	return texture(card_id) != null
