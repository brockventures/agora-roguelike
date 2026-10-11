extends SceneTree
## Screenshots for the first-hour tutorial's surface (#36 First-Hour Onboarding Flow, task 3):
## each of the five core beats' desk notes, a conditional beat (raid), the Chapter 11 note, the
## perk modal's row, the held footer (A reads Continue) and the 130% pseudo-locale. Beats are
## reached by marking the earlier ones seen and feeding the model the event that fires the beat,
## so the card is the real one. Persistence is on under a real display, so the game builds the tutorial the
## way a player's does; point HOME at a scratch directory so user:// is not the real one.
## Run under xvfb with the real renderer:
##   HOME=/tmp/agora-shots-home AGORA_RUN_SEED=84 xvfb-run -a -s "-screen 0 1280x800x24" godot \
##     --path game --rendering-driver opengl3 --resolution 1280x800 \
##     -s res://tools/shots_onboarding.gd -- <out dir> [name ...]
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


func _market_cargo() -> void:
	main.controller.cargo = {"ORE": 30}
	main.loop.set_tab(M0Loop.Tab.MARKET)


func _run() -> void:
	if _want("onb-01-tabs"):
		await _fresh()
		await _shot("onb-01-tabs")
	if _want("onb-02-order"):
		await _fresh()
		main.handle_input(_btn(JOY_BUTTON_A))
		main.handle_input(_btn(JOY_BUTTON_RIGHT_SHOULDER))
		await _settle()
		await _shot("onb-02-order")
	if _want("onb-03-debt"):
		await _fresh()
		_seen(["tabs", "order"])
		main.loop.set_tab(M0Loop.Tab.MARKET)
		main._onb_event("round_advanced")
		await _settle()
		print("active=", main.onboarding.active_id())
		await _shot("onb-03-debt")
	if _want("onb-04-leave"):
		await _fresh()
		_seen(["tabs", "order", "debt"])
		main.controller.cargo = {"ORE": 30}
		main.loop.set_tab(M0Loop.Tab.MAP)
		main.hud.set_station("ceres")
		await _settle(6)
		print("active=", main.onboarding.active_id())
		await _shot("onb-04-leave")
	if _want("onb-05-sell"):
		await _fresh()
		_seen(["tabs", "order", "debt", "leave"])
		_market_cargo()
		main._onb_event("transit_arrived")
		await _settle()
		print("active=", main.onboarding.active_id())
		await _shot("onb-05-sell")
	if _want("onb-06-raid"):
		await _fresh()
		_seen(["tabs", "order", "debt", "leave", "sell"])
		main._onb_event("corridor_raid")
		await _settle()
		print("active=", main.onboarding.active_id())
		await _shot("onb-06-raid")
	if _want("onb-07-chapter11"):
		await _fresh()
		_seen(["tabs", "order", "debt", "leave", "sell"])
		main.controller.profile.severance_points = 640
		main._onb_event("bankruptcy_filed")
		await _settle()
		print("active=", main.onboarding.active_id())
		await _shot("onb-07-chapter11")
	if _want("onb-08-perks"):
		await _fresh()
		_seen(["tabs", "order", "debt", "leave", "sell"])
		main.controller.profile.severance_points = 640
		main.loop.overlay_state = M0Loop.OVERLAY_COLLAPSED
		main.loop.collapse_phase = M0Loop.PHASE_PERKS
		main._onb_event("perk_screen_opened")
		await _settle()
		print("active=", main.onboarding.active_id())
		await _shot("onb-08-perks")
	if _want("onb-09-footer-held"):
		await _fresh()  # tabs hold on the Map tab: A would depart, but reads Continue
		await _shot("onb-09-footer-held")
	if _want("onb-10-pseudo-130-order"):
		await _fresh()
		Loc.set_locale(Loc.LOCALE_PSEUDO)
		main.settings.set_text_scale(1.3)
		main.apply_text_scale()
		main.handle_input(_btn(JOY_BUTTON_A))
		main.handle_input(_btn(JOY_BUTTON_RIGHT_SHOULDER))
		await _settle()
		await _shot("onb-10-pseudo-130-order")
	if _want("onb-11-pseudo-130-leave"):
		await _fresh()
		Loc.set_locale(Loc.LOCALE_PSEUDO)
		main.settings.set_text_scale(1.3)
		main.apply_text_scale()
		_seen(["tabs", "order", "debt"])
		main.controller.cargo = {"ORE": 30}
		main.loop.set_tab(M0Loop.Tab.MAP)
		main.hud.set_station("ceres")
		await _settle(6)
		await _shot("onb-11-pseudo-130-leave")
	if _want("onb-12-pseudo-130-footer-released"):
		await _fresh()  # the same footer once the hold is dismissed: the baseline for the held one
		Loc.set_locale(Loc.LOCALE_PSEUDO)
		main.settings.set_text_scale(1.3)
		main.apply_text_scale()
		main.handle_input(_btn(JOY_BUTTON_A))
		await _settle()
		await _shot("onb-12-pseudo-130-footer-released")
	# Leave the saved settings at defaults.
	await _fresh()
	main._save_settings()
