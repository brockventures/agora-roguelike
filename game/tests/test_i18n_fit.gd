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
	var font: Font = label.get_theme_font("font") if label.has_theme_font_override("font") else label.get_theme_default_font()
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


## Adds every label on screen right now as a row [name, label, text, size, parent size].
## Rows already seen with identical text and geometry are skipped.
var _seen: Dictionary = {}


## Node.get_path() errors on a scene that is not in the tree (the tests never add it).
func _node_path(n: Node) -> String:
	var parts: PackedStringArray = []
	while n != null:
		parts.append(str(n.name))
		n = n.get_parent()
	parts.reverse()
	return "/".join(parts)


func _snap(scene: Node, tag: String, rows: Array) -> void:
	for l in scene.text_labels():
		if l.text == "" or not scene.label_shown(l):
			continue
		# The ticker's text label is a wide marquee strip; its lines are checked in findings().
		if str(l.name).begins_with("TickerText"):
			continue
		var box: Vector2 = (l.get_parent() as Control).size
		var key: String = "%s|%s|%s|%s|%s" % [_node_path(l), l.text, str(l.size), str(l.position), str(box)]
		if _seen.has(key):
			continue
		_seen[key] = true
		# Judged now: the label's position, font and width axis are live state that a later
		# state of the same scene will overwrite.
		var nm: String = "%s %s" % [tag, l.name]
		rows.append([nm, l, l.text, l.size, box, overflow_of(nm, l, l.text, l.size, box)])


## Every HUD readout in every state the game can show, as [name, label, text] rows.
func _collect(scene: Node) -> Array:
	var rows: Array = []
	_seen = {}
	var add := func(name: String, _label: Label) -> void:
		_snap(scene, name, rows)
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
			add.call("header[%s]" % tag, scene.wordmark_label)
			add.call("tabs+hint[%s]" % tag, scene.wordmark_label)
			add.call("map[%s]" % tag, scene.map_label)
			add.call("sidebar[%s]" % tag, scene.wordmark_label)
	rc.doomsday.stage = DoomsdayClock.Stage.NORMAL
	_collect_travel(scene, add)
	_collect_barons(scene, add)
	_collect_ares(scene, add)
	_collect_titan(scene, add)
	_collect_sol(scene, add)
	_collect_takeover(scene, add)
	_collect_levers(scene, add)
	_collect_rivals(scene, add)
	_collect_fleet(scene, add)
	# Market board (resolution modal closed).
	loop.set_tab(M0Loop.Tab.MARKET)
	scene._refresh_readouts()
	add.call("market board", scene.wordmark_label)
	# Sidebar with every crisis active, and the filled-order line.
	var deck: CrisisDeck = loop.crisis_deck
	for def in deck.data["crises"]:
		var c: Dictionary = _fake_crisis(def, deck)
		deck.active = [c]
		deck.awaiting_ack = [c["uid"]]
		scene._refresh_readouts()
		add.call("sidebar[crisis %s]" % c["id"], scene.wordmark_label)
		add.call("market board[crisis %s]" % c["id"], scene.wordmark_label)
		loop.overlay_state = M0Loop.OVERLAY_CRISIS
		scene._refresh_readouts()
		add.call("crisis modal[%s]" % c["id"], scene.resolution_label)
		loop.overlay_state = M0Loop.OVERLAY_NONE
	deck.active = []
	deck.awaiting_ack = []
	scene.hud.gamepad_focus.last_rejection_reason = ""
	scene.hud.gamepad_focus.last_executed_order = {"side": "BUY", "qty": 12, "price": 1234.5, "fee": 400, "counterparty": "Ares Heavy Syndicate"}
	scene._refresh_readouts()
	add.call("sidebar[filled]", scene.wordmark_label)
	# Resolution overlays.
	loop.overlay_state = M0Loop.OVERLAY_CHAPTER_11
	scene._refresh_readouts()
	add.call("chapter 11 modal", scene.resolution_label)
	loop.overlay_state = M0Loop.OVERLAY_COLLAPSED
	loop.collapse_phase = M0Loop.PHASE_SUMMARY
	scene._refresh_readouts()
	add.call("run summary", scene.resolution_label)
	_collect_modals(scene, add)
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


