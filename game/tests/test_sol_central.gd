extends RefCounted
## Epic 3 task 6 (part of #16, Baron Archetype AIs): Sol Central. The ported
## find_clearing_price (parity with the Python fixture), the auction schedule, the
## order buffer, the rig and its invariants, the indicative price row, withdrawal,
## a held baron, Chapter 11 and departure, GalNet lines and tags, the
## random-never-forces-Chapter-11 rule, and save/load/continue equality (seeds 84
## and 7) with an auction buffered.

const Loader = preload("res://tests/golden/golden_loader.gd")
const FRAME: float = 1.0 / 60.0 + 0.0001
const TPR: int = 30
const SOL: String = "sol_central"
const CLEARING_FIXTURE: String = "res://tests/golden/clearing/clearing_price.json"


## A docked run with a world on a 30-tick round, starting at Earth (Sol Central's).
func _ctx(p_seed: int = 21) -> Dictionary:
	var rc := RunController.new(null, p_seed, null, {}, TPR)
	rc.world = Barons.for_new_run()
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("earth")
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


func _kinds(events: Array) -> Array:
	var out: Array = []
	for e in events:
		out.append(str(e["kind"]))
	return out


## Puts the clock inside round `r` (what the auction schedule reads).
func _at(c: Dictionary, r: int) -> void:
	(c["rc"] as RunController).sim_clock.total_ticks = r * TPR


func _auction(c: Dictionary, r: int) -> Dictionary:
	return (c["world"] as Barons).auction_at("earth", r, (c["rc"] as RunController).run_seed)


## Queues a BUY of `qty` at `limit` in the auction open in round `r`.
func _queue(c: Dictionary, r: int, side: String, qty: int, limit: int) -> Dictionary:
	_at(c, r)
	return (c["world"] as Barons).submit_auction_order(c["rc"], "earth", side, qty, limit)


## The round boundary the way M0Loop runs it: world step (closing the auction of
## round r-1), mods, reseed. Events are Sol Central's only.
func _boundary(c: Dictionary, r: int) -> Array:
	var w: Barons = c["world"]
	var m: StationMarket = c["market"]
	_at(c, r)
	var ev: Array = w.advance_round(r, c["rc"], m)
	m.set_world_mods(w.market_mods())
	m.replenish()
	return ev.filter(func(e): return str(e.get("baron", "")) == SOL)


func _buffer(c: Dictionary) -> Array:
	return SolCentral.buffer(c["world"], SOL)


func _best_ask(c: Dictionary, commodity: String) -> int:
	return int((c["market"] as StationMarket).ladder("earth", commodity, 1)["best_ask"])


func _with_params(c: Dictionary, key: String, value: Variant) -> void:
	for d in (c["world"] as Barons).data["barons"]:
		if str(d["id"]) == SOL:
			d["params"][key] = value


# --- the ported function: parity with the Python ---

func test_find_clearing_price_matches_the_python_fixture() -> String:
	var loaded: Dictionary = Loader.load_fixture(CLEARING_FIXTURE)
	if str(loaded["error"]) != "":
		return str(loaded["error"])
	var cases: Array = loaded["data"].get("cases", [])
	if cases.size() < 10:
		return "the fixture has only %d cases" % cases.size()
	for k in cases:
		var bids: Array = []
		var asks: Array = []
		for b in k["bids"]:
			bids.append(Order.new("b", "x", "FRAG", "bid", int(b["qty"]), int(b["limit_price"]), 0, 0.0, int(b["filled_qty"])))
		for a in k["asks"]:
			asks.append(Order.new("a", "x", "FRAG", "ask", int(a["qty"]), int(a["limit_price"]), 0, 0.0, int(a["filled_qty"])))
		var got: Dictionary = SolCentral.find_clearing_price(bids, asks, float(k["ref_price"]))
		var want = k["expected"]["price"]
		var want_price: int = -1 if want == null else int(want)
		if int(got["price"]) != want_price or int(got["volume"]) != int(k["expected"]["volume"]):
			return "case %s: port says %s, the Python says %s" % [k["name"], str(got), str(k["expected"])]
	return "ok"


# --- the schedule ---

