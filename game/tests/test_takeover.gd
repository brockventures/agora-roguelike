extends RefCounted
## Epic 3 task 7 (part of #17, Hostile Takeover & Insolvency): the takeover core.
## The share float and the distress auction, baron insolvency through Chapter11.assess,
## bankruptcy and settlement (haircut liquidation, pro rata to claims, largest claim
## holder, ties by sorted id), the takeover at 501, what a held baron does and pays,
## forfeit on a Chapter 11 filing, Ryan's rule (no random event forces Chapter 11),
## the UI path, and save/load/continue equality (seeds 84 and 7) through a takeover.

const FRAME: float = 1.0 / 60.0 + 0.0001
const TPR: int = 30
const ARES: String = "ares_heavy"
const TITAN: String = "titan_cryo_hydro"
const SOL: String = "sol_central"


## A docked run with a world on a 30-tick round, starting at Mars (Ares Heavy's).
func _ctx(p_seed: int = 21, cr: int = 100000, fleets: bool = false) -> Dictionary:
	var rc := RunController.new(null, p_seed, null, {}, TPR)
	rc.world = Barons.for_new_run()
	if not fleets:
		rc.world.rivals.clear()  # most tests are not about the fleets; the _with_fleets ones keep them ON
	rc.cr = cr
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("mars")
	return {"rc": rc, "hud": hud, "loop": lp, "world": rc.world, "market": lp.market}


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


## The round boundary the way M0Loop runs it. All events (every baron's).
func _boundary(c: Dictionary, r: int) -> Array:
	var w: Barons = c["world"]
	var m: StationMarket = c["market"]
	(c["rc"] as RunController).sim_clock.total_ticks = r * TPR
	var ev: Array = w.advance_round(r, c["rc"], m)
	m.set_world_mods(w.market_mods())
	m.replenish()
	return ev


func _kinds(events: Array, baron: String = "") -> Array:
	var out: Array = []
	for e in events:
		if baron == "" or str(e.get("baron", "")) == baron:
			out.append(str(e["kind"]))
	return out


## Places the player's bid on the standing Mars lot and runs boundary `r`, where it clears.
func _win(c: Dictionary, r: int, n: int = 100, px: int = 50) -> Array:
	(c["world"] as Barons).submit_bid(c["rc"], "mars", n, px)
	return _boundary(c, r)


## A non-player stand-in takes `n` shares of the standing lot at its reserve (outside the auction).
func _stand_in(w: Barons, id: String, buyer: String, n: int, rc: RunController) -> void:
	var o: Dictionary = Takeover.offer(w, id)
	if not o.is_empty():
		Takeover._transfer(w, id, buyer, mini(n, int(o["qty"])), int(o["px"]), rc)


## Debt that puts `id` `extra` CR past solvent: its liquidation value plus extra.
func _distress(w: Barons, id: String, extra: int = 5000) -> void:
	w.add_debt(id, int(w.assess_baron(id)["liquidation_value"]) + extra)


# --- data ---

func test_the_shipped_data_validates_and_the_takeover_keys_are_read() -> String:
	var errs: Array = Barons.validate(Barons.load_data())
	if not errs.is_empty():
		return "barons.json invalid: %s" % str(errs)
	var t: Dictionary = Takeover.settings(Barons.for_new_run())
	if t["float"] != 1000 or t["threshold"] != 501 or t["cap"] != 100 or t["discount_bps"] != 7000 or t["bankrupt_rounds"] != 6:
		return "settings wrong: %s" % str(t)
	if t["floor"] != 10 or t["reset_bps"] != 4000:
		return "price floor or reset wrong: %s" % str(t)
	var bad: Dictionary = Barons.load_data()
	bad["takeover"]["reset_treasury_bps"] = 20000
	bad["takeover"]["rent_units"] = -1
	if Barons.validate(bad).size() != 2:
		return "the optional takeover keys are not validated: %s" % str(Barons.validate(bad))
	return "ok"


func test_a_solvent_world_writes_nothing_in_forty_rounds() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	for r in range(1, 41):
		_boundary(c, r)
	# Archetypes write their own scratch; the takeover core must add none of its own.
	for id in w.ids():
		var s: BaronState = w.state(id)
		if s.strain != 0 or s.debt_cr != 0 or s.holder != "" or not s.shares.is_empty() or s.scratch.has("distress") or s.scratch.has("claims"):
			return "%s carries takeover state in a solvent world: %s" % [id, str(s.to_dict())]
		if s.treasury_shares != int(w.def(id)["treasury_shares"]):
			return "%s lost treasury shares" % id
	return "ok"


# --- insolvency and the distress auction ---

