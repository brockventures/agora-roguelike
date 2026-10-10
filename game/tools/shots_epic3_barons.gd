extends SceneTree
## Screenshots for Epic 3 task 1 (part of #15, Baron Framework design): the Sol
## tactical map with station labels at rounds 1 and 2 (Luna's disc used to cover
## Earth's label at round 1). Run under xvfb with the real renderer, as
## shots_epic3_travel.gd does:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic3_barons.gd -- <out dir> <file prefix>
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
	main._refresh_readouts()


## Steps the sim n ticks (the clock must be running), acknowledging stray crises.
func _fly(n: int) -> void:
	main.controller.sim_clock.resume()
	var target: int = main.controller.sim_clock.total_ticks + n
	while main.controller.sim_clock.total_ticks < target:
		if main.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			main.loop.acknowledge_crisis()
		main.loop.advance(1.0 / 60.0 + 0.0001)
	main.controller.sim_clock.pause()


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
	for r in [1, 2]:
		_fly(main.controller.ticks_per_round)
		main._refresh_readouts()
		print("round ", main.controller.get_current_round())
		await _shot("map-round-%d" % r)
