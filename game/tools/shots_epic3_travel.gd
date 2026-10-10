extends SceneTree
## Screenshots for the Epic 3 travel loop (#111): the map with the ship under way and
## the ETA in the header, the route preview with a belt toll, and the market after
## arriving at a second station. Run under xvfb with the real renderer, as
## shots_epic4_followups.gd does:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic3_travel.gd -- <out dir>
var main: Node
var out_dir: String = "/tmp/"


func _shot(name: String) -> void:
	for i in 5:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(out_dir + name + ".png")
	print("shot ", name, " ", img.get_size())


func _fresh() -> void:
	if main != null:
		main.queue_free()
		await process_frame
	Palette.set_current(Palette.DEFAULT)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	main.settings.reset_defaults()
	main.settings.set_text_scale(1.0)
	main.start_new_run(84)
	main.controller.sim_clock.pause()
	main._refresh_readouts()


func _btn(index: int) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = index
	e.pressed = true
	return e


func _trigger(axis: int) -> void:
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = 1.0
	main.handle_input(e)
	e = InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = 0.0
	main.handle_input(e)


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
	await _run()
	quit()


func _run() -> void:
	# 1. Docked at Mars, Ceres selected with LT/RT: the route preview and its belt toll.
	await _fresh()
	_trigger(JOY_AXIS_TRIGGER_RIGHT)
	main._refresh_readouts()
	await _shot("01-route-preview-belt-toll")

	# 2. A departs for Ceres; part-way along the lane, header shows the ETA.
	main.handle_input(_btn(JOY_BUTTON_A))
	_fly(main.controller.ticks_per_round + main.controller.ticks_per_round / 2)
	main._refresh_readouts()
	await _shot("02-map-in-transit-header-eta")

	# 3. Arrived at Ceres: the Market tab shows Ceres' book and trading works there.
	_fly(main.controller.ticks_per_round * 2)
	main.handle_input(_btn(JOY_BUTTON_RIGHT_SHOULDER))
	main._refresh_readouts()
	await _shot("03-market-after-arriving-at-ceres")
