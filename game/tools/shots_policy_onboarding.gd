extends SceneTree
## Screenshots for the policy onboarding beat (#160 Corporate policies, row 5): the Policy
## Committee modal with the tutorial `text` row at the top, at 1x English and at 130% pseudo.
##
## REAL    the beat fires from the controller's own policy_pending signal at the round-20 grant.
## STAGED  the clock is jumped to one tick before round 20 and the corp given cash (as
##         shots_policies.gd does); the core tutorial is switched off, as a player who has finished
##         the core beats would have it.
## Run under xvfb with the real renderer, HOME pointed at a scratch directory:
##   HOME=/tmp/agora-shots-home xvfb-run -a -s "-screen 0 1280x800x24" godot --path game \
##     --rendering-driver opengl3 --resolution 1280x800 \
##     -s res://tools/shots_policy_onboarding.gd -- <out dir>
const FRAME: float = 1.0 / 60.0 + 0.0001
var main: Node
var out_dir: String = "/tmp/"


func _fresh(locale: String, scale: float) -> void:
	if main != null:
		main.queue_free()
		await process_frame
	Palette.set_current(Palette.DEFAULT)
	Loc.set_locale(Loc.LOCALE_EN)
	SaveStore.new().delete_run()
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	main.settings.reset_defaults()
	main.settings.set_palette(Palette.DEFAULT)
	main.settings.set_text_scale(scale)
	main.settings.set_locale(locale)
	main.apply_text_scale()
	await process_frame
	Loc.set_locale(locale)
	main.start_new_run(84)
	main.enable_onboarding()
	main.settings.set_tutorial_enabled(false)  # the core beats are done; the conditional one still shows
	var rc: RunController = main.controller
	rc.cr = 500000
	rc._track_peak(rc.assess())
	main.loop.dock_at("mars")
	main.loop.set_tab(M0Loop.Tab.MARKET)
	rc.sim_clock.total_ticks = 20 * rc.ticks_per_round - 1
	rc.sim_clock.resume()
	for i in 600:
		match main.loop.overlay_state:
			M0Loop.OVERLAY_POLICY:
				break
			M0Loop.OVERLAY_CRISIS, M0Loop.OVERLAY_MONOPOLY:
				main.loop.dispatch_action(M0Loop.ACT_SUBMIT)
			M0Loop.OVERLAY_CONTRACT:
				main.loop.dispatch_action(M0Loop.ACT_CANCEL)
		main.loop.advance(FRAME)


func _shot(name: String) -> void:
	main.toasts.clear()
	main._refresh_readouts()
	for i in 8:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(out_dir + name + ".png")
	print("shot ", name, " ", img.get_size(), " loc=", Loc.current(), " scale=", main.settings.text_scale,
		" overlay=", main.loop.overlay_state, " beat=", main.onboarding.active_id())


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	await _fresh(Loc.LOCALE_EN, 1.0)
	await _shot("policy-onboarding-01-1x")
	await _fresh(Loc.LOCALE_PSEUDO, 1.3)
	await _shot("policy-onboarding-02-pseudo-130")
	quit()
