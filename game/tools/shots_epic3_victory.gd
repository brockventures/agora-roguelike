extends SceneTree
## Screenshots for Epic 3 task 9 (part of #17, Hostile Takeover & Insolvency): victory.
## Staged, and said so: the barons are taken with Takeover.take (the 501st-share purchase
## itself is shown by shots_epic3_takeover.gd), then the real loop raises the monopoly
## state; the run summary comes from the real doomsday collapse with two barons held.
## Run under xvfb with the real renderer, as shots_epic3_sol.gd does:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic3_victory.gd -- <out dir> <file prefix>
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
	main.controller._track_peak(main.controller.assess())  # gameplay tracks the peak every sub-tick
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


func _run() -> void:
	# 1. Monopoly: every baron taken; the real loop raises the summary state.
	await _fresh()
	var loop: M0Loop = main.loop
	var rc: RunController = main.controller
	var w: Barons = rc.world
	rc.sim_clock.pause()
	for id in w.ids():
		loop._post_baron_event(Takeover.take(w, id, Takeover.PLAYER, rc))  # STAGED
	print("monopoly: ", w.monopoly_achieved(), " overlay ", loop.overlay_state, " ", loop.monopoly_summary())
	# The staged takeovers moved CR directly, so do what gameplay does on the next sub-tick
	# (RunController._interrupt_check): record the new net worth against the peak.
	rc._track_peak(rc.assess())
	main._refresh_readouts()
	await _shot("monopoly-achieved")
	print("continue: ", loop.dispatch_action(M0Loop.ACT_SUBMIT), " overlay ", loop.overlay_state)
	# 2. A run that ends with two barons held: severance from broken barons.
	await _fresh()
	loop = main.loop
	rc = main.controller
	w = rc.world
	rc.sim_clock.pause()
	for id in ["ares_heavy", "titan_cryo_hydro"]:
		loop._post_baron_event(Takeover.take(w, id, Takeover.PLAYER, rc))  # STAGED
	rc.sim_clock.resume()
	rc.doomsday.ticks_remaining = 1
	for i in 8:
		await process_frame
	rc.sim_clock.pause()
	main._refresh_readouts()
	print("summary: ", loop.run_summary())
	await _shot("run-summary-severance")
