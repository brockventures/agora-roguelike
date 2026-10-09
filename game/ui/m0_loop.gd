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
##      d-pad / left stick: up/down the ladder (crossing the spread flips
##      BUY/SELL), left/right quantity, A submit, B back, X Chapter 11, Y speed cycle,
##      Start pause.
##  - Insolvency halts the clock and raises the Chapter 11 resolution overlay;
##    X files, which founds a new corp and lowers the overlay.
##  - Button presses click, order fills ring the market bell.

signal tab_changed(tab_name: String)
signal overlay_changed(overlay_state: String)
signal speed_changed(label: String)
signal action_handled(action: String)
## Collapse flow moved on: "" (none), "summary" or "perks".
signal collapse_phase_changed(phase: String)
## A fresh run replaced the collapsed one (rc is the new controller).
signal run_restarted(rc: RunController)

enum Tab { MAP = 0, MARKET = 1, FLEET = 2 }

const TAB_NAMES: Array[String] = ["MAP", "MARKET", "FLEET"]

## Resolution overlay states.
const OVERLAY_NONE: String = ""
const OVERLAY_CHAPTER_11: String = "chapter11"
const OVERLAY_COLLAPSED: String = "collapsed"
## A drawn crisis (#12): halts the clock until A acknowledges. Chapter 11 and
## collapse outrank it.
const OVERLAY_CRISIS: String = "crisis"

## Collapse flow: run summary, then Golden Parachutes perk select, then a new run.
const PHASE_NONE: String = ""
const PHASE_SUMMARY: String = "summary"
const PHASE_PERKS: String = "perks"

## The one tradable station in M0: Arcadia Foundries on Mars (#34). Other
## stations stay visible on the map, but LT/RT station cycling is disabled
## while a station is locked, so no path leads to a "Not docked" rejection.
const M0_STATION: String = "mars"

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
## Non-empty: the player is docked here and station cycling is disabled (see M0_STATION).
var locked_station: String = ""
var collapse_phase: String = PHASE_NONE
## Cursor over perk_rows(); index perk_rows().size() is the START NEW RUN row.
var perk_cursor: int = 0
var parachutes: Parachutes = null
## The run's crisis deck (#12); lives on the controller, wired to the market here.
var crisis_deck: CrisisDeck = null

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
	_attach_crisis_deck()
	_sync_overlay_from_controller()
	if locked_station != "":
		_apply_lock()


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
		controller.margin_call_applied.connect(_on_margin_call)
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
		if controller.margin_call_applied.is_connected(_on_margin_call):
			controller.margin_call_applied.disconnect(_on_margin_call)
		if controller.sim_clock.paused_changed.is_connected(_on_clock_changed):
			controller.sim_clock.paused_changed.disconnect(_on_clock_changed)
		if controller.sim_clock.speed_changed.is_connected(_on_clock_changed):
			controller.sim_clock.speed_changed.disconnect(_on_clock_changed)
	if hud != null and hud.gamepad_focus != null and _fill_callable.is_valid():
		if hud.gamepad_focus.order_executed.is_connected(_fill_callable):
			hud.gamepad_focus.order_executed.disconnect(_fill_callable)
		if hud.gamepad_focus.order_rejected.is_connected(_reject_callable):
			hud.gamepad_focus.order_rejected.disconnect(_reject_callable)
	if crisis_deck != null:
		if crisis_deck.crisis_drawn.is_connected(_on_crisis_drawn):
			crisis_deck.crisis_drawn.disconnect(_on_crisis_drawn)
		if crisis_deck.changed.is_connected(_on_crisis_changed):
			crisis_deck.changed.disconnect(_on_crisis_changed)
		crisis_deck = null
	controller = null


# --- Crisis deck (#12) ---

## Gives the controller a crisis deck (once) and wires it to the market, ticker
## and overlay. Re-binding the same controller keeps its deck.
func _attach_crisis_deck() -> void:
	if controller == null:
		return
	if controller.crisis_deck == null:
		controller.crisis_deck = CrisisDeck.new(controller.run_seed)
	crisis_deck = controller.crisis_deck
	crisis_deck.crisis_drawn.connect(_on_crisis_drawn)
	crisis_deck.changed.connect(_on_crisis_changed)
	hud.bind_crisis_deck(crisis_deck)
	market.set_crisis_mods(crisis_deck.market_mods())


