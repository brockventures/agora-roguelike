extends RefCounted
## Fleet tab (Epic 6 #122): the display-only ship readers, the hull cursor, and the rows.

const TravelTest := preload("res://tests/test_travel.gd")


func _loop(p_seed: int = 7) -> Dictionary:
	var rc := RunController.new(null, p_seed)
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	return {"rc": rc, "hud": hud, "loop": lp}


func _scene(ships: Array = []) -> Node:
	var scene = load("res://scenes/main.tscn").instantiate()
	var rc := RunController.new(null, 84)
	if not ships.is_empty():
		rc.ships = ships
	scene.initialize_systems(rc)
	scene._resolve_child_nodes()
	scene._build_readouts()
	return scene


func _fleet_of(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append({"id": "h%d" % i, "hull_value_cr": 0, "archetype": FleetView.ARCHETYPES[i % 5]})
	return out


func _texts(root: Node) -> Array:
	var out: Array = []
	for c in root.find_children("*", "Label", true, false):
		var l := c as Label
		var shown: bool = true
		var n: Node = l
		while n != null and n != root.get_parent():
			if n is CanvasItem and not (n as CanvasItem).visible:
				shown = false
			n = n.get_parent()
		if shown and l.text != "":
			out.append(l.text)
	return out


func test_stock_ship_reads_as_a_full_hauler_without_gaining_keys() -> String:
	var ship: Dictionary = Chapter11.STARTER_SHIP.duplicate(true)
	if FleetView.archetype_of(ship) != FleetView.HAULER or FleetView.hull_pct(ship) != 100 or FleetView.shield_pct(ship) != 100:
		return "a ship with no display keys must read HAULER / 100 / 100"
	if ship.size() != 2 or ship.has("archetype"):
		return "reading must not write keys: %s" % str(ship)
	if Chapter11.STARTER_SHIP.size() != 2:
		return "STARTER_SHIP must stay {id, hull_value_cr} so saves and pins do not move"
	return "ok"


func test_readers_accept_the_five_archetypes_and_clamp() -> String:
	for a in ["HAULER", "INTERCEPTOR", "FREIGHTER", "SCOUT", "SCRAP_BARGE"]:
		if FleetView.archetype_of({"archetype": a}) != a:
			return "%s not recognised" % a
	if FleetView.archetype_of({"archetype": "Scrap Barge"}) != FleetView.SCRAP_BARGE:
		return "spaced, mixed-case name should normalise"
	if FleetView.archetype_of({"archetype": "dreadnought"}) != FleetView.HAULER or FleetView.archetype_of("junk") != FleetView.HAULER:
		return "unknown archetype must fall back to HAULER"
	if FleetView.hull_pct({"hull_pct": 250}) != 100 or FleetView.shield_pct({"shield_pct": -5}) != 0:
		return "meters clamp to 0..100"
	return "ok"


func test_every_archetype_has_a_string() -> String:
	for a in FleetView.ARCHETYPES:
		if FleetView.archetype_label({"archetype": a}) == str(FleetView.ARCHETYPE_KEYS[a]):
			return "no string for %s" % a
	if FleetView.archetype_label({"archetype": "SCRAP_BARGE"}) != "SCRAP BARGE":
		return "scrap barge label"
	return "ok"


func test_status_follows_the_corp_voyage_with_an_eta() -> String:
	var rc := RunController.new(null, 7)
	var st: Dictionary = FleetView.status_of(rc)
	if st["state"] != FleetView.STATE_DOCKED or st["station"] != rc.docked_at:
		return "fresh run should be docked: %s" % str(st)
	var plan: Dictionary = rc.can_depart("ceres" if rc.docked_at != "ceres" else "earth")
	rc.cr = 100000
	var dest: String = "ceres" if rc.docked_at != "ceres" else "earth"
	if not rc.depart(dest).get("ok", true):
		return "could not depart for the test"
	st = FleetView.status_of(rc)
	if st["state"] != FleetView.STATE_TRANSIT or st["destination"] != dest or int(st["eta_rounds"]) < 1:
		return "in transit with an ETA expected: %s (plan %s)" % [str(st), str(plan)]
	return "ok"


func test_cursor_is_clamped_and_windowed() -> String:
	if FleetView.step_cursor(0, -1, 3) != 0 or FleetView.step_cursor(2, 1, 3) != 2 or FleetView.step_cursor(0, 1, 3) != 1:
		return "step_cursor clamps without wrapping"
	if FleetView.step_cursor(5, 0, 0) != 0:
		return "empty fleet pins to 0"
	if FleetView.window_start(0, 9, 4) != 0 or FleetView.window_start(3, 9, 4) != 0 or FleetView.window_start(4, 9, 4) != 1 or FleetView.window_start(8, 9, 4) != 5:
		return "window must keep the cursor in view"
	return "ok"


func test_dpad_walks_the_hulls_on_the_fleet_tab_only() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	var f: GamepadFocus = (ctx["hud"] as OrbitalHUD).gamepad_focus
	rc.ships = _fleet_of(3)
	if lp.dispatch_action(M0Loop.ACT_DOWN) or lp.fleet_cursor != 0:
		return "d-pad must do nothing on MAP"
	lp.set_tab(M0Loop.Tab.FLEET)
	var ladder: int = f.ladder_index
	var qty: int = f.order_qty
	if not lp.dispatch_action(M0Loop.ACT_DOWN) or lp.fleet_cursor != 1:
		return "down should select hull 2, got %d" % lp.fleet_cursor
	lp.dispatch_action(M0Loop.ACT_DOWN)
	if lp.dispatch_action(M0Loop.ACT_DOWN) or lp.fleet_cursor != 2:
		return "down at the last hull is a no-op, cursor %d" % lp.fleet_cursor
	if not lp.dispatch_action(M0Loop.ACT_UP) or lp.fleet_cursor != 1:
		return "up should step back"
	if lp.dispatch_action(M0Loop.ACT_LEFT) or lp.dispatch_action(M0Loop.ACT_RIGHT) or lp.dispatch_action(M0Loop.ACT_COMMODITY_NEXT) or lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "left/right/commodity/A stay inert on FLEET"
	if f.ladder_index != ladder or f.order_qty != qty:
		return "Fleet navigation must not touch the order ladder"
	lp.set_tab(M0Loop.Tab.MARKET)
	lp.dispatch_action(M0Loop.ACT_UP)
	if lp.fleet_cursor != 1 or f.ladder_index != ladder + 1:
		return "on MARKET up must still deepen the ladder, not move the fleet cursor"
	return "ok"


func test_fleet_navigation_plays_one_sound_and_a_single_hull_is_inert() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	var hud: OrbitalHUD = ctx["hud"]
	lp.set_tab(M0Loop.Tab.FLEET)
	if lp.dispatch_action(M0Loop.ACT_DOWN):
		return "one hull: d-pad has nowhere to go"
	rc.ships = _fleet_of(2)
	var heard: Array = []
	hud.tactile_audio.sound_played.connect(func(id, _bus, _db, _pitch): heard.append(id))
	hud.tactile_audio.advance_time(1.0)
	if not lp.dispatch_action(M0Loop.ACT_DOWN) or heard.size() != 1:
		return "one sound per step, got %s" % str(heard)
	return "ok"


func test_cursor_is_clamped_when_the_fleet_shrinks_and_never_saved() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	rc.ships = _fleet_of(3)
	lp.set_tab(M0Loop.Tab.FLEET)
	lp.dispatch_action(M0Loop.ACT_DOWN)
	lp.dispatch_action(M0Loop.ACT_DOWN)
	rc.ships = _fleet_of(1)
	if lp.selected_hull() != 0:
		return "cursor must clamp into a smaller fleet"
	if str(rc.to_dict()).contains("fleet_cursor"):
		return "cursor leaked into the save"
	return "ok"


func test_rows_show_hull_archetype_status_meters_and_manifest() -> String:
	var ships := [
		{"id": "a", "hull_value_cr": 0, "archetype": "INTERCEPTOR", "hull_pct": 64, "shield_pct": 30},
		{"id": "b", "hull_value_cr": 0, "archetype": "SCRAP_BARGE"},
	]
	var scene := _scene(ships)
	scene.controller.cargo = {"ORE": 12, "FUEL": 3}
	scene.loop.set_tab(M0Loop.Tab.FLEET)
	scene._refresh_readouts()
	var t: Array = _texts(scene.fleet_panel)
	for want in ["HULL 1", "HULL 2", "INTERCEPTOR", "SCRAP BARGE", "HULL", "SHIELD", "HOLD", "64%", "30%", "15/100", "×12", "×3", "CARGO MANIFEST"]:
		if not t.has(want):
			return "missing '%s' in %s" % [want, str(t)]
	var has_docked := false
	for s in t:
		if str(s).begins_with("DOCKED"):
			has_docked = true
	if not has_docked:
		return "no docking status in %s" % str(t)
	scene.loop.dispatch_action(M0Loop.ACT_DOWN)
	scene._refresh_readouts()
	t = _texts(scene.fleet_panel)
	if not t.has("100%"):
		return "hull 2 has no damage: 100% expected, got %s" % str(t)
	var hulls: Array = scene._fleet["hulls"]
	if (hulls[0]["bg"] as Control).visible or not (hulls[1]["bg"] as Control).visible:
		return "selection highlight should sit on hull 2"
	scene.free()
	return "ok"


func test_transit_shows_an_eta_chip_and_the_empty_hold_says_so() -> String:
	var scene := _scene()
	var rc: RunController = scene.controller
	rc.cargo = {}
	rc.cr = 100000
	var dest: String = "ceres" if rc.docked_at != "ceres" else "earth"
	rc.depart(dest)
	scene.loop.set_tab(M0Loop.Tab.FLEET)
	scene._refresh_readouts()
	var t: Array = _texts(scene.fleet_panel)
	var eta := false
	var transit := false
	for s in t:
		eta = eta or str(s).begins_with("ETA ")
		transit = transit or str(s).begins_with("IN TRANSIT")
	if not eta or not transit:
		return "transit status + ETA chip expected, got %s" % str(t)
	if not t.has("HOLD EMPTY"):
		return "empty hold line missing: %s" % str(t)
	if t.has("CARGO MANIFEST"):
		return "no manifest header for an empty hold"
	scene.free()
	return "ok"


func test_display_only_keys_leave_the_save_and_the_pin_alone() -> String:
	var a := RunController.new(null, 7)
	var b := RunController.new(null, 7)
	FleetView.archetype_of(b.ships[0])
	FleetView.hull_pct(b.ships[0])
	if a.to_dict() != b.to_dict():
		return "reading ship display keys changed the save"
	if TravelTest.NEVER_TRAVELS_HASH != "b30e7504c6f13e8c33288f628cc2337e913462b52f0d7193e635ffa5ddd65afc":
		return "NEVER_TRAVELS_HASH moved"
	return "ok"
