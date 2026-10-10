extends SceneTree
## Screenshots for Epic 3 task 11 (part of #18, Rival Syndicate Fleets): front-running,
## privateer bounties, heat and the consequence event. The loop is the real one, the shipped
## data is the shipped data; the only staging is CR, a full hold, and the chances (front-run,
## bounty and trace set to 10000 bps so the one run shows each, where the shipped odds
## would take many seeds). Shot 1: the player leaves Mars for Earth with 80 ORE and
## Kessler Freight front-runs it, one GalNet line, the dent on the Earth ORE book. Shot 2:
## the player has cornered Ares Heavy for four rounds (heat 4 of 6), then sails the belt lane
## with the hold full, and Blackwater's bounty is traced. Shot 3: the player keeps the corner
## on until the baron's retaliation lands, as the crisis modal.
## Run under xvfb with the real renderer, as shots_epic3_rivals.gd does:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic3_heat.gd -- <out dir> <file prefix>
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
	var r: Dictionary = main.controller.world.data["rivals"]
	r["front_run_chance_bps"] = 10000
	r["bounty_chance_bps"] = 10000
	r["bounty_trace_bps"] = 10000
	r["decide_chance_bps"] = 0  # the fleets only answer the player here
	main._refresh_readouts()


## Plays the real loop until `done` or the guard runs out. `stop_on_retaliation` leaves the
## crisis modal up when it is the baron's retaliation; any other crisis or offer is answered.
func _play_until(done: Callable, max_frames: int = 40000, stop_on_retaliation: bool = false) -> bool:
	var loop: M0Loop = main.loop
	for i in max_frames:
		if done.call():
			return true
		if loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			if stop_on_retaliation and str(loop.current_crisis().get("id", "")) == "ares_retaliation":
				return true
			loop.acknowledge_crisis()
		elif loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			loop.decline_contract()
		elif loop.overlay_state == M0Loop.OVERLAY_NONE and main.controller.sim_clock.paused and not main.controller.pending_bankruptcy:
			main.controller.sim_clock.resume()
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
		main.hud.set_station(station)
	if main.hud.active_commodity != com:
		main.hud.set_commodity(com)
	main._refresh_readouts()


func _headlines() -> Array:
	return main.hud.galnet_headlines.map(func(h): return main.hud.headline_text(h)).slice(0, 6)


func _run() -> void:
	# 1. Front-run: leave Mars for Earth with 80 ORE; Kessler Freight (docked at Earth) answers.
	await _fresh()
	var loop: M0Loop = main.loop
	var rc: RunController = main.controller
	var w: Barons = rc.world
	rc.cargo = {"ORE": 80}
	rc.sim_clock.pause()
	loop.set_tab(M0Loop.Tab.MAP)
	main.hud.set_station("earth")
	print("depart: ", loop.dispatch_action(M0Loop.ACT_SUBMIT), " ", rc.is_in_transit())
	print("kessler front: ", w.rival("kessler_freight").front, " route ", w.rival("kessler_freight").route)
	_play_until(func(): return rc.get_current_round() >= 1)  # the reseed that carries the dent
	_view("earth", "ORE")
	print("tag: ", loop.rival_tag("earth", "ORE"), " headlines: ", _headlines())
	await _shot("front-run")
	# 2. Heat and a traced bounty: corner Ares Heavy at Mars for four rounds, then sail the belt lane.
	await _fresh()
	loop = main.loop
	rc = main.controller
	w = rc.world
	rc.cargo = {"ORE": 100}
	_play_until(func(): return w.heat_of("ares_heavy") >= 4 or rc.get_current_round() > 12)
	print("heat ", w.heat_of("ares_heavy"), " round ", rc.get_current_round())
	loop.market.unlock_station("ceres")
	rc.sim_clock.pause()
	loop.set_tab(M0Loop.Tab.MAP)
	main.hud.set_station("ceres")
	print("depart: ", loop.dispatch_action(M0Loop.ACT_SUBMIT), " ", rc.is_in_transit())
	_play_until(func(): return not w.bounty_on_player(rc.get_current_round()).is_empty() and int(w.bounty_on_player(rc.get_current_round()).get("traced", 0)) > 0 or rc.get_current_round() > 30)
	print("bounty: ", w.bounty_on_player(rc.get_current_round()), " heat ", w.heat_of("ares_heavy"), " headlines ", _headlines())
	_view("mars", "ORE")
	print("notes: ", loop.lever_notes("mars"), loop.bounty_notes())
	await _shot("bounty-heat")
	# 3. The consequence: keep the corner on until Ares Heavy retaliates.
	await _fresh()
	loop = main.loop
	rc = main.controller
	w = rc.world
	rc.cargo = {"ORE": 100}
	var hit: bool = _play_until(func(): return false, 40000, true)
	print("retaliation modal: ", hit, " round ", rc.get_current_round(), " crisis ", loop.current_crisis().get("id", ""))
	main._refresh_readouts()
	await _shot("consequence-event")
	# The same frame once the player has answered the modal: the sidebar chip for the event.
	loop.acknowledge_crisis()
	main.controller.sim_clock.pause()
	main._refresh_readouts()
	await _shot("consequence-sidebar")
