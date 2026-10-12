class_name SettingsView
extends Control
## The settings screen as HudKit cards (#193): a Preferences card (text size, colours,
## language, CRT, alert volume and mute, reduced motion, the orientation program), a
## Controls card (one binding row per m0_* action, scrolled so the cursor row shows), RESET
## and CLOSE buttons, and the footer line. A view over SettingsMenu: it reads row_parts()
## and footer_text() and never changes the model; input stays in SettingsMenu.handle_event().
## Presentation only: nothing here reaches sim state, saves or hashes.

const PAD: float = 24.0
const GAP: float = 16.0
const COL_GAP: float = 8.0
const CARD_GAP_Y: float = 6.0
const CARD_PAD: float = 12.0
const ROW_INSET: float = 6.0
const ROW_MIN_H: float = 28.0
const ROW_PAD_H: float = 10.0
const EDGE_PAD: float = 8.0
const TRACK_H: float = 10.0
const TRACK_GAP: float = 8.0
const VALUE_W: float = 56.0
const ZONE_MAX_W: float = 190.0
const BIND_ZONE_MAX_W: float = 240.0
const SCROLL_H: float = 24.0
const BTN_W: float = 240.0
const BTN_H: float = 44.0
const BTN_GAP: float = 16.0
const BTN_GAP_V: float = 12.0

var _menu: SettingsMenu = null
var _kit: HudKit = null
var _frame: HudKit.Plate = null
var _title: Label = null
var _cards: Array = []
var _card_titles: Array = []
## Pooled rows: each {"host", "label", "track", "fill", "value", "chip"}.
var _pref_rows: Array = []
var _ctrl_rows: Array = []
## Footer buttons, in model order (RESET, CLOSE): each {"plate", "label", "index"}.
var _buttons: Array = []
var _footer: Label = null
var _scroll: Label = null
var _focus_bar: ColorRect = null
## Model index -> Rect2 in view space, for every row on screen.
var _row_rects: Dictionary = {}
var _ctrl_first: int = 0
var _ctrl_shown: int = 0
var _pref_count: int = 0
var _ctrl_count: int = 0


## Builds the nodes for `menu` on `kit` and lays them out at `p_size`. The model is read live:
## call refresh() after any change to it.
func setup(menu: SettingsMenu, kit: HudKit, p_size: Vector2) -> void:
	_menu = menu
	_kit = kit
	for i in menu.rows().size():
		var section: String = str(menu.row_parts(i)["section"])
		if section == "prefs":
			_pref_count += 1
		elif section == "controls":
			_ctrl_count += 1
	size = p_size
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame = kit.plate(self, Rect2(Vector2.ZERO, p_size), HudTheme.SLATE, HudTheme.INK, float(HudTheme.OUTLINE_PANEL))
	_title = kit.label(self, "SettingsTitle", HudTheme.ROLE_TITLE, 24, HudTheme.BONE)
	_cards = [kit.plate(self, Rect2(), HudTheme.INK), kit.plate(self, Rect2(), HudTheme.INK)]
	_card_titles = [kit.label(self, "PrefsCardTitle", HudTheme.ROLE_TITLE, 18, HudTheme.BONE), kit.label(self, "ControlsCardTitle", HudTheme.ROLE_TITLE, 18, HudTheme.BONE)]
	# Buttons' plates come before the focus bar and their labels after it, so the bar
	# (opaque) covers the plate of the focused button but never its caption.
	for k in 2:
		_buttons.append({"plate": kit.plate(self, Rect2(), HudTheme.PAPER_DEEP, HudTheme.INK, float(HudTheme.OUTLINE_CONTROL)), "label": null, "index": k})
	_focus_bar = HudTheme.make_focus_bar(self, HudTheme.RUST_DARK, HudTheme.OCHRE)
	for k in 2:
		_buttons[k]["label"] = kit.label(self, "SettingsButton%d" % k, HudTheme.ROLE_HINT, 16, HudTheme.INK, HORIZONTAL_ALIGNMENT_CENTER)
	_footer = kit.label(self, "SettingsFooter", HudTheme.ROLE_HINT, 14, HudTheme.BONE_DIM)
	_scroll = kit.label(self, "ControlsScroll", HudTheme.ROLE_HINT, 14, HudTheme.BONE_DIM)
	for i in _pref_count:
		_pref_rows.append(_make_row("PrefRow%d" % i))
	for i in _ctrl_count:
		_ctrl_rows.append(_make_row("ControlRow%d" % i))
	refresh()


