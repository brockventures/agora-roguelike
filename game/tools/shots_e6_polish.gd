extends SceneTree
## Screenshots for the Epic 6 motion and HUD-fit polish (#124): the map ring march and the
## ticker wipe-in at two phases each, plus three fit fixes: the auction desk notes in the
## card (no clipped chip), the header at the 130% pseudo-locale (CREDITS and SPEED cells),
## and the market ladder title clear of its R-STICK hint at 130%.
## Every capture is a chosen frame: Main starts settled under a SceneTree script, and the
## motion shots hold UI time by hand (Main.freeze_motion_at) rather than waiting on the clock.
## STAGED, and said so: Ares Heavy is given debt past its liquidation value (the door the
## levers use) so a distress lot opens; the rounds, the fleets' bids and the player's bid
## are the real loop. The run summary is the real collapse with two staged takeovers.
## Run under xvfb with the real renderer (not --headless):
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_e6_polish.gd -- <out dir> [name ...]
const FRAME: float = 1.0 / 60.0 + 0.0001
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
	print("shot ", name, " ", img.get_size(), " loc=", Loc.current(), " scale=", main.settings.text_scale, " ui_time=", main.ui_time)


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


func _pseudo_130() -> void:
	Loc.set_locale(Loc.LOCALE_PSEUDO)
	main.settings.set_text_scale(1.3)
	main.apply_text_scale()


func _play_until(done: Callable, max_frames: int = 40000) -> bool:
	var loop: M0Loop = main.loop
	for i in max_frames:
		if done.call():
			return true
		if loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			loop.acknowledge_crisis()
		elif loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			loop.decline_contract()
		elif loop.overlay_state == M0Loop.OVERLAY_NONE and main.controller.sim_clock.paused and not main.controller.pending_bankruptcy:
			main.controller.sim_clock.resume()
		loop.advance(FRAME)
	return bool(done.call())


func _next_round() -> void:
	var rc: RunController = main.controller
	rc.sim_clock.resume()
	var r0: int = rc.get_current_round()
	_play_until(func(): return rc.get_current_round() > r0)
	if main.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
		main.loop.acknowledge_crisis()
	rc.sim_clock.pause()


func _collapse_with_barons() -> void:
	var loop: M0Loop = main.loop
	var rc: RunController = main.controller
	for id in ["ares_heavy", "titan_cryo_hydro"]:
		loop._post_baron_event(Takeover.take(rc.world, id, Takeover.PLAYER, rc))  # STAGED
	rc._track_peak(rc.assess())
	rc.sim_clock.resume()
	rc.doomsday.ticks_remaining = 1
	for i in 8:
		await process_frame
		loop.advance(FRAME)
	main._refresh_readouts()


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	only = args.slice(1)
	await _run()
	quit()


func _run() -> void:
	if _want("polish-auction-hud"):
		await _fresh()
		var loop: M0Loop = main.loop
		var rc: RunController = main.controller
		var w: Barons = rc.world
		rc.cr = 400000
		w.data["takeover"]["auction_cap"] = 100
		w.add_debt("ares_heavy", int(w.assess_baron("ares_heavy")["liquidation_value"]) + 400000)  # STAGED
		var guard: int = 0
		while w.state("ares_heavy").scratch.get("last_clear", null) == null and guard < 10:
			_next_round()
			if loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
				loop.decline_contract()
			guard += 1
		print("bid: ", loop.dispatch_action(M0Loop.ACT_SHARES), " ", Takeover.player_bid(w, "ares_heavy"))
		loop.set_tab(M0Loop.Tab.MARKET)
		main.hud.set_station("mars")
		main.hud.set_commodity("ORE")
		main._refresh_readouts()
		var notes: Dictionary = main._card["notes"]["view"]
		print("desk notes overflow px: ", main.scroll_overflow(notes), " clip h ", (notes["clip"] as Control).size.y)
		await _shot("polish-auction-hud")
		# The same notes a few steps on: the view moves by whole entries, the credit line offer
		# is reached whole, and nothing is cut off at the bottom.
		main._scroll_t = MainScene.SIDEBAR_DWELL_TOP + 3.0
		main._refresh_readouts()
		await _shot("polish-auction-hud-scrolled")
	# Ring march: the map tab, docked with another station picked; two drawings of the loop.
	for phase in [0, 1]:
		var nm: String = "polish-ring-phase%d" % phase
		if _want(nm):
			await _fresh()
			main.hud.set_station("earth")
			main._refresh_readouts()  # the lines this posts are first seen now, at UI time 0
			# 5 s on, a whole number of 4-drawing loops (60 drawings): phase 0 is the settled ring.
			main.freeze_motion_at(5.0 + float(phase) / main.MOTION_FPS)
			main._refresh_readouts()
			await _shot(nm)
	# Ticker wipe: a fresh line a drawing and two drawings in (a third and two thirds revealed).
	for step in [1, 2]:
		var nm: String = "polish-ticker-wipe-%dof3" % step
		if _want(nm):
			await _fresh()
			main.freeze_motion_at(10.0)
			main._refresh_readouts()
			main.hud.post_headline("Belt Authority raises the Ceres lane toll to 25 CR; every hauler crossing the belt pays on departure, and escorts are advised.", "REGULATION", "WARNING")
			main._refresh_readouts()  # the line is first seen at ui_time 10.0
			main.freeze_motion_at(10.0 + float(step) / main.MOTION_FPS)
			main._refresh_readouts()
			await _shot(nm)
	if _want("polish-summary-130"):
		await _fresh()
		_pseudo_130()
		await _collapse_with_barons()
		await _shot("polish-summary-130")
	if _want("polish-market-130"):
		await _fresh()
		_pseudo_130()
		main.loop.set_tab(M0Loop.Tab.MARKET)
		# Ceres / Machinery is the longest ladder title: the one that used to touch the hint.
		main.hud.set_station("ceres")
		main.hud.set_commodity("MACHINERY")
		main._refresh_readouts()
		await _shot("polish-market-130")
	await _fresh()
