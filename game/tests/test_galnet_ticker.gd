extends RefCounted
## Tests for the live GalNet ticker feed and the market modal geometry (part of #20).

func _hud_with_market() -> OrbitalHUD:
	var rc := RunController.new(null, 84)
	var hud := OrbitalHUD.new(rc)
	hud.market = StationMarket.new()
	return hud


func _has_line(hud: OrbitalHUD, category: String, needle: String) -> bool:
	for h in hud.galnet_headlines:
		if h["category"] == category and needle in str(h["text"]):
			return true
	return false


func test_modal_rect_is_inside_map_panel_and_clear_of_sidebar() -> String:
	var m: Rect2 = OrbitalHUD.MODAL_OVERLAY_RECT
	if not OrbitalHUD.TACTICAL_MAP_RECT.encloses(m):
		return "modal %s not enclosed by map panel %s" % [str(m), str(OrbitalHUD.TACTICAL_MAP_RECT)]
	if m.intersects(OrbitalHUD.SIDEBAR_RECT):
		return "modal %s intersects sidebar %s" % [str(m), str(OrbitalHUD.SIDEBAR_RECT)]
	if m.intersects(OrbitalHUD.TICKER_RECT) or m.intersects(OrbitalHUD.HEADER_RECT):
		return "modal overlaps header or ticker"
	var inset: float = minf(m.position.x - OrbitalHUD.TACTICAL_MAP_RECT.position.x, OrbitalHUD.TACTICAL_MAP_RECT.end.x - m.end.x)
	if inset < 16.0:
		return "modal margin %f too tight" % inset
	return "ok"


func test_hazard_event_produces_ticker_line() -> String:
	var hud := _hud_with_market()
	var haz := Hazards.new([1.0, 1.0], null, null, 3)
	hud.bind_hazards(haz)
	haz.record("t1", "player", 4, 2, 5, "ORE", "storm on the route: arrival 2 rounds late; hull breach: 5 of 40 units lost")
	if not _has_line(hud, "HAZARD", "storm on the route"):
		return "hazard record did not reach the ticker"
	if hud.galnet_headlines[0]["severity"] != "WARNING":
		return "loss hazard should be a WARNING"
	return "ok"


func test_piracy_events_produce_ticker_lines() -> String:
	var hud := _hud_with_market()
	var desk := Piracy.new([1.0, 1.0], null, null, 9)
	hud.bind_piracy(desk)
	desk.raid_demanded.emit({"ransom": 450, "agent_id": "player", "origin": "earth", "destination": "mars", "commodity": "ORE"})
	if not _has_line(hud, "PIRACY", "demand 450 CR"):
		return "raid demand missing from ticker"
	if hud.galnet_headlines[0]["severity"] != "CRITICAL":
		return "demand should be CRITICAL"
	desk.raid_resolved.emit({"status": "paid", "agent_id": "player", "cr_taken": 450})
	if not _has_line(hud, "PIRACY", "paid 450 CR"):
		return "raid resolution missing from ticker"
	return "ok"


func test_transit_event_produces_ticker_lines() -> String:
	var hud := _hud_with_market()
	hud.post_transit_event("departed", "earth", "mars", "ore", 12, 3)
	if not _has_line(hud, "TRANSIT", "ETA 3 rounds"):
		return "departure missing from ticker"
	hud.post_transit_event("arrived", "earth", "mars", "ORE", 12)
	if not _has_line(hud, "TRANSIT", "docked at"):
		return "arrival missing from ticker"
	return "ok"


func test_fill_and_market_move_produce_ticker_lines() -> String:
	var hud := OrbitalHUD.new(RunController.new(null, 84))
	var lp := M0Loop.new(hud)
	lp.set_tab(M0Loop.Tab.MARKET)
	var before: int = hud.galnet_headlines.size()
	hud.gamepad_focus.set_quantity(3)
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "fill failed: %s" % hud.gamepad_focus.last_rejection_reason
	if not _has_line(hud, "MARKET", "FILL: BUY 3 ORE"):
		return "fill missing from ticker"
	# Wiping out the whole ask side moves the mid by well over the threshold.
	var m: StationMarket = hud.market
	var asks: Array = m.ladder("earth", "ORE", 5)["asks"]
	var total: int = 0
	for a in asks:
		total += int(a["quantity"])
	m.execute("earth", "ORE", "BUY", total - 3, 100000.0)
	if not _has_line(hud, "MARKET", "MOVE: ORE"):
		return "large book move missing from ticker"
	if hud.galnet_headlines.size() <= before:
		return "history did not grow"
	return "ok"


