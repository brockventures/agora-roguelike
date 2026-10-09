class_name TradingOverlay
extends RefCounted
## Floating Bloomberg-Style Trading Terminal Overlay for Agora Roguelike (#21).
##
## Acts as a modal / summonable HUD overlay that renders on top of the SolTacticalMap.
## Binds to RunController (#10, PR 2) for financial state, Doomsday countdown,
## commodity prices, and bankruptcy interrupts.

signal overlay_opened(station_id: String)
signal overlay_closed()
signal station_changed(new_station: String)
signal commodity_selected(commodity: String)

const DEFAULT_OVERLAY_SIZE: Vector2 = Vector2(880.0, 560.0)

var controller: RunController = null
var is_visible: bool = false
var active_station: String = "earth"
var selected_commodity: String = "FRAG"

func _init(p_controller: RunController = null, p_default_station: String = "earth") -> void:
	active_station = p_default_station if p_default_station in Transit.STATIONS else "earth"
	if p_controller != null:
		bind_controller(p_controller)

func bind_controller(rc: RunController) -> void:
	controller = rc

func unbind_controller() -> void:
	controller = null

## Opens the trading overlay for the specified station.
func open_overlay(station_id: String = "") -> bool:
	if not station_id.is_empty():
		var s := station_id.to_lower().strip_edges()
		if s in Transit.STATIONS:
			active_station = s
	is_visible = true
	overlay_opened.emit(active_station)
	return true

## Closes the trading overlay.
func close_overlay() -> void:
	if is_visible:
		is_visible = false
		overlay_closed.emit()

## Toggles the trading overlay on/off.
func toggle_overlay(station_id: String = "") -> bool:
	if is_visible:
		close_overlay()
		return false
	else:
		return open_overlay(station_id)

## Changes active station tab.
func set_station(station_id: String) -> bool:
	var s := station_id.to_lower().strip_edges()
	if not (s in Transit.STATIONS):
		return false
	if active_station != s:
		active_station = s
		station_changed.emit(active_station)
	return true

## Changes selected commodity tab.
func set_commodity(commodity: String) -> bool:
	var canon := Transit.normalize_commodity(commodity)
	if not (canon in Transit.COMMODITIES):
		return false
	selected_commodity = canon
	commodity_selected.emit(selected_commodity)
	return true

## Formats real-time financial telemetry from RunController.
func get_financial_summary() -> Dictionary:
	if controller == null:
		return {
			"cr": 0,
			"principal_debt": 0,
			"accrued_interest": 0,
			"total_debt": 0,
			"ticks_remaining": 0,
			"stage": 0,
			"stage_name": "UNKNOWN",
			"pending_bankruptcy": false,
			"is_collapsed": false,
		}

	var d := controller.doomsday
	var stage_idx: int = d.stage if d != null else 0
	var stage_name: String = "NORMAL"
	if d != null:
		match d.stage:
			DoomsdayClock.Stage.NORMAL: stage_name = "NORMAL"
			DoomsdayClock.Stage.UNSTABLE: stage_name = "UNSTABLE"
			DoomsdayClock.Stage.CRITICAL: stage_name = "CRITICAL"
			DoomsdayClock.Stage.IMMINENT: stage_name = "IMMINENT"
			DoomsdayClock.Stage.COLLAPSED: stage_name = "COLLAPSED"

	return {
		"cr": controller.cr,
		"principal_debt": d.principal_debt if d != null else 0,
		"accrued_interest": d.accrued_interest if d != null else 0,
		"total_debt": d.get_total_debt() if d != null else 0,
		"ticks_remaining": d.ticks_remaining if d != null else 0,
		"stage": stage_idx,
		"stage_name": stage_name,
		"pending_bankruptcy": controller.pending_bankruptcy,
		"is_collapsed": controller.is_collapsed(),
	}

## Returns equilibrium base price for the active station and commodity.
func get_active_market_quote() -> Dictionary:
	var prices: Dictionary = Transit.BASE_PRICES.get(active_station, {})
	var base_px: float = float(prices.get(selected_commodity, 0.0))
	var is_perish: bool = Transit.is_perishable(selected_commodity)
	return {
		"station": active_station,
		"commodity": selected_commodity,
		"base_price_cr": base_px,
		"is_perishable": is_perish,
	}

## Returns player inventory cargo for the active commodity.
func get_cargo_hold_qty() -> int:
	if controller == null:
		return 0
	return int(controller.cargo.get(selected_commodity, 0))

## Serializes overlay state.
func to_dict() -> Dictionary:
	return {
		"is_visible": is_visible,
		"active_station": active_station,
		"selected_commodity": selected_commodity,
		"financials": get_financial_summary(),
		"market_quote": get_active_market_quote(),
		"cargo_qty": get_cargo_hold_qty(),
	}
