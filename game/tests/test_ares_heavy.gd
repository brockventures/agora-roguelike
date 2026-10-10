extends RefCounted
## Epic 3 task 4 (part of #16, Baron Archetype AIs): Ares Heavy. Defense contract
## offers (cadence, determinism, the gamepad modal), delivery and its premium, the
## squeeze and its counterplay, the debt penalty as a consequence event under the
## lethal guard, the contract ending with a Chapter 11 filing, and save/load/continue
## equality with an unanswered offer and in the middle of a squeeze.

const FRAME: float = 1.0 / 60.0 + 0.0001
const TPR: int = 30


## A docked run with a world on a 30-tick round, starting at Mars (Ares Heavy's).
func _ctx(p_seed: int = 21, station: String = "mars") -> Dictionary:
	var rc := RunController.new(null, p_seed, null, {}, TPR)
	rc.world = Barons.for_new_run()
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at(station)
	return {"rc": rc, "hud": hud, "loop": lp, "world": rc.world}


## Ares Heavy's events only: Sol Central announces its call auctions on its own clock.
func _ares(events: Array) -> Array:
	return events.filter(func(e): return str(e.get("baron", "")) == "ares_heavy")


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


func _texts(hud: OrbitalHUD) -> Array:
	var out: Array = []
	for h in hud.galnet_headlines:
		out.append(str(h["text"]))
	return out


func _any(texts: Array, needle: String) -> bool:
	for t in texts:
		if str(t).contains(needle):
			return true
	return false


## Frames until the loop shows `overlay` (true) or the guard runs out (false); other
## overlays are answered the cheap way (crisis acknowledged, contract left alone).
func _until_overlay(lp: M0Loop, overlay: String, max_frames: int = 3000) -> bool:
	for i in max_frames:
		if lp.overlay_state == overlay:
			return true
		if lp.overlay_state == M0Loop.OVERLAY_CRISIS:
			lp.acknowledge_crisis()
		lp.advance(FRAME)
	return lp.overlay_state == overlay


## One offer, posted straight through the world step at its cadence round.
func _offer(c: Dictionary, round_num: int = 8) -> Dictionary:
	var events: Array = (c["world"] as Barons).advance_round(round_num, c["rc"])
	for e in events:
		if str(e["kind"]) == "offer":
			return e
	return {}


## An accepted contract in the world, via the model (no UI).
func _accepted(c: Dictionary, round_num: int = 8) -> Dictionary:
	var offer: Dictionary = _offer(c, round_num)
	(c["world"] as Barons).accept_offer(c["rc"])
	return offer


# --- the offer ---

func test_offers_post_on_the_cadence_and_never_before() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	for r in range(1, 8):
		if not _ares(w.advance_round(r, c["rc"])).is_empty():
			return "round %d produced an event before the first cadence round" % r
	var offer: Dictionary = _offer(c, 8)
	if offer.is_empty():
		return "no offer at round 8 (contract_every_rounds)"
	if not w.has_pending_offer() or str(w.pending_offer()["baron"]) != "ares_heavy":
		return "the offer is not pending"
	# One contract at a time: nothing new while the first waits, and none on off rounds.
	if not _ares(w.advance_round(9, c["rc"])).is_empty() or not _ares(w.advance_round(16, c["rc"])).is_empty():
		return "a second offer was posted over an unanswered one"
	return "ok"


func test_offer_is_a_pure_function_of_run_seed_and_round() -> String:
	var a := _offer(_ctx(21))
	var b := _offer(_ctx(21))
	if a != b:
		return "same seed, different offer: %s vs %s" % [str(a), str(b)]
	var seen: Dictionary = {}
	for sd in [1, 2, 3, 4, 5, 6, 7, 8]:
		var o := _offer(_ctx(sd))
		if not ["ORE", "MACHINERY"].has(str(o["commodity"])) or int(o["qty"]) < 30 or int(o["qty"]) > 60:
			return "seed %d offered %s x%d, outside the contract_qty / pipeline commodities" % [sd, o["commodity"], o["qty"]]
		seen["%s%d" % [o["commodity"], o["qty"]]] = true
		if int(o["due_round"]) != 14 or str(o["station"]) != "mars":
			return "seed %d: due round %d at %s, want 14 at mars" % [sd, o["due_round"], o["station"]]
	if seen.size() < 3:
		return "eight seeds produced only %d distinct offers" % seen.size()
	return "ok"


