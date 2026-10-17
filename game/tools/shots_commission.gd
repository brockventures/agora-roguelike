extends SceneTree
## Screenshots for the Commission hearing UI and $SOL true ending (#149):
##   1. hearing.png: Ministry Dissolution Hearing with one commissioner retained (enforcement),
##      1 Skeleton available, and the cursor on another commissioner (customs).
##   2. true_ending.png: Sun Privatization Act ($SOL) true ending card at 100% Regulatory Capture.
## Run under xvfb with the real renderer:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_commission.gd -- <out dir>
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
	DirAccess.make_dir_recursive_absolute(out_dir)
	Palette.set_current(Palette.DEFAULT)
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

	# 1. Hearing with one commissioner retained ("enforcement") and cursor on "customs" (index 1).
	var p: MetaProfile = main.controller.profile
	p.consultants = ["enforcement"]
	p.skeletons = 1
	main.loop.open_hearing()
	main.loop.hearing_cursor = 1
	main._refresh_readouts()
	await _settle(8)
	_save("hearing")

	# 2. $SOL true ending card (all 5 commissioners retained, 100% capture).
	p.consultants = Commission.ids()
	p.skeletons = 0
	main.loop.open_hearing()
	main._refresh_readouts()
	await _settle(8)
	_save("true_ending")

	main.queue_free()
	await _settle(2)
	quit()
