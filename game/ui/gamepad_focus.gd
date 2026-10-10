class_name GamepadFocus
extends RefCounted
## Steam Deck Gamepad Focus Graph and Controller Navigation Controller for Agora Roguelike (#22).
##
## Implements controller-first navigation across the 1280x800 Orbital Bloomberg Terminal:
## - Stations / commodities: cycled by actions "station_prev/next" and
##   "commodity_prev/next" (M0Loop maps LT/RT and the right stick onto them)
## - Up / Down: move one cursor across the visible ladder. Asks sit above the
##   spread, bids below; stepping past the best ask crosses to the best bid (and
##   back), so the BUY/SELL side follows the cursor.
## - Left / Right: decrease / increase order quantity, identically on both sides
## - Face Button A: Order execution (Buy/Sell on active ladder price with solvency & cargo validation)
## - Face Button B: Cancel / Close modal / return focus to tactical map
## - Face Button X: Toggle Trading Overlay modal
## - Face Button Y: Cycle Simulation Speed (1x -> 2x -> 5x)
## - Start / Select: Toggle Simulation Pause
##
## Takes semantic action strings only; raw InputEvents are routed by M0Loop through
## the m0_* InputMap actions (project.godot), which is the single binding table.

signal station_navigated(station: String)
signal commodity_navigated(commodity: String)
signal depth_level_snapped(index: int, side: String, price: float)
signal order_executed(order_payload: Dictionary)
signal order_rejected(reason: String, payload: Dictionary)
signal overlay_toggled(is_open: bool)
signal sim_speed_cycled(new_speed: int)
signal pause_toggled(is_paused: bool)
signal zone_changed(new_zone: int)
signal order_side_changed(new_side: String)
signal quantity_changed(new_qty: int)

enum Zone {
	TACTICAL_MAP = 0,
	ORDER_BOOK = 1,
	TRADING_OVERLAY = 2,
	SYSTEM_BAR = 3
}

enum OrderSide {
	BUY = 0,
	SELL = 1
}

const MAX_LADDER_DEPTH: int = 5
const DEFAULT_ORDER_QTY: int = 1
const MAX_ORDER_QTY: int = 999

var _hud_ref: WeakRef = null
var hud: OrbitalHUD:
	get:
		return _hud_ref.get_ref() as OrbitalHUD if _hud_ref != null else null
var current_zone: Zone = Zone.ORDER_BOOK
var active_side: OrderSide = OrderSide.BUY
var ladder_index: int = 0  ## 0 is top of book (best bid / best ask), 4 is deepest level
var order_qty: int = DEFAULT_ORDER_QTY
var last_executed_order: Dictionary = {}
var last_rejection_reason: String = ""
var last_rejection_payload: Dictionary = {}

func _init(p_hud: OrbitalHUD = null) -> void:
	if p_hud != null:
		bind_hud(p_hud)

func bind_hud(p_hud: OrbitalHUD) -> void:
	if p_hud != null:
		_hud_ref = weakref(p_hud)
	else:
		_hud_ref = null

func unbind_hud() -> void:
	_hud_ref = null

## Sets the current active focus zone.
func set_zone(p_zone: Zone) -> void:
	if current_zone != p_zone:
		current_zone = p_zone
		zone_changed.emit(int(current_zone))

## Sets order side (BUY or SELL).
func set_order_side(p_side: OrderSide) -> void:
	if active_side != p_side:
		active_side = p_side
		var side_str: String = "BUY" if active_side == OrderSide.BUY else "SELL"
		order_side_changed.emit(side_str)
		_emit_depth_snap()

## Toggles between BUY and SELL order sides.
func toggle_order_side() -> String:
	if active_side == OrderSide.BUY:
		set_order_side(OrderSide.SELL)
	else:
		set_order_side(OrderSide.BUY)
	return "BUY" if active_side == OrderSide.BUY else "SELL"

