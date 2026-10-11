extends RefCounted
## The first-hour onboarding bot (#36 First-Hour Onboarding Flow, task 5, docs/design/onboarding.md
## sections 8, 12 and 14): a headless scripted player that drives the real `Main` objects through
## the core beats 1 to 5 (change tab, place an order, wait while debt climbs, depart, sell at
## another station), pressing only real inputs (`Main.handle_input`), including the reading-hold
## dismissals the tutorial asks for.
##
## One instance is one run: `OnboardingBot.new(seed, tutorial)` then `run()`. With `tutorial` false
## no Onboarding is attached and no dismissal is sent, so the same script is the control. The
## script is a function of the sim state alone (never of the tutorial), and each `_step()` advances
## exactly one frame whether or not a hold was dismissed (a held frame advances zero ticks), so the
## two runs reach the same ticks, the same actions at the same ticks, and must hash the same.
##
## Not a class_name: callers load() it by path, like tools/rescue_bot.gd.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
## A frame is 0.25 s (SimClock.MAX_DELTA_CLAMP), 15 ticks of the sim's 60 per second.
const FRAME_DELTA: float = 0.25
const TICKS_PER_SECOND: int = 60
const MAX_FRAMES: int = 20000
const ORDER_QTY: int = 10
const DEBT_ROUNDS: int = 3
const TAIL_TICKS: int = 1800
const CORE_ORDER: Array = ["tabs", "order", "debt", "leave", "sell"]

var run_seed: int
var tutorial: bool
var main: MainScene = null
## Filled by run(): "" when the script ran to its end, else why it stopped.
var error: String = ""
var frames: int = 0
## Hold dismissals sent, and how many reached M0Loop (must be 0), and the holds seen per beat id.
var presses: int = 0
var leaks: int = 0
var holds: Dictionary = {}
## Per beat id: the sim tick it first became active (fired) and was first seen as done.
var fired_tick: Dictionary = {}
var done_tick: Dictionary = {}
var fire_order: Array = []
var done_order: Array = []
var rounds: int = 0
var buy_station: String = ""
var sell_station: String = ""
var end_ticks: int = 0
var _last_active: String = ""
var _actions: int = 0


func _init(p_seed: int, p_tutorial: bool) -> void:
	run_seed = p_seed
	tutorial = p_tutorial


## Plays the script. Returns true when it reached the end. Free the Main with free_main().
func run() -> bool:
	main = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	main.bags = Bags.new("m0", null, run_seed)
	main.initialize_systems(RunController.new(null, run_seed))
	main._resolve_child_nodes()
	main._build_readouts()
	main.controller.sim_clock.set_paused(false)
	main.controller.round_advanced.connect(func(_r): rounds += 1)
	main.loop.action_handled.connect(func(_a): _actions += 1)
	if tutorial:
		main.enable_onboarding()
	var rc: RunController = main.controller

	# Beat 1, change tab: the tabs hold is dismissed by the step, then RB opens Market.
	if not _step():
		return false
	_press(JOY_BUTTON_RIGHT_SHOULDER)
	_observe()
	# Beat 2, place an order: the order hold, then a real BUY through the order entry.
	if not _step():
		return false
	buy_station = rc.docked_at
	var c: String = _pick_commodity(buy_station)
	if not _trade(c, true, ORDER_QTY, "the order"):
		return false
	# Beat 3, wait while debt climbs: DEBT_ROUNDS rounds of the clock running.
	var base: int = rounds
	while rounds - base < DEBT_ROUNDS:
		if not _step():
			return false
	# Beat 4, depart: back to the Map, aim at a reachable station, dismiss the hold, press A.
	_press(JOY_BUTTON_LEFT_SHOULDER)
	var dest: String = _pick_destination()
	if dest == "":
		return _fail("no reachable destination from %s" % rc.docked_at)
	main.hud.set_station(dest)
	# Two frames: the first hides the Market modal (the route card reads that), the second sees
	# the route card, raises the leave hold and has it dismissed.
	if not _step() or not _step():
		return false
	if not _press(JOY_BUTTON_A) or not rc.is_in_transit():
		return _fail("the departure press did not leave (%s)" % main.loop.last_depart_reason)
	_observe()
	while rc.is_in_transit():
		if not _step():
			return false
	# Beat 5, sell at another station: the sell hold, then a real SELL of the hold.
	if not _step():
		return false
	sell_station = rc.docked_at
	if sell_station == buy_station:
		return _fail("arrived back at the buying station")
	_press(JOY_BUTTON_RIGHT_SHOULDER)
	if not _trade(c, false, int(rc.cargo.get(c, 0)), "the sale"):
		return false
	# Tail: the clock runs on, a fixed number of ticks, in both scripts.
	var stop: int = _ticks() + TAIL_TICKS
	while _ticks() < stop:
		if not _step():
			return false
	end_ticks = _ticks()
	return true


func free_main() -> void:
	if main != null:
		main.free()
		main = null


func state_hash() -> String:
	return RunSave.state_hash(main.controller, main.loop.market, main.bags)


func canonical() -> String:
	return RunSave.canonical(RunSave.capture(main.controller, main.loop.market, main.bags))


