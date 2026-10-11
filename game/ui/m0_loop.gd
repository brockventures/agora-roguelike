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
##      BUY/SELL), left/right quantity, A submit (on the Map tab: depart for the
##      selected station), B back, X Chapter 11, Y speed cycle, Start pause.
##      On the Fleet tab (no ladder shown) d-pad / left stick up/down walk the hull list.
##  - Travel (Epic 3 task 0, #111): LT/RT pick a destination, A on the Map tab
##    departs. The voyage lives on RunController (transit); arrival docks the
##    ship, seeds the new station's books and switches the HUD to them.
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
## A sim round completed and the books were refilled (the autosave point).
signal round_completed(round_num: int)
## The device woke from sleep (or the app was resumed): audio should be re-armed.
signal woke_from_sleep(source: String)

enum Tab { MAP = 0, MARKET = 1, FLEET = 2 }

const TAB_NAMES: Array[String] = ["MAP", "MARKET", "FLEET"]

## Resolution overlay states.
const OVERLAY_NONE: String = ""
const OVERLAY_CHAPTER_11: String = "chapter11"
const OVERLAY_COLLAPSED: String = "collapsed"
## A drawn crisis (#12): halts the clock until A acknowledges. Chapter 11 and
## collapse outrank it.
const OVERLAY_CRISIS: String = "crisis"
## A defense contract offer from Ares Heavy (Epic 3 task 4): halts the clock until
## A accepts or B declines. Chapter 11, collapse and a crisis outrank it.
const OVERLAY_CONTRACT: String = "contract"
## The player holds every baron (Epic 3 task 9, design doc 5.4): a summary state that
## halts the clock until A continues. Phase 1 of the win; the Sol System Rescue that
## finishes the run is #32 and is not built. Chapter 11, collapse and a crisis outrank it.
const OVERLAY_MONOPOLY: String = "monopoly"

## Collapse flow: run summary, then Golden Parachutes perk select, then a new run.
const PHASE_NONE: String = ""
const PHASE_SUMMARY: String = "summary"
const PHASE_PERKS: String = "perks"

## Where every run starts: docked at Arcadia Foundries on Mars (#34). Since #111
## the player can travel on from there; this is only the starting dock.
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
## Cycles the UI language (hot swap, #40). Live in every state, overlays included.
const ACT_LOCALE: String = "m0_locale"
## Buys the lot of shares the docked baron is auctioning in distress (Epic 3 task 7).
const ACT_SHARES: String = "m0_shares"
## Extends the standard credit line to the docked baron (Epic 3 task 8, lever c).
const ACT_CREDIT: String = "m0_credit"

