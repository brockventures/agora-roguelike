extends RefCounted
## Epic 3 task 8 (part of #17, Hostile Takeover & Insolvency): the player's levers.
## Corner (a held pipeline stock drains the baron's stock, then treasury, then credit),
## margin (sell pressure, the halving accumulator, the margin call), the credit line and
## its default into insolvency, the Hostile Buyout Line perk (451 shares, tender offers),
## the UI path, Chapter 11 and takeover clean-up, a passive world writing nothing, and
## save/load/continue equality (seeds 84 and 7) with every lever in play.

const TPR: int = 30
const ARES: String = "ares_heavy"
const TITAN: String = "titan_cryo_hydro"
const SOL: String = "sol_central"
const PERK: Dictionary = {"takeover_threshold_shares": {"add": -50, "mul_bps": 10000}}


## A docked run with a world on a 30-tick round, starting at Mars (Ares Heavy's).
func _ctx(p_seed: int = 21, cr: int = 100000, mods: Dictionary = {}) -> Dictionary:
	var rc := RunController.new(null, p_seed, null, mods, TPR)
	rc.world = Barons.for_new_run()
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


# --- data ---

func test_the_shipped_data_validates_and_the_lever_keys_are_read() -> String:
	var errs: Array = Barons.validate(Barons.load_data())
	if not errs.is_empty():
		return "barons.json invalid: %s" % str(errs)
	var cfg: Dictionary = Levers.settings(Barons.for_new_run())
	if cfg["corner"]["hold_qty"] != 60 or cfg["margin"]["maintenance_bps"] != 10500 or cfg["credit"]["rate_bps"] != 2000 or cfg["tender"]["premium_bps"] != 15000:
		return "settings wrong: %s" % str(cfg)
	# A hold the player cannot fill makes the corner unreachable: the hold is 100 units.
	if int(cfg["corner"]["hold_qty"]) > RunController.DEFAULT_CARGO_CAPACITY:
		return "the corner hold %d does not fit the %d-unit hold" % [cfg["corner"]["hold_qty"], RunController.DEFAULT_CARGO_CAPACITY]
	var bad: Dictionary = Barons.load_data()
	bad["levers"]["credit"]["spend_bps"] = 20000
	bad["levers"]["margin"]["nope"] = 1
	bad["levers"]["tender"]["cap"] = -3
	bad["levers"]["bogus"] = {}
	if Barons.validate(bad).size() != 4:
		return "the lever keys are not validated: %s" % str(Barons.validate(bad))
	var none: Dictionary = Barons.load_data()
	none.erase("levers")
	if not Barons.validate(none).is_empty() or Levers.settings(Barons.new(none))["credit"]["line_cr"] != 10000:
		return "a file without levers must validate and fall back to defaults"
	return "ok"


func test_a_passive_world_writes_no_lever_state_in_forty_rounds() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	for r in range(1, 41):
		_boundary(c, r)
	for id in w.ids():
		var s: BaronState = w.state(id)
		if not s.pressure_bps.is_empty() or s.scratch.has("corner") or s.scratch.has("credit") or s.scratch.has("crash") or s.scratch.has("tender") or s.scratch.has("tendered"):
			return "%s carries lever state in a passive world: %s" % [id, str(s.to_dict())]
		if s.margin_debt_cr != int(w.def(id)["margin_debt_cr"]):
			return "%s margin debt moved with nobody leaning on it" % id
	return "ok"


# --- lever a: corner ---

func test_holding_the_pipeline_stock_at_the_anchor_corners_it() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	rc.cargo = {"ORE": 59}
	_boundary(c, 1)
	if s.scratch.has("corner"):
		return "59 of 60 units cornered it"
	rc.cargo = {"ORE": 60}
	var ev: Array = _boundary(c, 2)
	if not _kinds(ev, ARES).has("lever_corner") or int(Levers.corners(w, ARES).get("ORE", 0)) != 1:
		return "60 units did not corner it: %s %s" % [str(_kinds(ev)), str(s.scratch)]
	# The first 100 units of cover come out of Ares's own stock (300 ORE): treasury untouched.
	if int(s.inventory["ORE"]) != 200 or s.treasury_cr != 60000 or s.debt_cr != 0:
		return "stock-first cover wrong: %s" % str(s.to_dict())
	# The book shows the squeeze: ask +50%, ask depth thinned, bids untouched.
	var mods: Array = w.market_mods()
	var found: bool = false
	for m in mods:
		if str(m.get("commodity", "")) == "ORE" and int(m.get("ask_price_bps", 0)) == 5000 and int(m.get("ask_depth_bps", 0)) == 4000 and str(m["station"]) == "mars":
			found = true
	if not found:
		return "no squeeze mod: %s" % str(mods)
	if (c["loop"] as M0Loop).lever_tag("mars", "ORE") != "CORNERED +50%":
		return "tag '%s'" % (c["loop"] as M0Loop).lever_tag("mars", "ORE")
	# Away from the dock, or after selling the stock, the corner ends.
	rc.cargo = {"ORE": 10}
	ev = _boundary(c, 3)
	if not _kinds(ev, ARES).has("lever_corner_end") or s.scratch.has("corner"):
		return "the corner did not end: %s" % str(s.scratch)
	rc.cargo = {"ORE": 100}
	rc.docked_at = "earth"
	_boundary(c, 4)
	if s.scratch.has("corner"):
		return "a corner held from the wrong station"
	return "ok"


