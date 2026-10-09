class_name OrbitalHUD
extends RefCounted
## 1280x800 Orbital Bloomberg Terminal HUD Controller for Agora Roguelike (#21).
##
## Dense, responsive HUD architecture targeting native Steam Deck 1280x800 resolution:
## - Header Bar: Doomsday Clock countdown gauge, run stage indicator, CR balance, and sim pace.
## - Tactical Map Center: Sol astrodynamics projection, planetary orbits, and shipping corridors.
## - Right Market Sidebar: Order book depth ladder, commodity quotes, and cargo inventory.
## - Bottom Ticker: GalNet market intelligence, hazard warnings, and fleet transit ETA log.
## - Floating Modal: Integrated TradingOverlay for station trade execution.
##
## Binds to RunController (#10), SolTacticalMap (#21 PR 1), and TradingOverlay (#21 PR 1).

signal station_changed(station_id: String)
signal commodity_changed(commodity_id: String)
signal trading_overlay_toggled(is_open: bool)
signal headline_emitted(headline: Dictionary)
signal emergency_alert(reason: String)

## Native Steam Deck viewport geometry.
const VIEWPORT_WIDTH: float = 1280.0
const VIEWPORT_HEIGHT: float = 800.0
const VIEWPORT_SIZE: Vector2 = Vector2(VIEWPORT_WIDTH, VIEWPORT_HEIGHT)

## Panel layouts in 1280x800 screen space.
const HEADER_RECT: Rect2 = Rect2(0.0, 0.0, 1280.0, 64.0)
const TACTICAL_MAP_RECT: Rect2 = Rect2(0.0, 64.0, 880.0, 672.0)
const SIDEBAR_RECT: Rect2 = Rect2(880.0, 64.0, 400.0, 672.0)
const TICKER_RECT: Rect2 = Rect2(0.0, 736.0, 1280.0, 64.0)
## The market modal lives inside the tactical map panel (never over the
## sidebar's order-book ladder), inset 24 px left/right and 32 px top/bottom.
const MODAL_OVERLAY_RECT: Rect2 = Rect2(24.0, 96.0, 832.0, 608.0)

## GalNet ticker feed: bounded history, lines visible at once, marquee tuning.
const HEADLINE_HISTORY_MAX: int = 20
const TICKER_VISIBLE_LINES: int = 2
const TICKER_VIEW_WIDTH: float = 1248.0
const TICKER_SCROLL_SPEED: float = 60.0
const TICKER_DWELL_SECONDS: float = 1.5
const TICKER_SCROLL_GAP: float = 32.0
## Rough glyph width used when no real font measure is supplied (headless).
const TICKER_FALLBACK_CHAR_WIDTH: float = 9.0
## A book's mid price must move by at least this fraction to be reported.
const MARKET_MOVE_THRESHOLD: float = 0.02

## Supported commodities for cycling, canonical from Transit.
const COMMODITIES: Array[String] = Transit.COMMODITIES

var controller: RunController = null
var tactical_map: SolTacticalMap = null
var trading_overlay: TradingOverlay = null
var gamepad_focus: GamepadFocus = null
var vector_orrery: VectorOrrery = null
var tactile_audio: TactileAudio = null
## Resting books for the stations that trade live (Earth, Mars). Null or a
## station without a book falls back to the synthetic ladder below.
var market: StationMarket = null:
	set = set_market

var active_station: String = "earth"
var active_commodity: String = "ORE"
var galnet_headlines: Array = []
var _crisis_deck: CrisisDeck = null
var order_book_depth_levels: int = 5

## Ticker marquee clocks keyed by headline seq (seconds since the line appeared).
var _ticker_clock: Dictionary = {}
var _headline_seq: int = 0
var _last_mid: Dictionary = {}
var _focus_executed_callable: Callable
var _hazards: Hazards = null
var _piracy: Piracy = null

## Controller signal callables for clean unbinding.
var _round_callable: Callable
var _bankruptcy_callable: Callable
var _stage_callable: Callable
var _collapsed_callable: Callable
var _paused_callable: Callable
var _speed_callable: Callable

