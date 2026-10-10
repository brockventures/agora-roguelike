class_name Loc
extends RefCounted
## Localization front door (#40). Display only: nothing here touches sim state,
## saves, replays or hashes, which keep the stable English ids.
##
## Pipeline: game/localization/agora_strings.csv -> TranslationServer (registered in
## project.godot). UI code calls tr("KEY") (or Loc.t("KEY") from a static func,
## where tr() is unavailable) with a stable KEY and keeps %s/%d placeholders in the
## translated text, never in the key.
##
## Data files (crises.json, parachutes.json, stations, commodities) keep their
## English text as the source of truth and as the fallback. Their display text is
## looked up through a key DERIVED from the id (CRISIS_<ID>_NAME, PERK_<ID>_NAME,
## STATION_<ID>, COMMODITY_<ID>, ...) via Loc.data_text(), which returns the data
## file's English when the CSV has no row. Adding a language is a new CSV column.

## Locale codes the in-game selector cycles through. "pseudo" is a QA locale:
## English text run through Godot's pseudolocalization (accents, doubled vowels,
## +30% length, [brackets]) so truncation shows up without a real translation.
const LOCALE_EN: String = "en"
const LOCALE_PSEUDO: String = "pseudo"
const CHOICES: Array[String] = [LOCALE_EN, LOCALE_PSEUDO]
## Environment overrides for the first locale: AGORA_PSEUDO=1, or AGORA_LOCALE=<code>.
const PSEUDO_ENV: String = "AGORA_PSEUDO"
const LOCALE_ENV: String = "AGORA_LOCALE"

static var _current: String = LOCALE_EN


## Translate a key (static-context twin of tr()).
static func t(key: String) -> String:
	return TranslationServer.translate(key)


## Display text for a data-file entry: the CSV row for key when there is one,
## otherwise the data file's own English.
static func data_text(key: String, fallback: String) -> String:
	var s: String = TranslationServer.translate(key)
	if s == key:
		return fallback
	return s


## "Logistics & Smuggling" -> "LOGISTICS_SMUGGLING".
static func slug(s: String) -> String:
	var out: String = ""
	var last_us: bool = true
	for ch in s.to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
			out += ch
			last_us = false
		elif not last_us:
			out += "_"
			last_us = true
	return out.rstrip("_")


static func station(id: String) -> String:
	return data_text("STATION_" + slug(id), StationMarket.station_name(id))


static func commodity(id: String) -> String:
	return data_text("COMMODITY_" + slug(id), id)


## A book maker's display name: the default Ares Heavy, or any baron by id.
## `fallback` is the data file's English (the baron's name, upper-cased).
static func maker(id: String = StationMarket.MAKER_ID, fallback: String = "") -> String:
	var english: String = StationMarket.MAKER_NAME if id == StationMarket.MAKER_ID else fallback
	return data_text("MAKER_" + slug(id), english)


## The short ladder tag for a maker ("ARES", "TITAN", "SOL").
static func maker_tag(id: String, fallback: String = "") -> String:
	return data_text("MAKERTAG_" + slug(id), fallback if fallback != "" else maker(id))


static func stage(stage_name: String) -> String:
	return data_text("STAGE_" + slug(stage_name), stage_name)


static func tab(index: int) -> String:
	return data_text("TAB_" + slug(M0Loop.TAB_NAMES[index]), M0Loop.TAB_NAMES[index])


static func category(cat: String) -> String:
	return data_text("CAT_" + slug(cat), cat)


static func crisis_name(c: Dictionary) -> String:
	return data_text("CRISIS_%s_NAME" % slug(str(c.get("id", ""))), str(c.get("name", "")))


static func tier_label(tier: String, fallback: String) -> String:
	return data_text("CRISIS_TIER_" + slug(tier), fallback)


## The crisis headline re-rendered in the current locale from its {rounds}/{commodity}/
## {station} template; the stored English text is the fallback.
static func crisis_text(c: Dictionary) -> String:
	var key: String = "CRISIS_%s_HEADLINE" % slug(str(c.get("id", "")))
	var tpl: String = TranslationServer.translate(key)
	if tpl == key:
		return str(c.get("text", ""))
	var st: String = str(c.get("station", ""))
	return tpl.replace("{rounds}", str(int(c.get("rounds", 0)))).replace("{commodity}", commodity(str(c.get("commodity", "")))).replace("{station}", station(st) if st != "*" else "*")


static func perk_name(row: Dictionary) -> String:
	return data_text("PERK_%s_NAME" % slug(str(row.get("id", ""))), str(row.get("name", "")))


static func perk_branch(branch: String) -> String:
	return data_text("PERK_BRANCH_" + slug(branch), branch)


# --- Deferred arguments (ticker headlines re-render on a language swap) ---

## A headline argument that must be localized at render time, not at post time.
static func station_arg(id: String, upper: bool = true) -> Dictionary:
	return {"loc": "station", "id": id, "upper": upper}


static func commodity_arg(id: String, upper: bool = true) -> Dictionary:
	return {"loc": "commodity", "id": id, "upper": upper}


static func key_arg(key: String) -> Dictionary:
	return {"loc": "key", "id": key}


## format(key, args): translate key, resolve deferred args, apply the % operator.
static func format(key: String, args: Array = []) -> String:
	var tpl: String = TranslationServer.translate(key)
	if args.is_empty():
		return tpl
	var out: Array = []
	for a in args:
		if a is Dictionary and a.has("loc"):
			var s: String
			match a["loc"]:
				"station":
					s = station(str(a["id"]))
				"commodity":
					s = commodity(str(a["id"]))
				_:
					s = TranslationServer.translate(str(a["id"]))
			out.append(s.to_upper() if bool(a.get("upper", false)) else s)
		else:
			out.append(a)
	return tpl % out


# --- Locale selection (hot swap) ---

static func current() -> String:
	return _current


## Switches the whole UI: the readouts re-read tr() every frame (Main._process), so
## the next frame is fully in the new language. False for an unknown code.
static func set_locale(code: String) -> bool:
	if not CHOICES.has(code):
		return false
	_current = code
	if code == LOCALE_PSEUDO:
		TranslationServer.set_locale(LOCALE_EN)
		TranslationServer.pseudolocalization_enabled = true
	else:
		TranslationServer.pseudolocalization_enabled = false
		TranslationServer.set_locale(code)
	return true


## Next language in CHOICES (wraps). Returns the new code.
static func cycle_locale() -> String:
	var i: int = CHOICES.find(_current)
	set_locale(CHOICES[(i + 1) % CHOICES.size()])
	return _current


static func locale_label() -> String:
	return t("LANG_" + slug(_current))


## Applies AGORA_PSEUDO=1 / AGORA_LOCALE=<code>; otherwise leaves the locale alone.
static func apply_env() -> void:
	if OS.get_environment(PSEUDO_ENV) in ["1", "true", "yes"]:
		set_locale(LOCALE_PSEUDO)
	elif OS.get_environment(LOCALE_ENV) != "":
		set_locale(OS.get_environment(LOCALE_ENV))
