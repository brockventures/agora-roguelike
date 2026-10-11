class_name MapIcons
extends RefCounted
## Illustrated map icons for the Sol tactical map nodes (#73 Visual Identity & Art Asset Pipeline).
## Built by tools/art/make_map_icons.py into assets/map_icons/. A missing texture returns null and
## the caller keeps drawing the flat disc, so the map never depends on the art being present.

const DIR: String = "res://assets/map_icons/"
## Per-body draw table, the one place the map's body sizes live. `disc` is the on-screen diameter
## in map px of the body itself (not the image); `frac` is that body's disc as a fraction of the
## 256 px icon's width and `center` where the disc's centre sits in the image (0..1), both measured
## from the art (Earth's disc is the left part of its image: the space-elevator tether and station
## run off to the right; Sol's dark arc and Ceres' scaffolding sit outside their discs). The icon is
## drawn so the disc, not the image, is centred on the node. Order of size: Sol, then Earth and Mars
## (equal discs), then Luna and Ceres. Hit-testing and label placement use SolTacticalMap's radii,
## which are half of these discs plus a little air.
const BODIES: Dictionary = {
	"sol": {"disc": 84.0, "frac": 0.58, "center": Vector2(0.42, 0.50)},
	"earth": {"disc": 44.0, "frac": 0.59, "center": Vector2(0.355, 0.50)},
	"mars": {"disc": 44.0, "frac": 0.80, "center": Vector2(0.50, 0.50)},
	"luna": {"disc": 28.0, "frac": 0.88, "center": Vector2(0.50, 0.49)},
	"ceres": {"disc": 30.0, "frac": 0.55, "center": Vector2(0.45, 0.52)},
}
const DEFAULT_BODY: Dictionary = {"disc": 26.0, "frac": 0.8, "center": Vector2(0.5, 0.5)}
## Far-side bodies are drawn this much smaller (1.0 on the near side); see depth_scale().
const FAR_SCALE: float = 0.92
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


## The body's table row (DEFAULT_BODY for an id with no entry).
static func body(id: String) -> Dictionary:
	return BODIES.get(id, DEFAULT_BODY)


## On-screen diameter of a body's disc, px.
static func disc_px(id: String) -> float:
	return float(body(id)["disc"])


## Size scale from depth: `depth` is -1 on the far (top) edge of the tilted orbital plane, +1 on
## the near (bottom) edge. Far bodies are very slightly smaller; the near side is full size.
static func depth_scale(depth: float) -> float:
	return lerpf(FAR_SCALE, 1.0, clampf(depth * 0.5 + 0.5, 0.0, 1.0))


## Draws the icon with the body's disc centred on `center`, sized from the BODIES table and
## multiplied by `scale`. Returns false (drawing nothing) when no texture exists.
static func draw_icon(ci: CanvasItem, id: String, center: Vector2, scale: float = 1.0) -> bool:
	var tex: Texture2D = texture(id)
	if tex == null:
		return false
	var row: Dictionary = body(id)
	var size: float = float(row["disc"]) / float(row["frac"]) * scale
	var origin: Vector2 = center - Vector2(row["center"]) * size
	ci.draw_texture_rect(tex, Rect2(origin, Vector2(size, size)), false)
	return true
