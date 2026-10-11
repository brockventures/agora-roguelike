extends SceneTree
## Screenshots for encounter deck card art integration (#73 / PR #170).
## Shows the in-game crisis card with the antitrust audit art:
## 1. Normal size (100% text scale, EN locale) -> 160x120 card plate.
## 2. 130% pseudo-locale (130% text scale, PSEUDO locale) -> 84 px tall card plate.
##
## Run under xvfb:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_card_art.gd -- <out dir>
const FRAME: float = 1.0 / 60.0 + 0.0001
var main: Node
var out_dir: String = "/workspace/agora-roguelike/docs/screenshots/card_art/"

func _shot(name: String) -> void:
	for i in 6:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	var path: String = out_dir + name + ".png"
	var err: Error = img.save_png(path)
	print("shot ", name, " ", img.get_size(), " loc=", Loc.current(), " scale=", main.settings.text_scale, " err=", err, " path=", path)

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

func _stage_antitrust_crisis() -> void:
	var loop: M0Loop = main.loop
	var deck: CrisisDeck = loop.crisis_deck
	for def in deck.data["crises"]:
		if def["id"] != "antitrust_audit":
			continue
		var fx: Dictionary = def["effects"].duplicate()
		fx = {"trade_cap_qty": int(fx["trade_cap_qty"]), "fee_bps": int(fx["fee_max_bps"])}
		var c: Dictionary = {
			"uid": 900,
			"id": "antitrust_audit",
			"kind": str(def["kind"]),
			"tier": str(def["tier"]),
			"name": str(def["name"]),
			"text": str(def["headline"]),
			"band": "mid",
			"station": "",
			"commodity": "",
			"started_round": 1,
			"expires_round": 4,
			"rounds": 3,
			"effects": fx
		}
		deck.active = [c]
		# Ensure modal overlay is dismissed so the card is visible on HUD
		loop.overlay_state = M0Loop.OVERLAY_NONE
		main._refresh_readouts()
		return

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	await _run()
	quit()

func _run() -> void:
	# 1. Normal size: 100% scale, EN locale
	await _fresh()
	_stage_antitrust_crisis()
	await _shot("card-art-01-antitrust-audit-normal")

	# 2. 130% pseudo-locale: 130% scale, PSEUDO locale
	await _fresh()
	Loc.set_locale(Loc.LOCALE_PSEUDO)
	main.settings.set_locale(Loc.LOCALE_PSEUDO)
	main.settings.set_text_scale(1.3)
	main.apply_text_scale()
	_stage_antitrust_crisis()
	await _shot("card-art-02-antitrust-audit-pseudo-130")

	# Cleanup: restore defaults
	await _fresh()
	main._save_settings()