func _ticks() -> int:
	return main.controller.sim_clock.total_ticks


func _fail(why: String) -> bool:
	if error == "":
		error = why
	return false


# ---- one frame ------------------------------------------------------------------------

## Advances exactly one frame of sim time: answers a stopped-clock modal (the same way in both
## scripts), runs the frame, and, if the tutorial held it, dismisses the hold with the confirm
## press and runs the frame that then advances. False (with `error`) on a stuck script.
func _step() -> bool:
	frames += 1
	if frames > MAX_FRAMES:
		return _fail("script stuck: ticks %d, rounds %d, beat '%s'" % [_ticks(), rounds, _active()])
	if not _answer_overlay():
		return false
	main._process(FRAME_DELTA)
	_observe()
	var guard: int = 0
	while tutorial and main.is_onboarding_held():
		guard += 1
		if guard > 4:
			return _fail("a hold would not stay dismissed")
		var id: String = _active()
		holds[id] = int(holds.get(id, 0)) + 1
		var before: int = _actions
		presses += 1
		if not _press(JOY_BUTTON_A) or _actions != before:
			leaks += 1
		main._process(FRAME_DELTA)
		_observe()
	return true


## Answers a modal that stopped the clock (a crisis, a contract offer), the same way in both
## scripts. Called before every step and every action press, since a modal traps input.
func _answer_overlay() -> bool:
	var ov: String = main.loop.overlay_state
	if ov == M0Loop.OVERLAY_CRISIS:
		main.loop.acknowledge_crisis()
	elif ov == M0Loop.OVERLAY_CONTRACT:
		main.loop.decline_contract()
	elif ov != M0Loop.OVERLAY_NONE:
		return _fail("unexpected overlay '%s' at tick %d" % [ov, _ticks()])
	return true


## The active beat id ("" with no tutorial), and a fired/done record against the sim tick.
func _active() -> String:
	return main.onboarding.active_id() if main.onboarding != null else ""


func _observe() -> void:
	if main.onboarding == null:
		return
	var a: String = _active()
	if a != "" and not fired_tick.has(a):
		fired_tick[a] = _ticks()
		fire_order.append(a)
	_last_active = a
	for id in CORE_ORDER:
		if main.onboarding.is_seen(id) and not done_tick.has(id):
			done_tick[id] = _ticks()
			done_order.append(id)


## A real joypad press through Main. True when Main (or the loop behind it) consumed it.
func _press(button: int) -> bool:
	_answer_overlay()
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.pressed = true
	return main.handle_input(e)


# ---- the order entry --------------------------------------------------------------------

## BUY or SELL `qty` of `c` at the docked station through the order entry and a confirm press.
func _trade(c: String, buying: bool, qty: int, what: String) -> bool:
	var hud: OrbitalHUD = main.hud
	var rc: RunController = main.controller
	var gf: GamepadFocus = hud.gamepad_focus
	if main.loop.tab != M0Loop.Tab.MARKET:
		return _fail("%s needs the Market tab" % what)
	hud.set_station(rc.docked_at)
	hud.set_commodity(c)
	gf.set_order_side(GamepadFocus.OrderSide.BUY if buying else GamepadFocus.OrderSide.SELL)
	gf.ladder_index = _level_for(buying, qty)
	gf.set_quantity(qty)
	var fills: int = main.loop.total_fills
	_press(JOY_BUTTON_A)
	_observe()
	if main.loop.total_fills <= fills:
		return _fail("%s was not filled (%s %d %s at %s)" % [what, "BUY" if buying else "SELL", qty, c, rc.docked_at])
	return true


## The shallowest ladder level whose cumulative depth covers `qty`, or the deepest there is.
func _level_for(buying: bool, qty: int) -> int:
	var lad: Dictionary = main.hud.get_sidebar_telemetry().get("order_book_ladder", {})
	var levels: Array = lad.get("asks", []) if buying else lad.get("bids", [])
	var cum: int = 0
	for i in levels.size():
		cum += int((levels[i] as Dictionary).get("quantity", (levels[i] as Dictionary).get("qty", 0)))
		if cum >= qty:
			return i
	return maxi(0, levels.size() - 1)


## A tradeable commodity that sells for the most more at the nearest station than it costs here.
func _pick_commodity(here: String) -> String:
	var dest: String = _pick_destination()
	var best: String = ""
	var best_gain: float = -1e9
	for c in Transit.COMMODITIES:
		if c == "FUEL":
			continue
		var gain: float = float(Transit.BASE_PRICES[dest][c]) - float(Transit.BASE_PRICES[here][c])
		if gain > best_gain:
			best_gain = gain
			best = c
	return best


## The shortest reachable destination the corp can afford to leave for ("" for none).
func _pick_destination() -> String:
	var rc: RunController = main.controller
	var best: String = ""
	var best_rounds: int = 1 << 30
	for d in Transit.STATIONS:
		if d == rc.docked_at:
			continue
		var plan: Dictionary = rc.can_depart(d, main.loop.market, "")
		if int(plan["rounds"]) > 0 and bool(plan["ok"]) and int(plan["rounds"]) < best_rounds:
			best_rounds = int(plan["rounds"])
			best = d
	return best
