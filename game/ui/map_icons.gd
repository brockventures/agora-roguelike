class_name MapIcons
extends RefCounted
## Illustrated map icons for the Sol tactical map nodes (#73 Visual Identity & Art Asset Pipeline).
## Built by tools/art/make_map_icons.py into assets/map_icons/. A missing texture returns null and
## the caller keeps drawing the flat disc, so the map never depends on the art being present.

const DIR: String = "res://assets/map_icons/"
## Drawn size in map pixels. Larger than the 2x node radius (28 / 48 px) so the subject reads;
## hit-testing and label placement still use SolTacticalMap's node radii.
const STATION_DRAW_PX: float = 40.0
const SOL_DRAW_PX: float = 68.0
const SOL_ID: String = "sol"

static var _cache: Dictionary = {}


## The icon texture for a station id or "sol", or null when there is none.
static func texture(id: String) -> Texture2D:
	if _cache.has(id):
		return _cache[id]
	var path: String = DIR + id + "_256.png"
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	_cache[id] = tex
	return tex


## Draws the icon centred on `center` at `size` px. Returns false (drawing nothing) when no texture exists.
static func draw_icon(ci: CanvasItem, id: String, center: Vector2, size: float) -> bool:
	var tex: Texture2D = texture(id)
	if tex == null:
		return false
	ci.draw_texture_rect(tex, Rect2(center - Vector2(size, size) * 0.5, Vector2(size, size)), false)
	return true
