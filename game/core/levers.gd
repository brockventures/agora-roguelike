class_name Levers
extends RefCounted
## The player's three levers on a sector baron (Epic 3 task 8, docs/design/epic3-barons.md 5.2).
##
## Each lever is a way to MAKE A BARON DISTRESSED; the takeover core (Takeover) then
## runs the distress auction, bankruptcy and the 501 takeover. Everything a lever does
## lands in BaronState, never in a resting order (design rule 1), and market_mods()
## re-emits the book effect every round from that state.
##
##  a. Corner. The player is docked at the baron's anchor and holds at least
##     `corner.hold_qty` of one of its pipeline commodities at a round boundary. The
##     baron must buy `corner.cover_qty` units of cover that round: from its own stock
##     first (which starves it), then bought at the anchor's base price plus
##     `corner.squeeze_bps`. What its treasury cannot pay becomes system debt. The
##     book shows the squeeze as an ask-side premium and a thinned ask.
##  b. Margin. A sale of a commodity the baron holds, at its anchor, adds
##     `margin.pressure_per_unit_bps` per unit to a per-commodity `pressure_bps`
##     accumulator (capped), which halves every round (integer) and is re-emitted as a
##     price mod. Collateral is the baron's stock marked at Piracy.REF_PRICE less that
##     pressure. A margin call needs pressure on a collateral commodity (a baron nobody
##     is leaning on is never called) and collateral under `margin.maintenance_bps` of
##     `margin_debt_cr`: it force-sells `margin.liquidate_bps` of each pressured
##     commodity at the Chapter 11 haircut, pays the loan down, charges a fee to the
##     treasury, writes any deficiency off as system debt, and crashes the book for
##     `margin.crash_rounds` rounds.
##  c. Credit line. The player extends `credit.line_cr` at `credit.rate_bps`, due in
##     `credit.term_rounds` rounds. A baron accepts only while pressed: insolvent
##     (`strain` > 0), or its treasury at or under `credit.accept_below_bps` of its
##     opening treasury (`strain` alone would let only an already insolvent baron
##     borrow). It spends `credit.spend_bps` of the principal at once. At maturity it
##     repays if its treasury covers the amount due, else defaults: the amount due
##     joins its debt as the player's claim, which bankruptcy settlement and the
##     takeover read.
##
## State: `pressure_bps` (an existing BaronState field) and three scratch keys,
## `corner` {COMMODITY: rounds}, `crash` {COMMODITY: rounds left}, `credit`
## {principal, due, due_round, rate_bps}, each written only while non-default. A world
## in which no lever is ever used writes nothing and hashes exactly as before.
## Nothing here is random. Every scratch read goes through int() (JSON floats). Every
## dictionary is walked in sorted key order. Ryan's rule (design doc 9.4): a lever only
## hurts a baron; the one thing it asks of the player is CR for a credit line, refused
## outright before it can leave the corp insolvent.

const PLAYER: String = "player"

const DEFAULTS: Dictionary = {
	"corner": {"hold_qty": 60, "cover_qty": 100, "squeeze_bps": 5000, "ask_depth_bps": 4000},
	"margin": {
		"maintenance_bps": 10500, "pressure_per_unit_bps": 40, "pressure_max_bps": 6000,
		"liquidate_bps": 3000, "crash_bps": 1500, "crash_rounds": 2, "fee_bps": 1000,
	},
	"credit": {"line_cr": 10000, "rate_bps": 2000, "term_rounds": 5, "spend_bps": 7500, "accept_below_bps": 7000},
	"tender": {"cap": 50, "premium_bps": 15000},
}

## The player-facing words for a refused credit line: the CSV key per reason.
const CREDIT_REASON_KEYS: Dictionary = {
	"NO_BARON": "CREDIT_REASON_NO_BARON",
	"HELD": "CREDIT_REASON_HELD",
	"OPEN": "CREDIT_REASON_OPEN",
	"NOT_PRESSED": "CREDIT_REASON_NOT_PRESSED",
	"NO_CR": "CREDIT_REASON_NO_CR",
	"WOULD_BANKRUPT": "CREDIT_REASON_WOULD_BANKRUPT",
}


static func reason_key(reason: String) -> String:
	return str(CREDIT_REASON_KEYS.get(reason, "CREDIT_REASON_NO_BARON"))


