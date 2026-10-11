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
##  - Distress auction (sealed-bid, uniform price, #134). While insolvent and holding treasury
##    shares, a baron offers min(treasury_shares, ceil(shortfall / px), auction_cap) shares with
##    a reserve of px = max(1, max(NAV per share, auction_price_floor) x auction_discount_bps).
##    The lot is written at the round boundary. During the next round the player submits a
##    bid {qty, max_price} (Barons.submit_bid; the shares action bids the whole lot at "your
##    value"). At the following boundary the lot clears: the player's bid and the fleets'
##    (Rivals.bids, computed from state) fill highest price first, ties by sorted id, and every
##    winner pays the lowest winning price. A lot that is not oversubscribed has no price
##    competition and clears at the reserve. A fleet that liquidates leaves a forced lot (no
##    reserve, any bid of at least 1 CR a share) in `scratch["forced"]`, offered at the baron's
##    next boundary whether or not the baron is distressed.
##  - Control premium. A bidder values a share at NAV per share (at least the price floor) x
##    (1 + premium_bps(stake) / 10000); the premium rises with the bidder's own stake as a share
##    of its takeover threshold along `takeover.control_premium`. value_per_share() is the one
##    rule behind the fleets' top bids, a fleet's asking price in recapture(), and the HUD.
##  - Recapture. The player tenders to a fleet holding shares; it sells at or above its own
##    valuation, premium included.
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
## [stake_bps of the bidder's threshold, control premium bps]; barons.json overrides.
const DEFAULT_PREMIUM: Array = [[0, 0], [5000, 2000], [8000, 9000], [10000, 10000]]


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
		"premium": t.get("control_premium", DEFAULT_PREMIUM),
		"bid_step_bps": clampi(int(t.get("bid_step_bps", 1500)), 0, 100000),
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
	return {"px": int(d["px"]), "qty": int(d["qty"]), "round": int(d.get("round", 0)), "forced": int(d.get("forced", 0)) == 1}


## The player-facing words for a refused buy: the CSV key per Takeover.buy reason.
const REASON_KEYS: Dictionary = {
	"NO_OFFER": "SHARES_REASON_NO_OFFER",
	"NO_CR": "SHARES_REASON_NO_CR",
	"WOULD_BANKRUPT": "SHARES_REASON_WOULD_BANKRUPT",
	"HELD": "SHARES_REASON_HELD",
	"LOCKED": "SHARES_REASON_LOCKED",
	"BELOW_RESERVE": "SHARES_REASON_BELOW_RESERVE",
	"NO_FLEET": "SHARES_REASON_NO_FLEET",
	"NO_SHARES": "SHARES_REASON_NO_SHARES",
	"REJECTED": "SHARES_REASON_REJECTED",
}


static func reason_key(reason: String) -> String:
	return str(REASON_KEYS.get(reason, "SHARES_REASON_NO_OFFER"))


## The shares `buyer` needs to take the baron. The player's is cut by the
## `takeover_threshold_shares` perk stat (Hostile Buyout Line, -50: 451 not 501);
## every other buyer needs the full threshold.
static func threshold_for(w: Barons, buyer: String, rc: RunController = null) -> int:
	var base: int = int(settings(w)["threshold"])
	if buyer == PLAYER and rc != null:
		return clampi(Parachutes.apply_stat(rc.modifiers, "takeover_threshold_shares", base), 1, base)
	return base


## True while the Hostile Buyout Line perk is owned: it unlocks tender offers.
static func tender_unlocked(rc: RunController) -> bool:
	return rc != null and rc.modifiers.has("takeover_threshold_shares")


## Shares outside the baron's treasury that nobody in the world holds yet: what a
## tender offer can reach (the float less the treasury's and every holder's).
static func public_float(w: Barons, id: String) -> int:
	var s: BaronState = _s(w, id)
	if s == null or s.holder != "":
		return 0
	var held: int = 0
	for k in s.shares:
		held += int(s.shares[k])
	return maxi(0, int(settings(w)["float"]) - s.treasury_shares - held - int(s.scratch.get("forced", 0)))