func test_price_is_frozen_at_the_base_price_plus_the_bid_premium() -> String:
	var c := _ctx()
	var o := _offer(c)
	var base: float = float(Transit.BASE_PRICES["mars"][o["commodity"]])
	var want: int = int(round(base * 1.15))
	if int(o["unit_px"]) != want:
		return "unit price %d, want %d (base %.1f + 15%%)" % [o["unit_px"], want, base]
	if int(o["unit_px"]) <= int(round(base)):
		return "the contract pays no premium over base"
	if int(o["total"]) != int(o["unit_px"]) * int(o["qty"]):
		return "total is not qty x unit price"
	return "ok"


func test_offer_halts_the_clock_and_a_declines_leaves_no_trace() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	var before: Dictionary = rc.world.to_dict()
	if not _until_overlay(lp, M0Loop.OVERLAY_CONTRACT):
		return "no contract modal within 3000 frames"
	if rc.get_current_round() != 8:
		return "the offer came at round %d, want 8" % rc.get_current_round()
	if lp.current_offer().is_empty():
		return "modal up but no offer"
	var ticks: int = rc.sim_clock.total_ticks
	for i in 20:
		lp.advance(FRAME)
	if rc.sim_clock.total_ticks != ticks:
		return "the clock ran behind the offer modal"
	# Other buttons do nothing behind the modal.
	if lp.dispatch_action(M0Loop.ACT_PAUSE) or lp.overlay_state != M0Loop.OVERLAY_CONTRACT:
		return "a non-answer button got through the modal"
	if not lp.dispatch_action(M0Loop.ACT_CANCEL):
		return "B did not decline"
	if lp.overlay_state != M0Loop.OVERLAY_NONE or rc.sim_clock.paused:
		return "declining did not lower the modal and resume the clock"
	if rc.world.has_pending_offer() or not rc.world.open_contract().is_empty():
		return "a declined offer is still on the books"
	# No trace: the world state is what it was before any offer existed.
	if RunSave.canonical(rc.world.to_dict()) != RunSave.canonical(before):
		return "a declined offer changed the saved world state"
	var st: BaronState = rc.world.state("ares_heavy")
	if not st.scratch.is_empty():
		return "a declined offer left scratch state: %s" % str(st.scratch)
	if not _any(_texts(c["hud"]), "posts a defense contract") or not _any(_texts(c["hud"]), "defense contract declined"):
		return "GalNet lines missing: %s" % str(_texts(c["hud"]))
	return "ok"


func test_a_accepts_and_the_contract_is_open() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	if not _until_overlay(lp, M0Loop.OVERLAY_CONTRACT):
		return "no contract modal"
	var offer: Dictionary = lp.current_offer()
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "A did not accept"
	var open: Dictionary = lp.open_contract()
	if open.is_empty() or str(open["state"]) != "accepted" or int(open["qty"]) != int(offer["qty"]):
		return "no open contract after accepting: %s" % str(open)
	if lp.overlay_state != M0Loop.OVERLAY_NONE or c["rc"].sim_clock.paused:
		return "accepting did not resume the clock"
	if not _any(_texts(c["hud"]), "defense contract taken"):
		return "no acceptance headline"
	return "ok"


func test_a_crisis_in_the_same_round_goes_first_then_the_offer() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	# Stage a pending crisis, then reach the offer round with the crisis modal up.
	if not _until_overlay(lp, M0Loop.OVERLAY_CONTRACT):
		return "no contract modal"
	lp.decline_contract()
	var ca: Dictionary = {"uid": 901, "id": "x", "kind": "shortage", "tier": "low", "name": "x", "text": "x", "band": "low", "station": "mars", "commodity": "ORE", "started_round": 8, "expires_round": 12, "rounds": 4, "effects": {"depth_bps": 5000}}
	rc.crisis_deck.active = [ca]
	rc.crisis_deck.awaiting_ack = [901]
	lp.overlay_state = M0Loop.OVERLAY_CRISIS
	rc.sim_clock.pause()
	rc.world.state("ares_heavy").scratch["contract"] = {"state": "offered", "id": 8, "commodity": "ORE", "qty": 40, "unit_px": 19, "offered_round": 8, "due_round": 14}
	if lp.dispatch_action(M0Loop.ACT_CANCEL):
		return "B got through the crisis modal"
	lp.acknowledge_crisis()
	if lp.overlay_state != M0Loop.OVERLAY_CONTRACT or not rc.sim_clock.paused:
		return "the offer did not follow the crisis (overlay '%s', paused %s)" % [lp.overlay_state, str(rc.sim_clock.paused)]
	return "ok"


