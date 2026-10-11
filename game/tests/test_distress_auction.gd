extends RefCounted
## #134 (Epic 3 steering): the sealed-bid uniform-price distress auction, the control premium,
## fleet bids, recapture from a fleet, and fleet bankruptcy. Clearing (uniform price, tie-break,
## reserve), the premium curve, fleet bids bounded by their valuation, recapture accept/reject,
## the liquidation path to a forced lot, the docking toll, and determinism / save-restore.

const TPR: int = 30
const ARES: String = "ares_heavy"
const SOL: String = "sol_central"
const TITAN: String = "titan_cryo_hydro"
const KESSLER: String = "kessler_freight"
const BLACKWATER: String = "blackwater_lines"
const EMBER: String = "ember_haulage"


## A world on a 30-tick round. `fleets` keeps the shipped rival fleets.
func _ctx(fleets: bool = false, p_seed: int = 21, cr: int = 100000) -> Dictionary:
	var rc := RunController.new(null, p_seed, null, {}, TPR)
	rc.world = Barons.for_new_run()
	if not fleets:
		rc.world.rivals.clear()
	else:
		rc.world.data["rivals"]["decide_chance_bps"] = 0  # fleets stay home: this is about the auction
		rc.world.data["rivals"]["react_chance_bps"] = 0
	rc.cr = cr
	var m := StationMarket.new()
	m.set_world(rc.world)
	m.set_world_mods(rc.world.market_mods())
	return {"rc": rc, "w": rc.world, "m": m}


func _boundary(c: Dictionary, r: int) -> Array:
	var rc: RunController = c["rc"]
	rc.sim_clock.total_ticks = r * TPR
	var ev: Array = (c["w"] as Barons).advance_round(r, rc, c["m"])
	(c["m"] as StationMarket).set_world_mods((c["w"] as Barons).market_mods())
	(c["m"] as StationMarket).replenish()
	return ev


func _distress(w: Barons, id: String, extra: int = 50000) -> void:
	w.add_debt(id, int(w.assess_baron(id)["liquidation_value"]) + extra)


func _kinds(events: Array) -> Array:
	var out: Array = []
	for e in events:
		out.append(str(e["kind"]))
	return out


func _json(d: Dictionary) -> String:
	return JSON.stringify(d, "", true)


# --- clearing: uniform price, tie-break, reserve ---

func test_every_winner_pays_the_lowest_winning_price() -> String:
	var r: Dictionary = Takeover.fill([
		{"buyer": "a", "qty": 30, "max_price": 20},
		{"buyer": "b", "qty": 30, "max_price": 15},
		{"buyer": "c", "qty": 60, "max_price": 12},
		{"buyer": "d", "qty": 40, "max_price": 8},
	], 100, 7)
	if int(r["price"]) != 12 or int(r["sold"]) != 100:
		return "price %d sold %d, want 12 / 100" % [int(r["price"]), int(r["sold"])]
	var want: Array = [["a", 30], ["b", 30], ["c", 40]]
	for i in want.size():
		if str(r["fills"][i]["buyer"]) != want[i][0] or int(r["fills"][i]["qty"]) != want[i][1]:
			return "fills %s" % str(r["fills"])
	return "ok"


func test_equal_prices_fill_in_sorted_id_order() -> String:
	var r: Dictionary = Takeover.fill([
		{"buyer": "b", "qty": 40, "max_price": 10},
		{"buyer": "a", "qty": 40, "max_price": 10},
	], 50, 5)
	if str(r["fills"][0]["buyer"]) != "a" or int(r["fills"][0]["qty"]) != 40 or int(r["fills"][1]["qty"]) != 10 or int(r["price"]) != 10:
		return "tie fill %s price %d" % [str(r["fills"]), int(r["price"])]
	return "ok"


func test_bids_under_the_reserve_never_fill_and_an_uncontested_lot_clears_at_the_reserve() -> String:
	var r: Dictionary = Takeover.fill([
		{"buyer": "a", "qty": 50, "max_price": 6},
		{"buyer": "b", "qty": 30, "max_price": 40},
	], 100, 7)
	if int(r["sold"]) != 30 or int(r["price"]) != 7 or r["fills"].size() != 1:
		return "reserve: %s" % str(r)
	# No reserve (a forced lot): the price floor is 1 CR.
	var f: Dictionary = Takeover.fill([{"buyer": "a", "qty": 10, "max_price": 90}], 100, 0)
	if int(f["price"]) != 1 or int(f["sold"]) != 10:
		return "forced lot: %s" % str(f)
	return "ok"