func test_insolvency_is_chapter11_assess_on_the_barons_books() -> String:
	var w: Barons = Barons.for_new_run()
	var a: Dictionary = w.assess_baron(ARES)
	if bool(a["insolvent"]) or int(a["total_debt"]) != 0:
		return "a fresh baron is insolvent: %s" % str(a)
	var s: BaronState = w.state(ARES)
	var snap := {"cr": s.treasury_cr, "cargo": s.inventory, "ships": [], "doomsday": {"principal_debt": 70000}}
	w.add_debt(ARES, 70000)
	var want: Dictionary = Chapter11.assess(snap)
	var got: Dictionary = w.assess_baron(ARES)
	if got["insolvent"] != want["insolvent"] or got["shortfall"] != want["shortfall"] or got["liquidation_value"] != want["liquidation_value"]:
		return "assess_baron disagrees with Chapter11.assess: %s vs %s" % [str(got), str(want)]
	# The 50% haircut is in it: stock counts at half.
	var stock: int = Piracy.cargo_value("ORE", 300) / 2 + Piracy.cargo_value("MACHINERY", 200) / 2
	if abs(int(got["liquidation_value"]) - (60000 + stock)) > 2:
		return "liquidation value %d does not use the haircut (want ~%d)" % [int(got["liquidation_value"]), 60000 + stock]
	if not bool(got["insolvent"]):
		return "70000 of debt against a ~%d liquidation should be insolvent" % int(got["liquidation_value"])
	return "ok"


func test_a_distressed_baron_offers_shares_at_a_discount_up_to_the_cap() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	_distress(w, ARES, 50000)
	var ev: Array = _boundary(c, 1)
	var o: Dictionary = w.distress_at("mars")
	# NAV is negative, so the price is the floor (10) x 0.7 = 7; the lot is the 100 cap.
	if o.is_empty() or int(o["px"]) != 7 or int(o["qty"]) != 100 or str(o["baron"]) != ARES:
		return "offer wrong: %s" % str(o)
	if w.state(ARES).strain != 1 or not _kinds(ev, ARES).has("distress"):
		return "strain %d events %s" % [w.state(ARES).strain, str(_kinds(ev))]
	# A second round: still insolvent, strain climbs, no second announcement.
	ev = _boundary(c, 2)
	if w.state(ARES).strain != 2 or _kinds(ev, ARES).has("distress"):
		return "round 2: strain %d, events %s" % [w.state(ARES).strain, str(_kinds(ev, ARES))]
	if not w.distress_at("earth").is_empty() or not w.distress_at("ceres").is_empty():
		return "a solvent baron is auctioning shares"
	return "ok"


func test_a_small_shortfall_offers_only_the_shares_that_cover_it() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	_distress(w, ARES, 15)  # 15 CR short: ceil(15 / 7) = 3 shares
	_boundary(c, 1)
	var o: Dictionary = w.distress_at("mars")
	if int(o.get("qty", 0)) != 3:
		return "lot %s, want 3 shares" % str(o)
	return "ok"


func test_the_price_floor_and_discount_come_from_the_data() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	w.data["takeover"]["auction_price_floor"] = 25
	w.data["takeover"]["auction_discount_bps"] = 6000
	_distress(w, ARES, 50000)
	_boundary(c, 1)
	if int(w.distress_at("mars").get("px", 0)) != 15:
		return "price %s, want 25 x 60%% = 15" % str(w.distress_at("mars"))
	return "ok"


func test_the_offer_lapses_when_the_baron_is_solvent_again() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	_distress(w, ARES, 50000)
	_boundary(c, 1)
	w.state(ARES).debt_cr = 0
	_boundary(c, 2)
	if w.state(ARES).strain != 0 or not w.distress_at("mars").is_empty():
		return "a solvent baron kept its strain or offer"
	return "ok"


func test_no_rival_bids_exist_yet_so_the_lot_stays_in_the_treasury() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	_distress(w, ARES, 50000)
	for r in range(1, 5):
		_boundary(c, r)
	if w.state(ARES).treasury_shares != 600 or not w.rival_bids(ARES, 1, 7, 100, c["rc"]).is_empty():
		return "shares moved with nobody buying: %d" % w.state(ARES).treasury_shares
	return "ok"


# --- buying ---

func test_buying_the_lot_moves_cash_and_shares() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	_distress(w, ARES, 50000)
	_boundary(c, 1)
	var cr0: int = rc.cr
	var tr0: int = w.state(ARES).treasury_cr
	var res: Dictionary = w.buy_shares(rc, "mars", 40)
	if not bool(res["ok"]) or int(res["n"]) != 40 or int(res["cost"]) != 0 or int(res["max_price"]) != 10:
		return "bid wrong: %s" % str(res)
	if rc.cr != cr0 or w.state(ARES).treasury_cr != tr0:
		return "a bid moved cash before the lot cleared"
	_boundary(c, 2)
	if rc.cr != cr0 - 280 or w.state(ARES).treasury_cr != tr0 + 280:
		return "cash did not move at the clearing: cr %d treasury %d" % [rc.cr, w.state(ARES).treasury_cr]
	var s: BaronState = w.state(ARES)
	if s.treasury_shares != 560 or int(s.shares["player"]) != 40:
		return "shares did not move: %s" % str(s.to_dict())
	# A bid for more than the lot is capped at the lot; the next lot is listed again.
	var big: Dictionary = w.buy_shares(rc, "mars", 500)
	if int(big["n"]) != 100:
		return "the bid was not capped at what was on offer: %s" % str(big)
	_boundary(c, 3)
	if w.state(ARES).treasury_shares != 460:
		return "the capped bid did not buy the lot: %d" % w.state(ARES).treasury_shares
	return "ok"