func test_the_cover_drains_stock_then_treasury_then_becomes_debt() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	rc.cargo = {"ORE": 100}
	var squeezed: int = int(round(16.5 * 100.0)) * 15000 / 10000 * 100 / 100  # cents per unit x100 units / 100 = CR for 100 units
	for r in range(1, 4):
		_boundary(c, r)
	if int(s.inventory["ORE"]) != 0 or s.treasury_cr != 60000:
		return "three rounds of stock-first cover left %s" % str(s.to_dict())
	_boundary(c, 4)
	if s.treasury_cr != 60000 - squeezed:
		return "a bought round cost %d, want %d" % [60000 - s.treasury_cr, squeezed]
	if Levers.cover_cost(w, ARES, "ORE")["cost"] != squeezed:
		return "cover_cost disagrees"
	# A treasury that cannot pay puts the rest on credit: debt, never a negative treasury.
	s.treasury_cr = 1000
	var ev: Array = _boundary(c, 5)
	if s.treasury_cr != 0 or s.debt_cr != squeezed - 1000:
		return "unpaid cover not in debt: treasury %d debt %d" % [s.treasury_cr, s.debt_cr]
	var unpaid: bool = false
	for e in ev:
		if str(e["kind"]) == "lever_corner" and int(e["unpaid"]) == squeezed - 1000:
			unpaid = true
	if not unpaid:
		return "the unpaid cover was not reported: %s" % str(ev)
	return "ok"


func test_a_held_stock_drains_titans_treasury_too() -> String:
	# Design doc 4.2: "a held player stock of the corner commodity drains Titan's treasury".
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(TITAN)
	rc.docked_at = "ceres"
	c["market"].unlock_station("ceres")
	rc.cargo = {"FUEL": 80}
	s.inventory["FUEL"] = 0
	var t0: int = s.treasury_cr
	_boundary(c, 1)
	if s.treasury_cr >= t0 or int(Levers.corners(w, TITAN).get("FUEL", 0)) != 1:
		return "Titan's treasury did not fall: %d -> %d, %s" % [t0, s.treasury_cr, str(s.scratch)]
	return "ok"


func test_a_corner_does_nothing_to_a_baron_the_player_holds() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	rc.cargo = {"ORE": 100}
	_boundary(c, 1)
	w.state(ARES).holder = "player"
	_boundary(c, 2)
	if w.state(ARES).scratch.has("corner") or Levers.mods(w, ARES).size() != 0:
		return "a held baron is still cornered: %s" % str(w.state(ARES).scratch)
	return "ok"


# --- lever b: margin ---

func test_selling_the_collateral_at_the_anchor_builds_halving_pressure() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	if w.record_trade("mars", "FUEL", "SELL", 50) != 0 or w.record_trade("mars", "ORE", "BUY", 50) != 0 or w.record_trade("earth", "ORE", "SELL", 50) != 0:
		return "pressure from a trade that is not a sale of Ares's stock at Mars"
	if w.record_trade("mars", "ORE", "SELL", 10) != 400:
		return "10 units should be 400 bps"
	if w.record_trade("mars", "ORE", "SELL", 500) != 6000:
		return "the accumulator is not capped at 6000"
	# Ratio 111% at rest; pressure bites the mark: 300 ORE x 19.25 x 0.4 + 200 MACH x 21.2.
	var mods: Array = w.market_mods()
	var press: Dictionary = {}
	for m in mods:
		if str(m.get("commodity", "")) == "ORE" and int(m.get("price_bps", 0)) < 0:
			press = m
	if press.is_empty() or int(press["price_bps"]) != -6000:
		return "no pressure mod: %s" % str(mods)
	s.pressure_bps["ORE"] = 100
	var halves: Array = []
	for r in range(1, 9):
		_boundary(c, r)
		halves.append(int(s.pressure_bps.get("ORE", 0)))
		if halves.back() == 0:
			break
	if halves != [50, 25, 12, 6, 3, 1, 0] or s.pressure_bps.has("ORE"):
		return "halving wrong: %s" % str(halves)
	return "ok"


