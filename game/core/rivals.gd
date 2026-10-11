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
##  - Distress bids (#134). A fleet bids in the sealed-bid auction for a baron's shares, but only
##    on a baron anchored at a station it trades at, at most its own valuation of the shares
##    (Takeover.value_per_share: NAV plus the control premium for its own stake) and no more
##    than `bid_cr_share_bps` of its CR, never so much it would be insolvent. No chance draw:
##    a fleet bids when it has a reason. Barons insolvent less than `bid_after_strain` rounds
##    are left alone (a forced lot from a liquidated fleet is not).
##  - Bankruptcy (#134). A fleet takes the same Chapter11.assess as barons and the player, against
##    the `debt_cr` its barons.json entry carries. After `fleet_bankrupt_rounds` insolvent rounds
##    it liquidates: cargo and CR are gone, its baron shares go to each baron's next auction as a
##    forced lot with no reserve, and it leaves the run (`gone`). Its dock tolls at a baron the
##    player holds are paid to the player.
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
	# Share of its CR a fleet will put into one lot of shares.
	"bid_cr_share_bps": 5000,
	# Insolvent rounds (Chapter11.assess against the fleet's debt_cr) before a fleet liquidates.
	"fleet_bankrupt_rounds": 4,
	# Front-running (task 11, trait front_runner): the least a departing hold must be worth
	# (Piracy.cargo_value), the CR the fleet must keep after fuel and tolls, the chance it
	# acts, how much of the destination book's depth it takes (depth_bps left, 6000 = -40%)
	# and for how many rounds.
	"front_run_min_value": 1000,
	"front_run_min_cr": 3000,
	"front_run_chance_bps": 7000,
	"front_run_depth_bps": 6000,
	"front_run_rounds": 2,
	# Privateer bounties (task 11, trait privateer_sponsor). The doc's floor is Piracy.VALUE_REF
	# (10,000 CR), which a 100-unit hold can never reach (the dearest unit is 21.2 CR), so the
	# floor is a placeholder of its own. Each point of total baron heat lowers it by
	# `bounty_heat_value_step` CR (rival targeting reads the same heat, doc 6.2).
	"bounty_min_value": 1500,
	"bounty_heat_value_step": 150,
	"bounty_chance_bps": 6000,
	# Chance each round that a standing bounty on the player is traced (Piracy.PRIV_TRACE = 10%).
	"bounty_trace_bps": 1000,
	# Raids (#134): while a bounty stands on the player, each departure with a hold worth at
	# least `raid_min_value` CR rolls a real Piracy raid (the +0.15 odds the contract adds).
	"raid_min_value": 1500,
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
## {destination, commodity, qty, limit, score, fuel_cr, fuel_units, toll_cr, rounds}.
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
				best = {"destination": dest, "commodity": c, "qty": filled, "limit": limit, "score": score, "fuel_cr": fuel_cr, "fuel_units": int(r["fuel"]), "toll_cr": belt, "rounds": int(r["rounds"])}
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
			if int(f.route.get("front", 0)) == 1:
				_front_arrive(w, f, round_num, events, rc)
			else:
				_arrive(w, f, market, round_num, events, rc)
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
		# A front_runner that can beat the player to the destination front-runs INSTEAD of
		# its ordinary reaction; one that cannot (or loses its chance draw) reacts as before.
		if str(w.rival_def(id).get("trait", "")) == "front_runner" and _try_front_run(w, f, rc, market, info, cfg, round_num, events):
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
	_try_bounty(w, rc, info, cfg, round_num, events)
	_try_raid(w, rc, info, cfg, round_num, events)
	return events


