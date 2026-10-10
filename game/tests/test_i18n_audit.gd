extends RefCounted
## Raw-English lint (#40). Fails when a GDScript under game/ui, game/scenes or
## game/core hands a literal containing English words to something the player
## reads: a Label/RichTextLabel text, the HUD ticker (post_headline), a text
## formatter's output list (out/parts/lines.append), or draw_string. Text must go
## through tr("KEY") / Loc.t / Loc.format, with the words in agora_strings.csv.
##
## A literal is "English" when it holds a run of two letters outside a
## %-placeholder, so "%s", "%d", "  ", "-" and "" are fine. Not user-facing, so
## exempt: lines that log or assert (push_warning, push_error, print, assert) and
## any line carrying the marker `i18n-ok` (use it for a stable id that happens to
## sit in a text slot, with a reason).

const SCAN_DIRS := ["res://ui", "res://scenes", "res://core"]
const MARKER := "i18n-ok"
const LOG_CALLS := ["push_warning", "push_error", "print(", "printerr", "assert(", "_load_errors", "errors.append"]
## Calls whose literal argument reaches the screen.
const SINKS := [
	"\\.text\\s*\\+?=\\s*\"",
	"\\btext\\s*\\+?=\\s*\"",
	"\\.tooltip_text\\s*=\\s*\"",
	"\\bpost_headline\\(\\s*\"",
	"\\b(?:out|parts|lines)\\.append\\(\\s*\"",
	"\\bdraw_string\\([^\"\\n]*\"",
	"\\bparent\\.text\\s*=\\s*\"",
]
## `return "literal"` inside a function whose name says it produces player text.
const TEXT_FUNC := "(?i)message|_text$|^text|label$|describe|title|headline|hint|notice"


## Strips a trailing # comment (outside quotes) so prose in comments is not linted.
static func code_part(line: String) -> String:
	var in_str := false
	for i in line.length():
		var ch := line[i]
		if ch == "\"" and (i == 0 or line[i - 1] != "\\"):
			in_str = not in_str
		elif ch == "#" and not in_str:
			return line.substr(0, i)
	return line


## Findings ("path:line: text") for one source string.
static func lint_source(path: String, src: String) -> Array:
	var sinks: Array[RegEx] = []
	for s in SINKS:
		sinks.append(RegEx.create_from_string(s))
	var words := RegEx.create_from_string("[A-Za-z]{2}")
	var out: Array = []
	var n := 0
	var func_re := RegEx.create_from_string("^\\s*(?:static\\s+)?func\\s+(\\w+)")
	var text_func := RegEx.create_from_string(TEXT_FUNC)
	var ret := RegEx.create_from_string("\\breturn\\s+\"")
	var in_text_func := false
	for raw in src.split("\n"):
		n += 1
		var fm := func_re.search(raw)
		if fm != null:
			in_text_func = text_func.search(fm.get_string(1)) != null
		if raw.contains(MARKER):
			continue
		var line := code_part(raw)
		var skip := false
		for call in LOG_CALLS:
			skip = skip or line.contains(call)
		if skip:
			continue
		var line_sinks: Array[RegEx] = sinks.duplicate()
		if in_text_func:
			line_sinks.append(ret)
		for sink in line_sinks:
			var m := sink.search(line)
			if m == null:
				continue
			# The literal that starts at the end of the match.
			var rest := line.substr(m.get_end())
			var close := rest.find("\"")
			var lit := rest if close < 0 else rest.substr(0, close)
			var stripped := RegEx.create_from_string("%[-+0-9.# ]*[a-zA-Z%]").sub(lit, "", true)
			if words.search(stripped) != null:
				out.append("%s:%d: raw English literal: %s" % [path, n, raw.strip_edges()])
				break
	return out


func test_no_raw_english_in_ui_scenes_or_core() -> String:
	var found: Array = []
	var scanned := 0
	for d in SCAN_DIRS:
		var dir := DirAccess.open(d)
		if dir == null:
			return "cannot open %s" % d
		for f in dir.get_files():
			if f.ends_with(".gd"):
				scanned += 1
				found.append_array(lint_source(d.path_join(f), FileAccess.get_file_as_string(d.path_join(f))))
	if scanned < 20:
		return "lint scanned only %d files" % scanned
	return "ok" if found.is_empty() else "raw English reaches the screen:\n  " + "\n  ".join(PackedStringArray(found))


func test_scene_files_carry_no_literal_text() -> String:
	# Scenes build their text in code; a .tscn "text = ..." would bypass the CSV.
	var re := RegEx.create_from_string("(?m)^\\s*(text|tooltip_text|title)\\s*=\\s*\"[^\"]*[A-Za-z]{2}")
	var bad: Array = []
	var dir := DirAccess.open("res://scenes")
	for f in dir.get_files():
		if f.ends_with(".tscn") and re.search(FileAccess.get_file_as_string("res://scenes/" + f)) != null:
			bad.append(f)
	return "ok" if bad.is_empty() else "literal text in scene files: %s" % str(bad)


func test_lint_catches_what_it_should_and_spares_what_it_should() -> String:
	var bad := [
		'label.text = "Hello world"',
		'hud.post_headline("MARGIN CALL: %d" % x)',
		'out.append("CRISIS " + name)',
		'canvas.draw_string(font, pos, "SOL", 0, -1, 14)',
		'header_label.text += "extra words"',
		'func rejection_message(r):\n\treturn "Not enough CR"',
	]
	for line in bad:
		if lint_source("t.gd", line).is_empty():
			return "lint missed: %s" % line
	var good := [
		'label.text = tr("HUD_TITLE")',
		'label.text = "%s" % name',
		'label.text = ""',
		'out.append("")',
		'out.append("%d/%d" % [a, b])',
		'out.append("  ")',
		'push_warning("run save ignored: %s" % err)',
		'label.text = "debug words"  # i18n-ok',
		'label.text = tr("X") # Hello there friend',
		'hud.post_headline_tr("HL_FILL", [])',
		'out.append(tr("SIDE_SPREAD") % x)',
		'func rejection_message(r):\n\treturn Loc.t("REJ_X")',
		'func speed_up(r):\n\treturn "ok"',
	]
	for line in good:
		var f := lint_source("t.gd", line)
		if not f.is_empty():
			return "lint flagged clean line: %s" % str(f)
	return "ok"


func test_fit_detector_flags_overflow() -> String:
	# Guards test_i18n_fit.gd itself: a too-wide / too-tall string must be reported.
	var l := Label.new()
	l.size = Vector2(100, 20)
	l.add_theme_font_size_override("font_size", 16)
	var wide: Array = load("res://tests/test_i18n_fit.gd").overflow_of("w", l, "this text is clearly wider than one hundred pixels", l.size, Vector2(200, 100))
	var tall := Label.new()
	tall.size = Vector2(100, 20)
	tall.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var high: Array = load("res://tests/test_i18n_fit.gd").overflow_of("t", tall, "word word word word word word word word word word", tall.size, Vector2(200, 100))
	var fits: Array = load("res://tests/test_i18n_fit.gd").overflow_of("f", l, "ok", l.size, Vector2(200, 100))
	l.free()
	tall.free()
	if wide.is_empty() or high.is_empty():
		return "overflow not detected (wide %s, tall %s)" % [str(wide), str(high)]
	return "ok" if fits.is_empty() else "false positive: %s" % str(fits)