func test_a_buy_is_refused_for_each_reason() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	if str(w.buy_shares(rc, "mars", 10)["reason"]) != "NO_OFFER":
		return "a healthy baron sold shares"
	_distress(w, ARES, 50000)
	_boundary(c, 1)
	rc.cr = 6
	if str(w.buy_shares(rc, "mars", 10)["reason"]) != "NO_CR":
		return "CR 6 bought a 7 CR share"
	# Spending the last CR would leave a corp with debt insolvent: refused, nothing moves.
	rc.cr = 700
	rc.doomsday.add_principal(500)
	var res: Dictionary = w.buy_shares(rc, "mars", 100)
	if str(res["reason"]) != "WOULD_BANKRUPT" or rc.cr != 700 or w.state(ARES).treasury_shares != 600:
		return "WOULD_BANKRUPT not enforced: %s cr %d" % [str(res), rc.cr]
	w.state(ARES).holder = "rival_a"
	if str(w.buy_shares(rc, "mars", 10)["reason"]) != "HELD":
		return "a held baron sold shares"
	return "ok"


func test_the_501st_share_takes_the_baron_and_not_a_share_more() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	_distress(w, ARES, 5000)
	var last: Array = []
	for r in range(1, 9):
		last = _boundary(c, r)
		w.buy_shares(rc, "mars", 100)
		if w.state(ARES).holder == Takeover.PLAYER:
			break
	var s: BaronState = w.state(ARES)
	if s.holder != "player" or int(s.shares["player"]) != 501:
		return "after %d rounds holder '%s' shares %s" % [7, s.holder, str(s.shares)]
	if not _kinds(last).has("takeover"):
		return "no takeover event: %s" % str(_kinds(last))
	return "ok"


func test_a_takeover_absorbs_treasury_and_debt_and_the_holder_gains_the_privileges() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	_distress(w, ARES, 3000)
	var debt: int = s.debt_cr
	s.shares["player"] = 500
	_boundary(c, 1)
	var cr0: int = rc.cr
	var pr0: int = rc.doomsday.principal_debt
	var tr0: int = s.treasury_cr
	var res: Dictionary = w.buy_shares(rc, "mars", 100)
	var tk: Dictionary = {}
	for e in _boundary(c, 2):
		if str(e["kind"]) == "takeover":
			tk = e
	if tk.is_empty() or int(res["n"]) != 1:
		return "one share should have taken it: %s" % str(res)
	if rc.cr != cr0 - 7 + (tr0 + 7) or int(tk["treasury"]) != tr0 + 7:
		return "treasury not absorbed: cr %d (was %d), treasury %d" % [rc.cr, cr0, tr0]
	if rc.doomsday.principal_debt != pr0 + debt or int(tk["debt"]) != debt:
		return "debt not assumed: principal %d (was %d), debt %d" % [rc.doomsday.principal_debt, pr0, debt]
	if s.treasury_cr != 0 or s.debt_cr != 0 or s.treasury_shares != 0 or s.strain != 0 or not w.distress_at("mars").is_empty():
		return "the baron's books were not cleared: %s" % str(s.to_dict())
	if not w.is_insider("player", ARES) or w.docking_toll_due("player", "mars") != 0:
		return "the holder is not toll exempt"
	for m in w.market_mods():
		if str(m.get("station", "")) == "mars" and int(m.get("ask_price_bps", 0)) != 0:
			return "the holder still pays the pipeline premium: %s" % str(m)
	if bool(tk["forced_ch11"]) or bool(rc.assess()["insolvent"]):
		return "a well-funded player was pushed into Chapter 11"
	return "ok"


func test_a_takeover_that_sinks_the_player_reports_it_and_filing_forfeits_the_baron() -> String:
	var c := _ctx(21, 20000)
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	w.add_debt(ARES, 400000)  # far past what the treasury covers
	s.shares["player"] = 500
	_boundary(c, 1)
	var res: Dictionary = w.buy_shares(rc, "mars", 1)
	var tk: Dictionary = {}
	for e in _boundary(c, 2):
		if str(e["kind"]) == "takeover":
			tk = e
	if tk.is_empty() or not bool(tk["forced_ch11"]):
		return "the takeover did not report forced_ch11: %s" % str(res)
	if not bool(rc.assess()["insolvent"]):
		return "the assumed debt did not sink the corp"
	# The next tick of the clock finds it insolvent and stops for Chapter 11.
	rc._interrupt_check()
	if not rc.pending_bankruptcy:
		return "no Chapter 11 pending after the takeover"
	var report: Dictionary = rc.file_bankruptcy()
	if report.is_empty() or s.holder != "":
		return "filing did not release the baron: holder '%s'" % s.holder
	if (report["forfeited_barons"] as Array).size() != 1 or str(report["forfeited_barons"][0]["baron"]) != ARES:
		return "report: %s" % str(report.get("forfeited_barons"))
	return "ok"


# --- the held baron ---

