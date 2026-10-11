extends SceneTree
## Screenshots for Epic 3 task 7 (part of #17, Hostile Takeover & Insolvency): the takeover
## core. Nothing in play raises a baron's debt before task 8's levers, so the ONE staged step
## is that Ares Heavy is given debt past its liquidation value (Barons.add_debt, the door
## the levers will use) and, for the bankruptcy, that two stand-in buyers take the lots a
## rival fleet will (Takeover._transfer). Everything else is the real loop: the
## round boundary opens the distress auction, the player buys the lot with the m0_shares
## action at Mars, the 501st share takes the baron, the held baron's market shows the
## pipeline as the player's, and a second baron runs out its six insolvent rounds.
## Run under xvfb with the real renderer, as shots_epic3_sol.gd does:
##   xvfb-run -a -s "-screen 0 1280x800x24" godot --path game --rendering-driver opengl3 \
##     --resolution 1280x800 -s res://tools/shots_epic3_takeover.gd -- <out dir> <file prefix> [auction]
## With the third argument `auction` it plays the #134 sealed-bid auction scenes instead and
## saves auction-*.png (no prefix): the HUD with stakes and the last clearing price, a won
## auction, a recapture tender, and a fleet going bankrupt. STAGED there: Ares's debt, and
## (recapture) Ember Haulage's holding of Ares, and (bankruptcy) a fleet's cash; the bids, the
## clearing, the tender, the insolvency count and the liquidation are the real loop and code.
const FRAME: float = 1.0 / 60.0 + 0.0001
var main: Node
var out_dir: String = "/tmp/"
var prefix: String = ""


func _shot(name: String, frames: int = 5) -> void:
	for i in frames:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(out_dir + prefix + name + ".png")
	print("shot ", prefix + name, " ", img.get_size())


func _fresh() -> void:
	Palette.set_current(Palette.DEFAULT)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	main.settings.reset_defaults()
	main.settings.set_text_scale(1.0)
	main.start_new_run(84)
	main.controller.cr = 50000
	main._refresh_readouts()


func _trigger(axis: int) -> void:
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = 1.0
	main.handle_input(e)
	e = InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = 0.0
	main.handle_input(e)


func _btn(index: int) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = index
	e.pressed = true
	return e


## Plays the real loop until `done` (a Callable returning bool) or the guard runs out.
func _play_until(done: Callable, max_frames: int = 40000) -> bool:
	var loop: M0Loop = main.loop
	for i in max_frames:
		if done.call():
			return true
		if loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			loop.acknowledge_crisis()
		elif loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			loop.decline_contract()  # Ares's round-8 offer is not what this run is about
		elif loop.overlay_state == M0Loop.OVERLAY_NONE and main.controller.sim_clock.paused and not main.controller.pending_bankruptcy:
			main.controller.sim_clock.resume()  # a doomsday stage change auto-pauses; the player presses Start
		loop.advance(FRAME)
	return bool(done.call())


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].rstrip("/") + "/"
	if args.size() > 1:
		prefix = args[1]
	if args.size() > 2 and args[2] == "auction":
		await _run_auction()
	else:
		await _run()
	quit()


func _view(station: String, com: String, tab: M0Loop.Tab = M0Loop.Tab.MARKET) -> void:
	main.controller.sim_clock.pause()
	main.loop.set_tab(tab)
	if main.hud.active_station != station:
		main.hud.set_station(station)  # re-selecting the same station posts its MOVE lines again
	if main.hud.active_commodity != com:
		main.hud.set_commodity(com)
	main._refresh_readouts()


## Plays on to the next round boundary (the world step has run when this returns).
func _next_round() -> void:
	var rc: RunController = main.controller
	rc.sim_clock.resume()
	var r0: int = rc.get_current_round()
	_play_until(func(): return rc.get_current_round() > r0)
	if main.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
		main.loop.acknowledge_crisis()
	rc.sim_clock.pause()


func _run() -> void:
	await _fresh()
	var loop: M0Loop = main.loop
	var rc: RunController = main.controller
	var w: Barons = rc.world
	rc.sim_clock.pause()
	# 1. STAGED: Ares Heavy falls $5,000 past its liquidation value. The round boundary does the rest.
	w.add_debt("ares_heavy", int(w.assess_baron("ares_heavy")["liquidation_value"]) + 5000)
	_next_round()
	print("offer: ", w.distress_at("mars"), " strain ", w.state("ares_heavy").strain)
	_view("mars", "ORE")
	await _shot("distress-offer")
	# 2. The player buys the lot with the shares action.
	print("bought: ", loop.dispatch_action(M0Loop.ACT_SHARES), " shares ", w.state("ares_heavy").shares)
	_view("mars", "ORE")
	await _shot("buying-shares")
	# 3. One lot a round until the 501st share.
	var guard: int = 0
	while w.state("ares_heavy").holder != "player" and guard < 12:
		_next_round()
		if loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			loop.decline_contract()
		for i in 12:
			await process_frame  # the round's own ticker lines land before the purchase
		loop.dispatch_action(M0Loop.ACT_SHARES)
		guard += 1
	print("holder: ", w.state("ares_heavy").holder, " shares ", w.state("ares_heavy").shares, " cr ", rc.cr, " principal ", rc.doomsday.principal_debt)
	_view("mars", "ORE", M0Loop.Tab.MAP)
	await _shot("takeover")
	# 4. The held baron's market, after a round of rent.
	var cr0: int = rc.cr
	_next_round()
	if loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
		loop.decline_contract()
	print("rent: ", rc.cr - cr0, " (", w.rent_of("ares_heavy"), ")")
	_view("mars", "ORE")
	await _shot("held-market")
	# 5. STAGED: Sol Central is given the same debt, and two stand-in buyers take each lot a
	# rival fleet will; six insolvent rounds with no treasury shares left settle it.
	w.add_debt("sol_central", int(w.assess_baron("sol_central")["liquidation_value"]) + 5000)
	var n: int = 0
	while w.state("sol_central").strain < 99 and n < 30:
		_next_round()
		if loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			loop.decline_contract()
		var o: Dictionary = Takeover.offer(w, "sol_central")
		if not o.is_empty():
			Takeover._transfer(w, "sol_central", "rival_a" if n % 2 == 0 else "rival_b", int(o["qty"]), int(o["px"]), rc)
		n += 1
		if w.state("sol_central").strain == 0 and w.state("sol_central").treasury_shares > 0 and n > 3:
			break
	print("sol after ", n, " rounds: ", w.state("sol_central").to_dict())
	_view("mars", "ORE", M0Loop.Tab.MAP)
	await _shot("bankruptcy")
	print("headlines: ", main.hud.galnet_headlines.map(func(h): return h["text"]))