## The tender price per share: NAV per share (at least the auction floor) over
## `tender.premium_bps`. A tender buys at a premium, the distress auction at a discount.
static func tender_price(w: Barons, id: String) -> int:
	var a: Dictionary = assess(w, id)
	var cfg: Dictionary = settings(w)
	var nav_ps: int = maxi(0, int(a["liquidation_value"]) - int(a["total_debt"])) / maxi(1, int(cfg["float"]))
	return maxi(1, maxi(nav_ps, int(cfg["floor"])) * int(Levers.settings(w)["tender"]["premium_bps"]) / 10000)


## The tender standing now as {px, qty}: up to `tender.cap` shares a round of the
## public float. {} when the perk is not owned, the baron is held, or nothing is left.
static func tender_offer(w: Barons, id: String, rc: RunController) -> Dictionary:
	if not tender_unlocked(rc):
		return {}
	var s: BaronState = _s(w, id)
	if s == null or s.holder != "":
		return {}
	var used: int = 0
	var t = s.scratch.get("tender", null)
	if t is Dictionary and int(t.get("round", -1)) == rc.get_current_round():
		used = int(t.get("n", 0))
	var qty: int = mini(public_float(w, id), maxi(0, int(Levers.settings(w)["tender"]["cap"]) - used))
	if qty <= 0:
		return {}
	return {"px": tender_price(w, id), "qty": qty}


## NAV per share, at least the auction price floor: the base every price here is built on.
static func base_price(w: Barons, id: String) -> int:
	var a: Dictionary = assess(w, id)
	var cfg: Dictionary = settings(w)
	var nav_ps: int = maxi(0, int(a["liquidation_value"]) - int(a["total_debt"])) / maxi(1, int(cfg["float"]))
	return maxi(nav_ps, int(cfg["floor"]))


## The control premium in bps for a stake of `stake_bps` (of the bidder's own takeover
## threshold, 0..10000): piecewise-linear integer interpolation along `takeover.control_premium`.
static func premium_bps(w: Barons, stake_bps: int) -> int:
	var pts: Array = settings(w)["premium"]
	var st: int = clampi(stake_bps, 0, 10000)
	var prev_x: int = int(pts[0][0])
	var prev_y: int = int(pts[0][1])
	for i in range(1, pts.size()):
		var x: int = int(pts[i][0])
		var y: int = int(pts[i][1])
		if st <= x:
			return prev_y + (y - prev_y) * (st - prev_x) / maxi(1, x - prev_x)
		prev_x = x
		prev_y = y
	return prev_y


## `bidder`'s stake in baron `id` as bps of the shares it needs to take it (capped at 10000).
static func stake_bps(w: Barons, id: String, bidder: String, rc: RunController = null) -> int:
	return clampi(shares_of(w, id, bidder) * 10000 / maxi(1, threshold_for(w, bidder, rc)), 0, 10000)


## What one share of baron `id` is worth to `bidder` ("player" or a fleet id): the base price
## times (1 + control premium for its own stake). The most a fleet bids, the price a fleet
## sells at in recapture(), and the HUD's "your value". Whole CR, at least 1.
static func value_per_share(w: Barons, id: String, bidder: String, rc: RunController = null) -> int:
	return maxi(1, base_price(w, id) * (10000 + premium_bps(w, stake_bps(w, id, bidder, rc))) / 10000)


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