## Snaps D-pad selection to a specific depth level (0..4).
func snap_depth_level(index: int) -> int:
	ladder_index = clampi(index, 0, MAX_LADDER_DEPTH - 1)
	_emit_depth_snap()
	return ladder_index

## Steps D-pad up/down across depth levels.
func step_depth_level(delta: int) -> int:
	return snap_depth_level(ladder_index + delta)

## Moves the single ladder cursor one visible row. Direction -1 is up the screen,
## +1 down. Asks are drawn deepest-first above the spread (best ask nearest it) and
## bids best-first below, so up from the best bid crosses to the best ask (BUY) and
## down from the best ask crosses to the best bid (SELL); elsewhere it deepens or
## shallows the current side. Clamped at the deepest row on each end.
func step_ladder_cursor(direction: int) -> int:
	var visual: int = (MAX_LADDER_DEPTH - 1 - ladder_index) if active_side == OrderSide.BUY else (MAX_LADDER_DEPTH + ladder_index)
	visual = clampi(visual + direction, 0, 2 * MAX_LADDER_DEPTH - 1)
	var new_side: OrderSide = OrderSide.BUY if visual < MAX_LADDER_DEPTH else OrderSide.SELL
	ladder_index = (MAX_LADDER_DEPTH - 1 - visual) if new_side == OrderSide.BUY else (visual - MAX_LADDER_DEPTH)
	if new_side != active_side:
		active_side = new_side
		order_side_changed.emit("BUY" if active_side == OrderSide.BUY else "SELL")
	_emit_depth_snap()
	return ladder_index

## Adjusts order execution quantity with bounds clamping.
func adjust_quantity(delta: int) -> int:
	order_qty = clampi(order_qty + delta, 1, MAX_ORDER_QTY)
	quantity_changed.emit(order_qty)
	return order_qty

func set_quantity(qty: int) -> int:
	order_qty = clampi(qty, 1, MAX_ORDER_QTY)
	quantity_changed.emit(order_qty)
	return order_qty

## Gets the active price quote from the HUD's order book ladder based on active side and ladder index.
func get_focused_quote() -> Dictionary:
	if hud == null:
		return {"price": 0.0, "qty": 0, "side": "BUY", "index": 0}
	var side_dict: Dictionary = hud.get_sidebar_telemetry()
	var ladder: Dictionary = side_dict.get("order_book_ladder", {})
	var is_buy: bool = (active_side == OrderSide.BUY)
	## When buying, player buys against the ASKS ladder (offers to sell to player).
	## When selling, player sells against the BIDS ladder (offers to buy from player).
	var levels: Array = ladder.get("asks", []) if is_buy else ladder.get("bids", [])
	var px: float = 0.0
	var available_qty: int = 0
	if ladder_index >= 0 and ladder_index < levels.size():
		var lvl: Dictionary = levels[ladder_index]
		px = float(lvl.get("price", 0.0))
		available_qty = int(lvl.get("quantity", lvl.get("qty", 0)))
	return {
		"station": hud.active_station,
		"commodity": hud.active_commodity,
		"side": "BUY" if is_buy else "SELL",
		"index": ladder_index,
		"price": px,
		"available_qty": available_qty,
		"order_qty": order_qty,
		"total_cr": snappedf(px * float(order_qty), 0.01)
	}

