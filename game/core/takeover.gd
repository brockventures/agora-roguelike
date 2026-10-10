class_name Takeover
extends RefCounted
## Hostile takeover and baron insolvency (Epic 3 task 7, docs/design/epic3-barons.md 5).
##
## The takeover core, ported from agora/corporate.py (`_auction_treasury`,
## `_takeovers`, `_bankrupt`, BANKRUPT_ROUNDS):
##  - Float. A baron has `float_shares` (1000); `treasury_shares` of them sit in its
##    own treasury, the rest are outside. `shares` counts what each buyer holds.
##  - Insolvency is Chapter11.assess on {cr: treasury, cargo: inventory, ships: [],
##    doomsday: {principal_debt: debt_cr}}: one definition for the player and the
##    barons, 50% haircut included. `strain` counts consecutive insolvent rounds.
##  - Distress auction. While insolvent and holding treasury shares, a baron offers
##    min(treasury_shares, ceil(shortfall / px), auction_cap) shares at
##    px = max(1, max(NAV per share, auction_price_floor) x auction_discount_bps).
##    The offer is written at the round boundary and read during the next round; the
##    player buys through Barons.buy_shares. Rival fleets do not exist yet:
##    Barons.rival_bids() is the seam (it returns no bids today).
##  - Takeover. `threshold_shares` (501) in one hand takes the baron at once: the
##    taker becomes `holder`, absorbs the treasury and the debt (a claim the taker
##    itself held cancels), and the baron's archetype AI stops acting.
##  - Bankruptcy. `bankrupt_rounds` (6) insolvent rounds with no treasury shares
##    left: inventory liquidates at the haircut, the proceeds pay creditors pro rata
##    by claim, and the largest claim holder (ties: sorted id) becomes holder.
##    Claims the world cannot attribute (every debt there is today) belong to
##    "system", which never becomes holder: a bankruptcy whose largest claim is the
##    system's reorganises the baron back to NPC control.
##  - Rent. A baron the player holds pays the anchor's maker spread each round.
##  - A Chapter 11 filing forfeits everything the failed corp held (forfeit()).
##
## State lives in BaronState fields that already serialise (treasury_cr,
## treasury_shares, inventory, debt_cr, strain, holder, shares) plus scratch keys
## written only while they are non-default (`distress`, `claims`), so
## a world in which no baron is ever insolvent hashes exactly as before. All money
## and shares are integers; every dictionary is walked in sorted key order; nothing
## here draws a random number (tie-breaks are sorted ids), so a replay re-derives it.
## Every scratch read goes through int() (JSON numbers come back as floats).
##
## Ryan's rule (design doc 9.4): nothing here is a random event. The only paths that
## can put the player into Chapter 11 are the debt a player's own purchase makes them
## assume (take(), reported as `forced_ch11`) and the player's own spending, which a
## purchase refuses outright (buy()).

const PLAYER: String = "player"
const SYSTEM: String = "system"
## Defaults for takeover keys a barons.json may leave out (the shipped file sets them).
const DEFAULT_PRICE_FLOOR: int = 10
const DEFAULT_RESET_BPS: int = 4000
const DEFAULT_RENT_UNITS: int = 100
const DEFAULT_RENT_SPREAD_BPS: int = 600


static func _s(w: Barons, id: String) -> BaronState:
	return w.state(id)


static func settings(w: Barons) -> Dictionary:
	var t: Dictionary = w.data.get("takeover", {})
	return {
		"float": int(t.get("float_shares", 1000)),
		"threshold": int(t.get("threshold_shares", 501)),
		"cap": int(t.get("auction_cap", 100)),
		"discount_bps": int(t.get("auction_discount_bps", 7000)),
		"floor": int(t.get("auction_price_floor", DEFAULT_PRICE_FLOOR)),
		"bankrupt_rounds": int(t.get("bankrupt_rounds", 6)),
		"reset_bps": clampi(int(t.get("reset_treasury_bps", DEFAULT_RESET_BPS)), 0, 10000),
		"rent_units": int(t.get("rent_units", DEFAULT_RENT_UNITS)),
		"rent_spread_bps": int(t.get("rent_spread_bps", DEFAULT_RENT_SPREAD_BPS)),
	}


# --- Reads ---

## Chapter11.assess on the baron's balance sheet (design doc 5.3).
static func assess(w: Barons, id: String) -> Dictionary:
	var s: BaronState = _s(w, id)
	if s == null:
		return {}
	return Chapter11.assess({
		"cr": s.treasury_cr,
		"cargo": s.inventory,
		"ships": [],
		"doomsday": {"principal_debt": s.debt_cr},
	})