func test_a_player_bid_pays_the_reserve_at_the_boundary_not_when_placed() -> String:
	var c := _ctx()
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	_distress(w, ARES)
	_boundary(c, 1)
	var o: Dictionary = w.distress_at("mars")
	if int(o.get("px", 0)) != 7 or int(o.get("qty", 0)) != 100:
		return "lot %s" % str(o)
	var cr0: int = rc.cr
	var res: Dictionary = w.submit_bid(rc, "mars", 100, 50)
	if not bool(res["ok"]) or int(res["n"]) != 100 or rc.cr != cr0 or w.state(ARES).shares.has(Takeover.PLAYER):
		return "placing a bid moved something: %s cr %d" % [str(res), rc.cr]
	var ev: Array = _boundary(c, 2)
	if not _kinds(ev).has("auction"):
		return "no auction event: %s" % str(_kinds(ev))
	# Nobody else bid, so the lot clears at the reserve, not the player's 50.
	if rc.cr != cr0 - 700 or Takeover.shares_of(w, ARES, Takeover.PLAYER) != 100 or w.state(ARES).treasury_shares != 500:
		return "cr %d (want %d), held %d, treasury %d" % [rc.cr, cr0 - 700, Takeover.shares_of(w, ARES, Takeover.PLAYER), w.state(ARES).treasury_shares]
	var info: Dictionary = w.auction_info(ARES, rc)
	if int(info["last_clear"]["px"]) != 7 or int(info["last_clear"]["qty"]) != 100:
		return "last clear %s" % str(info["last_clear"])
	return "ok"


func test_a_bid_is_refused_under_the_reserve_and_can_be_replaced() -> String:
	var c := _ctx()
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	if str(w.submit_bid(rc, "mars", 10, 20)["reason"]) != "NO_OFFER":
		return "a bid with no lot was not refused"
	_distress(w, ARES)
	_boundary(c, 1)
	if str(w.submit_bid(rc, "mars", 10, 6)["reason"]) != "BELOW_RESERVE":
		return "6 CR under a 7 CR reserve was accepted"
	w.submit_bid(rc, "mars", 100, 20)
	w.submit_bid(rc, "mars", 40, 9)
	var pb: Dictionary = Takeover.player_bid(w, ARES)
	if int(pb["qty"]) != 40 or int(pb["px"]) != 9:
		return "replacement bid %s" % str(pb)
	rc.cr = 3
	if str(w.submit_bid(rc, "mars", 10, 20)["reason"]) != "NO_CR":
		return "a bid the player cannot cover was accepted"
	return "ok"


func test_the_clearing_cuts_a_bid_the_player_can_no_longer_pay() -> String:
	var c := _ctx()
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	_distress(w, ARES)
	_boundary(c, 1)
	w.submit_bid(rc, "mars", 100, 20)
	rc.cr = 140  # spent elsewhere in the round: 20 shares at 7 CR
	_boundary(c, 2)
	var held: int = Takeover.shares_of(w, ARES, Takeover.PLAYER)
	if held != 20 or rc.cr != 0:
		return "held %d cr %d, want 20 / 0" % [held, rc.cr]
	return "ok"


# --- the control premium ---

func test_the_premium_curve_is_monotonic_and_hits_its_points() -> String:
	var c := _ctx()
	var w: Barons = c["w"]
	var last: int = -1
	for st in range(0, 10001, 50):
		var p: int = Takeover.premium_bps(w, st)
		if p < last:
			return "premium fell at stake %d bps: %d < %d" % [st, p, last]
		last = p
	if Takeover.premium_bps(w, 0) != 0 or Takeover.premium_bps(w, 5000) != 2000 or Takeover.premium_bps(w, 10000) != 10000:
		return "curve points %d / %d / %d" % [Takeover.premium_bps(w, 0), Takeover.premium_bps(w, 5000), Takeover.premium_bps(w, 10000)]
	if Takeover.premium_bps(w, 6500) != 5500 or Takeover.premium_bps(w, 99999) != 10000:
		return "interpolation %d, clamp %d" % [Takeover.premium_bps(w, 6500), Takeover.premium_bps(w, 99999)]
	return "ok"