## The lever tunables: barons.json `levers` over DEFAULTS, every value an int.
static func settings(w: Barons) -> Dictionary:
	var out: Dictionary = {}
	var raw = w.data.get("levers", {})
	for group in DEFAULTS:
		out[group] = {}
		var src = raw.get(group, {}) if raw is Dictionary else {}
		for k in DEFAULTS[group]:
			out[group][k] = int((src as Dictionary).get(k, DEFAULTS[group][k])) if src is Dictionary else int(DEFAULTS[group][k])
	return out


static func _s(w: Barons, id: String) -> BaronState:
	return w.state(id)


static func _anchor(w: Barons, id: String) -> String:
	return str(w.def(id).get("anchor", ""))


## The baron's pipeline commodities, sorted: the "float" a corner squeezes.
static func float_commodities(w: Barons, id: String) -> Array:
	var out: Array = []
	for pipe in w.def(id).get("privileges", {}).get("pipelines", []):
		var c: String = str(pipe.get("commodity", ""))
		if c != "" and not out.has(c):
			out.append(c)
	out.sort()
	return out


## The anchor's base price in cents (a pure function of data, not the live book).
static func _base_cents(w: Barons, id: String, commodity: String) -> int:
	var base: Dictionary = Transit.BASE_PRICES.get(_anchor(w, id), {})
	return int(round(float(base.get(commodity, 0.0)) * 100.0))


# --- Reads ---

## {COMMODITY: rounds} of the corners standing now.
static func corners(w: Barons, id: String) -> Dictionary:
	return _int_map(_s(w, id).scratch.get("corner", {})) if _s(w, id) != null else {}


## What a corner costs the baron per round on `commodity`: cover units from stock
## first, then the rest at the squeezed price. {from_stock, bought, cost}.
static func cover_cost(w: Barons, id: String, commodity: String) -> Dictionary:
	var cfg: Dictionary = settings(w)["corner"]
	var s: BaronState = _s(w, id)
	var need: int = int(cfg["cover_qty"])
	var from_stock: int = mini(need, maxi(0, int(s.inventory.get(commodity, 0)))) if s != null else 0
	var bought: int = need - from_stock
	var cents: int = _base_cents(w, id, commodity) * (10000 + int(cfg["squeeze_bps"])) / 10000
	return {"from_stock": from_stock, "bought": bought, "cost": cents * bought / 100}


## {COMMODITY: bps} sell pressure standing on the baron's stock.
static func pressure(w: Barons, id: String) -> Dictionary:
	var s: BaronState = _s(w, id)
	return _int_map(s.pressure_bps) if s != null else {}


## Collateral value of the baron's stock: each commodity marked at Piracy.REF_PRICE
## (the Chapter 11 valuation) less its sell pressure.
static func collateral(w: Barons, id: String) -> int:
	var s: BaronState = _s(w, id)
	if s == null:
		return 0
	var total: int = 0
	var keys: Array = s.inventory.keys()
	keys.sort()
	for c in keys:
		var p: int = clampi(int(s.pressure_bps.get(c, 0)), 0, 10000)
		total += Piracy.cargo_value(str(c), int(s.inventory[c])) * (10000 - p) / 10000
	return total


## Collateral over margin debt as a percent (0 when there is no margin debt).
static func margin_ratio_pct(w: Barons, id: String) -> int:
	var s: BaronState = _s(w, id)
	if s == null or s.margin_debt_cr <= 0:
		return 0
	return collateral(w, id) * 100 / s.margin_debt_cr


## {COMMODITY: rounds left} of the forced-sale crash on the book.
static func crashes(w: Barons, id: String) -> Dictionary:
	return _int_map(_s(w, id).scratch.get("crash", {})) if _s(w, id) != null else {}


## The open credit line as {principal, due, due_round, rate_bps}; {} when none.
static func credit(w: Barons, id: String) -> Dictionary:
	var s: BaronState = _s(w, id)
	if s == null:
		return {}
	var c = s.scratch.get("credit", null)
	if not (c is Dictionary) or int((c as Dictionary).get("due", 0)) <= 0:
		return {}
	return {
		"principal": int(c.get("principal", 0)), "due": int(c["due"]),
		"due_round": int(c.get("due_round", 0)), "rate_bps": int(c.get("rate_bps", 0)),
	}


