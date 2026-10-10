extends SceneTree
## Screenshots for Epic 3 task 5 (part of #16, Baron Archetype AIs): Titan Cryo-Hydro's
## hoard at Ceres. The ship flies Mars to Ceres through the real travel loop, the
## player buys a 40-unit FUEL bite off the Ceres ask through the Market tab, and the
## loop is played forward round by round: the hoard starts (HOARDED tag, thinned
## ask), the corner takes hold (CORNER +25% on the board and sidebar, and its headline in the ticker), and
## the release floods the book (RELEASE -15%, headline). Nothing is staged. Run under
## xvfb with the real renderer, as shots_epic3_ares.gd does:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic3_titan.gd -- <out dir> <file prefix>
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


func _view_ceres_fuel() -> void:
	main.controller.sim_clock.pause()
	main.loop.set_tab(M0Loop.Tab.MARKET)
	main.hud.set_station("ceres")
	main.hud.set_commodity("FUEL")
	main._refresh_readouts()


func _run() -> void:
	await _fresh()
	var loop: M0Loop = main.loop
	var rc: RunController = main.controller
	# 1. Fly to Ceres: Ceres selected with RT, A departs, play until docked.
	rc.sim_clock.pause()
	_trigger(JOY_AXIS_TRIGGER_RIGHT)
	main.handle_input(_btn(JOY_BUTTON_A))
	rc.sim_clock.resume()
	print("docked at ceres: ", _play_until(func(): return rc.docked_at == "ceres" and not rc.is_in_transit()), " round ", rc.get_current_round())
	# 2. The player buys a 40-unit FUEL bite off the Ceres ask through the Market tab.
	rc.sim_clock.pause()
	loop.set_tab(M0Loop.Tab.MARKET)
	main.hud.set_station("ceres")
	main.hud.set_commodity("FUEL")
	main.hud.gamepad_focus.set_quantity(40)
	loop.dispatch_action(M0Loop.ACT_UP)  # one level deeper into the ask, so 40 units fill
	var before: int = int(rc.cargo.get("FUEL", 0))
	print("buy: ", loop.dispatch_action(M0Loop.ACT_SUBMIT), " cargo FUEL ", int(rc.cargo.get("FUEL", 0)) - before, " ratio ", loop.market.ask_depth_ratio_bps("ceres", "FUEL"), " reject '", main.hud.gamepad_focus.last_rejection_reason, "'")
	var w: Barons = rc.world
	# 3. The next round boundary: Titan sees the thin ask and starts hoarding.
	rc.sim_clock.resume()
	print("hoard reached: ", _play_until(func(): return not w.hoard_on("ceres", "FUEL").is_empty()), " round ", rc.get_current_round())
	_view_ceres_fuel()
	await _shot("hoarding-market")
	# 4. A few rounds on, the stock reaches the corner line.
	rc.sim_clock.resume()
	print("corner reached: ", _play_until(func(): return str(w.hoard_on("ceres", "FUEL").get("phase", "")) == "cornered"), " round ", rc.get_current_round(), " stock ", w.state("titan_cryo_hydro").inventory)
	_view_ceres_fuel()
	await _shot("corner-market")
	# 5. The hold runs out: the book floods and the price falls.
	rc.sim_clock.resume()
	print("release reached: ", _play_until(func(): return str(w.hoard_on("ceres", "FUEL").get("phase", "")) == "releasing"), " round ", rc.get_current_round())
	_view_ceres_fuel()
	await _shot("release-market")
	print("headlines: ", main.hud.galnet_headlines.map(func(h): return h["text"]))
