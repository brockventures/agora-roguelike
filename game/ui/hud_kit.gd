class_name HudKit
extends RefCounted
## HUD v3 component kit (design system: StatChip, PaperTabs, LadderRow, OrderTicket,
## ArtCard, Modal title band, TickerLine, PadGlyph, Tag). Builds plain Control nodes
## with explicit rects: the scene tests measure the HUD without a SceneTree, where
## Container nodes never lay out, so columns are separate right-aligned Labels placed
## on a column grid by the caller instead of HBox/Grid children.
##
## Every text node is a Label made by label(): it carries a type role (hud_theme.gd),
## its font size at 100% text scale (BASE_SIZE_META) and sits in `labels`, the one
## registry the text scale, the localization tests and the pseudo-locale fit test walk.
## Presentation only: nothing here reaches sim state, saves or hashes.

## Label metadata key holding the font size at 100% text scale.
const BASE_SIZE_META: String = "base_font_size"
## Label metadata key holding the type role the label was made with.
const ROLE_META: String = "hud_role"

var labels: Array[Label] = []
var text_scale: float = 1.0


## A flat rectangle in the heavy-cel style: ink contour, optional hard shadow, optional
## cut corner (the StatChip alert fill, the modal band), a hatched fill (placeholder art)
## and a proportional bar fill (the depth bar). `is_disc` draws a disc instead (pad glyph).
class Plate extends Control:
	var fill: Color = Color(0, 0, 0, 0)
	var edge: Color = HudTheme.INK
	var border: float = 0.0
	var shadow: bool = false
	var cut: Color = Color(0, 0, 0, 0)
	var cut_size: float = 0.0
	var hatch: bool = false:
		set(v):
			hatch = v
			clip_contents = v
	var is_disc: bool = false
	## 0..1 share of the inner width painted with bar_color (-1 = no bar).
	var bar_frac: float = -1.0
	var bar_color: Color = Color.WHITE

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if is_disc:
			# A disc, or a pill when the label is wider than it is tall (VIEW, D-PAD).
			var rad: float = size.y * 0.5
			var half: float = maxf(0.0, size.x * 0.5 - rad)
			var c: Vector2 = size * 0.5
			draw_circle(c - Vector2(half, 0.0), rad, edge)
			draw_circle(c + Vector2(half, 0.0), rad, edge)
			draw_rect(Rect2(c.x - half, 0.0, half * 2.0, size.y), edge)
			draw_circle(c - Vector2(half, 0.0), rad - border, fill)
			draw_circle(c + Vector2(half, 0.0), rad - border, fill)
			draw_rect(Rect2(c.x - half, border, half * 2.0, size.y - 2.0 * border), fill)
			return
		if shadow:
			draw_rect(Rect2(HudTheme.SHADOW_OFFSET, size), HudTheme.INK)
		var inner: Rect2 = r.grow(-border)
		if border > 0.0:
			draw_rect(r, edge)
		if fill.a > 0.0:
			draw_rect(inner, fill)
		if hatch:
			# 135 degree hatch, clipped to the inner rect by the node's own clip.
			var x: float = inner.position.x - inner.size.y
			while x < inner.end.x:
				draw_line(Vector2(x, inner.end.y), Vector2(x + inner.size.y, inner.position.y), HudTheme.PAPER, 8.0)
				x += 16.0
			# The hatch overruns into the contour; paint the contour over it.
			draw_rect(Rect2(0.0, 0.0, size.x, border), edge)
			draw_rect(Rect2(0.0, size.y - border, size.x, border), edge)
			draw_rect(Rect2(0.0, 0.0, border, size.y), edge)
			draw_rect(Rect2(size.x - border, 0.0, border, size.y), edge)
		if bar_frac >= 0.0:
			draw_rect(Rect2(inner.position, Vector2(inner.size.x * clampf(bar_frac, 0.0, 1.0), inner.size.y)), bar_color)
		if cut.a > 0.0 and cut_size > 0.0:
			var s: float = minf(cut_size, minf(size.x, size.y))
			draw_colored_polygon(PackedVector2Array([Vector2(size.x - border - s, size.y - border), Vector2(size.x - border, size.y - border), Vector2(size.x - border, size.y - border - s)]), cut)


