extends SceneTree
## Screenshots for Epic 3 task 6 (part of #16, Baron Archetype AIs): Sol Central's call
## auction at Earth. The ship flies Mars to Earth through the real travel loop, the loop is
## played to the next auction round, and the player queues limit orders through the Market
## tab (A on the focused ladder level): the board shows AUCTION and the sidebar the
## indicative price against the reference, a top-of-book bid is flagged as missed, a bid with
## room is not, and the next round boundary clears the auction (headline in the ticker).
## Nothing is staged. Run under xvfb with the real renderer, as shots_epic3_ares.gd does:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic3_sol.gd -- <out dir> <file prefix>
const FRAME: float = 1.0 / 60.0 + 0.0001
var main: Node
var out_dir: String = "/tmp/"
var prefix: String = ""


func _shot(name: String) -> void:
	for i in 5:
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


func _view(com: String) -> void:
	main.controller.sim_clock.pause()
	main.loop.set_tab(M0Loop.Tab.MARKET)
	main.hud.set_station("earth")
	main.hud.set_commodity(com)
	main._refresh_readouts()


func _run() -> void:
	await _fresh()
	var loop: M0Loop = main.loop
	var rc: RunController = main.controller
	var w: Barons = rc.world
	# 1. Fly to Earth: LT until Earth is selected, A departs, play until docked.
	rc.sim_clock.pause()
	for i in 4:
		if main.hud.active_station == "earth":
			break
		_trigger(JOY_AXIS_TRIGGER_LEFT)
	print("selected: ", main.hud.active_station)
	main.handle_input(_btn(JOY_BUTTON_A))
	rc.sim_clock.resume()
	print("docked at earth: ", _play_until(func(): return rc.docked_at == "earth" and not rc.is_in_transit()), " round ", rc.get_current_round())
	# 2. Play on to the next auction round.
	print("auction open: ", _play_until(func(): return not w.auction_at("earth", rc.get_current_round(), rc.run_seed).is_empty()), " round ", rc.get_current_round())
	var au: Dictionary = w.auction_at("earth", rc.get_current_round(), rc.run_seed)
	var com: String = str(au["commodity"])
	print("auction: ", au)
	_view(com)
	await _shot("auction-open")
	# 3. A top-of-book bid: the rig prints a price past its limit, and the row says so.
	main.hud.gamepad_focus.set_quantity(6)
	print("top-of-book bid: ", loop.dispatch_action(M0Loop.ACT_SUBMIT), " buffer ", SolCentral.buffer(w, "sol_central"))
	_view(com)
	await _shot("indicative-misses")
	# 4. A bid with room (three levels deeper into the ask): it fills at the printed price.
	main.hud.gamepad_focus.set_quantity(12)
	for i in 3:
		loop.dispatch_action(M0Loop.ACT_UP)
	print("deep bid: ", loop.dispatch_action(M0Loop.ACT_SUBMIT), " buffer ", SolCentral.buffer(w, "sol_central"))
	print("indicative: ", w.indicative_at("earth", rc.get_current_round(), rc.run_seed, loop.market))
	_view(com)
	await _shot("indicative-fills")
	# 5. The round boundary clears the auction.
	var cargo0: int = int(rc.cargo.get(com, 0))
	var cr0: int = rc.cr
	rc.sim_clock.resume()
	var r0: int = rc.get_current_round()
	print("closed: ", _play_until(func(): return rc.get_current_round() > r0), " round ", rc.get_current_round())
	if loop.overlay_state == M0Loop.OVERLAY_CRISIS:
		loop.acknowledge_crisis()  # a crisis drawn at the same boundary halts the clock behind a modal
	_view(com)
	print("cargo ", cargo0, " -> ", int(rc.cargo.get(com, 0)), " CR ", cr0, " -> ", rc.cr)
	await _shot("auction-clears")
	print("headlines: ", main.hud.galnet_headlines.map(func(h): return h["text"]))
