extends SceneTree
## Screenshots for Epic 3 task 8 (part of #17, Hostile Takeover & Insolvency): the levers.
## Staged, and said so: the player's hold is filled with ORE (a free grant instead of a
## buy), and the credit shot starts with Ares's treasury already thinned. The distress shot
## has NO staged debt: the player sits on a full hold of ORE at Mars through the real loop
## until Ares's treasury is thin, extends the credit line with the m0_credit action, the
## baron cannot repay it, and the cover it still owes drives it insolvent.
## Run under xvfb with the real renderer, as shots_epic3_sol.gd does:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic3_levers.gd -- <out dir> <file prefix>
const FRAME: float = 1.0 / 60.0 + 0.0001
var main: Node
var out_dir: String = "/tmp/"
var prefix: String = ""


func _shot(name: String, frames: int = 5) -> void:
	for i in frames:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(out_dir + prefix + name + ".png")
	print("shot ", prefix + name, " ", img.get_size())


func _fresh() -> void:
	Palette.set_current(Palette.DEFAULT)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	main.settings.reset_defaults()
	main.settings.set_text_scale(1.0)
	main.start_new_run(84)
	main.controller.cr = 50000
	main._refresh_readouts()


func _trigger(axis: int) -> void:
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = 1.0
	main.handle_input(e)
	e = InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = 0.0
	main.handle_input(e)


func _btn(index: int) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = index
	e.pressed = true
	return e


## Plays the real loop until `done` (a Callable returning bool) or the guard runs out.
func _play_until(done: Callable, max_frames: int = 40000) -> bool:
	var loop: M0Loop = main.loop
	for i in max_frames:
		if done.call():
			return true
		if loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			loop.acknowledge_crisis()
		elif loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			loop.decline_contract()  # Ares's round-8 offer is not what this run is about
		elif loop.overlay_state == M0Loop.OVERLAY_NONE and main.controller.sim_clock.paused and not main.controller.pending_bankruptcy:
			main.controller.sim_clock.resume()  # a doomsday stage change auto-pauses; the player presses Start
		loop.advance(FRAME)
	return bool(done.call())


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	if args.size() > 1:
		prefix = args[1]
	await _run()
	quit()


func _view(station: String, com: String, tab: M0Loop.Tab = M0Loop.Tab.MARKET) -> void:
	main.controller.sim_clock.pause()
	main.loop.set_tab(tab)
	if main.hud.active_station != station:
		main.hud.set_station(station)  # re-selecting the same station posts its MOVE lines again
	if main.hud.active_commodity != com:
		main.hud.set_commodity(com)
	main._refresh_readouts()


## Plays on to the next round boundary (the world step has run when this returns).
func _next_round() -> void:
	var rc: RunController = main.controller
	rc.sim_clock.resume()
	var r0: int = rc.get_current_round()
	_play_until(func(): return rc.get_current_round() > r0)
	if main.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
		main.loop.acknowledge_crisis()
	rc.sim_clock.pause()


func _run() -> void:
	# 1. Corner: a full hold of Ares's pipeline stock at its own dock.
	await _fresh()
	var loop: M0Loop = main.loop
	var rc: RunController = main.controller
	var w: Barons = rc.world
	rc.sim_clock.pause()
	rc.cargo = {"ORE": 100}  # STAGED: a free hold instead of a buy
	_next_round()
	_next_round()
	print("corner: ", Levers.corners(w, "ares_heavy"), " ore stock ", w.state("ares_heavy").inventory)
	_view("mars", "ORE")
	await _shot("corner")
	# 2. Margin: the real sell path dumps the collateral, then the round boundary calls the loan.
	await _fresh()
	loop = main.loop
	rc = main.controller
	w = rc.world
	rc.sim_clock.pause()
	rc.cargo = {"ORE": 100}  # STAGED
	_view("mars", "ORE")
	main.hud.gamepad_focus.set_order_side(GamepadFocus.OrderSide.SELL)
	main.hud.gamepad_focus.snap_depth_level(3)  # the sweep reaches 50 units down the bid ladder
	main.hud.gamepad_focus.set_quantity(50)
	print("sold: ", loop.dispatch_action(M0Loop.ACT_SUBMIT), " ", main.hud.gamepad_focus.last_rejection_reason, " ", main.hud.gamepad_focus.last_rejection_payload, " pressure ", w.state("ares_heavy").pressure_bps, " ratio ", Levers.margin_ratio_pct(w, "ares_heavy"))
	_view("mars", "ORE")
	await _shot("margin-pressure")
	_next_round()
	print("margin: ", w.state("ares_heavy").to_dict())
	_view("mars", "ORE")
	await _shot("margin-call")
	# 3. Credit line: the baron is short of cash (STAGED: the treasury is already thin).
	await _fresh()
	loop = main.loop
	rc = main.controller
	w = rc.world
	rc.sim_clock.pause()
	w.state("ares_heavy").treasury_cr = 30000
	_view("mars", "ORE")
	await _shot("credit-offer")
	print("credit: ", loop.dispatch_action(M0Loop.ACT_CREDIT), " ", w.credit_at("mars"))
	_view("mars", "ORE")
	await _shot("credit-line")
	# 4. Tender: the Hostile Buyout Line unlocks it, and cuts the threshold to 451.
	await _fresh()
	loop = main.loop
	rc = main.controller
	w = rc.world
	rc.sim_clock.pause()
	rc.modifiers = {"takeover_threshold_shares": {"add": -50, "mul_bps": 10000}}  # the perk, owned
	_view("mars", "ORE")
	await _shot("tender-offer")
	print("tender: ", loop.dispatch_action(M0Loop.ACT_SHARES), " ", w.state("ares_heavy").shares)
	_next_round()
	if loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
		loop.decline_contract()
	_view("mars", "ORE")
	await _shot("tender")
	# 5. A baron driven into distress by the levers: nothing staged but the hold.
	await _fresh()
	loop = main.loop
	rc = main.controller
	w = rc.world
	rc.sim_clock.pause()
	rc.cargo = {"ORE": 100}  # STAGED
	var s: BaronState = w.state("ares_heavy")
	var rounds: int = 0
	var lent_at: int = 0
	while rounds < 70 and w.distress_at("mars").is_empty():
		_next_round()
		if loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			loop.decline_contract()
		rc.cargo["ORE"] = 100  # the hold is refilled if a crisis took stock; the player never leaves the dock
		rounds += 1
		if lent_at == 0 and s.treasury_cr < 12000 and s.debt_cr == 0:
			print("lend: ", loop.dispatch_action(M0Loop.ACT_CREDIT))
			lent_at = rounds
	print("distress after ", rounds, " rounds, lent at ", lent_at, ": ", s.to_dict(), " offer ", w.distress_at("mars"))
	for i in 12:
		await process_frame
	_view("mars", "ORE")
	await _shot("distress")
	print("headlines: ", main.hud.galnet_headlines.map(func(h): return h["text"]))