func _make_row(name: String) -> Dictionary:
	var host := Control.new()
	host.name = name
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(host)
	var label: Label = _kit.label(host, name + "Label", HudTheme.ROLE_BODY, 16, HudTheme.BONE)
	var track: HudKit.Plate = _kit.plate(host, Rect2(), HudTheme.SLATE)
	var fill: HudKit.Plate = _kit.plate(host, Rect2(), HudTheme.TEAL)
	var value: Label = _kit.label(host, name + "Value", HudTheme.ROLE_READOUT, 16, HudTheme.BONE, HORIZONTAL_ALIGNMENT_RIGHT)
	var chip: HudKit.Plate = _kit.tag(host, name + "Chip")
	return {"host": host, "label": label, "track": track, "fill": fill, "value": value, "chip": chip}


## Row height at the current text scale: one body line plus padding, never below ROW_MIN_H.
func _row_h() -> float:
	var l: Label = _pref_rows[0]["label"] if not _pref_rows.is_empty() else _title
	return maxf(ROW_MIN_H, ceilf(HudKit.line_height(l)) + ROW_PAD_H)


## Space above a card's rows: its padding, title line and gap.
func _card_head() -> float:
	return CARD_PAD + ceilf(HudKit.line_height(_card_titles[0])) + CARD_GAP_Y


## Sets the footer text fitted to `w` and returns its height.
func _fit_footer(w: float) -> float:
	var t: String = _menu.footer_text()
	_kit.fit_text(_footer, t, w)
	if _footer.autowrap_mode == TextServer.AUTOWRAP_OFF:
		return HudKit.line_height(_footer)
	return HudKit.wrapped_height(_footer, t, w)


## The height this screen needs at its current width and text scale: the owner grows the
## modal to it, so nothing is clipped at larger text.
func required_height() -> float:
	var head: float = HudKit.line_height(_title)
	var fh: float = _fit_footer(size.x - 2.0 * PAD)
	return PAD + head + GAP + _card_head() + float(_pref_count) * _row_h() + CARD_PAD + GAP + BTN_H + BTN_GAP_V + fh + PAD


## Lays out and fills every node from the model. Controls scroll so the cursor row shows.
func refresh() -> void:
	if _menu == null:
		return
	var w: float = size.x
	var h: float = size.y
	var inner_w: float = w - 2.0 * PAD
	_frame.position = Vector2.ZERO
	_frame.size = size
	_frame.queue_redraw()
	_kit.fit_text(_title, Loc.t("SET_TITLE"), inner_w)
	var head: float = HudKit.line_height(_title)
	_title.position = Vector2(PAD, PAD)
	_title.size = Vector2(inner_w, head)
	var fh: float = _fit_footer(inner_w)
	var footer_y: float = h - PAD - fh
	_footer.position = Vector2(PAD, footer_y)
	_footer.size = Vector2(inner_w, fh)
	var btn_y: float = footer_y - BTN_GAP_V - BTN_H
	var cards_y: float = PAD + head + GAP
	var cards_h: float = btn_y - GAP - cards_y
	var col_w: float = floorf((inner_w - COL_GAP) * 0.5)
	var left := Rect2(PAD, cards_y, col_w, cards_h)
	var right := Rect2(PAD + col_w + COL_GAP, cards_y, inner_w - col_w - COL_GAP, cards_h)
	_place_card(0, left, "SET_SECTION_PREFS")
	_place_card(1, right, "SET_SECTION_CONTROLS")
	_row_rects.clear()
	var rowh: float = _row_h()
	var row_top: float = left.position.y + _card_head()
	for i in _pref_rows.size():
		var rect := Rect2(left.position.x + ROW_INSET, row_top + float(i) * rowh, left.size.x - 2.0 * ROW_INSET, rowh)
		_place_row(_pref_rows[i], _menu.row_parts(i), rect)
		_row_rects[i] = rect
	_layout_controls(right, rowh)
	_layout_buttons(w, btn_y)
	var cursor: int = _menu.cursor
	if _row_rects.has(cursor):
		HudTheme.place_focus_bar(_focus_bar, _row_rects[cursor])
		_focus_bar.visible = true
	else:
		_focus_bar.visible = false


