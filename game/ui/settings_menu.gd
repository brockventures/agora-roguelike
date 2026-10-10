class_name SettingsMenu
extends RefCounted
## The settings screen (#37): text size, colors, language, and one row per m0_*
## action for rebinding, plus reset and close. A pure model: Main owns the node
## that draws text() and routes events to handle_event().
##
## Fully gamepad-driven, and deliberately NOT through the m0_* actions (which the
## player can rebind): navigation uses Godot's built-in ui_* actions (D-pad, left
## stick, A, B) so no binding the player picks can lock them out of this screen.
##   Up / Down   move          Left / Right  change a value
##   A           change / rebind the row    B / View  close (View also cancels a rebind)
## On an action row, A starts listening: the next joypad button or key becomes the
## binding. A conflict swaps the two actions (see InputRemap.rebind).

signal closed

enum Row { SCALE, PALETTE, LANGUAGE, CRT, ACTION, RESET, CLOSE }

var settings: AccessibilitySettings = null
var is_open: bool = false
var cursor: int = 0
## Action waiting for its new input, or "" when not listening.
var listening_action: String = ""
## Last result line as [translation key, args...]; shown under the list.
var message: Array = []
var _held: Dictionary = {}


func _init(p_settings: AccessibilitySettings = null) -> void:
	settings = p_settings if p_settings != null else AccessibilitySettings.new()


func open() -> void:
	is_open = true
	cursor = 0
	listening_action = ""
	message = []
	_held.clear()


func close() -> void:
	if is_open:
		is_open = false
		listening_action = ""
		closed.emit()


## One entry per selectable row: {"kind": Row, "action": String}.
func rows() -> Array:
	var out: Array = [{"kind": Row.SCALE}, {"kind": Row.PALETTE}, {"kind": Row.LANGUAGE}, {"kind": Row.CRT}]
	for a in InputRemap.actions():
		out.append({"kind": Row.ACTION, "action": a})
	out.append({"kind": Row.RESET})
	out.append({"kind": Row.CLOSE})
	return out


func move(dir: int) -> void:
	var n: int = rows().size()
	cursor = (cursor + dir + n) % n


## Row text: "> label   value" for the cursor row.
func row_text(i: int, row: Dictionary) -> String:
	var mark: String = ">" if i == cursor else " "
	match int(row["kind"]):
		Row.SCALE:
			return tr_row(mark, "SET_TEXT_SIZE", "< %d%% >" % int(round(settings.text_scale * 100.0)))
		Row.PALETTE:
			return tr_row(mark, "SET_PALETTE", "< %s >" % Palette.label(settings.palette))
		Row.LANGUAGE:
			return tr_row(mark, "SET_LANGUAGE", "< %s >" % Loc.locale_label())
		Row.CRT:
			return tr_row(mark, "SET_CRT", "< %s >" % Loc.t("SET_ON" if settings.crt_filter else "SET_OFF"))
		Row.ACTION:
			var a: String = str(row["action"])
			var value: String = Loc.t("SET_LISTENING") if a == listening_action else InputRemap.binding_text(settings.bindings.get(a, {}))
			return "%s %s   %s" % [mark, InputRemap.action_label(a), value]
		Row.RESET:
			return "%s %s" % [mark, Loc.t("SET_RESET")]
	return "%s %s" % [mark, Loc.t("SET_CLOSE")]


func tr_row(mark: String, key: String, value: String) -> String:
	return "%s %s   %s" % [mark, Loc.t(key), value]


## Index of the first row text() shows for `max_rows`.
func first_visible(max_rows: int = 99) -> int:
	var n: int = rows().size()
	var shown: int = clampi(max_rows, 3, n)
	return clampi(cursor - shown / 2, 0, n - shown)


## Line of text(max_rows) that holds the cursor row (title and a blank line come first).
func cursor_line(max_rows: int = 99) -> int:
	return 2 + cursor - first_visible(max_rows)


