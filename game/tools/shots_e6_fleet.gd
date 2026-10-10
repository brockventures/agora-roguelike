extends SceneTree
## Screenshots for the Fleet tab (Epic 6 #122): hull rows with archetype tags, hull / shield /
## hold meters, docking status and the transit ETA chip, a selected row, the stock one-hull
## fleet, and the 130% pseudo-locale. Extra hulls are seeded here only (a new game has one).
## Run under xvfb with the real renderer (not --headless):
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_e6_fleet.gd -- <out dir> [name ...]
const FRAME: float = 1.0 / 60.0 + 0.0001
var main: Node
var out_dir: String = "/tmp/"
var only: Array = []


func _want(names: Array) -> bool:
	if only.is_empty():
		return true
	for n in names:
		if only.has(n):
			return true
	return false


func _shot(name: String) -> void:
	if not only.is_empty() and not only.has(name):
		return
	for i in 6:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(out_dir + name + ".png")
	print("shot ", name, " ", img.get_size(), " loc=", Loc.current(), " pal=", Palette.current(), " scale=", main.settings.text_scale)


func _fresh(seed_value: int = 84, seeded: bool = true) -> void:
	if main != null:
		main.queue_free()
		await process_frame
	Palette.set_current(Palette.DEFAULT)
	Loc.set_locale(Loc.LOCALE_EN)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	# A previous capture's saved settings (locale, palette, scale) must not leak into this one.
	main.settings.reset_defaults()
	main.settings.set_locale(Loc.LOCALE_EN)
	main.settings.set_palette(Palette.DEFAULT)
	main.settings.set_text_scale(1.0)
	main.apply_text_scale()
	await process_frame  # a later _ready-time settings load must not win
	Loc.set_locale(Loc.LOCALE_EN)
	main.settings.set_locale(Loc.LOCALE_EN)
	main.settings.set_text_scale(1.0)
	main.apply_text_scale()
	main.start_new_run(seed_value)
	main.controller.cr = 5000
	main.loop.dock_at("mars")
	main.hud.set_commodity("ORE")
	if seeded:
		main.controller.ships = [
			{"id": "starter_hull", "hull_value_cr": 0},
			{"id": "fleet_2", "hull_value_cr": 0, "archetype": "INTERCEPTOR", "hull_pct": 62, "shield_pct": 18},
			{"id": "fleet_3", "hull_value_cr": 0, "archetype": "FREIGHTER", "hull_pct": 100, "shield_pct": 85},
			{"id": "fleet_4", "hull_value_cr": 0, "archetype": "SCRAP_BARGE", "hull_pct": 41, "shield_pct": 0},
			{"id": "fleet_5", "hull_value_cr": 0, "archetype": "SCOUT"},
		]
	main.controller.cargo = {"ORE": 28, "FUEL": 12, "FRAG": 6}
	main.controller.sim_clock.pause()
	main._refresh_readouts()


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	only = args.slice(1)
	await _run()
	quit()


func _depart() -> void:
	main.controller.cr = 100000
	main.controller.depart("ceres" if main.controller.docked_at != "ceres" else "earth")


func _run() -> void:
	var lp: M0Loop
	if _want(["fleet-01-docked-selected"]):
		await _fresh()
		lp = main.loop
		lp.set_tab(M0Loop.Tab.FLEET)
		lp.dispatch_action(M0Loop.ACT_DOWN)
		lp.dispatch_action(M0Loop.ACT_DOWN)
		main._refresh_readouts()
		await _shot("fleet-01-docked-selected")
	if _want(["fleet-02-transit-eta"]):
		await _fresh()
		lp = main.loop
		_depart()
		lp.set_tab(M0Loop.Tab.FLEET)
		lp.dispatch_action(M0Loop.ACT_DOWN)
		main._refresh_readouts()
		await _shot("fleet-02-transit-eta")
	if _want(["fleet-03-scrolled-last-hull"]):
		await _fresh()
		lp = main.loop
		lp.set_tab(M0Loop.Tab.FLEET)
		for i in 4:
			lp.dispatch_action(M0Loop.ACT_DOWN)
		main._refresh_readouts()
		await _shot("fleet-03-scrolled-last-hull")
	if _want(["fleet-04-stock-single-hull"]):
		await _fresh(84, false)
		lp = main.loop
		lp.set_tab(M0Loop.Tab.FLEET)
		main._refresh_readouts()
		await _shot("fleet-04-stock-single-hull")
	if _want(["fleet-05-pseudo-130"]):
		await _fresh()
		lp = main.loop
		_depart()
		Loc.set_locale(Loc.LOCALE_PSEUDO)
		main.settings.set_text_scale(1.3)
		main.apply_text_scale()
		lp.set_tab(M0Loop.Tab.FLEET)
		lp.dispatch_action(M0Loop.ACT_DOWN)
		lp.dispatch_action(M0Loop.ACT_DOWN)
		lp.dispatch_action(M0Loop.ACT_DOWN)
		main._refresh_readouts()
		await _shot("fleet-05-pseudo-130")
	# Leave the saved settings at defaults so a later run of the game does not inherit pseudo/130%.
	await _fresh(84, false)
	main._save_settings()