func _init(p_controller: RunController = null, p_station: String = "earth", p_commodity: String = "ORE") -> void:
	if Transit.STATIONS.has(p_station.to_lower()):
		active_station = p_station.to_lower()
	var norm_c: String = _normalize_commodity(p_commodity)
	if not norm_c.is_empty():
		active_commodity = norm_c

	# Initialize child sub-models
	tactical_map = SolTacticalMap.new(p_controller)
	tactical_map.select_station(active_station)
	trading_overlay = TradingOverlay.new(p_controller, active_station)
	trading_overlay.set_commodity(active_commodity)
	gamepad_focus = GamepadFocus.new(self)
	_focus_executed_callable = Callable(self, "_on_order_executed")
	gamepad_focus.order_executed.connect(_focus_executed_callable)
	vector_orrery = VectorOrrery.new(tactical_map, p_controller)
	tactile_audio = TactileAudio.new()

	# Seed baseline GalNet headlines
	_seed_default_headlines()

	if p_controller != null:
		bind_controller(p_controller)

func bind_controller(rc: RunController) -> void:
	unbind_controller()
	controller = rc
	if controller != null:
		# Bind child models to the new controller
		if tactical_map != null:
			tactical_map.bind_controller(rc)
		if trading_overlay != null:
			trading_overlay.bind_controller(rc)
		if vector_orrery != null:
			vector_orrery.bind_controller(rc)

		_round_callable = Callable(self, "_on_controller_round_advanced")
		_bankruptcy_callable = Callable(self, "_on_controller_bankruptcy_pending")
		_stage_callable = Callable(self, "_on_controller_stage_changed")
		_collapsed_callable = Callable(self, "_on_controller_collapsed")

		controller.round_advanced.connect(_round_callable)
		controller.bankruptcy_pending.connect(_bankruptcy_callable)
		controller.stage_changed.connect(_stage_callable)
		controller.run_collapsed.connect(_collapsed_callable)

		if controller.sim_clock != null:
			_paused_callable = Callable(self, "_on_sim_clock_paused")
			_speed_callable = Callable(self, "_on_sim_clock_speed")
			controller.sim_clock.paused_changed.connect(_paused_callable)
			controller.sim_clock.speed_changed.connect(_speed_callable)

func unbind_controller() -> void:
	if controller != null:
		if _round_callable.is_valid() and controller.round_advanced.is_connected(_round_callable):
			controller.round_advanced.disconnect(_round_callable)
		if _bankruptcy_callable.is_valid() and controller.bankruptcy_pending.is_connected(_bankruptcy_callable):
			controller.bankruptcy_pending.disconnect(_bankruptcy_callable)
		if _stage_callable.is_valid() and controller.stage_changed.is_connected(_stage_callable):
			controller.stage_changed.disconnect(_stage_callable)
		if _collapsed_callable.is_valid() and controller.run_collapsed.is_connected(_collapsed_callable):
			controller.run_collapsed.disconnect(_collapsed_callable)

		if controller.sim_clock != null:
			if _paused_callable.is_valid() and controller.sim_clock.paused_changed.is_connected(_paused_callable):
				controller.sim_clock.paused_changed.disconnect(_paused_callable)
			if _speed_callable.is_valid() and controller.sim_clock.speed_changed.is_connected(_speed_callable):
				controller.sim_clock.speed_changed.disconnect(_speed_callable)

		if tactical_map != null:
			tactical_map.unbind_controller()
		if trading_overlay != null:
			trading_overlay.unbind_controller()
		if vector_orrery != null:
			vector_orrery.unbind_controller()

	controller = null

# --- Header Telemetry ---