## A Label only re-reads its theme cache (and so its minimum size) on a theme notification,
## which a node outside the tree (the unit tests build the scene without adding it) never
## gets from an override; send it by hand after changing the font or its size.
static func refresh_theme(l: Label) -> void:
	l.notification(Control.NOTIFICATION_THEME_CHANGED)


func scaled(base: int) -> int:
	return int(round(float(base) * text_scale))


## A Label of one type role at `base_size` px (at 100%), registered for the text scale.
func label(parent: Node, name: String, role: String, base_size: int, color: Color, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.name = name
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Text arrives already translated; stop Label translating it a second time (which
	# would pseudolocalize twice).
	l.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	l.horizontal_alignment = align as HorizontalAlignment
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.set_meta(BASE_SIZE_META, base_size)
	l.set_meta(ROLE_META, role)
	l.add_theme_font_override("font", HudTheme.role_font(role))
	refresh_theme(l)
	l.add_theme_font_size_override("font_size", scaled(base_size))
	refresh_theme(l)
	l.add_theme_color_override("font_color", color)
	# The design's line boxes are the font's own height; Label's default 3 px of line
	# spacing would make every one-line label 3 px taller than the chip it sits in.
	l.add_theme_constant_override("line_spacing", 0)
	parent.add_child(l)
	labels.append(l)
	return l


## Scales every registered label from its 100% size.
func apply_scale(scale: float) -> void:
	text_scale = scale
	for l in labels:
		l.add_theme_font_size_override("font_size", scaled(int(l.get_meta(BASE_SIZE_META))))
		refresh_theme(l)


func plate(parent: Node, rect: Rect2, fill: Color, edge: Color = HudTheme.INK, border: float = 0.0) -> Plate:
	var p := Plate.new()
	p.position = rect.position
	p.size = rect.size
	p.fill = fill
	p.edge = edge
	p.border = border
	parent.add_child(p)
	return p


# --- Measuring (the Label's own font and size, as the fit test reads them) ---

static func font_of(l: Label) -> Font:
	return l.get_theme_font("font") if l.has_theme_font_override("font") else l.get_theme_default_font()


static func text_width(l: Label, text: String) -> float:
	return font_of(l).get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.get_theme_font_size("font_size")).x


static func line_height(l: Label) -> float:
	# The Label's own line box (it can exceed Font.get_height when the face has line gap),
	# which is also the least height the Label can be given.
	var font: Font = font_of(l)
	var fs: int = l.get_theme_font_size("font_size")
	var shaped: float = maxf(font.get_multiline_string_size("Ag", HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs, -1, TextServer.BREAK_MANDATORY).y, font.get_multiline_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs, -1, TextServer.BREAK_MANDATORY).y if l.autowrap_mode == TextServer.AUTOWRAP_OFF and not l.text.contains("\n") else 0.0)
	return maxf(maxf(ceilf(font.get_height(fs)), ceilf(shaped)), float(l.get_line_height()))


## Height of `text` wrapped at `width` (a wrapping label's needed height).
static func wrapped_height(l: Label, text: String, width: float) -> float:
	var font: Font = font_of(l)
	var fs: int = l.get_theme_font_size("font_size")
	var flags: int = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	var h: float = font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width, fs, -1, flags).y
	var lines: int = int(round(h / maxf(1.0, font.get_height(fs))))
	return maxf(h + float(maxi(0, lines - 1) * l.get_theme_constant("line_spacing")), float(maxi(1, lines)) * line_height(l))


## Sets `text` on a one-line label so it fits `max_w`: the role's own width axis first,
## then narrower steps down to HudTheme.MIN_WDTH (the design system's fit rule: use the
## width axis before wrapping, never go below 12 px). Returns the width the text needs.
## A line that still does not fit at the narrowest axis is wrapped (the caller sizes the
## label's height with wrapped_height).
func fit_text(l: Label, text: String, max_w: float) -> float:
	l.text = text
	var role: String = str(l.get_meta(ROLE_META))
	var own: int = int(HudTheme.TYPE_ROLES[role]["wdth"])
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	var w: float = 0.0
	for wd in [own, 85, 78, 70, HudTheme.MIN_WDTH]:
		if wd > own:
			continue
		l.add_theme_font_override("font", HudTheme.role_font(role, wd))
		refresh_theme(l)
		w = text_width(l, text)
		if w <= max_w + 0.01:
			return w
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Until it re-shapes, the label's cached minimum width is the unwrapped line's, which
	# would clamp any size the caller sets to the narrower wrap width.
	refresh_theme(l)
	return max_w