## Creditors' claims on the baron by creditor id (the attributed part of debt_cr).
static func claims(w: Barons, id: String) -> Dictionary:
	var s: BaronState = _s(w, id)
	var out: Dictionary = {}
	if s == null:
		return out
	var raw = s.scratch.get("claims", {})
	if raw is Dictionary:
		var keys: Array = (raw as Dictionary).keys()
		keys.sort()
		for k in keys:
			if int(raw[k]) > 0:
				out[str(k)] = int(raw[k])
	return out


## The distress offer standing now as {px, qty, round}; {} when none.
static func offer(w: Barons, id: String) -> Dictionary:
	var s: BaronState = _s(w, id)
	if s == null or s.holder != "":
		return {}
	var d = s.scratch.get("distress", null)
	if not (d is Dictionary) or int(d.get("qty", 0)) <= 0:
		return {}
	return {"px": int(d["px"]), "qty": int(d["qty"]), "round": int(d.get("round", 0))}


## The player-facing words for a refused buy: the CSV key per Takeover.buy reason.
const REASON_KEYS: Dictionary = {
	"NO_OFFER": "SHARES_REASON_NO_OFFER",
	"NO_CR": "SHARES_REASON_NO_CR",
	"WOULD_BANKRUPT": "SHARES_REASON_WOULD_BANKRUPT",
	"HELD": "SHARES_REASON_HELD",
}


static func reason_key(reason: String) -> String:
	return str(REASON_KEYS.get(reason, "SHARES_REASON_NO_OFFER"))


static func shares_of(w: Barons, id: String, holder: String) -> int:
	var s: BaronState = _s(w, id)
	return int(s.shares.get(holder, 0)) if s != null else 0


## Rent a held baron pays its holder per round: for each pipeline commodity,
## rent_units of the anchor's BASE price (not the live book, so it is a pure function
## of saved state) at rent_spread_bps. Whole CR, integer arithmetic.
static func rent(w: Barons, id: String) -> int:
	var d: Dictionary = w.def(id)
	var cfg: Dictionary = settings(w)
	var total: int = 0
	var base: Dictionary = Transit.BASE_PRICES.get(str(d.get("anchor", "")), {})
	for pipe in d.get("privileges", {}).get("pipelines", []):
		var cents: int = int(round(float(base.get(str(pipe.get("commodity", "")), 0.0)) * 100.0))
		total += cents * int(cfg["rent_units"]) * int(cfg["rent_spread_bps"]) / 1000000
	return maxi(0, total)


static func _ceil_div(a: int, b: int) -> int:
	return (a + b - 1) / b if a > 0 else 0


static func _cancel_archetype(w: Barons, id: String) -> void:
	match str(w.def(id).get("archetype", "")):
		"short_squeezer":
			AresHeavy.cancel(w, id)
		"auctioneer":
			SolCentral.cancel(w, id)


# --- The world step ---

## One baron's takeover step at the round boundary (called by Barons.advance_round
## after the archetype). Writes state; market_mods() only reads it. Returns events.
static func advance(w: Barons, id: String, round_num: int, rc: RunController) -> Array:
	var events: Array = []
	var s: BaronState = _s(w, id)
	if s == null:
		return events
	if s.holder != "":
		if s.holder == PLAYER and rc != null:
			var r: int = rent(w, id)
			if r > 0:
				rc.cr += r
		return events
	var cfg: Dictionary = settings(w)
	var a: Dictionary = assess(w, id)
	if not bool(a["insolvent"]):
		if s.strain != 0:
			s.strain = 0
		s.scratch.erase("distress")
		return events
	s.strain += 1
	var shortfall: int = int(a["shortfall"])
	if s.treasury_shares > 0:
		var nav_ps: int = maxi(0, int(a["liquidation_value"]) - int(a["total_debt"])) / maxi(1, int(cfg["float"]))
		var px: int = maxi(1, maxi(nav_ps, int(cfg["floor"])) * int(cfg["discount_bps"]) / 10000)
		var qty: int = mini(s.treasury_shares, mini(_ceil_div(shortfall, px), int(cfg["cap"])))
		s.scratch["distress"] = {"px": px, "qty": qty, "round": round_num}
		if s.strain == 1:
			events.append({"kind": "distress", "baron": id, "px": px, "qty": qty, "shortfall": shortfall, "cap": int(cfg["cap"])})
		# Seam for Epic 3 task 10: rival fleets bid for the lot in sorted id order.
		for bid in w.rival_bids(id, round_num, px, qty):
			events.append_array(w.sell_auction_shares(id, str(bid["buyer"]), int(bid["qty"]), rc))
			if s.holder != "":
				return events
	else:
		s.scratch.erase("distress")
	if s.strain >= int(cfg["bankrupt_rounds"]) and s.treasury_shares == 0:
		events.append(settle(w, id, rc))
	return events


# --- Buying ---