func test_a_share_is_worth_more_to_whoever_is_closer_to_control() -> String:
	var c := _ctx()
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	_distress(w, ARES)
	var base: int = Takeover.base_price(w, ARES)
	if w.share_value(ARES, Takeover.PLAYER, rc) != base:
		return "a bidder with no stake pays %d, NAV base is %d" % [w.share_value(ARES, Takeover.PLAYER, rc), base]
	var prev: int = 0
	for n in [0, 100, 250, 400, 500]:
		w.state(ARES).shares[Takeover.PLAYER] = n
		var v: int = w.share_value(ARES, Takeover.PLAYER, rc)
		if v < prev:
			return "value fell at %d shares" % n
		prev = v
	w.state(ARES).shares[Takeover.PLAYER] = 400
	if w.share_value(ARES, Takeover.PLAYER, rc) < base * 2 - 2 * base / 10:
		return "400 of 501 shares is worth only %d against a base of %d" % [w.share_value(ARES, Takeover.PLAYER, rc), base]
	# The Hostile Buyout Line cuts the player's threshold to 451, so the same stake is closer.
	var v501: int = w.share_value(ARES, Takeover.PLAYER, rc)
	rc.modifiers["takeover_threshold_shares"] = {"add": -50, "mul_bps": 10000}
	if w.share_value(ARES, Takeover.PLAYER, rc) <= v501:
		return "the cheaper threshold did not raise the value"
	return "ok"


func test_a_falling_or_malformed_premium_curve_is_rejected() -> String:
	var d: Dictionary = Barons.load_data()
	if not Barons.validate(d).is_empty():
		return "shipped data invalid: %s" % str(Barons.validate(d))
	var bad: Array = [
		[[0, 0], [5000, 2000], [10000, 1000]],
		[[100, 0], [10000, 1000]],
		[[0, 0], [0, 100]],
		[[0, 0]],
	]
	for curve in bad:
		var x: Dictionary = d.duplicate(true)
		x["takeover"]["control_premium"] = curve
		if Barons.validate(x).is_empty():
			return "accepted %s" % str(curve)
	var y: Dictionary = d.duplicate(true)
	y["rivals"]["fleets"][0]["debt_cr"] = -1
	if Barons.validate(y).is_empty():
		return "a negative fleet debt was accepted"
	return "ok"


# --- fleet bids ---

func test_fleets_bid_only_where_they_trade_and_never_above_their_value() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	w.state(ARES).strain = 3
	w.state(SOL).strain = 3
	w.state(TITAN).strain = 3
	var ares: Array = w.rival_bids(ARES, 5, 7, 100, rc)
	var ids: Array = []
	for b in ares:
		ids.append(str(b["buyer"]))
		if int(b["max_price"]) > w.share_value(ARES, str(b["buyer"]), rc):
			return "%s bids %d over its value %d" % [b["buyer"], b["max_price"], w.share_value(ARES, str(b["buyer"]), rc)]
		if int(b["qty"]) * int(b["max_price"]) > w.rival(str(b["buyer"])).cr * 5000 / 10000:
			return "%s bids more than its cash share" % b["buyer"]
	if ids != [BLACKWATER, EMBER]:
		return "Ares (Mars) bidders %s, want the two Mars fleets" % str(ids)
	var sol: Array = w.rival_bids(SOL, 5, 7, 100, rc)
	if sol.size() != 1 or str(sol[0]["buyer"]) != KESSLER:
		return "Sol Central (Earth) bidders %s" % str(sol)
	if not w.rival_bids(TITAN, 5, 7, 100, rc).is_empty():
		return "a fleet bid on a baron at a station it never trades"
	# Not on the off chance: the same call twice gives the same bids.
	if _json({"b": ares}) != _json({"b": w.rival_bids(ARES, 5, 7, 100, rc)}):
		return "bids are not repeatable"
	return "ok"


