extends SceneTree
## Screenshots for the HUD v3 "command deck" (part of #73 Epic 6: Visual Identity): every
## screen the 3a frame covers, reached through the real loop (docked start, real crisis
## deck, real Ares offer, real collapse), plus pseudo-locale at 130% and deuteranopia.
## Run under xvfb with the real renderer (not --headless):
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_hud_v3.gd -- <out dir> [name ...]
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


func _fresh(seed_value: int = 84) -> void:
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
	main.start_new_run(seed_value)
	main.controller.cr = 5000
	main.loop.dock_at("mars")
	main.hud.set_commodity("ORE")
	main.controller.sim_clock.pause()
	main._refresh_readouts()


## Plays the real loop until `done` (a Callable returning bool) or the guard runs out.
func _play_until(done: Callable, max_frames: int = 60000) -> bool:
	var loop: M0Loop = main.loop
	for i in max_frames:
		if done.call():
			return true
		if loop.overlay_state == M0Loop.OVERLAY_CRISIS and not done.call():
			loop.acknowledge_crisis()
		elif loop.overlay_state == M0Loop.OVERLAY_NONE and main.controller.sim_clock.paused and not main.controller.pending_bankruptcy:
			main.controller.sim_clock.resume()
		loop.advance(FRAME)
	return bool(done.call())


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	only = args.slice(1)
	await _run()
	quit()


func _run() -> void:
	if _want(["01-map-docked-mars", "02-market-ladder-ticket"]):
		await _fresh()
		var hud = main.hud
		var lp: M0Loop = main.loop
		# 01 Map root, docked at Mars (Arcadia Foundries), with the stock GalNet lines.
		hud.post_headline("Ares Heavy bids climbing: MACHINERY +4.2% on convoy delays", "MARKET", "INFO")
		lp.set_tab(M0Loop.Tab.MAP)
		main._refresh_readouts()
		await _shot("01-map-docked-mars")
		# 02 Market tab: the quote board over the map, ladder and ticket below.
		lp.set_tab(M0Loop.Tab.MARKET)
		main.hud.gamepad_focus.set_quantity(5)
		main._refresh_readouts()
		await _shot("02-market-ladder-ticket")
	if _want(["03-crisis-modal", "03b-crisis-card"]):
		await _fresh()
		var lp3: M0Loop = main.loop
		main.controller.sim_clock.resume()
		print("crisis reached: ", _play_until(func(): return lp3.overlay_state == M0Loop.OVERLAY_CRISIS))
		main.controller.sim_clock.pause()
		main._refresh_readouts()
		await _shot("03-crisis-modal")
		lp3.acknowledge_crisis()
		lp3.set_tab(M0Loop.Tab.MAP)
		main._refresh_readouts()
		await _shot("03b-crisis-card")
	if _want(["04-chapter-11"]):
		# 04 Chapter 11: push the corp past insolvency.
		await _fresh()
		var lp4: M0Loop = main.loop
		var a: Dictionary = main.controller.assess()
		main.controller.doomsday.principal_debt += int(a["liquidation_value"]) - int(a["total_debt"]) + 500
		main.controller.sim_clock.resume()
		print("chapter 11 reached: ", _play_until(func(): return lp4.overlay_state == M0Loop.OVERLAY_CHAPTER_11, 2000))
		main.controller.sim_clock.pause()
		main._refresh_readouts()
		await _shot("04-chapter-11")
	if _want(["05-ares-contract", "05b-contract-accepted-market"]):
		# 05 The Ares Heavy contract offer (round 8), then accepted.
		await _fresh()
		var lp5: M0Loop = main.loop
		main.controller.sim_clock.resume()
		print("offer reached: ", _play_until(func(): return lp5.overlay_state == M0Loop.OVERLAY_CONTRACT))
		main.controller.sim_clock.pause()
		main._refresh_readouts()
		await _shot("05-ares-contract")
		lp5.dispatch_action(M0Loop.ACT_SUBMIT)
		lp5.set_tab(M0Loop.Tab.MARKET)
		main.hud.set_commodity(str(lp5.open_contract().get("commodity", "MACHINERY")))
		main._refresh_readouts()
		await _shot("05b-contract-accepted-market")
	if _want(["06-fleet"]):
		await _fresh()
		main.controller.cargo["FUEL"] = 4
		main.loop.set_tab(M0Loop.Tab.FLEET)
		main._refresh_readouts()
		await _shot("06-fleet")
	if _want(["07-run-summary", "08-golden-parachutes"]):
		# 07 Run summary and the Golden Parachutes list: run the doomsday clock out.
		await _fresh()
		var lp7: M0Loop = main.loop
		main.controller.sim_clock.resume()
		print("collapse reached: ", _play_until(func(): return lp7.overlay_state == M0Loop.OVERLAY_COLLAPSED, 400000))
		main.controller.sim_clock.pause()
		main._refresh_readouts()
		await _shot("07-run-summary")
		lp7.dispatch_action(M0Loop.ACT_SUBMIT)
		main._refresh_readouts()
		await _shot("08-golden-parachutes")
	if _want(["09-pseudo-130-market"]):
		# 09 Pseudo-locale at 130% text on the Market tab.
		await _fresh()
		Loc.set_locale(Loc.LOCALE_PSEUDO)
		main.settings.set_text_scale(1.3)
		main.apply_text_scale()
		main.loop.set_tab(M0Loop.Tab.MARKET)
		main._refresh_readouts()
		await _shot("09-pseudo-130-market")
	if _want(["10-deuteranopia-market"]):
		# 10 Deuteranopia palette, cursor three levels into the book.
		await _fresh()
		main.settings.set_palette(Palette.DEUTERANOPIA)
		main.loop.set_tab(M0Loop.Tab.MARKET)
		for i in 3:
			main.loop.dispatch_action(M0Loop.ACT_DOWN)
		main._refresh_readouts()
		await _shot("10-deuteranopia-market")
	# Leave the saved settings at their defaults.
	main.settings.reset_defaults()
	main.settings.set_locale(Loc.LOCALE_EN)
	Loc.set_locale(Loc.LOCALE_EN)
