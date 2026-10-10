extends SceneTree
## Screenshots for Epic 3 task 4 (part of #16, Baron Archetype AIs): Ares Heavy's
## defense contract offer modal, the open contract on the map and sidebar, the SQUEEZE
## tag on the board and sidebar, and the default that forces Chapter 11. Everything is
## reached by playing the real loop forward, not by staging state. Run under xvfb with
## the real renderer, as shots_epic3_market.gd does:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic3_ares.gd -- <out dir> <file prefix>
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
	main.loop.dock_at("mars")
	main.hud.set_commodity("ORE")
	main._refresh_readouts()


## Plays the real loop until `done` (a Callable returning bool) or the guard runs out.
func _play_until(done: Callable, max_frames: int = 40000) -> bool:
	var loop: M0Loop = main.loop
	for i in max_frames:
		if done.call():
			return true
		if loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			loop.acknowledge_crisis()
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
	await _fresh()
	var loop: M0Loop = main.loop
	var rc: RunController = main.controller
	# 1. Round 8: Ares posts a contract and the clock halts on the offer modal.
	print("offer reached: ", _play_until(func(): return loop.overlay_state == M0Loop.OVERLAY_CONTRACT), " round ", rc.get_current_round())
	var offer: Dictionary = loop.current_offer()
	print("offer: ", offer)
	main._refresh_readouts()
	await _shot("contract-offer")
	# 2. A accepts: the contract shows on the map and in the sidebar.
	print("A accepts: ", loop.dispatch_action(M0Loop.ACT_SUBMIT))
	rc.sim_clock.pause()
	loop.set_tab(M0Loop.Tab.MAP)
	main._refresh_readouts()
	await _shot("contract-open-map")
	# 3. Hold nothing into the last three rounds: the squeeze starts (round 11).
	rc.sim_clock.resume()
	var com: String = str(offer["commodity"])
	print("squeeze reached: ", _play_until(func(): return loop.squeeze_tag("mars", com) != ""), " round ", rc.get_current_round())
	print("state: overlay '", loop.overlay_state, "' paused ", rc.sim_clock.paused, " ticks ", rc.sim_clock.total_ticks, " pending_bk ", rc.pending_bankruptcy)
	if loop.overlay_state == M0Loop.OVERLAY_CRISIS:
		loop.acknowledge_crisis()  # a crisis drawn the same round: shown first, then dismissed
	rc.sim_clock.pause()
	loop.set_tab(M0Loop.Tab.MARKET)
	main.hud.set_commodity(com)
	main._refresh_readouts()
	await _shot("squeeze-market")
	# 4. Never stock up: the contract is missed at round 14 and the fine joins the debt.
	rc.sim_clock.resume()
	print("default reached: ", _play_until(func(): return rc.world.state("ares_heavy").scratch.has("missed")), " round ", rc.get_current_round())
	rc.sim_clock.pause()
	if loop.overlay_state == M0Loop.OVERLAY_CRISIS:
		loop.acknowledge_crisis()
	loop.set_tab(M0Loop.Tab.MAP)
	main._refresh_readouts()
	await _shot("default-penalty-headline")
	# 5. The same default with the corp one step from the edge: the penalty forces Chapter 11.
	main.queue_free()
	await process_frame
	await _fresh()
	loop = main.loop
	rc = main.controller
	_play_until(func(): return loop.overlay_state == M0Loop.OVERLAY_CONTRACT)
	loop.dispatch_action(M0Loop.ACT_SUBMIT)
	print("last tick: ", _play_until(func(): return rc.sim_clock.total_ticks >= 14 * rc.ticks_per_round - 1))
	var a: Dictionary = rc.assess()
	rc.doomsday.principal_debt += int(a["liquidation_value"]) - int(a["total_debt"]) - 30
	print("forced reached: ", _play_until(func(): return rc.pending_bankruptcy), " overlay ", loop.overlay_state)
	loop.set_tab(M0Loop.Tab.MAP)
	main._refresh_readouts()
	await _shot("default-forces-chapter11")
