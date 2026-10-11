extends SceneTree
## Screenshots for the Sol tactical map (Epic 6 #124): the MapNode nodes (Sun, teal stations,
## the docked rust node and the dashed ring on the LT/RT pick), the route preview card on a
## belt lane and on a lane that stays inside the belt, a crowded inner-system round where the
## labels keep apart, the TickerLine chips by category, the ship under way with its YOU tag,
## and the map at the 130% pseudo-locale. Run under xvfb with the real renderer:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_e6_map.gd -- <out dir> [name ...]
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


## The round (1..47) whose four bodies sit closest together on the panel: the crowded moment.
func _crowded_round() -> int:
	var best: int = 1
	var best_d: float = 1.0e9
	for r in range(1, 48):
		var pts: Array = []
		for st in Transit.STATIONS:
			pts.append(main._map_point(main.tactical_map.get_station_screen_pos(st, r)))
		var d: float = 0.0
		for i in pts.size():
			for j in range(i + 1, pts.size()):
				d += (pts[i] as Vector2).distance_to(pts[j])
		if d < best_d:
			best_d = d
			best = r
	return best


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	only = args.slice(1)
	await _run()
	quit()


func _run() -> void:
	if _want("map-01-nodes"):
		await _fresh()
		main.hud.set_station("earth")
		main._refresh_readouts()
		await _shot("map-01-nodes")
	if _want("map-02-route-card-belt"):
		await _fresh()
		main.hud.set_station("ceres")
		main._refresh_readouts()
		await _shot("map-02-route-card-belt")
	if _want("map-03-route-card-no-belt"):
		await _fresh()
		main.hud.set_station("earth")
		main._refresh_readouts()
		await _shot("map-03-route-card-no-belt")
	if _want("map-04-crowded-inner-system"):
		await _fresh()
		var r: int = _crowded_round()
		var ticks: int = r * main.controller.ticks_per_round - main.controller.sim_clock.total_ticks + 2
		_fly(ticks)
		main.loop.dock_at("mars")
		main.hud.set_station("earth")
		main._refresh_readouts()
		print("crowded round ", r, " now ", main.controller.get_current_round())
		await _shot("map-04-crowded-inner-system")
	if _want("map-05-ticker"):
		await _fresh()
		var hud: OrbitalHUD = main.hud
		hud.post_headline("Ceres Mining Guild: deep-core ore extractors report record yields.", "MARKET", "INFO")
		hud.post_headline("Belt Authority raises the Ceres lane toll to 25 CR.", "REGULATION", "WARNING")
		hud.post_headline("Raiders reported off the Mars lane; escorts advised.", "PIRACY", "WARNING")
		main._refresh_readouts()
		await _shot("map-05-ticker")
		hud.post_headline("Refinancing window opens; margin calls on overdue notes.", "DEBT", "INFO")
		hud.post_headline("Your ship departs Arcadia Foundries for Ceres, ETA 2 rounds.", "TRANSIT", "INFO")
		main._refresh_readouts()
		await _shot("map-05b-ticker")
	if _want("map-06-in-transit-you-tag"):
		await _fresh()
		main.controller.depart("ceres")
		_fly(main.controller.ticks_per_round / 2)
		main._refresh_readouts()
		await _shot("map-06-in-transit-you-tag")
	if _want("map-07-pseudo-130"):
		await _fresh()
		main.hud.set_station("ceres")
		Loc.set_locale(Loc.LOCALE_PSEUDO)
		main.settings.set_text_scale(1.3)
		main.apply_text_scale()
		main._refresh_readouts()
		await _shot("map-07-pseudo-130")
	# Leave the saved settings at defaults so a later run of the game does not inherit pseudo/130%.
	await _fresh()
	main._save_settings()