const ALL_ACTIONS: Array[String] = [
	ACT_TAB_PREV, ACT_TAB_NEXT, ACT_STATION_PREV, ACT_STATION_NEXT,
	ACT_COMMODITY_PREV, ACT_COMMODITY_NEXT, ACT_UP, ACT_DOWN, ACT_LEFT, ACT_RIGHT,
	ACT_SUBMIT, ACT_CANCEL, ACT_CHAPTER_11, ACT_SPEED, ACT_PAUSE, ACT_LOCALE, ACT_SHARES, ACT_CREDIT,
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
## Where the gamepad focus was when the open modal went up ({} when no modal is open);
## closing the modal restores it (see _set_overlay).
var focus_trap: Dictionary = {}
## The barons held when the corp ended, for the summary's per-baron severance rows.
var _broken_ids: Array = []
## True while the sim is paused by a wake (banner text: key SLEEP_NOTICE); cleared when the player resumes.
const FOCUS_ANCHOR_PAUSE: String = "pause"
var sleep_pause_active: bool = false
## What controller input is anchored to after a wake: an overlay state or "pause".
var focus_anchor: String = ""
var wake_count: int = 0
var total_fills: int = 0
## Why the last A-to-depart press did nothing ("" when it worked); see depart_message().
var last_depart_reason: String = ""
## The last depart() result, for the fuel figures in a refusal message.
var last_depart_check: Dictionary = {}
var collapse_phase: String = PHASE_NONE
## Cursor over perk_rows(); index perk_rows().size() is the START NEW RUN row.
var perk_cursor: int = 0
## Cursor over controller.ships on the Fleet tab (Epic 6 #122). UI only: never saved.
var fleet_cursor: int = 0
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
	_attach_world()
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
		controller.margin_call_applied.connect(_on_margin_call)
		controller.transit_departed.connect(_on_transit_departed)
		controller.transit_arrived.connect(_on_transit_arrived)
		controller.sim_clock.paused_changed.connect(_on_clock_changed)
		controller.sim_clock.speed_changed.connect(_on_clock_changed)
	if hud != null and hud.gamepad_focus != null:
		_fill_callable = Callable(self, "_on_order_executed")
		_reject_callable = Callable(self, "_on_order_rejected")
		if not hud.gamepad_focus.order_executed.is_connected(_fill_callable):
			hud.gamepad_focus.order_executed.connect(_fill_callable)
			hud.gamepad_focus.order_rejected.connect(_reject_callable)
		if not hud.gamepad_focus.auction_queued.is_connected(_on_auction_queued):
			hud.gamepad_focus.auction_queued.connect(_on_auction_queued)


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
		if controller.transit_departed.is_connected(_on_transit_departed):
			controller.transit_departed.disconnect(_on_transit_departed)
		if controller.transit_arrived.is_connected(_on_transit_arrived):
			controller.transit_arrived.disconnect(_on_transit_arrived)
		if controller.sim_clock.paused_changed.is_connected(_on_clock_changed):
			controller.sim_clock.paused_changed.disconnect(_on_clock_changed)
		if controller.sim_clock.speed_changed.is_connected(_on_clock_changed):
			controller.sim_clock.speed_changed.disconnect(_on_clock_changed)
	if hud != null and hud.gamepad_focus != null and _fill_callable.is_valid():
		if hud.gamepad_focus.order_executed.is_connected(_fill_callable):
			hud.gamepad_focus.order_executed.disconnect(_fill_callable)
		if hud.gamepad_focus.order_rejected.is_connected(_reject_callable):
			hud.gamepad_focus.order_rejected.disconnect(_reject_callable)
		if hud.gamepad_focus.auction_queued.is_connected(_on_auction_queued):
			hud.gamepad_focus.auction_queued.disconnect(_on_auction_queued)
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


## Points the market at the controller's world (null = none, the M0 default of
## Ares Heavy everywhere). Only a controller that already carries a world gets
## baron-made books: a bare controller, as in Replay.Session, never does.
func _attach_world() -> void:
	if market == null or controller == null:
		return
	market.set_world(controller.world)
	market.set_world_mods(controller.world.market_mods() if controller.world != null else [])


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
	# A contract offer drawn the same round waits behind the crisis; the clock
	# stays halted for it.
	_raise_contract_if_pending()
	if overlay_state == OVERLAY_NONE:
		controller.sim_clock.resume()
	return true


# --- Baron contracts (Epic 3 task 4, Ares Heavy) ---

## Raises the offer modal and halts the clock when a defense contract awaits an
## answer and nothing outranks it.
func _raise_contract_if_pending() -> void:
	if controller == null or controller.world == null or not controller.world.has_pending_offer():
		return
	if overlay_state != OVERLAY_NONE:
		return
	controller.sim_clock.pause()
	_set_overlay(OVERLAY_CONTRACT)


## The offer awaiting an answer ({} when none).
func current_offer() -> Dictionary:
	return controller.world.pending_offer() if controller != null and controller.world != null else {}


## The accepted, unsettled contract ({} when none), for the HUD.
func open_contract() -> Dictionary:
	return controller.world.open_contract() if controller != null and controller.world != null else {}


## A: accept the offer. A ship already docked at the anchor with the stock is paid
## at once. The clock resumes.
func accept_contract() -> bool:
	if overlay_state != OVERLAY_CONTRACT or controller == null or controller.world == null:
		return false
	var ev: Dictionary = controller.world.accept_offer(controller)
	if ev.is_empty():
		return false
	_post_baron_event(ev)
	var done: Dictionary = controller.world.try_deliver(controller)
	if not done.is_empty():
		_post_baron_event(done)
	_refresh_world_mods()
	_set_overlay(OVERLAY_NONE)
	controller.sim_clock.resume()
	return true


## B: decline. Nothing is kept of a declined offer.
func decline_contract() -> bool:
	if overlay_state != OVERLAY_CONTRACT or controller == null or controller.world == null:
		return false
	var o: Dictionary = controller.world.pending_offer()
	if not controller.world.decline_offer():
		return false
	if hud != null and not o.is_empty():
		hud.post_headline_tr("HL_ARES_DECLINED", [Loc.maker_arg(str(o["baron"]))], "MARKET", "INFO")
	_set_overlay(OVERLAY_NONE)
	controller.sim_clock.resume()
	return true


func _refresh_world_mods() -> void:
	if market != null and controller != null and controller.world != null:
		market.set_world_mods(controller.world.market_mods())


## Turns a world event (Barons.advance_round / accept / deliver) into its GalNet line.
func _post_baron_event(e: Dictionary) -> void:
	_post_baron_headline(e)
	if str(e.get("kind", "")) == "takeover" and str(e.get("holder", "")) == Takeover.PLAYER:
		_raise_monopoly_if_any()


## Raises the monopoly summary the first time the player holds every baron, unless a
## filing is pending or the takeover itself tipped the corp insolvent (the filing
## would forfeit the lot, so there is nothing to celebrate yet).
func _raise_monopoly_if_any() -> void:
	if controller == null or overlay_state != OVERLAY_NONE or controller.pending_bankruptcy:
		return
	if not controller.has_monopoly() or bool(controller.assess()["insolvent"]):
		return
	if controller.check_monopoly():
		controller.sim_clock.pause()
		_set_overlay(OVERLAY_MONOPOLY)


## Numbers for the monopoly summary state.
func monopoly_summary() -> Dictionary:
	if controller == null or controller.world == null:
		return {}
	var held: int = controller.world.held_by(Takeover.PLAYER).size()
	return {
		"barons_held": held,
		"barons_total": controller.world.ids().size(),
		"net_worth": controller.net_worth(),
		"peak_net_worth": controller.peak_net_worth,
		"rounds": controller.get_current_round(),
		"corp_number": controller.corp_number,
		"severance_pending": held * Parachutes.SEVERANCE_PER_BARON,
	}


## A: carry on from the monopoly summary. The clock resumes.
func acknowledge_monopoly() -> bool:
	if overlay_state != OVERLAY_MONOPOLY or controller == null:
		return false
	_set_overlay(OVERLAY_NONE)
	_raise_crisis_if_pending()
	_raise_contract_if_pending()
	if overlay_state == OVERLAY_NONE:
		controller.sim_clock.resume()
	return true


func _post_baron_headline(e: Dictionary) -> void:
	if hud == null:
		return
	if str(e.get("kind", "")).begins_with("rival_"):
		_post_rival_headline(e)
		return
	var who: Dictionary = Loc.maker_arg(str(e.get("baron", "")))
	var com: Dictionary = Loc.commodity_arg(str(e.get("commodity", "")))
	match str(e.get("kind", "")):
		"offer":
			hud.post_headline_tr("HL_ARES_OFFER", [who, int(e["qty"]), com, Loc.station_arg(str(e["station"])), int(e["rounds"]), int(e["total"])], "MARKET", "WARNING")
		"accepted":
			hud.post_headline_tr("HL_ARES_ACCEPTED", [who, int(e["qty"]), com, int(e["due_round"])], "MARKET", "INFO")
		"delivered":
			hud.post_headline_tr("HL_ARES_DELIVERED", [who, int(e["qty"]), com, int(e["paid"])], "MARKET", "INFO")
		"squeeze":
			hud.post_headline_tr("HL_ARES_SQUEEZE", [who, Loc.station_arg(str(e["station"])), com, int(e["price_bps"]) / 100], "CRISIS", "WARNING")
		"heat_queued":
			hud.post_headline_tr("HL_HEAT_QUEUED", [who, int(e["heat"])], "CRISIS", "WARNING")
		"retaliation":
			# The deck already posted the event's own headline when it was injected; the
			# line here is only for the fine that the player's own choices made fatal.
			if bool(e.get("forced_ch11", false)):
				hud.post_headline_tr("HL_BARON_RETALIATION_CH11", [who], "INSOLVENCY", "CRITICAL")
		"hoard":
			hud.post_headline_tr("HL_TITAN_HOARD", [who, com, Loc.station_arg(str(e["station"]))], "MARKET", "INFO")
		"corner":
			hud.post_headline_tr("HL_TITAN_CORNER", [who, com, Loc.station_arg(str(e["station"])), int(e["price_bps"]) / 100], "CRISIS", "WARNING")
		"release":
			hud.post_headline_tr("HL_TITAN_RELEASE", [who, com, Loc.station_arg(str(e["station"])), -int(e["price_bps"]) / 100], "MARKET", "INFO")
		"spoil":
			hud.post_headline_tr("HL_TITAN_SPOIL", [who, int(e["qty"]), com], "MARKET", "INFO")
		"auction_open":
			hud.post_headline_tr("HL_SOL_OPEN", [who, com, Loc.station_arg(str(e["station"])), int(e["ref"]), int(e["close_round"])], "MARKET", "INFO")
		"auction_clear":
			hud.post_headline_tr("HL_SOL_CLEAR", [who, com, int(e["price"]), int(e["ref"]), int(e["qty"])], "MARKET", "INFO")
		"auction_lapse":
			if int(e["price"]) < 0:
				hud.post_headline_tr("HL_SOL_NOCROSS", [who, com, int(e["qty"])], "MARKET", "WARNING")
			else:
				hud.post_headline_tr("HL_SOL_LAPSE", [who, int(e["qty"]), com, int(e["price"])], "MARKET", "WARNING")
		"lever_corner":
			if int(e["round"]) == 1:
				hud.post_headline_tr("HL_CORNER", [who, com, int(e["from_stock"]), int(e["cost"])], "MARKET", "WARNING")
			if int(e["unpaid"]) > 0:
				hud.post_headline_tr("HL_CORNER_UNPAID", [who, int(e["unpaid"])], "INSOLVENCY", "WARNING")
		"lever_corner_end":
			hud.post_headline_tr("HL_CORNER_END", [who, com], "MARKET", "INFO")
		"lever_margin":
			hud.post_headline_tr("HL_LEVER_MARGIN", [who, int(e["units"]), int(e["proceeds"]), int(e["deficiency"])], "INSOLVENCY", "CRITICAL")
		"credit_open":
			hud.post_headline_tr("HL_CREDIT_OPEN", [who, int(e["principal"]), int(e["rate_bps"]) / 100, int(e["due"]), int(e["due_round"])], "DEBT", "INFO")
		"credit_repaid":
			hud.post_headline_tr("HL_CREDIT_REPAID", [who, int(e["due"])], "DEBT", "INFO")
		"credit_default":
			hud.post_headline_tr("HL_CREDIT_DEFAULT", [who, int(e["due"])], "INSOLVENCY", "WARNING")
		"distress":
			hud.post_headline_tr("HL_DISTRESS", [who, int(e["qty"]), int(e["px"]), int(e["cap"])], "INSOLVENCY", "WARNING")
		"auction":
			if bool(e.get("forced", false)):
				hud.post_headline_tr("HL_AUCTION_FORCED", [who, int(e["qty"]), int(e["px"])], "INSOLVENCY", "WARNING")
			else:
				hud.post_headline_tr("HL_AUCTION_CLEARED", [who, int(e["qty"]), int(e["px"]), int(e["reserve"])], "INSOLVENCY", "WARNING")
		"control_lost":
			hud.post_headline_tr("HL_CONTROL_LOST", [Loc.maker_arg(str(e.get("fleet", ""))), who], "INSOLVENCY", "WARNING")
		"shares":
			if str(e.get("buyer", "")) == Takeover.PLAYER and bool(e.get("tender", false)):
				hud.post_headline_tr("HL_TENDER_BOUGHT", [int(e["qty"]), who, int(e["px"]), int(e["held"]), int(e["threshold"])], "MARKET", "INFO")
			elif str(e.get("buyer", "")) == Takeover.PLAYER:
				hud.post_headline_tr("HL_SHARES_BOUGHT", [int(e["qty"]), who, int(e["px"]), int(e["held"]), int(e["threshold"])], "MARKET", "INFO")
			else:
				hud.post_headline_tr("HL_SHARES_SOLD", [who, int(e["qty"]), Loc.maker_arg(str(e.get("buyer", ""))), int(e["px"])], "MARKET", "INFO")
		"takeover":
			if str(e.get("holder", "")) == Takeover.PLAYER:
				hud.post_headline_tr("HL_TAKEOVER", [who, int(e["treasury"]), int(e["debt"])], "INSOLVENCY", "CRITICAL")
				if bool(e.get("forced_ch11", false)):
					hud.post_headline_tr("HL_TAKEOVER_FORCED", [who], "INSOLVENCY", "CRITICAL")
			else:
				hud.post_headline_tr("HL_TAKEOVER_OTHER", [who, Loc.maker_arg(str(e.get("holder", "")))], "INSOLVENCY", "WARNING")
		"bankrupt":
			var holder: String = str(e.get("holder", ""))
			if holder == Takeover.PLAYER:
				hud.post_headline_tr("HL_BANKRUPT_PLAYER", [who, int(e["liquidation"]), int(e["owed"]), int(e["recovered"])], "INSOLVENCY", "CRITICAL")
			elif holder != "":
				hud.post_headline_tr("HL_BANKRUPT_OTHER", [who, int(e["liquidation"]), int(e["owed"]), Loc.maker_arg(holder)], "INSOLVENCY", "CRITICAL")
			else:
				hud.post_headline_tr("HL_BANKRUPT_NONE", [who, int(e["liquidation"]), int(e["owed"])], "INSOLVENCY", "CRITICAL")
		"forfeit":
			hud.post_headline_tr("HL_FORFEIT", [who], "INSOLVENCY", "WARNING")
		"missed":
			hud.post_headline_tr("HL_ARES_MISSED", [who, int(e["penalty"])], "DEBT", "CRITICAL")
			if bool(e.get("forced_ch11", false)):
				hud.post_headline_tr("HL_ARES_RETALIATION", [who], "INSOLVENCY", "CRITICAL")


## GalNet lines for the rival fleets (Epic 3 task 10). A sailing that answers the
## player's departure always posts, as one line that leads with what the fleet saw. A
## spontaneous sailing or sale posts only where the player is docked, so the ticker is not
## buried by trades the player cannot act on; the map shows every fleet in flight.
func _post_rival_headline(e: Dictionary) -> void:
	var fleet: Dictionary = Loc.maker_arg(str(e.get("fleet", "")))
	var station: Dictionary = Loc.station_arg(str(e.get("station", "")))
	var com: Dictionary = Loc.commodity_arg(str(e.get("commodity", "")))
	var here: bool = controller != null and controller.docked_at == str(e.get("station", ""))
	match str(e.get("kind", "")):
		"rival_depart":
			var dest: Dictionary = Loc.station_arg(str(e["destination"]))
			if bool(e.get("reaction", false)):
				hud.post_headline_tr("HL_RIVAL_REACT", [fleet, Loc.station_arg(str(e.get("watched", ""))), int(e["qty"]), com, dest], "MARKET", "WARNING")
			elif here:
				hud.post_headline_tr("HL_RIVAL_DEPART", [fleet, int(e["qty"]), com, station, dest], "MARKET", "INFO")
		"rival_frontrun":
			hud.post_headline_tr("HL_RIVAL_FRONTRUN", [fleet, com, station, (10000 - int(e["depth_bps"])) / 100, int(e["rounds"])], "MARKET", "WARNING")
		"rival_bankrupt":
			hud.post_headline_tr("HL_RIVAL_BANKRUPT", [fleet, int(e["shares"])], "INSOLVENCY", "CRITICAL")
		"rival_bounty_traced":
			hud.post_headline_tr("HL_RIVAL_BOUNTY_TRACED", [fleet, int(e["rounds"])], "CRISIS", "WARNING")
		"rival_raid":
			if str(e.get("choice", "")) == "pay":
				hud.post_headline_tr("HL_RIVAL_RAID_PAID", [fleet, int(e["ransom"])], "CRISIS", "CRITICAL")
			else:
				hud.post_headline_tr("HL_RIVAL_RAID_TAKEN", [fleet, int(e["qty_taken"]), com], "CRISIS", "CRITICAL")
		"rival_trade":
			if here:
				hud.post_headline_tr("HL_RIVAL_SELL", [fleet, int(e["qty"]), com, station, int(e["price"])], "MARKET", "INFO")


## Rival tag for one book ("KESSLER BOUGHT 40", "EMBER SOLD 52"): the first fleet that
## traded it this round; "" when none did or there is no world.
func rival_tag(station: String, commodity: String) -> String:
	if controller == null or controller.world == null:
		return ""
	# A standing front-run is the louder fact about a book than one fleet's last fill.
	var fr: Dictionary = Rivals.front_on(controller.world, station, commodity)
	if not fr.is_empty():
		var fdef: Dictionary = controller.world.rival_def(str(fr["fleet"]))
		var ftag: String = Loc.maker_tag(str(fr["fleet"]), str(fdef.get("name", "")).split(" ")[0].to_upper())
		return Loc.t("TAG_RIVAL_FRONT") % [ftag, (10000 - int(fr["depth_bps"])) / 100]
	var moves: Array = controller.world.rival_moves_on(station, commodity, controller.get_current_round())
	if moves.is_empty():
		return ""
	var m: Dictionary = moves[0]
	var def: Dictionary = controller.world.rival_def(str(m["fleet"]))
	var tag: String = Loc.maker_tag(str(m["fleet"]), str(def.get("name", "")).split(" ")[0].to_upper())
	return Loc.t("TAG_RIVAL_BOUGHT" if str(m["side"]) == "BUY" else "TAG_RIVAL_SOLD") % [tag, int(m["qty"])]


## Squeeze tag for one book as the player sees it ("SHORT SQUEEZE +20%"), "" when
## it is not squeezed or there is no world.
func squeeze_tag(station: String, commodity: String) -> String:
	if controller == null or controller.world == null:
		return ""
	var q: Dictionary = controller.world.squeeze_on(station, commodity)
	if q.is_empty():
		return ""
	return Loc.t("TAG_SQUEEZE") % (int(q["price_bps"]) / 100)


## An order queued into Sol Central's call auction (nothing has traded yet).
func _on_auction_queued(p: Dictionary) -> void:
	if hud != null:
		hud.post_headline_tr("HL_SOL_QUEUED", [Loc.key_arg("ORDER_" + str(p["side"])), int(p["qty"]), Loc.commodity_arg(str(p["commodity"])), Loc.maker_arg(str(p["baron"])), int(p["limit_price"])], "MARKET", "INFO")
	if hud != null and hud.tactile_audio != null:
		hud.tactile_audio.play_sfx(TactileAudio.NAV_BUMP)


## Auction tag for one book ("AUCTION") while Sol Central is auctioning that
## commodity at that station, "" otherwise or with no world.
func auction_tag(station: String, commodity: String) -> String:
	if controller == null or controller.world == null:
		return ""
	var au: Dictionary = controller.world.auction_at(station, controller.get_current_round(), controller.run_seed)
	if au.is_empty() or str(au["commodity"]) != commodity.to_upper():
		return ""
	return Loc.t("TAG_AUCTION")


## Sidebar rows for the auction on the selected book: when it closes, the
## indicative price against the printed reference (the rig made legible), and the
## player's queued orders. Empty when no auction runs on that book.
func auction_lines(station: String, commodity: String) -> Array:
	var out: Array = []
	if controller == null or controller.world == null:
		return out
	var rd: int = controller.get_current_round()
	var ind: Dictionary = controller.world.indicative_at(station, rd, controller.run_seed, market)
	if ind.is_empty() or str(ind["commodity"]) != commodity.to_upper():
		return out
	out.append(Loc.t("SIDE_AUCTION") % [Loc.commodity(commodity), int(ind["close_round"])])
	if bool(ind["hidden"]):
		out.append(Loc.t("SIDE_AUCTION_HIDDEN") % int(ind["ref"]))
	elif int(ind["price"]) < 0:
		out.append(Loc.t("SIDE_AUCTION_NONE") % int(ind["ref"]))
	else:
		var ref: int = int(ind["ref"])
		out.append(Loc.t("SIDE_AUCTION_IND") % [int(ind["price"]), ref, (int(ind["price"]) - ref) * 100 / maxi(1, ref)])
	for o in ind["orders"]:
		# A queued order the printed price walks past is flagged before the close.
		var misses: bool = int(ind["price"]) >= 0 and int((ind["fills"] as Dictionary).get(int(o["seq"]), 0)) <= 0
		out.append(Loc.t("SIDE_AUCTION_ORDER_MISS" if misses else "SIDE_AUCTION_ORDER") % [Loc.t("ORDER_" + str(o["side"])), int(o["qty"]), int(o["limit"])])
	if not (ind["orders"] as Array).is_empty():
		out.append(Loc.t("SIDE_AUCTION_HINT"))
	return out


## B on the Market tab takes queued auction orders back before it leaves the tab.
func withdraw_auction_orders() -> int:
	if controller == null or controller.world == null or controller.docked_at == "":
		return 0
	var n: int = controller.world.withdraw_auction_orders(controller.docked_at)
	if n > 0 and hud != null:
		var id: String = controller.world.baron_at(controller.docked_at)
		hud.post_headline_tr("HL_SOL_WITHDRAWN", [Loc.maker_arg(id), n], "MARKET", "INFO")
	return n


# --- Takeover (Epic 3 task 7): the distress auction and held barons ---

## Why the last share buy was refused ("" when it worked); see buy_shares().
var last_shares_reason: String = ""


## ACT_SHARES (#134): bid for the whole standing lot of the baron anchoring the docked
## station at the player's own value per share; the lot clears, one price for every winner, at
## the next round boundary. Pressing it again raises the top price by bid_step_bps (to outbid a fleet). At a baron a rival fleet holds
## it tenders for the shares the player needs at the fleet's asking price (recapture); with no
## lot and the Hostile Buyout Line it tenders for the public float. Returns true when a bid was
## placed or shares changed hands. A takeover at the threshold happens inside a recapture.
func buy_shares() -> bool:
	if controller == null or controller.world == null or controller.docked_at == "":
		return false
	var o: Dictionary = controller.world.distress_at(controller.docked_at)
	var res: Dictionary
	var bid_placed: bool = false
	var tid: String = controller.world.baron_at(controller.docked_at)
	var ts: BaronState = controller.world.state(tid) if tid != "" else null
	if not o.is_empty():
		var value: int = controller.world.share_value(tid, Takeover.PLAYER, controller)
		# The first press bids at the player's value; each press after it, in the same lot, raises
		# the top price by takeover.bid_step_bps, which is how the player outbids a fleet.
		var prior: Dictionary = Takeover.player_bid(controller.world, tid)
		if not prior.is_empty():
			value = maxi(value, int(prior["px"]) + maxi(1, int(prior["px"]) * int(Takeover.settings(controller.world)["bid_step_bps"]) / 10000))
		res = controller.world.submit_bid(controller, controller.docked_at, int(o["qty"]), value)
		bid_placed = bool(res["ok"])
	elif ts != null and ts.holder != "" and ts.holder != Takeover.PLAYER and controller.world.rival(ts.holder) != null:
		var need: int = Takeover.threshold_for(controller.world, Takeover.PLAYER, controller) - Takeover.shares_of(controller.world, tid, Takeover.PLAYER)
		res = controller.world.recapture_shares(controller, controller.docked_at, ts.holder, need, controller.world.share_value(tid, ts.holder, controller))
	else:
		# No lot on offer: with the Hostile Buyout Line the same key tenders for the public float.
		var to: Dictionary = Takeover.tender_offer(controller.world, tid, controller) if tid != "" else {}
		if to.is_empty():
			return false  # nothing to buy here: the key does nothing
		res = controller.world.tender_shares(controller, controller.docked_at, int(to["qty"]))
	last_shares_reason = "" if bool(res["ok"]) else str(res["reason"])
	if not bool(res["ok"]):
		if hud != null:
			hud.post_headline_tr("HL_SHARES_REFUSED", [Loc.key_arg(Takeover.reason_key(last_shares_reason))], "MARKET", "WARNING")
			if hud.tactile_audio != null:
				hud.tactile_audio.play_sfx(TactileAudio.NAV_BUMP)
		return false
	_refresh_world_mods()  # a taken baron's pipeline premium is gone; its repricing posts first
	if bid_placed and hud != null:
		hud.post_headline_tr("HL_BID_PLACED", [int(res["n"]), Loc.maker_arg(tid), int(res["max_price"]), int(o["px"])], "MARKET", "INFO")
	for e in res["events"]:
		_post_baron_event(e)
	if hud != null and hud.tactile_audio != null:
		hud.tactile_audio.play_sfx(TactileAudio.MARKET_BELL)
	return true


## Why the last credit line was refused ("" when it was extended); see extend_credit().
var last_credit_reason: String = ""


## ACT_CREDIT: extend the standard credit line to the baron anchoring the docked
## station (lever c). Returns true when the line was extended.
func extend_credit() -> bool:
	if controller == null or controller.world == null or controller.docked_at == "":
		return false
	if controller.world.baron_at(controller.docked_at) == "":
		return false
	var res: Dictionary = controller.world.open_credit(controller, controller.docked_at)
	last_credit_reason = "" if bool(res["ok"]) else str(res["reason"])
	if not bool(res["ok"]):
		if hud != null:
			hud.post_headline_tr("HL_CREDIT_REFUSED", [Loc.key_arg(Levers.reason_key(last_credit_reason))], "DEBT", "WARNING")
			if hud.tactile_audio != null:
				hud.tactile_audio.play_sfx(TactileAudio.NAV_BUMP)
		return false
	for e in res["events"]:
		_post_baron_event(e)
	if hud != null and hud.tactile_audio != null:
		hud.tactile_audio.play_sfx(TactileAudio.MARKET_BELL)
	return true


## "distress", "held" or "" for the baron anchoring `station`: what the sidebar leads with.
func takeover_state(station: String) -> String:
	if controller == null or controller.world == null:
		return ""
	var id: String = controller.world.baron_at(station)
	var s: BaronState = controller.world.state(id) if id != "" else null
	if s == null:
		return ""
	if s.holder != "":
		return "held"
	return "distress" if s.strain > 0 or not controller.world.distress_at(station).is_empty() else ""


## Sidebar rows for the baron anchoring `station`; the first is the chip.
## Distress: the lot on offer, how long it has been insolvent, what the player
## holds. Held: who holds it, and the rent. Empty for a healthy baron.
func takeover_lines(station: String) -> Array:
	var out: Array = []
	var st: String = takeover_state(station)
	if st == "":
		return out
	var w: Barons = controller.world
	var id: String = w.baron_at(station)
	var s: BaronState = w.state(id)
	var t: Dictionary = Takeover.settings(w)
	if st == "held":
		if s.holder == Takeover.PLAYER:
			out.append(Loc.t("TAG_HELD"))
			out.append(Loc.t("SIDE_HELD_RENT") % w.rent_of(id))
		else:
			out.append(Loc.t("SIDE_HELD_BY") % (str(w.rival_def(s.holder).get("name", s.holder)).to_upper() if w.rival(s.holder) != null else s.holder.to_upper()))
			if w.rival(s.holder) != null:
				out.append(Loc.t("SIDE_RECAPTURE") % w.share_value(id, s.holder, controller))
		return out
	var o: Dictionary = w.distress_at(station)
	if o.is_empty():
		# This round's lot is sold (the next round lists another), or the treasury has none left.
		out.append(Loc.t("SIDE_DISTRESS_SOLD" if s.treasury_shares > 0 else "SIDE_DISTRESS_NONE"))
	elif bool(o.get("forced", false)):
		out.append(Loc.t("SIDE_FORCED") % int(o["qty"]))
	else:
		out.append(Loc.t("SIDE_DISTRESS") % [int(o["qty"]), int(o["px"])])
	if s.strain > 0:
		out.append(Loc.t("SIDE_INSOLVENT") % [s.strain, int(t["bankrupt_rounds"])])
	out.append(Loc.t("SIDE_SHARES_HELD") % [Takeover.shares_of(w, id, Takeover.PLAYER), Takeover.threshold_for(w, Takeover.PLAYER, controller)])
	var info: Dictionary = w.auction_info(id, controller)
	# One row for value and bid, and the hint only before the player has bid or held a share:
	# the card is short, and the fleets' cash health rows below must not be pushed off it.
	var mine: int = Takeover.shares_of(w, id, Takeover.PLAYER)
	if info["your_bid"].is_empty():
		out.append(Loc.t("SIDE_YOUR_VALUE") % int(info["your_value"]))
	else:
		out.append(Loc.t("SIDE_YOUR_VALUE_BID") % [int(info["your_value"]), int(info["your_bid"]["qty"]), int(info["your_bid"]["px"])])
	if not info["last_clear"].is_empty():
		out.append(Loc.t("SIDE_LAST_CLEAR") % [int(info["last_clear"]["px"]), int(info["last_clear"]["qty"])])
	for row in info["stakes"]:
		if str(row["bidder"]) != Takeover.PLAYER and int(row["shares"]) > 0:
			out.append(Loc.t("SIDE_STAKE") % [Loc.maker_tag(str(row["bidder"]), str(row["bidder"]).to_upper()), int(row["shares"]), int(row["stake_bps"]) / 100])
	if not o.is_empty() and controller.docked_at == station.to_lower() and info["your_bid"].is_empty() and mine == 0:
		out.append(Loc.t("SIDE_BID_HINT"))
	return out


## Sidebar rows for the rival fleets' cash health (#134): every fleet still in the run, its CR
## against its debt, and while it is insolvent the rounds left before it liquidates. Shown at a
## baron's station (where the auction is) and anywhere a fleet is under strain; else empty.
func fleet_health_lines(station: String = "") -> Array:
	var out: Array = []
	if controller == null or controller.world == null:
		return out
	var w: Barons = controller.world
	var at_baron: bool = station != "" and w.baron_at(station) != ""
	var healthy: Array = []
	for fid in w.rival_ids():
		var h: Dictionary = w.fleet_health(fid)
		if h.is_empty() or (int(h["strain"]) <= 0 and not at_baron):
			continue
		var nm: String = str(w.rival_def(fid).get("name", fid)).to_upper()
		if int(h["strain"]) > 0:
			out.append(Loc.t("SIDE_FLEET_STRAIN") % [nm, int(h["cr"]), int(h["debt"]), int(h["rounds_left"])])
		else:
			# Solvent fleets share one row (the card is short): first word of the name, CR / debt.
			healthy.append("%s %d/%d" % [nm.split(" ")[0], int(h["cr"]), int(h["debt"])])
	if not healthy.is_empty():
		out.append(Loc.t("SIDE_FLEET_CASH") % ", ".join(healthy))
	return out


# --- Levers (Epic 3 task 8): corner, margin, credit line, tender ---

## Book tag for a lever leaning on one book ("CORNERED +50%", "FORCED SALE -15%",
## "SELL PRESSURE -20%"), "" when none is or there is no world.
func lever_tag(station: String, commodity: String) -> String:
	if controller == null or controller.world == null:
		return ""
	var w: Barons = controller.world
	var id: String = w.baron_at(station)
	var s: BaronState = w.state(id) if id != "" else null
	if s == null or s.holder != "":
		return ""
	var c: String = commodity.to_upper()
	var cn: Dictionary = w.corner_on(station, c)
	if not cn.is_empty():
		return Loc.t("TAG_CORNERED") % (int(cn["price_bps"]) / 100)
	if Levers.crashes(w, id).has(c):
		return Loc.t("TAG_FORCED_SALE") % (int(Levers.settings(w)["margin"]["crash_bps"]) / 100)
	var p: int = int(Levers.pressure(w, id).get(c, 0))
	if p >= 100:
		return Loc.t("TAG_SELL_PRESSURE") % (p / 100)
	return ""


## Sidebar notes for the levers on the baron anchoring `station`, as {kind, text, tone}
## ("chip" or "line"; tone "bad", "credit" or "tender"). Empty for a held baron, a
## station with no baron, or when no lever is in play.
func lever_notes(station: String) -> Array:
	var out: Array = []
	if controller == null or controller.world == null:
		return out
	var w: Barons = controller.world
	var id: String = w.baron_at(station)
	var s: BaronState = w.state(id) if id != "" else null
	if s == null or s.holder != "":
		return out
	var docked: bool = controller.docked_at == station.to_lower() and not controller.is_in_transit()
	var cfg: Dictionary = Levers.settings(w)
	# a. corner
	var corners: Dictionary = Levers.corners(w, id)
	var corner_keys: Array = corners.keys()
	corner_keys.sort()
	for c in corner_keys:
		var cc: Dictionary = Levers.cover_cost(w, id, str(c))
		out.append({"kind": "chip", "text": Loc.t("TAG_CORNER_NOTE") % Loc.commodity(str(c)), "tone": "bad"})
		out.append({"kind": "line", "text": Loc.t("SIDE_CORNER_COST") % [int(cc["from_stock"]), int(cc["cost"])], "tone": "bad"})
	if docked and corner_keys.is_empty():
		var best: String = ""
		for c in Levers.float_commodities(w, id):
			if int(controller.cargo.get(c, 0)) > int(controller.cargo.get(best, 0)):
				best = c
		if best != "":
			out.append({"kind": "line", "text": Loc.t("SIDE_CORNER_HOLD") % [Loc.commodity(best), int(cfg["corner"]["hold_qty"]), int(controller.cargo.get(best, 0))], "tone": "bad"})
	# b. margin
	var press: Dictionary = Levers.pressure(w, id)
	var crash: Dictionary = Levers.crashes(w, id)
	if s.margin_debt_cr > 0 and (not press.is_empty() or not crash.is_empty()):
		out.append({"kind": "chip", "text": Loc.t("TAG_MARGIN_FORCED" if not crash.is_empty() else "TAG_MARGIN"), "tone": "bad"})
		out.append({"kind": "line", "text": Loc.t("SIDE_MARGIN") % [Levers.margin_ratio_pct(w, id), int(cfg["margin"]["maintenance_bps"]) / 100], "tone": "bad"})
		var pk: Array = press.keys()
		pk.sort()
		for c in pk:
			out.append({"kind": "line", "text": Loc.t("SIDE_PRESSURE") % [Loc.commodity(str(c)), int(press[c]) / 100], "tone": "bad"})
	# c. credit line
	var cl: Dictionary = Levers.credit(w, id)
	if not cl.is_empty():
		out.append({"kind": "chip", "text": Loc.t("TAG_CREDIT"), "tone": "credit"})
		out.append({"kind": "line", "text": Loc.t("SIDE_CREDIT_OPEN") % [int(cl["due"]), int(cl["due_round"])], "tone": "credit"})
	elif docked and Levers.is_pressed(w, id):
		out.append({"kind": "chip", "text": Loc.t("TAG_CREDIT_OFFER"), "tone": "credit"})
		out.append({"kind": "line", "text": Loc.t("SIDE_CREDIT_OFFER") % [int(cfg["credit"]["line_cr"]), int(cfg["credit"]["rate_bps"]) / 100, int(cfg["credit"]["term_rounds"])], "tone": "credit"})
		out.append({"kind": "line", "text": Loc.t("SIDE_CREDIT_HINT"), "tone": "credit"})
	# tender (Hostile Buyout Line)
	var to: Dictionary = Takeover.tender_offer(w, id, controller)
	if not to.is_empty() and w.distress_at(station).is_empty():
		out.append({"kind": "chip", "text": Loc.t("TAG_TENDER"), "tone": "tender"})
		out.append({"kind": "line", "text": Loc.t("SIDE_TENDER") % [int(to["qty"]), int(to["px"])], "tone": "tender"})
		out.append({"kind": "line", "text": Loc.t("SIDE_SHARES_HELD") % [Takeover.shares_of(w, id, Takeover.PLAYER), Takeover.threshold_for(w, Takeover.PLAYER, controller)], "tone": "tender"})
		if docked:
			out.append({"kind": "line", "text": Loc.t("SIDE_SHARES_HINT"), "tone": "tender"})
	# heat (task 11): what this baron remembers, and the retaliation it has queued
	var rq: Dictionary = Heat.queued(w, id)
	if not rq.is_empty():
		out.append({"kind": "chip", "text": Loc.t("TAG_RETALIATION"), "tone": "bad"})
		out.append({"kind": "line", "text": Loc.t("SIDE_RETALIATION") % int(rq["due"]), "tone": "bad"})
	elif s.heat > 0:
		out.append({"kind": "chip", "text": Loc.t("TAG_HEAT"), "tone": "bad"})
		out.append({"kind": "line", "text": Loc.t("SIDE_HEAT") % [s.heat, int(Heat.settings(w)["retaliation_at"])], "tone": "bad"})
	return out


## Sidebar notes for a bounty on the player the player has traced (it is secret until
## then, design doc 6.1): the chip, who hired it and how long it runs. {kind, text, tone}.
func bounty_notes() -> Array:
	var out: Array = []
	if controller == null or controller.world == null:
		return out
	var rd: int = controller.get_current_round()
	var c: Dictionary = controller.world.bounty_on_player(rd)
	if c.is_empty() or int(c.get("traced", 0)) <= 0:
		return out
	var def: Dictionary = controller.world.rival_def(str(c["sponsor"]))
	var who: String = Loc.maker_tag(str(c["sponsor"]), str(def.get("name", "")).split(" ")[0].to_upper())
	out.append({"kind": "chip", "text": Loc.t("TAG_BOUNTY"), "tone": "bad"})
	out.append({"kind": "line", "text": Loc.t("SIDE_BOUNTY") % [who, maxi(0, int(c["expires_round"]) - rd), controller.world.bounty_raid_odds_bps(rd) / 100], "tone": "bad"})
	return out


## Hoard tag for one book as the player sees it ("TITAN HOARDING", "CORNER +25%",
## "RELEASE -15%"), "" when it is not being hoarded or there is no world.
func hoard_tag(station: String, commodity: String) -> String:
	if controller == null or controller.world == null:
		return ""
	var h: Dictionary = controller.world.hoard_on(station, commodity)
	if h.is_empty():
		return ""
	match str(h["phase"]):
		TitanCryoHydro.PHASE_HOARDING:
			return Loc.t("TAG_HOARD")
		TitanCryoHydro.PHASE_CORNERED:
			return Loc.t("TAG_CORNER") % (int(h["price_bps"]) / 100)
		TitanCryoHydro.PHASE_RELEASING:
			return Loc.t("TAG_RELEASE") % (-int(h["price_bps"]) / 100)
	return ""


func _on_margin_call(amount: int) -> void:
	if hud != null:
		hud.post_headline_tr("HL_MARGIN_CALL", [amount], "CRISIS", "WARNING")

## Swaps in a restored StationMarket (loading a saved run) and rebinds the HUD to it.
func set_market(m: StationMarket) -> void:
	market = m
	if hud != null:
		hud.market = market


# --- Docking and travel (#111) ---

## Docks the player at `station` and points the HUD at it. This is the run's
## starting dock only: binding or rebinding never calls it, so a loaded save
## (docked elsewhere, or in transit) keeps its place.
func dock_at(station: String) -> void:
	var s: String = station.to_lower()
	if controller != null and Transit.STATIONS.has(s):
		controller.docked_at = s
		controller.transit = {}
	if market != null:
		market.unlock_station(s)
	if hud != null and Transit.STATIONS.has(s):
		hud.set_station(s)


## Points the HUD at where a loaded run actually is: the dock, or the voyage's
## destination while in transit. Does not move the ship.
func sync_hud_to_ship() -> void:
	if controller == null or hud == null:
		return
	var s: String = controller.docked_at
	if controller.is_in_transit():
		s = str(controller.transit["destination"])
	if Transit.STATIONS.has(s):
		hud.set_station(s)


## A on the Map tab: leave the docked station for the station LT/RT selected.
## Returns true when the ship left. Otherwise last_depart_reason says why.
func depart_to_selected() -> bool:
	if controller == null or hud == null:
		return false
	var res: Dictionary = controller.depart(hud.active_station, market)
	last_depart_reason = "" if bool(res["ok"]) else str(res["reason"])
	last_depart_check = res
	if not bool(res["ok"]) and hud.tactile_audio != null:
		hud.tactile_audio.play_sfx(TactileAudio.NAV_BUMP)
	return bool(res["ok"])


## Player-facing line for the last refused departure ("" when none).
func depart_message() -> String:
	var dest: String = hud.active_station if hud != null else ""
	match last_depart_reason:
		"":
			return ""
		"IN_TRANSIT":
			return Loc.t("DEPART_IN_TRANSIT")
		"SAME_STATION":
			return Loc.t("DEPART_SAME_STATION")
		"INSUFFICIENT_CR":
			return Loc.t("DEPART_NO_TOLL") % Transit.calculate_toll(controller.docked_at, dest)
		"INSUFFICIENT_FUEL":
			return Loc.t("DEPART_NO_FUEL") % [int(last_depart_check.get("fuel_units", 0)), int(last_depart_check.get("fuel_buy", 0)), int(last_depart_check.get("fuel_cr", 0)) + int(last_depart_check.get("fuel_fee", 0)) + int(last_depart_check.get("toll", 0))]
		"NO_ROUTE":
			return Loc.t("DEPART_NO_ROUTE")
	return Loc.t("DEPART_REFUSED")


func _on_transit_departed(info: Dictionary) -> void:
	last_depart_reason = ""
	# Unlock the destination's books now, so its ladder is live while the player browses it.
	if market != null:
		market.unlock_station(str(info["destination"]))
	# Idle rival fleets see the departure (decision 9.5): the world moves them now, their
	# GalNet lines are posted after the player's own departure line below.
	var rival_events: Array = []
	if controller != null and controller.world != null and market != null:
		rival_events = controller.world.react_to_departure(controller, market, info)
	if hud == null:
		return
	var origin: Dictionary = Loc.station_arg(str(info["origin"]))
	var dest: Dictionary = Loc.station_arg(str(info["destination"]))
	var rounds: int = int(info["rounds"])
	if rounds == 1:
		hud.post_headline_tr("HL_SHIP_DEPART_ONE", [origin, dest], "TRANSIT", "INFO")
	else:
		hud.post_headline_tr("HL_SHIP_DEPART_MANY", [origin, dest, rounds], "TRANSIT", "INFO")
	if int(info["toll"]) > 0:
		hud.post_headline_tr("HL_BELT_TOLL", [int(info["toll"]), origin, dest], "TRANSIT", "WARNING")
	if int(info.get("fuel_burned", 0)) > 0:
		hud.post_headline_tr("HL_FUEL_BURN", [int(info["fuel_burned"]), int(info["fuel_hold"]), int(info["fuel_bought"]), int(info["fuel_cr"])], "TRANSIT", "INFO")
	for e in rival_events:
		_post_baron_event(e)


func _on_transit_arrived(info: Dictionary) -> void:
	var dest: String = str(info["destination"])
	if market != null:
		market.unlock_station(dest)
	# An accepted defense contract is paid the moment the ship docks at the anchor
	# with the stock (Epic 3 task 4).
	if controller != null and controller.world != null:
		var done: Dictionary = controller.world.try_deliver(controller)
		if not done.is_empty():
			_post_baron_event(done)
			_refresh_world_mods()
	if hud == null:
		return
	# The book, ladder and quotes follow the dock, whatever the player was browsing.
	hud.set_station(dest)
	hud.post_headline_tr("HL_SHIP_ARRIVED", [Loc.station_arg(dest), Loc.station_arg(str(info["origin"]))], "TRANSIT", "INFO")
	var baron: String = str(info.get("toll_baron", ""))
	if int(info.get("docking_toll", 0)) > 0:
		var short: bool = int(info["docking_toll"]) < int(info.get("docking_toll_due", 0))
		hud.post_headline_tr("HL_DOCKING_TOLL_SHORT" if short else "HL_DOCKING_TOLL", [Loc.maker_arg(baron), int(info["docking_toll"]), Loc.station_arg(dest)], "TRANSIT", "WARNING")
	elif baron != "" and controller != null and controller.world != null and controller.world.is_insider(StationMarket.PLAYER_ID, baron) and controller.world.def(baron).get("privileges", {}).get("docking_toll_cr", 0) > 0:
		hud.post_headline_tr("HL_DOCKING_EXEMPT", [Loc.maker_arg(baron), Loc.station_arg(dest)], "TRANSIT", "INFO")


# --- Baron privileges (Epic 3 task 3): tag strings for the board and sidebar ---

## Pipeline tag for one book as the player sees it: "PIPELINE +8% ASK" for an
## outsider, "PIPELINE (YOURS)" once the baron is held, "" when the book has no
## pipeline (or there is no world).
func pipeline_tag(station: String, commodity: String) -> String:
	if controller == null or controller.world == null:
		return ""
	var p: Dictionary = controller.world.pipeline(station, commodity)
	if p.is_empty():
		return ""
	if controller.world.is_insider(StationMarket.PLAYER_ID, str(p["baron"])):
		return Loc.t("TAG_PIPELINE_YOURS")
	var bps: int = int(p["outsider_ask_bps"])
	return Loc.t("TAG_PIPELINE_ASK") % (str(bps / 100) if bps % 100 == 0 else String.num(float(bps) / 100.0))


## Docking-toll line for a station ("" when it charges none or there is no world):
## the toll an outsider pays, or EXEMPT for an insider.
func toll_line(station: String) -> String:
	if controller == null or controller.world == null:
		return ""
	var id: String = controller.world.baron_at(station)
	if id == "":
		return ""
	var fee: int = int(controller.world.def(id).get("privileges", {}).get("docking_toll_cr", 0))
	if fee <= 0:
		return ""
	if controller.world.is_insider(StationMarket.PLAYER_ID, id):
		return Loc.t("TAG_TOLL_EXEMPT")
	return Loc.t("TAG_TOLL") % fee


# --- Clock ---

## Steps the simulation by a real-time frame delta. Returns sub-ticks executed.
## Zero while paused, while the Chapter 11 overlay is up, or after collapse.
func advance(delta: float) -> int:
	# Raw delta is inspected first, ahead of the overlay/bankruptcy gates and the lag clamp.
	if controller != null and SimClock.is_wake_delta(delta):
		handle_wake("delta")
		return 0
	if controller == null or overlay_state != OVERLAY_NONE:
		return 0
	return controller.advance(delta)


## Wake from suspend (raw-delta spike, or the platform pause/resume/focus notifications):
## discard slept time, auto-pause, flag the banner, re-anchor focus and tell listeners
## to re-arm audio. Zero sim ticks, doomsday ticks or market rounds run here.
func handle_wake(source: String = "delta") -> void:
	if controller == null:
		return
	var was_paused: bool = controller.sim_clock.paused
	controller.sim_clock.handle_suspend_wake(source if source != "delta" else "system_suspend")
	# A deliberate player pause is left as-is; only a pause the wake itself caused gets the banner.
	sleep_pause_active = sleep_pause_active or not was_paused
	wake_count += 1
	reanchor_focus()
	woke_from_sleep.emit(source)


## Points controller input at the active modal (overlay) or the pause state, and
## releases any m0_* action that was held when the device slept.
func reanchor_focus() -> void:
	for a in ALL_ACTIONS:
		if InputMap.has_action(a) and Input.is_action_pressed(a):
			Input.action_release(a)
	if overlay_state != OVERLAY_NONE:
		focus_anchor = overlay_state
		return
	focus_anchor = FOCUS_ANCHOR_PAUSE
	if hud != null and hud.gamepad_focus != null:
		var zone: GamepadFocus.Zone = GamepadFocus.Zone.ORDER_BOOK if tab == Tab.MARKET else GamepadFocus.Zone.TACTICAL_MAP
		hud.gamepad_focus.current_zone = zone
		hud.gamepad_focus.zone_changed.emit(int(zone))


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


## The hull the Fleet tab has selected, clamped into the current fleet.
func selected_hull() -> int:
	if controller == null:
		return 0
	fleet_cursor = FleetView.step_cursor(fleet_cursor, 0, controller.ships.size())
	return fleet_cursor


## Moves the Fleet tab's selection one hull (no wrap). False at either end of the list.
func move_fleet_cursor(delta: int) -> bool:
	if controller == null:
		return false
	var before: int = selected_hull()
	fleet_cursor = FleetView.step_cursor(before, delta, controller.ships.size())
	return fleet_cursor != before


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
	if action == ACT_LOCALE:
		Loc.cycle_locale()
		_click()
		action_handled.emit(action)
		return true
	if overlay_state == OVERLAY_NONE and sleep_trap_active() and action != ACT_PAUSE:
		return false  # the sleep banner: Start resumes, nothing behind it is live
	if overlay_state == OVERLAY_COLLAPSED:
		return _collapsed_action(action)
	if overlay_state == OVERLAY_CRISIS and action != ACT_CHAPTER_11:
		# A acknowledges; nothing else is live behind the modal.
		var acked: bool = action == ACT_SUBMIT and acknowledge_crisis()
		if acked:
			_click()
			action_handled.emit(action)
		return acked
	if overlay_state == OVERLAY_MONOPOLY and action != ACT_CHAPTER_11:
		# A continues; nothing else is live behind the modal.
		var carried: bool = action == ACT_SUBMIT and acknowledge_monopoly()
		if carried:
			_click()
			action_handled.emit(action)
		return carried
	if overlay_state == OVERLAY_CONTRACT and action != ACT_CHAPTER_11:
		# A accepts, B declines; nothing else is live behind the modal.
		var answered: bool = (action == ACT_SUBMIT and accept_contract()) or (action == ACT_CANCEL and decline_contract())
		if answered:
			_click()
			action_handled.emit(action)
		return answered
	if overlay_state != OVERLAY_NONE and not OVERLAY_ACTIONS.has(action):
		return false
	if action == ACT_SUBMIT and tab == Tab.MAP:
		# On the Map tab A is not an order: it departs for the selected station.
		if not depart_to_selected():
			return false
		_click()
		action_handled.emit(action)
		return true
	if tab == Tab.FLEET and (action == ACT_UP or action == ACT_DOWN):
		# The ladder is not shown on the Fleet tab, so the D-pad and left stick walk the
		# hull list instead. Every other order-entry action stays inert here.
		var moved: bool = move_fleet_cursor(-1 if action == ACT_UP else 1)
		if moved:
			_click()
			action_handled.emit(action)
		return moved
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
		ACT_SHARES:
			handled = buy_shares()
		ACT_CREDIT:
			handled = extend_credit()
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
	if tab == Tab.MARKET and withdraw_auction_orders() > 0:
		return true
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
	# The severance breakdown, re-derived from the same terms Parachutes.award_severance
	# summed: peak share, rounds, and per-baron points are exact, the rest is filings.
	var award: int = controller.severance_award
	var broken: int = controller.barons_broken_award
	var rounds: int = controller.rounds_survived_award
	var peak_pts: int = maxi(0, controller.peak_net_worth) * Parachutes.SEVERANCE_NET_WORTH_BPS / Parachutes.BPS
	var baron_pts: int = broken * Parachutes.SEVERANCE_PER_BARON
	var round_pts: int = rounds * Parachutes.SEVERANCE_PER_ROUND
	var filing_pts: int = maxi(0, award - peak_pts - baron_pts - round_pts)
	var filings_count: int = (filing_pts / Parachutes.SEVERANCE_PER_FILING) if Parachutes.SEVERANCE_PER_FILING > 0 else 0
	return {
		"reason": controller.end_reason,
		"net_worth": controller.net_worth(),
		"peak_net_worth": controller.peak_net_worth,
		"rounds_survived": controller.get_current_round(),
		"corp_number": controller.corp_number,
		"severance_awarded": controller.severance_award,
		"severance_balance": controller.profile.severance_points,
		"barons_broken": controller.barons_broken_award,
		"barons_severance": baron_pts,
		"severance_rounds": rounds,
		"severance_rounds_pts": round_pts,
		"severance_filings": filings_count,
		"severance_filings_pts": filing_pts,
		"severance_peak_pts": peak_pts,
		"broken_ids": _broken_baron_ids(broken),
		"runs_completed": controller.profile.runs_completed,
	}


## The barons held when the corp ended (captured by _on_collapsed), else those held now
## when that count matches the award; [] when the names are unknown (the summary then
## shows one aggregate row).
func _broken_baron_ids(count: int) -> Array:
	if count <= 0:
		return []
	if _broken_ids.size() == count:
		return _broken_ids.duplicate()
	if controller != null and controller.world != null:
		var held: Array = controller.world.held_by(Takeover.PLAYER)
		if held.size() == count:
			return held
	return []


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
	focus_trap = {}  # a new run starts on its own defaults, not the old corp's focus
	_broken_ids = []
	if controller.world != null:
		rc.world = Barons.for_new_run()  # a new Sol: fresh barons
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
	dock_at(M0_STATION)
	collapse_phase = PHASE_NONE
	perk_cursor = 0
	collapse_phase_changed.emit(PHASE_NONE)
	run_restarted.emit(rc)
	tab_changed.emit(tab_name())
	return rc


# --- Signal handlers ---

func _on_order_executed(payload: Dictionary) -> void:
	total_fills += 1
	# Lever b: a sale at a baron's anchor leans on its collateral (Levers.record_trade).
	if controller != null and controller.world != null:
		controller.world.record_trade(str(payload.get("station", "")).to_lower(), str(payload.get("commodity", "")), str(payload.get("side", "")), int(payload.get("qty", 0)))
	if hud != null and hud.tactile_audio != null:
		hud.tactile_audio.play_sfx(TactileAudio.MARKET_BELL)


func _on_order_rejected(_reason: String, _payload: Dictionary) -> void:
	if hud != null and hud.tactile_audio != null:
		hud.tactile_audio.play_sfx(TactileAudio.NAV_BUMP)


func _on_bankruptcy_pending(_assessment: Dictionary) -> void:
	# SimClock has already auto-paused via the interrupt hook; make it explicit.
	controller.sim_clock.pause()
	_set_overlay(OVERLAY_CHAPTER_11)


func _on_bankruptcy_filed(report: Dictionary) -> void:
	_set_overlay(OVERLAY_NONE)
	for e in report.get("forfeited_barons", []):
		_post_baron_event(e)  # held barons revert to their own management
	# The controller leaves the clock paused for the caller; the new corp starts at 1x.
	controller.sim_clock.set_speed(1)
	controller.sim_clock.resume()
	_refresh_world_mods()  # the failed corp's contract and squeeze ended with it
	_raise_crisis_if_pending()


func _on_collapsed() -> void:
	_broken_ids = controller.world.held_by(Takeover.PLAYER) if controller.world != null else []
	controller.sim_clock.pause()
	_set_phase(PHASE_SUMMARY)
	_set_overlay(OVERLAY_COLLAPSED)


func _on_round_advanced(round_num: int) -> void:
	# World first, then replenish (design doc 2.2); the crisis deck already ran.
	# advance_round decides the baron behaviours and writes them into world state;
	# the mods are then re-emitted from that state, since replenish() reseeds every book.
	if controller != null and controller.world != null:
		for e in controller.world.advance_round(round_num, controller, market):
			_post_baron_event(e)
		market.set_world_mods(controller.world.market_mods())
	market.replenish()
	# Rival fleets trade the fresh books (Epic 3 task 10), so their dent stays on the
	# ladder for the round.
	if controller != null and controller.world != null:
		for e in controller.world.advance_rivals(round_num, controller, market):
			_post_baron_event(e)
	_raise_contract_if_pending()
	round_completed.emit(round_num)


func _on_clock_changed(_value: Variant) -> void:
	if controller != null and not controller.sim_clock.paused:
		sleep_pause_active = false
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
		# A save can hold an unanswered contract offer (autosave runs after it was posted).
		_raise_contract_if_pending()


func _set_overlay(state: String) -> void:
	if overlay_state != state:
		var was: String = overlay_state
		overlay_state = state
		# The focus trap: a modal opening notes where the gamepad focus was, and the
		# modal closing puts it back there (UI state only; nothing here reaches the sim).
		if was == OVERLAY_NONE:
			focus_trap = _capture_focus()
		overlay_changed.emit(overlay_state)
		if state == OVERLAY_NONE and not focus_trap.is_empty():
			_restore_focus(focus_trap)
			focus_trap = {}


## Where the gamepad focus is: the zone, the ladder cursor and side, the order quantity,
## the tab, the fleet cursor and whether the trading overlay is up.
func _capture_focus() -> Dictionary:
	if hud == null or hud.gamepad_focus == null:
		return {}
	var f: GamepadFocus = hud.gamepad_focus
	return {"zone": int(f.current_zone), "side": int(f.active_side), "ladder": f.ladder_index, "qty": f.order_qty,
		"tab": int(tab), "fleet": fleet_cursor, "overlay": hud.is_trading_overlay_open()}


func _restore_focus(snap: Dictionary) -> void:
	if hud == null or hud.gamepad_focus == null:
		return
	var f: GamepadFocus = hud.gamepad_focus
	if int(tab) != int(snap["tab"]):
		set_tab(int(snap["tab"]) as Tab)
	f.set_zone(int(snap["zone"]) as GamepadFocus.Zone)
	f.set_order_side(int(snap["side"]) as GamepadFocus.OrderSide)
	f.ladder_index = int(snap["ladder"])
	f.order_qty = int(snap["qty"])
	fleet_cursor = int(snap["fleet"])
	if bool(snap["overlay"]) != hud.is_trading_overlay_open():
		if bool(snap["overlay"]):
			hud.open_trading_overlay()
		else:
			hud.close_trading_overlay()


## True while the sleep banner holds the gamepad: only Start (resume) is live behind it.
func sleep_trap_active() -> bool:
	return sleep_pause_active and controller != null and controller.sim_clock.paused


func to_dict() -> Dictionary:
	return {
		"docked_at": controller.docked_at if controller != null else "",
		"in_transit": controller != null and controller.is_in_transit(),
		"tab": tab_name(),
		"overlay_state": overlay_state,
		"speed_label": speed_label(),
		"total_fills": total_fills,
		"has_controller": controller != null,
		"markets": market.books.keys() if market != null else [],
	}