## The Epic 6 (#123) modals and toasts: the run summary with its severance breakdown at its
## longest (named barons, then the aggregate row), the monopoly summary, every crisis card
## with its 4:3 art frame, and a stack of toasts with long lines.
func _collect_modals(scene: Node, add: Callable) -> void:
	var loop: M0Loop = scene.loop
	var rc: RunController = scene.controller
	var deck: CrisisDeck = loop.crisis_deck
	for def in deck.data["crises"]:
		var c: Dictionary = _fake_crisis(def, deck)
		deck.active = [c]
		deck.awaiting_ack = [c["uid"]]
		loop.overlay_state = M0Loop.OVERLAY_CRISIS
		scene._refresh_readouts()
		add.call("crisis card[%s]" % c["id"], scene.resolution_label)
	deck.active = []
	deck.awaiting_ack = []
	loop.overlay_state = M0Loop.OVERLAY_COLLAPSED
	loop.collapse_phase = M0Loop.PHASE_SUMMARY
	rc.severance_award = 99999
	rc.barons_broken_award = 3
	rc.peak_net_worth = 9999999
	loop._broken_ids = ["ares_heavy", "titan_cryo_hydro", "blackwater_lines"]
	scene._refresh_readouts()
	add.call("run summary[breakdown]", scene.resolution_label)
	loop._broken_ids = []
	scene._refresh_readouts()
	add.call("run summary[aggregate]", scene.resolution_label)
	rc.severance_award = 0
	rc.barons_broken_award = 0
	rc.peak_net_worth = 0
	loop.overlay_state = M0Loop.OVERLAY_NONE
	loop.collapse_phase = M0Loop.PHASE_NONE
	# Toasts: a fill, a rejection and an alert, each with a long line.
	scene.toasts.push(ToastTray.KIND_FILLED, "BUY 999 MACHINERY @ 99999.9 at Arcadia Foundries vs Ares Heavy Syndicate")
	scene.toasts.push(ToastTray.KIND_REJECTED, "Orders capped at 20 units while the audit lasts")
	scene.toasts.push(ToastTray.KIND_INFO, "Ares Heavy squeezes the machinery lanes: bids climbing across the sector")
	scene._refresh_readouts()
	add.call("toasts", scene.wordmark_label)
	scene.toasts.clear()
	scene._refresh_readouts()


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
			add.call("baron board[%s %s]" % [st, c], scene.wordmark_label)
			add.call("baron sidebar[%s %s]" % [st, c], scene.wordmark_label)
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
		add.call("sidebar[%s]" % tag, scene.wordmark_label)
	add.call("market board[ares squeeze]", scene.wordmark_label)
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
		add.call("market board[titan %s]" % phase, scene.wordmark_label)
		add.call("sidebar[titan %s]" % phase, scene.wordmark_label)
	rc.world = null
	loop.market.set_world(null)
	loop.market.set_world_mods([])
	scene.hud.set_station("mars")
	scene.hud.set_commodity("FRAG")
	scene._refresh_readouts()


## Sol Central (Epic 3 task 6, part of #16): the Earth sidebar during an auction under
## each indicative-price state (nothing crosses yet, a queued bid with the rig showing,
## the delayed leak) with its queued-order and withdraw rows, and the AUCTION board tag.
## The headlines are checked in findings().
func _collect_sol(scene: Node, add: Callable) -> void:
	var loop: M0Loop = scene.loop
	var rc: RunController = scene.controller
	rc.world = Barons.new()
	loop.market.set_world(rc.world)
	var cargo0: Dictionary = rc.cargo.duplicate()
	var cr0: int = rc.cr
	rc.cargo = {}
	rc.docked_at = "earth"
	rc.cr = 50000
	rc.sim_clock.total_ticks = 5 * rc.ticks_per_round
	var au: Dictionary = rc.world.auction_at("earth", 5, rc.run_seed)
	scene.hud.set_station("earth")
	scene.hud.set_commodity(str(au["commodity"]))
	loop.set_tab(M0Loop.Tab.MARKET)
	var ask: int = int(loop.market.ladder("earth", str(au["commodity"]), 1)["best_ask"])
	for state in ["empty", "queued", "queued x3", "queued miss", "delayed"]:
		match state:
			"queued":
				rc.world.submit_auction_order(rc, "earth", "BUY", 12, ask + 12)
			"queued miss":
				rc.world.submit_auction_order(rc, "earth", "BUY", 9, ask)
			"queued x3":
				rc.world.submit_auction_order(rc, "earth", "BUY", 100, ask + 10)
				rc.world.submit_auction_order(rc, "earth", "BUY", 100, ask + 11)
			"delayed":
				for d in rc.world.data["barons"]:
					if str(d["id"]) == "sol_central":
						d["params"]["indicative_leak"] = "delayed"
		scene._refresh_readouts()
		add.call("market board[sol %s]" % state, scene.wordmark_label)
		add.call("sidebar[sol %s]" % state, scene.wordmark_label)
	rc.world.withdraw_auction_orders("earth")
	rc.world = null
	loop.market.set_world(null)
	rc.cargo = cargo0
	rc.cr = cr0
	rc.sim_clock.total_ticks = 0
	rc.docked_at = "mars"
	scene.hud.set_station("mars")
	scene.hud.set_commodity("FRAG")
	scene._refresh_readouts()


