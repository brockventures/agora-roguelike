extends RefCounted
## Pseudo-localization audit (#40): with Godot's pseudolocalization on (accents,
## doubled vowels, +30% length, [brackets]), every HUD label must still fit its
## container at the 1280x800 handheld layout. "Fits" means the text, measured with
## the label's own font at its own size, is no wider than the label (or the wrap
## width, for wrapping labels) and no taller than the label, and the label stays
## inside its panel. The GalNet ticker is exempt from the width rule on purpose: a
## line wider than the strip scrolls as a marquee (OrbitalHUD.marquee_offset), so
## it is checked for being scrollable, not for fitting.

const SKIP_NOTE := "ticker"


func _scene() -> Node:
	var scene = load("res://scenes/main.tscn").instantiate()
	scene.initialize_systems(RunController.new(null, 84))
	scene._resolve_child_nodes()
	scene._build_readouts()
	return scene


## Required size of a label's text, as Label would lay it out.
static func text_extent(label: Label, text: String, box: Vector2 = Vector2.ZERO) -> Vector2:
	if box == Vector2.ZERO:
		box = label.size
	var font: Font = label.get_theme_default_font()
	var fs: int = label.get_theme_font_size("font_size")
	var width: float = box.x if label.autowrap_mode != TextServer.AUTOWRAP_OFF else -1.0
	var flags: int = TextServer.BREAK_MANDATORY
	if label.autowrap_mode != TextServer.AUTOWRAP_OFF:
		flags |= TextServer.BREAK_WORD_BOUND
		if label.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART:
			flags |= TextServer.BREAK_ADAPTIVE
		if label.autowrap_mode == TextServer.AUTOWRAP_ARBITRARY:
			flags |= TextServer.BREAK_GRAPHEME_BOUND
	var sz: Vector2 = font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width, fs, -1, flags)
	# Label adds line_spacing between lines; multiline size already includes the font height.
	var lines: int = int(round(sz.y / maxf(1.0, font.get_height(fs))))
	sz.y += float(maxi(0, lines - 1) * label.get_theme_constant("line_spacing"))
	return sz


## Findings for one label showing text: [] when it fits.
static func overflow_of(name: String, label: Label, text: String, box: Vector2, panel: Vector2) -> Array:
	var out: Array = []
	# Above 100% text size the sidebar scrolls vertically when its text outgrows the
	# view (#37), like the ticker does sideways: checked for width, and for being scrollable, not for height.
	if bool(label.get_meta("scrolls_vertically", false)):
		var need_w: Vector2 = text_extent(label, text, box)
		if need_w.x > box.x + 0.5:
			out.append("%s: text %.0f px wide, label %.0f" % [name, need_w.x, box.x])
		return out
	var need: Vector2 = text_extent(label, text, box)
	if need.x > box.x + 0.5:
		out.append("%s: text %.0f px wide, label %.0f" % [name, need.x, box.x])
	if need.y > box.y + 0.5:
		out.append("%s: text %.0f px tall, label %.0f" % [name, need.y, box.y])
	var rect := Rect2(label.position, box)
	if not Rect2(Vector2.ZERO, panel).encloses(rect):
		out.append("%s: label rect %s escapes its panel %s" % [name, str(rect), str(panel)])
	return out


func _fake_crisis(def: Dictionary, deck: CrisisDeck) -> Dictionary:
	var kind: String = str(def["kind"])
	var fx: Dictionary = def["effects"].duplicate()
	if kind == "audit":
		fx = {"trade_cap_qty": int(fx["trade_cap_qty"]), "fee_bps": int(fx["fee_max_bps"])}
	if kind == "collapse":
		fx["margin_call_bps"] = int(fx.get("margin_call_bps", 150))
	var station: String = "*" if kind == "collapse" else ("mars" if kind == "shortage" else "")
	var commodity: String = "*" if kind == "collapse" else ("MACHINERY" if kind == "shortage" else "")
	var text: String = str(def["headline"]).replace("{rounds}", "5").replace("{commodity}", commodity).replace("{station}", "Arcadia Foundries")
	return {"uid": 900, "id": str(def["id"]), "kind": kind, "tier": str(def["tier"]), "name": str(def["name"]), "text": text,
		"band": "high", "station": station, "commodity": commodity, "started_round": 4, "expires_round": 9, "rounds": 5, "effects": fx}