func test_a_held_baron_acts_against_no_one_and_pays_rent() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	for id in [ARES, TITAN, SOL]:
		w.state(id).holder = "player"
	rc.cr = 1000
	var rent: int = 0
	for id in [ARES, TITAN, SOL]:
		rent += w.rent_of(id)
	if w.rent_of(ARES) != 181:
		return "Ares rent %d, want 100 units of ORE and MACHINERY at 6%% = 181" % w.rent_of(ARES)
	var all: Array = []
	for r in range(1, 21):
		all.append_array(_boundary(c, r))
	for e in all:
		if ["offer", "squeeze", "hoard", "corner", "auction_open", "auction_clear", "missed"].has(str(e["kind"])):
			return "a held baron acted: %s" % str(e)
	if rc.cr != 1000 + 20 * rent:
		return "rent: cr %d, want %d" % [rc.cr, 1000 + 20 * rent]
	if not w.auction_at("earth", 5, rc.run_seed).is_empty() or w.has_pending_offer():
		return "a held baron still runs an auction or an offer"
	return "ok"


func test_a_rival_held_baron_pays_the_player_no_rent() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	c["world"].state(ARES).holder = "rival_a"
	rc.cr = 1000
	for r in range(1, 6):
		_boundary(c, r)
	if rc.cr != 1000:
		return "rent reached the player from a rival's baron: %d" % rc.cr
	return "ok"


func test_taking_a_baron_cancels_its_contract_and_auction() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	# Ares has an open offer at round 8; Sol Central a queued order.
	_boundary(c, 8)
	if not w.has_pending_offer():
		return "no Ares offer to cancel"
	w.state(ARES).shares["player"] = 500
	_distress(w, ARES, 5000)
	_boundary(c, 9)
	var res: Dictionary = w.buy_shares(rc, "mars", 1)
	_boundary(c, 10)
	if not bool(res["ok"]) or w.state(ARES).holder != Takeover.PLAYER or w.has_pending_offer() or w.state(ARES).scratch.has("contract"):
		return "taking Ares left its contract behind: %s" % str(w.state(ARES).scratch)
	return "ok"


# --- bankruptcy and settlement ---

## Sells each round's lot to two stand-in buyers (neither reaches 501) until the
## treasury holds no shares; returns the boundary round that settles.
func _sell_out(c: Dictionary, id: String, start: int) -> int:
	var w: Barons = c["world"]
	var r: int = start
	while r < start + 30:
		_boundary(c, r)
		if w.state(id).holder != "" or w.state(id).strain == 0:
			return r
		var o: Dictionary = Takeover.offer(w, id)
		if not o.is_empty():
			_stand_in(w, id, "rival_a" if r % 2 == 0 else "rival_b", int(o["qty"]), c["rc"])
		r += 1
	return r


func test_bankruptcy_needs_six_insolvent_rounds_and_no_treasury_shares() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	_distress(w, ARES, 50000)
	# With shares still in the treasury the baron never goes bankrupt, however long it lasts.
	for r in range(1, 13):
		_boundary(c, r)
	if w.state(ARES).holder != "" or w.state(ARES).strain != 12:
		return "bankrupt with shares left: strain %d holder '%s'" % [w.state(ARES).strain, w.state(ARES).holder]
	var c2 := _ctx()
	var w2: Barons = c2["world"]
	_distress(w2, ARES, 50000)
	var at: int = _sell_out(c2, ARES, 1)
	if w2.state(ARES).strain != 0 or w2.state(ARES).holder != "":
		return "the stand-in sales never settled: strain %d" % w2.state(ARES).strain
	if at < 7:
		return "settled at round %d, before six insolvent rounds were served" % at
	return "ok"


func test_a_systems_bankruptcy_liquidates_at_the_haircut_and_reorganises_the_baron() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	_distress(w, ARES, 50000)
	var liq: int = int(w.assess_baron(ARES)["liquidation_value"])
	var cr0: int = rc.cr
	var events: Array = []
	var r: int = 1
	while r < 40 and not _kinds(events, ARES).has("bankrupt"):
		events = _boundary(c, r)
		var o: Dictionary = Takeover.offer(w, ARES)
		if not o.is_empty() and w.state(ARES).treasury_shares > 0:
			_stand_in(w, ARES, "rival_a" if r % 2 == 0 else "rival_b", int(o["qty"]), rc)
		r += 1
	var ev: Dictionary = {}
	for e in events:
		if str(e["kind"]) == "bankrupt" and str(e["baron"]) == ARES:
			ev = e
	if ev.is_empty():
		return "never went bankrupt"
	# Treasury grew by the share proceeds before the sale, so compare with the live number.
	if int(ev["liquidation"]) < liq or str(ev["holder"]) != "" or int(ev["recovered"]) != 0:
		return "event wrong: %s (liq at start %d)" % [str(ev), liq]
	var s: BaronState = w.state(ARES)
	var d: Dictionary = w.def(ARES)
	if s.holder != "" or s.debt_cr != 0 or s.strain != 0 or not s.inventory.is_empty() or not s.shares.is_empty():
		return "the shell kept its old books: %s" % str(s.to_dict())
	if s.treasury_cr != int(d["treasury_cr"]) * 4000 / 10000 or s.treasury_shares != int(d["treasury_shares"]):
		return "reorganised treasury %d / %d shares, want 40%% of the opening" % [s.treasury_cr, s.treasury_shares]
	if rc.cr != cr0 or rc.doomsday.principal_debt != 0:
		return "a bankruptcy the player had no claim in touched their books"
	return "ok"