func _place_card(k: int, rect: Rect2, title_key: String) -> void:
	var card: HudKit.Plate = _cards[k]
	card.position = rect.position
	card.size = rect.size
	card.queue_redraw()
	var t: Label = _card_titles[k]
	_kit.fit_text(t, Loc.t(title_key), rect.size.x - 2.0 * CARD_PAD)
	t.position = rect.position + Vector2(CARD_PAD, CARD_PAD)
	t.size = Vector2(rect.size.x - 2.0 * CARD_PAD, HudKit.line_height(t))


## The Controls card: as many action rows as fit, windowed on the cursor. A "(n / m)" line
## under the rows says so when the list is scrolled.
func _layout_controls(card: Rect2, rowh: float) -> void:
	var avail: float = card.size.y - _card_head() - CARD_PAD
	var shown: int = 0
	if _ctrl_count > 0:
		shown = mini(_ctrl_count, int(floorf(avail / rowh)))
		if shown < _ctrl_count:
			shown = int(floorf((avail - SCROLL_H) / rowh))
		shown = clampi(shown, 1, _ctrl_count)
	var cc: int = _menu.cursor - _pref_count
	var in_ctrl: bool = cc >= 0 and cc < _ctrl_count
	var first: int = clampi(cc - int(shown / 2.0), 0, _ctrl_count - shown) if in_ctrl else 0
	_ctrl_first = first
	_ctrl_shown = shown
	var row_top: float = card.position.y + _card_head()
	for j in _ctrl_rows.size():
		var r: Dictionary = _ctrl_rows[j]
		if j >= shown:
			(r["host"] as Control).visible = false
			continue
		var mi: int = _pref_count + first + j
		var rect := Rect2(card.position.x + ROW_INSET, row_top + float(j) * rowh, card.size.x - 2.0 * ROW_INSET, rowh)
		_place_row(r, _menu.row_parts(mi), rect)
		_row_rects[mi] = rect
	_scroll.visible = shown < _ctrl_count
	if _scroll.visible:
		var pos: int = (cc if in_ctrl else first) + 1
		_kit.fit_text(_scroll, Loc.t("SET_SCROLL") % [pos, _ctrl_count], card.size.x - 2.0 * CARD_PAD)
		_scroll.position = Vector2(card.position.x + CARD_PAD, row_top + float(shown) * rowh)
		_scroll.size = Vector2(card.size.x - 2.0 * CARD_PAD, SCROLL_H)


func _layout_buttons(w: float, btn_y: float) -> void:
	var x0: float = (w - (2.0 * BTN_W + BTN_GAP)) * 0.5
	for k in 2:
		var b: Dictionary = _buttons[k]
		var rect := Rect2(x0 + float(k) * (BTN_W + BTN_GAP), btn_y, BTN_W, BTN_H)
		var plate: HudKit.Plate = b["plate"]
		plate.position = rect.position
		plate.size = rect.size
		plate.queue_redraw()
		var mi: int = _pref_count + _ctrl_count + k
		var part: Dictionary = _menu.row_parts(mi)
		var l: Label = b["label"]
		_kit.fit_text(l, str(part["label"]), BTN_W - 16.0)
		l.position = rect.position
		l.size = rect.size
		# Under the focus bar the caption is bone, not ink, so it stays readable on rust.
		l.add_theme_color_override("font_color", HudTheme.BONE if _menu.cursor == mi else HudTheme.INK)
		_row_rects[mi] = rect


