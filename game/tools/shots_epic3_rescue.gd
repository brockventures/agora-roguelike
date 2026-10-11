extends SceneTree
## Screenshots for Epic 3 / #32 task 4 (the Sol System Rescue Project UI): the Stabiliser card
## with an open phase, the delivery prompt, the delivery chips mid-phase, a refused delivery
## (toast and ticker), the clock suffix, the rescued overlay and the run summary rows, and the
## 130% pseudo-locale of the card. STAGED: the player holds every baron and has CR (the
## takeover chain is Epic 3 task 8's, not this one's), and the hold is filled by hand where the
## shot needs cargo; everything else is the real loop (the monopoly modal's A opens the project,
## m0_project delivers, the last delivery wins the run).
## Run under xvfb with the real renderer, as shots_epic3_takeover.gd does:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic3_rescue.gd -- <out dir> <file prefix>
var main: Node
var out_dir: String = "/tmp/"
var prefix: String = ""


func _shot(name: String, frames: int = 6) -> void:
	for i in frames:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(out_dir + prefix + name + ".png")
	print("shot ", prefix + name, " ", img.get_size())


func _fresh() -> void:
	Palette.set_current(Palette.DEFAULT)
	Loc.set_locale(Loc.LOCALE_EN)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	main.settings.reset_defaults()
	main.settings.set_text_scale(1.0)
	main.start_new_run(84)
	main.controller.cr = 400000
	main._refresh_readouts()


func _view(station: String, com: String, tab: M0Loop.Tab = M0Loop.Tab.MARKET) -> void:
	main.controller.sim_clock.pause()
	main.loop.dock_at(station)
	main.loop.set_tab(tab)
	main.hud.set_station(station)
	main.hud.set_commodity(com)
	main._refresh_readouts()


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	if args.size() > 1:
		prefix = args[1]
	await _run()
	quit()


func _run() -> void:
	await _fresh()
	var loop: M0Loop = main.loop
	var rc: RunController = main.controller
	rc.sim_clock.pause()
	# 1. STAGED: the player holds every baron. The monopoly modal is the real one; its A opens the project.
	for id in rc.world.ids():
		Takeover.take(rc.world, id, Takeover.PLAYER, rc)
	rc.doomsday.clear_debt()
	rc.cr = 400000
	loop._raise_monopoly_if_any()
	main._refresh_readouts()
	await _shot("monopoly-modal")
	print("A: ", loop.dispatch_action(M0Loop.ACT_SUBMIT), " rescue open: ", rc.rescue != null and rc.rescue.is_open())
	rc.sim_clock.pause()
	# 2. The Stabiliser card at Mars (not the site), nothing in the hold yet.
	rc.cargo = {}
	_view("mars", "ORE")
	await _shot("card-open-phase")
	# 3. Docked at the site with a full hold: the delivery prompt. STAGED: the hold's contents.
	rc.cargo = {"MACHINERY": 50, "ORE": 30, "FRAG": 20}
	_view("luna", "ORE")
	await _shot("card-deliver-prompt")
	# 4. A delivery leaves the phase half built; the chips mark the books that still matter.
	print("delivered: ", loop.dispatch_action(M0Loop.ACT_PROJECT), " left ", rc.rescue.remaining())
	_view("luna", "ORE")
	await _shot("delivery-progress")
	rc.cargo = {}
	_view("mars", "ORE")
	await _shot("chips-mid-phase")
	# 5. A refused delivery: at the wrong station (toast and ticker line).
	main.toasts.clear()
	print("refused: ", loop.dispatch_action(M0Loop.ACT_PROJECT), " ", loop.last_project_reason)
	_view("mars", "ORE")
	await _shot("refused-toast", 10)
	# 6. Phase 1 finishes: the field slows the clock (header suffix), the next site is the card.
	main.toasts.clear()
	rc.cargo = {"MACHINERY": 50, "ORE": 70}
	_view("luna", "ORE")
	loop.dispatch_action(M0Loop.ACT_PROJECT)
	_view("earth", "FUEL")
	await _shot("phase-done-clock", 10)
	# 7. The 130% pseudo-locale of the card, with a delivery prompt and the longest phase name.
	main.toasts.clear()
	rc.rescue.phase = 2
	rc.rescue.deposits = {"FOOD": 40}
	rc.rescue.fee_paid = 1400
	rc.rescue.keep_bps = 3500
	rc.cargo = {"FOOD": 40, "FRAG": 60}
	_view("mars", "FRAG")
	Loc.set_locale(Loc.LOCALE_PSEUDO)
	main.settings.set_text_scale(1.3)
	main.apply_text_scale()
	main._refresh_readouts()
	await _shot("card-pseudo-130", 10)
	Loc.set_locale(Loc.LOCALE_EN)
	main.settings.set_text_scale(1.0)
	main.apply_text_scale()
	rc.rescue.phase = 0
	rc.rescue.deposits = {}
	rc.rescue.fee_paid = 0
	rc.rescue.keep_bps = 10000
	rc.rescue.completed = []
	main._refresh_readouts()
	rc.doomsday.ticks_remaining = 14 * rc.ticks_per_round  # a late rescue, for a believable summary
	rc.sim_clock.total_ticks = 106 * rc.ticks_per_round
	# 8. The win: every phase delivered through m0_project, as the player would.
	for i in 4:
		var ph: Dictionary = rc.rescue.current()
		_view(str(ph["site"]), str((ph["needs"] as Dictionary).keys()[0]))
		rc.cargo = {}
		for com in ph["needs"]:
			rc.cargo[com] = int(ph["needs"][com])
		loop.dispatch_action(M0Loop.ACT_PROJECT)
	print("rescued: ", rc.is_rescued(), " overlay ", loop.overlay_state)
	main.toasts.clear()
	main._refresh_readouts()
	await _shot("rescued-overlay")
	print("A: ", loop.dispatch_action(M0Loop.ACT_SUBMIT), " phase ", loop.collapse_phase)
	main._refresh_readouts()
	await _shot("run-summary-rescued")
	Loc.set_locale(Loc.LOCALE_PSEUDO)
	main.settings.set_text_scale(1.3)
	main.apply_text_scale()
	main._refresh_readouts()
	await _shot("run-summary-pseudo-130", 10)
	# Leave the user's settings as found: the pseudo-locale and 130% text persist across runs.
	Loc.set_locale(Loc.LOCALE_EN)
	main.settings.set_text_scale(1.0)
	main.apply_text_scale()
	print("headlines: ", main.hud.galnet_headlines.map(func(h): return h["text"]))