func test_settlement_pays_creditors_pro_rata_and_the_largest_claim_holder_takes_over() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	s.treasury_shares = 0
	s.strain = 6
	# 60000 treasury + haircut stock against 150000 owed: the player's 90000 claim is the largest.
	w.add_debt(ARES, 40000, "rival_a")
	w.add_debt(ARES, 90000, "player")
	w.add_debt(ARES, 20000)  # unattributed: the system's
	var liq: int = int(w.assess_baron(ARES)["liquidation_value"])
	var owed: int = 150000
	var cr0: int = rc.cr
	var ev: Dictionary = Takeover.settle(w, ARES, rc)
	var paid: Dictionary = ev["paid"]
	var total: int = 0
	for k in paid:
		total += int(paid[k])
	if total != mini(liq, owed):
		return "payouts sum to %d, want %d (all of the liquidation)" % [total, mini(liq, owed)]
	if abs(int(paid["player"]) - liq * 90000 / owed) > 2 or abs(int(paid["rival_a"]) - liq * 40000 / owed) > 2 or abs(int(paid["system"]) - liq * 20000 / owed) > 2:
		return "not pro rata: %s on %d" % [str(paid), liq]
	if str(ev["holder"]) != "player" or s.holder != "player":
		return "the largest claim did not take the company: %s" % str(ev)
	if rc.cr != cr0 + int(paid["player"]) or int(ev["recovered"]) != int(paid["player"]):
		return "the player's recovery was not credited"
	if s.debt_cr != 0 or s.treasury_cr != 0 or not s.inventory.is_empty() or not Takeover.claims(w, ARES).is_empty():
		return "the settled baron kept books: %s" % str(s.to_dict())
	return "ok"


func test_equal_claims_break_ties_by_sorted_id() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	w.state(ARES).treasury_shares = 0
	w.add_debt(ARES, 60000, "rival_b")
	w.add_debt(ARES, 60000, "rival_a")
	w.add_debt(ARES, 59999)
	var ev: Dictionary = Takeover.settle(w, ARES, c["rc"])
	if str(ev["holder"]) != "rival_a":
		return "tie went to '%s', want rival_a" % str(ev["holder"])
	# Run it again: identical.
	var c2 := _ctx()
	var w2: Barons = c2["world"]
	w2.state(ARES).treasury_shares = 0
	w2.add_debt(ARES, 60000, "rival_a")
	w2.add_debt(ARES, 60000, "rival_b")
	w2.add_debt(ARES, 59999)
	var ev2: Dictionary = Takeover.settle(w2, ARES, c2["rc"])
	if JSON.stringify(ev["paid"]) != JSON.stringify(ev2["paid"]) or str(ev2["holder"]) != "rival_a":
		return "insertion order changed the settlement: %s vs %s" % [str(ev["paid"]), str(ev2["paid"])]
	return "ok"


func test_a_takeover_cancels_a_loan_the_taker_made() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	w.add_debt(ARES, 50000, "player")  # the player's own loan to Ares
	w.add_debt(ARES, 10000)
	var pr0: int = rc.doomsday.principal_debt
	var ev: Dictionary = Takeover.take(w, ARES, "player", rc)
	if rc.doomsday.principal_debt != pr0 + 10000 or int(ev["debt"]) != 10000:
		return "the taker assumed its own loan: %s" % str(ev)
	return "ok"


# --- forfeit on a Chapter 11 filing ---

func test_filing_chapter_11_forfeits_every_holding_deterministically() -> String:
	var run := func() -> String:
		var c := _ctx(21, 20000)
		var rc: RunController = c["rc"]
		var w: Barons = c["world"]
		w.state(ARES).holder = "player"
		w.state(ARES).treasury_cr = 0
		w.state(ARES).inventory = {"ORE": 7}
		w.state(ARES).shares = {"player": 520}
		w.state(TITAN).shares = {"player": 250, "rival_a": 100}  # a partial stake
		w.state(TITAN).treasury_shares = 250
		w.add_debt(TITAN, 1000, "player")
		w.state(SOL).holder = "rival_a"  # not the failed corp's
		rc.doomsday.add_principal(1000000)
		rc._interrupt_check()
		var rep: Dictionary = rc.file_bankruptcy()
		if rep.is_empty():
			return "did not file"
		return JSON.stringify(w.to_dict())
	var a: String = run.call()
	if not a.begins_with("{"):
		return a
	if a != run.call():
		return "the forfeit is not deterministic"
	var w: Barons = Barons.from_dict(JSON.parse_string(a))
	var ares: BaronState = w.state(ARES)
	var d: Dictionary = w.def(ARES)
	if ares.holder != "" or ares.treasury_cr != int(d["treasury_cr"]) * 4000 / 10000 or ares.treasury_shares != int(d["treasury_shares"]) or not ares.shares.is_empty():
		return "Ares did not revert: %s" % str(ares.to_dict())
	if ares.inventory != {"ORE": 300, "MACHINERY": 200}:
		return "Ares stock not restored: %s" % str(ares.inventory)
	var titan: BaronState = w.state(TITAN)
	if int(titan.shares.get("player", 0)) != 0 or titan.treasury_shares != 500 or int(titan.shares["rival_a"]) != 100:
		return "the partial stake did not return to the treasury: %s" % str(titan.to_dict())
	if titan.debt_cr != 0 or not Takeover.claims(w, TITAN).is_empty():
		return "the failed corp's claim stayed on Titan's books"
	if w.state(SOL).holder != "rival_a":
		return "a rival's baron was forfeited"
	return "ok"