func test_a_fleet_bids_up_with_its_own_stake() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	w.state(ARES).strain = 3
	var low: int = 0
	for b in w.rival_bids(ARES, 5, 7, 100, rc):
		if str(b["buyer"]) == EMBER:
			low = int(b["max_price"])
	w.state(ARES).shares[EMBER] = 400
	var high: int = 0
	for b in w.rival_bids(ARES, 5, 7, 100, rc):
		if str(b["buyer"]) == EMBER:
			high = int(b["max_price"])
	if low <= 0 or high <= low:
		return "a fleet at 400 shares bids %d, at none %d" % [high, low]
	return "ok"


func test_a_fleet_never_bids_itself_into_insolvency() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	w.state(ARES).strain = 3
	w.rival(EMBER).cr = 6050  # 6,000 of debt: 50 CR of headroom
	for b in w.rival_bids(ARES, 5, 7, 100, rc):
		if str(b["buyer"]) == EMBER and int(b["qty"]) * int(b["max_price"]) > 50:
			return "Ember bids %s with 50 CR of headroom" % str(b)
	return "ok"


func test_fleets_outbid_a_low_player_bid_and_pay_the_uniform_price() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	_distress(w, ARES)
	_boundary(c, 1)
	_boundary(c, 2)  # strain 2: the fleets are in
	if w.distress_at("mars").is_empty():
		return "no lot at round 2"
	var cr0: int = w.rival(BLACKWATER).cr + w.rival(EMBER).cr
	w.submit_bid(rc, "mars", 100, 8)  # over the 7 CR reserve, under the fleets' 10 CR value
	var player_cr: int = rc.cr
	_boundary(c, 3)
	var fleets: int = Takeover.shares_of(w, ARES, BLACKWATER) + Takeover.shares_of(w, ARES, EMBER)
	if fleets != 100 or Takeover.shares_of(w, ARES, Takeover.PLAYER) != 0 or rc.cr != player_cr:
		return "fleets hold %d, player %d, cr %d -> %d" % [fleets, Takeover.shares_of(w, ARES, Takeover.PLAYER), player_cr, rc.cr]
	var px: int = int(w.auction_info(ARES, rc)["last_clear"]["px"])
	var paid: int = cr0 - (w.rival(BLACKWATER).cr + w.rival(EMBER).cr)
	if px < 7 or px > 10 or paid != 100 * px:
		return "clearing %d CR, fleets paid %d for 100 shares" % [px, paid]
	return "ok"


func test_the_player_outbids_the_fleets() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	_distress(w, ARES)
	_boundary(c, 1)
	_boundary(c, 2)
	w.submit_bid(rc, "mars", 100, 14)
	var cr0: int = rc.cr
	_boundary(c, 3)
	if Takeover.shares_of(w, ARES, Takeover.PLAYER) != 100 or Takeover.shares_of(w, ARES, EMBER) != 0:
		return "the higher bid did not win: %s" % str(w.state(ARES).shares)
	if rc.cr != cr0 - 100 * 14:
		return "winner paid %d, want the lowest winning price (its own 14)" % (cr0 - rc.cr)
	var stakes: Array = w.auction_info(ARES, rc)["stakes"]
	if stakes.is_empty():
		return "no bidder stakes exposed"
	return "ok"


func test_the_player_can_win_a_whole_baron_against_the_fleets_by_outbidding() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	rc.cr = 400000
	w.data["takeover"]["auction_cap"] = 200  # bigger lots: fewer rounds, same rule
	_distress(w, ARES, 400000)
	var top: int = 0
	var r: int = 1
	while r <= 14 and w.state(ARES).holder != Takeover.PLAYER:
		_boundary(c, r)
		if not w.distress_at("mars").is_empty():
			# Always a clear margin over the dearest fleet valuation (a fleet's value is capped by its stake).
			top = Takeover.value_per_share(w, ARES, EMBER, rc) * 3
			w.submit_bid(rc, "mars", 200, maxi(top, w.share_value(ARES, Takeover.PLAYER, rc) * 3))
		r += 1
	if w.state(ARES).holder != Takeover.PLAYER or Takeover.shares_of(w, ARES, Takeover.PLAYER) < 501:
		return "after %d rounds holder '%s', stakes %s" % [r, w.state(ARES).holder, str(w.state(ARES).shares)]
	var fleets: int = Takeover.shares_of(w, ARES, EMBER) + Takeover.shares_of(w, ARES, BLACKWATER)
	if fleets >= 501:
		return "a fleet got there first"
	return "ok"