func test_a_dump_of_the_collateral_triggers_a_margin_call() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	if Levers.margin_ratio_pct(w, ARES) != 111:
		return "Ares opens at %d%%, want 111" % Levers.margin_ratio_pct(w, ARES)
	# Nobody is leaning on it: no call, however thin the cushion.
	var ev: Array = _boundary(c, 1)
	if _kinds(ev, ARES).has("lever_margin"):
		return "a call with no pressure"
	w.record_trade("mars", "ORE", "SELL", 50)  # 2000 bps
	if Levers.margin_ratio_pct(w, ARES) >= 105:
		return "50 units should break the line, ratio %d%%" % Levers.margin_ratio_pct(w, ARES)
	var ore0: int = int(s.inventory["ORE"])
	var debt0: int = s.margin_debt_cr
	ev = _boundary(c, 2)
	var call: Dictionary = {}
	for e in ev:
		if str(e["kind"]) == "lever_margin":
			call = e
	if call.is_empty():
		return "no margin call: %s" % str(_kinds(ev))
	# 30% of the ORE sold, the loan paid down, the book crashed, the rest of the hole is debt.
	if int(s.inventory["ORE"]) != ore0 - ore0 * 3000 / 10000 or int(s.inventory["MACHINERY"]) != 200:
		return "stock after the call: %s" % str(s.inventory)
	if s.margin_debt_cr >= debt0 or int(call["proceeds"]) <= 0 or int(call["units"]) != 90:
		return "loan not paid down: %s" % str(call)
	var coll: int = Levers.collateral(w, ARES)
	if s.margin_debt_cr > coll:
		return "the loan %d still exceeds its collateral %d" % [s.margin_debt_cr, coll]
	if s.debt_cr != int(call["deficiency"]) or s.debt_cr <= 0:
		return "the deficiency is not debt: %d vs %s" % [s.debt_cr, str(call)]
	var crash: bool = false
	for m in w.market_mods():
		if str(m.get("commodity", "")) == "ORE" and int(m.get("price_bps", 0)) <= -1500:
			crash = true
	if not crash or (c["loop"] as M0Loop).lever_tag("mars", "ORE") == "":
		return "no crash on the book"
	# No second call while the forced sale is still on the book, however much pressure is left.
	w.record_trade("mars", "ORE", "SELL", 100)
	ev = _boundary(c, 3)
	if _kinds(ev, ARES).has("lever_margin"):
		return "a second call during the crash"
	if int(Levers.crashes(w, ARES).get("ORE", 0)) != 1:
		return "the crash should have one round left: %s" % str(Levers.crashes(w, ARES))
	# The crash lasts two rounds, then the book recovers (with the pressure gone, no new call).
	s.pressure_bps.clear()
	ev = _boundary(c, 4)
	if not Levers.crashes(w, ARES).is_empty() or s.scratch.has("crash") or _kinds(ev, ARES).has("lever_margin"):
		return "the crash did not end: %s" % str(s.scratch)
	# While pressure persists the cascade goes on: a new call once the last forced sale clears.
	s.pressure_bps["ORE"] = 3000
	s.margin_debt_cr = 9000
	ev = _boundary(c, 5)
	if not _kinds(ev, ARES).has("lever_margin"):
		return "no new call once the crash cleared"
	return "ok"


func test_a_robust_baron_shrugs_off_the_same_dump() -> String:
	# Sol Central's stock is 169% of its loan: 50 units of FRAG do not trouble it.
	var c := _ctx()
	var w: Barons = c["world"]
	(c["rc"] as RunController).docked_at = "earth"
	w.record_trade("earth", "FRAG", "SELL", 50)
	var ev: Array = _boundary(c, 1)
	if _kinds(ev, SOL).has("lever_margin"):
		return "Sol Central was called on 50 units"
	return "ok"


# --- lever c: credit line, default, insolvency ---

func test_the_credit_line_is_refused_until_the_baron_is_pressed() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	_boundary(c, 1)
	var r: Dictionary = w.open_credit(rc, "mars")
	if bool(r["ok"]) or r["reason"] != "NOT_PRESSED":
		return "a flush baron borrowed: %s" % str(r)
	s.treasury_cr = 42000  # exactly 70%
	r = w.open_credit(rc, "mars")
	if not bool(r["ok"]):
		return "a baron at 70%% of its treasury refused: %s" % str(r)
	if rc.cr != 90000 or s.treasury_cr != 42000 + 2500 or int(r["due"]) != 12000 or int(r["due_round"]) != 6:
		return "line terms wrong: cr %d treasury %d %s" % [rc.cr, s.treasury_cr, str(r)]
	var again: Dictionary = w.open_credit(rc, "mars")
	if bool(again["ok"]) or again["reason"] != "OPEN":
		return "a second line opened: %s" % str(again)
	if w.credit_at("mars").is_empty() or int(w.credit_at("mars")["due"]) != 12000:
		return "credit_at: %s" % str(w.credit_at("mars"))
	# Insolvency alone also makes it a borrower.
	var c2 := _ctx()
	c2["world"].add_debt(ARES, 999999)
	_boundary(c2, 1)
	if not bool(c2["world"].open_credit(c2["rc"], "mars")["ok"]):
		return "an insolvent baron refused credit"
	return "ok"


func test_the_credit_line_is_refused_when_it_would_sink_the_player() -> String:
	var c := _ctx(21, 9000)
	var w: Barons = c["world"]
	w.state(ARES).treasury_cr = 1000
	var r: Dictionary = w.open_credit(c["rc"], "mars")
	if r["reason"] != "NO_CR":
		return "9,000 CR lent 10,000: %s" % str(r)
	var c2 := _ctx(21, 10000)
	c2["world"].state(ARES).treasury_cr = 1000
	c2["rc"].doomsday.add_principal(500)
	r = c2["world"].open_credit(c2["rc"], "mars")
	if r["reason"] != "WOULD_BANKRUPT" or c2["rc"].cr != 10000:
		return "a loan that insolvent the corp went through: %s cr %d" % [str(r), c2["rc"].cr]
	var c3 := _ctx()
	c3["world"].state(ARES).holder = "player"
	if c3["world"].open_credit(c3["rc"], "mars")["reason"] != "HELD":
		return "lent to a baron the player holds"
	if c3["world"].open_credit(c3["rc"], "luna")["reason"] != "NO_BARON":
		return "lent at a station with no baron"
	return "ok"