## Executes an order based on current focused quote and side with full validation.
func execute_focused_order() -> Dictionary:
	if hud == null:
		last_rejection_reason = "NO_HUD_BOUND"
		var rej: Dictionary = {"ok": false, "reason": last_rejection_reason}
		_note_rejection(rej)
		return rej

	var is_buy: bool = (active_side == OrderSide.BUY)
	var station: String = hud.active_station
	var commodity: String = hud.active_commodity
	var rc: RunController = hud.controller

	# 0. In-transit gate (#111): a ship between stations trades nowhere.
	if rc != null and rc.is_in_transit():
		last_rejection_reason = "IN_TRANSIT"
		var rej_transit: Dictionary = {
			"ok": false,
			"reason": last_rejection_reason,
			"destination": str(rc.transit.get("destination", "")),
			"active_station": station,
			"commodity": commodity
		}
		_note_rejection(rej_transit)
		return rej_transit

	# 1. Docked Station Gate (Marvin Review Catch):
	# The player ship can only execute market trades at the station where it is currently docked.
	# Cycling HUD station tabs allows browsing other stations' order books read-only, but prevents
	# free cross-station arbitrage without physical transit.
	if rc != null and rc.docked_at != station:
		last_rejection_reason = "NOT_DOCKED_AT_STATION"
		var rej_dock: Dictionary = {
			"ok": false,
			"reason": last_rejection_reason,
			"docked_at": rc.docked_at,
			"active_station": station,
			"commodity": commodity
		}
		_note_rejection(rej_dock)
		return rej_dock

	var quote: Dictionary = get_focused_quote()
	var px: float = float(quote.get("price", 0.0))
	if px <= 0.0:
		last_rejection_reason = "INVALID_PRICE"
		var rej_px: Dictionary = {"ok": false, "reason": last_rejection_reason, "quote": quote}
		_note_rejection(rej_px)
		return rej_px

	# Antitrust audit (#12): unit cap per round while one is active. Cumulative
	# over the round (D5), so several small orders cannot add up past the cap.
	if rc != null and rc.trade_cap_qty() > 0 and order_qty > rc.audit_units_remaining():
		last_rejection_reason = "AUDIT_TRADE_CAP"
		var rej_audit: Dictionary = {"ok": false, "reason": last_rejection_reason, "order_qty": order_qty, "cap": rc.trade_cap_qty(), "remaining": rc.audit_units_remaining()}
		_note_rejection(rej_audit)
		return rej_audit

	# Live resting book (Earth/Mars): sweep it up to the focused level's price.
	var mkt: StationMarket = hud.market
	var use_book: bool = mkt != null and mkt.has_book(station, commodity)
	var side_str: String = "BUY" if is_buy else "SELL"
	var sweep: Dictionary = {}
	if use_book:
		sweep = mkt.sweep_quote(station, commodity, side_str, order_qty, px)
		if int(sweep["filled"]) < order_qty:
			last_rejection_reason = "INSUFFICIENT_LIQUIDITY"
			var rej_liq: Dictionary = {
				"ok": false,
				"reason": last_rejection_reason,
				"order_qty": order_qty,
				"available_qty": int(sweep["filled"]),
				"quote": quote
			}
			_note_rejection(rej_liq)
			return rej_liq

	# 2. Level Available Quantity Gate (Marvin Review Catch):
	# A single book depth level cannot fill more units than its resting liquidity.
	var avail_qty: int = int(quote.get("available_qty", 0))
	if not use_book and avail_qty > 0 and order_qty > avail_qty:
		last_rejection_reason = "EXCEEDS_AVAILABLE_QTY"
		var rej_qty: Dictionary = {
			"ok": false,
			"reason": last_rejection_reason,
			"order_qty": order_qty,
			"available_qty": avail_qty,
			"quote": quote
		}
		_note_rejection(rej_qty)
		return rej_qty

	var total_cost: int = int(sweep["cost"]) if use_book else int(round(px * float(order_qty)))

	# Antitrust fee (#12) on the swept notional; zero with no audit active.
	var fee: int = rc.trade_fee(total_cost) if rc != null else 0

	if rc != null:
		if is_buy:
			# 3. Solvency Gate: Player must have sufficient liquid CR (fee included)
			if rc.cr < total_cost + fee:
				last_rejection_reason = "INSUFFICIENT_CR"
				var rej_cr: Dictionary = {
					"ok": false,
					"reason": last_rejection_reason,
					"cr": rc.cr,
					"required": total_cost + fee,
					"quote": quote
				}
				_note_rejection(rej_cr)
				return rej_cr

			# 4. Cargo Capacity Gate (Marvin Review Catch):
			# Purchasing cargo cannot exceed the vessel's physical hold capacity.
			var remaining_capacity: int = rc.get_remaining_cargo_capacity()
			if order_qty > remaining_capacity:
				last_rejection_reason = "INSUFFICIENT_CARGO_CAPACITY"
				var rej_cap: Dictionary = {
					"ok": false,
					"reason": last_rejection_reason,
					"remaining_capacity": remaining_capacity,
					"order_qty": order_qty,
					"cargo_capacity": rc.cargo_capacity,
					"total_cargo": rc.get_total_cargo()
				}
				_note_rejection(rej_cap)
				return rej_cap

			## Deduct CR and credit cargo
			rc.cr -= total_cost + fee
			var current_cargo: int = int(rc.cargo.get(commodity, 0))
			rc.cargo[commodity] = current_cargo + order_qty
		else:
			## SELL: Player must hold sufficient units of the commodity
			var current_cargo: int = int(rc.cargo.get(commodity, 0))
			if current_cargo < order_qty:
				last_rejection_reason = "INSUFFICIENT_CARGO"
				var rej_cargo: Dictionary = {
					"ok": false,
					"reason": last_rejection_reason,
					"held": current_cargo,
					"required": order_qty,
					"quote": quote
				}
				_note_rejection(rej_cargo)
				return rej_cargo
			## Deduct cargo and credit CR
			rc.cargo[commodity] = current_cargo - order_qty
			rc.cr += maxi(0, total_cost - fee)

	if rc != null:
		rc.record_audit_trade(order_qty)

	var counterparty: String = ""
	var counterparty_id: String = ""
	if use_book:
		# Gates passed: consume the resting liquidity the sweep priced.
		var fill: Dictionary = mkt.execute(station, commodity, side_str, order_qty, px)
		counterparty = str(fill.get("counterparty", ""))
		counterparty_id = str(fill.get("counterparty_id", ""))

	var result: Dictionary = {
		"ok": true,
		"station": station,
		"commodity": commodity,
		"side": "BUY" if is_buy else "SELL",
		"price": (float(total_cost) / float(order_qty)) if use_book else px,
		"limit_price": px,
		"counterparty": counterparty,
		"counterparty_id": counterparty_id,
		"qty": order_qty,
		"total_cr": total_cost,
		"fee": fee,
		"ladder_index": ladder_index,
		"cr_remaining": rc.cr if rc != null else 0,
		"cargo_remaining": int(rc.cargo.get(commodity, 0)) if rc != null else 0
	}
	last_executed_order = result
	last_rejection_reason = ""
	last_rejection_payload = {}
	order_executed.emit(result)
	return result