## Every HUD readout in every state the game can show, as [name, label, text] rows.
func _collect(scene: Node) -> Array:
	var rows: Array = []
	var add := func(name: String, label: Label) -> void:
		rows.append([name, label, label.text, label.size, (label.get_parent() as Control).size])
	var loop: M0Loop = scene.loop
	var rc: RunController = scene.controller
	rc.cr = 99999999
	rc.cargo = {"FRAG": 12, "FUEL": 12, "FOOD": 12, "ORE": 12, "MACHINERY": 12}
	scene.hud.gamepad_focus.last_rejection_reason = "AUDIT_TRADE_CAP"
	scene.hud.gamepad_focus.last_rejection_payload = {"cap": 20}
	for tab in [M0Loop.Tab.MAP, M0Loop.Tab.MARKET, M0Loop.Tab.FLEET]:
		loop.set_tab(tab)
		for stage in [DoomsdayClock.Stage.NORMAL, DoomsdayClock.Stage.UNSTABLE, DoomsdayClock.Stage.IMMINENT, DoomsdayClock.Stage.COLLAPSED]:
			rc.doomsday.stage = stage
			scene._refresh_readouts()
			var tag: String = "tab%d/stage%d" % [int(tab), int(stage)]
			add.call("header[%s]" % tag, scene.header_label)
			add.call("tabs+hint[%s]" % tag, scene.hint_label)
			add.call("map[%s]" % tag, scene.map_label)
			add.call("sidebar[%s]" % tag, scene.sidebar_label)
	rc.doomsday.stage = DoomsdayClock.Stage.NORMAL
	_collect_travel(scene, add)
	_collect_barons(scene, add)
	_collect_ares(scene, add)
	_collect_titan(scene, add)
	# Market board (resolution modal closed).
	loop.set_tab(M0Loop.Tab.MARKET)
	scene._refresh_readouts()
	scene.market_label.text = scene._board_text()
	add.call("market board", scene.market_label)
	# Sidebar with every crisis active, and the filled-order line.
	var deck: CrisisDeck = loop.crisis_deck
	for def in deck.data["crises"]:
		var c: Dictionary = _fake_crisis(def, deck)
		deck.active = [c]
		deck.awaiting_ack = [c["uid"]]
		scene.sidebar_label.text = scene._sidebar_text()
		add.call("sidebar[crisis %s]" % c["id"], scene.sidebar_label)
		scene.market_label.text = scene._board_text()
		add.call("market board[crisis %s]" % c["id"], scene.market_label)
		loop.overlay_state = M0Loop.OVERLAY_CRISIS
		scene._refresh_readouts()
		add.call("crisis modal[%s]" % c["id"], scene.resolution_label)
	deck.active = []
	deck.awaiting_ack = []
	scene.hud.gamepad_focus.last_rejection_reason = ""
	scene.hud.gamepad_focus.last_executed_order = {"side": "BUY", "qty": 12, "price": 1234.5, "fee": 400, "counterparty": "Ares Heavy Syndicate"}
	scene.sidebar_label.text = scene._sidebar_text()
	add.call("sidebar[filled]", scene.sidebar_label)
	# Resolution overlays.
	loop.overlay_state = M0Loop.OVERLAY_CHAPTER_11
	scene._refresh_readouts()
	add.call("chapter 11 modal", scene.resolution_label)
	loop.overlay_state = M0Loop.OVERLAY_COLLAPSED
	loop.collapse_phase = M0Loop.PHASE_SUMMARY
	scene._refresh_readouts()
	add.call("run summary", scene.resolution_label)
	loop.collapse_phase = M0Loop.PHASE_PERKS
	rc.profile.severance_points = 999999
	scene._refresh_readouts()
	add.call("perk select", scene.resolution_label)
	loop.overlay_state = M0Loop.OVERLAY_NONE
	loop.collapse_phase = M0Loop.PHASE_NONE
	# Sleep banner.
	loop.sleep_pause_active = true
	rc.sim_clock.paused = true
	scene._refresh_readouts()
	add.call("sleep banner", scene.sleep_label)
	loop.sleep_pause_active = false
	return rows