func get_header_telemetry() -> Dictionary:
	var cr_val: int = Chapter11.FRESH_START_CR
	var debt_val: int = DoomsdayClock.DEFAULT_DEBT
	var principal_debt_val: int = DoomsdayClock.DEFAULT_DEBT
	var int_rate: int = DoomsdayClock.DEFAULT_INTEREST_RATE_BPS_PER_MINUTE
	var ticks_rem: int = DoomsdayClock.DEFAULT_TOTAL_TICKS
	var stage_name: String = "NORMAL"
	var is_paused: bool = false
	var sim_speed: int = 1
	var round_num: int = 0
	var progress: float = 0.0
	var pending_bankrupt: bool = false

	if controller != null:
		cr_val = controller.cr
		if controller.doomsday != null:
			var d: DoomsdayClock = controller.doomsday
			debt_val = d.get_total_debt()
			principal_debt_val = d.principal_debt
			int_rate = d.interest_rate_bps_per_minute
			ticks_rem = d.ticks_remaining
			stage_name = _stage_to_name(d.stage)
		round_num = controller.get_current_round()
		progress = controller.get_round_progress()
		pending_bankrupt = controller.pending_bankruptcy
		if controller.sim_clock != null:
			is_paused = controller.sim_clock.paused
			sim_speed = controller.sim_clock.speed

	return {
		"viewport_size": [VIEWPORT_WIDTH, VIEWPORT_HEIGHT],
		"cr": cr_val,
		"total_debt": debt_val,
		"principal_debt": principal_debt_val,
		"interest_bps": int_rate,
		"ticks_remaining": ticks_rem,
		"stage_name": stage_name,
		"is_paused": is_paused,
		"sim_speed": sim_speed,
		"speed_label": speed_label(is_paused, sim_speed),
		"current_round": round_num,
		"round_progress": progress,
		"pending_bankruptcy": pending_bankrupt
	}

# --- Sidebar & Order Book Ladder Telemetry ---

func get_sidebar_telemetry() -> Dictionary:
	var base_quote: Dictionary = get_market_quote()
	var ladder: Dictionary = get_order_book_ladder()
	var cargo_qty: int = get_cargo_qty(active_commodity)
	var all_cargo: Dictionary = {}
	if controller != null:
		all_cargo = controller.cargo.duplicate()

	return {
		"station": active_station,
		"commodity": active_commodity,
		"market_quote": base_quote,
		"order_book_ladder": ladder,
		"cargo_held": cargo_qty,
		"all_cargo": all_cargo
	}

func get_market_quote() -> Dictionary:
	var price: float = 50.0
	if Transit.BASE_PRICES.has(active_station) and Transit.BASE_PRICES[active_station].has(active_commodity):
		price = float(Transit.BASE_PRICES[active_station][active_commodity])

	var is_perish: bool = Transit.is_perishable(active_commodity)
	return {
		"station": active_station,
		"station_name": StationMarket.station_name(active_station),
		"commodity": active_commodity,
		"base_price_cr": price,
		"is_perishable": is_perish
	}

func get_order_book_ladder() -> Dictionary:
	if market != null and market.has_book(active_station, active_commodity):
		return market.ladder(active_station, active_commodity, order_book_depth_levels)
	var quote: Dictionary = get_market_quote()
	var base_px: float = quote["base_price_cr"]
	var spread: float = maxf(1.0, snappedf(base_px * 0.04, 0.5))
	var best_bid: float = maxf(1.0, snappedf(base_px - (spread * 0.5), 0.5))
	var best_ask: float = snappedf(base_px + (spread * 0.5), 0.5)
	var step: float = maxf(0.5, snappedf(spread * 0.5, 0.5))

	var bids: Array = []
	var asks: Array = []
	for i in order_book_depth_levels:
		var b_px: float = maxf(1.0, best_bid - (float(i) * step))
		var a_px: float = best_ask + (float(i) * step)
		var b_vol: int = 15 + ((i + 1) * 8)
		var a_vol: int = 12 + ((i + 1) * 7)
		bids.append({"price": snappedf(b_px, 0.5), "quantity": b_vol})
		asks.append({"price": snappedf(a_px, 0.5), "quantity": a_vol})

	return {
		"synthetic": true,
		"spread": snappedf(best_ask - best_bid, 0.5),
		"best_bid": best_bid,
		"best_ask": best_ask,
		"mid_price": snappedf((best_bid + best_ask) * 0.5, 0.5),
		"bids": bids,
		"asks": asks
	}

