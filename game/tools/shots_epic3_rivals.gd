extends SceneTree
## Screenshots for Epic 3 task 10 (part of #18, Rival Syndicate Fleets): the rival fleets.
## Nothing is staged except the starting CR: the fleets are the shipped ones, and everything
## on screen comes out of the real loop. Shot 1 plays on until a rival is mid-lane and
## shows it on the map; shot 2 is a real departure (Map tab, A) that idle fleets answer,
## with the GalNet lines on the ticker; shot 3 plays on to a round where a fleet loaded up at
## the player's own dock and shows the dented ladder with its desk tag.
## Run under xvfb with the real renderer, as shots_epic3_sol.gd does:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic3_rivals.gd -- <out dir> <file prefix>
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
	if main.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
		main.loop.acknowledge_crisis()  # the boundary we stopped on drew a crisis: the player answers it
	main.controller.sim_clock.pause()
	main.loop.set_tab(tab)
	if main.hud.active_station != station:
		main.hud.set_station(station)
	if main.hud.active_commodity != com:
		main.hud.set_commodity(com)
	main._refresh_readouts()


func _asks(m: StationMarket, station: String, com: String) -> Array:
	return (m.get_book(station, com).asks as Array).map(func(o: Order): return "%d x%d" % [o.limit_price, o.remaining_qty()])


func _run() -> void:
	# 1. A fleet mid-lane on the Tactical Map, after the real loop has run a few rounds.
	await _fresh()
	var loop: M0Loop = main.loop
	var rc: RunController = main.controller
	var w: Barons = rc.world
	# Earth and Mars drift apart as the rounds go (periods 12 and 24), so the lanes only read
	# on the map from about round 10 on: play to there first.
	var found: bool = _play_until(func():
		if rc.get_current_round() < 10:
			return false
		for v in main.tactical_map.get_rival_transits():
			if float(v["progress"]) > 0.3 and float(v["progress"]) < 0.7:
				return true
		return false)
	print("map: found ", found, " round ", rc.get_current_round(), " voyages ", w.rival_voyages())
	_view("mars", "ORE", M0Loop.Tab.MAP)
	await _shot("map-fleet-in-flight")
	# 2. The player departs for Earth (Map tab, LT/RT pick, A). Idle fleets answer, one GalNet
	# line each, after the player's own line.
	await _fresh()
	loop = main.loop
	rc = main.controller
	w = rc.world
	_play_until(func():
		return rc.get_current_round() >= 10 and w.rival_voyages().size() <= 1)
	print("round ", rc.get_current_round(), " fleets in flight before departing: ", w.rival_voyages().size())
	rc.sim_clock.pause()
	loop.set_tab(M0Loop.Tab.MAP)
	main.hud.set_station("earth")
	print("depart: ", loop.dispatch_action(M0Loop.ACT_SUBMIT), " ", rc.is_in_transit())
	print("voyages: ", w.rival_voyages())
	# Let the lanes open up so the hulls and their tags read (crises are acknowledged on the way).
	_play_until(func(): return float(rc.transit_info().get("progress", 1.0)) >= 0.4)
	print("player progress ", rc.transit_info().get("progress", -1), " rivals ", main.tactical_map.get_rival_transits().map(func(v): return v["progress"]))
	rc.sim_clock.pause()
	_view("earth", "ORE", M0Loop.Tab.MAP)
	print("headlines: ", main.hud.galnet_headlines.map(func(h): return main.hud.headline_text(h)).slice(0, 6))
	await _shot("departure-headline")
	# 3. A rival trade on the player's own book: play on to a round boundary where a fleet
	# bought at Mars, then show that book.
	await _fresh()
	loop = main.loop
	rc = main.controller
	w = rc.world
	var before: Dictionary = {}
	for c in Transit.COMMODITIES:
		before[c] = _asks(loop.market, "mars", c)
	var hit_box: Dictionary = {"c": ""}  # a lambda copies a plain String, so hold it in a Dictionary
	_play_until(func():
		if rc.get_current_round() < 10:  # as shot 1: the map only reads once Earth and Mars have drifted apart
			return false
		for c in Transit.COMMODITIES:
			if not w.rival_moves_on("mars", c, rc.get_current_round()).is_empty():
				hit_box["c"] = c
				return true
		return false)
	var hit: String = str(hit_box["c"])
	print("trade: ", hit, " round ", rc.get_current_round(), " moves ", w.rival_moves_on("mars", hit, rc.get_current_round()))
	print("asks as seeded (round 0): ", before.get(hit, []))
	print("asks after: ", _asks(loop.market, "mars", hit))
	_view("mars", hit if hit != "" else "ORE")
	await _shot("ladder-trade")
