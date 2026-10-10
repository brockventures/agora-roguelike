class_name Rivals
extends RefCounted
## Rival syndicate fleets: route arbitrage on the shared books (Epic 3 task 10,
## docs/design/epic3-barons.md 6.1 and 6.3, decision 9.5).
##
## A fleet is a RivalFleet (CR, cargo, a voyage) and does nothing the player cannot: it
## reads the live books, sails on Transit's routes and timings (alignment windows
## included, they are public), pays the belt toll and the anchoring baron's docking toll,
## and trades through StationMarket.execute_as. It only uses stations that already have
## books, so it never opens a station the player has not.
##
##  - Arbitrage. An idle fleet scores every (destination, commodity) by
##    (dest_mid - origin_mid) x qty - fuel - tolls using the book mids, keeps the best,
##    with a sorted-id tie-break (destinations then commodities in fixed order, a
##    strictly better score replaces the leader), and sails if the score clears its
##    stance's floor. It buys on departure and sells everything into the destination
##    bids on arrival, both after the round's replenish so the dent stays on the ladder
##    for the round.
##  - Departure reaction (decision 9.5). The player's departure is public, so each idle
##    fleet may break dock at once; the sailing event carries `reaction` and `watched`
##    so the UI can lead with "saw you leave X" in one GalNet line.
##    This is NOT front-running (task 11): the fleet sails its own best route, it does
##    not chase the player's cargo.
##  - Distress bids. A fleet with spare CR bids for a baron's treasury shares once the
##    baron has been insolvent for `bid_after_strain` rounds, so the player gets a head start.
##
## Determinism (design doc 6.3): every chance comes from a fresh NativeDrawSource seeded
## with StableHash.hash32("rival-<id>-<run_seed>-<round>") (react and bid use their own
## prefix), so there is no stream a skipped round could desync, and nothing is recorded:
## a replay re-derives the fleets from the player's inputs. Ids are walked sorted, money
## and bps are ints, and the CR a rival spends never touches the player's ledger.
## Every number below is a placeholder tuning guess, overridable in barons.json `rivals`.

const TRAITS: Array[String] = ["front_runner", "privateer_sponsor", "hauler"]
const STANCES: Array[String] = ["bold", "cautious"]
const DEFAULTS: Dictionary = {
	# Units a fleet can carry.
	"capacity": 60,
	# Chance an idle fleet looks for a route on a given round, in bps.
	"decide_chance_bps": 3500,
	# Chance an idle fleet reacts to the player's departure, in bps.
	"react_chance_bps": 8000,
	# Smallest profit a bold fleet will sail for.
	"min_profit_cr": 60,
	# A cautious fleet also wants this share of its outlay as profit.
	"cautious_margin_bps": 1500,
	# Insolvent rounds a baron must have run before fleets bid for its shares.
	"bid_after_strain": 2,
	"bid_chance_bps": 5000,
	# Share of its CR a fleet will put into one lot of shares.
	"bid_cr_share_bps": 5000,
}


static func settings(w: Barons) -> Dictionary:
	var out: Dictionary = DEFAULTS.duplicate()
	var r = w.data.get("rivals", {})
	if r is Dictionary:
		for k in DEFAULTS:
			if (r as Dictionary).has(k):
				out[k] = int(r[k])
	return out


static func _draw(prefix: String, id: String, run_seed: int, round_num: int) -> NativeDrawSource:
	return NativeDrawSource.new(StableHash.hash32("%s-%s-%d-%d" % [prefix, id, run_seed, round_num]))


# --- Reading the books ---

static func _best(market: StationMarket, station: String, commodity: String, side: String) -> int:
	var b: OrderBook = market.get_book(station, commodity)
	if b == null:
		return 0
	var arr: Array = b.asks if side == "ask" else b.bids
	return int((arr[0] as Order).limit_price) if not arr.is_empty() else 0


static func _mid(market: StationMarket, station: String, commodity: String) -> int:
	var bid: int = _best(market, station, commodity, "bid")
	var ask: int = _best(market, station, commodity, "ask")
	return (bid + ask) / 2 if bid > 0 and ask > 0 else 0