## One baron's takeover step at the round boundary (called by Barons.advance_round after the
## archetype). Writes state; market_mods() only reads it. Returns events. The lot posted last
## boundary clears first (clear_lot), then the baron is re-assessed and posts the next one.
static func advance(w: Barons, id: String, round_num: int, rc: RunController) -> Array:
	var events: Array = []
	var s: BaronState = _s(w, id)
	if s == null:
		return events
	var held_before: String = s.holder
	events.append_array(clear_lot(w, id, round_num, rc))
	if held_before == "" and s.holder != "":
		return events  # taken at this clearing: the rent starts next boundary
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
		s.scratch.erase("bids")
	else:
		s.strain += 1
		var shortfall: int = int(a["shortfall"])
		if s.treasury_shares > 0:
			var px: int = maxi(1, base_price(w, id) * int(cfg["discount_bps"]) / 10000)
			var qty: int = mini(s.treasury_shares, mini(_ceil_div(shortfall, px), int(cfg["cap"])))
			s.scratch["distress"] = {"px": px, "qty": qty, "round": round_num}
			if s.strain == 1:
				events.append({"kind": "distress", "baron": id, "px": px, "qty": qty, "shortfall": shortfall, "cap": int(cfg["cap"])})
		else:
			s.scratch.erase("distress")
	# A liquidated fleet's shares: offered next, with no reserve, whether or not the baron is
	# distressed (the treasury's own lot waits a round).
	if int(s.scratch.get("forced", 0)) > 0:
		s.scratch["distress"] = {"px": 0, "qty": int(s.scratch["forced"]), "round": round_num, "forced": 1}
	if bool(a["insolvent"]) and s.strain >= int(cfg["bankrupt_rounds"]) and s.treasury_shares == 0:
		events.append(settle(w, id, rc))
	return events


# --- The sealed-bid auction ---

## The player's standing bid on baron `id` as {qty, px}, {} when none.
static func player_bid(w: Barons, id: String) -> Dictionary:
	var s: BaronState = _s(w, id)
	if s == null:
		return {}
	var b = s.scratch.get("bids", null)
	if b is Dictionary and (b as Dictionary).get(PLAYER, null) is Dictionary:
		var pb: Dictionary = b[PLAYER]
		if int(pb.get("qty", 0)) > 0:
			return {"qty": int(pb["qty"]), "px": int(pb.get("px", 0))}
	return {}


## Fills `bids` ({buyer, qty, max_price}) against a lot of `lot` shares with reserve `reserve`:
## highest price first, ties by sorted buyer id, bids under the reserve (or under 1 CR) ignored.
## Every winner pays one price: the lowest winning bid when the lot is oversubscribed, else the
## reserve (at least 1). Returns {price, fills: [{buyer, qty}], sold}.
static func fill(bids: Array, lot: int, reserve: int) -> Dictionary:
	var floor_px: int = maxi(1, reserve)
	var eligible: Array = []
	var demand: int = 0
	for b in bids:
		if int(b["qty"]) > 0 and int(b["max_price"]) >= floor_px:
			eligible.append(b)
			demand += int(b["qty"])
	eligible.sort_custom(func(x, y) -> bool:
		if int(x["max_price"]) != int(y["max_price"]):
			return int(x["max_price"]) > int(y["max_price"])
		return str(x["buyer"]) < str(y["buyer"]))
	var fills: Array = []
	var left: int = lot
	var lowest: int = floor_px
	for b in eligible:
		if left <= 0:
			break
		var n: int = mini(int(b["qty"]), left)
		fills.append({"buyer": str(b["buyer"]), "qty": n})
		lowest = int(b["max_price"])
		left -= n
	return {"price": lowest if demand > lot else floor_px, "fills": fills, "sold": lot - left}