func get_cargo_qty(commodity: String) -> int:
	var norm: String = _normalize_commodity(commodity)
	if controller != null and controller.cargo.has(norm):
		return int(controller.cargo[norm])
	return 0

# --- Station & Commodity Cycling (Gamepad / Steam Deck Controls) ---

func set_station(p_station: String) -> bool:
	var s: String = p_station.to_lower()
	if not Transit.STATIONS.has(s):
		return false
	if active_station == s:
		return true
	active_station = s
	if tactical_map != null:
		tactical_map.select_station(s)
	if trading_overlay != null:
		trading_overlay.set_station(s)
	if tactile_audio != null:
		tactile_audio.play_sfx(TactileAudio.TAB_SWOOSH)
	station_changed.emit(active_station)
	return true

func cycle_station(direction: int = 1) -> String:
	var idx: int = Transit.STATIONS.find(active_station)
	if idx == -1:
		idx = 0
	var count: int = Transit.STATIONS.size()
	var new_idx: int = (idx + direction) % count
	if new_idx < 0:
		new_idx += count
	set_station(Transit.STATIONS[new_idx])
	return active_station

func set_commodity(p_commodity: String) -> bool:
	var norm: String = _normalize_commodity(p_commodity)
	if norm.is_empty():
		return false
	if active_commodity == norm:
		return true
	active_commodity = norm
	if trading_overlay != null:
		trading_overlay.set_commodity(norm)
	if tactile_audio != null:
		tactile_audio.play_sfx(TactileAudio.NAV_TICK)
	commodity_changed.emit(active_commodity)
	return true

func cycle_commodity(direction: int = 1) -> String:
	var idx: int = Transit.COMMODITIES.find(active_commodity)
	if idx == -1:
		idx = 0
	var count: int = Transit.COMMODITIES.size()
	var new_idx: int = (idx + direction) % count
	if new_idx < 0:
		new_idx += count
	set_commodity(Transit.COMMODITIES[new_idx])
	return active_commodity

# --- Trading Overlay Modal Routing ---

func toggle_trading_overlay() -> bool:
	if trading_overlay == null:
		return false
	var res: bool = trading_overlay.toggle_overlay(active_station)
	if tactile_audio != null:
		tactile_audio.play_sfx(TactileAudio.MODAL_OPEN if res else TactileAudio.MODAL_CLOSE)
	trading_overlay_toggled.emit(res)
	return res

func open_trading_overlay() -> bool:
	if trading_overlay == null:
		return false
	var ok: bool = trading_overlay.open_overlay(active_station)
	if ok:
		if tactile_audio != null:
			tactile_audio.play_sfx(TactileAudio.MODAL_OPEN)
		trading_overlay_toggled.emit(true)
	return ok

func close_trading_overlay() -> void:
	if trading_overlay != null:
		trading_overlay.close_overlay()
		if tactile_audio != null:
			tactile_audio.play_sfx(TactileAudio.MODAL_CLOSE)
		trading_overlay_toggled.emit(false)

func is_trading_overlay_open() -> bool:
	return trading_overlay != null and trading_overlay.is_visible

# --- Simulation Speed & Pause Controls ---

func toggle_pause() -> bool:
	if controller != null and controller.sim_clock != null:
		var new_state: bool = not controller.sim_clock.paused
		controller.sim_clock.set_paused(new_state)
		return new_state
	return false

func cycle_sim_speed() -> int:
	if controller != null and controller.sim_clock != null:
		var cur: int = controller.sim_clock.speed
		var nxt: int = 1
		if cur == 1:
			nxt = 2
		elif cur == 2:
			nxt = 5
		else:
			nxt = 1
		controller.sim_clock.set_speed(nxt)
		return nxt
	return 1

## Header text for the pace indicator: "PAUSED" or "1x" / "2x" / "5x".
static func speed_label(p_paused: bool, p_speed: int) -> String:
	return "PAUSED" if p_paused else "%dx" % p_speed