func test_a_baron_with_the_cash_repays_at_maturity() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	s.treasury_cr = 40000
	w.open_credit(rc, "mars")
	for r in range(1, 5):
		_boundary(c, r)
	if w.credit_at("mars").is_empty():
		return "repaid early"
	var ev: Array = _boundary(c, 5)
	if not w.credit_at("mars").is_empty():
		return "the line is still open at maturity"
	var repaid: bool = false
	for e in ev:
		if str(e["kind"]) == "credit_repaid" and int(e["due"]) == 12000:
			repaid = true
	if not repaid or rc.cr != 100000 - 10000 + 12000 or s.debt_cr != 0:
		return "not repaid: %s cr %d debt %d" % [str(_kinds(ev)), rc.cr, s.debt_cr]
	return "ok"


func test_a_default_adds_the_due_amount_as_the_players_claim() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	s.treasury_cr = 5000
	w.open_credit(rc, "mars")  # treasury 7,500, due 12,000
	var ev: Array = []
	for r in range(1, 6):
		ev = _boundary(c, r)
	if not _kinds(ev, ARES).has("credit_default") or not w.credit_at("mars").is_empty():
		return "no default at maturity: %s" % str(_kinds(ev))
	if s.debt_cr != 12000 or Takeover.claims(w, ARES).get("player", 0) != 12000:
		return "claim wrong: debt %d claims %s" % [s.debt_cr, str(Takeover.claims(w, ARES))]
	if rc.cr != 90000:
		return "the player was paid back by a baron that could not pay: %d" % rc.cr
	return "ok"


func test_a_corner_then_a_loan_then_a_default_ends_in_a_distress_auction() -> String:
	# The whole chain on the real world step, no staged debt: the player sits on Ares's
	# pipeline stock until its treasury is thin, lends into the hole, and the baron
	# cannot repay.
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	rc.cargo = {"ORE": 100}
	var r: int = 0
	var lent_at: int = 0
	while r < 60 and w.distress_at("mars").is_empty():
		r += 1
		_boundary(c, r)
		if lent_at == 0 and s.treasury_cr < 12000 and s.debt_cr == 0:
			if not bool(w.open_credit(rc, "mars")["ok"]):
				return "round %d: the pressed baron refused a line" % r
			lent_at = r
	if lent_at == 0 or w.distress_at("mars").is_empty():
		return "never reached distress (round %d, treasury %d, debt %d)" % [r, s.treasury_cr, s.debt_cr]
	if not bool(w.assess_baron(ARES)["insolvent"]) or s.strain < 1:
		return "distress without insolvency"
	if Takeover.claims(w, ARES).get("player", 0) != 12000:
		return "the default is not the player's claim: %s (round %d, lent at %d)" % [str(Takeover.claims(w, ARES)), r, lent_at]
	if bool(rc.assess()["insolvent"]) or rc.pending_bankruptcy:
		return "the levers put the player into Chapter 11"
	# And the lot can be bought: the chain ends where the takeover core takes over.
	var bought: Dictionary = w.buy_shares(rc, "mars", 100)
	if not bool(bought["ok"]):
		return "the distress lot cannot be bought: %s" % str(bought)
	return "ok"


func test_bankruptcy_hands_the_company_to_the_largest_claim_holder() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	s.treasury_cr = 0
	s.treasury_shares = 0
	s.inventory = {}
	w.open_credit(rc, "mars")  # a pressed baron: treasury 0
	var settled: Dictionary = {}
	for r in range(1, 20):
		for e in _boundary(c, r):
			if str(e["kind"]) == "bankrupt":
				settled = e
		if not settled.is_empty():
			break
	if settled.is_empty() or str(settled["holder"]) != "player":
		return "the lender did not take the company: %s" % str(settled)
	if s.holder != "player":
		return "holder %s" % s.holder
	return "ok"


func test_an_open_line_is_called_in_when_the_baron_goes_bankrupt() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	s.treasury_cr = 100
	s.treasury_shares = 0
	w.open_credit(rc, "mars")
	w.add_debt(ARES, 5000000)
	var ev: Dictionary = Takeover.settle(w, ARES, rc)
	if int((ev["paid"] as Dictionary).get("player", 0)) <= 0 and int(ev["owed"]) < 12000:
		return "the open line was not called in: %s" % str(ev)
	if not Levers.credit(w, ARES).is_empty():
		return "the line outlived the settlement"
	return "ok"


# --- the perk and the tender ---

func test_the_perk_is_live_and_cuts_the_players_threshold_to_451() -> String:
	if Parachutes.STATS.get("takeover_threshold_shares", "") != "live":
		return "the stat is not live"
	var tree: Parachutes = Parachutes.load()
	if not tree.validate().is_empty():
		return "shipped tree invalid: %s" % str(tree.validate())
	var p := MetaProfile.new()
	p.severance_points = 5000
	if bool(tree.can_buy(p, "hostile_buyout_line")["ok"]):
		return "bought without a tier-2 prerequisite"
	p.add_unlock("deferred_audit")
	if not bool(tree.buy(p, "hostile_buyout_line")["ok"]):
		return "hostile_buyout_line cannot be bought"
	var mods: Dictionary = tree.modifiers(p)
	if Parachutes.apply_stat(mods, "takeover_threshold_shares", 501) != 451:
		return "modifiers: %s" % str(mods)
	var w: Barons = Barons.for_new_run()
	var rc := RunController.new(p, 5, null, {}, TPR)
	if Takeover.threshold_for(w, "player", rc) != 451 or Takeover.threshold_for(w, "rival_a", rc) != 501 or Takeover.threshold_for(w, "player", RunController.new(null, 5, null, {}, TPR)) != 501:
		return "thresholds: %d %d" % [Takeover.threshold_for(w, "player", rc), Takeover.threshold_for(w, "rival_a", rc)]
	return "ok"