## Clears the standing lot of baron `id` at the round boundary: see the header. Pays the
## fleets' CR, moves the shares, takes the baron if a winner reaches its threshold. A player
## bid the player can no longer afford (or that would leave the corp insolvent, Ryan's rule)
## is cut down, then dropped, and the lot re-cleared without it. Records the last clearing in
## `scratch["last_clear"]`. Returns events: "auction" then the usual "shares"/"takeover".
static func clear_lot(w: Barons, id: String, round_num: int, rc: RunController) -> Array:
	var events: Array = []
	var s: BaronState = _s(w, id)
	if s == null:
		return events
	var d = s.scratch.get("distress", null)
	if not (d is Dictionary) or s.holder != "" or int(d.get("qty", 0)) <= 0:
		s.scratch.erase("bids")
		return events
	var forced: bool = int(d.get("forced", 0)) == 1
	var reserve: int = int(d["px"])
	var lot: int = int(d["qty"])
	var bids: Array = Rivals.bids(w, id, round_num, reserve, lot, rc, forced)
	var pb: Dictionary = player_bid(w, id)
	var pq: int = 0
	if not pb.is_empty() and rc != null:
		pq = mini(int(pb["qty"]), maxi(1, threshold_for(w, PLAYER, rc) - shares_of(w, id, PLAYER)))
	var res: Dictionary = {}
	for _i in 6:
		var all: Array = bids.duplicate()
		if pq > 0:
			all.append({"buyer": PLAYER, "qty": pq, "max_price": int(pb["px"])})
		res = fill(all, lot, reserve)
		var won: int = 0
		for f in res["fills"]:
			if str(f["buyer"]) == PLAYER:
				won = int(f["qty"])
		if won <= 0:
			break
		var px: int = int(res["price"])
		var afford: int = maxi(0, rc.cr) / px
		if won > afford:
			pq = afford
			continue
		var snap: Dictionary = rc.snapshot()
		snap["cr"] = rc.cr - won * px
		if bool(Chapter11.assess(snap, rc.haircut_bps())["insolvent"]):
			pq = 0
			continue
		break
	s.scratch.erase("bids")
	s.scratch.erase("distress")
	var price: int = int(res.get("price", 0))
	if int(res.get("sold", 0)) <= 0:
		return events
	var winners: Array = []
	for f in res["fills"]:
		if str(f["buyer"]) == PLAYER and pq <= 0:
			continue
		winners.append(f)
	events.append({"kind": "auction", "baron": id, "px": price, "qty": int(res["sold"]), "reserve": reserve, "forced": forced, "winners": winners})
	s.scratch["last_clear"] = {"round": round_num, "px": price, "qty": int(res["sold"]), "forced": 1 if forced else 0}
	for f in winners:
		if s.holder != "":
			break  # a winner already took the baron: the rest of the lot is off the table
		var buyer: String = str(f["buyer"])
		var n: int = int(f["qty"])
		if buyer != PLAYER:
			var fl: RivalFleet = w.rival(buyer)
			n = mini(n, maxi(0, fl.cr) / price)
			if n <= 0:
				continue
			fl.cr -= n * price
		events.append_array(_transfer(w, id, buyer, n, price, rc, false, forced))
	return events


## The player's sealed bid for baron `id`'s standing lot: up to `n` shares (the lot, and no
## more than the threshold needs) paying at most `max_price` a share. Replaces an earlier bid.
## Cash is not held; the clearing re-checks it. {ok, reason, n, max_price, cost, held, events}.
## Refused: HELD, NO_OFFER, BELOW_RESERVE, NO_CR (not even one share at the reserve),
## WOULD_BANKRUPT (the spend at the reserve would leave the corp insolvent).
static func bid(w: Barons, id: String, rc: RunController, n: int, max_price: int) -> Dictionary:
	var out: Dictionary = {"ok": false, "reason": "", "n": 0, "max_price": 0, "cost": 0, "held": 0, "events": []}
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
	var floor_px: int = maxi(1, int(o["px"]))
	if max_price < floor_px:
		out["reason"] = "BELOW_RESERVE"
		return out
	var qty: int = mini(n, int(o["qty"]))
	qty = mini(qty, maxi(1, threshold_for(w, PLAYER, rc) - shares_of(w, id, PLAYER)))
	var cheapest: int = mini(qty, maxi(0, rc.cr) / floor_px)
	if cheapest <= 0:
		out["reason"] = "NO_CR"
		return out
	var snap: Dictionary = rc.snapshot()
	snap["cr"] = rc.cr - cheapest * floor_px  # the least the bid can cost
	if bool(Chapter11.assess(snap, rc.haircut_bps())["insolvent"]):
		out["reason"] = "WOULD_BANKRUPT"
		return out
	var bids = s.scratch.get("bids", {})
	if not (bids is Dictionary):
		bids = {}
	bids[PLAYER] = {"qty": qty, "px": max_price}
	s.scratch["bids"] = bids
	out["ok"] = true
	out["n"] = qty
	out["max_price"] = max_price
	out["held"] = shares_of(w, id, PLAYER)
	return out