func test_auctions_open_every_fifth_round_from_the_fifth() -> String:
	var c := _ctx()
	var opened: Array = []
	for r in range(0, 42):
		if not _auction(c, r).is_empty():
			opened.append(r)
	if opened != [5, 10, 15, 20, 25, 30, 35, 40]:
		return "auction rounds were %s" % str(opened)
	return "ok"


func test_the_commodity_is_one_of_sol_centrals_two_and_a_pure_function_of_seed_and_round() -> String:
	var seen: Dictionary = {}
	for sd in [84, 7, 21]:
		var a := _ctx(sd)
		var b := _ctx(sd)
		for r in [5, 10, 15, 20, 25, 30, 35, 40]:
			var x: Dictionary = _auction(a, r)
			var y: Dictionary = _auction(b, r)
			if str(x["commodity"]) != str(y["commodity"]):
				return "seed %d round %d: not repeatable" % [sd, r]
			if not ["FOOD", "FRAG"].has(str(x["commodity"])):
				return "auctioned %s, which Sol Central does not stock" % x["commodity"]
			seen[str(x["commodity"])] = true
	if seen.size() != 2:
		return "only %s was ever auctioned" % str(seen.keys())
	return "ok"


func test_the_close_is_the_next_round_and_the_reference_is_the_base_price() -> String:
	var c := _ctx()
	var au: Dictionary = _auction(c, 15)
	if int(au["close_round"]) != 16 or int(au["round"]) != 15:
		return "bad window: %s" % str(au)
	var want: int = int(round(float(Transit.BASE_PRICES["earth"][au["commodity"]])))
	if int(au["ref_price"]) != want:
		return "reference %d, base price %d" % [au["ref_price"], want]
	return "ok"


func test_a_run_that_queues_nothing_leaves_no_trace() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	var before: Dictionary = w.state(SOL).to_dict()
	for r in range(1, 42):
		_boundary(c, r)
	if w.state(SOL).to_dict() != before:
		return "an unused auction changed Sol Central's state: %s" % str(w.state(SOL).scratch)
	if not w.market_mods().filter(func(m): return str(m.get("station", "")) == "earth" and m.has("price_bps")).is_empty():
		return "Sol Central moved the Earth price"
	return "ok"


func test_boundaries_announce_each_opening() -> String:
	var c := _ctx()
	var opens: Array = []
	for r in range(1, 12):
		for e in _boundary(c, r):
			if str(e["kind"]) == "auction_open":
				opens.append(r)
	if opens != [5, 10]:
		return "openings announced at %s" % str(opens)
	return "ok"


# --- the buffer ---

func test_orders_outside_an_auction_or_on_another_commodity_are_not_queued() -> String:
	var c := _ctx()
	if bool(_queue(c, 4, "BUY", 5, 40)["ok"]):
		return "queued in a non-auction round"
	var au: Dictionary = _auction(c, 5)
	var other: String = "FOOD" if str(au["commodity"]) == "FRAG" else "FRAG"
	var rc: RunController = c["rc"]
	rc.world.state(SOL).scratch.clear()
	# The gamepad path: the other commodity sweeps the book as ever.
	_at(c, 5)
	var hud: OrbitalHUD = c["hud"]
	hud.set_station("earth")
	hud.set_commodity(other)
	hud.gamepad_focus.set_quantity(5)
	hud.gamepad_focus.active_side = GamepadFocus.OrderSide.BUY
	var res: Dictionary = hud.gamepad_focus.execute_focused_order()
	if not bool(res.get("ok", false)) or bool(res.get("buffered", false)):
		return "the other commodity did not sweep: %s" % str(res)
	if not _buffer(c).is_empty():
		return "a sweep landed in the auction buffer"
	return "ok"