func test_refinancing_stage_and_insolvency_still_post() -> String:
	var d := DoomsdayClock.new(36000, 10000, 10, 500)
	var rc := RunController.new(null, 100, d)
	var hud := OrbitalHUD.new(rc)
	rc.round_advanced.emit(4)
	rc.bankruptcy_pending.emit({"insolvent": true, "total_debt": 5, "shortfall": 2})
	rc.run_collapsed.emit()
	if not _has_line(hud, "DEBT", "QUARTERLY REFINANCING") or not _has_line(hud, "INSOLVENCY", "CHAPTER 11") or not _has_line(hud, "COLLAPSE", "SOVEREIGN DEFAULT"):
		return "controller events missing from ticker"
	return "ok"


func test_history_is_bounded_and_newest_first() -> String:
	var hud := OrbitalHUD.new()
	for i in 60:
		hud.post_headline("event %d" % i)
	if hud.galnet_headlines.size() != OrbitalHUD.HEADLINE_HISTORY_MAX:
		return "history size %d, expected %d" % [hud.galnet_headlines.size(), OrbitalHUD.HEADLINE_HISTORY_MAX]
	if hud.galnet_headlines[0]["text"] != "event 59":
		return "newest headline is not first"
	var lines: Array = hud.get_ticker_lines()
	if lines.size() != OrbitalHUD.TICKER_VISIBLE_LINES or not "event 59" in lines[0]["text"]:
		return "ticker did not show the newest lines"
	if hud._ticker_clock.size() > OrbitalHUD.TICKER_VISIBLE_LINES:
		return "marquee clocks leaked for dropped headlines: %d" % hud._ticker_clock.size()
	return "ok"


func test_long_lines_scroll_and_short_lines_do_not() -> String:
	var hud := OrbitalHUD.new()
	hud.post_headline("short")
	hud.post_headline("LONG ".repeat(80))
	var l0: Array = hud.get_ticker_lines()
	if not bool(l0[0]["overflow"]) or bool(l0[1]["overflow"]):
		return "overflow flags wrong: %s" % str(l0)
	if float(l0[0]["offset"]) != 0.0:
		return "line should start unscrolled"
	hud.advance_ticker(OrbitalHUD.TICKER_DWELL_SECONDS + 2.0)
	var l1: Array = hud.get_ticker_lines()
	if float(l1[0]["offset"]) <= 0.0:
		return "long line offset did not advance"
	if float(l1[1]["offset"]) != 0.0:
		return "short line must not scroll"
	var travel: float = float(l1[0]["width"]) - OrbitalHUD.TICKER_VIEW_WIDTH + OrbitalHUD.TICKER_SCROLL_GAP
	hud.advance_ticker(1000.0)
	for i in 40:
		hud.advance_ticker(0.37)
		if float(hud.get_ticker_lines()[0]["offset"]) > travel + 0.001:
			return "offset exceeded travel"
	return "ok"


func test_real_font_measure_is_honoured() -> String:
	var hud := OrbitalHUD.new()
	hud.post_headline("x")
	var wide := func(_t: String) -> float: return 5000.0
	var lines: Array = hud.get_ticker_lines(wide)
	if not bool(lines[0]["overflow"]):
		return "measure callable ignored"
	return "ok"


func test_main_scene_ticker_labels_follow_the_feed() -> String:
	var scene = load("res://scenes/main.tscn").instantiate()
	scene.initialize_systems(RunController.new(null, 84))
	scene._resolve_child_nodes()
	scene._build_readouts()
	scene.hud.post_headline("LONG ".repeat(120), "HAZARD", "WARNING")
	scene.hud.advance_ticker(OrbitalHUD.TICKER_DWELL_SECONDS + 3.0)
	scene._refresh_readouts()
	var ok_text: bool = scene.ticker_labels.size() == OrbitalHUD.TICKER_VISIBLE_LINES and scene.ticker_labels[0].text.begins_with("HAZARD:")
	var moved: bool = scene.ticker_labels[0].position.x < 0.0
	var modal_ok: bool = scene.market_modal.position == OrbitalHUD.MODAL_OVERLAY_RECT.position and scene.market_modal.size == OrbitalHUD.MODAL_OVERLAY_RECT.size
	scene.free()
	if not ok_text:
		return "ticker labels not populated"
	if not moved:
		return "ticker label did not scroll"
	if not modal_ok:
		return "market modal does not use MODAL_OVERLAY_RECT"
	return "ok"
