extends SceneTree
## Screenshots for the animated title screen (#192 animated title screen): the title at
## rest with the first button focused, and the settings overlay open. Run under xvfb with
## the real renderer and an empty save directory, so Resume Shift is greyed out:
##   AGORA_SAVE_DIR=/tmp/agora-title-shots-save xvfb-run -a -s "-screen 0 1280x800x24" godot \
##     --path game --rendering-driver opengl3 --resolution 1280x800 \
##     -s res://tools/shots_title.gd -- <out dir>
var out_dir: String = "/tmp/"


func _settle(frames: int = 6) -> void:
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
	var title: TitleScreen = (load("res://scenes/title.tscn") as PackedScene).instantiate()
	root.add_child(title)
	await _settle(30)  # first frames: layout, focus, the art's first drift step
	_save("title")
	title.menu_buttons[2].pressed.emit()  # Corporate Governance: the settings overlay
	await _settle()
	_save("title-settings")
	quit()
