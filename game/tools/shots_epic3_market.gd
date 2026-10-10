extends SceneTree
## Screenshots for Epic 3 task 2 (part of #15, Baron Framework design): the market
## board and ladder at Mars, Ceres (with a fill) and Earth, each made by a different
## baron. Run under xvfb with the real renderer, as shots_epic3_barons.gd does:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic3_market.gd -- <out dir> <file prefix>
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
	print("makers: ", {"mars": main.loop.market.maker_for("mars"), "ceres": main.loop.market.maker_for("ceres"), "earth": main.loop.market.maker_for("earth")})
	await _shot("market-mars")
	main.loop.dock_at("ceres")
	main._refresh_readouts()
	await _shot("market-ceres")
	# Buy at the Ceres ask: the fill line names the baron.
	main.loop.dispatch_action(M0Loop.ACT_SUBMIT)
	main._refresh_readouts()
	print("ceres fill: ", main.hud.gamepad_focus.last_executed_order)
	await _shot("market-ceres-fill")
	main.hud.gamepad_focus.last_executed_order = {}
	main.loop.dock_at("earth")
	main._refresh_readouts()
	await _shot("market-earth")