## What a fleet would do from where it is: {} when no route clears its floor, else
## {destination, commodity, qty, limit, score, fuel_cr, toll_cr, rounds}.
static func plan(w: Barons, f: RivalFleet, market: StationMarket, round_num: int) -> Dictionary:
	var cfg: Dictionary = settings(w)
	var space: int = int(cfg["capacity"]) - f.cargo_units()
	if space <= 0 or not Transit.STATIONS.has(f.at):
		return {}
	var best: Dictionary = {}
	var dests: Array = Transit.STATIONS.duplicate()
	dests.sort()
	for dest in dests:
		if dest == f.at:
			continue
		var r = Transit.get_route(f.at, dest, round_num)
		if r == null:
			continue
		var fuel_px: int = _mid(market, f.at, "FUEL")
		if fuel_px <= 0:
			fuel_px = int(round(float(Transit.BASE_PRICES.get(f.at, {}).get("FUEL", 0.0))))
		var fuel_cr: int = int(r["fuel"]) * fuel_px
		var belt: int = int(r["toll"])
		var fixed: int = fuel_cr + belt + w.docking_toll_due(f.id, dest)
		var budget: int = f.cr - fixed
		if budget <= 0:
			continue
		for c in Transit.COMMODITIES:
			if not market.has_book(f.at, c) or not market.has_book(dest, c):
				continue
			var o_ask: int = _best(market, f.at, c, "ask")
			var d_bid: int = _best(market, dest, c, "bid")
			# No executable edge: the best bid there must beat the best ask here.
			if o_ask <= 0 or d_bid <= o_ask:
				continue
			var limit: int = d_bid - 1
			var qty: int = mini(space, budget / o_ask)
			if qty <= 0:
				continue
			var q: Dictionary = market.sweep_quote(f.at, c, "BUY", qty, float(limit))
			if int(q["filled"]) > 0 and int(q["cost"]) > budget:
				q = market.sweep_quote(f.at, c, "BUY", maxi(1, int(q["filled"]) * budget / int(q["cost"])), float(limit))
			var filled: int = int(q["filled"])
			if filled <= 0 or int(q["cost"]) > budget:
				continue
			var score: int = (_mid(market, dest, c) - _mid(market, f.at, c)) * filled - fuel_cr - belt - w.docking_toll_due(f.id, dest)
			var need: int = int(cfg["min_profit_cr"])
			if str(w.rival_def(f.id).get("stance", "bold")) == "cautious":
				need = maxi(need, (int(q["cost"]) + fixed) * int(cfg["cautious_margin_bps"]) / 10000)
			if score < need:
				continue
			if best.is_empty() or score > int(best["score"]):
				best = {"destination": dest, "commodity": c, "qty": filled, "limit": limit, "score": score, "fuel_cr": fuel_cr, "toll_cr": belt, "rounds": int(r["rounds"])}
	return best


# --- Moving ---

## The once-a-round step, run by M0Loop AFTER the books are replenished: fleets by sorted
## id. Arrivals sell, idle fleets may sail. Returns the events the UI turns into GalNet
## lines: {kind: "rival_trade" | "rival_depart", fleet, ...}.
static func advance(w: Barons, round_num: int, rc: RunController, market: StationMarket) -> Array:
	var events: Array = []
	if market == null:
		return events
	var cfg: Dictionary = settings(w)
	for id in w.rival_ids():
		var f: RivalFleet = w.rival(id)
		if f.in_flight() and round_num >= int(f.route.get("arrival_round", 0)):
			_arrive(w, f, market, round_num, events)
		if f.in_flight():
			continue
		if f.cargo_units() > 0:
			_sell_cargo(f, market, round_num, events)
		var roll: int = _draw("rival", id, rc.run_seed, round_num).randint(0, 9999)
		if roll < int(cfg["decide_chance_bps"]):
			_try_depart(w, f, market, round_num, events)
	return events


## The player's departure is public (decision 9.5): each idle fleet may break dock at
## once. Its sailing event is flagged `reaction` (and `watched`, the station the player left)
## so the GalNet line leads with what it saw. `info` is the controller's departure.
static func react(w: Barons, rc: RunController, market: StationMarket, info: Dictionary) -> Array:
	var events: Array = []
	if market == null:
		return events
	var round_num: int = rc.get_current_round()
	var cfg: Dictionary = settings(w)
	for id in w.rival_ids():
		var f: RivalFleet = w.rival(id)
		if f.in_flight():
			continue
		var roll: int = _draw("rival-react", id, rc.run_seed, round_num).randint(0, 9999)
		if roll >= int(cfg["react_chance_bps"]):
			continue
		if f.cargo_units() > 0:
			_sell_cargo(f, market, round_num, events)
		var p: Dictionary = plan(w, f, market, round_num)
		if p.is_empty():
			continue
		var n0: int = events.size()
		_sail(w, f, p, market, round_num, events)
		if events.size() > n0:
			events[n0]["reaction"] = true
			events[n0]["watched"] = str(info.get("origin", ""))
	return events


