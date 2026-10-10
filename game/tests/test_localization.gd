extends RefCounted
## Localization pipeline (#40): the CSV is the single source of UI text, every key
## the code asks for exists, data-file text is covered by derived keys, and the
## language selector hot-swaps the live HUD.

const CSV_PATH := "res://localization/agora_strings.csv"
const SCAN_DIRS := ["res://ui", "res://scenes", "res://core"]
## Literal keys the scan recognises (the prefixes the code base uses for tr keys).
## Sound ids (ORDER_FILL, TICKER_BLIP) share prefixes with text keys; they are not UI text.
const NOT_TEXT_FILES := ["tactile_audio.gd"]
const KEY_PREFIXES := "HUD|HL|REJ|SIDE|BOARD|CH11|CRISIS|SUM|PERKS?|SLEEP|SET|TICKER|FLEET|ORDER|LANG|MAKER"


static func csv_rows() -> Dictionary:
	var f := FileAccess.open(CSV_PATH, FileAccess.READ)
	var rows: Dictionary = {}
	if f == null:
		return rows
	f.get_csv_line()  # header
	while not f.eof_reached():
		var r: PackedStringArray = f.get_csv_line()
		if r.size() >= 2 and r[0] != "":
			rows[r[0]] = r[1]
	return rows


static func script_paths() -> Array:
	var out: Array = []
	for d in SCAN_DIRS:
		var dir := DirAccess.open(d)
		if dir == null:
			continue
		for f in dir.get_files():
			if f.ends_with(".gd") and not NOT_TEXT_FILES.has(f):
				out.append(d.path_join(f))
	return out


func test_csv_header_and_uniqueness() -> String:
	var f := FileAccess.open(CSV_PATH, FileAccess.READ)
	if f == null:
		return "missing %s" % CSV_PATH
	var head: PackedStringArray = f.get_csv_line()
	if head.size() < 2 or head[0] != "keys" or head[1] != "en":
		return "header must start keys,en: %s" % str(head)
	var seen: Dictionary = {}
	while not f.eof_reached():
		var r: PackedStringArray = f.get_csv_line()
		if r.size() == 1 and r[0] == "":
			continue
		if r.size() != head.size():
			return "row has %d columns, header %d: %s" % [r.size(), head.size(), str(r)]
		if seen.has(r[0]):
			return "duplicate key %s" % r[0]
		if r[1] == "":
			return "empty English for %s" % r[0]
		seen[r[0]] = true
	if seen.size() < 100:
		return "suspiciously few strings: %d" % seen.size()
	return "ok"


func test_project_registers_the_translation_and_pseudo_settings() -> String:
	var t: PackedStringArray = ProjectSettings.get_setting("internationalization/locale/translations")
	if not t.has("res://localization/agora_strings.en.translation"):
		return "translation not registered: %s" % str(t)
	if absf(float(ProjectSettings.get_setting("internationalization/pseudolocalization/expansion_ratio")) - 0.3) > 0.001:
		return "pseudo expansion ratio should be 0.3"
	if str(ProjectSettings.get_setting("internationalization/pseudolocalization/prefix")) != "[":
		return "pseudo brackets missing"
	if str(ProjectSettings.get_setting("internationalization/locale/fallback")) != "en":
		return "fallback locale must be en"
	return "ok"


func test_every_key_in_code_exists_in_the_csv() -> String:
	var rows := csv_rows()
	var lit := RegEx.create_from_string("\"((?:%s)_[A-Z0-9_]*[A-Z0-9])\"" % KEY_PREFIXES)
	var missing: Array = []
	var used := 0
	for path in script_paths():
		var src: String = FileAccess.get_file_as_string(path)
		for m in lit.search_all(src):
			used += 1
			if not rows.has(m.get_string(1)):
				missing.append("%s: %s" % [path, m.get_string(1)])
	if used < 80:
		return "key scan found only %d literals; the regex is stale" % used
	return "ok" if missing.is_empty() else "keys used in code but absent from the CSV: %s" % str(missing)