## True while the baron would take a credit line: insolvent, or its treasury at or
## under accept_below_bps of the opening treasury.
static func is_pressed(w: Barons, id: String) -> bool:
	var s: BaronState = _s(w, id)
	if s == null:
		return false
	if s.strain > 0:
		return true
	var opening: int = int(w.def(id).get("treasury_cr", 0))
	return s.treasury_cr * 10000 <= opening * int(settings(w)["credit"]["accept_below_bps"])


## The sell pressure and forced-sale crash mods for `commodity` at the anchor, as
## the book's price_bps; used by the board tag.
static func price_bps_on(w: Barons, id: String, commodity: String) -> int:
	var s: BaronState = _s(w, id)
	if s == null:
		return 0
	var cfg: Dictionary = settings(w)["margin"]
	var out: int = -int(s.pressure_bps.get(commodity, 0))
	if crashes(w, id).has(commodity):
		out -= int(cfg["crash_bps"])
	return out


# --- Book mods (read-only; appended after the baron's own mods) ---

static func mods(w: Barons, id: String) -> Array:
	var out: Array = []
	var s: BaronState = _s(w, id)
	if s == null:
		return out
	var anchor: String = _anchor(w, id)
	var cfg: Dictionary = settings(w)
	var press: Dictionary = pressure(w, id)
	var keys: Array = press.keys()
	keys.sort()
	for c in keys:
		if int(press[c]) > 0:
			out.append({"station": anchor, "commodity": str(c), "price_bps": -int(press[c])})
	var cr: Dictionary = crashes(w, id)
	keys = cr.keys()
	keys.sort()
	for c in keys:
		if int(cr[c]) > 0:
			out.append({"station": anchor, "commodity": str(c), "price_bps": -int(cfg["margin"]["crash_bps"])})
	if s.holder == "":
		var co: Dictionary = corners(w, id)
		keys = co.keys()
		keys.sort()
		for c in keys:
			if int(co[c]) > 0:
				out.append({
					"station": anchor, "commodity": str(c),
					"ask_price_bps": int(cfg["corner"]["squeeze_bps"]),
					"ask_depth_bps": int(cfg["corner"]["ask_depth_bps"]),
				})
	return out


# --- The feed: the player's sales ---

## A sale at `station` of `qty` units of `commodity` (the trade StationMarket.execute
## filled). Adds sell pressure when the station is a baron's anchor, that baron is not
## held, and the commodity is part of its stock. Returns the pressure now standing.
static func record_trade(w: Barons, station: String, commodity: String, side: String, qty: int) -> int:
	if side.to_upper() != "SELL" or qty <= 0:
		return 0
	var id: String = w.baron_at(station)
	var s: BaronState = _s(w, id) if id != "" else null
	var c: String = commodity.to_upper()
	if s == null or s.holder != "" or not s.inventory.has(c):
		return 0
	var cfg: Dictionary = settings(w)["margin"]
	var p: int = mini(int(cfg["pressure_max_bps"]), int(s.pressure_bps.get(c, 0)) + qty * int(cfg["pressure_per_unit_bps"]))
	s.pressure_bps[c] = p
	return p


# --- The world step ---

## One baron's lever step at the round boundary (Barons.advance_round, after the
## archetype and before Takeover.advance). Writes state; market_mods() only reads it.
## Returns events.
static func advance(w: Barons, id: String, round_num: int, rc: RunController) -> Array:
	var events: Array = []
	var s: BaronState = _s(w, id)
	if s == null:
		return events
	_tick_crash(s)
	if s.holder == "":
		events.append_array(_credit_maturity(w, id, round_num, rc))
		events.append_array(_corner_step(w, id, rc))
		events.append_array(_margin_step(w, id))
	else:
		s.scratch.erase("corner")
		s.scratch.erase("credit")
	_decay_pressure(s)
	return events


static func _tick_crash(s: BaronState) -> void:
	var cr = s.scratch.get("crash", null)
	if not (cr is Dictionary):
		return
	var out: Dictionary = {}
	var keys: Array = (cr as Dictionary).keys()
	keys.sort()
	for c in keys:
		var left: int = int(cr[c]) - 1
		if left > 0:
			out[str(c)] = left
	if out.is_empty():
		s.scratch.erase("crash")
	else:
		s.scratch["crash"] = out