# --- delivery ---

func test_delivery_pays_the_premium_and_takes_the_stock() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var o := _accepted(c)
	var com: String = str(o["commodity"])
	rc.cargo = {com: int(o["qty"]) + 5}
	var cr: int = rc.cr
	var treasury: int = w.state("ares_heavy").treasury_cr
	var done: Dictionary = w.try_deliver(rc)
	if done.is_empty():
		return "docked at Mars with the stock, nothing was delivered"
	if int(done["paid"]) != int(o["qty"]) * int(o["unit_px"]):
		return "paid %d, want %d" % [done["paid"], int(o["qty"]) * int(o["unit_px"])]
	if rc.cr != cr + int(done["paid"]):
		return "the player was not paid"
	if int(rc.cargo.get(com, 0)) != 5:
		return "cargo %s after delivery, want 5" % str(rc.cargo)
	if w.state("ares_heavy").treasury_cr != treasury - int(done["paid"]):
		return "Ares did not pay from its treasury"
	if int(w.state("ares_heavy").inventory[com]) < int(o["qty"]):
		return "the goods did not reach Ares's inventory"
	if not w.open_contract().is_empty():
		return "the contract is still open after delivery"
	# The profit is real: the payout beats the base cost of the stock.
	if int(done["paid"]) <= int(round(float(Transit.BASE_PRICES["mars"][com]) * int(o["qty"]))):
		return "delivery paid no more than base value"
	return "ok"


func test_accepting_with_the_stock_in_hand_at_mars_pays_at_once() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	rc.cargo = {"ORE": 60, "MACHINERY": 60}
	var cr: int = rc.cr
	if not _until_overlay(lp, M0Loop.OVERLAY_CONTRACT):
		return "no contract modal"
	lp.dispatch_action(M0Loop.ACT_SUBMIT)
	if not lp.open_contract().is_empty() or rc.cr <= cr:
		return "the prepared player was not paid on accepting (cr %d -> %d)" % [cr, rc.cr]
	if not _any(_texts(c["hud"]), "delivered"):
		return "no delivered headline"
	return "ok"


func test_arriving_at_mars_with_the_stock_delivers() -> String:
	var c := _ctx(21, "earth")
	var rc: RunController = c["rc"]
	var lp: M0Loop = c["loop"]
	var w: Barons = c["world"]
	rc.cr = 5000
	var o := _accepted(c)
	rc.cargo = {str(o["commodity"]): int(o["qty"])}
	if not bool(rc.depart("mars")["ok"]):
		return "departure refused"
	var cr: int = rc.cr
	for i in 800:
		if not rc.is_in_transit():
			break
		if lp.overlay_state == M0Loop.OVERLAY_CRISIS:
			lp.acknowledge_crisis()
		lp.advance(FRAME)
	if rc.docked_at != "mars" or not w.open_contract().is_empty():
		return "docked '%s', open contract %s" % [rc.docked_at, str(w.open_contract())]
	if rc.cr < cr + int(o["total"]) - 15 - 100:
		return "arrival delivery did not pay (cr %d -> %d)" % [cr, rc.cr]
	return "ok"


func test_a_ship_elsewhere_or_short_does_not_deliver() -> String:
	var c := _ctx(21, "earth")
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var o := _accepted(c)
	rc.cargo = {str(o["commodity"]): int(o["qty"])}
	if not w.try_deliver(rc).is_empty():
		return "delivered from Earth"
	rc.docked_at = "mars"
	rc.cargo = {str(o["commodity"]): int(o["qty"]) - 1}
	if not w.try_deliver(rc).is_empty():
		return "delivered one unit short"
	return "ok"