func _on_crisis_changed() -> void:
	if market != null and crisis_deck != null:
		market.set_crisis_mods(crisis_deck.market_mods())


func _on_crisis_drawn(_crisis: Dictionary) -> void:
	_raise_crisis_if_pending()


## Raises the crisis modal and halts the clock when a crisis awaits
## acknowledgement and nothing outranks it. Otherwise it stays pending and is
## raised once the higher overlay is resolved.
func _raise_crisis_if_pending() -> void:
	if crisis_deck == null or controller == null or not crisis_deck.has_pending_ack():
		return
	if overlay_state != OVERLAY_NONE:
		return
	controller.sim_clock.pause()
	_set_overlay(OVERLAY_CRISIS)


## The crisis awaiting acknowledgement ({} when none).
func current_crisis() -> Dictionary:
	return crisis_deck.pending_crisis() if crisis_deck != null else {}


## A: acknowledge the crisis; the clock resumes at its prior speed.
func acknowledge_crisis() -> bool:
	if overlay_state != OVERLAY_CRISIS or crisis_deck == null:
		return false
	crisis_deck.acknowledge()
	_set_overlay(OVERLAY_NONE)
	controller.sim_clock.resume()
	return true


func _on_margin_call(amount: int) -> void:
	if hud != null:
		hud.post_headline("MARGIN CALL: %d CR drained from your account" % amount, "CRISIS", "WARNING")


# --- Station lock ---

## Docks the player at `station` and disables LT/RT station cycling.
func lock_station(station: String) -> void:
	locked_station = station.to_lower()
	_apply_lock()


func _apply_lock() -> void:
	if controller != null and Transit.STATIONS.has(locked_station):
		controller.docked_at = locked_station
	if hud != null and locked_station != "":
		hud.set_station(locked_station)


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
	if overlay_state == OVERLAY_COLLAPSED:
		return _collapsed_action(action)
	if overlay_state == OVERLAY_CRISIS and action != ACT_CHAPTER_11:
		# A acknowledges; nothing else is live behind the modal.
		var acked: bool = action == ACT_SUBMIT and acknowledge_crisis()
		if acked:
			_click()
			action_handled.emit(action)
		return acked
	if locked_station != "" and (action == ACT_STATION_PREV or action == ACT_STATION_NEXT):
		return false
	if overlay_state != OVERLAY_NONE and not OVERLAY_ACTIONS.has(action):
		return false
	if MARKET_ONLY_ACTIONS.has(action) and tab != Tab.MARKET:
		return false
	var handled: bool = false
	var heard_before: int = hud.tactile_audio.sounds_played_count if hud.tactile_audio != null else 0
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
		# One sound per press: the click is the fallback for actions whose own
		# feedback (tick, swoosh, modal, bell) did not already play.
		var heard_now: int = hud.tactile_audio.sounds_played_count if hud.tactile_audio != null else 0
		if heard_now == heard_before:
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


# --- Collapse: run summary, Golden Parachutes, restart ---

## Run-end numbers for the summary screen, from what RunController already tracks.
func run_summary() -> Dictionary:
	if controller == null:
		return {}
	return {
		"reason": controller.end_reason,
		"net_worth": controller.net_worth(),
		"peak_net_worth": controller.peak_net_worth,
		"rounds_survived": controller.get_current_round(),
		"corp_number": controller.corp_number,
		"severance_awarded": controller.severance_award,
		"severance_balance": controller.profile.severance_points,
		"runs_completed": controller.profile.runs_completed,
	}


