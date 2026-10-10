class_name SolCentral
extends RefCounted
## Sol Central, the auctioneer (Epic 3 task 6, docs/design/epic3-barons.md 4.3).
##
## Every `auction_every_rounds`, Earth runs a call auction for one of Sol Central's
## stock commodities. The auction for round R is open while the clock is in round
## R: the player's orders at Earth for that commodity go into a buffer instead of
## sweeping the book (limit orders, no escrow), and at the next round boundary the
## buffer and Earth's resting book uncross at ONE price.
##  - find_clearing_price() is a port of agora/circuit_breaker.py:43, parity-checked
##    against the Python by tests/golden/clearing (tools/golden/gen_clearing.py).
##  - The rig: Sol Central prints the reference price and, in the cross, injects a
##    balanced bid/ask pair that is large enough for its price to be the only
##    volume-maximising one. The price it picks is the one in
##    [honest - rig, honest + rig] best for its own stock (higher while it holds
##    the commodity, lower when it is out; ties go to the lower price), where
##    `rig` is rig_bps_max of the honest price, at least 1 CR. The pair trades with
##    itself, so only the price moves: a limit order outside it simply lapses.
##  - Indicative price (`indicative_leak`): "full" shows the cross as it stands,
##    "delayed" hides it until the auction has closed.
##
## Whether an auction is open, and on what commodity, is a pure function of
## (run_seed, round): nothing is stored for it. The only saved state is the
## player's order buffer, scratch["buffer"], an Array of {seq, side, qty, limit,
## round, commodity} kept sorted by (limit, seq) and written only while it holds an
## order, so a run that never queues one hashes exactly as before. No RNG sits in
## the clearing; the one draw is the commodity, from
## hash32("baron-<id>-<run_seed>-<round>"). Sol Central moves no market mods and
## never touches the player's debt, so none of its events can force Chapter 11:
## the only cost to the player is the price of a trade they chose to queue.
## Every scratch read goes through int() (JSON numbers come back as floats).

const SIDE_BUY: String = "BUY"
const SIDE_SELL: String = "SELL"
const PLAYER: String = "player"


# --- the ported function ---

## Port of agora/circuit_breaker.py find_clearing_price. The single call-auction
## price that maximises executable volume; ties go to the price closest to
## `ref_price`, then the lower one. Returns {price, volume}; price is -1 where the
## Python returns None (an empty side, or no volume).
static func find_clearing_price(bids: Array, asks: Array, ref_price: float) -> Dictionary:
	if bids.is_empty() or asks.is_empty():
		return {"price": -1, "volume": 0}
	var seen: Dictionary = {}
	for o: Order in bids:
		seen[o.limit_price] = true
	for o: Order in asks:
		seen[o.limit_price] = true
	var prices: Array = seen.keys()
	prices.sort()
	var max_volume: int = 0
	var best: Array = []
	for p: int in prices:
		var buy_vol: int = 0
		for o: Order in bids:
			if o.limit_price >= p:
				buy_vol += o.remaining_qty()
		var sell_vol: int = 0
		for o: Order in asks:
			if o.limit_price <= p:
				sell_vol += o.remaining_qty()
		var match_vol: int = mini(buy_vol, sell_vol)
		if match_vol > max_volume:
			max_volume = match_vol
			best = [p]
		elif match_vol == max_volume and match_vol > 0:
			best.append(p)
	if max_volume == 0 or best.is_empty():
		return {"price": -1, "volume": 0}
	var pick: int = best[0]
	for p: int in best:
		var dp: float = absf(float(p) - ref_price)
		var dq: float = absf(float(pick) - ref_price)
		if dp < dq or (dp == dq and p < pick):
			pick = p
	return {"price": pick, "volume": max_volume}


# --- the schedule (pure) ---

static func _params(w: Barons, id: String) -> Dictionary:
	return w.def(id).get("params", {})


static func _state(w: Barons, id: String) -> BaronState:
	return w.state(id)


