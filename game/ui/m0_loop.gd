class_name M0Loop
extends RefCounted
## M0 game loop model (#84): ties RunController, OrbitalHUD, GamepadFocus and
## TactileAudio into one playable single-station trading loop.
##
## Presentation-free so it is testable headless; MainScene owns one and feeds it
## frame deltas and InputEvents.
##
##  - advance(delta) steps the SimClock at the selected speed (pause stops it).
##  - handle_input(event) / dispatch_action(action) map the m0_* InputMap actions
##    (declared in project.godot with joypad and keyboard bindings) onto the
##    existing GamepadFocus API:
##      LB/RB tabs (Map, Market, Fleet), LT/RT stations, right stick commodities,
##      d-pad / left stick focus, A submit, B back, X Chapter 11, Y speed cycle,
##      Start pause.
##  - Insolvency halts the clock and raises the Chapter 11 resolution overlay;
##    X files, which founds a new corp and lowers the overlay.
##  - Button presses click, order fills ring the market bell.

signal tab_changed(tab_name: String)
signal overlay_changed(overlay_state: String)
signal speed_changed(label: String)
signal action_handled(action: String)

enum Tab { MAP = 0, MARKET = 1, FLEET = 2 }

const TAB_NAMES: Array[String] = ["MAP", "MARKET", "FLEET"]

## Resolution overlay states.
const OVERLAY_NONE: String = ""
const OVERLAY_CHAPTER_11: String = "chapter11"
const OVERLAY_COLLAPSED: String = "collapsed"

const ACT_TAB_PREV: String = "m0_tab_prev"
const ACT_TAB_NEXT: String = "m0_tab_next"
const ACT_STATION_PREV: String = "m0_station_prev"
const ACT_STATION_NEXT: String = "m0_station_next"
const ACT_COMMODITY_PREV: String = "m0_commodity_prev"
const ACT_COMMODITY_NEXT: String = "m0_commodity_next"
const ACT_UP: String = "m0_up"
const ACT_DOWN: String = "m0_down"
const ACT_LEFT: String = "m0_left"
const ACT_RIGHT: String = "m0_right"
const ACT_SUBMIT: String = "m0_submit"
const ACT_CANCEL: String = "m0_cancel"
const ACT_CHAPTER_11: String = "m0_chapter11"
const ACT_SPEED: String = "m0_speed"
const ACT_PAUSE: String = "m0_pause"

const ALL_ACTIONS: Array[String] = [
	ACT_TAB_PREV, ACT_TAB_NEXT, ACT_STATION_PREV, ACT_STATION_NEXT,
	ACT_COMMODITY_PREV, ACT_COMMODITY_NEXT, ACT_UP, ACT_DOWN, ACT_LEFT, ACT_RIGHT,
	ACT_SUBMIT, ACT_CANCEL, ACT_CHAPTER_11, ACT_SPEED, ACT_PAUSE,
]

## Actions that stay live while a resolution overlay is up.
const OVERLAY_ACTIONS: Array[String] = [ACT_CHAPTER_11]

## Action -> GamepadFocus.handle_action() string, for the pure delegations.
const FOCUS_ACTIONS: Dictionary = {
	ACT_STATION_PREV: "station_prev",
	ACT_STATION_NEXT: "station_next",
	ACT_COMMODITY_PREV: "commodity_prev",
	ACT_COMMODITY_NEXT: "commodity_next",
	ACT_UP: "dpad_up",
	ACT_DOWN: "dpad_down",
	ACT_LEFT: "dpad_left",
	ACT_RIGHT: "dpad_right",
	ACT_SUBMIT: "button_a",
}

## Actions only meaningful on the Market tab (order entry focus).
const MARKET_ONLY_ACTIONS: Array[String] = [
	ACT_COMMODITY_PREV, ACT_COMMODITY_NEXT, ACT_UP, ACT_DOWN, ACT_LEFT, ACT_RIGHT, ACT_SUBMIT,
]

var hud: OrbitalHUD = null
var controller: RunController = null
var market: StationMarket = null
var tab: Tab = Tab.MAP
var overlay_state: String = OVERLAY_NONE
var total_fills: int = 0

## Stick axes held past the deadzone, so a held stick fires once per push.
var _held: Dictionary = {}
var _fill_callable: Callable
var _reject_callable: Callable


func _init(p_hud: OrbitalHUD = null) -> void:
	if p_hud != null:
		bind_hud(p_hud)