# --- the squeeze ---

func test_squeeze_starts_in_the_window_and_ramps_to_the_cap() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	_accepted(c)
	rc.docked_at = "earth"
	for r in range(9, 11):
		w.advance_round(r, rc)
		if not w.market_mods().filter(func(m): return int(m.get("price_bps", 0)) != 0).is_empty():
			return "squeezed at round %d, before the %d-round window" % [r, 3]
	var want := {11: 1000, 12: 2000, 13: 3000}
	for r in want:
		var ev: Array = w.advance_round(r, rc)
		var sq: Array = w.market_mods().filter(func(m): return int(m.get("price_bps", 0)) != 0)
		if sq.size() != 1 or int(sq[0]["price_bps"]) != want[r] or int(sq[0]["depth_bps"]) != 3000 or str(sq[0]["station"]) != "mars":
			return "round %d squeeze mod is %s, want +%d bps and depth 3000 at mars" % [r, str(sq), want[r]]
		if ev.is_empty() or str(ev[0]["kind"]) != "squeeze":
			return "round %d: no squeeze event" % r
	return "ok"


func test_squeeze_price_is_capped() -> String:
	var data: Dictionary = Barons.load_data()
	data["barons"][0]["params"]["squeeze_window_rounds"] = 6
	data["barons"][0]["params"]["contract_deadline_rounds"] = 9
	var rc := RunController.new(null, 21, null, {}, TPR)
	rc.world = Barons.new(data)
	rc.docked_at = "earth"
	var c := {"rc": rc, "world": rc.world}
	_accepted(c)
	var last: int = 0
	for r in range(9, 17):
		rc.world.advance_round(r, rc)
		var sq: Array = rc.world.market_mods().filter(func(m): return int(m.get("price_bps", 0)) != 0)
		if not sq.is_empty():
			last = int(sq[0]["price_bps"])
			if last > 5000:
				return "round %d price %d bps exceeds squeeze_price_bps_max 5000" % [r, last]
	if last != 5000:
		return "the squeeze never reached the cap (last %d)" % last
	return "ok"


func test_holding_the_stock_means_no_squeeze() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var o := _accepted(c)
	rc.docked_at = "earth"
	rc.cargo = {str(o["commodity"]): int(o["qty"])}
	for r in range(9, 14):
		w.advance_round(r, rc)
		if not w.market_mods().filter(func(m): return int(m.get("price_bps", 0)) != 0).is_empty():
			return "round %d squeezed a player who holds the whole quantity" % r
	# Selling it back inside the window starts the squeeze; re-stocking ends it and resets the ramp.
	rc.cargo = {}
	w.advance_round(11, rc)
	if w.squeeze_on("mars", str(o["commodity"])).is_empty():
		return "no squeeze after the stock was sold"
	rc.cargo = {str(o["commodity"]): int(o["qty"])}
	w.advance_round(12, rc)
	if not w.squeeze_on("mars", str(o["commodity"])).is_empty():
		return "the squeeze survived the player re-stocking"
	rc.cargo = {}
	w.advance_round(13, rc)
	if int(w.squeeze_on("mars", str(o["commodity"]))["price_bps"]) != 1000:
		return "the ramp did not restart from +10% after a covered round"
	return "ok"