func test_the_player_takes_a_baron_at_451_with_the_perk_and_not_without() -> String:
	var with := _ctx(21, 100000, PERK)
	var w: Barons = with["world"]
	w.add_debt(ARES, 999999)
	w.state(ARES).shares["player"] = 450
	_boundary(with, 1)
	var r: Dictionary = w.buy_shares(with["rc"], "mars", 100)
	if not bool(r["ok"]) or int(r["n"]) != 1 or w.state(ARES).holder != "player":
		return "the 451st share did not take it: %s holder '%s'" % [str(r), w.state(ARES).holder]
	var without := _ctx()
	var w2: Barons = without["world"]
	w2.add_debt(ARES, 999999)
	w2.state(ARES).shares["player"] = 450
	_boundary(without, 1)
	r = w2.buy_shares(without["rc"], "mars", 100)
	# Without the perk the same 450 shares need 51 more: the perk saves 50.
	if int(r["n"]) != 51 or w2.state(ARES).holder != "player" or int(w2.state(ARES).shares["player"]) != 501:
		return "without the perk 450 + 51 should take it at 501: n %d holder '%s'" % [int(r["n"]), w2.state(ARES).holder]
	return "ok"


func test_tender_offers_need_the_perk_and_buy_the_public_float_at_a_premium() -> String:
	var plain := _ctx()
	var w0: Barons = plain["world"]
	var r0: Dictionary = w0.tender_shares(plain["rc"], "mars", 50)
	if bool(r0["ok"]) or r0["reason"] != "LOCKED":
		return "a tender without the perk: %s" % str(r0)
	var c := _ctx(21, 100000, PERK)
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	_boundary(c, 1)
	var o: Dictionary = Takeover.tender_offer(w, ARES, rc)
	# NAV: (60000 + half the stock marked at 300 x 19.25 + 200 x 21.2) / 1000 = 65; x 150% = 97.
	if int(o.get("qty", 0)) != 50 or int(o.get("px", 0)) != 97:
		return "tender offer %s" % str(o)
	if Takeover.public_float(w, ARES) != 400:
		return "public float %d, want 400 (1000 - 600 treasury)" % Takeover.public_float(w, ARES)
	var t0: int = s.treasury_cr
	var r: Dictionary = w.tender_shares(rc, "mars", 50)
	if not bool(r["ok"]) or int(r["n"]) != 50 or int(r["cost"]) != 50 * 97 or rc.cr != 100000 - 50 * 97:
		return "tender: %s cr %d" % [str(r), rc.cr]
	# The cash goes to the sellers, not the treasury; the treasury's shares are untouched.
	if s.treasury_cr != t0 or s.treasury_shares != 600 or int(s.shares["player"]) != 50:
		return "tender touched the treasury: %s" % str(s.to_dict())
	# One tender a round.
	var again: Dictionary = w.tender_shares(rc, "mars", 50)
	if bool(again["ok"]) or again["reason"] != "NO_OFFER":
		return "two tenders in one round: %s" % str(again)
	# The public float runs out after eight rounds' tenders, not before.
	for rd in range(2, 9):
		_boundary(c, rd)
		if not bool(w.tender_shares(rc, "mars", 50)["ok"]):
			return "round %d tender refused" % rd
	if Takeover.public_float(w, ARES) != 0 or int(s.shares["player"]) != 400:
		return "float after 8 tenders: %d, held %d" % [Takeover.public_float(w, ARES), int(s.shares["player"])]
	_boundary(c, 9)
	if not Takeover.tender_offer(w, ARES, rc).is_empty():
		return "a tender with no float left"
	return "ok"


func test_a_tender_cannot_reach_the_threshold_alone() -> String:
	# 400 public shares < 451: the last 51 still have to come from a distress lot.
	var c := _ctx(21, 1000000, PERK)
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	for rd in range(1, 10):
		_boundary(c, rd)
		w.tender_shares(rc, "mars", 50)
	if w.state(ARES).holder != "" or int(w.state(ARES).shares["player"]) != 400:
		return "the tender alone took the baron: %s" % str(w.state(ARES).to_dict())
	w.add_debt(ARES, 999999)
	_boundary(c, 10)
	var r: Dictionary = w.buy_shares(rc, "mars", 100)
	if w.state(ARES).holder != "player" or int(r["n"]) != 51:
		return "tender + a distress lot should take it at 451: %s holder '%s'" % [str(r), w.state(ARES).holder]
	return "ok"


func test_a_tender_is_refused_when_it_would_sink_the_player() -> String:
	var c := _ctx(21, 2000, PERK)
	var w: Barons = c["world"]
	_boundary(c, 1)
	c["rc"].doomsday.add_principal(1900)
	var r: Dictionary = w.tender_shares(c["rc"], "mars", 50)
	if bool(r["ok"]) or r["reason"] not in ["WOULD_BANKRUPT", "NO_CR"]:
		return "tender: %s" % str(r)
	return "ok"