func test_a_filing_with_nothing_held_writes_nothing() -> String:
	var c := _ctx(21, 20000)
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	rc.doomsday.add_principal(1000000)
	rc._interrupt_check()
	var before: String = JSON.stringify(w.to_dict())
	rc.file_bankruptcy()
	if JSON.stringify(w.to_dict()) != before:
		return "a filing rewrote barons the corp never held"
	return "ok"


# --- Ryan's rule ---

func test_no_random_event_forces_chapter_11() -> String:
	# Forty rounds with every baron in deep distress and a rival buying lots: the player
	# does nothing, and nothing the world does touches their debt or solvency.
	var c := _ctx(21, 50000)
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	# Random baron events (on since task 12) fine the player under their own lethal guard,
	# tested in test_heat_bounties.gd; this test is about settlements and takeovers.
	w.data["consequence"]["random_event_bps"] = 0
	for id in [ARES, TITAN, SOL]:
		_distress(w, id, 100000)
	var cr0: int = rc.cr
	for r in range(1, 41):
		var ev: Array = _boundary(c, r)
		for e in ev:
			if str(e["kind"]) == "bankrupt" or str(e["kind"]) == "takeover":
				if bool(e.get("forced_ch11", false)):
					return "round %d: a world event forced Chapter 11: %s" % [r, str(e)]
		for id in [ARES, TITAN, SOL]:
			var o: Dictionary = Takeover.offer(w, id)
			if not o.is_empty() and r % 3 == 0:
				_stand_in(w, id, "rival_a" if r % 2 == 0 else "rival_b", 100, rc)
		if rc.doomsday.principal_debt != 0 or bool(rc.assess()["insolvent"]):
			return "round %d: the world put debt on the player" % r
	if rc.cr < cr0:
		return "the world took %d CR from a passive player" % (cr0 - rc.cr)
	return "ok"


func test_only_the_players_own_purchase_can_report_a_forced_chapter_11() -> String:
	# The lethal guard: a settlement the player has no claim in cannot fail the corp.
	var c := _ctx(21, 3000)
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	w.state(ARES).treasury_shares = 0
	w.add_debt(ARES, 500000, "rival_a")
	var ev: Dictionary = Takeover.settle(w, ARES, rc)
	if bool(ev.get("forced_ch11", false)) or bool(rc.assess()["insolvent"]) or rc.cr != 3000:
		return "a settlement hurt a player with no stake: %s" % str(ev)
	return "ok"


# --- the same rules with the shipped fleets ON (#134) ---

func test_with_fleets_on_a_distressed_baron_is_contested_and_the_player_can_still_take_it() -> String:
	var c := _ctx(21, 400000, true)
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	w.data["takeover"]["auction_cap"] = 200
	_distress(w, ARES, 400000)
	var fleets_got: int = 0
	var r: int = 1
	while r <= 14 and w.state(ARES).holder != Takeover.PLAYER:
		_boundary(c, r)
		fleets_got = maxi(fleets_got, Takeover.shares_of(w, ARES, "ember_haulage") + Takeover.shares_of(w, ARES, "blackwater_lines"))
		if not w.distress_at("mars").is_empty():
			w.submit_bid(rc, "mars", 200, w.share_value(ARES, "player", rc) * 4)
		r += 1
	if w.state(ARES).holder != Takeover.PLAYER:
		return "the player never took Ares against the fleets: %s" % str(w.state(ARES).shares)
	if w.state(ARES).scratch.has("distress") or w.has_pending_offer():
		return "a taken baron kept its auction"
	return "ok"


func test_with_fleets_on_the_same_bankruptcy_path_settles() -> String:
	var c := _ctx(21, 100000, true)
	var w: Barons = c["world"]
	w.data["rivals"]["bid_after_strain"] = 99  # the fleets sit this one out
	w.data["rivals"]["decide_chance_bps"] = 0
	_distress(w, ARES, 50000)
	var at: int = _sell_out(c, ARES, 1)
	if w.state(ARES).strain != 0 or w.state(ARES).holder != "":
		return "the stand-in sales never settled with fleets present: strain %d" % w.state(ARES).strain
	if at < 7:
		return "settled at round %d, before six insolvent rounds were served" % at
	return "ok"


# --- the UI path ---