func test_the_gamepad_queues_into_the_buffer_without_trading() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var hud: OrbitalHUD = c["hud"]
	_at(c, 5)
	var au: Dictionary = _auction(c, 5)
	hud.set_station("earth")
	hud.set_commodity(str(au["commodity"]))
	hud.gamepad_focus.set_quantity(5)
	hud.gamepad_focus.active_side = GamepadFocus.OrderSide.BUY
	var fills: Array = []
	hud.gamepad_focus.order_executed.connect(func(p): fills.append(p))
	var cr0: int = rc.cr
	var res: Dictionary = hud.gamepad_focus.execute_focused_order()
	if not bool(res.get("ok", false)) or not bool(res.get("buffered", false)):
		return "not queued: %s" % str(res)
	if not fills.is_empty() or rc.cr != cr0 or int(rc.cargo.get(str(au["commodity"]), 0)) != 0:
		return "queuing traded: order_executed fired %d times, CR %d -> %d" % [fills.size(), cr0, rc.cr]
	var buf: Array = _buffer(c)
	if buf.size() != 1 or str(buf[0]["side"]) != "BUY" or int(buf[0]["qty"]) != 5:
		return "buffer is %s" % str(buf)
	if not _any(_texts(hud), "queued") and not _any(_texts(hud), "QUEUED"):
		return "no GalNet line for the queued order: %s" % str(_texts(hud))
	return "ok"


func test_the_buffer_is_sorted_by_limit_then_seq() -> String:
	var c := _ctx()
	_queue(c, 5, "BUY", 2, 30)
	_queue(c, 5, "BUY", 3, 28)
	_queue(c, 5, "BUY", 4, 30)
	var got: Array = _buffer(c).map(func(o): return [int(o["limit"]), int(o["seq"])])
	if got != [[28, 2], [30, 1], [30, 3]]:
		return "order was %s" % str(got)
	return "ok"


func test_submit_checks_what_the_player_can_pay_and_hold() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	rc.cr = 100
	if str(_queue(c, 5, "BUY", 50, 40)["reason"]) != "INSUFFICIENT_CR":
		return "an unaffordable bid was queued"
	rc.cr = 100000
	rc.cargo_capacity = 3
	if str(_queue(c, 5, "BUY", 5, 40)["reason"]) != "INSUFFICIENT_CARGO_CAPACITY":
		return "a bid past the hold was queued"
	if str(_queue(c, 5, "SELL", 1, 10)["reason"]) != "INSUFFICIENT_CARGO":
		return "a sale of nothing was queued"
	var com: String = str(_auction(c, 5)["commodity"])
	rc.cargo[com] = 4
	if not bool(_queue(c, 5, "SELL", 3, 10)["ok"]) or str(_queue(c, 5, "SELL", 3, 10)["reason"]) != "INSUFFICIENT_CARGO":
		return "queued sales must add up against the cargo held"
	return "ok"


# --- the clear and the rig ---

## A cross: the player bids `qty` at `limit` for the auctioned commodity in round 5.
func _bid(c: Dictionary, qty: int, limit: int) -> String:
	var com: String = str(_auction(c, 5)["commodity"])
	if not bool(_queue(c, 5, "BUY", qty, limit)["ok"]):
		return ""
	return com


func test_a_rigged_clear_prints_one_price_inside_the_rig_and_settles_it() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var com: String = str(_auction(c, 5)["commodity"])
	var limit: int = _best_ask(c, com) + 12
	_bid(c, 8, limit)
	var res: Dictionary = SolCentral.resolve(c["world"], SOL, com, _buffer(c), c["market"])
	if int(res["price"]) < 0 or int(res["volume"]) != 8:
		return "no clear: %s" % str(res)
	var honest: int = int(res["honest"])
	var rig: int = SolCentral.rig_cr(c["world"], SOL, honest)
	if not bool(res["rigged"]) or int(res["price"]) != honest + rig:
		return "Sol holds stock, so it rigs up by %d: honest %d, printed %d" % [rig, honest, res["price"]]
	var cr0: int = rc.cr
	var ev: Array = _boundary(c, 6)
	if not _kinds(ev).has("auction_clear"):
		return "no clear event: %s" % str(_kinds(ev))
	var price: int = int(res["price"])
	if rc.cr != cr0 - 8 * price or int(rc.cargo.get(com, 0)) != 8:
		return "settled %d CR for %d units, expected %d for 8" % [cr0 - rc.cr, int(rc.cargo.get(com, 0)), 8 * price]
	if price > limit:
		return "filled above the limit"
	if not _buffer(c).is_empty() or c["world"].state(SOL).scratch.has("buffer"):
		return "the buffer survived the clear"
	return "ok"