func test_chapter_11_returns_tendered_shares_to_the_public_float() -> String:
	var c := _ctx(21, 100000, PERK)
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	_boundary(c, 1)
	w.tender_shares(rc, "mars", 50)
	w.add_debt(ARES, 999999)
	_boundary(c, 2)
	w.buy_shares(rc, "mars", 30)  # 30 from the treasury at the auction price
	var ts0: int = s.treasury_shares
	if int(s.shares["player"]) != 80 or ts0 != 570:
		return "setup: held %d treasury shares %d" % [int(s.shares["player"]), ts0]
	Takeover.forfeit(w)
	# The 30 treasury shares go home; the 50 tendered return to the public, not the treasury.
	if s.treasury_shares != 600 or s.shares.has("player") or s.scratch.has("tendered") or s.scratch.has("tender"):
		return "forfeit: treasury shares %d %s" % [s.treasury_shares, str(s.scratch)]
	return "ok"


# --- clean-up ---

func test_filing_chapter_11_ends_the_corners_and_the_open_line() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	rc.cargo = {"ORE": 100}
	_boundary(c, 1)
	s.treasury_cr = 5000
	w.open_credit(rc, "mars")
	if not s.scratch.has("corner") or not s.scratch.has("credit"):
		return "setup: %s" % str(s.scratch)
	rc.cr = 0
	rc.doomsday.add_principal(900000)
	var report: Dictionary = rc.file_bankruptcy()
	if s.scratch.has("corner") or s.scratch.has("credit"):
		return "the failed corp's levers survived the filing: %s (%s)" % [str(s.scratch), str(report.keys())]
	return "ok"


func test_a_takeover_cancels_the_line_the_taker_extended() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	s.treasury_cr = 5000
	w.open_credit(rc, "mars")
	Takeover.take(w, ARES, "player", rc)
	if not Levers.credit(w, ARES).is_empty() or s.scratch.has("corner"):
		return "levers outlived the takeover: %s" % str(s.scratch)
	return "ok"


# --- the UI path ---

func test_the_credit_action_is_bound_named_and_off_the_locked_controls() -> String:
	if not InputMap.has_action(M0Loop.ACT_CREDIT) or not M0Loop.ALL_ACTIONS.has(M0Loop.ACT_CREDIT):
		return "m0_credit is not bound or not remappable"
	# Locked controls: LB/RB tabs, LT/RT stations, R-stick commodity, D-pad ladder and quantity.
	var locked: Array = [M0Loop.ACT_TAB_PREV, M0Loop.ACT_TAB_NEXT, M0Loop.ACT_STATION_PREV, M0Loop.ACT_STATION_NEXT, M0Loop.ACT_COMMODITY_PREV, M0Loop.ACT_COMMODITY_NEXT, M0Loop.ACT_UP, M0Loop.ACT_DOWN, M0Loop.ACT_LEFT, M0Loop.ACT_RIGHT]
	var mine: Array = []
	for e in InputMap.action_get_events(M0Loop.ACT_CREDIT):
		mine.append(e)
	for a in InputMap.get_actions():
		if not str(a).begins_with("m0_") or str(a) == M0Loop.ACT_CREDIT:
			continue
		for e in InputMap.action_get_events(a):
			for m in mine:
				if e is InputEventJoypadButton and m is InputEventJoypadButton and e.button_index == m.button_index:
					return "R3 is also bound to %s" % a
				if e is InputEventKey and m is InputEventKey and e.physical_keycode == m.physical_keycode:
					return "G is also bound to %s" % a
	for a in locked:
		if not InputMap.has_action(a):
			return "locked action %s vanished" % a
	if Loc.t("SET_ACT_CREDIT") != "Extend credit line":
		return "no settings label"
	return "ok"


func test_the_credit_key_extends_the_line_and_a_refusal_says_why() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var w: Barons = c["world"]
	var rc: RunController = c["rc"]
	if lp.dispatch_action(M0Loop.ACT_CREDIT) or lp.last_credit_reason != "NOT_PRESSED":
		return "a flush baron took the line: '%s'" % lp.last_credit_reason
	if not _any(_texts(c["hud"]), "Credit line refused: the baron is not short of cash"):
		return "no refusal headline: %s" % str(_texts(c["hud"]))
	w.state(ARES).treasury_cr = 1000
	if not lp.dispatch_action(M0Loop.ACT_CREDIT) or rc.cr != 90000:
		return "the key did not extend the line: '%s'" % lp.last_credit_reason
	if not _any(_texts(c["hud"]), "takes your credit line: 10000 CR at 20%, 12000 CR due round 5"):
		return "no acceptance headline: %s" % str(_texts(c["hud"]))
	if lp.dispatch_action(M0Loop.ACT_CREDIT) or lp.last_credit_reason != "OPEN":
		return "a second line: '%s'" % lp.last_credit_reason
	rc.docked_at = ""
	if lp.dispatch_action(M0Loop.ACT_CREDIT):
		return "the key did something away from a dock"
	return "ok"