## Dispatches an action string (e.g. "lb", "rb", "lt", "rt", "dpad_up", "button_a", etc.).
func handle_action(action: String) -> bool:
	var act: String = action.to_lower().strip_edges()
	match act:
		"lb", "station_prev":
			if hud != null:
				var s: String = hud.cycle_station(-1)
				station_navigated.emit(s)
				_emit_depth_snap()
				return true
		"rb", "station_next":
			if hud != null:
				var s: String = hud.cycle_station(1)
				station_navigated.emit(s)
				_emit_depth_snap()
				return true
		"lt", "commodity_prev":
			if hud != null:
				var c: String = hud.cycle_commodity(-1)
				commodity_navigated.emit(c)
				_emit_depth_snap()
				return true
		"rt", "commodity_next":
			if hud != null:
				var c: String = hud.cycle_commodity(1)
				commodity_navigated.emit(c)
				_emit_depth_snap()
				return true
		"dpad_up", "up":
			step_ladder_cursor(-1)
			return true
		"dpad_down", "down":
			step_ladder_cursor(1)
			return true
		"dpad_left", "left":
			adjust_quantity(-1)
			return true
		"dpad_right", "right":
			adjust_quantity(1)
			return true
		"button_a", "confirm", "execute":
			var res: Dictionary = execute_focused_order()
			return bool(res.get("ok", false))
		"button_b", "cancel", "back":
			if hud != null and hud.is_trading_overlay_open():
				hud.close_trading_overlay()
				overlay_toggled.emit(false)
			else:
				set_zone(Zone.TACTICAL_MAP)
			return true
		"button_x", "overlay_toggle":
			if hud != null:
				var is_open: bool = hud.toggle_trading_overlay()
				set_zone(Zone.TRADING_OVERLAY if is_open else Zone.ORDER_BOOK)
				overlay_toggled.emit(is_open)
				return true
		"button_y", "cycle_speed":
			if hud != null:
				var sp: int = hud.cycle_sim_speed()
				sim_speed_cycled.emit(sp)
				return true
		"start", "menu", "pause":
			if hud != null:
				var paused: bool = hud.toggle_pause()
				pause_toggled.emit(paused)
				return true
		"select", "view":
			set_zone(Zone.SYSTEM_BAR)
			return true
		_:
			return false
	return false

