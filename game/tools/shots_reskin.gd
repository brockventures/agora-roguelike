extends SceneTree
## Renders every HUD screen at 1280x800 for the #105 re-skin review.
## Run under xvfb with the real renderer (not --headless):
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_reskin.gd -- <out dir> [name ...]
## Screens other than the ones a build supports are skipped, so the same script can
## photograph the "before" checkout.
var main: Node
var out_dir: String = "/tmp/"
var only: Array = []


func _shot(name: String) -> void:
	if not only.is_empty() and not only.has(name):
		return
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
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	root.add_child(main)
	# Deterministic run, no wall-clock ticking during the capture.
	# Persisted settings from an earlier capture must not leak into this one.
	main.settings.reset_defaults()
	main.settings.set_text_scale(1.0)
	main.start_new_run(84)
	main.controller.sim_clock.pause()
	main._refresh_readouts()


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	only = args.slice(1)
	await _run()
	quit()


func _run() -> void:
	await _fresh()
	var lp = main.loop
	var hud = main.hud
	hud.post_headline("Ares Heavy bids climbing: MACHINERY +4.2% on convoy delays", "MARKET", "INFO")
	hud.post_headline("Piracy reported on the Ceres lane, insurers raise premiums", "HAZARD", "WARNING")
	main.controller.sim_clock.resume()
	await _shot("01-hud-map")
	main.controller.sim_clock.pause()

	lp.set_tab(M0Loop.Tab.MARKET)
	hud.gamepad_focus.set_quantity(5)
	main._refresh_readouts()
	await _shot("02-trading-overlay")

	lp.set_tab(M0Loop.Tab.FLEET)
	main._refresh_readouts()
	await _shot("03-fleet-tab")

	lp.set_tab(M0Loop.Tab.MARKET)
	for i in 6:
		lp.dispatch_action(M0Loop.ACT_DOWN)
	main._refresh_readouts()
	await _shot("04-ladder-focus-bid")
	lp.dispatch_action(M0Loop.ACT_CANCEL)
	main._refresh_readouts()
	await _shot("04b-map-zone-focus")
	lp.set_tab(M0Loop.Tab.MARKET)
	main._refresh_readouts()

	for pal in [Palette.DEUTERANOPIA, Palette.PROTANOPIA]:
		main.settings.set_palette(pal)
		main._refresh_readouts()
		await _shot("05-ladder-%s" % pal)
	main.settings.set_palette(Palette.DEFAULT)

	await _fresh()
	lp = main.loop
	var rc: RunController = main.controller
	rc.sim_clock.resume()
	lp.toggle_pause()
	main._refresh_readouts()
	await _shot("06-pause")

	lp.handle_wake("system_suspend")
	main._refresh_readouts()
	await _shot("07-sleep-banner")

	await _fresh()
	lp = main.loop
	lp._set_overlay(M0Loop.OVERLAY_CHAPTER_11)
	main._refresh_readouts()
	await _shot("08-chapter11")

	await _fresh()
	lp = main.loop
	lp.crisis_deck.bags.force("crisis", true)
	lp.crisis_deck.advance_round(3, 1, 400000)
	lp._raise_crisis_if_pending()
	main._refresh_readouts()
	await _shot("09-crisis-modal")

	await _fresh()
	lp = main.loop
	main.controller.sim_clock.resume()
	main.controller.doomsday.ticks_remaining = 1
	for i in 8:
		await process_frame
	main.controller.sim_clock.pause()
	main._refresh_readouts()
	await _shot("10-collapse-summary")

	main.controller.profile.severance_points = 350
	lp.dispatch_action(M0Loop.ACT_SUBMIT)
	main._refresh_readouts()
	await _shot("11-golden-parachutes")
	lp.dispatch_action(M0Loop.ACT_SUBMIT)
	main._refresh_readouts()
	await _shot("12-parachute-bought")

	await _fresh()
	main.settings_menu.open()
	main._refresh_readouts()
	await _shot("13-settings")
	for i in 3:
		main.settings_menu.move(1)
	main._refresh_readouts()
	await _shot("14-settings-focus-binding")
	main.settings_menu.cursor = 1
	main.settings.set_palette(Palette.DEUTERANOPIA)
	main._refresh_readouts()
	await _shot("15-settings-colorblind")
	if main.settings_menu.has_method("rows") and "crt_filter" in main.settings:
		main.settings.set_palette(Palette.DEFAULT)
		main.settings_menu.cursor = 3
		main.settings.crt_filter = true
		main.settings.changed.emit()
		main._refresh_readouts()
		await _shot("16-settings-crt-on")
		main.settings_menu.close()
		main._refresh_readouts()
		await _shot("17-hud-crt-on")
		main.settings.crt_filter = false
		main.settings.changed.emit()

	await _fresh()
	main.settings.set_text_scale(1.3)
	main.loop.set_tab(M0Loop.Tab.MARKET)
	main._refresh_readouts()
	await _shot("18-hud-text-130")
	main.settings_menu.open()
	main._refresh_readouts()
	await _shot("19-settings-text-130")
	main.settings.set_text_scale(1.0)
