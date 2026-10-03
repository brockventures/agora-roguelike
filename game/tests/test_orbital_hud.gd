extends RefCounted
## Unit tests for OrbitalHUD Bloomberg Terminal layout and telemetry controller (#21).

func test_init_defaults() -> String:
	var hud := OrbitalHUD.new()
	if hud.VIEWPORT_WIDTH != 1280.0 or hud.VIEWPORT_HEIGHT != 800.0:
		return "viewport bounds mismatch"
	if hud.active_station != "earth" or hud.active_commodity != "ORE":
		return "initial station or commodity mismatch"
	if hud.tactical_map == null or hud.trading_overlay == null:
		return "child sub-models failed to instantiate"
	if hud.HEADER_RECT.size != Vector2(1280.0, 64.0):
		return "header rect size mismatch"
	if hud.TACTICAL_MAP_RECT.size != Vector2(880.0, 672.0):
		return "tactical map rect size mismatch"
	if hud.SIDEBAR_RECT.size != Vector2(400.0, 672.0):
		return "sidebar rect size mismatch"
	if hud.TICKER_RECT.size != Vector2(1280.0, 64.0):
		return "ticker rect size mismatch"
	if hud.galnet_headlines.size() != 3:
		return "default headlines count should be 3"
	return "ok"

func test_station_and_commodity_cycling() -> String:
	var hud := OrbitalHUD.new()
	var station_signals: Array = []
	var commodity_signals: Array = []
	hud.station_changed.connect(func(s): station_signals.append(s))
	hud.commodity_changed.connect(func(c): commodity_signals.append(c))

	# Station forward cycle: earth -> luna -> mars -> ceres -> earth
	var s1 := hud.cycle_station(1)
	if s1 != "luna" or hud.active_station != "luna" or hud.tactical_map.selected_station != "luna":
		return "cycle_station forward failed on luna"
	var s2 := hud.cycle_station(1)
	if s2 != "mars":
		return "cycle_station forward failed on mars"
	var s3 := hud.cycle_station(1)
	if s3 != "ceres":
		return "cycle_station forward failed on ceres"
	var s4 := hud.cycle_station(1)
	if s4 != "earth":
		return "cycle_station forward wrap to earth failed"

	# Station backward cycle
	var s_prev := hud.cycle_station(-1)
	if s_prev != "ceres":
		return "cycle_station backward wrap to ceres failed"

	# Commodity forward cycle: ORE -> FRAG -> FOOD -> WATER -> FUEL -> MACHINERY -> ORE
	var c1 := hud.cycle_commodity(1)
	if c1 != "FRAG" or hud.active_commodity != "FRAG" or hud.trading_overlay.selected_commodity != "FRAG":
		return "cycle_commodity forward failed on FRAG"
	var c2 := hud.cycle_commodity(1)
	if c2 != "FOOD":
		return "cycle_commodity forward failed on FOOD"

	# Commodity backward cycle
	var c_back := hud.cycle_commodity(-1)
	if c_back != "FRAG":
		return "cycle_commodity backward failed"

	if station_signals.size() != 5 or commodity_signals.size() != 3:
		return "signal dispatch count mismatch"

	return "ok"

func test_header_telemetry_controller_binding() -> String:
	var d := DoomsdayClock.new(36000, 0, 0, 0)
	var rc := RunController.new(null, 100, d, {}, 60)
	rc.cr = 9200
	var hud := OrbitalHUD.new(rc)

	var h: Dictionary = hud.get_header_telemetry()
	if h["cr"] != 9200 or h["principal_debt"] != 0:
		return "cr or debt mismatch in header"
	if h["current_round"] != 0 or h["stage_name"] != "NORMAL":
		return "round or stage mismatch"

	# Advance 30 sub-ticks at 1/60s step -> round 0, 0.5 progress
	for i in 30:
		rc.advance(1.0 / 60.0)

	var h_mid: Dictionary = hud.get_header_telemetry()
	if absf(float(h_mid["round_progress"]) - 0.5) > 0.05:
		return "round progress mismatch: %f" % float(h_mid["round_progress"])

	# Advance 30 more -> round 1
	for i in 30:
		rc.advance(1.0 / 60.0)

	var h_r1: Dictionary = hud.get_header_telemetry()
	if h_r1["current_round"] != 1:
		return "round 1 advance failed"

	return "ok"

func test_sidebar_and_order_book_ladder() -> String:
	var d := DoomsdayClock.new(36000, 0, 0, 0)
	var rc := RunController.new(null, 1, d)
	rc.cargo = {"ORE": 50, "FOOD": 12}
	var hud := OrbitalHUD.new(rc, "ceres", "ORE")

	var side: Dictionary = hud.get_sidebar_telemetry()
	if side["station"] != "ceres" or side["commodity"] != "ORE":
		return "sidebar station/commodity mismatch"
	if side["cargo_held"] != 50:
		return "cargo_held mismatch for ORE: %d" % side["cargo_held"]

	var ladder: Dictionary = side["order_book_ladder"]
	var bids: Array = ladder["bids"]
	var asks: Array = ladder["asks"]
	if bids.size() != 5 or asks.size() != 5:
		return "order book ladder size mismatch"

	var best_b: float = ladder["best_bid"]
	var best_a: float = ladder["best_ask"]
	var mid: float = ladder["mid_price"]
	var spread: float = ladder["spread"]

	if best_b >= best_a:
		return "best bid must be strictly less than best ask"
	if mid <= best_b or mid >= best_a:
		return "mid price must be between best bid and best ask"
	if absf(spread - (best_a - best_b)) > 0.01:
		return "spread calculation mismatch"

	# Check descending bid order and ascending ask order
	for i in range(1, 5):
		if float(bids[i]["price"]) >= float(bids[i - 1]["price"]):
			return "bids must be sorted descending"
		if float(asks[i]["price"]) <= float(asks[i - 1]["price"]):
			return "asks must be sorted ascending"

	return "ok"

