extends SceneTree
## Screenshots for the rated piracy and hazard corridors (#139): the route card on a belt lane
## without and with the black_market_corridors perk, the Dark Run smuggling lane card, the ticker
## after a raid and after a storm, and the card at the 130% pseudo-locale.
## Run under xvfb with the real renderer:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_corridors.gd -- <out dir> [name ...]
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


func _perk() -> void:
	main.controller.apply_modifiers({"piracy_odds_bps": {"add": 0, "mul_bps": 8000}})


## A hold worth raiding: the card quotes the raid chance for the cargo aboard.
func _stock() -> void:
	main.controller.cargo = {"MACHINERY": 60, "ORE": 30}


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	only = args.slice(1)
	await _run()
	quit()


func _run() -> void:
	if _want("corridors-01-belt-no-perk"):
		await _fresh()
		_stock()
		main.hud.set_station("ceres")
		main._refresh_readouts()
		await _shot("corridors-01-belt-no-perk")
	if _want("corridors-02-belt-perk"):
		await _fresh()
		_stock()
		_perk()
		main.hud.set_station("ceres")
		main._refresh_readouts()
		await _shot("corridors-02-belt-perk")
	if _want("corridors-03-smuggle-lane"):
		await _fresh()
		_stock()
		_perk()
		main.hud.set_station("ceres")
		main.hud.cycle_station(1)  # the Dark Run entry sits straight after Ceres
		main._refresh_readouts()
		await _shot("corridors-03-smuggle-lane")
	if _want("corridors-04-raid-ticker"):
		await _fresh()
		_stock()
		# The ticker lines a raid posts, through the same strings the departure uses (a hit is not
		# forced: the lines are what is shown). The player's own pair and a rival's answer scroll
		# past, so the raid goes last and is the visible pair.
		main.hud.set_station("ceres")
		main.hud.cycle_station(1)
		main.loop.depart_to_selected()
		main.loop._post_baron_event({"kind": "corridor_raid", "fleet": "", "choice": "surrender", "ransom": 0, "qty_taken": 20, "commodity": "MACHINERY", "value": 1696, "station": "mars", "clamped": false})
		main.loop._post_baron_event({"kind": "corridor_raid", "fleet": "", "choice": "pay", "ransom": 254, "qty_taken": 0, "commodity": "MACHINERY", "value": 1696, "station": "mars", "clamped": false})
		main._refresh_readouts()
		await _shot("corridors-04-raid-ticker")
	if _want("corridors-06-hazard-ticker"):
		await _fresh()
		_stock()
		main.hud.set_station("ceres")
		main.loop.depart_to_selected()
		main.loop._post_baron_event({"kind": "corridor_hazard", "delay": 2, "lost": 7, "requested": 7, "commodity": "ORE", "origin": "mars", "destination": "ceres", "station": "mars"})
		main._refresh_readouts()
		await _shot("corridors-06-hazard-ticker")
	if _want("corridors-05-pseudo-130"):
		await _fresh()
		_stock()
		_perk()
		main.hud.set_station("ceres")
		main.hud.cycle_station(1)
		Loc.set_locale(Loc.LOCALE_PSEUDO)
		main.settings.set_text_scale(1.3)
		main.apply_text_scale()
		main._refresh_readouts()
		await _shot("corridors-05-pseudo-130")
	# Leave the saved settings at defaults so a later run of the game does not inherit pseudo/130%.
	await _fresh()
	main._save_settings()