func test_every_csv_key_is_reachable() -> String:
	# A key nobody asks for is dead weight for translators: it must be used
	# literally, or belong to a derived family (data-file ids, enum names).
	var rows := csv_rows()
	var corpus: String = ""
	for path in script_paths():
		corpus += FileAccess.get_file_as_string(path)
	var derived := ["STATION_", "COMMODITY_", "STAGE_", "TAB_", "CAT_", "CRISIS_TIER_", "PERK_BRANCH_", "MAKER_", "LANG_", "SET_ACT_", "SET_PALETTE_"]
	var dead: Array = []
	for k in rows:
		var fam := false
		for p in derived:
			fam = fam or str(k).begins_with(p)
		if str(k).begins_with("CRISIS_") and (str(k).ends_with("_NAME") or str(k).ends_with("_HEADLINE")):
			fam = true
		if str(k).begins_with("PERK_") and str(k).ends_with("_NAME"):
			fam = true
		if ["ORDER_BUY", "ORDER_SELL"].has(k):
			fam = true
		if not fam and not corpus.contains("\"%s\"" % k):
			dead.append(k)
	return "ok" if dead.is_empty() else "CSV keys no code uses: %s" % str(dead)


func test_data_files_have_derived_keys_and_english_matches() -> String:
	var rows := csv_rows()
	var cr: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/crises.json"))
	var pk: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/parachutes.json"))
	var problems: Array = []
	var want := func(key: String, english: String) -> void:
		if not rows.has(key):
			problems.append("missing %s" % key)
		elif rows[key] != english:
			problems.append("%s is '%s' but the data file says '%s'" % [key, rows[key], english])
	for t in cr["tiers"]:
		want.call("CRISIS_TIER_" + Loc.slug(t), str(cr["tiers"][t]["label"]))
	for c in cr["crises"]:
		want.call("CRISIS_%s_NAME" % Loc.slug(c["id"]), str(c["name"]))
		want.call("CRISIS_%s_HEADLINE" % Loc.slug(c["id"]), str(c["headline"]))
	for p in pk["perks"]:
		want.call("PERK_%s_NAME" % Loc.slug(p["id"]), str(p["name"]))
		want.call("PERK_BRANCH_" + Loc.slug(p["branch"]), str(p["branch"]))
	for st in StationMarket.STATION_NAMES:
		want.call("STATION_" + Loc.slug(st), str(StationMarket.STATION_NAMES[st]))
	for c in Transit.COMMODITIES:
		want.call("COMMODITY_" + Loc.slug(c), c)
	want.call("MAKER_" + Loc.slug(StationMarket.MAKER_ID), StationMarket.MAKER_NAME)
	for i in M0Loop.TAB_NAMES.size():
		want.call("TAB_" + Loc.slug(M0Loop.TAB_NAMES[i]), M0Loop.TAB_NAMES[i])
	for s in ["NORMAL", "UNSTABLE", "CRITICAL", "IMMINENT", "COLLAPSED"]:
		want.call("STAGE_" + s, s)
	return "ok" if problems.is_empty() else str(problems)


func test_english_is_the_default_and_unknown_locales_fall_back() -> String:
	Loc.set_locale(Loc.LOCALE_EN)
	if Loc.t("HUD_TITLE") != "AGORA" or tr_test("HUD_PAUSED") != "PAUSED":
		return "English strings not resolved"
	TranslationServer.set_locale("de")
	var fell_back: bool = Loc.t("HUD_TITLE") == "AGORA"
	TranslationServer.set_locale("en")
	if not fell_back:
		return "a locale without a column must fall back to English"
	if Loc.data_text("NO_SUCH_KEY", "fallback text") != "fallback text":
		return "data_text must return the data file's English for an unknown key"
	if Loc.set_locale("xx") or Loc.current() != Loc.LOCALE_EN:
		return "unknown locale accepted"
	return "ok"


func tr_test(key: String) -> String:
	return tr(key)


func test_pseudo_locale_expands_and_brackets_and_keeps_placeholders() -> String:
	Loc.set_locale(Loc.LOCALE_PSEUDO)
	var s: String = Loc.t("HUD_DOOMSDAY")
	var en_len: int = "DOOMSDAY %d:%02d %s".length()
	var ok_form: bool = s.begins_with("[") and s.ends_with("]") and s.length() >= int(en_len * 1.3)
	var formatted: String = s % [10, 0, "x"]
	Loc.set_locale(Loc.LOCALE_EN)
	if not ok_form:
		return "pseudo string not bracketed/expanded: %s" % s
	if not formatted.contains("10:00"):
		return "placeholders broke under pseudo: %s" % formatted
	return "ok"


