class_name AresHeavy
extends RefCounted
## Ares Heavy, the short squeezer (Epic 3 task 4, docs/design/epic3-barons.md 4.1).
##
## Rules over existing primitives, all of them operating on one BaronState:
##  - Defense contract. Every `contract_every_rounds` Ares posts one contract:
##    deliver `qty` of ORE or MACHINERY to its anchor within `contract_deadline_rounds`,
##    for a unit price `contract_bid_bps` over the BASE price (frozen when the offer
##    is posted, so neither the player's own trading nor the squeeze can move it).
##    The player answers the offer (accept / decline). Delivery is settled by the
##    world step: the ship docked at the anchor holding the whole quantity.
##  - Squeeze. While an accepted contract has <= `squeeze_window_rounds` left and
##    the player holds less than the quantity, Ares emits an anchor-book mod for the
##    commodity: `depth_bps = squeeze_depth_bps`, `price_bps = min(max, 1000 *
##    rounds_short)` where rounds_short counts the consecutive rounds the player was
##    short inside the window. No RNG; same shape as `localized_shortage`.
##  - Debt penalty. A contract still open at its due round is missed: its value
##    times `contract_penalty_bps` joins the doomsday principal debt, as a
##    CONSEQUENCE event (the player accepted it), under Barons.penalize's lethal guard.
##
## Everything it decides is written into BaronState.scratch, because market_mods()
## must be a pure function of saved state (RunSave.restore calls it with no
## controller) and books reseed every round. scratch keys, all optional:
##   contract  {state "offered"|"accepted", id, commodity, qty, unit_px,
##              offered_round, due_round}
##   squeeze   {commodity, price_bps, depth_bps, rounds_short}
##   delivered / missed   lifetime counters
## A DECLINED offer leaves no trace, so a run that always declines hashes exactly
## as it did before this archetype existed. Every scratch read goes through int():
## after a JSON load the numbers come back as floats.

const COMMODITIES_FALLBACK: Array = ["ORE", "MACHINERY"]
## Price step per consecutive round short: +10% a round up to the cap.
const SQUEEZE_STEP_BPS: int = 1000


static func _state(w: Barons, id: String) -> BaronState:
	return w.state(id)


static func _params(w: Barons, id: String) -> Dictionary:
	return w.def(id).get("params", {})


static func contract(w: Barons, id: String) -> Dictionary:
	var s: BaronState = _state(w, id)
	if s == null:
		return {}
	var c = s.scratch.get("contract", {})
	if not (c is Dictionary) or (c as Dictionary).is_empty():
		return {}
	return {
		"state": str(c.get("state", "")),
		"id": int(c.get("id", 0)),
		"commodity": str(c.get("commodity", "")),
		"qty": int(c.get("qty", 0)),
		"unit_px": int(c.get("unit_px", 0)),
		"offered_round": int(c.get("offered_round", 0)),
		"due_round": int(c.get("due_round", 0)),
	}


static func squeeze(w: Barons, id: String) -> Dictionary:
	var s: BaronState = _state(w, id)
	if s == null:
		return {}
	var q = s.scratch.get("squeeze", {})
	if not (q is Dictionary) or (q as Dictionary).is_empty():
		return {}
	return {
		"commodity": str(q.get("commodity", "")),
		"price_bps": int(q.get("price_bps", 0)),
		"depth_bps": int(q.get("depth_bps", 10000)),
		"rounds_short": int(q.get("rounds_short", 0)),
	}


## The squeeze as a book mod on the anchor (empty when none is active).
static func squeeze_mods(w: Barons, id: String) -> Array:
	var q: Dictionary = squeeze(w, id)
	if q.is_empty():
		return []
	return [{
		"station": str(w.def(id).get("anchor", "")),
		"commodity": str(q["commodity"]),
		"depth_bps": int(q["depth_bps"]),
		"price_bps": int(q["price_bps"]),
	}]