func test_the_rig_invariants_hold_across_limits() -> String:
	var c := _ctx()
	var com: String = str(_auction(c, 5)["commodity"])
	var base: int = _best_ask(c, com)
	var saw_fill: bool = false
	var saw_lapse: bool = false
	for extra in range(0, 14):
		var w: Barons = c["world"]
		w.state(SOL).scratch.clear()
		var limit: int = base + extra
		_queue(c, 5, "BUY", 4, limit)
		var orders: Array = _buffer(c)
		var res: Dictionary = SolCentral.resolve(w, SOL, com, orders, c["market"])
		if int(res["honest"]) < 0:
			continue
		var honest: int = int(res["honest"])
		var rig: int = SolCentral.rig_cr(w, SOL, honest)
		var price: int = int(res["price"])
		if absi(price - honest) > rig:
			return "limit %d: printed %d is more than %d from honest %d" % [limit, price, rig, honest]
		var f: int = int(res["fills"].get(int(orders[0]["seq"]), 0))
		if f > 0 and price > limit:
			return "limit %d: a fill at %d is outside the limit" % [limit, price]
		if f > 4:
			return "filled more than asked"
		if int(res["volume"]) > 4:
			return "limit %d: more traded (%d) than the player queued" % [limit, res["volume"]]
		if price > limit and f != 0:
			return "limit %d: filled outside the rigged price" % limit
		saw_fill = saw_fill or f > 0
		saw_lapse = saw_lapse or (f == 0 and price > limit)
	if not saw_fill or not saw_lapse:
		return "the sweep never showed both a fill and a lapse (fill %s, lapse %s)" % [str(saw_fill), str(saw_lapse)]
	return "ok"


func test_a_limit_the_rig_walks_past_lapses_and_costs_only_the_missed_trade() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var com: String = str(_auction(c, 5)["commodity"])
	var base: int = _best_ask(c, com)
	var lapse_limit: int = -1
	for extra in range(0, 14):
		c["world"].state(SOL).scratch.clear()
		_queue(c, 5, "BUY", 4, base + extra)
		var res: Dictionary = SolCentral.resolve(c["world"], SOL, com, _buffer(c), c["market"])
		if int(res["honest"]) >= 0 and int(res["price"]) > base + extra and int(res["honest"]) <= base + extra:
			lapse_limit = base + extra
			break
	if lapse_limit < 0:
		return "no limit sat between the honest and the rigged price"
	c["world"].state(SOL).scratch.clear()
	_queue(c, 5, "BUY", 4, lapse_limit)
	var cr0: int = rc.cr
	var ev: Array = _boundary(c, 6)
	if _kinds(ev).has("auction_clear") or not _kinds(ev).has("auction_lapse"):
		return "expected a lapse only: %s" % str(_kinds(ev))
	if rc.cr != cr0 or int(rc.cargo.get(com, 0)) != 0:
		return "a lapsed order still moved CR or cargo"
	return "ok"


func test_the_rig_runs_the_other_way_when_sol_is_out_of_stock() -> String:
	var c := _ctx()
	var com: String = str(_auction(c, 5)["commodity"])
	(c["world"] as Barons).state(SOL).inventory[com] = 0
	_queue(c, 5, "BUY", 6, _best_ask(c, com) + 12)
	var res: Dictionary = SolCentral.resolve(c["world"], SOL, com, _buffer(c), c["market"])
	var honest: int = int(res["honest"])
	if int(res["price"]) != honest - SolCentral.rig_cr(c["world"], SOL, honest):
		return "an empty Sol should rig down: honest %d, printed %d" % [honest, res["price"]]
	return "ok"


func test_no_rig_means_the_honest_price() -> String:
	var c := _ctx()
	_with_params(c, "rig_bps_max", 0)
	var com: String = str(_auction(c, 5)["commodity"])
	_queue(c, 5, "BUY", 6, _best_ask(c, com) + 12)
	var res: Dictionary = SolCentral.resolve(c["world"], SOL, com, _buffer(c), c["market"])
	if bool(res["rigged"]) or int(res["price"]) != int(res["honest"]):
		return "rig_bps_max 0 still moved the price: %s" % str(res)
	return "ok"