## The auction open during `round_num` as {baron, station, commodity, round,
## close_round, ref_price}, {} when none. A held baron runs none.
static func open_auction(w: Barons, id: String, round_num: int, run_seed: int) -> Dictionary:
	var s: BaronState = _state(w, id)
	if s == null or s.holder != "":
		return {}
	var every: int = int(_params(w, id).get("auction_every_rounds", 0))
	if every <= 0 or round_num < every or round_num % every != 0:
		return {}
	var coms: Array = _stock_commodities(w, id)
	if coms.is_empty():
		return {}
	var draw := NativeDrawSource.new(StableHash.hash32("baron-%s-%d-%d" % [id, run_seed, round_num]))
	var c: String = str(coms[draw.randint(0, coms.size() - 1)])
	return {
		"baron": id, "station": str(w.def(id).get("anchor", "")), "commodity": c,
		"round": round_num, "close_round": round_num + 1, "ref_price": ref_price(w, id, c),
	}


## The commodities Sol Central auctions: those its opening stock lists, sorted.
static func _stock_commodities(w: Barons, id: String) -> Array:
	var out: Array = []
	for c in w.def(id).get("inventory", {}):
		out.append(str(c))
	out.sort()
	return out


## The reference price Sol Central prints: the anchor's base price in whole CR
## (never the live book, which the player can move).
static func ref_price(w: Barons, id: String, commodity: String) -> int:
	var anchor: String = str(w.def(id).get("anchor", ""))
	return maxi(1, int(round(float(Transit.BASE_PRICES.get(anchor, {}).get(commodity, 1.0)))))


## The largest the rig may move the honest price, in CR.
static func rig_cr(w: Barons, id: String, honest: int) -> int:
	var bps: int = int(_params(w, id).get("rig_bps_max", 0))
	if bps <= 0 or honest <= 0:
		return 0
	return maxi(1, (honest * bps + 9999) / 10000)


# --- the buffer ---

## The buffered orders, sorted by (limit, seq).
static func buffer(w: Barons, id: String) -> Array:
	var s: BaronState = _state(w, id)
	if s == null:
		return []
	var raw = s.scratch.get("buffer", [])
	var out: Array = []
	if raw is Array:
		for e in raw:
			if e is Dictionary:
				out.append({
					"seq": int(e.get("seq", 0)), "side": str(e.get("side", "")), "qty": int(e.get("qty", 0)),
					"limit": int(e.get("limit", 0)), "round": int(e.get("round", 0)), "commodity": str(e.get("commodity", "")),
				})
	return out


static func _store(s: BaronState, orders: Array) -> void:
	orders.sort_custom(func(a, b): return int(a["limit"]) < int(b["limit"]) or (int(a["limit"]) == int(b["limit"]) and int(a["seq"]) < int(b["seq"])))
	if orders.is_empty():
		s.scratch.erase("buffer")
	else:
		s.scratch["buffer"] = orders


## Queues a limit order into the open auction. Validates against what the player
## holds NOW, counting orders already queued (nothing is escrowed, so the clear
## re-checks). Returns {ok, reason, order}.
static func submit(w: Barons, id: String, rc: RunController, side: String, qty: int, limit: int) -> Dictionary:
	var au: Dictionary = open_auction(w, id, rc.get_current_round(), rc.run_seed)
	if au.is_empty():
		return {"ok": false, "reason": "NO_AUCTION"}
	if qty <= 0 or limit <= 0:
		return {"ok": false, "reason": "INVALID_PRICE"}
	var s: BaronState = _state(w, id)
	var orders: Array = buffer(w, id)
	var buy_qty: int = 0
	var buy_cr: int = 0
	var sell_qty: int = 0
	var top: int = 0
	for o in orders:
		top = maxi(top, int(o["seq"]))
		if str(o["side"]) == SIDE_BUY:
			buy_qty += int(o["qty"])
			buy_cr += int(o["qty"]) * int(o["limit"])
		else:
			sell_qty += int(o["qty"])
	var c: String = str(au["commodity"])
	if side == SIDE_BUY:
		if rc.cr < buy_cr + qty * limit:
			return {"ok": false, "reason": "INSUFFICIENT_CR"}
		if qty + buy_qty > rc.get_remaining_cargo_capacity():
			return {"ok": false, "reason": "INSUFFICIENT_CARGO_CAPACITY"}
	else:
		if int(rc.cargo.get(c, 0)) < sell_qty + qty:
			return {"ok": false, "reason": "INSUFFICIENT_CARGO"}
	var order := {"seq": top + 1, "side": side, "qty": qty, "limit": limit, "round": int(au["round"]), "commodity": c}
	orders.append(order)
	_store(s, orders)
	return {"ok": true, "reason": "", "order": order, "auction": au}