## Contract unit price: the anchor's BASE price for the commodity plus the bid
## premium, in whole CR (never the live book).
static func unit_price(w: Barons, id: String, commodity: String) -> int:
	var anchor: String = str(w.def(id).get("anchor", ""))
	var base: float = float(Transit.BASE_PRICES.get(anchor, {}).get(commodity, 1.0))
	var bps: int = int(_params(w, id).get("contract_bid_bps", 0))
	return maxi(1, int(round(base * float(10000 + bps) / 10000.0)))


## Commodities a contract may ask for: the baron's pipeline commodities in file order.
static func offer_commodities(w: Barons, id: String) -> Array:
	var out: Array = []
	for pipe in w.def(id).get("privileges", {}).get("pipelines", []):
		out.append(str(pipe.get("commodity", "")))
	return out if not out.is_empty() else COMMODITIES_FALLBACK


## The world step for one baron. See Barons.advance_round.
static func advance(w: Barons, id: String, round_num: int, rc: RunController) -> Array:
	var s: BaronState = _state(w, id)
	var events: Array = []
	if s == null:
		return events
	if s.holder != "":
		# A held baron does not squeeze its holder or post contracts to them.
		cancel(w, id)
		return events
	var p: Dictionary = _params(w, id)
	var anchor: String = str(w.def(id).get("anchor", ""))
	var c: Dictionary = contract(w, id)
	if str(c.get("state", "")) == "accepted":
		# Settle first: a ship docked at the anchor with the stock delivers even on the due round.
		var done: Dictionary = deliver(w, id, rc)
		if not done.is_empty():
			events.append(done)
			c = {}
	if str(c.get("state", "")) == "accepted":
		if round_num >= int(c["due_round"]):
			events.append(_miss(w, id, c, rc, round_num))
			c = {}
		else:
			var held: int = int(rc.cargo.get(c["commodity"], 0))
			var left: int = int(c["due_round"]) - round_num
			if left <= int(p.get("squeeze_window_rounds", 0)) and held < int(c["qty"]):
				var prior: Dictionary = squeeze(w, id)
				var short: int = int(prior.get("rounds_short", 0)) + 1
				var price: int = mini(int(p.get("squeeze_price_bps_max", 0)), SQUEEZE_STEP_BPS * short)
				s.scratch["squeeze"] = {
					"commodity": str(c["commodity"]), "price_bps": price,
					"depth_bps": int(p.get("squeeze_depth_bps", 10000)), "rounds_short": short,
				}
				events.append({"kind": "squeeze", "baron": id, "station": anchor, "commodity": str(c["commodity"]), "price_bps": price, "rounds_short": short})
			else:
				s.scratch.erase("squeeze")
	else:
		s.scratch.erase("squeeze")
	var every: int = int(p.get("contract_every_rounds", 0))
	if c.is_empty() and every > 0 and round_num > 0 and round_num % every == 0:
		events.append(_post_offer(w, id, round_num, rc))
	return events


## Posts the round's offer. Commodity and quantity come from this round's draw
## source, seeded from the run seed: a pure function of (run_seed, round).
static func _post_offer(w: Barons, id: String, round_num: int, rc: RunController) -> Dictionary:
	var s: BaronState = _state(w, id)
	var p: Dictionary = _params(w, id)
	var draw := NativeDrawSource.new(StableHash.hash32("baron-%s-%d-%d" % [id, rc.run_seed, round_num]))
	var commodity: String = str(draw.choice(offer_commodities(w, id)))
	var range_q: Array = p.get("contract_qty", [30, 60])
	var qty: int = draw.randint(int(range_q[0]), int(range_q[1]))
	var unit_px: int = unit_price(w, id, commodity)
	var rounds: int = maxi(1, int(p.get("contract_deadline_rounds", 6)))
	s.scratch["contract"] = {
		"state": "offered", "id": round_num, "commodity": commodity, "qty": qty,
		"unit_px": unit_px, "offered_round": round_num, "due_round": round_num + rounds,
	}
	return {
		"kind": "offer", "baron": id, "station": str(w.def(id).get("anchor", "")),
		"commodity": commodity, "qty": qty, "unit_px": unit_px, "total": qty * unit_px,
		"rounds": rounds, "due_round": round_num + rounds,
	}