func bind_hud(p_hud: OrbitalHUD) -> void:
	_disconnect_all()
	hud = p_hud
	controller = hud.controller if hud != null else null
	if hud == null:
		return
	if market == null:
		market = StationMarket.new()
	hud.market = market
	_connect_all()
	_sync_overlay_from_controller()


## Rebinds after the HUD's controller changed (MainScene.initialize_systems).
func rebind_controller() -> void:
	if hud != null:
		bind_hud(hud)


func _connect_all() -> void:
	if controller != null:
		controller.bankruptcy_pending.connect(_on_bankruptcy_pending)
		controller.bankruptcy_filed.connect(_on_bankruptcy_filed)
		controller.run_collapsed.connect(_on_collapsed)
		controller.round_advanced.connect(_on_round_advanced)
		controller.sim_clock.paused_changed.connect(_on_clock_changed)
		controller.sim_clock.speed_changed.connect(_on_clock_changed)
	if hud != null and hud.gamepad_focus != null:
		_fill_callable = Callable(self, "_on_order_executed")
		_reject_callable = Callable(self, "_on_order_rejected")
		if not hud.gamepad_focus.order_executed.is_connected(_fill_callable):
			hud.gamepad_focus.order_executed.connect(_fill_callable)
			hud.gamepad_focus.order_rejected.connect(_reject_callable)


func _disconnect_all() -> void:
	if controller != null:
		if controller.bankruptcy_pending.is_connected(_on_bankruptcy_pending):
			controller.bankruptcy_pending.disconnect(_on_bankruptcy_pending)
		if controller.bankruptcy_filed.is_connected(_on_bankruptcy_filed):
			controller.bankruptcy_filed.disconnect(_on_bankruptcy_filed)
		if controller.run_collapsed.is_connected(_on_collapsed):
			controller.run_collapsed.disconnect(_on_collapsed)
		if controller.round_advanced.is_connected(_on_round_advanced):
			controller.round_advanced.disconnect(_on_round_advanced)
		if controller.sim_clock.paused_changed.is_connected(_on_clock_changed):
			controller.sim_clock.paused_changed.disconnect(_on_clock_changed)
		if controller.sim_clock.speed_changed.is_connected(_on_clock_changed):
			controller.sim_clock.speed_changed.disconnect(_on_clock_changed)
	if hud != null and hud.gamepad_focus != null and _fill_callable.is_valid():
		if hud.gamepad_focus.order_executed.is_connected(_fill_callable):
			hud.gamepad_focus.order_executed.disconnect(_fill_callable)
		if hud.gamepad_focus.order_rejected.is_connected(_reject_callable):
			hud.gamepad_focus.order_rejected.disconnect(_reject_callable)
	controller = null


# --- Clock ---

## Steps the simulation by a real-time frame delta. Returns sub-ticks executed.
## Zero while paused, while the Chapter 11 overlay is up, or after collapse.
func advance(delta: float) -> int:
	if controller == null or overlay_state != OVERLAY_NONE:
		return 0
	return controller.advance(delta)


func speed_label() -> String:
	if controller == null:
		return OrbitalHUD.speed_label(false, 1)
	return OrbitalHUD.speed_label(controller.sim_clock.paused, controller.sim_clock.speed)


## Y: 1x -> 2x -> 5x -> PAUSED -> 1x. Returns the new label.
func cycle_speed() -> String:
	if controller == null or overlay_state != OVERLAY_NONE:
		return speed_label()
	var clock: SimClock = controller.sim_clock
	if clock.paused:
		clock.set_speed(1)
		clock.resume()
	elif clock.speed == 1:
		clock.set_speed(2)
	elif clock.speed == 2:
		clock.set_speed(5)
	else:
		clock.pause()
	return speed_label()


## Start: pause / resume at the current speed.
func toggle_pause() -> String:
	if controller == null or overlay_state != OVERLAY_NONE:
		return speed_label()
	controller.sim_clock.set_paused(not controller.sim_clock.paused)
	return speed_label()


# --- Tabs ---

func tab_name() -> String:
	return TAB_NAMES[int(tab)]


func set_tab(p_tab: Tab) -> void:
	if tab == p_tab:
		return
	tab = p_tab
	if hud != null:
		if tab == Tab.MARKET:
			hud.open_trading_overlay()
			hud.gamepad_focus.set_zone(GamepadFocus.Zone.ORDER_BOOK)
		else:
			hud.close_trading_overlay()
			hud.gamepad_focus.set_zone(GamepadFocus.Zone.TACTICAL_MAP)
	tab_changed.emit(tab_name())


func cycle_tab(direction: int) -> String:
	var count: int = TAB_NAMES.size()
	var idx: int = ((int(tab) + direction) % count + count) % count
	set_tab(idx as Tab)
	return tab_name()