## Baron-made books (Epic 3 task 2, part of #15): the board title and the ladder maker
## tags at every station with a baron, and a fill that names one.
func _collect_barons(scene: Node, add: Callable) -> void:
	var loop: M0Loop = scene.loop
	var rc: RunController = scene.controller
	rc.world = Barons.new()
	loop.market.set_world(rc.world)
	loop.set_tab(M0Loop.Tab.MARKET)
	for st in ["mars", "ceres", "earth"]:
		loop.market.unlock_station(st)
		scene.hud.set_station(st)
		for c in Transit.COMMODITIES:
			scene.hud.set_commodity(c)
			scene.hud.gamepad_focus.last_executed_order = {"side": "BUY", "qty": 12, "price": 1234.5, "fee": 400, "counterparty": "", "counterparty_id": "titan_cryo_hydro"}
			scene._refresh_readouts()
			scene.market_label.text = scene._board_text()
			add.call("baron board[%s %s]" % [st, c], scene.market_label)
			add.call("baron sidebar[%s %s]" % [st, c], scene.sidebar_label)
	scene.hud.gamepad_focus.last_executed_order = {}
	rc.world = null
	loop.market.set_world(null)
	scene.hud.set_station("mars")
	scene.hud.set_commodity("FRAG")
	scene._refresh_readouts()


## Ares Heavy (Epic 3 task 4, part of #16): the defense contract offer modal, the
## sidebar contract line and SHORT SQUEEZE tag, the board row tag, and the map line.
func _collect_ares(scene: Node, add: Callable) -> void:
	var loop: M0Loop = scene.loop
	var rc: RunController = scene.controller
	rc.world = Barons.new()
	loop.market.set_world(rc.world)
	var st: BaronState = rc.world.state("ares_heavy")
	st.scratch["contract"] = {"state": "offered", "id": 8, "commodity": "MACHINERY", "qty": 60, "unit_px": 19, "offered_round": 8, "due_round": 14}
	loop.overlay_state = M0Loop.OVERLAY_CONTRACT
	scene._refresh_readouts()
	add.call("contract offer modal", scene.resolution_label)
	loop.overlay_state = M0Loop.OVERLAY_NONE
	st.scratch["contract"]["state"] = "accepted"
	st.scratch["squeeze"] = {"commodity": "MACHINERY", "price_bps": 5000, "depth_bps": 3000, "rounds_short": 5}
	loop.market.set_world_mods(rc.world.market_mods())
	scene.hud.set_station("mars")
	scene.hud.set_commodity("MACHINERY")
	for tab in [M0Loop.Tab.MAP, M0Loop.Tab.MARKET]:
		loop.set_tab(tab)
		scene._refresh_readouts()
		var tag: String = "ares/tab%d" % int(tab)
		add.call("map[%s]" % tag, scene.map_label)
		add.call("sidebar[%s]" % tag, scene.sidebar_label)
	scene.market_label.text = scene._board_text()
	add.call("market board[ares squeeze]", scene.market_label)
	rc.world = null
	loop.market.set_world(null)
	loop.market.set_world_mods([])
	scene.hud.set_station("mars")
	scene.hud.set_commodity("FRAG")
	scene._refresh_readouts()


## Titan Cryo-Hydro (Epic 3 task 5, part of #16): the Ceres board row and sidebar under
## each hoard tag (HOARDED, CORNER, RELEASE). The headlines are checked in findings().
func _collect_titan(scene: Node, add: Callable) -> void:
	var loop: M0Loop = scene.loop
	var rc: RunController = scene.controller
	rc.world = Barons.new()
	loop.market.set_world(rc.world)
	loop.market.unlock_station("ceres")
	var st: BaronState = rc.world.state("titan_cryo_hydro")
	for phase in ["hoarding", "cornered", "releasing"]:
		st.scratch["hoard"] = {"FUEL": {"phase": phase, "age": 2, "hold": 6, "rel": 0, "ask_depth_bps": 8000, "announced": true, "spoiled": 0}}
		loop.market.set_world_mods(rc.world.market_mods())
		scene.hud.set_station("ceres")
		scene.hud.set_commodity("FUEL")
		loop.set_tab(M0Loop.Tab.MARKET)
		scene._refresh_readouts()
		scene.market_label.text = scene._board_text()
		add.call("market board[titan %s]" % phase, scene.market_label)
		add.call("sidebar[titan %s]" % phase, scene.sidebar_label)
	rc.world = null
	loop.market.set_world(null)
	loop.market.set_world_mods([])
	scene.hud.set_station("mars")
	scene.hud.set_commodity("FRAG")
	scene._refresh_readouts()


