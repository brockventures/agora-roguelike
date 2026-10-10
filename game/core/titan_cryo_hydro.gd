class_name TitanCryoHydro
extends RefCounted
## Titan Cryo-Hydro, the hoarder (Epic 3 task 5, docs/design/epic3-barons.md 4.2).
##
## A state machine per float commodity (FUEL, FOOD), idle -> hoarding -> cornered
## -> releasing -> idle, over the anchor's book and Titan's own treasury and stock:
##  - idle -> hoarding when the player's trading has eaten the anchor's ask down to
##    <= `hoard_trigger_depth_bps` of what the book was seeded with, the cooldown is
##    over, and the treasury covers a round's buy.
##  - hoarding: each round Titan buys up to `hoard_cap_qty` units off the ask (a
##    thinning `ask_depth_bps` mod, since it cannot edit the book), pays the base
##    price from its treasury and stocks the units.
##  - cornered once its stock reaches `corner_inventory_qty[commodity]`: the ask is
##    thinned to `corner_ask_depth_bps` and the price is `corner_premium_bps` over
##    mid on both sides (so hauling stock in and selling into it pays).
##  - releasing after `release_after_rounds` (+/- 1, one draw) or when the treasury
##    can no longer cover a round's buy: the ask floods and the price falls by
##    `release_discount_bps` for `release_rounds` rounds while Titan sells its
##    hoard back down to its opening stock.
##  - FOOD decay link: a perishable (Transit.is_perishable) loses `food_decay_bps`
##    of the stock Titan holds each round it is hoarding, cornered or releasing, at
##    least one unit. Waiting works against Titan; the loss is reported on release.
##
## Like AresHeavy, advance() decides everything and writes it into
## BaronState.scratch; mods() only reads it, so a restored run re-emits identical
## mods and the books (which replenish() reseeds every round) carry the hoard again.
## scratch keys, all optional:
##   hoard     {COMMODITY: {phase, age, hold, rel, ask_depth_bps, announced, spoiled}}
##   cooldown  {COMMODITY: first round a new hoard may start}
## Idle with no cooldown leaves no trace, so a run that never trips the trigger
## hashes exactly as before. Titan only moves its own treasury and stock and the
## book mods: it never touches the player's CR or debt, so no Titan event (all of
## them random, none a consequence) can force Chapter 11. Every scratch read goes
## through int(): after a JSON load the numbers come back as floats.

const PHASE_HOARDING: String = "hoarding"
const PHASE_CORNERED: String = "cornered"
const PHASE_RELEASING: String = "releasing"


static func _state(w: Barons, id: String) -> BaronState:
	return w.state(id)


static func _params(w: Barons, id: String) -> Dictionary:
	return w.def(id).get("params", {})


## Float commodities in sorted order: the only order they may be decided in.
static func float_commodities(w: Barons, id: String) -> Array:
	var out: Array = []
	for c in _params(w, id).get("float_commodities", []):
		out.append(str(c))
	out.sort()
	return out


## The commodity's hoard record, {} while idle.
static func hoard(w: Barons, id: String, commodity: String) -> Dictionary:
	var s: BaronState = _state(w, id)
	if s == null:
		return {}
	var all = s.scratch.get("hoard", {})
	if not (all is Dictionary) or not (all as Dictionary).has(commodity):
		return {}
	var h = all[commodity]
	if not (h is Dictionary):
		return {}
	return {
		"phase": str(h.get("phase", "")),
		"age": int(h.get("age", 0)),
		"hold": int(h.get("hold", 0)),
		"rel": int(h.get("rel", 0)),
		"ask_depth_bps": int(h.get("ask_depth_bps", 10000)),
		"announced": bool(h.get("announced", false)),
		"spoiled": int(h.get("spoiled", 0)),
	}


static func _put(s: BaronState, commodity: String, h: Dictionary) -> void:
	var all = s.scratch.get("hoard", {})
	if not (all is Dictionary):
		all = {}
	all[commodity] = h
	s.scratch["hoard"] = all


static func _drop(s: BaronState, commodity: String) -> void:
	var all = s.scratch.get("hoard", {})
	if all is Dictionary:
		(all as Dictionary).erase(commodity)
		if (all as Dictionary).is_empty():
			s.scratch.erase("hoard")


## The phase a commodity is in ("" when idle) and its price effect in bps (the
## corner premium positive, the release discount negative, 0 while hoarding).
static func state_of(w: Barons, id: String, commodity: String) -> Dictionary:
	var h: Dictionary = hoard(w, id, commodity)
	if h.is_empty():
		return {}
	var p: Dictionary = _params(w, id)
	var price: int = 0
	if str(h["phase"]) == PHASE_CORNERED:
		price = int(p.get("corner_premium_bps", 0))
	elif str(h["phase"]) == PHASE_RELEASING:
		price = -int(p.get("release_discount_bps", 0))
	return {"phase": str(h["phase"]), "price_bps": price, "age": int(h["age"])}


