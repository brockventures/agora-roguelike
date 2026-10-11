extends SceneTree
## Screenshots for the first-hour tutorial's reading hold (#36 First-Hour Onboarding Flow, task 2):
## the tabs beat on its first frame (HELD chip on the header and the card), the order beat held on
## the Market tab, the row after the dismissal with the clock running, and the held card at the
## 130% pseudo-locale. Persistence is on under a real display, so the game builds the tutorial the
## way a player's does; point HOME at a scratch directory so user:// is not the real one.
## Run under xvfb with the real renderer:
##   HOME=/tmp/agora-shots-home AGORA_RUN_SEED=84 xvfb-run -a -s "-screen 0 1280x800x24" godot \
##     --path game --rendering-driver opengl3 --resolution 1280x800 \
##     -s res://tools/shots_onboarding_hold.gd -- <out dir> [name ...]
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


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	only = args.slice(1)
	await _run()
	quit()


func _run() -> void:
	if _want("hold-01-tabs"):
		await _fresh()
		await _shot("hold-01-tabs")
	if _want("hold-02-order"):
		await _fresh()
		main.handle_input(_btn(JOY_BUTTON_A))  # dismiss the tabs hold
		main.handle_input(_btn(JOY_BUTTON_RIGHT_SHOULDER))  # Market tab: the order beat holds
		await process_frame
		await process_frame
		await _shot("hold-02-order")
	if _want("hold-03-dismissed"):
		await _fresh()
		main.handle_input(_btn(JOY_BUTTON_A))
		for i in 30:
			await process_frame
		await _shot("hold-03-dismissed")
	if _want("hold-04-pseudo-130"):
		await _fresh()
		Loc.set_locale(Loc.LOCALE_PSEUDO)
		main.settings.set_text_scale(1.3)
		main.apply_text_scale()
		await _shot("hold-04-pseudo-130")
	# Leave the saved settings at defaults.
	await _fresh()
	main._save_settings()