## Withdraws every queued order (allowed until the auction closes). Returns how
## many orders were taken back.
static func withdraw(w: Barons, id: String) -> int:
	var s: BaronState = _state(w, id)
	if s == null:
		return 0
	var n: int = buffer(w, id).size()
	s.scratch.erase("buffer")
	return n


# --- the cross ---

## Earth's resting orders for the commodity as Order lists {bids, asks}.
static func _book_orders(market: StationMarket, anchor: String, commodity: String) -> Dictionary:
	var bids: Array = []
	var asks: Array = []
	var book: OrderBook = market.get_book(anchor, commodity) if market != null else null
	if book != null:
		for o: Order in book.bids:
			if o.remaining_qty() > 0:
				bids.append(o)
		for o: Order in book.asks:
			if o.remaining_qty() > 0:
				asks.append(o)
	return {"bids": bids, "asks": asks}


## Resolves the auction for `orders` (buffer entries) against the book:
## {honest, price, volume, rigged, fills}. `honest` is the port's price on the real
## orders; `price` is what Sol Central prints after the rig (-1 = no cross, nothing
## trades). `fills` is the quantity each buffered order gets, keyed by seq.
## Pure: nothing is changed.
static func resolve(w: Barons, id: String, commodity: String, orders: Array, market: StationMarket) -> Dictionary:
	var anchor: String = str(w.def(id).get("anchor", ""))
	var book: Dictionary = _book_orders(market, anchor, commodity)
	var bids: Array = (book["bids"] as Array).duplicate()
	var asks: Array = (book["asks"] as Array).duplicate()
	var by_seq: Dictionary = {}
	var total: int = 0
	for o in orders:
		var po := Order.new("auction-%d" % int(o["seq"]), PLAYER, commodity, "bid" if str(o["side"]) == SIDE_BUY else "ask", int(o["qty"]), int(o["limit"]), int(o["seq"]), 0.0)
		by_seq[po.order_id] = int(o["seq"])
		(bids if str(o["side"]) == SIDE_BUY else asks).append(po)
	for o: Order in bids + asks:
		total += o.remaining_qty()
	var ref: int = ref_price(w, id, commodity)
	var honest: Dictionary = find_clearing_price(bids, asks, float(ref))
	var out := {"honest": int(honest["price"]), "price": -1, "volume": 0, "rigged": false, "fills": {}}
	if int(honest["price"]) < 0:
		return out
	var h: int = int(honest["price"])
	var price: int = _rigged_price(w, id, commodity, h)
	if price != h:
		# The balanced pair: one bid and one ask at the rigged price, bigger than
		# everything else together, so it is the only volume-maximising price.
		var pair_qty: int = total + 1
		var pb := Order.new("sol-pair-bid", id, commodity, "bid", pair_qty, price, 0, 0.0)
		var pa := Order.new("sol-pair-ask", id, commodity, "ask", pair_qty, price, 0, 0.0)
		var rigged: Dictionary = find_clearing_price(bids + [pb], asks + [pa], float(h))
		if int(rigged["price"]) != price:
			price = h  # cannot happen (the pair dominates); never print a price the cross does not give
	out["price"] = price
	out["rigged"] = price != h
	var fills: Dictionary = _allocate(bids, asks, price, by_seq)
	out["fills"] = fills
	var vol: int = 0
	for k in fills:
		vol += int(fills[k])
	out["volume"] = vol
	return out


## The price in [honest - rig, honest + rig] best for Sol Central's own stock.
## The score is the price times the direction (+1 while it holds the commodity, so
## higher is better; -1 when it is out, so lower is better); ties go to the lower.
static func _rigged_price(w: Barons, id: String, commodity: String, honest: int) -> int:
	var r: int = rig_cr(w, id, honest)
	if r <= 0:
		return honest
	var s: BaronState = _state(w, id)
	var dir: int = 1 if s != null and int(s.inventory.get(commodity, 0)) > 0 else -1
	var best: int = honest
	var best_score: int = honest * dir
	for p in range(maxi(1, honest - r), honest + r + 1):
		if p * dir > best_score or (p * dir == best_score and p < best):
			best = p
			best_score = p * dir
	return best