func test_squeeze_reaches_the_book_and_the_board_tag() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	if not _until_overlay(lp, M0Loop.OVERLAY_CONTRACT):
		return "no contract modal"
	var com: String = str(lp.current_offer()["commodity"])
	lp.dispatch_action(M0Loop.ACT_SUBMIT)
	# Fly nowhere, hold nothing: round 11 opens the window.
	var plain := StationMarket.new()
	plain.set_world(Barons.new())
	var before: Dictionary = plain.ladder("mars", com, 1)
	var guard: int = 600
	while lp.squeeze_tag("mars", com) == "" and guard > 0:
		guard -= 1
		if lp.overlay_state == M0Loop.OVERLAY_CRISIS:
			lp.acknowledge_crisis()
		lp.advance(FRAME)
	if rc.get_current_round() != 11:
		return "the squeeze showed at round %d, want 11" % rc.get_current_round()
	var after: Dictionary = lp.market.ladder("mars", com, 5)
	var calm: Dictionary = plain.ladder("mars", com, 5)
	if float(after["best_ask"]) <= float(calm["best_ask"]):
		return "best ask %.1f did not rise over %.1f" % [after["best_ask"], calm["best_ask"]]
	var depth_after: int = 0
	var depth_calm: int = 0
	for row in after["asks"]:
		depth_after += int(row["quantity"])
	for row in calm["asks"]:
		depth_calm += int(row["quantity"])
	if depth_after >= depth_calm / 2:
		return "ask depth %d is not thin against %d" % [depth_after, depth_calm]
	if lp.squeeze_tag("mars", com) != "SQUEEZE +10%":
		return "tag is '%s'" % lp.squeeze_tag("mars", com)
	if before.is_empty() or not _any(_texts(c["hud"]), "squeezes ARCADIA FOUNDRIES"):
		return "no squeeze headline: %s" % str(_texts(c["hud"]))
	# The mods are in world state and survive replenish() every round: re-emitted, not edited into a book.
	lp.market.replenish()
	if float(lp.market.ladder("mars", com, 1)["best_ask"]) != float(after["best_ask"]):
		return "the squeeze did not survive a replenish"
	return "ok"


# --- the debt penalty and the lethal guard ---

func test_a_missed_contract_adds_the_penalty_to_principal_as_a_consequence() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var o := _accepted(c)
	rc.docked_at = "earth"
	for r in range(9, 14):
		w.advance_round(r, rc)
	var debt: int = rc.doomsday.principal_debt
	var ev: Array = w.advance_round(14, rc)
	var miss: Dictionary = {}
	for e in ev:
		if str(e["kind"]) == "missed":
			miss = e
	if miss.is_empty():
		return "no missed event at the due round"
	var want: int = int(o["qty"]) * int(o["unit_px"]) * 2000 / 10000
	if int(miss["penalty"]) != want or rc.doomsday.principal_debt != debt + want:
		return "penalty %d, principal %d -> %d, want +%d" % [miss["penalty"], debt, rc.doomsday.principal_debt, want]
	if str(miss["origin"]) != "consequence":
		return "a missed contract is not tagged a consequence event: %s" % str(miss["origin"])
	if not w.open_contract().is_empty() or not w.market_mods().filter(func(m): return int(m.get("price_bps", 0)) != 0).is_empty():
		return "the contract or squeeze outlived the miss"
	if int(w.state("ares_heavy").scratch.get("missed", 0)) != 1:
		return "the miss was not counted"
	return "ok"


func test_the_penalty_that_tips_the_corp_over_forces_chapter_11() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	if not _until_overlay(lp, M0Loop.OVERLAY_CONTRACT):
		return "no contract modal"
	lp.dispatch_action(M0Loop.ACT_SUBMIT)
	var guard: int = 2000
	# Step to the tick before the due round, then leave the corp solvent by less than the penalty.
	while rc.sim_clock.total_ticks < 14 * TPR - 1 and guard > 0:
		guard -= 1
		if lp.overlay_state == M0Loop.OVERLAY_CRISIS:
			lp.acknowledge_crisis()
		lp.advance(FRAME)
	rc.cr = 20000
	var a: Dictionary = rc.assess()
	rc.doomsday.principal_debt += int(a["liquidation_value"]) - int(a["total_debt"]) - 30
	if bool(rc.assess()["insolvent"]):
		return "setup left the corp insolvent"
	while not rc.pending_bankruptcy and guard > 0:
		guard -= 1
		lp.advance(FRAME)
	if not rc.pending_bankruptcy or lp.overlay_state != M0Loop.OVERLAY_CHAPTER_11:
		return "the penalty did not force Chapter 11 (pending %s, overlay '%s')" % [str(rc.pending_bankruptcy), lp.overlay_state]
	var texts: Array = _texts(c["hud"])
	if not _any(texts, "defense contract defaulted") or not _any(texts, "leaves you insolvent"):
		return "missing default / retaliation headlines: %s" % str(texts)
	return "ok"