## The screen text. Only `max_rows` rows are shown, scrolled so the cursor stays
## in view (larger text scales leave room for fewer rows).
func text(max_rows: int = 99) -> String:
	var all: Array = rows()
	var n: int = all.size()
	var shown: int = clampi(max_rows, 3, n)
	var first: int = first_visible(max_rows)
	var out: PackedStringArray = [Loc.t("SET_TITLE"), ""]
	for i in range(first, first + shown):
		out.append(row_text(i, all[i]))
	out.append("")
	if listening_action != "":
		out.append(Loc.t("SET_LISTEN_HINT"))
	elif not message.is_empty():
		out.append(Loc.t(str(message[0])) % message.slice(1))
	else:
		out.append(Loc.t("SET_HINT"))
	if shown < n:
		out.append(Loc.t("SET_SCROLL") % [cursor + 1, n])
	return "\n".join(out)


## Routes one input event. Returns true when the screen consumed it (always,
## while it is open, so nothing leaks to the game behind it).
func handle_event(event: InputEvent) -> bool:
	if not is_open:
		return false
	if listening_action != "":
		_listen(event)
		return true
	if event is InputEventJoypadMotion:
		_stick(event)
		return true
	if event.is_action_pressed(InputRemap.ACT_SETTINGS) and not event.is_echo():
		close()
		return true
	if not event.is_pressed():
		return true
	if event.is_action_pressed("ui_up", true):
		move(-1)
	elif event.is_action_pressed("ui_down", true):
		move(1)
	elif event.is_action_pressed("ui_left", true):
		_change(-1)
	elif event.is_action_pressed("ui_right", true):
		_change(1)
	elif event.is_action_pressed("ui_accept") and not event.is_echo():
		_activate()
	elif event.is_action_pressed("ui_cancel") and not event.is_echo():
		close()
	return true


## A held stick steps once per push, like the game's own stick handling.
func _stick(event: InputEventJoypadMotion) -> void:
	for a in ["ui_up", "ui_down", "ui_left", "ui_right"]:
		if event.is_action_pressed(a):
			if not _held.get(a, false):
				_held[a] = true
				match a:
					"ui_up": move(-1)
					"ui_down": move(1)
					"ui_left": _change(-1)
					"ui_right": _change(1)
		elif event.is_action(a):
			_held[a] = false


func _change(dir: int) -> void:
	var row: Dictionary = rows()[cursor]
	match int(row["kind"]):
		Row.SCALE:
			settings.step_text_scale(dir)
		Row.PALETTE:
			settings.step_palette(dir)
		Row.LANGUAGE:
			settings.step_locale(dir)
		Row.CRT:
			settings.set_crt_filter(not settings.crt_filter)


func _activate() -> void:
	var row: Dictionary = rows()[cursor]
	match int(row["kind"]):
		Row.SCALE, Row.PALETTE, Row.LANGUAGE, Row.CRT:
			_change(1)
		Row.ACTION:
			listening_action = str(row["action"])
			message = []
		Row.RESET:
			settings.reset_defaults()
			message = ["SET_MSG_RESET"]
		Row.CLOSE:
			close()


## While listening, the next button or key press is the new binding.
func _listen(event: InputEvent) -> void:
	if not (event is InputEventJoypadButton or event is InputEventKey):
		return
	if not event.is_pressed() or event.is_echo():
		return
	var s: Dictionary = InputRemap.slot_of(event)
	# View and Escape cancel; F1 is reserved too but only refused, below.
	if (event is InputEventJoypadButton and int(event.button_index) == JOY_BUTTON_BACK) or (event is InputEventKey and InputRemap.key_code_of(event) == KEY_ESCAPE):
		listening_action = ""
		message = ["SET_MSG_CANCELLED"]
		return
	var r: Dictionary = settings.rebind(listening_action, event)
	message = r["message"]
	if bool(r["ok"]) or not s.is_empty():
		listening_action = ""