## The travel loop (#111): the route preview with a belt toll, a refused departure,
## then the header ETA, the in-transit map text, hint and rejection while under way.
func _collect_travel(scene: Node, add: Callable) -> void:
	var loop: M0Loop = scene.loop
	var rc: RunController = scene.controller
	scene.hud.set_station("ceres")
	loop.set_tab(M0Loop.Tab.MAP)
	scene._refresh_readouts()
	add.call("header[route]", scene.header_label)
	add.call("tabs+hint[route]", scene.hint_label)
	add.call("map[route]", scene.map_label)
	for reason in ["INSUFFICIENT_CR", "SAME_STATION", "IN_TRANSIT", "NO_ROUTE", "OTHER"]:
		loop.last_depart_reason = reason
		scene._refresh_readouts()
		add.call("map[refused %s]" % reason, scene.map_label)
	loop.last_depart_reason = ""
	rc.depart("ceres")
	scene.hud.gamepad_focus.last_rejection_reason = "IN_TRANSIT"
	scene.hud.gamepad_focus.last_rejection_payload = {"destination": "ceres"}
	for tab in [M0Loop.Tab.MAP, M0Loop.Tab.MARKET, M0Loop.Tab.FLEET]:
		loop.set_tab(tab)
		scene._refresh_readouts()
		var tag: String = "transit/tab%d" % int(tab)
		add.call("header[%s]" % tag, scene.header_label)
		add.call("tabs+hint[%s]" % tag, scene.hint_label)
		add.call("map[%s]" % tag, scene.map_label)
		add.call("sidebar[%s]" % tag, scene.sidebar_label)
	rc.transit = {}
	rc.docked_at = "mars"
	scene.hud.set_station("mars")
	scene.hud.gamepad_focus.last_rejection_reason = "AUDIT_TRADE_CAP"
	scene.hud.gamepad_focus.last_rejection_payload = {"cap": 20}
	loop.set_tab(M0Loop.Tab.MAP)


## All findings for the scene under the current locale.
func findings(scene: Node) -> Array:
	var out: Array = []
	for row in _collect(scene):
		for f in overflow_of(row[0], row[1], row[2], row[3], row[4]):
			if not out.has(f):
				out.append(f)
	# Ticker: every visible line must be scrollable inside its strip.
	var ares_lines: Array = [
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_ARES_OFFER", [Loc.maker_arg("ares_heavy"), 60, Loc.commodity_arg("MACHINERY"), Loc.station_arg("mars"), 6, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("DEBT"), Loc.format("HL_ARES_MISSED", [Loc.maker_arg("ares_heavy"), 99999])]),
	]
	var titan: Dictionary = Loc.maker_arg("titan_cryo_hydro")
	var fuel: Dictionary = Loc.commodity_arg("FUEL")
	var ceres: Dictionary = Loc.station_arg("ceres")
	var titan_lines: Array = [
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_TITAN_HOARD", [titan, fuel, ceres])]),
		Loc.format("TICKER_LINE", [Loc.category("CRISIS"), Loc.format("HL_TITAN_CORNER", [titan, fuel, ceres, 99])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_TITAN_RELEASE", [titan, fuel, ceres, 99])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_TITAN_SPOIL", [titan, 999, Loc.commodity_arg("FOOD")])]),
	]
	for text in [Loc.format("TICKER_LINE", [Loc.category("PIRACY"), Loc.format("HL_PIRACY_DEMAND", [99999, "ship_alpha", Loc.station_arg("earth"), Loc.station_arg("mars"), Loc.commodity_arg("MACHINERY")])])] + ares_lines + titan_lines:
		var tl: Label = scene.ticker_labels[0]
		var w: float = text_extent(tl, text).x
		if w > tl.size.x:
			out.append("ticker: line %.0f px exceeds its %.0f px label (cannot marquee fully)" % [w, tl.size.x])
	return out


func test_labels_fit_in_english() -> String:
	Loc.set_locale(Loc.LOCALE_EN)
	var scene := _scene()
	var f: Array = findings(scene)
	scene.free()
	return "ok" if f.is_empty() else "English layout overflows: %s" % str(f)


func test_labels_fit_under_pseudolocalization() -> String:
	Loc.set_locale(Loc.LOCALE_PSEUDO)
	var scene := _scene()
	var f: Array = findings(scene)
	scene.free()
	Loc.set_locale(Loc.LOCALE_EN)
	return "ok" if f.is_empty() else "pseudo layout overflows (%d): %s" % [f.size(), "\n  ".join(PackedStringArray(f))]