## Price-time allocation of the orders that can trade at `price`: resting maker
## orders first (they were there before the auction opened), then the player's, by
## (limit, seq). Returns {seq: filled_qty} for the player's orders only.
static func _allocate(bids: Array, asks: Array, price: int, by_seq: Dictionary) -> Dictionary:
	var eb: Array = _queue(bids, true, price)
	var ea: Array = _queue(asks, false, price)
	var fills: Dictionary = {}
	var i: int = 0
	var j: int = 0
	while i < eb.size() and j < ea.size():
		var b: Dictionary = eb[i]
		var a: Dictionary = ea[j]
		var take: int = mini(int(b["rem"]), int(a["rem"]))
		if take > 0:
			for side in [b, a]:
				if by_seq.has((side["o"] as Order).order_id):
					var k: int = int(by_seq[(side["o"] as Order).order_id])
					fills[k] = int(fills.get(k, 0)) + take
		b["rem"] = int(b["rem"]) - take
		a["rem"] = int(a["rem"]) - take
		if int(b["rem"]) <= 0:
			i += 1
		if int(a["rem"]) <= 0:
			j += 1
	return fills


static func _queue(orders: Array, is_bid: bool, price: int) -> Array:
	var q: Array = []
	for idx in orders.size():
		var o: Order = orders[idx]
		if (is_bid and o.limit_price >= price) or (not is_bid and o.limit_price <= price):
			q.append({"o": o, "rem": o.remaining_qty(), "group": 1 if o.agent_id == PLAYER else 0, "idx": idx})
	q.sort_custom(func(x, y):
		var px: int = (x["o"] as Order).limit_price
		var py: int = (y["o"] as Order).limit_price
		if px != py:
			return px > py if is_bid else px < py
		if int(x["group"]) != int(y["group"]):
			return int(x["group"]) < int(y["group"])
		if int(x["group"]) == 1 and (x["o"] as Order).seq_seen != (y["o"] as Order).seq_seen:
			return (x["o"] as Order).seq_seen < (y["o"] as Order).seq_seen
		return int(x["idx"]) < int(y["idx"]))
	return q


# --- indicative price (the player's view) ---

## What the player is shown for the open auction as {baron, commodity, close_round,
## ref, hidden, price, volume, rigged, orders}. `price` is the indicative clearing
## price on the queued orders (-1 = nothing crosses yet); `fills` is what each queued
## order would get at it, by seq; `hidden` is the delayed leak, which shows none. {} when no auction is open.
static func indicative(w: Barons, id: String, round_num: int, run_seed: int, market: StationMarket) -> Dictionary:
	var au: Dictionary = open_auction(w, id, round_num, run_seed)
	if au.is_empty():
		return {}
	var orders: Array = _live_orders(w, id, au)
	var out := {
		"baron": id, "commodity": str(au["commodity"]), "close_round": int(au["close_round"]),
		"ref": int(au["ref_price"]), "hidden": str(_params(w, id).get("indicative_leak", "full")) == "delayed",
		"price": -1, "volume": 0, "rigged": false, "orders": orders, "fills": {},
	}
	if not bool(out["hidden"]) and not orders.is_empty():
		var r: Dictionary = resolve(w, id, str(au["commodity"]), orders, market)
		out["price"] = int(r["price"])
		out["volume"] = int(r["volume"])
		out["rigged"] = bool(r["rigged"])
		out["fills"] = r["fills"]
	return out


static func _live_orders(w: Barons, id: String, au: Dictionary) -> Array:
	var out: Array = []
	for o in buffer(w, id):
		if int(o["round"]) == int(au["round"]) and str(o["commodity"]) == str(au["commodity"]):
			out.append(o)
	return out


# --- the world step ---

