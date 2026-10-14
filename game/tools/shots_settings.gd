extends SceneTree
## Screenshots for the settings menu as HudKit cards (#193 settings menu as HudKit cards):
## in-game with the cursor on Text size, in-game with the cursor scrolled into the Controls
## card, and the title screen with the settings overlay open. Run under xvfb with the real
## renderer, not --headless:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_settings.gd -- <out dir>
var out_dir: String = "/tmp/"


func _settle(frames: int = 8) -> void:
	for i in frames:
		await process_frame


func _save(name: String) -> void:
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(out_dir + name + ".png")
	print("shot ", name, " ", img.get_size())


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	Loc.set_locale(Loc.LOCALE_EN)
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await _settle(4)
	main.settings.reset_defaults()
	main.settings.set_locale(Loc.LOCALE_EN)
	main.settings.set_text_scale(1.0)
	main.apply_text_scale()
	main.start_new_run(84)
	main.controller.sim_clock.pause()
	main.settings_menu.open()
	main.settings_menu.cursor = 0
	main._refresh_readouts()
	await _settle()
	_save("ingame")
	# The last action row: the Controls card scrolls so it shows, and says so.
	main.settings_menu.cursor = main.settings_menu.rows().size() - 3
	main._refresh_readouts()
	await _settle()
	_save("controls")
	main.settings_menu.close()
	main.queue_free()
	await _settle(2)
	var title: TitleScreen = (load("res://scenes/title.tscn") as PackedScene).instantiate()
	root.add_child(title)
	await _settle(30)
	title.menu_buttons[2].pressed.emit()  # Corporate Governance: the settings overlay
	await _settle()
	_save("title")
	quit()
