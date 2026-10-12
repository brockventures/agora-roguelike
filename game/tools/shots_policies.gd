extends SceneTree
## Screenshots for the Policy Committee modal, the held-policy chip and the adoption line on the
## ticker (#160 Corporate policies, row 4): the pick modal at the round 20 grant with the full
## eligible list, a second pick with an exclusion shown as unavailable, the desk-notes chip with
## the adopted names, the GalNet line just after an adoption, and the modal at 130% in the
## pseudo-locale.
##
## What is real and what is staged, said plainly:
##   REAL    the picks are made with the modal's own input (m0_down / m0_submit through
##           M0Loop.dispatch_action); the grants come from the controller's round counter.
##   STAGED  the clock is jumped to one tick before the grant round (sim_clock.total_ticks), so
##           the shot does not wait 18,000 ticks per milestone; the corp is given cash so it
##           stays solvent across the jump; the 130% pseudo shot stages three held roots and a
##           fourth pending pick (the tallest list a run can show) instead of playing there.
## Run under xvfb with the real renderer (not --headless), HOME pointed at a scratch directory so
## user:// is not the real one (settings and the run slot are written):
##   HOME=/tmp/agora-shots-home xvfb-run -a -s "-screen 0 1280x800x24" godot --path game \
##     --rendering-driver opengl3 --resolution 1280x800 \
##     -s res://tools/shots_policies.gd -- <out dir> [name ...]
const FRAME: float = 1.0 / 60.0 + 0.0001
var main: Node
var out_dir: String = "/tmp/"
var only: Array = []


func _want(name: String) -> bool:
	return only.is_empty() or only.has(name)


func _shot(name: String) -> void:
	main.toasts.clear()
	main._refresh_readouts()
	for i in 8:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(out_dir + name + ".png")
	print("shot ", name, " ", img.get_size(), " loc=", Loc.current(), " scale=", main.settings.text_scale, " overlay=", main.loop.overlay_state, " picks=", main.controller.policies.picks)


func _fresh(p_seed: int = 84) -> void:
	if main != null:
		main.queue_free()
		await process_frame
	Palette.set_current(Palette.DEFAULT)
	Loc.set_locale(Loc.LOCALE_EN)
	SaveStore.new().delete_run()  # a saved run would resume instead of starting this one
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	main.settings.reset_defaults()
	main.settings.set_locale(Loc.LOCALE_EN)
	main.settings.set_palette(Palette.DEFAULT)
	main.settings.set_text_scale(1.0)
	main.settings.tutorial_enabled = false
	main.apply_text_scale()
	await process_frame
	Loc.set_locale(Loc.LOCALE_EN)
	main.start_new_run(p_seed)  # attaches policies, as a player's new game does
	var rc: RunController = main.controller
	rc.cr = 500000
	rc._track_peak(rc.assess())
	main.loop.dock_at("mars")
	main.loop.set_tab(M0Loop.Tab.MARKET)
	main.hud.set_commodity("ORE")
	main.settings.tutorial_enabled = false
	rc.sim_clock.pause()
	main._refresh_readouts()


## STAGED: jumps the clock to one tick before `round_num` and plays the boundary for real; any
## crisis or contract the round draws is answered, until the policy modal is up.
func _play_to_grant(round_num: int) -> bool:
	var rc: RunController = main.controller
	var loop: M0Loop = main.loop
	rc.cr = 500000
	rc.sim_clock.total_ticks = round_num * rc.ticks_per_round - 1
	rc.sim_clock.resume()
	for i in 600:
		match loop.overlay_state:
			M0Loop.OVERLAY_POLICY:
				main._refresh_readouts()
				return true
			M0Loop.OVERLAY_CRISIS, M0Loop.OVERLAY_MONOPOLY:
				loop.dispatch_action(M0Loop.ACT_SUBMIT)
			M0Loop.OVERLAY_CONTRACT:
				loop.dispatch_action(M0Loop.ACT_CANCEL)
		loop.advance(FRAME)
	return false


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	only = args.slice(1)
	await _run()
	quit()


func _run() -> void:
	var loop: M0Loop
	if _want("policy-01-round20-grant"):
		await _fresh()
		loop = main.loop
		print("round 20 modal: ", _play_to_grant(20), " rows=", loop.policy_rows().size())
		await _shot("policy-01-round20-grant")
	if _want("policy-02-exclusion-unavailable") or _want("policy-03-held-chip") or _want("policy-04-adopted-ticker"):
		await _fresh()
		loop = main.loop
		_play_to_grant(20)
		loop.dispatch_action(M0Loop.ACT_SUBMIT)  # A: Synergized Supply Chain (first offer)
		_play_to_grant(50)
		loop.dispatch_action(M0Loop.ACT_SUBMIT)  # A: Risk Transfer Framework (first offer now)
		print("held: ", main.controller.policies.picks)
		_play_to_grant(80)  # the third pick: Corridor Access is barred by Risk Transfer
		if _want("policy-02-exclusion-unavailable"):
			await _shot("policy-02-exclusion-unavailable")
		loop.dispatch_action(M0Loop.ACT_DOWN)  # D-pad to the second offer
		loop.dispatch_action(M0Loop.ACT_SUBMIT)  # A: adopt it
		main.hud.get_recent_headlines(1)
		for i in 30:
			loop.advance(FRAME)
			await process_frame
		if _want("policy-04-adopted-ticker"):
			await _shot("policy-04-adopted-ticker")
		main.controller.sim_clock.pause()
		if _want("policy-03-held-chip"):
			await _shot("policy-03-held-chip")
	if _want("policy-05-pseudo-130"):
		await _fresh()
		loop = main.loop
		Loc.set_locale(Loc.LOCALE_PSEUDO)
		main.settings.set_text_scale(1.3)
		main.apply_text_scale()
		var rc: RunController = main.controller
		rc.policies.earned = 4  # STAGED: three roots held, the fourth pick pending
		rc.policies.milestones_done = 3
		rc.policies.picks = ["supply_chain", "cost_containment", "training_module"] as Array[String]
		loop._raise_policy_if_pending()
		loop.dispatch_action(M0Loop.ACT_DOWN)
		loop.dispatch_action(M0Loop.ACT_DOWN)
		await _shot("policy-05-pseudo-130")
	# Leave the saved settings at defaults.
	main.settings.reset_defaults()