func test_a_sale_to_the_auction_clears_at_the_printed_price() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var com: String = str(_auction(c, 5)["commodity"])
	rc.cargo[com] = 10
	# Out of stock, Sol rigs down: a seller's price is shaved but still crosses the bids
	# (rigged up it would walk past every bid and the sale would lapse).
	(c["world"] as Barons).state(SOL).inventory[com] = 0
	var bid: int = int((c["market"] as StationMarket).ladder("earth", com, 1)["best_bid"])
	_queue(c, 5, "SELL", 5, maxi(1, bid - 12))
	var res: Dictionary = SolCentral.resolve(c["world"], SOL, com, _buffer(c), c["market"])
	if int(res["price"]) < 0:
		return "a deep-in-the-money sale found no cross"
	var cr0: int = rc.cr
	var ev: Array = _boundary(c, 6)
	if not _kinds(ev).has("auction_clear"):
		return "no clear: %s" % str(_kinds(ev))
	if int(rc.cargo.get(com, 0)) != 5 or rc.cr != cr0 + 5 * int(res["price"]):
		return "sale settled wrongly: cargo %d, CR %+d" % [int(rc.cargo.get(com, 0)), rc.cr - cr0]
	return "ok"


func test_the_clear_rechecks_what_the_player_can_still_pay_for() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var com: String = str(_auction(c, 5)["commodity"])
	_queue(c, 5, "BUY", 10, _best_ask(c, com) + 12)
	rc.cr = 0  # the money went elsewhere while the auction was open
	var ev: Array = _boundary(c, 6)
	if _kinds(ev).has("auction_clear") or rc.cr < 0 or int(rc.cargo.get(com, 0)) != 0:
		return "an unaffordable bid still traded: CR %d, %s" % [rc.cr, str(_kinds(ev))]
	return "ok"


func test_leaving_the_dock_before_the_close_lapses_the_orders() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	_queue(c, 5, "BUY", 5, 60)
	var out: Dictionary = rc.depart("mars")
	if not bool(out.get("ok", false)):
		return "could not depart: %s" % str(out)
	if not _buffer(c).is_empty():
		return "queued orders followed the ship"
	return "ok"


# --- the indicative price row ---

func test_the_indicative_row_shows_the_rig_against_the_reference() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var lp: M0Loop = c["loop"]
	var com: String = str(_auction(c, 5)["commodity"])
	_at(c, 5)
	var empty: Array = lp.auction_lines("earth", com)
	if empty.size() != 2 or not str(empty[1]).contains("NO CROSS YET"):
		return "an empty buffer should read NO CROSS YET: %s" % str(empty)
	_queue(c, 5, "BUY", 6, _best_ask(c, com) + 12)
	var ind: Dictionary = c["world"].indicative_at("earth", 5, rc.run_seed, c["market"])
	var lines: Array = lp.auction_lines("earth", com)
	if int(ind["price"]) <= int(ind["ref"]) - 1 and int(ind["price"]) < 0:
		return "no indicative price with a cross queued"
	if not str(lines[1]).contains("INDICATIVE %d CR" % int(ind["price"])) or not str(lines[1]).contains("REF %d" % int(ind["ref"])):
		return "the row does not show indicative vs reference: %s" % str(lines)
	if not lines.has("B WITHDRAWS"):
		return "no withdraw hint: %s" % str(lines)
	if lp.auction_tag("earth", com) != "AUCTION" or lp.auction_tag("earth", "ORE") != "":
		return "the AUCTION tag is on the wrong books"
	_at(c, 6)
	if not lp.auction_lines("earth", com).is_empty():
		return "the row outlived the auction"
	return "ok"


func test_a_queued_order_the_rig_walks_past_is_flagged_before_the_close() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var com: String = str(_auction(c, 5)["commodity"])
	_queue(c, 5, "BUY", 6, _best_ask(c, com))
	var lines: Array = lp.auction_lines("earth", com)
	if not str(lines[2]).contains("MISSES"):
		return "a top-of-book bid is rigged out of the fill but not flagged: %s" % str(lines)
	c["world"].state(SOL).scratch.clear()
	_queue(c, 5, "BUY", 6, _best_ask(c, com) + 12)
	if str(lp.auction_lines("earth", com)[2]).contains("MISSES"):
		return "a bid with room is flagged as missing"
	return "ok"