# --- Chapter 11 ---

## X: files Chapter 11 when insolvent or pending. Returns the filing report, or
## {} when there is nothing to file.
func file_chapter_11() -> Dictionary:
	if controller == null:
		return {}
	return controller.file_bankruptcy()


# --- Input ---

## Routes a Godot InputEvent through the m0_* actions. Sticks fire once per push.
func handle_input(event: InputEvent) -> bool:
	var handled: bool = false
	for action in ALL_ACTIONS:
		if not event.is_action(action):
			continue
		if event is InputEventJoypadMotion:
			# is_action() ignores the stick direction, so check each action's
			# own pressed state and track held axes per action.
			if event.is_action_pressed(action):
				if not _held.get(action, false):
					_held[action] = true
					handled = dispatch_action(action) or handled
			else:
				_held[action] = false
		elif not event.is_echo() and event.is_action_pressed(action):
			return dispatch_action(action)
	return handled


## Applies one m0_* action. Returns true when it did something.
func dispatch_action(action: String) -> bool:
	if hud == null or not ALL_ACTIONS.has(action):
		return false
	if overlay_state != OVERLAY_NONE and not OVERLAY_ACTIONS.has(action):
		return false
	if MARKET_ONLY_ACTIONS.has(action) and tab != Tab.MARKET:
		return false
	var handled: bool = false
	match action:
		ACT_TAB_PREV:
			cycle_tab(-1)
			handled = true
		ACT_TAB_NEXT:
			cycle_tab(1)
			handled = true
		ACT_CANCEL:
			handled = _cancel()
		ACT_CHAPTER_11:
			handled = not file_chapter_11().is_empty()
		ACT_SPEED:
			cycle_speed()
			handled = controller != null
		ACT_PAUSE:
			toggle_pause()
			handled = controller != null
		_:
			handled = hud.gamepad_focus.handle_action(str(FOCUS_ACTIONS[action]))
	if handled:
		_click()
		action_handled.emit(action)
	return handled


## B: leave the Market tab for the Map; on any other tab, return focus to the map.
func _cancel() -> bool:
	if tab != Tab.MAP:
		set_tab(Tab.MAP)
		return true
	hud.gamepad_focus.set_zone(GamepadFocus.Zone.TACTICAL_MAP)
	return true


func _click() -> void:
	if hud != null and hud.tactile_audio != null:
		hud.tactile_audio.play_sfx(TactileAudio.KEY_CLICK_DOWN)


# --- Signal handlers ---

func _on_order_executed(_payload: Dictionary) -> void:
	total_fills += 1
	if hud != null and hud.tactile_audio != null:
		hud.tactile_audio.play_sfx(TactileAudio.MARKET_BELL)


func _on_order_rejected(_reason: String, _payload: Dictionary) -> void:
	if hud != null and hud.tactile_audio != null:
		hud.tactile_audio.play_sfx(TactileAudio.NAV_BUMP)


func _on_bankruptcy_pending(_assessment: Dictionary) -> void:
	# SimClock has already auto-paused via the interrupt hook; make it explicit.
	controller.sim_clock.pause()
	_set_overlay(OVERLAY_CHAPTER_11)


func _on_bankruptcy_filed(_report: Dictionary) -> void:
	_set_overlay(OVERLAY_NONE)
	# The controller leaves the clock paused for the caller; the new corp starts at 1x.
	controller.sim_clock.set_speed(1)
	controller.sim_clock.resume()


func _on_collapsed() -> void:
	controller.sim_clock.pause()
	_set_overlay(OVERLAY_COLLAPSED)


func _on_round_advanced(_round_num: int) -> void:
	market.replenish()


func _on_clock_changed(_value: Variant) -> void:
	speed_changed.emit(speed_label())


func _sync_overlay_from_controller() -> void:
	if controller == null:
		_set_overlay(OVERLAY_NONE)
	elif controller.is_collapsed():
		_set_overlay(OVERLAY_COLLAPSED)
	elif controller.pending_bankruptcy:
		_set_overlay(OVERLAY_CHAPTER_11)
	else:
		_set_overlay(OVERLAY_NONE)


func _set_overlay(state: String) -> void:
	if overlay_state != state:
		overlay_state = state
		overlay_changed.emit(overlay_state)


func to_dict() -> Dictionary:
	return {
		"tab": tab_name(),
		"overlay_state": overlay_state,
		"speed_label": speed_label(),
		"total_fills": total_fills,
		"has_controller": controller != null,
		"markets": market.books.keys() if market != null else [],
	}