# --- GalNet Ticker Stream ---

func post_headline(text: String, category: String = "MARKET", severity: String = "INFO") -> Dictionary:
	var r_num: int = controller.get_current_round() if controller != null else 0
	var item: Dictionary = {
		"text": text,
		"category": category.to_upper(),
		"severity": severity.to_upper(),
		"round": r_num,
		"seq": _next_seq()
	}
	galnet_headlines.push_front(item)
	while galnet_headlines.size() > HEADLINE_HISTORY_MAX:
		var dropped: Dictionary = galnet_headlines.pop_back()
		_ticker_clock.erase(int(dropped.get("seq", -1)))
	if tactile_audio != null:
		var sev_up: String = severity.to_upper()
		if sev_up == "CRITICAL":
			tactile_audio.play_sfx(TactileAudio.ALARM_CRITICAL)
		elif sev_up == "WARNING":
			tactile_audio.play_sfx(TactileAudio.ALARM_WARNING)
		else:
			tactile_audio.play_sfx(TactileAudio.TICKER_BLIP)
	headline_emitted.emit(item)
	return item

func _next_seq() -> int:
	_headline_seq += 1
	return _headline_seq

func get_recent_headlines(limit: int = 5) -> Array:
	var cnt: int = mini(limit, galnet_headlines.size())
	return galnet_headlines.slice(0, cnt)

func _seed_default_headlines() -> void:
	galnet_headlines.clear()
	_ticker_clock.clear()
	galnet_headlines.append({
		"text": "SOL SYSTEM COMMERCE COMMISSION: Doomsday debt enforcement protocol active.",
		"category": "REGULATION",
		"severity": "WARNING",
		"round": 0,
		"seq": _next_seq()
	})
	galnet_headlines.append({
		"text": "CERES MINING GUILD: Deep-core ore extractors reporting record yields at Station Alpha.",
		"category": "MARKET",
		"severity": "INFO",
		"round": 0,
		"seq": _next_seq()
	})
	galnet_headlines.append({
		"text": "ORBITAL CORRIDORS: Earth-Luna syzygy alignment open for low-burn bulk transit.",
		"category": "TRANSIT",
		"severity": "INFO",
		"round": 0,
		"seq": _next_seq()
	})

# --- Live feed: hazards, piracy, transit, market ---

func set_market(m: StationMarket) -> void:
	if market != null and market.book_changed.is_connected(_on_book_changed):
		market.book_changed.disconnect(_on_book_changed)
	market = m
	_last_mid.clear()
	if market != null:
		for key in market.books.keys():
			var parts: PackedStringArray = str(key).split(":")
			_last_mid[str(key)] = _book_mid(parts[0], parts[1])
		market.book_changed.connect(_on_book_changed)

## Feeds hazard rolls recorded on a Hazards engine into the ticker.
func bind_hazards(h: Hazards) -> void:
	if _hazards != null and _hazards.hazard_recorded.is_connected(_on_hazard_recorded):
		_hazards.hazard_recorded.disconnect(_on_hazard_recorded)
	_hazards = h
	if _hazards != null:
		_hazards.hazard_recorded.connect(_on_hazard_recorded)

## Feeds crisis draws and expiries from the deck (#12) into the ticker.
func bind_crisis_deck(d: CrisisDeck) -> void:
	if _crisis_deck != null:
		if _crisis_deck.crisis_drawn.is_connected(_on_crisis_drawn):
			_crisis_deck.crisis_drawn.disconnect(_on_crisis_drawn)
		if _crisis_deck.crisis_expired.is_connected(_on_crisis_expired):
			_crisis_deck.crisis_expired.disconnect(_on_crisis_expired)
	_crisis_deck = d
	if _crisis_deck != null:
		_crisis_deck.crisis_drawn.connect(_on_crisis_drawn)
		_crisis_deck.crisis_expired.connect(_on_crisis_expired)