## What a fleet pays for the fuel of a trip (#138): it buys `units` FUEL from the station's
## own book, so the fill dents the ask ladder like any other. Units the book cannot supply
## (or a station with no FUEL book) are charged at the planning mid price, `mid_cr / units`
## each, as fuel always was. Returns the CR due; the caller deducts it.
static func _buy_fuel(f: RivalFleet, market: StationMarket, units: int, mid_cr: int) -> int:
	if units <= 0:
		return mid_cr
	var res: Dictionary = market.execute_as(f.id, f.at, "FUEL", "BUY", units, RunController.FUEL_LIMIT_PX)
	var filled: int = int(res["filled"])
	return int(res["cost"]) + (units - filled) * (mid_cr / units)


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
	var fuel_paid: int = _buy_fuel(f, market, int(p.get("fuel_units", 0)), int(p["fuel_cr"]))
	f.cr = maxi(0, f.cr - cost - fuel_paid - int(p["toll_cr"]))
	f.cargo[c] = int(f.cargo.get(c, 0)) + filled
	var origin: String = f.at
	var price: int = cost / filled
	f.route = {"origin": origin, "destination": str(p["destination"]), "depart_round": round_num, "arrival_round": round_num + int(p["rounds"]), "commodity": c, "qty": filled}
	f.last = {"round": round_num, "station": origin, "commodity": c, "side": "BUY", "qty": filled, "price": price}
	events.append({"kind": "rival_depart", "fleet": f.id, "station": origin, "destination": str(p["destination"]), "commodity": c, "qty": filled, "price": price, "rounds": int(p["rounds"])})


## A fleet pays the docking toll on arrival; at a baron the player holds the player collects it.
static func _pay_toll(w: Barons, f: RivalFleet, dest: String, rc: RunController) -> void:
	var toll: int = w.docking_toll(f.id, dest, f.cr)
	f.cr -= toll
	if toll > 0 and rc != null:
		var bs: BaronState = w.state(w.baron_at(dest))
		if bs != null and bs.holder == Takeover.PLAYER:
			rc.cr += toll


static func _arrive(w: Barons, f: RivalFleet, market: StationMarket, round_num: int, events: Array, rc: RunController = null) -> void:
	var dest: String = str(f.route.get("destination", f.at))
	f.at = dest
	f.route = {}
	_pay_toll(w, f, dest, rc)
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


# --- Distress bids and bankruptcy (#134) ---

## True when the fleet trades at `station`: its home, where it is docked or heading, or where
## it last traded. A fleet only bids on a baron anchored at one of these.
static func trades_at(f: RivalFleet, home: String, station: String) -> bool:
	var st: String = station.to_lower()
	if st == "":
		return false
	if home == st or f.at == st or str(f.last.get("station", "")) == st:
		return true
	return str(f.route.get("origin", "")) == st or str(f.route.get("destination", "")) == st


## The sealed bids {buyer, qty, max_price} fleets make for a lot of `qty` shares at reserve
## `px` in baron `baron_id`'s auction, sorted by fleet id. Nothing is drawn: a fleet bids when
## the baron is anchored at a station it trades at (a forced lot, reserve 0, ignores the
## `bid_after_strain` head start), its valuation (Takeover.value_per_share) clears the reserve,
## and it can pay: at most `bid_cr_share_bps` of its CR and never enough to leave it insolvent.
## Its top price is its valuation; it pays only the uniform clearing price. CR is taken by the
## clearing, not here.
static func bids(w: Barons, baron_id: String, round_num: int, px: int, qty: int, rc: RunController, forced: bool = false) -> Array:
	var out: Array = []
	var s: BaronState = w.state(baron_id)
	if s == null or rc == null or qty <= 0 or w.rivals.is_empty() or s.holder != "":
		return out
	var cfg: Dictionary = settings(w)
	if not forced and s.strain < int(cfg["bid_after_strain"]):
		return out
	var anchor: String = str(w.def(baron_id).get("anchor", ""))
	for id in w.rival_ids():
		var f: RivalFleet = w.rival(id)
		if not trades_at(f, str(w.rival_def(id).get("home", "")), anchor):
			continue
		var top: int = Takeover.value_per_share(w, baron_id, id, rc)
		if top < maxi(1, px):
			continue
		var n: int = mini(qty, f.cr * int(cfg["bid_cr_share_bps"]) / 10000 / top)
		n = mini(n, maxi(1, Takeover.threshold_for(w, id, rc) - Takeover.shares_of(w, baron_id, id)))
		n = mini(n, maxi(0, int(health(w, id)["headroom"])) / top)
		if n <= 0:
			continue
		out.append({"buyer": id, "qty": n, "max_price": top})
	return out