## Takeover core (Epic 3 task 7, part of #17): the Mars board and sidebar while Ares Heavy
## is in distress (a lot on offer, a part-held stake, the lot sold out), then once held and
## once held by a rival, with the F / L3 hint and the rent row. Headlines: findings().
func _collect_takeover(scene: Node, add: Callable) -> void:
	var loop: M0Loop = scene.loop
	var rc: RunController = scene.controller
	rc.world = Barons.new()
	loop.market.set_world(rc.world)
	var st: BaronState = rc.world.state("ares_heavy")
	rc.docked_at = "mars"
	scene.hud.set_station("mars")
	scene.hud.set_commodity("ORE")
	loop.set_tab(M0Loop.Tab.MARKET)
	for state in ["lot", "stake", "lot sold", "sold out", "held", "rival"]:
		match state:
			"lot":
				rc.world.add_debt("ares_heavy", 200000)
				st.strain = 3
				st.scratch["distress"] = {"px": 7, "qty": 100, "round": 3}
			"stake":
				st.shares["player"] = 300
			"lot sold":
				st.scratch.erase("distress")
			"sold out":
				st.treasury_shares = 0
			"held":
				st.holder = "player"
			"rival":
				st.holder = "rival_fleet_one"
		loop.market.set_world_mods(rc.world.market_mods())
		scene._refresh_readouts()
		add.call("market board[takeover %s]" % state, scene.wordmark_label)
		add.call("sidebar[takeover %s]" % state, scene.wordmark_label)
	rc.world = null
	loop.market.set_world(null)
	loop.market.set_world_mods([])
	scene.hud.set_station("mars")
	scene.hud.set_commodity("FRAG")
	scene._refresh_readouts()


## The player's levers (Epic 3 task 8, part of #17): the Mars board and sidebar with a corner
## standing, then sell pressure and a forced sale, then an open credit line, then the
## Hostile Buyout Line's tender rows. Headlines: findings().
func _collect_levers(scene: Node, add: Callable) -> void:
	var loop: M0Loop = scene.loop
	var rc: RunController = scene.controller
	rc.world = Barons.new()
	loop.market.set_world(rc.world)
	var st: BaronState = rc.world.state("ares_heavy")
	rc.docked_at = "mars"
	scene.hud.set_station("mars")
	scene.hud.set_commodity("ORE")
	loop.set_tab(M0Loop.Tab.MARKET)
	var saved_mods: Dictionary = rc.modifiers
	for state in ["hold", "corner", "pressure", "forced sale", "credit offer", "credit open", "tender"]:
		match state:
			"hold":
				rc.cargo = {"ORE": 30}
			"corner":
				rc.cargo = {"ORE": 100}
				st.scratch["corner"] = {"ORE": 3}
			"pressure":
				st.scratch.erase("corner")
				st.pressure_bps = {"ORE": 4000, "MACHINERY": 1500}
			"forced sale":
				st.scratch["crash"] = {"ORE": 2}
			"credit offer":
				st.scratch.erase("crash")
				st.treasury_cr = 1000
			"credit open":
				st.scratch["credit"] = {"principal": 10000, "due": 12000, "due_round": 99, "rate_bps": 2000}
			"tender":
				st.scratch.erase("credit")
				st.treasury_cr = 60000
				rc.modifiers = {"takeover_threshold_shares": {"add": -50, "mul_bps": 10000}}
		loop.market.set_world_mods(rc.world.market_mods())
		scene._refresh_readouts()
		add.call("market board[levers %s]" % state, scene.wordmark_label)
		add.call("sidebar[levers %s]" % state, scene.wordmark_label)
	rc.modifiers = saved_mods
	rc.cargo = {}
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
	add.call("header[route]", scene.wordmark_label)
	add.call("tabs+hint[route]", scene.wordmark_label)
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
		add.call("header[%s]" % tag, scene.wordmark_label)
		add.call("tabs+hint[%s]" % tag, scene.wordmark_label)
		add.call("map[%s]" % tag, scene.map_label)
		add.call("sidebar[%s]" % tag, scene.wordmark_label)
	rc.transit = {}
	rc.docked_at = "mars"
	scene.hud.set_station("mars")
	scene.hud.gamepad_focus.last_rejection_reason = "AUDIT_TRADE_CAP"
	scene.hud.gamepad_focus.last_rejection_payload = {"cap": 20}
	loop.set_tab(M0Loop.Tab.MAP)