## Records and emits a rejection; the payload keeps the context a message needs.
func _note_rejection(payload: Dictionary) -> void:
	last_rejection_payload = payload
	order_rejected.emit(last_rejection_reason, payload)

## Player-facing text for a rejection reason code. Pass the payload for context.
static func rejection_message(reason: String, payload: Dictionary = {}) -> String:
	match reason:
		"NOT_DOCKED_AT_STATION":
			var st: String = str(payload.get("active_station", ""))
			return Loc.t("REJ_NOT_DOCKED") % (Loc.station(st) if st != "" else Loc.t("REJ_THIS_STATION"))
		"IN_TRANSIT":
			var dest: String = str(payload.get("destination", ""))
			return Loc.t("REJ_IN_TRANSIT") % (Loc.station(dest) if dest != "" else Loc.t("REJ_THIS_STATION"))
		"INSUFFICIENT_CR":
			return Loc.t("REJ_INSUFFICIENT_CR")
		"INSUFFICIENT_CARGO":
			return Loc.t("REJ_INSUFFICIENT_CARGO")
		"INSUFFICIENT_CARGO_CAPACITY":
			return Loc.t("REJ_CARGO_FULL")
		"INSUFFICIENT_LIQUIDITY", "EXCEEDS_AVAILABLE_QTY":
			return Loc.t("REJ_NO_VOLUME")
		"AUDIT_TRADE_CAP":
			return Loc.t("REJ_AUDIT_CAP") % int(payload.get("cap", 0))
		"INVALID_PRICE":
			return Loc.t("REJ_NO_QUOTE")
		"NO_HUD_BOUND":
			return Loc.t("REJ_OFFLINE")
		_:
			return reason.capitalize()

## Readable text for the last rejection ("" when the last order filled).
func get_rejection_message() -> String:
	if last_rejection_reason == "":
		return ""
	return rejection_message(last_rejection_reason, last_rejection_payload)

func _emit_depth_snap() -> void:
	var q: Dictionary = get_focused_quote()
	var side_str: String = "BUY" if active_side == OrderSide.BUY else "SELL"
	var px: float = float(q.get("price", 0.0))
	depth_level_snapped.emit(ladder_index, side_str, px)

## Serializes focus state for save-state, telemetry, and assertions.
func to_dict() -> Dictionary:
	return {
		"current_zone": int(current_zone),
		"active_side": "BUY" if active_side == OrderSide.BUY else "SELL",
		"ladder_index": ladder_index,
		"order_qty": order_qty,
		"focused_quote": get_focused_quote(),
		"last_executed_order": last_executed_order,
		"last_rejection_reason": last_rejection_reason
	}