func test_the_shares_action_bids_for_the_lot_and_posts_the_headlines() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var w: Barons = c["world"]
	var rc: RunController = c["rc"]
	if lp.dispatch_action(M0Loop.ACT_SHARES):
		return "the key did something with no lot on offer"
	_distress(w, ARES, 50000)
	var ev: Array = _boundary(c, 1)
	for e in ev:
		lp._post_baron_event(e)
	if not lp.dispatch_action(M0Loop.ACT_SHARES):
		return "the key did not bid for the lot (reason '%s')" % lp.last_shares_reason
	if rc.cr != 100000 or w.state(ARES).shares.has("player"):
		return "the key bought at once: cr %d" % rc.cr
	for e in _boundary(c, 2):
		lp._post_baron_event(e)
	if int(w.state(ARES).shares["player"]) != 100 or rc.cr != 100000 - 700:
		return "lot not won: %s cr %d" % [str(w.state(ARES).shares), rc.cr]
	var t: Array = _texts(c["hud"])
	if not _any(t, "ARES HEAVY is in distress") or not _any(t, "Bid placed: 100 ARES HEAVY shares, up to 10 CR each (reserve 7)") or not _any(t, "ARES HEAVY auction clears: 100 shares at 7 CR each (reserve 7)") or not _any(t, "You buy 100 ARES HEAVY shares at 7 CR each: 100 of 501 held"):
		return "headlines: %s" % str(t)
	return "ok"


func test_a_refused_buy_says_why() -> String:
	var c := _ctx(21, 700)
	var lp: M0Loop = c["loop"]
	var w: Barons = c["world"]
	var rc: RunController = c["rc"]
	_distress(w, ARES, 50000)
	_boundary(c, 1)
	rc.doomsday.add_principal(500)
	if lp.dispatch_action(M0Loop.ACT_SHARES) or lp.last_shares_reason != "WOULD_BANKRUPT":
		return "reason '%s'" % lp.last_shares_reason
	if not _any(_texts(c["hud"]), "Shares refused: the purchase would leave you insolvent"):
		return "no refusal headline: %s" % str(_texts(c["hud"]))
	return "ok"


func test_the_sidebar_rows_follow_the_baron() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var w: Barons = c["world"]
	var rc: RunController = c["rc"]
	if not lp.takeover_lines("mars").is_empty() or lp.takeover_state("mars") != "":
		return "a healthy baron has takeover rows"
	_distress(w, ARES, 50000)
	_boundary(c, 1)
	var rows: Array = lp.takeover_lines("mars")
	if rows != ["DISTRESS LOT: 100 SHARES, RESERVE 7 CR", "INSOLVENT RD 1 OF 6", "YOU HOLD 0 OF 501 SHARES", "YOUR VALUE 10 CR A SHARE", "F / L3 BIDS AT YOUR VALUE. PRESS AGAIN TO RAISE"]:
		return "distress rows: %s" % str(rows)
	if lp.takeover_state("mars") != "distress":
		return "state %s" % lp.takeover_state("mars")
	w.buy_shares(rc, "mars", 100)
	if not (lp.takeover_lines("mars") as Array).has("YOUR VALUE 10 CR. BID 100 SHARES UP TO 10 CR"):
		return "no bid row: %s" % str(lp.takeover_lines("mars"))
	_boundary(c, 2)
	if not (lp.takeover_lines("mars") as Array).has("LAST CLEAR 7 CR (100 SHARES)") or not (lp.takeover_lines("mars") as Array).has("YOU HOLD 100 OF 501 SHARES"):
		return "no last-clear row: %s" % str(lp.takeover_lines("mars"))
	w.state(ARES).scratch.erase("distress")
	if lp.takeover_lines("mars")[0] != "DISTRESS: LOT SOLD":
		return "sold-lot row: %s" % str(lp.takeover_lines("mars"))
	w.state(ARES).scratch["distress"] = {"px": 7, "qty": 100, "round": 1}
	# Away from the baron's dock there is nothing to press, so no hint (and it shows only to a player with no stake).
	w.state(ARES).shares.erase("player")
	if not (lp.takeover_lines("mars") as Array).has("F / L3 BIDS AT YOUR VALUE. PRESS AGAIN TO RAISE"):
		return "no hint at the dock: %s" % str(lp.takeover_lines("mars"))
	rc.docked_at = "earth"
	if (lp.takeover_lines("mars") as Array).has("F / L3 BIDS AT YOUR VALUE. PRESS AGAIN TO RAISE"):
		return "hint shown away from the dock"
	rc.docked_at = "mars"
	w.state(ARES).holder = "player"
	rows = lp.takeover_lines("mars")
	if lp.takeover_state("mars") != "held" or rows != ["HELD", "RENT +181 CR A ROUND"]:
		return "held rows: %s" % str(rows)
	w.state(ARES).holder = "rival_a"
	if lp.takeover_lines("mars") != ["HELD BY RIVAL_A"]:
		return "rival rows: %s" % str(lp.takeover_lines("mars"))
	return "ok"


func test_the_market_tab_tags_a_held_barons_pipeline_as_yours() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var w: Barons = c["world"]
	if lp.pipeline_tag("mars", "ORE") == "PIPELINE (YOURS)":
		return "pipeline is already yours"
	w.state(ARES).holder = "player"
	if lp.pipeline_tag("mars", "ORE") != "PIPELINE (YOURS)":
		return "tag %s" % lp.pipeline_tag("mars", "ORE")
	return "ok"