# --- #134: the sealed-bid auction scenes ---

func _free_main() -> void:
	if main != null:
		main.queue_free()
		await process_frame
		main = null


func _run_auction() -> void:
	await _fresh()
	var loop: M0Loop = main.loop
	var rc: RunController = main.controller
	var w: Barons = rc.world
	rc.cr = 400000
	rc.sim_clock.pause()
	w.data["takeover"]["auction_cap"] = 100
	# 1. STAGED: Ares Heavy falls past its liquidation value. Two rounds on, the fleets that
	# trade at Mars are bidding; one lot clears with no bid from the player.
	w.add_debt("ares_heavy", int(w.assess_baron("ares_heavy")["liquidation_value"]) + 400000)
	var guard: int = 0
	while w.state("ares_heavy").scratch.get("last_clear", null) == null and guard < 10:
		_next_round()
		if loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			loop.decline_contract()
		guard += 1
	print("last clear: ", w.state("ares_heavy").scratch.get("last_clear", {}), " stakes ", w.state("ares_heavy").shares, " lot ", w.distress_at("mars"))
	# 2. The player bids at their own value (the shares key) for the standing lot.
	for i in 12:
		await process_frame
	print("bid: ", loop.dispatch_action(M0Loop.ACT_SHARES), " ", Takeover.player_bid(w, "ares_heavy"))
	_view("mars", "ORE")
	await _shot("auction-hud")
	# 3. Pressing the key again raises the bid until it beats every fleet's value; the lot then
	# clears at the boundary and the winner pays the uniform price.
	var top: int = 0
	for b in Rivals.bids(w, "ares_heavy", rc.get_current_round(), 1, 100, rc):
		top = maxi(top, int(b["max_price"]))
	var presses: int = 0
	while int(Takeover.player_bid(w, "ares_heavy").get("px", 0)) <= top and presses < 30:
		loop.dispatch_action(M0Loop.ACT_SHARES)
		presses += 1
	print("raised ", presses, " times to ", Takeover.player_bid(w, "ares_heavy"), " over the fleets' ", top)
	var held0: int = Takeover.shares_of(w, "ares_heavy", "player")
	_next_round()
	if loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
		loop.decline_contract()
	print("won: held ", held0, " -> ", Takeover.shares_of(w, "ares_heavy", "player"), " clear ", w.state("ares_heavy").scratch.get("last_clear", {}))
	_view("mars", "ORE")
	await _shot("auction-won")
	await _free_main()
	# 4. STAGED: Ember Haulage holds Ares (501 shares). The shares key tenders to buy it back.
	await _fresh()
	loop = main.loop
	rc = main.controller
	w = rc.world
	rc.cr = 400000
	rc.sim_clock.pause()
	var s: BaronState = w.state("ares_heavy")
	s.treasury_shares = 0
	s.shares["ember_haulage"] = 501
	s.holder = "ember_haulage"
	for i in 12:
		await process_frame
	_view("mars", "ORE")
	await _shot("auction-recapture-ask")
	var cr_before: int = rc.cr
	print("recapture: ", loop.dispatch_action(M0Loop.ACT_SHARES), " holder ", s.holder, " paid ", cr_before - rc.cr)
	_view("mars", "ORE")
	await _shot("auction-recapture")
	await _free_main()
	# 5. STAGED: Ember Haulage is out of cash against its debt. Real rounds count it down and
	# liquidate it; its shares become a forced lot.
	await _fresh()
	loop = main.loop
	rc = main.controller
	w = rc.world
	rc.cr = 400000
	rc.sim_clock.pause()
	w.state("ares_heavy").shares["ember_haulage"] = 150
	w.rival("ember_haulage").cr = 500
	w.rival("ember_haulage").cargo = {}
	var n: int = 0
	while not w.rival("ember_haulage").gone and n < 12:
		_next_round()
		if loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			loop.decline_contract()
		if w.rival("ember_haulage").strain == 2:
			_view("mars", "ORE")
			await _shot("auction-fleet-strain")
		w.rival("ember_haulage").cr = mini(w.rival("ember_haulage").cr, 500)  # keep it broke: nothing it trades rescues it
		n += 1
	print("ember gone after ", n, " rounds; forced ", w.state("ares_heavy").scratch.get("forced", 0))
	for i in 12:
		await process_frame
	_view("mars", "ORE")
	await _shot("auction-fleet-bankrupt")
	print("headlines: ", main.hud.galnet_headlines.map(func(h): return h["text"]))
