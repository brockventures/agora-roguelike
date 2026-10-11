extends RefCounted
## Tests for the first-hour tutorial's surface (#36 First-Hour Onboarding Flow, task 3): the
## beat copy is CSV keys, every beat renders as desk notes with no debug text, the copy names the
## default buttons and the permanent View hint, and the held footer reads A as continue.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const CSV_PATH := "res://localization/agora_strings.csv"


func _main() -> MainScene:
	var m: MainScene = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	m.initialize_systems(RunController.new(null, 84))
	m._resolve_child_nodes()
	m._build_readouts()
	m.enable_onboarding()
	return m


func _keys_of(b: Dictionary) -> Array:
	var out: Array = [str(b["title_key"])]
	out.append_array(b["line_keys"])
	return out


func test_every_beat_key_has_english_copy() -> String:
	var rows: Dictionary = (load("res://tests/test_localization.gd") as GDScript).csv_rows()
	var missing: Array = []
	var n: int = 0
	for b in Onboarding.shipped()["beats"]:
		for k in _keys_of(b):
			n += 1
			if not rows.has(k):
				missing.append(k)
			elif str(rows[k]).strip_edges() == "" or str(rows[k]).contains("ONB_"):
				missing.append("%s (empty or self-referencing)" % k)
	if not rows.has("ONB_HINT") or not rows.has("HUD_PROMPT_NEXT"):
		missing.append("ONB_HINT / HUD_PROMPT_NEXT")
	if n < 20:
		return "only %d beat keys found" % n
	return "ok" if missing.is_empty() else "beat copy missing: %s" % str(missing)


func test_copy_names_the_default_buttons_and_the_view_hint() -> String:
	var rows: Dictionary = (load("res://tests/test_localization.gd") as GDScript).csv_rows()
	var need: Dictionary = {
		"tabs": ["LB/RB", "RB"], "order": ["R-STICK", "D-PAD", "A"], "leave": ["LT/RT", "route card"],
		"sell": ["A"], "debt": ["DEBT", "DOOMSDAY"], "chapter11": ["Severance"],
	}
	var bad: Array = []
	for b in Onboarding.shipped()["beats"]:
		var id: String = str(b["id"])
		var text: String = " ".join(PackedStringArray(_keys_of(b).map(func(k): return str(rows[k]))))
		for w in need.get(id, []):
			if not text.contains(w):
				bad.append("%s should name '%s'" % [id, w])
	if not str(rows["ONB_HINT"]).begins_with("VIEW"):
		bad.append("the permanent hint must name the View button")
	if not str(rows["ONB_LEAVE_TITLE"]).contains("A"):
		bad.append("leave must name A")
	return "ok" if bad.is_empty() else str(bad)


func test_every_beat_renders_as_notes_without_debug_text() -> String:
	var m := _main()
	var bad: Array = []
	for b in Onboarding.shipped()["beats"]:
		var id: String = str(b["id"])
		m.onboarding._active = id
		for held in [false, true]:
			m._onb_hold = id if held else ""
			var notes: Array = m._onb_notes()
			var want: int = 1 + (1 if held else 0) + 1 + (b["line_keys"] as Array).size() + 1
			if notes.size() != want:
				bad.append("%s held=%s: %d entries, expected %d" % [id, str(held), notes.size(), want])
				continue
			if str(notes[0]["kind"]) != "chip":
				bad.append("%s: first entry is not the chip" % id)
			if held and str(notes[1]["text"]) != m.tr("ONB_CONTINUE"):
				bad.append("%s: held row does not lead with A: CONTINUE" % id)
			if str(notes[notes.size() - 1]["text"]) != m.tr("ONB_HINT"):
				bad.append("%s: the permanent hint is not last" % id)
			for e in notes:
				var t: String = str(e["text"])
				if t == id.to_upper() or t.contains("ONB_") or t.contains("%"):
					bad.append("%s: raw or debug text '%s'" % [id, t])
	m.free()
	return "ok" if bad.is_empty() else str(bad)


func test_numbers_come_from_the_hud_values() -> String:
	var m := _main()
	m.controller.profile.severance_points = 321
	var ch11: String = m._onb_text("ONB_CH11_2")
	var perk: String = m._onb_text("ONB_PERKS_1")
	var cheapest: int = m._onb_cheapest_perk()
	m.free()
	if not ch11.contains("321"):
		return "chapter 11 row should carry the banked Severance: %s" % ch11
	if cheapest <= 0 or not perk.contains(str(cheapest)):
		return "perk row should carry the cheapest perk (%d): %s" % [cheapest, perk]
	return "ok"


func test_footer_reads_a_as_continue_while_held() -> String:
	var m := _main()
	var depart: Array = m.prompts()[0]
	m._onb_hold = "tabs"
	var held: Array = m.prompts()
	m._onb_hold = ""
	var ok: bool = depart[1] == m.tr("HUD_PROMPT_DEPART") and held[0][0] == m.tr("HUD_PAD_A") and held[0][1] == m.tr("HUD_PROMPT_NEXT")
	var rest_same: bool = held.size() == m.prompts().size()
	# The footer is already tight at 130% pseudo, so the held caption may not be longer than the
	# captions it replaces (Depart, Submit) in either locale.
	var cap_ok: bool = true
	for locale in [Loc.LOCALE_EN, Loc.LOCALE_PSEUDO]:
		Loc.set_locale(locale)
		var n: int = m.tr("HUD_PROMPT_NEXT").length()
		cap_ok = cap_ok and n <= m.tr("HUD_PROMPT_DEPART").length() and n <= m.tr("HUD_PROMPT_SUBMIT").length()
	Loc.set_locale(Loc.LOCALE_EN)
	m.free()
	if not cap_ok:
		return "the held footer caption is longer than Depart or Submit"
	return "ok" if ok and rest_same else "held footer wrong: depart=%s held=%s" % [str(depart), str(held)]


func test_perk_modal_shows_the_row_only_for_the_active_beat() -> String:
	var m := _main()
	m.controller.profile.severance_points = 500
	var plain: Dictionary = m._perks_model()
	m.onboarding._active = "perks"
	var with_row: Dictionary = m._perks_model()
	m.free()
	if (with_row["rows"] as Array).size() != (plain["rows"] as Array).size() + 1:
		return "the perk beat should add exactly one row"
	if str(with_row["rows"][0]["kind"]) != "text":
		return "the perk beat row should be a text row, first"
	return "ok"
