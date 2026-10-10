class_name AccessibilitySettings
extends RefCounted
## Player accessibility settings (#37): text scale, colorblind palette, control
## bindings, language, and the alert volume / mute (Epic 4 follow-ups, #104). Persisted to <save dir>/settings.json through SaveStore
## (same atomic envelope as the profile and run slot), so a test pointed at a temp
## directory never touches the real user://.
##
## Display and input only: nothing here reaches sim state, saves of a run, replays
## or hashes.

## Selectable text scales (1.0 is the shipped layout).
const TEXT_SCALES: Array[float] = [1.0, 1.15, 1.3]
## Valve's Deck Verified floor: the smallest on-screen text is at least ~12 px at 1280x800.
const MIN_FONT_SIZE: int = 12

signal changed

var text_scale: float = 1.0
var palette: String = Palette.DEFAULT
var locale: String = Loc.LOCALE_EN
## Optional retro CRT filter (scanlines, chromatic fringe, phosphor glow). Off by default
## since the HUD re-skin (#105): the Scavengers Reign look is the default, CRT is opt-in.
var crt_filter: bool = false
## Alert sounds (warning and critical headlines): linear volume 0..1 in 10% steps, and a
## mute toggle. They drive the Alerts bus only; UI clicks and market chimes are untouched.
const ALERT_VOLUME_STEP: float = 0.1
const ALERT_VOLUME_DEFAULT: float = 1.0
var alert_volume: float = ALERT_VOLUME_DEFAULT
var alert_mute: bool = false
var bindings: Dictionary = {}


func _init() -> void:
	bindings = InputRemap.defaults()


func scale_index() -> int:
	return maxi(0, TEXT_SCALES.find(text_scale))


func set_text_scale(s: float) -> bool:
	for c in TEXT_SCALES:
		if absf(c - s) < 0.001:
			text_scale = c
			changed.emit()
			return true
	return false


## Steps the scale by `dir` (+1 / -1), clamped at the ends.
func step_text_scale(dir: int) -> void:
	text_scale = TEXT_SCALES[clampi(scale_index() + dir, 0, TEXT_SCALES.size() - 1)]
	changed.emit()


func set_palette(id: String) -> bool:
	if not Palette.CHOICES.has(id):
		return false
	palette = id
	Palette.set_current(id)
	changed.emit()
	return true


func step_palette(dir: int) -> void:
	var n: int = Palette.CHOICES.size()
	set_palette(Palette.CHOICES[(Palette.CHOICES.find(palette) + dir + n) % n])


func set_locale(code: String) -> bool:
	if not Loc.set_locale(code):
		return false
	locale = code
	changed.emit()
	return true


func step_locale(dir: int) -> void:
	var n: int = Loc.CHOICES.size()
	set_locale(Loc.CHOICES[(Loc.CHOICES.find(Loc.current()) + dir + n) % n])


## Rebinds one action and writes it to the InputMap. See InputRemap.rebind.
func rebind(action: String, event: InputEvent) -> Dictionary:
	var r: Dictionary = InputRemap.rebind(bindings, action, event)
	if bool(r["ok"]):
		bindings = r["bindings"]
		InputRemap.apply(bindings)
		changed.emit()
	return r


func set_crt_filter(on: bool) -> void:
	crt_filter = on
	changed.emit()


func set_alert_volume(v: float) -> void:
	alert_volume = snappedf(clampf(v, 0.0, 1.0), ALERT_VOLUME_STEP)
	changed.emit()


## Steps the alert volume by `dir` tenths, clamped at the ends.
func step_alert_volume(dir: int) -> void:
	set_alert_volume(alert_volume + float(dir) * ALERT_VOLUME_STEP)


func set_alert_mute(on: bool) -> void:
	alert_mute = on
	changed.emit()


## Back to the shipped bindings, palette, scale and look (CRT off). Language is left alone.
func reset_defaults() -> void:
	text_scale = 1.0
	crt_filter = false
	alert_volume = ALERT_VOLUME_DEFAULT
	alert_mute = false
	set_palette(Palette.DEFAULT)
	bindings = InputRemap.defaults()
	InputRemap.apply(bindings)
	changed.emit()


## Pushes everything held here into the live game state (InputMap, Palette, Loc).
func apply_all(apply_locale: bool = true) -> void:
	Palette.set_current(palette)
	InputRemap.apply(bindings)
	if apply_locale:
		Loc.set_locale(locale)


func to_dict() -> Dictionary:
	return {"text_scale": text_scale, "palette": palette, "locale": locale, "crt_filter": crt_filter, "alert_volume": alert_volume, "alert_mute": alert_mute, "bindings": bindings.duplicate(true)}


## Restores from a stored dictionary; every field is validated and a bad or
## missing one keeps its default.
static func from_dict(d: Dictionary) -> AccessibilitySettings:
	var s := AccessibilitySettings.new()
	var sc = d.get("text_scale", 1.0)
	if (sc is float or sc is int):
		for c in TEXT_SCALES:
			if absf(c - float(sc)) < 0.001:
				s.text_scale = c
	if Palette.CHOICES.has(str(d.get("palette", ""))):
		s.palette = str(d["palette"])
	if Loc.CHOICES.has(str(d.get("locale", ""))):
		s.locale = str(d["locale"])
	if d.has("crt_filter") and d["crt_filter"] is bool:
		s.crt_filter = d["crt_filter"]
	var av = d.get("alert_volume", ALERT_VOLUME_DEFAULT)
	if (av is float or av is int) and not is_nan(float(av)):
		s.alert_volume = snappedf(clampf(float(av), 0.0, 1.0), ALERT_VOLUME_STEP)
	if d.has("alert_mute") and d["alert_mute"] is bool:
		s.alert_mute = d["alert_mute"]
	s.bindings = InputRemap.sanitize(d.get("bindings", {}))
	return s


func save(store: SaveStore) -> Error:
	return store.save_settings(to_dict())


## Loads from the store; defaults when there is no usable file.
static func load_from(store: SaveStore) -> AccessibilitySettings:
	var r: Dictionary = store.load_settings()
	return from_dict(r) if not r.is_empty() else AccessibilitySettings.new()
