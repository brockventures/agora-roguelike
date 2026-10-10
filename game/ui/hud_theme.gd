class_name HudTheme
extends RefCounted
## Epic 6 HUD look (#105, "re-skin the HUD from CRT phosphor to the approved Scavengers
## Reign style"): heavy ligne claire ink contours, flat graphic shadow cuts and a muted
## mineral and rust palette. Palette constants live here; `res://ui/hud_theme.tres` is the
## Theme resource that carries the panel styles, and tests keep the two in step.
## Presentation only: nothing here reaches sim state, saves or hashes.

const THEME_PATH: String = "res://ui/hud_theme.tres"

const INK := Color("1c1a17")
const SLATE := Color("2c353b")
const BONE := Color("e6dcc3")
const BONE_DIM := Color("b8ad94")
const PAPER := Color("d9cdb0")
const PAPER_DEEP := Color("cdbf9f")
const OCHRE := Color("c99a2e")
const OCHRE_DARK := Color("9a6f1c")
const RUST := Color("a8431f")
const RUST_DARK := Color("7a2e14")
const TEAL := Color("2f6f6a")
const TEAL_DARK := Color("1f4f4b")

## Ink contour widths in px.
const OUTLINE_PANEL: int = 4
const OUTLINE_NODE: float = 3.0
const OUTLINE_RING: float = 2.0
## Offset of the solid shadow shapes, px (down and right, never blurred).
const SHADOW_OFFSET: Vector2 = Vector2(4.0, 4.0)

static var _cached: Theme = null


static func load_theme() -> Theme:
	if _cached == null:
		_cached = load(THEME_PATH) as Theme
	return _cached


## A flat filled disc with an ink contour and a hard-edged shadow cut: a circular
## segment on the lower right, plus an offset solid ink shadow disc behind it.
static func draw_flat_disc(ci: CanvasItem, center: Vector2, radius: float, fill: Color, cut: Color) -> void:
	ci.draw_circle(center + SHADOW_OFFSET, radius + OUTLINE_NODE, INK)
	ci.draw_circle(center, radius + OUTLINE_NODE, INK)
	ci.draw_circle(center, radius, fill)
	# Shadow cut: the part of the disc beyond a chord, centred on the lower-right (45 deg).
	var chord: float = radius * 0.3
	var half: float = acos(chord / radius)
	var mid: float = PI * 0.25
	var pts := PackedVector2Array()
	var steps: int = 20
	for i in steps + 1:
		var a: float = mid - half + 2.0 * half * float(i) / float(steps)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	ci.draw_colored_polygon(pts, cut)