## The accumulator halves every round (integer), erased at 0.
static func _decay_pressure(s: BaronState) -> void:
	var keys: Array = s.pressure_bps.keys()
	keys.sort()
	for c in keys:
		var half: int = int(s.pressure_bps[c]) / 2
		if half > 0:
			s.pressure_bps[c] = half
		else:
			s.pressure_bps.erase(c)


static func _corner_step(w: Barons, id: String, rc: RunController) -> Array:
	var events: Array = []
	var s: BaronState = _s(w, id)
	var cfg: Dictionary = settings(w)["corner"]
	var before: Dictionary = corners(w, id)
	var now: Dictionary = {}
	if rc != null and rc.docked_at == _anchor(w, id) and not rc.is_in_transit():
		for c in float_commodities(w, id):
			if int(rc.cargo.get(c, 0)) >= int(cfg["hold_qty"]):
				now[c] = int(before.get(c, 0)) + 1
	for c in now:
		var cc: Dictionary = cover_cost(w, id, c)
		s.inventory[c] = int(s.inventory.get(c, 0)) - int(cc["from_stock"])
		var cost: int = int(cc["cost"])
		var paid: int = mini(maxi(0, s.treasury_cr), cost)
		s.treasury_cr -= paid
		if cost > paid:
			Takeover.add_debt(w, id, cost - paid)  # cover it could not pay for, bought on credit
		events.append({
			"kind": "lever_corner", "baron": id, "commodity": c, "round": int(now[c]),
			"from_stock": int(cc["from_stock"]), "cost": cost, "unpaid": cost - paid,
		})
	for c in before:
		if not now.has(c):
			events.append({"kind": "lever_corner_end", "baron": id, "commodity": c})
	if now.is_empty():
		s.scratch.erase("corner")
	else:
		s.scratch["corner"] = now
	return events


static func _margin_step(w: Barons, id: String) -> Array:
	var events: Array = []
	var s: BaronState = _s(w, id)
	if s.margin_debt_cr <= 0:
		return events
	var cfg: Dictionary = settings(w)["margin"]
	var pressed: Array = []
	var keys: Array = s.pressure_bps.keys()
	keys.sort()
	for c in keys:
		if int(s.pressure_bps[c]) > 0 and int(s.inventory.get(c, 0)) > 0:
			pressed.append(str(c))
	if pressed.is_empty() or not crashes(w, id).is_empty():
		return events  # no new call while the last forced sale is still on the book
	if collateral(w, id) * 10000 >= s.margin_debt_cr * int(cfg["maintenance_bps"]):
		return events
	# The call: force-sell a slice of each pressured commodity into the baron's own book.
	var sold_units: int = 0
	var notional: int = 0
	var proceeds: int = 0
	var crash: Dictionary = _int_map(s.scratch.get("crash", {}))
	for c in pressed:
		var have: int = int(s.inventory.get(c, 0))
		var units: int = mini(have, maxi(1, have * int(cfg["liquidate_bps"]) / 10000))
		var value: int = Piracy.cargo_value(c, units) * (10000 - clampi(int(s.pressure_bps[c]), 0, 10000)) / 10000
		s.inventory[c] = have - units
		sold_units += units
		notional += value
		proceeds += value * Chapter11.LIQUIDATION_HAIRCUT_BPS / 10000
		crash[c] = int(cfg["crash_rounds"])
	var repay: int = mini(s.margin_debt_cr, proceeds)
	s.margin_debt_cr -= repay
	s.treasury_cr += proceeds - repay
	var fee: int = notional * int(cfg["fee_bps"]) / 10000
	var fee_paid: int = mini(maxi(0, s.treasury_cr), fee)
	s.treasury_cr -= fee_paid
	# What the remaining stock no longer covers is the lender's loss: it joins the baron's
	# debt, unsecured, with whatever fee the treasury could not pay.
	var excess: int = maxi(0, s.margin_debt_cr - collateral(w, id))
	s.margin_debt_cr -= excess
	var deficiency: int = excess + (fee - fee_paid)
	if deficiency > 0:
		Takeover.add_debt(w, id, deficiency)
	s.scratch["crash"] = crash
	events.append({
		"kind": "lever_margin", "baron": id, "commodities": pressed, "units": sold_units,
		"proceeds": proceeds, "fee": fee, "deficiency": deficiency,
	})
	return events