## Width of `text` at the label's role as designed (the width axis a previous fit_text
## narrowed is reset first), for sizing a column before fitting into it.
func natural_width(l: Label, text: String) -> float:
	l.add_theme_font_override("font", HudTheme.role_font(str(l.get_meta(ROLE_META))))
	refresh_theme(l)
	return text_width(l, text)


# --- Components ---

## PadGlyph: a 22 px disc with the button letter, then its label. Returns the node and
## sets `width` in its meta so callers can flow a row of them.
func pad_glyph(parent: Node, name: String, button: String, caption: String, color: Color = HudTheme.BONE, disc_fill: Color = HudTheme.BONE) -> Control:
	var host := Control.new()
	host.name = name
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(host)
	var disc := Plate.new()
	disc.is_disc = true
	disc.fill = disc_fill
	disc.border = 2.0
	disc.position = Vector2.ZERO
	host.add_child(disc)
	var b: Label = label(host, name + "_btn", HudTheme.ROLE_LABEL, 12, HudTheme.INK, HORIZONTAL_ALIGNMENT_CENTER)
	b.add_theme_font_override("font", HudTheme.role_font(HudTheme.ROLE_LABEL, 70))
	refresh_theme(b)
	var c: Label = label(host, name + "_cap", HudTheme.ROLE_HINT, 14, color)
	host.set_meta("disc", disc)
	host.set_meta("btn", b)
	host.set_meta("cap", c)
	set_pad_glyph(host, button, caption, color)
	return host


## Updates a pad glyph's letter and caption and re-lays it; its width is host.size.x.
func set_pad_glyph(host: Control, button: String, caption: String, color: Color = HudTheme.BONE) -> void:
	var disc: Plate = host.get_meta("disc")
	var b: Label = host.get_meta("btn")
	var c: Label = host.get_meta("cap")
	b.text = button
	c.text = caption
	c.add_theme_color_override("font_color", color)
	var d: float = maxf(22.0, text_width(b, button) + 8.0)
	var dh: float = maxf(22.0, line_height(b) + 4.0)
	disc.size = Vector2(d, dh)
	disc.queue_redraw()
	b.position = Vector2.ZERO
	b.size = Vector2(d, dh)
	var cw: float = text_width(c, caption) if caption != "" else 0.0
	var ch: float = line_height(c)
	c.visible = caption != ""
	c.position = Vector2(d + 6.0, (dh - ch) * 0.5)
	c.size = Vector2(cw + 2.0, ch)
	host.size = Vector2(d + (6.0 + cw + 2.0 if caption != "" else 0.0), maxf(dh, ch))


## Tag: a small ink-outlined chip (category labels, baron tags, side tags). The text is
## fitted to `max_w` on the width axis; the chip is sized to it. Returns the chip.
func tag(parent: Node, name: String) -> Plate:
	var chip := Plate.new()
	chip.name = name
	chip.border = 2.0
	parent.add_child(chip)
	var l: Label = label(chip, name + "_text", HudTheme.ROLE_LABEL, 12, HudTheme.INK, HORIZONTAL_ALIGNMENT_CENTER)
	chip.set_meta("text", l)
	return chip


func set_tag(chip: Plate, text: String, bg: Color, fg: Color, max_w: float = 400.0, min_w: float = 0.0) -> void:
	var l: Label = chip.get_meta("text")
	l.add_theme_color_override("font_color", fg)
	var w: float = fit_text(l, text, max_w - 12.0)
	var lh: float = line_height(l)
	if l.autowrap_mode != TextServer.AUTOWRAP_OFF:
		lh = wrapped_height(l, text, max_w - 12.0)
	var cw: float = maxf(min_w, w + 12.0)
	chip.fill = bg
	chip.size = Vector2(cw, lh + 4.0)
	chip.queue_redraw()
	l.position = Vector2(0.0, 0.0)
	l.size = chip.size