## A fleet's balance sheet through Chapter11.assess, the same test as barons and the player:
## {cr, debt, liquidation, headroom (liquidation less debt), insolvent, strain, rounds_left
## (insolvent rounds before it liquidates), gone}. {} for an unknown fleet.
static func health(w: Barons, fleet_id: String) -> Dictionary:
	var f: RivalFleet = w.rival(fleet_id)
	if f == null:
		return {}
	var debt: int = maxi(0, int(w.rival_def(fleet_id).get("debt_cr", 0)))
	var a: Dictionary = Chapter11.assess({"cr": f.cr, "cargo": f.cargo, "ships": [], "doomsday": {"principal_debt": debt}})
	var liq: int = int(a["liquidation_value"])
	return {
		"cr": f.cr, "debt": debt, "liquidation": liq, "headroom": liq - debt,
		"insolvent": bool(a["insolvent"]), "strain": f.strain,
		"rounds_left": maxi(0, int(settings(w)["fleet_bankrupt_rounds"]) - f.strain), "gone": f.gone,
	}


## The once-a-round solvency step (Barons.advance_round, before the barons' lots): fleets by
## sorted id. An insolvent fleet's strain climbs, a solvent one's resets; at
## `fleet_bankrupt_rounds` it liquidates. Returns {kind: "rival_bankrupt", fleet, shares, barons}.
static func advance_health(w: Barons, round_num: int) -> Array:
	var events: Array = []
	var limit: int = int(settings(w)["fleet_bankrupt_rounds"])
	for id in w.rival_ids():
		var f: RivalFleet = w.rival(id)
		if bool(health(w, id)["insolvent"]):
			f.strain += 1
			if f.strain >= limit:
				events.append(_liquidate(w, f, round_num))
		elif f.strain != 0:
			f.strain = 0
	return events


## The fleet's CR and cargo are gone and it leaves the run. Each baron it held shares of
## (sorted) takes them as a forced lot (BaronState.scratch["forced"]) for its next auction,
## with no reserve; a baron the fleet held reverts to NPC control. Shares in a baron someone
## else holds simply return to the public float.
static func _liquidate(w: Barons, f: RivalFleet, round_num: int) -> Dictionary:
	var total: int = 0
	var barons: Array = []
	for bid in w.ids():
		var s: BaronState = w.state(bid)
		var n: int = int(s.shares.get(f.id, 0))
		if n <= 0 and s.holder != f.id:
			continue
		s.shares.erase(f.id)
		if s.holder == f.id:
			s.holder = ""
		if n > 0 and s.holder == "":
			s.scratch["forced"] = int(s.scratch.get("forced", 0)) + n
			total += n
			barons.append(bid)
	var ev: Dictionary = {"kind": "rival_bankrupt", "fleet": f.id, "shares": total, "barons": barons, "cr": f.cr, "round": round_num}
	f.cr = 0
	f.cargo = {}
	f.route = {}
	f.front = {}
	f.strain = 0
	f.gone = true
	return ev


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


# --- Front-running (Epic 3 task 11, design doc 6.1) ---

## The player's most valuable commodity aboard and the whole hold's value (Piracy.cargo_value),
## commodities in sorted order, the first of equal value winning.
static func _hold_value(rc: RunController) -> Dictionary:
	var keys: Array = rc.cargo.keys()
	keys.sort()
	var best: String = ""
	var best_v: int = 0
	var total: int = 0
	for c in keys:
		var v: int = Piracy.cargo_value(str(c), int(rc.cargo[c]))
		total += v
		if v > best_v:
			best_v = v
			best = str(c)
	return {"commodity": best, "value": total}