## Golden Parachutes rows (enabled perks by tier then id) with live buy state
## from Parachutes.can_buy (requires, requires_any, cost).
func perk_rows() -> Array:
	var rows: Array = []
	if controller == null:
		return rows
	if parachutes == null:
		parachutes = Parachutes.load()
	for id in parachutes.perks:
		var perk: Dictionary = parachutes.perks[id]
		if not bool(perk["enabled"]):
			continue
		var check: Dictionary = parachutes.can_buy(controller.profile, str(id))
		rows.append({
			"id": str(id),
			"name": str(perk["name"]),
			"branch": str(perk["branch"]),
			"tier": int(perk["tier"]),
			"cost": int(perk["cost"]),
			"owned": controller.profile.has_unlock(str(id)),
			"can_buy": bool(check["ok"]),
		})
	rows.sort_custom(func(a, b): return [a["tier"], a["id"]] < [b["tier"], b["id"]])
	return rows


func _set_phase(phase: String) -> void:
	if collapse_phase != phase:
		collapse_phase = phase
		collapse_phase_changed.emit(phase)


## Collapse overlay input. A advances summary -> perk select -> new run; in perk
## select up/down move the cursor and A on a perk buys it. Something is always
## accepted (A), so the screen can never soft-lock.
func _collapsed_action(action: String) -> bool:
	if controller == null:
		return false
	if collapse_phase == PHASE_NONE:
		_set_phase(PHASE_SUMMARY)
	if collapse_phase == PHASE_SUMMARY:
		if action != ACT_SUBMIT:
			return false
		_open_perk_select()
		return true
	var rows: Array = perk_rows()
	match action:
		ACT_UP:
			perk_cursor = maxi(0, perk_cursor - 1)
			return true
		ACT_DOWN:
			perk_cursor = mini(rows.size(), perk_cursor + 1)
			return true
		ACT_SUBMIT:
			if perk_cursor >= rows.size():
				start_next_run()
				return true
			var res: Dictionary = parachutes.buy(controller.profile, str(rows[perk_cursor]["id"]))
			return bool(res["ok"])
		ACT_CANCEL:
			_set_phase(PHASE_SUMMARY)
			return true
	return false


func _open_perk_select() -> void:
	var rows: Array = perk_rows()
	perk_cursor = rows.size()
	for i in rows.size():
		if bool(rows[i]["can_buy"]):
			perk_cursor = i
			break
	_set_phase(PHASE_PERKS)


## Starts a fresh run from the collapsed one: same profile (so the perks bought
## above become RunController modifiers), new seed, fresh books, docked at the
## M0 station. Returns the new controller.
func start_next_run() -> RunController:
	if controller == null or hud == null:
		return null
	var rc: RunController = controller.next_run()
	hud.bind_controller(rc)
	market = StationMarket.new()
	tab = Tab.MAP
	hud.close_trading_overlay()
	hud.gamepad_focus.set_zone(GamepadFocus.Zone.TACTICAL_MAP)
	hud.gamepad_focus.last_executed_order = {}
	hud.gamepad_focus.last_rejection_reason = ""
	hud.gamepad_focus.last_rejection_payload = {}
	total_fills = 0
	bind_hud(hud)
	collapse_phase = PHASE_NONE
	perk_cursor = 0
	collapse_phase_changed.emit(PHASE_NONE)
	run_restarted.emit(rc)
	tab_changed.emit(tab_name())
	return rc


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
	_raise_crisis_if_pending()


func _on_collapsed() -> void:
	controller.sim_clock.pause()
	_set_phase(PHASE_SUMMARY)
	_set_overlay(OVERLAY_COLLAPSED)


func _on_round_advanced(_round_num: int) -> void:
	market.replenish()


func _on_clock_changed(_value: Variant) -> void:
	speed_changed.emit(speed_label())


func _sync_overlay_from_controller() -> void:
	if controller == null:
		_set_overlay(OVERLAY_NONE)
	elif controller.is_collapsed():
		_set_phase(PHASE_SUMMARY)
		_set_overlay(OVERLAY_COLLAPSED)
	elif controller.pending_bankruptcy:
		_set_overlay(OVERLAY_CHAPTER_11)
	else:
		_set_overlay(OVERLAY_NONE)
		_raise_crisis_if_pending()


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