## The hoard as book mods on the anchor, commodities in sorted order. Pure.
static func mods(w: Barons, id: String) -> Array:
	var out: Array = []
	var s: BaronState = _state(w, id)
	if s == null or s.holder != "":
		return out
	var anchor: String = str(w.def(id).get("anchor", ""))
	var p: Dictionary = _params(w, id)
	for c in float_commodities(w, id):
		var h: Dictionary = hoard(w, id, c)
		if h.is_empty():
			continue
		var m: Dictionary = {"station": anchor, "commodity": c}
		match str(h["phase"]):
			PHASE_HOARDING:
				m["ask_depth_bps"] = int(h["ask_depth_bps"])
			PHASE_CORNERED:
				m["ask_depth_bps"] = int(p.get("corner_ask_depth_bps", 10000))
				m["price_bps"] = int(p.get("corner_premium_bps", 0))
			PHASE_RELEASING:
				m["ask_depth_bps"] = int(p.get("release_ask_depth_bps", 10000))
				m["price_bps"] = -int(p.get("release_discount_bps", 0))
			_:
				continue
		out.append(m)
	return out


## The anchor's base price for a commodity in whole CR (never the live book).
static func base_price(w: Barons, id: String, commodity: String) -> int:
	var anchor: String = str(w.def(id).get("anchor", ""))
	return maxi(1, int(round(float(Transit.BASE_PRICES.get(anchor, {}).get(commodity, 1.0)))))


## The pipeline depth factor (bps) on the anchor's ask for a commodity.
static func _pipeline_bps(w: Barons, id: String, commodity: String) -> int:
	for pipe in w.def(id).get("privileges", {}).get("pipelines", []):
		if str(pipe.get("commodity", "")) == commodity:
			return int(pipe.get("depth_bps", 10000))
	return 10000


## The ask-depth factor that removes about `qty` units from a freshly seeded ask
## (pipeline included), and the units it really removes (integer ladder rounding).
static func thin_for(pipeline_bps: int, qty: int) -> Dictionary:
	var nominal: int = StationMarket.ask_qty_at(pipeline_bps)
	var want: int = clampi(nominal - qty, 0, nominal)
	var factor: int = want * 10000 / maxi(1, nominal)
	# Fold exactly as StationMarket._mods_for does: depth 10000 x pipeline x thinning.
	var folded: int = 10000 * pipeline_bps / 10000 * factor / 10000
	var removed: int = nominal - StationMarket.ask_qty_at(folded)
	# The ladder rounds each level down: nudge the factor until Titan takes no more than asked.
	while removed > qty and factor < 10000:
		factor += 10
		folded = 10000 * pipeline_bps / 10000 * factor / 10000
		removed = nominal - StationMarket.ask_qty_at(folded)
	return {"ask_depth_bps": factor, "removed": maxi(0, removed)}


## The world step for one baron. See Barons.advance_round. `market` supplies the
## anchor's ask depth for the trigger (null = the trigger cannot fire).
static func advance(w: Barons, id: String, round_num: int, rc: RunController, market: StationMarket = null) -> Array:
	var s: BaronState = _state(w, id)
	var events: Array = []
	if s == null:
		return events
	if s.holder != "":
		# A held baron does not hoard against its holder.
		cancel(w, id)
		return events
	var anchor: String = str(w.def(id).get("anchor", ""))
	for c in float_commodities(w, id):
		var h: Dictionary = hoard(w, id, c)
		if h.is_empty():
			h = _maybe_start(w, id, c, round_num, rc, market)
			if h.is_empty():
				continue
			events.append({"kind": "hoard", "baron": id, "station": anchor, "commodity": c})
		_step(w, id, c, h, round_num, events)
	return events


## The idle -> hoarding trigger. {} when it does not fire.
static func _maybe_start(w: Barons, id: String, c: String, round_num: int, rc: RunController, market: StationMarket) -> Dictionary:
	var s: BaronState = _state(w, id)
	var p: Dictionary = _params(w, id)
	if market == null:
		return {}
	var cool = s.scratch.get("cooldown", {})
	if cool is Dictionary and round_num < int((cool as Dictionary).get(c, 0)):
		return {}
	var anchor: String = str(w.def(id).get("anchor", ""))
	var ratio: int = market.ask_depth_ratio_bps(anchor, c)
	if ratio < 0 or ratio > int(p.get("hoard_trigger_depth_bps", 0)):
		return {}
	var cap: int = int(p.get("hoard_cap_qty", 0))
	if cap <= 0 or s.treasury_cr < cap * base_price(w, id, c):
		return {}
	# The one draw: the hold length jitter (+/- 1 round), a pure function of
	# (run_seed, round), the commodities drawing in sorted order.
	var draw := NativeDrawSource.new(StableHash.hash32("baron-%s-%d-%d" % [id, rc.run_seed, round_num]))
	var hold: int = int(p.get("release_after_rounds", 6))
	for fc in float_commodities(w, id):
		var jitter: int = draw.randint(-1, 1)
		if fc == c:
			hold = maxi(1, hold + jitter)
			break
	var h := {"phase": PHASE_HOARDING, "age": 0, "hold": hold, "rel": 0, "ask_depth_bps": 10000, "announced": false, "spoiled": 0}
	if s.scratch.has("cooldown"):
		(s.scratch["cooldown"] as Dictionary).erase(c)
		if (s.scratch["cooldown"] as Dictionary).is_empty():
			s.scratch.erase("cooldown")
	return h