func test_agora_pseudo_env_enables_the_pseudo_locale() -> String:
	OS.set_environment(Loc.PSEUDO_ENV, "1")
	Loc.apply_env()
	var on: bool = Loc.current() == Loc.LOCALE_PSEUDO and TranslationServer.pseudolocalization_enabled
	OS.unset_environment(Loc.PSEUDO_ENV)
	Loc.set_locale(Loc.LOCALE_EN)
	return "ok" if on and not TranslationServer.pseudolocalization_enabled else "AGORA_PSEUDO=1 did not switch to pseudo"


func _scene() -> Node:
	var scene = load("res://scenes/main.tscn").instantiate()
	scene.initialize_systems(RunController.new(null, 84))
	scene._resolve_child_nodes()
	scene._build_readouts()
	return scene


func test_language_action_hot_swaps_the_hud() -> String:
	Loc.set_locale(Loc.LOCALE_EN)
	var scene := _scene()
	var lp: M0Loop = scene.loop
	lp.set_tab(M0Loop.Tab.MARKET)
	scene.hud.post_transit_event("arrived", "earth", "mars", "ORE", 5)
	scene._refresh_readouts()
	var en_header: String = scene.header_label.text
	var en_hint: String = scene.hint_label.text
	var en_side: String = scene.sidebar_label.text
	var en_board: String = scene._board_text()
	var en_ticker: String = scene.ticker_labels[0].text
	var err: String = ""
	if not en_header.begins_with("AGORA") or not en_ticker.begins_with("TRANSIT: FLEET ARRIVAL: 5 ORE docked at ARCADIA FOUNDRIES"):
		err = "English baseline wrong: %s | %s" % [en_header, en_ticker]
	if err == "" and not lp.dispatch_action(M0Loop.ACT_LOCALE):
		err = "language action not handled"
	if err == "":
		scene._refresh_readouts()
		if Loc.current() != Loc.LOCALE_PSEUDO:
			err = "action did not select the pseudo locale"
		elif scene.header_label.text == en_header or scene.hint_label.text == en_hint or scene.sidebar_label.text == en_side or scene._board_text() == en_board:
			err = "a readout did not change on swap"
		elif scene.ticker_labels[0].text == en_ticker:
			err = "a headline already on the ticker did not re-render on swap"
		elif scene.header_label.text.contains("[[["):
			err = "header translated twice: %s" % scene.header_label.text
	if err == "":
		lp.dispatch_action(M0Loop.ACT_LOCALE)
		scene._refresh_readouts()
		if scene.header_label.text != en_header or scene.hint_label.text != en_hint or scene.ticker_labels[0].text != en_ticker or scene.sidebar_label.text != en_side:
			err = "swapping back did not restore English"
	var all_off: bool = true
	for l in [scene.header_label, scene.hint_label, scene.map_label, scene.sidebar_label, scene.market_label, scene.resolution_label, scene.sleep_label] + scene.ticker_labels:
		all_off = all_off and l.auto_translate_mode == Node.AUTO_TRANSLATE_MODE_DISABLED
	scene.free()
	Loc.set_locale(Loc.LOCALE_EN)
	if err != "":
		return err
	return "ok" if all_off else "a HUD label still auto-translates (would double-translate)"


func test_language_action_works_under_every_overlay() -> String:
	Loc.set_locale(Loc.LOCALE_EN)
	var rc := RunController.new(null, 9)
	var lp := M0Loop.new(OrbitalHUD.new(rc))
	var results: Array = []
	for state in [M0Loop.OVERLAY_NONE, M0Loop.OVERLAY_CHAPTER_11, M0Loop.OVERLAY_COLLAPSED, M0Loop.OVERLAY_CRISIS]:
		lp.overlay_state = state
		results.append(lp.dispatch_action(M0Loop.ACT_LOCALE))
	Loc.set_locale(Loc.LOCALE_EN)
	return "ok" if not results.has(false) else "language action refused in some state: %s" % str(results)


func test_derived_text_follows_the_locale() -> String:
	Loc.set_locale(Loc.LOCALE_PSEUDO)
	var st: String = Loc.station("mars")
	var tag: String = GamepadFocus.rejection_message("INSUFFICIENT_CR")
	var crisis_name: String = Loc.crisis_name({"id": "localized_shortage", "name": "Localized Shortage"})
	Loc.set_locale(Loc.LOCALE_EN)
	if st == "Arcadia Foundries" or tag == "Not enough CR" or crisis_name == "Localized Shortage":
		return "derived text did not change under pseudo: %s / %s / %s" % [st, tag, crisis_name]
	return "ok"