func test_a_random_event_is_clamped_and_never_forces_chapter_11() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	rc.cr = 10000
	var nw: int = rc.net_worth()
	var res: Dictionary = w.penalize(rc, 1000000, "random")
	if not bool(res["clamped"]) or bool(res["forced_ch11"]) or bool(rc.assess()["insolvent"]):
		return "a random fine broke the guard: %s" % str(res)
	if rc.net_worth() < nw - nw * w.random_max_loss_bps() / 10000:
		return "net worth fell to %d from %d, past the %d bps allowance" % [rc.net_worth(), nw, w.random_max_loss_bps()]
	if str(res["origin"]) != "random":
		return "origin '%s'" % res["origin"]
	# An already insolvent corp takes nothing more from a random event.
	rc.doomsday.principal_debt += 10000000
	var again: Dictionary = w.penalize(rc, 500, "random")
	if int(again["applied"]) != 0:
		return "a random fine landed on an insolvent corp: %s" % str(again)
	return "ok"


func test_a_consequence_is_uncapped_and_says_when_it_forced_chapter_11() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	rc.cr = 10000
	var res: Dictionary = w.penalize(rc, 1000000, "consequence")
	if bool(res["clamped"]) or int(res["applied"]) != 1000000 or not bool(res["forced_ch11"]) or not bool(rc.assess()["insolvent"]):
		return "a consequence event was held back or did not report the filing: %s" % str(res)
	var ticks: int = rc.doomsday.ticks_remaining
	w.penalize(rc, 5, "consequence")
	if rc.doomsday.ticks_remaining != ticks:
		return "a baron fine touched the doomsday ticks"
	return "ok"


func test_add_principal_keeps_interest_compounding_on_the_new_debt() -> String:
	var d := DoomsdayClock.new()
	d.add_principal(1000)
	if d.principal_debt != 1000 or d._compounding_base != 1000:
		return "principal %d base %d after a 1000 CR fine" % [d.principal_debt, d._compounding_base]
	if d.add_principal(-5) != 0 or d.principal_debt != 1000:
		return "a negative fine changed the debt"
	if d.add_principal(DoomsdayClock.MAX_CR) + 1000 != DoomsdayClock.MAX_CR:
		return "the principal did not saturate at MAX_CR"
	return "ok"


# --- the failed corp's contract ends with it ---

func test_filing_chapter_11_cancels_the_open_contract_and_squeeze() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var lp: M0Loop = c["loop"]
	_accepted(c)
	rc.docked_at = "earth"
	w.advance_round(11, rc)
	lp.market.set_world_mods(w.market_mods())
	if w.open_contract().is_empty() or lp.market.world_mods.filter(func(m): return int(m.get("price_bps", 0)) != 0).is_empty():
		return "setup: no contract / squeeze to cancel"
	rc.cr = 0
	rc.doomsday.principal_debt = 100000
	if rc.file_bankruptcy().is_empty():
		return "filing refused"
	if not w.open_contract().is_empty() or w.has_pending_offer():
		return "the dead corp's contract survived the filing"
	if not lp.market.world_mods.filter(func(m): return int(m.get("price_bps", 0)) != 0).is_empty():
		return "the squeeze mod survived the filing"
	return "ok"


func test_a_held_baron_posts_no_contract_and_no_squeeze() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	w.state("ares_heavy").holder = "player"
	if not _ares(w.advance_round(8, c["rc"])).is_empty() or w.has_pending_offer():
		return "a held baron still offered its holder a contract"
	return "ok"


func test_no_world_means_none_of_it() -> String:
	var rc := RunController.new(null, 21, null, {}, TPR)
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	for i in 600:
		lp.advance(FRAME)
	if lp.overlay_state == M0Loop.OVERLAY_CONTRACT or not lp.current_offer().is_empty() or lp.squeeze_tag("mars", "ORE") != "":
		return "a world-less run grew a contract"
	return "ok"


# --- save / load / continue ---

