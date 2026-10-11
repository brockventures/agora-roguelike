extends SceneTree
## Screenshots for the fuel market (#138): the route card with its fuel cost (bought, from the
## hold, and with the fuel_hedge perk), the refusal when the player cannot pay for the fuel, the
## departure ticker line that notes the fuel burned, and the card at the 130% pseudo-locale.
## Run under xvfb with the real renderer:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_fuel.gd -- <out dir> [name ...]
var main: Node
var out_dir: String = "/tmp/"
var only: Array = []


func _want(name: String) -> bool:
	return only.is_empty() or only.has(name)


func _shot(name: String) -> void:
	# Notices raised while the clock ran would sit over the map's corner; they are not the subject.
	main.toasts.clear()
	main._refresh_readouts()
	for i in 6:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(out_dir + name + ".png")
	print("shot ", name, " ", img.get_size(), " loc=", Loc.current(), " scale=", main.settings.text_scale)


func _fresh(seed_value: int = 84) -> void:
	if main != null:
		main.queue_free()
		await process_frame
	Palette.set_current(Palette.DEFAULT)
	Loc.set_locale(Loc.LOCALE_EN)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	main.settings.reset_defaults()
	main.settings.set_locale(Loc.LOCALE_EN)
	main.settings.set_palette(Palette.DEFAULT)
	main.settings.set_text_scale(1.0)
	main.apply_text_scale()
	await process_frame
	Loc.set_locale(Loc.LOCALE_EN)
	main.settings.set_locale(Loc.LOCALE_EN)
	main.settings.set_text_scale(1.0)
	main.apply_text_scale()
	main.start_new_run(seed_value)
	main.controller.cr = 5000
	main.loop.dock_at("mars")
	main.hud.set_commodity("ORE")
	main.controller.sim_clock.pause()
	main._refresh_readouts()


## Steps the sim n ticks (the clock must be running), acknowledging stray crises.
func _fly(n: int) -> void:
	main.controller.sim_clock.resume()
	var target: int = main.controller.sim_clock.total_ticks + n
	var guard: int = 0
	while main.controller.sim_clock.total_ticks < target and guard < 400000:
		guard += 1
		if main.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			main.loop.acknowledge_crisis()
		elif main.loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			main.loop.decline_contract()
		elif main.loop.overlay_state != M0Loop.OVERLAY_NONE:
			print("overlay ", main.loop.overlay_state, " stopped the fly at round ", main.controller.get_current_round())
			break
		main.loop.advance(1.0 / 60.0 + 0.0001)
	main.controller.sim_clock.pause()


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	only = args.slice(1)
	await _run()
	quit()


func _hedge() -> void:
	main.controller.apply_modifiers({"fuel_discount_bps": {"add": 1000, "mul_bps": 10000}})


func _run() -> void:
	if _want("fuel-01-card-buy"):
		await _fresh()
		main.hud.set_station("ceres")
		main._refresh_readouts()
		await _shot("fuel-01-card-buy")
	if _want("fuel-02-card-hedge"):
		await _fresh()
		_hedge()
		main.hud.set_station("ceres")
		main._refresh_readouts()
		await _shot("fuel-02-card-hedge")
	if _want("fuel-03-card-hold"):
		await _fresh()
		main.controller.cargo = {"FUEL": 30}
		main.hud.set_station("ceres")
		main._refresh_readouts()
		await _shot("fuel-03-card-hold")
	if _want("fuel-04-refusal"):
		await _fresh()
		main.controller.cr = 60
		main.hud.set_station("ceres")
		main.loop.depart_to_selected()
		main._refresh_readouts()
		await _shot("fuel-04-refusal")
	if _want("fuel-05-ticker"):
		await _fresh()
		main.hud.set_station("earth")
		main.loop.depart_to_selected()
		# The rival fleets' answers to the departure scroll past the player's own lines; post
		# the player's two again, through the same call and strings, so they are the visible pair.
		var info: Dictionary = main.controller.transit_info()
		var origin: Dictionary = Loc.station_arg(str(info["origin"]))
		var dest: Dictionary = Loc.station_arg(str(info["destination"]))
		main.hud.post_headline_tr("HL_SHIP_DEPART_MANY", [origin, dest, int(info["rounds"])], "TRANSIT", "INFO")
		main.hud.post_headline_tr("HL_FUEL_BURN", [int(info["fuel_burned"]), int(info["fuel_hold"]), int(info["fuel_bought"]), int(info["fuel_cr"])], "TRANSIT", "INFO")
		main._refresh_readouts()
		await _shot("fuel-05-ticker")
	if _want("fuel-06-pseudo-130"):
		await _fresh()
		_hedge()
		main.hud.set_station("ceres")
		Loc.set_locale(Loc.LOCALE_PSEUDO)
		main.settings.set_text_scale(1.3)
		main.apply_text_scale()
		main._refresh_readouts()
		await _shot("fuel-06-pseudo-130")
	# Leave the saved settings at defaults so a later run of the game does not inherit pseudo/130%.
	await _fresh()
	main._save_settings()