## Fleet tab (Epic 6 #122): all five archetypes in one list, the cursor on each, docked and
## in transit with an ETA chip, a full hold and a damaged hull (the widest readouts).
func _collect_fleet(scene: Node, add: Callable) -> void:
	var loop: M0Loop = scene.loop
	var rc: RunController = scene.controller
	var saved_ships: Array = rc.ships.duplicate(true)
	rc.ships = []
	for a in FleetView.ARCHETYPES:
		rc.ships.append({"id": "fit_" + a, "hull_value_cr": 0, "archetype": a, "hull_pct": 88, "shield_pct": 7})
	rc.cargo = {"FRAG": 100, "FUEL": 100, "FOOD": 100, "ORE": 100, "MACHINERY": 100}
	loop.set_tab(M0Loop.Tab.FLEET)
	for state in ["docked", "transit"]:
		if state == "transit":
			rc.docked_at = "ceres"
			rc.transit = {"origin": "ceres", "destination": "earth", "depart_tick": 0, "arrive_tick": 3 * rc.ticks_per_round, "rounds": 3, "toll": 0}
		for i in rc.ships.size():
			loop.fleet_cursor = i
			scene._refresh_readouts()
			add.call("fleet[%s %d]" % [state, i], scene.wordmark_label)
	rc.transit = {}
	rc.docked_at = "mars"
	rc.ships = saved_ships
	loop.fleet_cursor = 0
	loop.set_tab(M0Loop.Tab.MAP)


## Rival fleets (Epic 3 task 10, part of #18): the desk-notes chip a fleet's fill leaves on
## the book, for every fleet and both sides, on a book with a pipeline tag and a squeeze
## already (the busiest rows). Headlines: findings().
func _collect_rivals(scene: Node, add: Callable) -> void:
	var loop: M0Loop = scene.loop
	var rc: RunController = scene.controller
	rc.world = Barons.new()
	loop.market.set_world(rc.world)
	rc.docked_at = "mars"
	scene.hud.set_station("mars")
	scene.hud.set_commodity("ORE")
	loop.set_tab(M0Loop.Tab.MARKET)
	for id in rc.world.rival_ids():
		for side in ["BUY", "SELL"]:
			rc.world.rival(id).last = {"round": rc.get_current_round(), "station": "mars", "commodity": "ORE", "side": side, "qty": 99999, "price": 99}
			scene._refresh_readouts()
			add.call("market board[rival %s %s]" % [id, side], scene.wordmark_label)
			add.call("sidebar[rival %s %s]" % [id, side], scene.wordmark_label)
		rc.world.rival(id).last = {}
	rc.world = null
	loop.market.set_world(null)
	loop.market.set_world_mods([])
	scene.hud.set_station("mars")
	scene.hud.set_commodity("FRAG")
	scene._refresh_readouts()