func test_the_delayed_leak_hides_the_indicative_price() -> String:
	var c := _ctx()
	_with_params(c, "indicative_leak", "delayed")
	var lp: M0Loop = c["loop"]
	var com: String = str(_auction(c, 5)["commodity"])
	_queue(c, 5, "BUY", 6, _best_ask(c, com) + 12)
	var lines: Array = lp.auction_lines("earth", com)
	if not str(lines[1]).contains("HIDDEN"):
		return "the delayed leak still showed a price: %s" % str(lines)
	return "ok"


# --- withdrawal ---

func test_b_on_the_market_tab_withdraws_before_it_leaves_the_tab() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	_queue(c, 5, "BUY", 5, 60)
	lp.set_tab(M0Loop.Tab.MARKET)
	if not lp.dispatch_action(M0Loop.ACT_CANCEL) or not _buffer(c).is_empty():
		return "B did not withdraw the queued order"
	if lp.tab != M0Loop.Tab.MARKET:
		return "the first B left the Market tab"
	lp.dispatch_action(M0Loop.ACT_CANCEL)
	if lp.tab == M0Loop.Tab.MARKET:
		return "the second B did not go back"
	if not _any(_texts(c["hud"]), "withdrawn"):
		return "no GalNet line for the withdrawal"
	return "ok"


func test_a_withdrawn_order_leaves_no_trace_in_the_save() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	var before: Dictionary = w.state(SOL).to_dict()
	_queue(c, 5, "BUY", 5, 60)
	if w.state(SOL).to_dict() == before:
		return "queuing left no state"
	w.withdraw_auction_orders("earth")
	if w.state(SOL).to_dict() != before:
		return "withdrawing left state behind"
	return "ok"


# --- a held baron, Chapter 11, the debt ---

func test_a_held_baron_runs_no_auction_and_drops_the_buffer() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	_queue(c, 5, "BUY", 5, 60)
	w.state(SOL).holder = "player"
	if not _auction(c, 5).is_empty():
		return "a held Sol Central still opens auctions"
	var ev: Array = _boundary(c, 6)
	if not ev.is_empty() or not _buffer(c).is_empty():
		return "a held baron acted: %s" % str(_kinds(ev))
	for r in range(7, 12):
		if not _boundary(c, r).is_empty():
			return "a held baron announced something at round %d" % r
	return "ok"


func test_filing_chapter_11_drops_the_queued_orders() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	_queue(c, 5, "BUY", 5, 60)
	rc.cr = 0
	rc.doomsday.principal_debt = 100000
	if rc.file_bankruptcy().is_empty():
		return "filing refused"
	if not _buffer(c).is_empty():
		return "the dead corp's orders survived the filing"
	return "ok"


func test_sol_central_never_touches_the_debt_or_forces_chapter_11() -> String:
	var c := _ctx()
	# Random baron events (on since task 12) fine the player on their own account; this
	# test is about what an auction does to the debt.
	(c["world"] as Barons).data["consequence"]["random_event_bps"] = 0
	var rc: RunController = c["rc"]
	var com: String = str(_auction(c, 5)["commodity"])
	var debt0: int = rc.doomsday.principal_debt
	# The worst case: every unit the player can afford, bid far above the market.
	_queue(c, 5, "BUY", mini(rc.get_remaining_cargo_capacity(), 40), _best_ask(c, com) + 14)
	for r in range(6, 42):
		_boundary(c, r)
	if rc.doomsday.principal_debt != debt0:
		return "an auction changed the player's debt"
	if bool(rc.assess()["insolvent"]) or rc.cr < 0:
		return "an auction left the corp insolvent (CR %d)" % rc.cr
	return "ok"


# --- determinism ---

func test_the_same_seed_clears_the_same_way() -> String:
	var out: Array = []
	for i in 2:
		var c := _ctx(33)
		var com: String = str(_auction(c, 10)["commodity"])
		_queue(c, 10, "BUY", 7, _best_ask(c, com) + 10)
		var ev: Array = _boundary(c, 11)
		out.append(str(ev) + str((c["rc"] as RunController).cr))
	return "ok" if out[0] == out[1] else "two runs of one seed cleared differently"


# --- GalNet lines ---