static func _credit_maturity(w: Barons, id: String, round_num: int, rc: RunController) -> Array:
	var events: Array = []
	var s: BaronState = _s(w, id)
	var c: Dictionary = credit(w, id)
	if c.is_empty() or round_num < int(c["due_round"]):
		return events
	var due: int = int(c["due"])
	if s.treasury_cr >= due:
		if rc == null:
			return events  # nobody to pay: it waits for the player's controller
		s.treasury_cr -= due
		rc.cr += due
		s.scratch.erase("credit")
		events.append({"kind": "credit_repaid", "baron": id, "due": due})
	else:
		Takeover.add_debt(w, id, due, PLAYER)
		s.scratch.erase("credit")
		events.append({"kind": "credit_default", "baron": id, "due": due})
	return events


# --- The credit line (the player's action) ---

## Extends the standard line to the baron anchoring `station`. {ok, reason, principal,
## due, due_round, events}. Refused: NO_BARON, HELD, OPEN, NOT_PRESSED, NO_CR, and
## WOULD_BANKRUPT (the lent CR would leave the corp insolvent: the receivable is not in
## the Chapter 11 snapshot).
static func open_credit(w: Barons, station: String, rc: RunController) -> Dictionary:
	var out: Dictionary = {"ok": false, "reason": "", "principal": 0, "due": 0, "due_round": 0, "events": []}
	var id: String = w.baron_at(station)
	var s: BaronState = _s(w, id) if id != "" else null
	if s == null:
		out["reason"] = "NO_BARON"
		return out
	if s.holder != "":
		out["reason"] = "HELD"
		return out
	if not credit(w, id).is_empty():
		out["reason"] = "OPEN"
		return out
	if not is_pressed(w, id):
		out["reason"] = "NOT_PRESSED"
		return out
	var cfg: Dictionary = settings(w)["credit"]
	var principal: int = int(cfg["line_cr"])
	if principal <= 0 or rc.cr < principal:
		out["reason"] = "NO_CR"
		return out
	var snap: Dictionary = rc.snapshot()
	snap["cr"] = rc.cr - principal
	if bool(Chapter11.assess(snap, rc.haircut_bps())["insolvent"]):
		out["reason"] = "WOULD_BANKRUPT"
		return out
	var due: int = principal * (10000 + int(cfg["rate_bps"])) / 10000
	var due_round: int = rc.get_current_round() + int(cfg["term_rounds"])
	rc.cr -= principal
	s.treasury_cr += principal * (10000 - clampi(int(cfg["spend_bps"]), 0, 10000)) / 10000
	s.scratch["credit"] = {"principal": principal, "due": due, "due_round": due_round, "rate_bps": int(cfg["rate_bps"])}
	out["ok"] = true
	out["principal"] = principal
	out["due"] = due
	out["due_round"] = due_round
	out["events"] = [{"kind": "credit_open", "baron": id, "principal": principal, "due": due, "due_round": due_round, "rate_bps": int(cfg["rate_bps"])}]
	return out


## Bankruptcy calls the line in: the amount due joins the debt as the player's claim.
static func accelerate(w: Barons, id: String) -> void:
	var c: Dictionary = credit(w, id)
	if c.is_empty():
		return
	_s(w, id).scratch.erase("credit")
	Takeover.add_debt(w, id, int(c["due"]), PLAYER)


## A takeover cancels what the taker was owed by itself and ends every lever.
static func cancel_baron(w: Barons, id: String) -> void:
	var s: BaronState = _s(w, id)
	if s == null:
		return
	s.scratch.erase("corner")
	s.scratch.erase("credit")


## A Chapter 11 filing: the failed corp's open lines and corners end with it.
static func cancel_all(w: Barons) -> void:
	for id in w.ids():
		cancel_baron(w, id)


static func _int_map(v: Variant) -> Dictionary:
	var out: Dictionary = {}
	if v is Dictionary:
		var keys: Array = (v as Dictionary).keys()
		keys.sort()
		for k in keys:
			out[str(k)] = int(v[k])
	return out