# --- recapture ---

func _fleet_holds_ares(c: Dictionary, shares: int = 501) -> void:
	var w: Barons = c["w"]
	var s: BaronState = w.state(ARES)
	s.shares[EMBER] = shares
	s.treasury_shares = 0
	if shares >= 501:
		s.holder = EMBER


func test_a_fleet_sells_its_stake_back_at_or_above_its_valuation() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	_fleet_holds_ares(c)
	var ask: int = w.share_value(ARES, EMBER, rc)
	var low: Dictionary = w.recapture_shares(rc, "mars", EMBER, 501, ask - 1)
	if bool(low["ok"]) or str(low["reason"]) != "REJECTED" or int(low["ask"]) != ask or w.state(ARES).holder != EMBER:
		return "an offer under the valuation was not rejected: %s" % str(low)
	var cr0: int = rc.cr
	var fleet_cr0: int = w.rival(EMBER).cr
	var ok: Dictionary = w.recapture_shares(rc, "mars", EMBER, 501, ask)
	if not bool(ok["ok"]) or int(ok["n"]) != 501 or w.state(ARES).holder != Takeover.PLAYER:
		return "recapture failed: %s holder %s" % [str(ok), w.state(ARES).holder]
	# Taking the baron also absorbs its treasury into the player's books, so the fleet's side is the clean count.
	if int(ok["cost"]) != 501 * ask or w.rival(EMBER).cr != fleet_cr0 + 501 * ask:
		return "the cash did not reach the fleet: cost %d fleet +%d (cr %d -> %d)" % [int(ok["cost"]), w.rival(EMBER).cr - fleet_cr0, cr0, rc.cr]
	return "ok"


func test_a_recapture_is_dear_and_a_partial_one_costs_the_fleet_control() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	_fleet_holds_ares(c)
	# The fleet at full stake values a share at 2x the base (the curve's 10,000 bps).
	var base: int = Takeover.base_price(w, ARES)
	var ask: int = w.share_value(ARES, EMBER, rc)
	if ask != base * 2:
		return "ask %d, want twice the base %d" % [ask, base]
	var res: Dictionary = w.recapture_shares(rc, "mars", EMBER, 100, ask)
	var kinds: Array = _kinds(res["events"])
	if not bool(res["ok"]) or int(res["n"]) != 100 or w.state(ARES).holder != "" or not kinds.has("control_lost"):
		return "partial recapture: %s holder '%s'" % [str(res), w.state(ARES).holder]
	if Takeover.shares_of(w, ARES, EMBER) != 401 or Takeover.shares_of(w, ARES, Takeover.PLAYER) != 100:
		return "shares %s" % str(w.state(ARES).shares)
	# Poor player: refused, nothing moves.
	rc.cr = 10
	if str(w.recapture_shares(rc, "mars", EMBER, 100, ask)["reason"]) != "NO_CR":
		return "a recapture the player cannot pay was not refused"
	if str(w.recapture_shares(rc, "mars", KESSLER, 10, 999)["reason"]) != "NO_SHARES":
		return "a fleet with no shares sold some"
	if str(w.recapture_shares(rc, "mars", "nobody", 10, 999)["reason"]) != "NO_FLEET":
		return "an unknown fleet sold shares"
	return "ok"


# --- fleet bankruptcy ---

