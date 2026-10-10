class_name InputRemap
extends RefCounted
## Rebinding of the m0_* actions (#37), as plain data plus one InputMap writer.
##
## A binding set is {action: {"joy": [button_index, ...], "key": [physical_keycode, ...]}}.
## Only joypad BUTTONS and keys are remappable; stick/axis events on an action
## are left exactly as project.godot defines them. The pure functions here
## (rebind, defaults) never touch InputMap, so they test without global state;
## apply() is the one place that writes it.
##
## Reserved inputs cannot be bound: View (opens the settings screen and cancels
## a rebind), F1 (the keyboard way into settings) and Escape (cancels a rebind).
## That keeps the settings screen reachable whatever the player does.

const SLOT_JOY: String = "joy"
const SLOT_KEY: String = "key"
const RESERVED_JOY: Array[int] = [JOY_BUTTON_BACK]
const RESERVED_KEYS: Array[int] = [KEY_ESCAPE, KEY_F1]

## Action fired by View / F1 to open the settings screen. Not remappable.
const ACT_SETTINGS: String = "m0_settings"

const JOY_NAMES: Dictionary = {
	0: "A", 1: "B", 2: "X", 3: "Y", 4: "View", 5: "Guide", 6: "Start",
	7: "L3", 8: "R3", 9: "LB", 10: "RB", 11: "D-up", 12: "D-down", 13: "D-left", 14: "D-right",
}

static var _defaults: Dictionary = {}


static func actions() -> Array[String]:
	return M0Loop.ALL_ACTIONS


## The shipped bindings (read from the InputMap the first time, before any rebind).
static func defaults() -> Dictionary:
	if _defaults.is_empty():
		_defaults = capture()
	return _defaults.duplicate(true)


## Reads the live InputMap into a binding set.
static func capture() -> Dictionary:
	var out: Dictionary = {}
	for a in actions():
		var joy: Array = []
		var key: Array = []
		if InputMap.has_action(a):
			for ev in InputMap.action_get_events(a):
				if ev is InputEventJoypadButton:
					joy.append(int(ev.button_index))
				elif ev is InputEventKey:
					key.append(_key_code(ev))
		out[a] = {SLOT_JOY: joy, SLOT_KEY: key}
	return out


static func key_code_of(ev: InputEventKey) -> int:
	return _key_code(ev)


static func _key_code(ev: InputEventKey) -> int:
	return int(ev.physical_keycode) if int(ev.physical_keycode) != 0 else int(ev.keycode)


## Writes a binding set into the InputMap (buttons and keys only; axes untouched).
## Unknown actions and malformed entries are ignored, so a hand-edited or old
## settings file can never break input.
static func apply(bindings: Dictionary) -> void:
	for a in actions():
		if not InputMap.has_action(a) or not bindings.has(a) or not (bindings[a] is Dictionary):
			continue
		var entry: Dictionary = bindings[a]
		for ev in InputMap.action_get_events(a):
			if ev is InputEventJoypadButton or ev is InputEventKey:
				InputMap.action_erase_event(a, ev)
		for code in _ints(entry.get(SLOT_JOY, [])):
			var jb := InputEventJoypadButton.new()
			jb.button_index = code
			InputMap.action_add_event(a, jb)
		for code in _ints(entry.get(SLOT_KEY, [])):
			var k := InputEventKey.new()
			k.physical_keycode = code
			InputMap.action_add_event(a, k)


static func _ints(v) -> Array:
	var out: Array = []
	if v is Array:
		for x in v:
			if x is int or x is float:
				out.append(int(x))
	return out


## A binding set cleaned for storage / use: known actions only, ints only, and
## actions the file lacks filled from the defaults.
static func sanitize(raw) -> Dictionary:
	var out: Dictionary = defaults()
	if raw is Dictionary:
		for a in actions():
			if raw.has(a) and raw[a] is Dictionary:
				out[a] = {SLOT_JOY: _ints(raw[a].get(SLOT_JOY, [])), SLOT_KEY: _ints(raw[a].get(SLOT_KEY, []))}
	return out


