extends SceneTree
## Screenshots for the Epic 4 steering follow-ups (#104): the controls hint, the
## collapse summary with its cause line, and the settings screen with the alert rows.
## Run under xvfb with the real renderer (not --headless), same as shots_reskin.gd:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic4_followups.gd -- <out dir>
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


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	await _run()
	quit()


func _run() -> void:
	await _fresh()
	await _shot("01-hud-controls-hint")

	await _fresh()
	main.controller.sim_clock.resume()
	main.controller.doomsday.ticks_remaining = 1
	for i in 8:
		await process_frame
	main.controller.sim_clock.pause()
	main._refresh_readouts()
	await _shot("02-collapse-summary-cause")

	await _fresh()
	main.settings_menu.open()
	main.settings.set_alert_volume(0.7)
	for i in 4:
		main.settings_menu.move(1)
	main._refresh_readouts()
	await _shot("03-settings-alert-volume")
	main.settings_menu.move(1)
	main.settings.set_alert_mute(true)
	main._refresh_readouts()
	await _shot("04-settings-alert-mute-on")
	# Leave no trace in the real settings.json.
	main.settings.reset_defaults()