static func _try_depart(w: Barons, f: RivalFleet, market: StationMarket, round_num: int, events: Array) -> void:
	var p: Dictionary = plan(w, f, market, round_num)
	if not p.is_empty():
		_sail(w, f, p, market, round_num, events)


static func _sail(w: Barons, f: RivalFleet, p: Dictionary, market: StationMarket, round_num: int, events: Array) -> void:
	var c: String = str(p["commodity"])
	var res: Dictionary = market.execute_as(f.id, f.at, c, "BUY", int(p["qty"]), float(p["limit"]))
	var filled: int = int(res["filled"])
	if filled <= 0:
		return
	var cost: int = int(res["cost"])
	f.cr = maxi(0, f.cr - cost - int(p["fuel_cr"]) - int(p["toll_cr"]))
	f.cargo[c] = int(f.cargo.get(c, 0)) + filled
	var origin: String = f.at
	var price: int = cost / filled
	f.route = {"origin": origin, "destination": str(p["destination"]), "depart_round": round_num, "arrival_round": round_num + int(p["rounds"]), "commodity": c, "qty": filled}
	f.last = {"round": round_num, "station": origin, "commodity": c, "side": "BUY", "qty": filled, "price": price}
	events.append({"kind": "rival_depart", "fleet": f.id, "station": origin, "destination": str(p["destination"]), "commodity": c, "qty": filled, "price": price, "rounds": int(p["rounds"])})


static func _arrive(w: Barons, f: RivalFleet, market: StationMarket, round_num: int, events: Array) -> void:
	var dest: String = str(f.route.get("destination", f.at))
	f.at = dest
	f.route = {}
	f.cr -= w.docking_toll(f.id, dest, f.cr)
	_sell_cargo(f, market, round_num, events)


## Sells what the fleet can into the bids where it is docked, in commodity order.
static func _sell_cargo(f: RivalFleet, market: StationMarket, round_num: int, events: Array) -> void:
	for c in Transit.COMMODITIES:
		var qty: int = int(f.cargo.get(c, 0))
		if qty <= 0 or not market.has_book(f.at, c):
			continue
		var res: Dictionary = market.execute_as(f.id, f.at, c, "SELL", qty, 1.0)
		var filled: int = int(res["filled"])
		if filled <= 0:
			continue
		f.cr += int(res["cost"])
		if filled >= qty:
			f.cargo.erase(c)
		else:
			f.cargo[c] = qty - filled
		var price: int = int(res["cost"]) / filled
		f.last = {"round": round_num, "station": f.at, "commodity": c, "side": "SELL", "qty": filled, "price": price}
		events.append({"kind": "rival_trade", "fleet": f.id, "station": f.at, "commodity": c, "qty": filled, "price": price})


# --- Distress bids (the Takeover seam) ---

## The bids {buyer, qty} fleets make for a distress lot, in sorted fleet id order. The CR
## is taken from the fleet here; Takeover sells the shares. A baron must have been
## insolvent `bid_after_strain` rounds, and each fleet puts at most `bid_cr_share_bps` of
## its CR into the lot, so the player has a head start on every distress auction.
static func bids(w: Barons, baron_id: String, round_num: int, px: int, qty: int, rc: RunController) -> Array:
	var out: Array = []
	var s: BaronState = w.state(baron_id)
	if s == null or rc == null or px <= 0 or qty <= 0 or w.rivals.is_empty():
		return out
	var cfg: Dictionary = settings(w)
	if s.strain < int(cfg["bid_after_strain"]):
		return out
	var left: int = qty
	for id in w.rival_ids():
		if left <= 0:
			break
		var f: RivalFleet = w.rival(id)
		var roll: int = _draw("rival-bid-%s" % baron_id, id, rc.run_seed, round_num).randint(0, 9999)
		if roll >= int(cfg["bid_chance_bps"]):
			continue
		var n: int = mini(left, f.cr * int(cfg["bid_cr_share_bps"]) / 10000 / px)
		if n <= 0:
			continue
		f.cr -= n * px
		left -= n
		out.append({"buyer": id, "qty": n})
	return out


# --- Reading state for the UI ---

## The fills fleets made on a (station, commodity) book this round, sorted by fleet id:
## [{fleet, side, qty, price}].
static func moves_on(w: Barons, station: String, commodity: String, round_num: int) -> Array:
	var out: Array = []
	for id in w.rival_ids():
		var l: Dictionary = w.rival(id).last
		if not l.is_empty() and int(l.get("round", -1)) == round_num and str(l.get("station", "")) == station.to_lower() and str(l.get("commodity", "")) == commodity.to_upper():
			out.append({"fleet": id, "side": str(l["side"]), "qty": int(l["qty"]), "price": int(l["price"])})
	return out