## One round of an active hoard.
static func _step(w: Barons, id: String, c: String, h: Dictionary, round_num: int, events: Array) -> void:
	var s: BaronState = _state(w, id)
	var p: Dictionary = _params(w, id)
	var anchor: String = str(w.def(id).get("anchor", ""))
	var cap: int = int(p.get("hoard_cap_qty", 0))
	var price: int = base_price(w, id, c)
	h["age"] = int(h["age"]) + 1
	# FOOD decay link: held stock of a perishable rots while Titan sits on it.
	if Transit.is_perishable(c):
		var held: int = int(s.inventory.get(c, 0))
		var lost: int = mini(held, maxi(1, held * int(p.get("food_decay_bps", 0)) / 10000)) if held > 0 else 0
		if lost > 0:
			s.inventory[c] = held - lost
			h["spoiled"] = int(h["spoiled"]) + lost
	var corner_qty: int = int(p.get("corner_inventory_qty", {}).get(c, 0))
	var phase: String = str(h["phase"])
	if phase == PHASE_HOARDING or phase == PHASE_CORNERED:
		var strained: bool = s.treasury_cr < cap * price and int(s.inventory.get(c, 0)) < corner_qty
		if int(h["age"]) >= int(h["hold"]) or strained:
			phase = PHASE_RELEASING
			h["rel"] = 0
			events.append({"kind": "release", "baron": id, "station": anchor, "commodity": c, "price_bps": -int(p.get("release_discount_bps", 0))})
			if int(h["spoiled"]) > 0:
				events.append({"kind": "spoil", "baron": id, "station": anchor, "commodity": c, "qty": int(h["spoiled"])})
	if phase == PHASE_HOARDING:
		var thin: Dictionary = thin_for(_pipeline_bps(w, id, c), cap)
		var buy: int = mini(int(thin["removed"]), s.treasury_cr / price)
		if buy < int(thin["removed"]):
			thin = thin_for(_pipeline_bps(w, id, c), buy)
			buy = int(thin["removed"])
		s.treasury_cr -= buy * price
		s.inventory[c] = int(s.inventory.get(c, 0)) + buy
		h["ask_depth_bps"] = int(thin["ask_depth_bps"])
		if int(s.inventory.get(c, 0)) >= corner_qty:
			phase = PHASE_CORNERED
			if not bool(h["announced"]):
				h["announced"] = true
				events.append({"kind": "corner", "baron": id, "station": anchor, "commodity": c, "price_bps": int(p.get("corner_premium_bps", 0))})
	elif phase == PHASE_CORNERED:
		# Decay can drop the stock back under the corner line: the premium lapses
		# and Titan buys again until the hold runs out.
		if int(s.inventory.get(c, 0)) < corner_qty:
			phase = PHASE_HOARDING
	elif phase == PHASE_RELEASING:
		if int(h["rel"]) >= int(p.get("release_rounds", 1)):
			_drop(s, c)
			var cool = s.scratch.get("cooldown", {})
			if not (cool is Dictionary):
				cool = {}
			cool[c] = round_num + int(p.get("cooldown_rounds", 0))
			s.scratch["cooldown"] = cool
			return
		h["rel"] = int(h["rel"]) + 1
		var floor_qty: int = int(w.def(id).get("inventory", {}).get(c, 0))
		var sell: int = mini(int(p.get("release_sell_qty", 0)), maxi(0, int(s.inventory.get(c, 0)) - floor_qty))
		if sell > 0:
			var px: int = maxi(1, price * (10000 - int(p.get("release_discount_bps", 0))) / 10000)
			s.inventory[c] = int(s.inventory[c]) - sell
			s.treasury_cr += sell * px
	h["phase"] = phase
	_put(s, c, h)


static func cancel(w: Barons, id: String) -> void:
	var s: BaronState = _state(w, id)
	if s != null:
		s.scratch.erase("hoard")
		s.scratch.erase("cooldown")