func test_modal_overlay_routing() -> String:
	var hud := OrbitalHUD.new()
	var toggle_events: Array = []
	hud.trading_overlay_toggled.connect(func(v): toggle_events.append(v))

	if hud.is_trading_overlay_open():
		return "overlay should initially be closed"

	if not hud.open_trading_overlay():
		return "open_trading_overlay failed"
	if not hud.is_trading_overlay_open():
		return "overlay state should be open"

	hud.close_trading_overlay()
	if hud.is_trading_overlay_open():
		return "close_trading_overlay failed"

	# Toggle open then close
	var is_now_open := hud.toggle_trading_overlay()
	if not is_now_open or not hud.is_trading_overlay_open():
		return "toggle to open failed"

	var is_now_closed := hud.toggle_trading_overlay()
	if is_now_closed or hud.is_trading_overlay_open():
		return "toggle to close failed"

	if toggle_events != [true, false, true, false]:
		return "toggle events sequence mismatch: %s" % str(toggle_events)

	return "ok"

func test_galnet_ticker_stream() -> String:
	var hud := OrbitalHUD.new()
	var emitted: Array = []
	hud.headline_emitted.connect(func(h): emitted.append(h))

	var item: Dictionary = hud.post_headline("SOLAR FLARE DETECTED: CME intercepting Mars corridor.", "HAZARD", "WARNING")
	if item["category"] != "HAZARD" or item["severity"] != "WARNING":
		return "headline payload mismatch"
	if emitted.size() != 1:
		return "headline signal failed to emit"

	# Test FIFO cap (max 20)
	for i in 25:
		hud.post_headline("Tick headline %d" % i)

	if hud.galnet_headlines.size() > 20:
		return "galnet headlines exceeded 20 item cap: %d" % hud.galnet_headlines.size()

	var recent: Array = hud.get_recent_headlines(3)
	if recent.size() != 3:
		return "get_recent_headlines slice mismatch"

	return "ok"

func test_controller_event_reactions() -> String:
	var d := DoomsdayClock.new(36000, 10000, 10, 500)
	var rc := RunController.new(null, 100, d)
	var hud := OrbitalHUD.new(rc)

	var alerts: Array = []
	hud.emergency_alert.connect(func(a): alerts.append(a))

	# Trigger insolvency interrupt
	rc.bankruptcy_pending.emit({"net_worth": -500})
	if alerts.size() != 1 or not alerts[0].begins_with("CHAPTER 11"):
		return "insolvency alert failed to forward"

	# Trigger collapse
	rc.run_collapsed.emit()
	if alerts.size() != 2 or alerts[1] != "COLLAPSE":
		return "collapse alert failed to forward"

	return "ok"

func test_sim_speed_and_pause_controls() -> String:
	var d := DoomsdayClock.new(36000, 0, 0, 0)
	var rc := RunController.new(null, 1, d)
	var hud := OrbitalHUD.new(rc)

	# Initial pause state: running
	var h: Dictionary = hud.get_header_telemetry()
	if bool(h["is_paused"]):
		return "clock should initially be unpaused"

	var p1 := hud.toggle_pause()
	var h1: Dictionary = hud.get_header_telemetry()
	if not p1 or not bool(h1["is_paused"]):
		return "toggle_pause to paused failed"

	var p2 := hud.toggle_pause()
	var h2: Dictionary = hud.get_header_telemetry()
	if p2 or bool(h2["is_paused"]):
		return "toggle_pause to resume failed"

	# Speed cycling 1 -> 2 -> 5 -> 1
	var sp1 := hud.cycle_sim_speed()
	var hs1: Dictionary = hud.get_header_telemetry()
	if sp1 != 2 or hs1["sim_speed"] != 2:
		return "sim speed cycle to 2 failed"

	var sp2 := hud.cycle_sim_speed()
	var hs2: Dictionary = hud.get_header_telemetry()
	if sp2 != 5 or hs2["sim_speed"] != 5:
		return "sim speed cycle to 5 failed"

	var sp3 := hud.cycle_sim_speed()
	var hs3: Dictionary = hud.get_header_telemetry()
	if sp3 != 1 or hs3["sim_speed"] != 1:
		return "sim speed cycle wrap to 1 failed"

	return "ok"

func test_to_dict_serialization() -> String:
	var d := DoomsdayClock.new(36000, 20000, 10, 500)
	var rc := RunController.new(null, 10, d)
	var hud := OrbitalHUD.new(rc, "mars", "FOOD")
	hud.open_trading_overlay()

	var snap: Dictionary = hud.to_dict()
	if snap["viewport"] != [1280.0, 800.0]:
		return "viewport mismatch in snapshot"
	if snap["active_station"] != "mars" or snap["active_commodity"] != "FOOD":
		return "active station or commodity mismatch in snapshot"
	if not bool(snap["is_trading_overlay_open"]):
		return "trading overlay open flag mismatch"
	if not snap.has("panels") or not snap.has("header") or not snap.has("sidebar"):
		return "missing top-level dictionary keys"
	if not snap.has("tactical_map") or not snap.has("trading_overlay"):
		return "missing child component dictionary keys"

	return "ok"