func test_the_action_is_bound_and_named() -> String:
	if not InputMap.has_action(M0Loop.ACT_SHARES):
		return "m0_shares is not in the InputMap"
	if not M0Loop.ALL_ACTIONS.has(M0Loop.ACT_SHARES):
		return "m0_shares is not remappable"
	return "ok"


# --- determinism: save / load / continue (seeds 84 and 7) ---

## Drives the scenario as a pure function of the run's own state, so a resumed run
## plays exactly as the uninterrupted one: Ares falls into debt at round 3, and the
## player buys each round's lot at Mars until the baron is theirs.
func _drive(rc: RunController, lp: M0Loop) -> void:
	var w: Barons = rc.world
	if w == null or rc.docked_at != "mars":
		return
	var s: BaronState = w.state(ARES)
	if rc.get_current_round() == 3 and s.debt_cr == 0 and s.holder == "":
		_distress(w, ARES, 50000)
	if not w.distress_at("mars").is_empty():
		lp.buy_shares()


func _play(s: Replay.Session, frames: int, stop: Callable = Callable()) -> int:
	var used: int = 0
	for i in frames:
		if s.loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			s.loop.decline_contract()
		elif s.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			s.loop.acknowledge_crisis()
		elif s.loop.overlay_state == M0Loop.OVERLAY_NONE and s.controller.sim_clock.paused and not s.controller.pending_bankruptcy:
			s.controller.sim_clock.resume()
		_drive(s.controller, s.loop)
		s.advance()
		used += 1
		if stop.is_valid() and bool(stop.call()):
			break
	return used


func _session(p_seed: int) -> Replay.Session:
	var s := Replay.Session.new(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	s.controller.world.rivals.clear()  # not what this test is about; test_rival_fleets.gd covers the fleets
	s.controller.cr = 100000
	s.loop.dock_at("mars")
	return s


func _resume(cap: Dictionary) -> Dictionary:
	var r: Dictionary = RunSave.restore(cap.duplicate(true))
	var rc: RunController = r["controller"]
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.set_market(r["market"])
	lp.sync_hud_to_ship()
	hud.set_station(rc.docked_at)
	return {"rc": rc, "loop": lp, "market": r["market"], "bags": r["bags"]}


func _continue_equal(p_seed: int) -> String:
	var total: int = 4500
	var whole := _session(p_seed)
	_play(whole, total)
	if whole.controller.world.state(ARES).holder != "player":
		return "seed %d: the uninterrupted run never took Ares (round %d, shares %s)" % [p_seed, whole.controller.get_current_round(), str(whole.controller.world.state(ARES).shares)]
	var split := _session(p_seed)
	var stop: Callable = func(): return int(split.controller.world.state(ARES).shares.get("player", 0)) >= 300
	var used: int = _play(split, total, stop)
	if used >= total:
		return "seed %d: never held a stake to split on" % p_seed
	if split.controller.world.state(ARES).holder != "":
		return "seed %d: split after the takeover, not before" % p_seed
	var cap: Dictionary = RunSave.capture(split.controller, split.loop.market, split.bags)
	var via_json: Dictionary = RunSave.restore(_json(cap))
	if not bool(via_json["ok"]) or RunSave.state_hash(via_json["controller"], via_json["market"], via_json["bags"]) != split.state_hash():
		return "seed %d: the save file round trip changed the hash" % p_seed
	var rw: Barons = (via_json["controller"] as RunController).world
	if int(rw.state(ARES).shares["player"]) != int(split.controller.world.state(ARES).shares["player"]) or rw.state(ARES).strain != split.controller.world.state(ARES).strain:
		return "seed %d: the stake or strain did not survive the JSON round trip" % p_seed
	var back := _resume(cap)
	var lp: M0Loop = back["loop"]
	if lp.takeover_lines("mars").size() < 3:
		return "seed %d: the sidebar rows did not come back" % p_seed
	for i in total - used:
		if lp.overlay_state == M0Loop.OVERLAY_CONTRACT:
			lp.decline_contract()
		elif lp.overlay_state == M0Loop.OVERLAY_CRISIS:
			lp.acknowledge_crisis()
		elif lp.overlay_state == M0Loop.OVERLAY_NONE and back["rc"].sim_clock.paused and not back["rc"].pending_bankruptcy:
			back["rc"].sim_clock.resume()
		_drive(back["rc"], lp)
		lp.advance(Replay.DEFAULT_FRAME_DELTA)
	if back["rc"].world.state(ARES).holder != "player":
		return "seed %d: the resumed run never took Ares" % p_seed
	if RunSave.state_hash(back["rc"], lp.market, back["bags"]) != whole.state_hash():
		return "seed %d: save/load/continue diverged from the uninterrupted run" % p_seed
	return "ok"


func test_continue_equals_uninterrupted_through_a_takeover() -> String:
	for sd in [84, 7]:
		var r := _continue_equal(sd)
		if r != "ok":
			return r
	return "ok"


func test_the_same_takeover_run_hashes_the_same_twice() -> String:
	var a := _session(84)
	_play(a, 4500)
	var b := _session(84)
	_play(b, 4500)
	if a.state_hash() != b.state_hash():
		return "the same takeover run hashed twice differently"
	if _session(7).state_hash() == a.state_hash():
		return "two seeds hashed alike"
	return "ok"