func test_the_trade_feed_reaches_the_baron_through_the_focus_signal() -> String:
	var c := _ctx()
	var hud: OrbitalHUD = c["hud"]
	var w: Barons = c["world"]
	hud.gamepad_focus.order_executed.emit({"station": "mars", "commodity": "ORE", "side": "SELL", "qty": 20, "price": 16.0, "total_cr": 320})
	if int(w.state(ARES).pressure_bps.get("ORE", 0)) != 800:
		return "pressure %s" % str(w.state(ARES).pressure_bps)
	hud.gamepad_focus.order_executed.emit({"station": "mars", "commodity": "ORE", "side": "BUY", "qty": 20, "price": 16.0, "total_cr": 320})
	if int(w.state(ARES).pressure_bps.get("ORE", 0)) != 800:
		return "a purchase added pressure"
	return "ok"


func test_a_real_sell_order_at_the_anchor_leans_on_the_collateral() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var hud: OrbitalHUD = c["hud"]
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	rc.cargo = {"ORE": 60}
	lp.set_tab(M0Loop.Tab.MARKET)
	hud.set_commodity("ORE")
	hud.gamepad_focus.set_order_side(GamepadFocus.OrderSide.SELL)
	hud.gamepad_focus.snap_depth_level(3)
	hud.gamepad_focus.set_quantity(50)
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "the sell was rejected: %s" % hud.gamepad_focus.last_rejection_reason
	if int(w.state(ARES).pressure_bps.get("ORE", 0)) != 2000:
		return "50 units sold left pressure %s" % str(w.state(ARES).pressure_bps)
	var ev: Array = _boundary(c, 1)
	if not _kinds(ev, ARES).has("lever_margin"):
		return "the dump did not call the loan: %s" % str(_kinds(ev))
	return "ok"


func test_the_sidebar_notes_follow_the_levers() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var w: Barons = c["world"]
	var rc: RunController = c["rc"]
	rc.cargo = {"ORE": 30}
	var rows: Array = lp.lever_notes("mars")
	if rows.size() != 1 or rows[0]["text"] != "CORNER ORE: HOLD 60, HAVE 30":
		return "idle rows: %s" % str(rows)
	rc.cargo = {"ORE": 100}
	_boundary(c, 1)
	rows = lp.lever_notes("mars")
	if rows[0]["text"] != "CORNERED ORE" or rows[0]["kind"] != "chip" or rows[1]["text"] != "COVER: 100 FROM STOCK, 0 CR A ROUND":
		return "corner rows: %s" % str(rows)
	w.record_trade("mars", "ORE", "SELL", 50)
	w.state(ARES).treasury_cr = 1000
	var texts: Array = []
	for n in lp.lever_notes("mars"):
		texts.append(str(n["text"]))
	for want in ["MARGIN PRESSURE", "ORE PRESSURE -20%", "CREDIT LINE OFFER", "10000 CR @ 20%, DUE IN 5 RDS", "G / R3 EXTENDS THE LINE"]:
		if not texts.has(want):
			return "missing row '%s' in %s" % [want, str(texts)]
	if not str(texts[texts.find("MARGIN PRESSURE") + 1]).begins_with("COLLATERAL ") or not texts.any(func(t): return str(t).ends_with("CALL BELOW 105%")):
		return "margin row: %s" % str(texts)
	w.open_credit(rc, "mars")
	texts = []
	for n in lp.lever_notes("mars"):
		texts.append(str(n["text"]))
	if not texts.has("CREDIT LINE") or not texts.has("OWES YOU 12000 CR, DUE RD 6"):
		return "open-line rows: %s" % str(texts)
	w.state(ARES).holder = "player"
	if not lp.lever_notes("mars").is_empty() or lp.lever_tag("mars", "ORE") != "":
		return "a held baron still shows levers"
	if not lp.lever_notes("luna").is_empty():
		return "levers at a station with no baron"
	return "ok"


func test_the_shares_key_tenders_when_no_lot_is_on_offer() -> String:
	var c := _ctx(21, 100000, PERK)
	var lp: M0Loop = c["loop"]
	var w: Barons = c["world"]
	var rc: RunController = c["rc"]
	_boundary(c, 1)
	var rows: Array = []
	for n in lp.lever_notes("mars"):
		rows.append(str(n["text"]))
	for want in ["TENDER OFFER", "TENDER: 50 SHARES @ 97 CR", "YOU HOLD 0 OF 451 SHARES", "F / L3 BUYS THE LOT"]:
		if not rows.has(want):
			return "missing '%s' in %s" % [want, str(rows)]
	if not lp.dispatch_action(M0Loop.ACT_SHARES) or int(w.state(ARES).shares["player"]) != 50:
		return "the key did not tender: '%s'" % lp.last_shares_reason
	if not _any(_texts(c["hud"]), "You tender for 50 ARES HEAVY shares at 97 CR each: 50 of 451 held"):
		return "no tender headline: %s" % str(_texts(c["hud"]))
	if lp.dispatch_action(M0Loop.ACT_SHARES):
		return "a second tender in the same round"
	var plain := _ctx()
	if plain["loop"].dispatch_action(M0Loop.ACT_SHARES):
		return "the key bought shares with no perk and no lot"
	if not (plain["loop"] as M0Loop).lever_notes("mars").all(func(n): return str(n["tone"]) != "tender"):
		return "tender rows without the perk"
	return "ok"