func _on_crisis_drawn(c: Dictionary) -> void:
	post_headline(str(c.get("text", c.get("name", ""))), "CRISIS", "CRITICAL" if str(c.get("tier", "")) == "endgame" else "WARNING")

func _on_crisis_expired(c: Dictionary) -> void:
	post_headline("%s has lifted, books restored" % str(c.get("name", "")), "CRISIS", "INFO")

## Feeds pirate demands and their settlement on a Piracy desk into the ticker.
func bind_piracy(p: Piracy) -> void:
	if _piracy != null:
		if _piracy.raid_demanded.is_connected(_on_raid_demanded):
			_piracy.raid_demanded.disconnect(_on_raid_demanded)
		if _piracy.raid_resolved.is_connected(_on_raid_resolved):
			_piracy.raid_resolved.disconnect(_on_raid_resolved)
	_piracy = p
	if _piracy != null:
		_piracy.raid_demanded.connect(_on_raid_demanded)
		_piracy.raid_resolved.connect(_on_raid_resolved)

## Transit is a static rules library with no events of its own, so whatever
## dispatches a ship reports it here. kind is "departed" or "arrived".
func post_transit_event(kind: String, origin: String, destination: String, commodity: String, qty: int, rounds: int = 0) -> Dictionary:
	var route: String = "%s -> %s" % [StationMarket.station_name(origin).to_upper(), StationMarket.station_name(destination).to_upper()]
	var text: String
	if kind.to_lower() == "arrived":
		text = "FLEET ARRIVAL: %d %s docked at %s from %s" % [qty, commodity.to_upper(), StationMarket.station_name(destination).to_upper(), StationMarket.station_name(origin).to_upper()]
	else:
		text = "FLEET DEPARTURE: %d %s on %s" % [qty, commodity.to_upper(), route]
		if rounds > 0:
			text += ", ETA %d round%s" % [rounds, "" if rounds == 1 else "s"]
	return post_headline(text, "TRANSIT", "INFO")

func _on_hazard_recorded(rec: Dictionary) -> void:
	var lost: int = int(rec.get("lost_qty", 0))
	var delay: int = int(rec.get("delay", 0))
	var text: String = str(rec.get("note", "")).strip_edges()
	if str(rec.get("note", "")).strip_edges().is_empty():
		text = "transit %s delayed %d, lost %d" % [str(rec.get("transit_id", "?")), delay, lost]
	var com: String = str(rec.get("commodity", ""))
	if not com.is_empty():
		text += " (%s, transit %s)" % [com, str(rec.get("transit_id", "?"))]
	post_headline(text, "HAZARD", "WARNING" if lost > 0 else "INFO")

func _on_raid_demanded(d: Dictionary) -> void:
	var text: String = "ALERT: pirates demand %d CR ransom from %s, %s -> %s (%s)" % [
		int(d.get("ransom", 0)), str(d.get("agent_id", "?")), str(d.get("origin", "?")).to_upper(), str(d.get("destination", "?")).to_upper(), str(d.get("commodity", "")).to_upper()]
	post_headline(text, "PIRACY", "CRITICAL")

func _on_raid_resolved(row: Dictionary) -> void:
	var status: String = str(row.get("status", ""))
	var text: String
	match status:
		"paid":
			text = "%s paid %d CR ransom, cargo released" % [str(row.get("agent_id", "?")), int(row.get("cr_taken", 0))]
		"surrendered":
			text = "%s surrendered %d %s to the raiders" % [str(row.get("agent_id", "?")), int(row.get("qty_taken", 0)), str(row.get("commodity", "")).to_upper()]
		"escaped":
			text = "%s fought off the raiders and escaped" % str(row.get("agent_id", "?"))
		_:
			text = "%s lost %d %s after a failed fight" % [str(row.get("agent_id", "?")), int(row.get("qty_taken", 0)), str(row.get("commodity", "")).to_upper()]
	post_headline(text, "PIRACY", "WARNING" if status in ["lost", "surrendered"] else "INFO")