## The read model the HUD draws for baron `id`: {stakes: [{bidder, shares, stake_bps, value}]
## (every holder, sorted by bidder id, plus the player), last_clear: {round, px, qty, forced} or
## {}, your_value, your_bid: {qty, px} or {}, lot: the standing offer or {}}.
static func auction_info(w: Barons, id: String, rc: RunController = null) -> Dictionary:
	var s: BaronState = _s(w, id)
	if s == null:
		return {}
	var holders: Array = s.shares.keys()
	if not holders.has(PLAYER):
		holders.append(PLAYER)
	holders.sort()
	var stakes: Array = []
	for h in holders:
		stakes.append({"bidder": str(h), "shares": shares_of(w, id, str(h)), "stake_bps": stake_bps(w, id, str(h), rc), "value": value_per_share(w, id, str(h), rc)})
	var lc = s.scratch.get("last_clear", null)
	var last: Dictionary = {}
	if lc is Dictionary:
		last = {"round": int(lc.get("round", 0)), "px": int(lc.get("px", 0)), "qty": int(lc.get("qty", 0)), "forced": int(lc.get("forced", 0)) == 1}
	return {"stakes": stakes, "last_clear": last, "your_value": value_per_share(w, id, PLAYER, rc), "your_bid": player_bid(w, id), "lot": offer(w, id)}


## Recapture: the player tenders `offer_px` a share to fleet `fleet_id` for up to `n` of the
## shares it holds in baron `id` (not gated on the Hostile Buyout Line). The fleet sells when
## `offer_px` is at least its own valuation (value_per_share for its stake before the sale,
## control premium included), so the price is `ask` and recapture is possible but dear. The
## cash goes to the fleet. Takes no more than the threshold needs. A fleet left under its own
## threshold loses control of the baron; the player reaching theirs takes it.
## {ok, reason, n, cost, held, ask, events}. Refused: NO_FLEET, NO_SHARES, REJECTED (offer under
## `ask`), NO_CR, WOULD_BANKRUPT.
static func recapture(w: Barons, id: String, rc: RunController, fleet_id: String, n: int, offer_px: int) -> Dictionary:
	var out: Dictionary = {"ok": false, "reason": "", "n": 0, "cost": 0, "held": 0, "ask": 0, "events": []}
	var s: BaronState = _s(w, id)
	var f: RivalFleet = w.rival(fleet_id)
	if s == null or f == null or f.gone or fleet_id == PLAYER:
		out["reason"] = "NO_FLEET"
		return out
	var owned: int = shares_of(w, id, fleet_id)
	if owned <= 0 or n <= 0:
		out["reason"] = "NO_SHARES"
		return out
	var ask: int = value_per_share(w, id, fleet_id, rc)
	out["ask"] = ask
	if offer_px < ask:
		out["reason"] = "REJECTED"
		return out
	var take_n: int = mini(n, owned)
	take_n = mini(take_n, maxi(1, threshold_for(w, PLAYER, rc) - shares_of(w, id, PLAYER)))
	take_n = mini(take_n, maxi(0, rc.cr) / maxi(1, offer_px))
	if take_n <= 0:
		out["reason"] = "NO_CR"
		return out
	var snap: Dictionary = rc.snapshot()
	snap["cr"] = rc.cr - take_n * offer_px
	if bool(Chapter11.assess(snap, rc.haircut_bps())["insolvent"]):
		out["reason"] = "WOULD_BANKRUPT"
		return out
	rc.cr -= take_n * offer_px
	f.cr += take_n * offer_px
	s.shares[fleet_id] = owned - take_n
	if int(s.shares[fleet_id]) <= 0:
		s.shares.erase(fleet_id)
	s.shares[PLAYER] = shares_of(w, id, PLAYER) + take_n
	# Shares bought back from a fleet came from the float, not the treasury (like a tender).
	s.scratch["tendered"] = int(s.scratch.get("tendered", 0)) + take_n
	var held: int = shares_of(w, id, PLAYER)
	var need: int = threshold_for(w, PLAYER, rc)
	var events: Array = [{"kind": "shares", "baron": id, "buyer": PLAYER, "qty": take_n, "px": offer_px, "held": held, "threshold": need, "tender": false, "recapture": true, "seller": fleet_id}]
	if held >= need:
		events.append(take(w, id, PLAYER, rc))
	elif s.holder == fleet_id and shares_of(w, id, fleet_id) < threshold_for(w, fleet_id, rc):
		s.holder = ""  # the fleet sold itself under control
		events.append({"kind": "control_lost", "baron": id, "fleet": fleet_id})
	out["ok"] = true
	out["n"] = take_n
	out["cost"] = take_n * offer_px
	out["held"] = shares_of(w, id, PLAYER)
	out["events"] = events
	return out