func test_the_boundary_events_become_galnet_lines() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var hud: OrbitalHUD = c["hud"]
	Loc.set_locale(Loc.LOCALE_EN)
	var com: String = str(_auction(c, 5)["commodity"])
	for e in _boundary(c, 5):
		lp._post_baron_event(e)
	_queue(c, 5, "BUY", 6, _best_ask(c, com) + 12)
	for e in _boundary(c, 6):
		lp._post_baron_event(e)
	var texts: Array = _texts(hud)
	if not _any(texts, "opens a call auction") or not _any(texts, "SOL CENTRAL"):
		return "no opening line: %s" % str(texts)
	if not _any(texts, "auction clears"):
		return "no clearing line: %s" % str(texts)
	return "ok"


# --- save / load / continue ---

## Queues a 5-unit bid in the auction round, once. A pure function of the run's
## own state, so a resumed run drives itself exactly as the original did.
func _drive(rc: RunController, lp: M0Loop) -> void:
	var w: Barons = rc.world
	if rc.docked_at != "earth" or w == null:
		return
	var au: Dictionary = w.auction_at("earth", rc.get_current_round(), rc.run_seed)
	if au.is_empty() or not w.auction_orders("earth", rc.get_current_round(), rc.run_seed).is_empty():
		return
	var ask: int = int(lp.market.ladder("earth", str(au["commodity"]), 1)["best_ask"])
	w.submit_auction_order(rc, "earth", "BUY", 5, ask + 12)


func _play(s: Replay.Session, frames: int, stop: Callable = Callable()) -> int:
	var used: int = 0
	for i in frames:
		if s.loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			s.loop.decline_contract()
		elif s.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			s.loop.acknowledge_crisis()
		_drive(s.controller, s.loop)
		s.advance()
		used += 1
		if stop.is_valid() and bool(stop.call()):
			break
	return used


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
	var total: int = 1500
	var whole := Replay.Session.new(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	whole.loop.dock_at("earth")
	_play(whole, total)
	var split := Replay.Session.new(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	split.loop.dock_at("earth")
	var stop: Callable = func(): return not SolCentral.buffer(split.controller.world, SOL).is_empty() and split.controller.get_current_round() >= 10
	var used: int = _play(split, total, stop)
	if used >= total:
		return "seed %d: never had an auction buffered to split on" % p_seed
	var cap: Dictionary = RunSave.capture(split.controller, split.loop.market, split.bags)
	var via_json: Dictionary = RunSave.restore(_json(cap))
	if not bool(via_json["ok"]) or RunSave.state_hash(via_json["controller"], via_json["market"], via_json["bags"]) != split.state_hash():
		return "seed %d: the save file round trip changed the hash" % p_seed
	var restored: RunController = via_json["controller"]
	if SolCentral.buffer(restored.world, SOL) != SolCentral.buffer(split.controller.world, SOL):
		return "seed %d: the buffer did not survive the JSON round trip" % p_seed
	var back := _resume(cap)
	var lp: M0Loop = back["loop"]
	if lp.auction_lines("earth", str(SolCentral.buffer(back["rc"].world, SOL)[0]["commodity"])).size() < 3:
		return "seed %d: the indicative row did not come back" % p_seed
	for i in total - used:
		if lp.overlay_state == M0Loop.OVERLAY_CONTRACT:
			lp.decline_contract()
		elif lp.overlay_state == M0Loop.OVERLAY_CRISIS:
			lp.acknowledge_crisis()
		_drive(back["rc"], lp)
		lp.advance(Replay.DEFAULT_FRAME_DELTA)
	if RunSave.state_hash(back["rc"], lp.market, back["bags"]) != whole.state_hash():
		return "seed %d: save/load/continue diverged from the uninterrupted run" % p_seed
	return "ok"


func test_continue_equals_uninterrupted_with_an_auction_buffered() -> String:
	for sd in [84, 7]:
		var r := _continue_equal(sd)
		if r != "ok":
			return r
	return "ok"


func test_a_run_with_auctions_actually_trades() -> String:
	var s := Replay.Session.new(84, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	s.loop.dock_at("earth")
	_play(s, 1500)
	var held: int = int(s.controller.cargo.get("FRAG", 0)) + int(s.controller.cargo.get("FOOD", 0))
	if held <= 0:
		return "no auction ever filled a bid"
	return "ok"