## Runs at the round boundary `round_num`: closes the auction of the round that
## just ended and settles the player's fills. Events for the UI: auction_open,
## auction_clear, auction_lapse. A held baron holds no auction.
static func advance(w: Barons, id: String, round_num: int, rc: RunController, market: StationMarket = null) -> Array:
	var s: BaronState = _state(w, id)
	var events: Array = []
	if s == null:
		return events
	if s.holder != "":
		cancel(w, id)
		return events
	var closing: Dictionary = open_auction(w, id, round_num - 1, rc.run_seed)
	var queued: Array = buffer(w, id)
	if not queued.is_empty():
		if closing.is_empty():
			cancel(w, id)  # a stale buffer belongs to no auction
		else:
			events.append_array(_close(w, id, closing, rc, market))
	var opening: Dictionary = open_auction(w, id, round_num, rc.run_seed)
	if not opening.is_empty():
		events.append({"kind": "auction_open", "baron": id, "station": str(opening["station"]), "commodity": str(opening["commodity"]), "close_round": int(opening["close_round"]), "ref": int(opening["ref_price"])})
	return events


## Closes one auction: re-validates what the player can still pay for, crosses,
## settles and clears the buffer.
static func _close(w: Barons, id: String, au: Dictionary, rc: RunController, market: StationMarket) -> Array:
	var s: BaronState = _state(w, id)
	var anchor: String = str(au["station"])
	var c: String = str(au["commodity"])
	var events: Array = []
	var queued: Array = _live_orders(w, id, au)
	var asked: int = 0
	for o in queued:
		asked += int(o["qty"])
	s.scratch.erase("buffer")
	if queued.is_empty():
		return events
	# Re-validate before pricing: only trades the player can still afford count.
	var valid: Array = []
	if rc.docked_at == anchor and not rc.is_in_transit():
		var cr_left: int = rc.cr
		var cap_left: int = rc.get_remaining_cargo_capacity()
		var held: int = int(rc.cargo.get(c, 0))
		for o in queued:
			var q: int = int(o["qty"])
			if str(o["side"]) == SIDE_BUY:
				q = mini(q, mini(cap_left, cr_left / maxi(1, int(o["limit"]))))
				cap_left -= q
				cr_left -= q * int(o["limit"])
			else:
				q = mini(q, held)
				held -= q
			if q > 0:
				var e: Dictionary = (o as Dictionary).duplicate()
				e["qty"] = q
				valid.append(e)
	var res: Dictionary = resolve(w, id, c, valid, market)
	var price: int = int(res["price"])
	var filled: int = 0
	var fills: Dictionary = res["fills"]
	var cost_total: int = 0
	var side_bought: int = 0
	var side_sold: int = 0
	for o in valid:
		var f: int = mini(int(fills.get(int(o["seq"]), 0)), int(o["qty"]))
		if f <= 0:
			continue
		var cost: int = f * price
		var fee: int = rc.trade_fee(cost)
		if str(o["side"]) == SIDE_BUY:
			rc.cr -= cost + fee
			rc.cargo[c] = int(rc.cargo.get(c, 0)) + f
			s.inventory[c] = maxi(0, int(s.inventory.get(c, 0)) - f)
			s.treasury_cr += cost
			side_bought += f
		else:
			rc.cargo[c] = int(rc.cargo.get(c, 0)) - f
			rc.cr += maxi(0, cost - fee)
			s.inventory[c] = int(s.inventory.get(c, 0)) + f
			s.treasury_cr = maxi(0, s.treasury_cr - cost)
			side_sold += f
		rc.record_audit_trade(f)
		filled += f
		cost_total += cost
	if filled > 0:
		events.append({
			"kind": "auction_clear", "baron": id, "station": anchor, "commodity": c, "price": price,
			"honest": int(res["honest"]), "ref": int(au["ref_price"]), "qty": filled,
			"bought": side_bought, "sold": side_sold, "rigged": bool(res["rigged"]),
		})
	if filled < asked:
		events.append({"kind": "auction_lapse", "baron": id, "station": anchor, "commodity": c, "qty": asked - filled, "price": price})
	return events


## The failed corp's (or a taken baron's) queued orders end with it.
static func cancel(w: Barons, id: String) -> void:
	var s: BaronState = _state(w, id)
	if s != null:
		s.scratch.erase("buffer")