# --- Buying ---

## The shares action: bids for up to `n` shares of the standing lot at the player's own value
## per share (value_per_share, premium included), the most the shares are worth to them. Pays
## only the uniform clearing price. {ok, reason, n, max_price, cost: 0, held, events: []}; see bid().
static func buy(w: Barons, id: String, rc: RunController, n: int) -> Dictionary:
	return bid(w, id, rc, n, value_per_share(w, id, PLAYER, rc))


## The player tenders for up to `n` shares of the public float at the tender price
## (Hostile Buyout Line only). {ok, reason, n, cost, held, events}. Refused: LOCKED (no
## perk), HELD, NO_OFFER (the float or this round's cap is spent), NO_CR,
## WOULD_BANKRUPT (the spend would leave the corp insolvent).
static func tender(w: Barons, id: String, rc: RunController, n: int) -> Dictionary:
	var out: Dictionary = {"ok": false, "reason": "", "n": 0, "cost": 0, "held": 0, "events": []}
	var s: BaronState = _s(w, id)
	if s == null:
		out["reason"] = "NO_OFFER"
		return out
	if s.holder != "":
		out["reason"] = "HELD"
		return out
	if not tender_unlocked(rc):
		out["reason"] = "LOCKED"
		return out
	var o: Dictionary = tender_offer(w, id, rc)
	if o.is_empty() or n <= 0:
		out["reason"] = "NO_OFFER"
		return out
	var px: int = int(o["px"])
	var take_n: int = mini(n, int(o["qty"]))
	take_n = mini(take_n, maxi(1, threshold_for(w, PLAYER, rc) - shares_of(w, id, PLAYER)))
	take_n = mini(take_n, maxi(0, rc.cr) / px)
	if take_n <= 0:
		out["reason"] = "NO_CR"
		return out
	var snap: Dictionary = rc.snapshot()
	snap["cr"] = rc.cr - take_n * px
	if bool(Chapter11.assess(snap, rc.haircut_bps())["insolvent"]):
		out["reason"] = "WOULD_BANKRUPT"
		return out
	out["events"] = _transfer(w, id, PLAYER, take_n, px, rc, true)
	out["ok"] = true
	out["n"] = take_n
	out["cost"] = take_n * px
	out["held"] = shares_of(w, id, PLAYER)
	return out


