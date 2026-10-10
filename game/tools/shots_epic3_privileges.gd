extends SceneTree
## Screenshots for Epic 3 task 3 (part of #15, Baron Framework design): the market
## board and sidebar with PIPELINE tags and the docking-toll line at Mars, and the
## GalNet toll headline after a real arrival at Earth. Run under xvfb with the real
## renderer, as shots_epic3_market.gd does:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic3_privileges.gd -- <out dir> <file prefix>
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
	main.controller.sim_clock.pause()
	main.controller.cr = 20000
	main.loop.set_tab(M0Loop.Tab.MARKET)
	main.hud.set_commodity("ORE")
	main._refresh_readouts()


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
	await _shot("market-pipeline-mars")
	# A real voyage Mars -> Earth: the docking toll comes off on arrival.
	var rc: RunController = main.controller
	var before: int = rc.cr
	print("depart: ", rc.depart("earth")["ok"])
	rc.sim_clock.resume()
	var guard: int = 4000
	while rc.is_in_transit() and guard > 0:
		guard -= 1
		if main.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			main.loop.acknowledge_crisis()
		main.loop.advance(1.0 / 60.0 + 0.0001)
	rc.sim_clock.pause()
	print("arrived: ", rc.docked_at, " cr ", before, " -> ", rc.cr)
	main.loop.set_tab(M0Loop.Tab.MARKET)
	main.hud.set_commodity("FRAG")
	main._refresh_readouts()
	await _shot("market-toll-earth")