## The player buys up to `n` shares of the standing distress offer at the offer
## price. {ok, reason, n, cost, held, events}. Refused: HELD, NO_OFFER, NO_CR,
## WOULD_BANKRUPT (the spend would leave the corp insolvent; shares are not in the
## Chapter 11 snapshot, so spending lowers liquidation value).
static func buy(w: Barons, id: String, rc: RunController, n: int) -> Dictionary:
	var out: Dictionary = {"ok": false, "reason": "", "n": 0, "cost": 0, "held": 0, "events": []}
	var s: BaronState = _s(w, id)
	if s == null:
		out["reason"] = "NO_OFFER"
		return out
	if s.holder != "":
		out["reason"] = "HELD"
		return out
	var o: Dictionary = offer(w, id)
	if o.is_empty() or n <= 0:
		out["reason"] = "NO_OFFER"
		return out
	var px: int = int(o["px"])
	var take_n: int = mini(n, int(o["qty"]))
	# No more than the threshold needs: the 501st share takes the baron, the rest of
	# the lot stays on offer.
	take_n = mini(take_n, maxi(1, int(settings(w)["threshold"]) - shares_of(w, id, PLAYER)))
	take_n = mini(take_n, maxi(0, rc.cr) / px)
	if take_n <= 0:
		out["reason"] = "NO_CR"
		return out
	var snap: Dictionary = rc.snapshot()
	snap["cr"] = rc.cr - take_n * px
	if bool(Chapter11.assess(snap, rc.haircut_bps())["insolvent"]):
		out["reason"] = "WOULD_BANKRUPT"
		return out
	var events: Array = _transfer(w, id, PLAYER, take_n, px, rc)
	out["ok"] = true
	out["n"] = take_n
	out["cost"] = take_n * px
	out["held"] = shares_of(w, id, PLAYER)
	out["events"] = events
	return out


## Moves `n` treasury shares to `buyer` at `px`, treasury takes the cash, and takes
## the baron when the buyer reaches the threshold. The player's cash is debited here;
## any other buyer is a stand-in with no ledger of its own. Returns the events.
static func _transfer(w: Barons, id: String, buyer: String, n: int, px: int, rc: RunController) -> Array:
	var events: Array = []
	var s: BaronState = _s(w, id)
	var cfg: Dictionary = settings(w)
	if buyer == PLAYER and rc != null:
		rc.cr -= n * px
	s.treasury_cr += n * px
	s.treasury_shares -= n
	s.shares[buyer] = int(s.shares.get(buyer, 0)) + n
	var d = s.scratch.get("distress", null)
	if d is Dictionary:
		var left: int = int(d.get("qty", 0)) - n
		if left > 0:
			d["qty"] = left
		else:
			s.scratch.erase("distress")
	var held: int = int(s.shares[buyer])
	events.append({"kind": "shares", "baron": id, "buyer": buyer, "qty": n, "px": px, "held": held, "threshold": int(cfg["threshold"])})
	if held >= int(cfg["threshold"]):
		events.append(take(w, id, buyer, rc))
	return events


## `buyer` takes the baron. The player absorbs the treasury into CR and assumes the
## debt (their own claim cancels) as a CONSEQUENCE of their purchase, reporting
## `forced_ch11` when that tipped the corp from solvent to insolvent. The baron's
## stock stays in its warehouse (the hold is 100 units; Ares alone stocks 500). Its
## archetype AI stops acting against the holder.
static func take(w: Barons, id: String, buyer: String, rc: RunController) -> Dictionary:
	var s: BaronState = _s(w, id)
	var ev: Dictionary = {"kind": "takeover", "baron": id, "holder": buyer, "treasury": 0, "debt": 0, "forced_ch11": false}
	var cl: Dictionary = claims(w, id)
	var debt: int = maxi(0, s.debt_cr - int(cl.get(buyer, 0)))  # the taker's own loan cancels out
	if buyer == PLAYER and rc != null:
		var pre: Dictionary = rc.assess()
		ev["treasury"] = s.treasury_cr
		rc.cr += s.treasury_cr
		ev["debt"] = rc.doomsday.add_principal(debt)
		s.treasury_cr = 0
		ev["forced_ch11"] = not bool(pre["insolvent"]) and bool(rc.assess()["insolvent"])
	else:
		# A rival (Epic 3 task 10) has no ledger yet: the baron nets its own books.
		s.treasury_cr = maxi(0, s.treasury_cr - debt)
		ev["debt"] = debt
	s.holder = buyer
	s.debt_cr = 0
	s.strain = 0
	s.treasury_shares = 0
	s.scratch.erase("claims")
	s.scratch.erase("distress")
	_cancel_archetype(w, id)
	return ev


# --- Bankruptcy ---

