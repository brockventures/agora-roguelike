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
## Rust lightened for text on the slate plates (5.3:1 on SLATE).
const RUST_LIGHT := Color("e8946e")
const TEAL := Color("2f6f6a")
const TEAL_DARK := Color("1f4f4b")

## Ink contour widths in px.
const OUTLINE_PANEL: int = 4
const OUTLINE_NODE: float = 3.0
const OUTLINE_RING: float = 2.0
## Offset of the solid shadow shapes, px (down and right, never blurred).
const SHADOW_OFFSET: Vector2 = Vector2(4.0, 4.0)

## Panel variations in hud_theme.tres: the plate styles every screen draws from.
const PANEL_VARIATIONS: Array[String] = ["HeaderPanel", "MapPanel", "SidebarPanel", "TickerPanel", "HeaderPanelPaused", "ModalPanel", "AlertPanel", "BannerPanel", "FocusFrameRust", "FocusFrameOchre"]
## Minimum contrast for graphical objects (WCAG 1.4.11) and for text (1.4.3).
const MIN_GRAPHIC_CONTRAST: float = 3.0
const MIN_TEXT_CONTRAST: float = 4.5

## GalNet ticker line colours by severity, for text on the slate plate.
static func ticker_color(severity: String) -> Color:
	match severity.to_upper():
		"CRITICAL":
			return RUST_LIGHT
		"WARNING":
			return OCHRE
	return BONE


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


## The panel StyleBox of a theme variation, so code-built panels share the .tres styles.
static func panel_style(variation: String) -> StyleBox:
	return load_theme().get_stylebox("panel", variation)


## Gives a code-built Panel one of the theme's variations. The style is also set as
## the node's own override so it resolves before the node is in the tree.
static func style_panel(p: Panel, variation: String) -> void:
	p.theme_type_variation = StringName(variation)
	p.add_theme_stylebox_override("panel", panel_style(variation))


## WCAG relative luminance and contrast ratio, shared by the tests and any caller that
## wants to check a pair of palette colours.
static func luminance(c: Color) -> float:
	var f := func(v: float) -> float: return v / 12.92 if v <= 0.03928 else pow((v + 0.055) / 1.055, 2.4)
	return 0.2126 * f.call(c.r) + 0.7152 * f.call(c.g) + 0.0722 * f.call(c.b)


static func contrast(a: Color, b: Color) -> float:
	var la: float = luminance(a)
	var lb: float = luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


## A focus highlight bar: a flat fill with a heavy outline drawn behind it. `fill` and
## `outline` are the two colours; the outline is a child so the bar keeps one rect.
static func make_focus_bar(parent: Control, fill: Color, outline: Color) -> ColorRect:
	var bar := ColorRect.new()
	bar.color = fill
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var edge := ColorRect.new()
	edge.name = "Outline"
	edge.color = outline
	edge.show_behind_parent = true
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(edge)
	parent.add_child(bar)
	bar.visible = false
	return bar


## Places a focus bar over `rect` (in its parent's space); the outline grows 3 px outward.
static func place_focus_bar(bar: ColorRect, rect: Rect2) -> void:
	bar.position = rect.position
	bar.size = rect.size
	var edge := bar.get_node("Outline") as ColorRect
	edge.position = Vector2(-OUTLINE_NODE, -OUTLINE_NODE)
	edge.size = rect.size + Vector2(OUTLINE_NODE, OUTLINE_NODE) * 2.0