## A front_runner reacts to the player's DEPARTURE only (never a resting order: the
## player has none). It qualifies when the hold is worth `front_run_min_value`, it can reach
## the destination in no more rounds than the player's trip, and it keeps `front_run_min_cr`
## after fuel and tolls. It then sails there to pre-position (or, already docked there,
## starts at once); on arrival `front_run_depth_bps` of the commodity's depth stays on the
## destination book for `front_run_rounds` rounds and one GalNet line says so. Its chance is
## a fresh source seeded hash32("rival-front-<id>-<run_seed>-<round>").
static func _try_front_run(w: Barons, f: RivalFleet, rc: RunController, market: StationMarket, info: Dictionary, cfg: Dictionary, round_num: int, events: Array) -> bool:
	if market == null or not f.front.is_empty():
		return false
	var hold: Dictionary = _hold_value(rc)
	var com: String = str(hold["commodity"])
	var dest: String = str(info.get("destination", ""))
	if com == "" or int(hold["value"]) < int(cfg["front_run_min_value"]) or not market.has_book(dest, com):
		return false
	var trip: int = int(info.get("rounds", 0))
	var rounds: int = 0
	var fuel_cr: int = 0
	var fuel_units: int = 0
	var belt: int = 0
	var dock: int = 0
	if f.at != dest:
		var r = Transit.get_route(f.at, dest, round_num)
		if r == null or int(r["rounds"]) > trip:
			return false
		rounds = int(r["rounds"])
		var fuel_px: int = _mid(market, f.at, "FUEL")
		if fuel_px <= 0:
			fuel_px = int(round(float(Transit.BASE_PRICES.get(f.at, {}).get("FUEL", 0.0))))
		fuel_cr = int(r["fuel"]) * fuel_px
		fuel_units = int(r["fuel"])
		belt = int(r["toll"])
		dock = w.docking_toll_due(f.id, dest)
	if f.cr - fuel_cr - belt - dock < int(cfg["front_run_min_cr"]):
		return false
	if _draw("rival-front", f.id, rc.run_seed, round_num).randint(0, 9999) >= int(cfg["front_run_chance_bps"]):
		return false
	if f.cargo_units() > 0:
		_sell_cargo(f, market, round_num, events)
	f.cr = maxi(0, f.cr - _buy_fuel(f, market, fuel_units, fuel_cr) - belt)
	var ev: Dictionary = {"kind": "rival_frontrun", "fleet": f.id, "station": dest, "commodity": com, "depth_bps": int(cfg["front_run_depth_bps"]), "rounds": int(cfg["front_run_rounds"]), "watched": str(info.get("origin", ""))}
	if f.at == dest:
		# Already docked there: the dent starts at the next boundary's reseed.
		f.front = {"station": dest, "commodity": com, "depth_bps": int(cfg["front_run_depth_bps"]), "until_round": round_num + 1 + int(cfg["front_run_rounds"])}
		events.append(ev)
		return true
	f.route = {"origin": f.at, "destination": dest, "depart_round": round_num, "arrival_round": round_num + rounds, "commodity": com, "qty": 0, "front": 1, "depth_bps": int(cfg["front_run_depth_bps"]), "hold_rounds": int(cfg["front_run_rounds"])}
	f.last = {}
	return true


## Fleets that front-ran and have landed: runs at the START of the round boundary
## (Barons.advance_round), before the books are reseeded, so the dent is on the book the
## player docks to. Also expires finished front-runs. Returns the GalNet events.
static func front_arrivals(w: Barons, round_num: int, rc: RunController = null) -> Array:
	var events: Array = []
	for id in w.rival_ids():
		var f: RivalFleet = w.rival(id)
		if not f.front.is_empty() and round_num >= int(f.front["until_round"]):
			f.front = {}
		if f.in_flight() and int(f.route.get("front", 0)) == 1 and round_num >= int(f.route.get("arrival_round", 0)):
			_front_arrive(w, f, round_num, events, rc)
	return events


static func _front_arrive(w: Barons, f: RivalFleet, round_num: int, events: Array, rc: RunController = null) -> void:
	var dest: String = str(f.route.get("destination", f.at))
	var com: String = str(f.route.get("commodity", ""))
	var depth: int = int(f.route.get("depth_bps", 10000))
	var hold: int = int(f.route.get("hold_rounds", 2))
	f.at = dest
	f.route = {}
	_pay_toll(w, f, dest, rc)
	f.front = {"station": dest, "commodity": com, "depth_bps": depth, "until_round": round_num + hold}
	events.append({"kind": "rival_frontrun", "fleet": f.id, "station": dest, "commodity": com, "depth_bps": depth, "rounds": hold, "arrived": true})