static func is_reserved(event: InputEvent) -> bool:
	if event is InputEventJoypadButton:
		return RESERVED_JOY.has(int(event.button_index))
	if event is InputEventKey:
		return RESERVED_KEYS.has(_key_code(event))
	return false


## Slot and code of a capturable event, or {} for anything else.
static func slot_of(event: InputEvent) -> Dictionary:
	if event is InputEventJoypadButton:
		return {"slot": SLOT_JOY, "code": int(event.button_index)}
	if event is InputEventKey:
		return {"slot": SLOT_KEY, "code": _key_code(event)}
	return {}


## Binds `event` to `action`. Returns {"ok", "bindings", "message": [key, args...],
## "swapped_with"}. `bindings` is a new set; the input is not modified.
##
## Conflict handling is a swap: if another action already uses that button/key,
## it takes the input the rebound action just gave up, so nothing is silently
## unbound. When the rebound action had nothing in that slot to give (so the
## other action would be left bare), the rebind is refused with a message.
static func rebind(bindings: Dictionary, action: String, event: InputEvent) -> Dictionary:
	var b: Dictionary = bindings.duplicate(true)
	var fail := func(msg: Array) -> Dictionary:
		return {"ok": false, "bindings": bindings, "message": msg, "swapped_with": ""}
	var s: Dictionary = slot_of(event)
	if s.is_empty() or not b.has(action):
		return fail.call(["SET_MSG_UNSUPPORTED"])
	if is_reserved(event):
		return fail.call(["SET_MSG_RESERVED", describe(event)])
	var slot: String = s["slot"]
	var code: int = s["code"]
	var mine: Array = b[action][slot]
	if mine.has(code):
		return {"ok": true, "bindings": b, "message": ["SET_MSG_UNCHANGED", describe(event)], "swapped_with": ""}
	var other: String = ""
	for a in actions():
		if a != action and b.has(a) and b[a][slot].has(code):
			other = a
			break
	if other != "":
		if mine.is_empty():
			return fail.call(["SET_MSG_REFUSED", describe(event), action_label(other)])
		var theirs: Array = b[other][slot].duplicate()
		theirs.erase(code)
		for m in mine:
			if not theirs.has(m):
				theirs.append(m)
		b[other][slot] = theirs
	b[action][slot] = [code]
	if other != "":
		return {"ok": true, "bindings": b, "message": ["SET_MSG_SWAPPED", describe(event), action_label(other)], "swapped_with": other}
	return {"ok": true, "bindings": b, "message": ["SET_MSG_BOUND", action_label(action), describe(event)], "swapped_with": ""}


static func describe(event: InputEvent) -> String:
	var s: Dictionary = slot_of(event)
	if s.is_empty():
		return "?"
	return code_label(s["slot"], s["code"])


static func code_label(slot: String, code: int) -> String:
	if slot == SLOT_JOY:
		return str(JOY_NAMES.get(code, "Btn%d" % code))
	var name: String = OS.get_keycode_string(code)
	return name if name != "" else "Key%d" % code


## "m0_tab_prev" -> its translated name.
static func action_label(action: String) -> String:
	return Loc.t("SET_ACT_" + action.trim_prefix("m0_").to_upper())


## Compact "Pad: LB  Key: Q" text for a row.
static func binding_text(entry: Dictionary) -> String:
	var joy: PackedStringArray = []
	for c in entry.get(SLOT_JOY, []):
		joy.append(code_label(SLOT_JOY, int(c)))
	var key: PackedStringArray = []
	for c in entry.get(SLOT_KEY, []):
		key.append(code_label(SLOT_KEY, int(c)))
	return "%s %s  %s %s" % [Loc.t("SET_PAD"), "/".join(joy) if not joy.is_empty() else "-", Loc.t("SET_KEY"), "/".join(key) if not key.is_empty() else "-"]