## All findings for the scene under the current locale.
func findings(scene: Node) -> Array:
	var out: Array = []
	for row in _collect(scene):
		for f in (row[5] if row.size() > 5 else overflow_of(row[0], row[1], row[2], row[3], row[4])):
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
	var sol: Dictionary = Loc.maker_arg("sol_central")
	var frag: Dictionary = Loc.commodity_arg("FRAG")
	var sol_lines: Array = [
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_SOL_OPEN", [sol, frag, Loc.station_arg("earth"), 99999, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_SOL_QUEUED", [Loc.key_arg("ORDER_BUY"), 99999, frag, sol, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_SOL_CLEAR", [sol, frag, 99999, 99999, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_SOL_LAPSE", [sol, 99999, frag, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_SOL_NOCROSS", [sol, frag, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_SOL_WITHDRAWN", [sol, 99999])]),
	]
	var ares: Dictionary = Loc.maker_arg("ares_heavy")
	var take_lines: Array = [
		Loc.format("TICKER_LINE", [Loc.category("INSOLVENCY"), Loc.format("HL_DISTRESS", [ares, 99999, 99999, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_SHARES_BOUGHT", [99999, ares, 99999, 99999, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_SHARES_SOLD", [ares, 99999, "RIVAL_FLEET_ONE", 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_SHARES_REFUSED", [Loc.key_arg("SHARES_REASON_WOULD_BANKRUPT")])]),
		Loc.format("TICKER_LINE", [Loc.category("INSOLVENCY"), Loc.format("HL_TAKEOVER", [ares, 999999, 999999])]),
		Loc.format("TICKER_LINE", [Loc.category("INSOLVENCY"), Loc.format("HL_TAKEOVER_FORCED", [ares])]),
		Loc.format("TICKER_LINE", [Loc.category("INSOLVENCY"), Loc.format("HL_TAKEOVER_OTHER", [ares, "RIVAL_FLEET_ONE"])]),
		Loc.format("TICKER_LINE", [Loc.category("INSOLVENCY"), Loc.format("HL_BANKRUPT_PLAYER", [ares, 999999, 999999, 999999])]),
		Loc.format("TICKER_LINE", [Loc.category("INSOLVENCY"), Loc.format("HL_BANKRUPT_OTHER", [ares, 999999, 999999, "RIVAL_FLEET_ONE"])]),
		Loc.format("TICKER_LINE", [Loc.category("INSOLVENCY"), Loc.format("HL_BANKRUPT_NONE", [ares, 999999, 999999])]),
		Loc.format("TICKER_LINE", [Loc.category("INSOLVENCY"), Loc.format("HL_FORFEIT", [ares])]),
	]
	var lever_lines: Array = [
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_CORNER", [ares, Loc.commodity_arg("MACHINERY"), 99999, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("INSOLVENCY"), Loc.format("HL_CORNER_UNPAID", [ares, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_CORNER_END", [ares, Loc.commodity_arg("MACHINERY")])]),
		Loc.format("TICKER_LINE", [Loc.category("INSOLVENCY"), Loc.format("HL_LEVER_MARGIN", [ares, 99999, 99999, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("DEBT"), Loc.format("HL_CREDIT_OPEN", [ares, 99999, 99, 99999, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("DEBT"), Loc.format("HL_CREDIT_REPAID", [ares, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("INSOLVENCY"), Loc.format("HL_CREDIT_DEFAULT", [ares, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("DEBT"), Loc.format("HL_CREDIT_REFUSED", [Loc.key_arg("CREDIT_REASON_WOULD_BANKRUPT")])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_TENDER_BOUGHT", [99999, ares, 99999, 99999, 99999])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_SHARES_REFUSED", [Loc.key_arg("SHARES_REASON_LOCKED")])]),
	]
	var kess: Dictionary = Loc.maker_arg("blackwater_lines")
	var rival_lines: Array = [
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_RIVAL_REACT", [kess, Loc.station_arg("earth"), 99999, Loc.commodity_arg("MACHINERY"), Loc.station_arg("mars")])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_RIVAL_DEPART", [kess, 99999, Loc.commodity_arg("MACHINERY"), Loc.station_arg("earth"), Loc.station_arg("mars")])]),
		Loc.format("TICKER_LINE", [Loc.category("MARKET"), Loc.format("HL_RIVAL_SELL", [kess, 99999, Loc.commodity_arg("MACHINERY"), Loc.station_arg("earth"), 99999])]),
	]
	for text in [Loc.format("TICKER_LINE", [Loc.category("PIRACY"), Loc.format("HL_PIRACY_DEMAND", [99999, "ship_alpha", Loc.station_arg("earth"), Loc.station_arg("mars"), Loc.commodity_arg("MACHINERY")])])] + ares_lines + titan_lines + sol_lines + take_lines + lever_lines + rival_lines:
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



## The modals and toasts at every text scale, English and pseudo-localization (the 130%
## pseudo-locale is the worst case): only what sits in a modal or a toast is judged here,
## the rest of the HUD has its own tests.
func test_modals_and_toasts_fit_at_every_text_scale() -> String:
	var bad: Array = []
	for locale in [Loc.LOCALE_EN, Loc.LOCALE_PSEUDO]:
		Loc.set_locale(locale)
		for scale in AccessibilitySettings.TEXT_SCALES:
			var scene := _scene()
			scene.settings.text_scale = scale
			scene.apply_text_scale()
			var rows: Array = []
			_seen = {}
			var add := func(name: String, _label: Label) -> void:
				_snap(scene, name, rows)
			_collect_modals(scene, add)
			var judged: int = 0
			for row in rows:
				var path: String = _node_path(row[1])
				if not (path.contains("ResolutionPanel") or path.contains("/Toast")):
					continue
				judged += 1
				for f in (row[5] if row.size() > 5 else overflow_of(row[0], row[1], row[2], row[3], row[4])):
					bad.append("%s %.2fx: %s" % [locale, scale, f])
			if judged < 20:
				bad.append("%s %.2fx: judged only %d labels" % [locale, scale, judged])
			scene.free()
	Loc.set_locale(Loc.LOCALE_EN)
	return "ok" if bad.is_empty() else "modals or toasts overflow (%d): %s" % [bad.size(), "\n  ".join(PackedStringArray(bad))]


## Sol Central's rows at every text scale (the Earth sidebar scrolls vertically above
## 100%, so this checks width), in English and under pseudo-localization.
func test_sol_central_rows_fit_at_every_text_scale() -> String:
	var bad: Array = []
	for locale in [Loc.LOCALE_EN, Loc.LOCALE_PSEUDO]:
		Loc.set_locale(locale)
		for scale in AccessibilitySettings.TEXT_SCALES:
			var scene := _scene()
			scene.settings.text_scale = scale
			scene.apply_text_scale()
			var rows: Array = []
			_seen = {}
			var add := func(name: String, _label: Label) -> void:
				_snap(scene, name, rows)
			_collect_sol(scene, add)
			if rows.size() < 10:
				bad.append("%s %.2fx: collected %d rows" % [locale, scale, rows.size()])
			for row in rows:
				for f in (row[5] if row.size() > 5 else overflow_of(row[0], row[1], row[2], row[3], row[4])):
					bad.append("%s %.2fx: %s" % [locale, scale, f])
			scene.free()
	Loc.set_locale(Loc.LOCALE_EN)
	return "ok" if bad.is_empty() else "Sol Central rows overflow: %s" % str(bad)


## The takeover rows at every text scale, English and pseudo-localization.
func test_takeover_rows_fit_at_every_text_scale() -> String:
	var bad: Array = []
	for locale in [Loc.LOCALE_EN, Loc.LOCALE_PSEUDO]:
		Loc.set_locale(locale)
		for scale in AccessibilitySettings.TEXT_SCALES:
			var scene := _scene()
			scene.settings.text_scale = scale
			scene.apply_text_scale()
			var rows: Array = []
			_seen = {}
			var add := func(name: String, _label: Label) -> void:
				_snap(scene, name, rows)
			_collect_takeover(scene, add)
			if rows.size() < 10:
				bad.append("%s %.2fx: collected %d rows" % [locale, scale, rows.size()])
			for row in rows:
				for f in (row[5] if row.size() > 5 else overflow_of(row[0], row[1], row[2], row[3], row[4])):
					bad.append("%s %.2fx: %s" % [locale, scale, f])
			scene.free()
	Loc.set_locale(Loc.LOCALE_EN)
	return "ok" if bad.is_empty() else "takeover rows overflow: %s" % str(bad)


## The lever rows at every text scale, English and pseudo-localization.
func test_lever_rows_fit_at_every_text_scale() -> String:
	var bad: Array = []
	for locale in [Loc.LOCALE_EN, Loc.LOCALE_PSEUDO]:
		Loc.set_locale(locale)
		for scale in AccessibilitySettings.TEXT_SCALES:
			var scene := _scene()
			scene.settings.text_scale = scale
			scene.apply_text_scale()
			var rows: Array = []
			_seen = {}
			var add := func(name: String, _label: Label) -> void:
				_snap(scene, name, rows)
			_collect_levers(scene, add)
			if rows.size() < 10:
				bad.append("%s %.2fx: collected %d rows" % [locale, scale, rows.size()])
			for row in rows:
				for f in (row[5] if row.size() > 5 else overflow_of(row[0], row[1], row[2], row[3], row[4])):
					bad.append("%s %.2fx: %s" % [locale, scale, f])
			scene.free()
	Loc.set_locale(Loc.LOCALE_EN)
	return "ok" if bad.is_empty() else "lever rows overflow: %s" % str(bad)