## One fleet's standing front-run as a book mod, [] when none. Emitted by Barons.market_mods
## AFTER every baron's mods, fleets by sorted id, so the fold-order contract holds.
static func mods_of(f: RivalFleet) -> Array:
	if f.front.is_empty():
		return []
	return [{"station": str(f.front["station"]), "commodity": str(f.front["commodity"]), "depth_bps": int(f.front["depth_bps"]), "price_bps": 0, "spread_bps": 10000}]


## The front-run standing on a book as {fleet, depth_bps, until_round}, {} when none.
static func front_on(w: Barons, station: String, commodity: String) -> Dictionary:
	for id in w.rival_ids():
		var fr: Dictionary = w.rival(id).front
		if not fr.is_empty() and str(fr["station"]) == station.to_lower() and str(fr["commodity"]) == commodity.to_upper():
			return {"fleet": id, "depth_bps": int(fr["depth_bps"]), "until_round": int(fr["until_round"])}
	return {}


# --- Privateer bounties (Epic 3 task 11, design doc 6.1) ---

## On the player's departure each privateer_sponsor (sorted id) may hire privateers against
## the player through Piracy.hire, so a fleet can do nothing the player cannot: it pays
## Piracy.PRIV_COST, the desk allows one contract per sponsor and one per target, and
## the contract is the existing +0.15 raid odds for 20 rounds. Conditions: the hold is worth at
## least `bounty_min_value` less the heat the barons carry, the lane is a belt lane, the hold
## is unescorted (there is no escort in play yet, so always), and the fleet holds PRIV_COST.
## Its chance is a fresh source seeded hash32("rival-bounty-<id>-<run_seed>-<round>").
static func _try_bounty(w: Barons, rc: RunController, info: Dictionary, cfg: Dictionary, round_num: int, events: Array) -> void:
	var key: String = Transit.route_key(str(info.get("origin", "")), str(info.get("destination", "")))
	if not (key in Transit.BELT_ROUTES):
		return
	var value: int = int(_hold_value(rc)["value"])
	var floor_cr: int = maxi(0, int(cfg["bounty_min_value"]) - Heat.total(w) * int(cfg["bounty_heat_value_step"]))
	if value <= 0 or value < floor_cr:
		return
	for id in w.rival_ids():
		var f: RivalFleet = w.rival(id)
		if str(w.rival_def(id).get("trait", "")) != "privateer_sponsor" or f.cr < Piracy.PRIV_COST:
			continue
		if _draw("rival-bounty", id, rc.run_seed, round_num).randint(0, 9999) >= int(cfg["bounty_chance_bps"]):
			continue
		var res: Dictionary = w.desk().hire(id, StationMarket.PLAYER_ID, round_num, f.cr)
		if str(res.get("kind", "")) != "privateer_hire_ok":
			continue
		f.cr -= Piracy.PRIV_COST
		events.append({"kind": "rival_bounty", "fleet": id, "rounds": Piracy.PRIV_ROUNDS, "fee": Piracy.PRIV_COST, "value": value})
		return