## The player accepts the waiting offer. Returns the accepted event, {} when there
## is nothing to accept. Settlement is separate (deliver): M0Loop calls it right
## after, so a ship already docked at the anchor with the stock is paid at once.
static func accept(w: Barons, id: String, rc: RunController) -> Dictionary:
	var c: Dictionary = contract(w, id)
	if str(c.get("state", "")) != "offered":
		return {}
	var raw: Dictionary = (_state(w, id).scratch["contract"] as Dictionary)
	raw["state"] = "accepted"
	return {"kind": "accepted", "baron": id, "commodity": str(c["commodity"]), "qty": int(c["qty"]), "due_round": int(c["due_round"])}


static func decline(w: Barons, id: String) -> bool:
	var c: Dictionary = contract(w, id)
	if str(c.get("state", "")) != "offered":
		return false
	_state(w, id).scratch.erase("contract")
	return true


## Settles an accepted contract when the ship is docked at the anchor holding the
## whole quantity: cargo leaves, the player is paid qty x unit price, the baron
## pays from its treasury (floored at 0) and stocks the goods. {} when not met.
static func deliver(w: Barons, id: String, rc: RunController) -> Dictionary:
	var c: Dictionary = contract(w, id)
	if str(c.get("state", "")) != "accepted":
		return {}
	if rc.docked_at != str(w.def(id).get("anchor", "")) or int(rc.cargo.get(c["commodity"], 0)) < int(c["qty"]):
		return {}
	var s: BaronState = _state(w, id)
	var com: String = str(c["commodity"])
	var qty: int = int(c["qty"])
	var paid: int = qty * int(c["unit_px"])
	var left: int = int(rc.cargo[com]) - qty
	if left > 0:
		rc.cargo[com] = left
	else:
		rc.cargo.erase(com)
	rc.cr += paid
	s.treasury_cr = maxi(0, s.treasury_cr - paid)
	s.inventory[com] = int(s.inventory.get(com, 0)) + qty
	s.scratch["delivered"] = int(s.scratch.get("delivered", 0)) + 1
	s.scratch.erase("contract")
	s.scratch.erase("squeeze")
	return {"kind": "delivered", "baron": id, "commodity": com, "qty": qty, "paid": paid}


## A missed contract: its value x contract_penalty_bps joins the principal debt as a
## CONSEQUENCE event (docs 7 and decision 4). It may be what tips the corp into
## Chapter 11, and the event says so.
static func _miss(w: Barons, id: String, c: Dictionary, rc: RunController, round_num: int) -> Dictionary:
	var s: BaronState = _state(w, id)
	var value: int = int(c["qty"]) * int(c["unit_px"])
	var penalty: int = value * int(_params(w, id).get("contract_penalty_bps", 0)) / 10000
	var res: Dictionary = w.penalize(rc, penalty, "consequence")
	s.scratch["missed"] = int(s.scratch.get("missed", 0)) + 1
	s.scratch.erase("contract")
	s.scratch.erase("squeeze")
	return {
		"kind": "missed", "baron": id, "commodity": str(c["commodity"]), "qty": int(c["qty"]),
		"penalty": int(res["applied"]), "origin": str(res["origin"]), "forced_ch11": bool(res["forced_ch11"]),
		"round": round_num,
	}


static func cancel(w: Barons, id: String) -> void:
	var s: BaronState = _state(w, id)
	if s != null:
		s.scratch.erase("contract")
		s.scratch.erase("squeeze")