func test_a_fleet_takes_chapter_11_and_liquidates_after_the_set_rounds() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	var h0: Dictionary = w.fleet_health(KESSLER)
	if bool(h0["insolvent"]) or int(h0["headroom"]) <= 0:
		return "a fleet starts insolvent: %s" % str(h0)
	w.state(ARES).shares[KESSLER] = 200
	w.rival(KESSLER).cr = 1000  # against 10,000 of debt
	w.rival(KESSLER).cargo = {}
	var rounds: int = int(Rivals.settings(w)["fleet_bankrupt_rounds"])
	if rounds != 4:
		return "default fleet_bankrupt_rounds is %d" % rounds
	for r in range(1, rounds):
		var ev: Array = Rivals.advance_health(w, r)
		if not ev.is_empty() or w.rival(KESSLER).strain != r or w.rival(KESSLER).gone:
			return "round %d: strain %d gone %s events %s" % [r, w.rival(KESSLER).strain, w.rival(KESSLER).gone, str(ev)]
	var last: Array = Rivals.advance_health(w, rounds)
	if last.size() != 1 or str(last[0]["kind"]) != "rival_bankrupt" or int(last[0]["shares"]) != 200:
		return "liquidation events %s" % str(last)
	if not w.rival(KESSLER).gone or w.rival_ids().has(KESSLER) or w.rival(KESSLER).cr != 0:
		return "the fleet is still in the run"
	if w.state(ARES).shares.has(KESSLER) or int(w.state(ARES).scratch.get("forced", 0)) != 200:
		return "shares %s forced %s" % [str(w.state(ARES).shares), str(w.state(ARES).scratch.get("forced", 0))]
	return "ok"


func test_a_solvent_round_resets_the_fleets_strain() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	w.rival(EMBER).cr = 1000
	Rivals.advance_health(w, 1)
	Rivals.advance_health(w, 2)
	if w.rival(EMBER).strain != 2:
		return "strain %d" % w.rival(EMBER).strain
	w.rival(EMBER).cr = 16000
	Rivals.advance_health(w, 3)
	if w.rival(EMBER).strain != 0 or w.rival(EMBER).gone:
		return "a recovered fleet kept strain %d" % w.rival(EMBER).strain
	return "ok"


func test_a_liquidated_fleets_shares_become_a_forced_lot_with_no_reserve() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	w.state(ARES).shares[KESSLER] = 200
	w.rival(KESSLER).cr = 1000
	for r in range(1, 5):
		Rivals.advance_health(w, r)
	var tcr: int = w.state(ARES).treasury_cr
	var ev: Array = _boundary(c, 5)  # Ares is solvent: the forced lot is still posted
	var o: Dictionary = w.distress_at("mars")
	if o.is_empty() or not bool(o["forced"]) or int(o["px"]) != 0 or int(o["qty"]) != 200:
		return "no forced lot: %s events %s" % [str(o), str(_kinds(ev))]
	# Public float is net of the forced shares.
	if Takeover.public_float(w, ARES) != 1000 - w.state(ARES).treasury_shares - 200:
		return "public float %d counts the forced shares" % Takeover.public_float(w, ARES)
	if not bool(w.submit_bid(rc, "mars", 200, 5)["ok"]):
		return "a bid at 5 CR was refused on a lot with no reserve"
	# The two Mars fleets bid their own value on it; the player outbids them by a wide margin.
	var top: int = 0
	for b in Rivals.bids(w, ARES, 6, 0, 200, rc, true):
		top = maxi(top, int(b["max_price"]))
	w.submit_bid(rc, "mars", 200, top * 3)
	var cr0: int = rc.cr
	var ev6: Array = _boundary(c, 6)
	if Takeover.shares_of(w, ARES, Takeover.PLAYER) != 200 or int(w.state(ARES).scratch.get("forced", 0)) != 0:
		return "forced lot not sold: %s" % str(w.state(ARES).shares)
	var px: int = int(w.auction_info(ARES, rc)["last_clear"]["px"])
	if px < 1 or cr0 - rc.cr != 200 * px or w.state(ARES).treasury_cr != tcr or w.state(ARES).treasury_shares != 600:
		return "the sale paid %d (want 200 x %d) or moved the baron's treasury %s" % [cr0 - rc.cr, px, str(_kinds(ev6))]
	return "ok"


func test_a_bankrupt_fleet_that_held_a_baron_gives_it_back() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	_fleet_holds_ares(c)
	w.rival(EMBER).cr = 500
	var ev: Array = []
	for r in range(1, 5):
		ev = Rivals.advance_health(w, r)
	if ev.size() != 1 or w.state(ARES).holder != "" or int(w.state(ARES).scratch.get("forced", 0)) != 501:
		return "holder '%s' forced %d" % [w.state(ARES).holder, int(w.state(ARES).scratch.get("forced", 0))]
	return "ok"


