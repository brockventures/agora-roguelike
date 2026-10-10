class_name AccessibilitySettings
extends RefCounted
## Player accessibility settings (#37): text scale, colorblind palette, control
## bindings and language. Persisted to <save dir>/settings.json through SaveStore
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


## Back to the shipped bindings, palette and scale. Language is left alone.
func reset_defaults() -> void:
	text_scale = 1.0
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
	return {"text_scale": text_scale, "palette": palette, "locale": locale, "bindings": bindings.duplicate(true)}


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
	s.bindings = InputRemap.sanitize(d.get("bindings", {}))
	return s


func save(store: SaveStore) -> Error:
	return store.save_settings(to_dict())


## Loads from the store; defaults when there is no usable file.
static func load_from(store: SaveStore) -> AccessibilitySettings:
	var r: Dictionary = store.load_settings()
	return from_dict(r) if not r.is_empty() else AccessibilitySettings.new()