## Settlement (design doc 5.3). Returns the event.
static func settle(w: Barons, id: String, rc: RunController) -> Dictionary:
	var s: BaronState = _s(w, id)
	var cfg: Dictionary = settings(w)
	var a: Dictionary = assess(w, id)
	var liquidation: int = int(a["liquidation_value"])
	var cl: Dictionary = claims(w, id)
	var attributed: int = 0
	for k in cl:
		attributed += int(cl[k])
	var owed: int = maxi(s.debt_cr, attributed)
	if owed > attributed:
		cl[SYSTEM] = int(cl.get(SYSTEM, 0)) + owed - attributed
	var ids: Array = cl.keys()
	ids.sort()
	var payout: int = mini(liquidation, owed)
	var paid: Dictionary = {}
	var given: int = 0
	var largest: String = ""
	for c in ids:
		var p: int = payout * int(cl[c]) / owed if owed > 0 else 0
		paid[c] = p
		given += p
		if largest == "" or int(cl[c]) > int(cl[largest]):
			largest = c  # sorted walk, strictly greater: ties keep the lower id
	if largest != "":
		paid[largest] = int(paid[largest]) + (payout - given)  # the rounding remainder
	var recovered: int = int(paid.get(PLAYER, 0))
	if recovered > 0 and rc != null:
		rc.cr += recovered
	var holder: String = largest if largest != SYSTEM else ""
	# What is left of the company: the stock is gone, the equity is wiped.
	s.inventory = {}
	s.treasury_cr = 0
	s.treasury_shares = 0
	s.shares = {}
	s.debt_cr = 0
	s.strain = 0
	s.scratch.erase("claims")
	s.scratch.erase("distress")
	if holder == "":
		# No creditor of its own took it: it reorganises under NPC management.
		var d: Dictionary = w.def(id)
		s.treasury_cr = int(d.get("treasury_cr", 0)) * int(cfg["reset_bps"]) / 10000
		s.treasury_shares = int(d.get("treasury_shares", 0))
	else:
		s.holder = holder
		_cancel_archetype(w, id)
	return {
		"kind": "bankrupt", "baron": id, "liquidation": liquidation, "owed": owed,
		"holder": holder, "recovered": recovered, "paid": paid,
	}


# --- Debt (seam for the levers, Epic 3 task 8) ---

## Adds `amount` to the baron's debt, attributed to `creditor` ("" or "system" =
## unattributed). Nothing in play raises a baron's debt until task 8's levers land;
## this is the one door they use, and the tests and screenshots drive distress
## through it.
static func add_debt(w: Barons, id: String, amount: int, creditor: String = "") -> void:
	var s: BaronState = _s(w, id)
	if s == null or amount <= 0:
		return
	s.debt_cr += amount
	if creditor != "" and creditor != SYSTEM:
		var cl: Dictionary = claims(w, id)
		cl[creditor] = int(cl.get(creditor, 0)) + amount
		s.scratch["claims"] = cl


# --- Chapter 11: forfeit ---

## A filing founds a new corp, so what the failed one held reverts, in sorted baron
## order. A held baron returns to NPC control with its opening stock and float and
## its treasury reset to reset_treasury_bps (40%) of the opening treasury. A partial
## stake goes back to the treasury shares, and the failed corp's claim on a baron
## is struck from its debt. Returns an event per baron that was held.
static func forfeit(w: Barons) -> Array:
	var events: Array = []
	var cfg: Dictionary = settings(w)
	for id in w.ids():
		var s: BaronState = _s(w, id)
		var d: Dictionary = w.def(id)
		if s.holder == PLAYER:
			s.holder = ""
			s.treasury_cr = int(d.get("treasury_cr", 0)) * int(cfg["reset_bps"]) / 10000
			s.treasury_shares = int(d.get("treasury_shares", 0))
			s.inventory = {}
			var inv = d.get("inventory", {})
			if inv is Dictionary:
				for k in inv:
					s.inventory[str(k)] = int(inv[k])
			s.debt_cr = 0
			s.strain = 0
			s.shares = {}
			s.scratch.erase("claims")
			s.scratch.erase("distress")
			events.append({"kind": "forfeit", "baron": id})
		elif s.holder == "" and (int(s.shares.get(PLAYER, 0)) > 0 or int(claims(w, id).get(PLAYER, 0)) > 0):
			s.treasury_shares += int(s.shares.get(PLAYER, 0))
			s.shares.erase(PLAYER)
			var cl: Dictionary = claims(w, id)
			if cl.has(PLAYER):
				s.debt_cr = maxi(0, s.debt_cr - int(cl[PLAYER]))
				cl.erase(PLAYER)
				if cl.is_empty():
					s.scratch.erase("claims")
				else:
					s.scratch["claims"] = cl
			s.scratch.erase("distress")
	return events