## A standing bounty makes real raids (#134). On the player's departure, when a privateer
## contract stands on them and the hold is worth at least `raid_min_value` CR (1,500), the
## departure rolls Piracy.roll_departure on an ephemeral desk seeded
## hash32("rival-raid-<run_seed>-<round>") that carries the world's contracts, so the roll is
## a pure function of (seed, round, saved contracts) and no bag state needs saving. The
## contract's raid count, trace and fine are written back to the world's desk. The demand is
## auto-settled (no modal exists yet): pay the ransom when the player holds it, else
## surrender cargo (fenced, so lost to the player). A traced raid fines the sponsor.
## Emits {kind: "rival_raid", fleet, choice, ransom, qty_taken, commodity, value}.
static func _try_raid(w: Barons, rc: RunController, info: Dictionary, cfg: Dictionary, round_num: int, events: Array) -> void:
	if w.bounty_on_player(round_num).is_empty():
		return
	var hold: Dictionary = _hold_value(rc)
	var value: int = int(hold["value"])
	if value <= 0 or value < int(cfg["raid_min_value"]):
		return
	var origin: String = str(info.get("origin", ""))
	var dest: String = str(info.get("destination", ""))
	var tolled: bool = Transit.route_key(origin, dest) in Transit.BELT_ROUTES
	var sp: RivalFleet = w.rival(str(w.bounty_on_player(round_num).get("sponsor", "")))
	var desk := Piracy.new(true, null, null, StableHash.hash32("rival-raid-%d-%d" % [rc.run_seed, round_num]))
	desk.load_privateer_contracts(w.desk().privateer_contracts())
	var com: String = str(hold["commodity"])
	var tid: String = "raid-%d-%s-%s" % [round_num, origin, dest]
	var res = desk.roll_departure(tid, StationMarket.PLAYER_ID, origin, dest, tolled, com, int(rc.cargo.get(com, 0)), false, round_num,
		"", value, rc.get_total_cargo(), 1.0, 0, 1.0, 0, false, sp.cr if sp != null else null, 1.0, "", rc.piracy_odds_bps())
	w.desk().load_privateer_contracts(desk.privateer_contracts())
	if not (res is Dictionary) or not bool(res.get("raided", false)):
		return
	var demand: Dictionary = res["demand"]
	var choice: String = "pay" if rc.cr >= int(demand["ransom"]) else "surrender"
	var out: Dictionary = desk.respond(StationMarket.PLAYER_ID, tid, choice, rc.cr)
	var row: Dictionary = out.get("payload", {})
	rc.cr -= int(row.get("cr_taken", 0))
	var left: int = int(row.get("qty_taken", 0))
	var order: Array = rc.cargo.keys()
	order.sort_custom(func(a, b) -> bool:
		var va: int = Piracy.cargo_value(str(a), int(rc.cargo[a]))
		var vb: int = Piracy.cargo_value(str(b), int(rc.cargo[b]))
		return str(a) < str(b) if va == vb else va > vb)
	var taken: int = 0
	for c in order:
		var n: int = mini(left, int(rc.cargo[c]))
		if n <= 0:
			continue
		rc.cargo[c] = int(rc.cargo[c]) - n
		if int(rc.cargo[c]) <= 0:
			rc.cargo.erase(c)
		left -= n
		taken += n
	var sponsor: String = str(demand.get("sponsor", ""))
	var f: RivalFleet = w.rival(sponsor)
	if f != null and int(demand.get("fine", 0)) > 0:
		f.cr = maxi(0, f.cr - int(demand["fine"]))
	events.append({"kind": "rival_raid", "fleet": sponsor, "choice": str(row.get("choice", choice)), "ransom": int(row.get("cr_taken", 0)),
		"qty_taken": taken, "commodity": com, "value": value, "station": origin})


## Each round a standing bounty on the player may be traced (Piracy.PRIV_TRACE, here
## `bounty_trace_bps`): a fresh source seeded hash32("rival-trace-<contract>-<run_seed>-<round>").
## A traced contract is marked once and the GalNet line says who hired it. Runs at the
## start of the round boundary (Barons.advance_round).
static func trace_bounties(w: Barons, round_num: int, rc: RunController) -> Array:
	var events: Array = []
	var cfg: Dictionary = settings(w)
	var c: Dictionary = w.bounty_on_player(round_num)
	if c.is_empty() or int(c.get("traced", 0)) > 0 or rc == null:
		return events
	if _draw("rival-trace", str(c["contract_id"]), rc.run_seed, round_num).randint(0, 9999) < int(cfg["bounty_trace_bps"]):
		w.mark_bounty_traced(str(c["contract_id"]))
		events.append({"kind": "rival_bounty_traced", "fleet": str(c["sponsor"]), "rounds": maxi(0, int(c["expires_round"]) - round_num)})
	return events