func test_the_lever_headlines_read_well() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	lp._post_baron_event({"kind": "lever_corner", "baron": ARES, "commodity": "ORE", "round": 1, "from_stock": 100, "cost": 0, "unpaid": 0})
	lp._post_baron_event({"kind": "lever_corner", "baron": ARES, "commodity": "ORE", "round": 2, "from_stock": 0, "cost": 2475, "unpaid": 475})
	lp._post_baron_event({"kind": "lever_corner_end", "baron": ARES, "commodity": "ORE"})
	lp._post_baron_event({"kind": "lever_margin", "baron": ARES, "commodities": ["ORE"], "units": 90, "proceeds": 650, "fee": 90, "deficiency": 2350})
	lp._post_baron_event({"kind": "credit_repaid", "baron": ARES, "due": 12000})
	lp._post_baron_event({"kind": "credit_default", "baron": ARES, "due": 12000})
	var t: Array = _texts(c["hud"])
	for want in ["ARES HEAVY is cornered on ORE: 100 units of cover from stock, 0 CR bought at the squeeze", "ARES HEAVY cannot pay for its cover: 475 CR added to its debt", "the ORE corner ends", "ARES HEAVY margin call: 90 units sold at a haircut for 650 CR, 2350 CR written off as debt", "repays your credit line: 12000 CR", "defaults on your credit line: 12000 CR added to its debt, your claim"]:
		if not _any(t, want):
			return "missing headline '%s' in %s" % [want, str(t)]
	return "ok"


# --- determinism: save / load / continue (seeds 84 and 7) ---

## Drives every lever as a pure function of the run's own state, so a resumed run plays
## exactly as the uninterrupted one: the player sits on a full hold of ORE at Mars, dumps
## 50 units at round 2, and extends a credit line once Ares's treasury is thin.
func _drive(rc: RunController, lp: M0Loop) -> void:
	var w: Barons = rc.world
	if w == null or rc.docked_at != "mars":
		return
	var s: BaronState = w.state(ARES)
	if s.holder != "":
		return
	if rc.get_current_round() >= 1 and int(rc.cargo.get("ORE", 0)) < 100 and not rc.is_in_transit():
		rc.cargo["ORE"] = 100
	if rc.get_current_round() == 2 and s.pressure_bps.is_empty():
		w.record_trade("mars", "ORE", "SELL", 50)
	if s.treasury_cr < 40000 and Levers.credit(w, ARES).is_empty() and not Takeover.claims(w, ARES).has("player") and rc.cr > 20000:
		lp.extend_credit()


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
	var total: int = 3600
	var whole := _session(p_seed)
	_play(whole, total)
	var ws: BaronState = whole.controller.world.state(ARES)
	if ws.treasury_cr >= 60000 or ws.margin_debt_cr >= 9000 or ws.debt_cr == 0 or not Takeover.claims(whole.controller.world, ARES).has("player"):
		return "seed %d: the levers never bit in the uninterrupted run: %s" % [p_seed, str(ws.to_dict())]
	var split := _session(p_seed)
	var stop: Callable = func(): return not Levers.credit(split.controller.world, ARES).is_empty()
	var used: int = _play(split, total, stop)
	if used >= total:
		return "seed %d: no credit line was ever open to split on" % p_seed
	var cap: Dictionary = RunSave.capture(split.controller, split.loop.market, split.bags)
	var via_json: Dictionary = RunSave.restore(_json(cap))
	if not bool(via_json["ok"]) or RunSave.state_hash(via_json["controller"], via_json["market"], via_json["bags"]) != split.state_hash():
		return "seed %d: the save file round trip changed the hash" % p_seed
	var rw: Barons = (via_json["controller"] as RunController).world
	if Levers.credit(rw, ARES) != Levers.credit(split.controller.world, ARES) or Levers.corners(rw, ARES) != Levers.corners(split.controller.world, ARES) or Levers.pressure(rw, ARES) != Levers.pressure(split.controller.world, ARES):
		return "seed %d: lever state did not survive the JSON round trip" % p_seed
	var back := _resume(cap)
	var lp: M0Loop = back["loop"]
	if lp.lever_notes("mars").size() < 2:
		return "seed %d: the sidebar notes did not come back" % p_seed
	for i in total - used:
		if lp.overlay_state == M0Loop.OVERLAY_CONTRACT:
			lp.decline_contract()
		elif lp.overlay_state == M0Loop.OVERLAY_CRISIS:
			lp.acknowledge_crisis()
		elif lp.overlay_state == M0Loop.OVERLAY_NONE and back["rc"].sim_clock.paused and not back["rc"].pending_bankruptcy:
			back["rc"].sim_clock.resume()
		_drive(back["rc"], lp)
		lp.advance(Replay.DEFAULT_FRAME_DELTA)
	if RunSave.state_hash(back["rc"], lp.market, back["bags"]) != whole.state_hash():
		return "seed %d: save/load/continue diverged from the uninterrupted run" % p_seed
	return "ok"


func test_continue_equals_uninterrupted_with_every_lever_in_play() -> String:
	for sd in [84, 7]:
		var r := _continue_equal(sd)
		if r != "ok":
			return r
	return "ok"


func test_the_same_lever_run_hashes_the_same_twice() -> String:
	var a := _session(84)
	_play(a, 3600)
	var b := _session(84)
	_play(b, 3600)
	if a.state_hash() != b.state_hash():
		return "the same lever run hashed twice differently"
	if _session(7).state_hash() == a.state_hash():
		return "two seeds hashed alike"
	return "ok"