func _on_order_executed(o: Dictionary) -> void:
	var text: String = "FILL: %s %d %s @ %.1f at %s" % [str(o.get("side", "")), int(o.get("qty", 0)), str(o.get("commodity", "")), float(o.get("price", 0.0)), StationMarket.station_name(str(o.get("station", active_station))).to_upper()]
	post_headline(text, "MARKET", "INFO")

func _book_mid(station: String, commodity: String) -> float:
	if market == null or not market.has_book(station, commodity):
		return 0.0
	return float(market.ladder(station, commodity, 1).get("mid_price", 0.0))

func _on_book_changed(station: String, commodity: String) -> void:
	var key: String = StationMarket.book_key(station, commodity)
	var mid: float = _book_mid(station, commodity)
	var prev: float = float(_last_mid.get(key, 0.0))
	_last_mid[key] = mid
	if prev <= 0.0 or mid <= 0.0:
		return
	var change: float = (mid - prev) / prev
	if absf(change) < MARKET_MOVE_THRESHOLD:
		return
	post_headline("MOVE: %s %s %s %.1f%% to %.1f at %s" % [commodity.to_upper(), "firms" if change > 0.0 else "eases", "up" if change > 0.0 else "down", absf(change) * 100.0, mid, StationMarket.station_name(station).to_upper()], "MARKET", "INFO")

# --- Ticker marquee (headless-safe: pure state, no nodes) ---

## Advances every visible ticker line's marquee clock by a frame delta.
func advance_ticker(delta: float) -> void:
	for item in get_recent_headlines(TICKER_VISIBLE_LINES):
		var seq: int = int(item["seq"])
		_ticker_clock[seq] = float(_ticker_clock.get(seq, 0.0)) + maxf(0.0, delta)

## Pixel width of a ticker line, using measure when valid.
## Optional measure is Callable(text) -> pixel width; the default estimates from
## character count so the model works without a font (headless).
func ticker_text_width(text: String, measure: Callable = Callable()) -> float:
	if measure.is_valid():
		return float(measure.call(text))
	return float(text.length()) * TICKER_FALLBACK_CHAR_WIDTH

## Horizontal marquee offset in px for a clock reading: dwell, scroll to the
## end of the line, dwell, then restart. Lines that fit never scroll.
static func marquee_offset(clock: float, text_width: float, view_width: float) -> float:
	var travel: float = text_width - view_width + TICKER_SCROLL_GAP
	if travel <= 0.0 or text_width <= view_width:
		return 0.0
	var scroll_time: float = travel / TICKER_SCROLL_SPEED
	var cycle: float = TICKER_DWELL_SECONDS * 2.0 + scroll_time
	var t: float = fposmod(clock, cycle) - TICKER_DWELL_SECONDS
	return clampf(t, 0.0, scroll_time) * TICKER_SCROLL_SPEED

## Newest ticker lines with their current scroll offsets, newest first.
func get_ticker_lines(measure: Callable = Callable(), view_width: float = TICKER_VIEW_WIDTH) -> Array:
	var out: Array = []
	for item in get_recent_headlines(TICKER_VISIBLE_LINES):
		var text: String = "%s: %s" % [item["category"], item["text"]]
		var w: float = ticker_text_width(text, measure)
		out.append({
			"text": text,
			"severity": item["severity"],
			"width": w,
			"overflow": w > view_width,
			"offset": marquee_offset(float(_ticker_clock.get(int(item["seq"]), 0.0)), w, view_width)
		})
	return out

# --- Controller Signal Callbacks ---

func _on_controller_round_advanced(r: int) -> void:
	if r % 4 == 0:
		post_headline("QUARTERLY REFINANCING: Central bank debt tranche rolled at current interest rate.", "DEBT", "INFO")
	if tactile_audio != null:
		tactile_audio.play_sfx(TactileAudio.MARKET_BELL)