## Moves `n` treasury shares to `buyer` at `px`, treasury takes the cash, and takes
## the baron when the buyer reaches the threshold. The player's cash is debited here;
## any other buyer is a stand-in with no ledger of its own. Returns the events.
static func _transfer(w: Barons, id: String, buyer: String, n: int, px: int, rc: RunController, tender: bool = false, forced: bool = false) -> Array:
	var events: Array = []
	var s: BaronState = _s(w, id)
	if buyer == PLAYER and rc != null:
		rc.cr -= n * px
	if tender:
		# A tender buys from the public float: the cash goes to the sellers, not the treasury.
		var t = s.scratch.get("tender", null)
		var rd: int = rc.get_current_round() if rc != null else 0
		var used: int = int(t.get("n", 0)) if t is Dictionary and int(t.get("round", -1)) == rd else 0
		s.scratch["tender"] = {"round": rd, "n": used + n}
		s.scratch["tendered"] = int(s.scratch.get("tendered", 0)) + n
	elif forced:
		# A liquidated fleet's shares: the sale pays no one the baron answers to.
		var left_f: int = int(s.scratch.get("forced", 0)) - n
		if left_f > 0:
			s.scratch["forced"] = left_f
		else:
			s.scratch.erase("forced")
	else:
		s.treasury_cr += n * px
		s.treasury_shares -= n
		var d = s.scratch.get("distress", null)
		if d is Dictionary:
			var left: int = int(d.get("qty", 0)) - n
			if left > 0:
				d["qty"] = left
			else:
				s.scratch.erase("distress")
	s.shares[buyer] = int(s.shares.get(buyer, 0)) + n
	var held: int = int(s.shares[buyer])
	var need: int = threshold_for(w, buyer, rc)
	events.append({"kind": "shares", "baron": id, "buyer": buyer, "qty": n, "px": px, "held": held, "threshold": need, "tender": tender})
	if held >= need:
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
		# A rival fleet takes the baron: the baron nets its own books against the debt.
		s.treasury_cr = maxi(0, s.treasury_cr - debt)
		ev["debt"] = debt
	s.holder = buyer
	s.debt_cr = 0
	s.strain = 0
	s.treasury_shares = 0
	s.scratch.erase("claims")
	s.scratch.erase("distress")
	s.scratch.erase("forced")
	s.scratch.erase("bids")
	s.scratch.erase("tender")
	s.scratch.erase("tendered")
	Levers.cancel_baron(w, id)  # a line the taker extended is its own now: cancelled, like its claim
	_cancel_archetype(w, id)
	return ev


# --- Bankruptcy ---

## Settlement (design doc 5.3). Returns the event.
static func settle(w: Barons, id: String, rc: RunController) -> Dictionary:
	var s: BaronState = _s(w, id)
	var cfg: Dictionary = settings(w)
	Levers.accelerate(w, id)  # an open credit line is called in: its amount due is a claim
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
	s.scratch.erase("forced")
	s.scratch.erase("bids")
	s.scratch.erase("tender")
	s.scratch.erase("tendered")
	s.scratch.erase("corner")
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


# --- Debt (the door the levers use, Epic 3 task 8) ---

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
			s.scratch.erase("forced")
			s.scratch.erase("bids")
			s.scratch.erase("tender")
			s.scratch.erase("tendered")
			events.append({"kind": "forfeit", "baron": id})
		elif s.holder == "" and (int(s.shares.get(PLAYER, 0)) > 0 or int(claims(w, id).get(PLAYER, 0)) > 0):
			# Shares tendered for came from the public float, not the treasury.
			s.treasury_shares += maxi(0, int(s.shares.get(PLAYER, 0)) - int(s.scratch.get("tendered", 0)))
			s.shares.erase(PLAYER)
			s.scratch.erase("tendered")
			s.scratch.erase("tender")
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
