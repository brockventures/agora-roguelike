extends SceneTree
## Screenshots for the run summary, crisis cards, toasts and modal focus traps (Epic 6 #123):
## the run summary with its severance breakdown (per filing, peak share, per broken baron,
## total), the crisis and audit modals with their 4:3 art frame, a fill toast and a GalNet
## toast, and a modal at the 130% pseudo-locale. Staged, and said so: the two barons are
## taken with Takeover.take (the purchase itself is shown by shots_epic3_takeover.gd), the
## crisis comes from the real deck forced onto its draw, the fill is a real A press on the
## ladder and the GalNet alert is a posted headline.
## Run under xvfb with the real renderer (not --headless):
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_e6_summary.gd -- <out dir> [name ...]
const FRAME: float = 1.0 / 60.0 + 0.0001
var main: Node
var out_dir: String = "/tmp/"
var only: Array = []


func _want(name: String) -> bool:
	return only.is_empty() or only.has(name)


func _shot(name: String) -> void:
	for i in 6:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(out_dir + name + ".png")
	print("shot ", name, " ", img.get_size(), " loc=", Loc.current(), " scale=", main.settings.text_scale)


func _fresh(p_seed: int = 84) -> void:
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
	main.start_new_run(p_seed)
	main.controller.cr = 50000
	main.controller._track_peak(main.controller.assess())
	main.loop.dock_at("mars")
	main.controller.sim_clock.pause()
	main._refresh_readouts()


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	only = args.slice(1)
	await _run()
	quit()


## Raises the crisis modal for `crisis_id` through the real deck.
func _raise_crisis(crisis_id: String) -> bool:
	var loop: M0Loop = main.loop
	var deck: CrisisDeck = loop.crisis_deck
	var keep: Array = []
	for def in deck.data["crises"]:
		if def["id"] == crisis_id:
			keep.append(def)
	deck.data["crises"] = keep
	deck.data["grace_rounds"] = 0
	deck.bags.force("crisis", true)
	main.controller.sim_clock.resume()
	for i in 4000:
		loop.advance(FRAME)
		if loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			main._refresh_readouts()
			return true
	return false


## Raises the audit modal with a crisis built from its definition (STAGED: the real deck
## only draws an audit under conditions the shot does not wait for).
func _raise_staged(crisis_id: String) -> bool:
	var loop: M0Loop = main.loop
	var deck: CrisisDeck = loop.crisis_deck
	for def in deck.data["crises"]:
		if def["id"] != crisis_id:
			continue
		var fx: Dictionary = def["effects"].duplicate()
		if str(def["kind"]) == "audit":
			fx = {"trade_cap_qty": int(fx["trade_cap_qty"]), "fee_bps": int(fx["fee_max_bps"])}
		var c: Dictionary = {"uid": 900, "id": crisis_id, "kind": str(def["kind"]), "tier": str(def["tier"]), "name": str(def["name"]),
			"text": str(def["headline"]), "band": "high", "station": "", "commodity": "", "started_round": 1, "expires_round": 4, "rounds": 3, "effects": fx}
		deck.active = [c]
		deck.awaiting_ack = [c["uid"]]
		loop._raise_crisis_if_pending()
		main._refresh_readouts()
		return loop.overlay_state == M0Loop.OVERLAY_CRISIS
	return false


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


func _run() -> void:
	if _want("summary-01-run-summary-severance"):
		await _fresh()
		await _collapse_with_barons()
		print("summary: ", main.loop.run_summary())
		await _shot("summary-01-run-summary-severance")
	if _want("summary-02-crisis-4x3-frame"):
		await _fresh()
		print("crisis raised: ", _raise_crisis("localized_shortage"))
		await _shot("summary-02-crisis-4x3-frame")
	if _want("summary-03-audit-4x3-frame"):
		await _fresh()
		print("audit raised: ", _raise_staged("antitrust_audit"))
		await _shot("summary-03-audit-4x3-frame")
	if _want("summary-04-fill-toast"):
		await _fresh()
		var loop: M0Loop = main.loop
		loop.set_tab(M0Loop.Tab.MARKET)
		main.hud.set_commodity("ORE")
		main._refresh_readouts()
		print("fill: ", loop.dispatch_action(M0Loop.ACT_SUBMIT), " toasts ", main.toasts.toasts)
		for i in 20:
			main.toasts.advance(1.0 / 60.0)
		main._refresh_readouts()
		await _shot("summary-04-fill-toast")
	if _want("summary-05-galnet-toast"):
		await _fresh()
		main.hud.post_headline_tr("HL_ARES_DECLINED", [Loc.maker_arg("ares_heavy")], "MARKET", "WARNING")  # STAGED alert
		for i in 20:
			main.toasts.advance(1.0 / 60.0)
		main._refresh_readouts()
		print("toasts: ", main.toasts.toasts)
		await _shot("summary-05-galnet-toast")
	if _want("summary-06-pseudo-130-modal"):
		await _fresh()
		Loc.set_locale(Loc.LOCALE_PSEUDO)
		main.settings.set_text_scale(1.3)
		main.apply_text_scale()
		print("audit raised: ", _raise_staged("antitrust_audit"))
		main.toasts.push(ToastTray.KIND_FILLED, "BUY 5 ORE @ 18.0")
		main._refresh_readouts()
		await _shot("summary-06-pseudo-130-modal")
	if _want("summary-07-pseudo-130-run-summary"):
		await _fresh()
		Loc.set_locale(Loc.LOCALE_PSEUDO)
		main.settings.set_text_scale(1.3)
		main.apply_text_scale()
		await _collapse_with_barons()
		await _shot("summary-07-pseudo-130-run-summary")
	# Leave the saved settings at defaults so a later run of the game does not inherit pseudo/130%.
	await _fresh()
	main._save_settings()