## Plays `frames` (or until `stop` is true), answering offers: accept.
func _play(s: Replay.Session, frames: int, stop: Callable = Callable()) -> int:
	var used: int = 0
	for i in frames:
		if s.loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			s.loop.dispatch_action(M0Loop.ACT_SUBMIT)
		elif s.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			s.loop.acknowledge_crisis()
		s.advance()
		used += 1
		if stop.is_valid() and bool(stop.call()):
			break
	return used


func _answer(lp: M0Loop) -> void:
	if lp.overlay_state == M0Loop.OVERLAY_CONTRACT:
		lp.dispatch_action(M0Loop.ACT_SUBMIT)
	elif lp.overlay_state == M0Loop.OVERLAY_CRISIS:
		lp.acknowledge_crisis()


## Restores `cap` into a fresh loop and returns {rc, loop, market, bags}.
func _resume(cap: Dictionary) -> Dictionary:
	var r: Dictionary = RunSave.restore(cap.duplicate(true))
	var rc: RunController = r["controller"]
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.set_market(r["market"])
	lp.sync_hud_to_ship()
	hud.set_station(rc.docked_at)
	return {"rc": rc, "loop": lp, "market": r["market"], "bags": r["bags"]}


func _continue_equal(p_seed: int, stop_on_offer: bool) -> String:
	var total: int = 900
	var whole := Replay.Session.new(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	whole.loop.dock_at("mars")
	_play(whole, total)
	var split := Replay.Session.new(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	split.loop.dock_at("mars")
	var stop: Callable
	if stop_on_offer:
		stop = func(): return split.loop.overlay_state == M0Loop.OVERLAY_CONTRACT
	else:
		stop = func(): return not split.controller.world.squeeze_on("mars", "ORE").is_empty() or not split.controller.world.squeeze_on("mars", "MACHINERY").is_empty()
	var used: int = _play(split, total, stop)
	if used >= total:
		return "seed %d: never reached the split point" % p_seed
	var cap: Dictionary = RunSave.capture(split.controller, split.loop.market, split.bags)
	var via_json: Dictionary = RunSave.restore(_json(cap))
	if not bool(via_json["ok"]) or RunSave.state_hash(via_json["controller"], via_json["market"], via_json["bags"]) != split.state_hash():
		return "seed %d: the save file round trip changed the hash" % p_seed
	var rjson: RunController = via_json["controller"]
	if str(rjson.world.market_mods()) != str(split.controller.world.market_mods()):
		return "seed %d: the restored world emits different mods" % p_seed
	var back := _resume(cap)
	var lp: M0Loop = back["loop"]
	var rc: RunController = back["rc"]
	if stop_on_offer and (lp.overlay_state != M0Loop.OVERLAY_CONTRACT or lp.current_offer().is_empty()):
		return "seed %d: the unanswered offer did not come back as a modal (overlay '%s')" % [p_seed, lp.overlay_state]
	if not stop_on_offer and lp.squeeze_tag("mars", "ORE") + lp.squeeze_tag("mars", "MACHINERY") == "":
		return "seed %d: the squeeze did not come back" % p_seed
	for i in total - used:
		_answer(lp)
		lp.advance(Replay.DEFAULT_FRAME_DELTA)
	if RunSave.state_hash(rc, lp.market, back["bags"]) != whole.state_hash():
		return "seed %d: save/load/continue diverged from the uninterrupted run" % p_seed
	return "ok"


func test_continue_equals_uninterrupted_with_an_unanswered_offer() -> String:
	for sd in [84, 7]:
		var r := _continue_equal(sd, true)
		if r != "ok":
			return r
	return "ok"


func test_continue_equals_uninterrupted_in_the_middle_of_a_squeeze() -> String:
	for sd in [84, 7]:
		var r := _continue_equal(sd, false)
		if r != "ok":
			return r
	return "ok"


func test_two_runs_of_the_same_seed_hash_alike_and_offers_move_the_hash() -> String:
	var a := Replay.Session.new(84, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	var b := Replay.Session.new(84, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	a.loop.dock_at("mars")
	b.loop.dock_at("mars")
	_play(a, 700)
	_play(b, 700)
	if a.state_hash() != b.state_hash():
		return "the same seed hashed differently"
	if a.controller.world.state("ares_heavy").scratch.is_empty():
		return "700 frames at 30 ticks a round produced no contract state"
	return "ok"