func test_a_gone_fleet_stays_gone_through_a_save() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	w.rival(EMBER).cr = 500
	for r in range(1, 5):
		Rivals.advance_health(w, r)
	var back: Barons = Barons.from_dict(JSON.parse_string(JSON.stringify(w.to_dict())))
	if back.rival_ids().has(EMBER) or not back.rival(EMBER).gone or back.rival(EMBER).cr != 0:
		return "Ember came back after a save"
	if not (_json(w.to_dict()) == _json(back.to_dict())):
		return "the saved form changed on the round trip"
	# A fleet that never struggled saves exactly as before.
	var fresh := Barons.for_new_run()
	if fresh.rival(KESSLER).to_dict().has("strain") or fresh.rival(KESSLER).to_dict().has("gone"):
		return "a healthy fleet writes the new keys"
	return "ok"


func test_docking_tolls_at_a_player_held_baron_charge_the_fleets_and_pay_the_player() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	if w.docking_toll_due(EMBER, "mars") != 15:
		return "an outsider owes %d at Ares" % w.docking_toll_due(EMBER, "mars")
	w.state(ARES).holder = Takeover.PLAYER
	if w.docking_toll_due(EMBER, "mars") != 15 or w.docking_toll_due(Takeover.PLAYER, "mars") != 0:
		return "the held baron's toll is wrong: fleet %d, player %d" % [w.docking_toll_due(EMBER, "mars"), w.docking_toll_due(Takeover.PLAYER, "mars")]
	var f: RivalFleet = w.rival(EMBER)
	var f0: int = f.cr
	var p0: int = rc.cr
	Rivals._pay_toll(w, f, "mars", rc)
	if f.cr != f0 - 15 or rc.cr != p0 + 15:
		return "fleet %d -> %d, player %d -> %d" % [f0, f.cr, p0, rc.cr]
	return "ok"


# --- the HUD read helpers ---

func test_the_hud_reads_stakes_last_clear_and_fleet_health() -> String:
	var c := _ctx(true)
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	w.state(ARES).shares[EMBER] = 120
	var info: Dictionary = w.auction_info(ARES, rc)
	var seen: Dictionary = {}
	for row in info["stakes"]:
		seen[str(row["bidder"])] = int(row["shares"])
	if int(seen.get(EMBER, -1)) != 120 or not seen.has(Takeover.PLAYER) or not info["last_clear"].is_empty():
		return "stakes %s last %s" % [str(info["stakes"]), str(info["last_clear"])]
	if int(info["your_value"]) != w.share_value(ARES, Takeover.PLAYER, rc):
		return "your_value disagrees with share_value"
	var h: Dictionary = w.fleet_health(BLACKWATER)
	if int(h["cr"]) != 20000 or int(h["debt"]) != 8000 or bool(h["insolvent"]) or int(h["rounds_left"]) != 4:
		return "health %s" % str(h)
	var lp := M0Loop.new(OrbitalHUD.new(rc))
	rc.world = w
	var rows0: Array = lp.fleet_health_lines("mars")
	if rows0 != ["FLEET CASH/DEBT: BLACKWATER 20000/8000, EMBER 16000/6000, KESSLER 24000/10000"] or not lp.fleet_health_lines("").is_empty():
		return "fleet rows %s" % str(rows0)
	w.rival(BLACKWATER).cr = 100
	Rivals.advance_health(w, 1)
	h = w.fleet_health(BLACKWATER)
	if not bool(h["insolvent"]) or int(h["strain"]) != 1 or int(h["rounds_left"]) != 3:
		return "strained health %s" % str(h)
	var rows1: Array = lp.fleet_health_lines("")
	if rows1.size() != 1 or not str(rows1[0]).contains("BLACKWATER LINES INSOLVENT: 100 CR VS 8000 DEBT, 3 RDS LEFT"):
		return "strained rows %s" % str(rows1)
	return "ok"


