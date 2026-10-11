extends SceneTree
## Screenshots for the "Orientation program" settings row (#36 First-Hour Onboarding Flow,
## task 4): the settings screen with the row ON, OFF (after pressing Right on the real menu),
## and at 130% text in the pseudo-locale. Persistence is on, so point HOME at a scratch
## directory so user:// is not the real one.
## Run under xvfb with the real renderer:
##   HOME=/tmp/agora-shots-home AGORA_RUN_SEED=84 xvfb-run -a -s "-screen 0 1280x800x24" godot \
##     --path game --rendering-driver opengl3 --resolution 1280x800 \
##     -s res://tools/shots_settings_tutorial.gd -- <out dir> [name ...]
var main: Node
var out_dir: String = "/tmp/"
var only: Array = []


func _want(name: String) -> bool:
	return only.is_empty() or only.has(name)


func _shot(name: String) -> void:
	main.toasts.clear()
	main._refresh_readouts()
	for i in 6:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(out_dir + name + ".png")
	print("shot ", name, " ", img.get_size(), " loc=", Loc.current(), " scale=", main.settings.text_scale, " held=", main.is_onboarding_held(), " ticks=", main.controller.sim_clock.total_ticks)


func _btn(index: int) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = index
	e.pressed = true
	return e


func _fresh() -> void:
	if main != null:
		main.queue_free()
		await process_frame
	Palette.set_current(Palette.DEFAULT)
	Loc.set_locale(Loc.LOCALE_EN)
	SaveStore.new().delete_run()  # a saved run would resume without a hold, by design
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)  # _ready: persistence on, the tutorial built, a new run started
	main.settings.reset_defaults()
	main.settings.set_locale(Loc.LOCALE_EN)
	main.settings.set_palette(Palette.DEFAULT)
	main.settings.set_text_scale(1.0)
	main.settings.tutorial_enabled = true
	main.settings.clear_tutorial_seen(Onboarding.beat_ids())
	main.apply_text_scale()
	Loc.set_locale(Loc.LOCALE_EN)
	await process_frame
	await process_frame  # the first frame raises the tabs hold


func _seen(ids: Array) -> void:
	for id in ids:
		main.settings.mark_tutorial_seen(str(id))
	main._onb_sync_context()


func _settle(frames: int = 3) -> void:
	for i in frames:
		await process_frame


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	only = args.slice(1)
	await _run()
	quit()


func _open_row() -> void:
	var menu: SettingsMenu = main.settings_menu
	menu.open()
	for i in menu.rows().size():
		if int(menu.rows()[i]["kind"]) == SettingsMenu.Row.TUTORIAL:
			menu.cursor = i


func _right() -> void:
	var e := InputEventAction.new()
	e.action = "ui_right"
	e.pressed = true
	main.settings_menu.handle_event(e)


func _run() -> void:
	if _want("set-01-on"):
		await _fresh()
		_open_row()
		await _settle()
		await _shot("set-01-on")
		if _want("set-02-off"):
			_right()
			await _settle()
			await _shot("set-02-off")
	if _want("set-03-pseudo-130-on"):
		await _fresh()
		Loc.set_locale(Loc.LOCALE_PSEUDO)
		main.settings.set_text_scale(1.3)
		main.apply_text_scale()
		_open_row()
		await _settle()
		await _shot("set-03-pseudo-130-on")
		_right()
		await _settle()
		await _shot("set-04-pseudo-130-off")
	# Leave the saved settings at defaults.
	await _fresh()
	main._save_settings()