func _on_controller_bankruptcy_pending(assessment: Dictionary) -> void:
	var shortfall: int = int(assessment.get("shortfall", 0))
	var total_debt: int = int(assessment.get("total_debt", 0))
	var alert_msg: String = "CHAPTER 11 WARNING: Insolvent (Shortfall: %d CR, Total Debt: %d CR)" % [shortfall, total_debt]
	post_headline(alert_msg, "INSOLVENCY", "CRITICAL")
	emergency_alert.emit(alert_msg)

func _on_controller_stage_changed(_old_stage: int, new_stage: int) -> void:
	var st_name: String = _stage_to_name(new_stage)
	post_headline("SOL EMERGENCY LEVEL ESCALATION: Run stage advanced to %s" % st_name, "SECURITY", "WARNING")
	if tactile_audio != null:
		tactile_audio.update_doomsday_stage(new_stage)

func _on_controller_collapsed() -> void:
	post_headline("SOVEREIGN DEFAULT: Sol System asset seizure initiated. Run collapsed.", "COLLAPSE", "CRITICAL")
	emergency_alert.emit("COLLAPSE")

func _on_sim_clock_paused(_paused: bool) -> void:
	pass

func _on_sim_clock_speed(_mult: int) -> void:
	pass

# --- Helper Normalization ---

func _stage_to_name(st: int) -> String:
	match st:
		DoomsdayClock.Stage.NORMAL:
			return "NORMAL"
		DoomsdayClock.Stage.UNSTABLE:
			return "UNSTABLE"
		DoomsdayClock.Stage.CRITICAL:
			return "CRITICAL"
		DoomsdayClock.Stage.IMMINENT:
			return "IMMINENT"
		DoomsdayClock.Stage.COLLAPSED:
			return "COLLAPSED"
	return "NORMAL"

func _normalize_commodity(c: String) -> String:
	var up: String = c.to_upper().strip_edges()
	if up == "BANANAS":
		return "FRAG"
	var norm: String = Transit.normalize_commodity(up)
	if Transit.COMMODITIES.has(norm):
		return norm
	return ""

# --- Gamepad Controller Action Delegation ---

func handle_gamepad_action(action: String) -> bool:
	if gamepad_focus != null:
		return gamepad_focus.handle_action(action)
	return false

# --- JSON Snapshot Serialization ---

func to_dict() -> Dictionary:
	return {
		"viewport": [VIEWPORT_WIDTH, VIEWPORT_HEIGHT],
		"panels": {
			"header_rect": [HEADER_RECT.position.x, HEADER_RECT.position.y, HEADER_RECT.size.x, HEADER_RECT.size.y],
			"tactical_map_rect": [TACTICAL_MAP_RECT.position.x, TACTICAL_MAP_RECT.position.y, TACTICAL_MAP_RECT.size.x, TACTICAL_MAP_RECT.size.y],
			"sidebar_rect": [SIDEBAR_RECT.position.x, SIDEBAR_RECT.position.y, SIDEBAR_RECT.size.x, SIDEBAR_RECT.size.y],
			"ticker_rect": [TICKER_RECT.position.x, TICKER_RECT.position.y, TICKER_RECT.size.x, TICKER_RECT.size.y],
			"modal_overlay_rect": [MODAL_OVERLAY_RECT.position.x, MODAL_OVERLAY_RECT.position.y, MODAL_OVERLAY_RECT.size.x, MODAL_OVERLAY_RECT.size.y]
		},
		"header": get_header_telemetry(),
		"sidebar": get_sidebar_telemetry(),
		"active_station": active_station,
		"active_commodity": active_commodity,
		"is_trading_overlay_open": is_trading_overlay_open(),
		"headlines_count": galnet_headlines.size(),
		"tactical_map": tactical_map.to_dict() if tactical_map != null else {},
		"trading_overlay": trading_overlay.to_dict() if trading_overlay != null else {},
		"gamepad_focus": gamepad_focus.to_dict() if gamepad_focus != null else {},
		"vector_orrery": vector_orrery.to_dict() if vector_orrery != null else {},
		"crt_preset": vector_orrery.current_preset if vector_orrery != null else "",
		"tactile_audio": tactile_audio.to_dict() if tactile_audio != null else {}
	}