func test_pressing_the_shares_key_again_raises_the_bid_until_it_outbids_the_fleets() -> String:
	var rc := RunController.new(null, 21, null, {}, TPR)
	rc.world = Barons.for_new_run()
	rc.world.data["rivals"]["decide_chance_bps"] = 0
	rc.world.data["rivals"]["react_chance_bps"] = 0
	rc.cr = 100000
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("mars")
	var w: Barons = rc.world
	_distress(w, ARES)
	for r in [1, 2]:
		rc.sim_clock.total_ticks = r * TPR
		w.advance_round(r, rc, lp.market)
	var top: int = 0
	for b in Rivals.bids(w, ARES, 2, 7, 100, rc):
		top = maxi(top, int(b["max_price"]))
	if top <= 0:
		return "no fleet is bidding on the lot"
	var last: int = 0
	var presses: int = 0
	while int(Takeover.player_bid(w, ARES).get("px", 0)) <= top and presses < 30:
		lp.buy_shares()
		var px: int = int(Takeover.player_bid(w, ARES).get("px", 0))
		if px <= last:
			return "press %d did not raise the bid (%d after %d)" % [presses, px, last]
		last = px
		presses += 1
	rc.sim_clock.total_ticks = 3 * TPR
	w.advance_round(3, rc, lp.market)
	if Takeover.shares_of(w, ARES, Takeover.PLAYER) != 100:
		return "after %d presses (top bid %d vs fleets %d) the player holds %d" % [presses, last, top, Takeover.shares_of(w, ARES, Takeover.PLAYER)]
	return "ok"


func test_the_shares_key_bids_at_the_players_value_and_the_sidebar_says_so() -> String:
	var rc := RunController.new(null, 21, null, {}, TPR)
	rc.world = Barons.for_new_run()
	rc.world.rivals.clear()
	rc.cr = 100000
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("mars")
	var w: Barons = rc.world
	_distress(w, ARES)
	rc.sim_clock.total_ticks = TPR
	w.advance_round(1, rc, lp.market)
	var cr0: int = rc.cr
	if not lp.buy_shares():
		return "the shares key did nothing with a lot standing"
	var pb: Dictionary = Takeover.player_bid(w, ARES)
	if int(pb.get("qty", 0)) != 100 or int(pb.get("px", 0)) != w.share_value(ARES, Takeover.PLAYER, rc) or rc.cr != cr0:
		return "bid %s cr %d -> %d" % [str(pb), cr0, rc.cr]
	var rows: String = " | ".join(lp.takeover_lines("mars"))
	if not rows.contains("YOUR VALUE") or not rows.contains("BID 100 SHARES UP TO") or not rows.contains("RESERVE"):
		return "sidebar: %s" % rows
	return "ok"


# --- determinism ---

func _play(p_seed: int, split_at: int = 0) -> String:
	var c := _ctx(true, p_seed)
	var w: Barons = c["w"]
	var rc: RunController = c["rc"]
	_distress(w, ARES)
	for r in range(1, 9):
		if r == 3 or r == 6:
			w.submit_bid(rc, "mars", 100, 9 + r)
		if r == split_at:
			# Save and restore the world, as a quit and continue would.
			var back: Barons = Barons.from_dict(JSON.parse_string(JSON.stringify(w.to_dict())))
			c["w"] = back
			rc.world = back
			w = back
			(c["m"] as StationMarket).set_world(back)
		_boundary(c, r)
	return _json({"world": w.to_dict(), "cr": rc.cr})


func test_the_same_auction_run_hashes_the_same_twice() -> String:
	for sd in [21, 84]:
		if _play(sd) != _play(sd):
			return "seed %d: two identical runs diverged" % sd
	return "ok"


func test_save_restore_mid_auction_equals_the_uninterrupted_run() -> String:
	for sd in [21, 84]:
		var plain: String = _play(sd)
		for split in [3, 4, 6]:
			if plain != _play(sd, split):
				return "seed %d: restoring at round %d changed the outcome" % [sd, split]
	return "ok"


func test_a_world_in_which_nothing_is_distressed_writes_none_of_the_new_keys() -> String:
	var c := _ctx(true)
	for r in range(1, 6):
		_boundary(c, r)
	var text: String = _json((c["w"] as Barons).to_dict())
	for k in ["forced", "last_clear", "\"bids\"", "\"gone\"", "\"strain\": 1"]:
		if text.contains(k):
			return "a quiet world wrote %s" % k
	return "ok"