## One row: the label on the left; on the right a slider track with its value, a chip
## (toggles, choices, a listening binding) or the binding's value text.
func _place_row(r: Dictionary, part: Dictionary, rect: Rect2) -> void:
	var host: Control = r["host"]
	host.visible = true
	host.position = rect.position
	host.size = rect.size
	var rw: float = rect.size.x
	var rh: float = rect.size.y
	var kind: String = str(part["kind"])
	# A binding can list two buttons and two keys, so its value gets the wider zone.
	var zone_w: float = minf(BIND_ZONE_MAX_W, rw * 0.6) if str(part["kind"]) == "binding" else minf(ZONE_MAX_W, rw * 0.5)
	var zone_x: float = rw - EDGE_PAD - zone_w
	var lab: Label = r["label"]
	_kit.fit_text(lab, str(part["label"]), maxf(0.0, zone_x - 2.0 * EDGE_PAD))
	lab.position = Vector2(EDGE_PAD, 0.0)
	lab.size = Vector2(maxf(0.0, zone_x - 2.0 * EDGE_PAD), rh)
	var track: HudKit.Plate = r["track"]
	var fill: HudKit.Plate = r["fill"]
	var value: Label = r["value"]
	var chip: HudKit.Plate = r["chip"]
	track.visible = kind == "slider"
	fill.visible = kind == "slider"
	value.visible = false
	chip.visible = false
	var text: String = str(part["value"])
	match kind:
		"slider":
			var val_x: float = rw - EDGE_PAD - VALUE_W
			_kit.fit_text(value, text, VALUE_W)
			value.position = Vector2(val_x, 0.0)
			value.size = Vector2(VALUE_W, rh)
			value.visible = true
			var tw: float = maxf(0.0, val_x - TRACK_GAP - zone_x)
			track.position = Vector2(zone_x, (rh - TRACK_H) * 0.5)
			track.size = Vector2(tw, TRACK_H)
			track.queue_redraw()
			var frac: float = clampf(float(part["fraction"]), 0.0, 1.0)
			fill.position = track.position + Vector2(2.0, 2.0)
			fill.size = Vector2(maxf(0.0, (tw - 4.0) * frac), TRACK_H - 4.0)
			fill.queue_redraw()
		"choice":
			_set_chip(chip, "‹ %s ›" % text, HudTheme.PAPER_DEEP, HudTheme.INK, zone_w, rw, rh)
		"toggle":
			if bool(part["on"]):
				_set_chip(chip, text, HudTheme.TEAL, HudTheme.INK, zone_w, rw, rh)
			else:
				_set_chip(chip, text, HudTheme.SLATE, HudTheme.BONE, zone_w, rw, rh)
		"binding":
			if text == Loc.t("SET_LISTENING"):
				_set_chip(chip, text, HudTheme.TEAL, HudTheme.BONE, zone_w, rw, rh)
			else:
				_kit.fit_text(value, text, zone_w)
				value.position = Vector2(zone_x, 0.0)
				value.size = Vector2(zone_w, rh)
				value.visible = true


func _set_chip(chip: HudKit.Plate, text: String, bg: Color, fg: Color, max_w: float, rw: float, rh: float) -> void:
	_kit.set_tag(chip, text, bg, fg, max_w)
	chip.position = Vector2(rw - EDGE_PAD - chip.size.x, (rh - chip.size.y) * 0.5)
	chip.visible = true


## The model row a view row is drawn for, in view space (empty when it is not on screen).
func row_rect(i: int) -> Rect2:
	return _row_rects.get(i, Rect2())


## Where the focus bar's fill sits, in view space.
func focus_rect() -> Rect2:
	return Rect2(_focus_bar.position, _focus_bar.size)


func focus_visible() -> bool:
	return _focus_bar.visible


## The row nodes of one section: the Preferences rows, or the Controls rows (pooled, so
## the count is the section's size, not the window's).
func row_hosts(prefs: bool) -> Array:
	var out: Array = []
	for r in (_pref_rows if prefs else _ctrl_rows):
		out.append(r["host"])
	return out


## First model-visible Controls row and how many are on screen.
func control_window() -> Vector2i:
	return Vector2i(_ctrl_first, _ctrl_shown)
