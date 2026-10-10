class_name Barons
extends RefCounted
## The sector barons: the world object Epic 3 hangs rivals on (docs/design/epic3-barons.md 3.1).
##
## This task (Epic 3 task 1, part of #15 Baron Framework design) is data, load,
## validate and save only. It holds the parsed res://data/barons.json and one
## BaronState per baron, and does nothing to any market yet.
##
## Like the crisis deck, the world is attached to a RunController (`world`) and
## saved under RunSave key `world` only when attached, so a run with no
## barons.json loaded hashes exactly as before. The data file is content and is
## not saved: a save carries the states, and from_dict() re-reads the file.

const DEFAULT_PATH: String = "res://data/barons.json"
const VERSION: int = 1
const ARCHETYPES: Array[String] = ["short_squeezer", "hoarder", "auctioneer"]
const LEAK_MODES: Array[String] = ["full", "delayed"]
## Required `params` keys per archetype and the kind each must be.
const PARAM_KINDS: Dictionary = {
	"short_squeezer": {
		"squeeze_window_rounds": "int", "squeeze_price_bps_max": "int", "squeeze_depth_bps": "int",
		"contract_every_rounds": "int", "contract_qty": "range", "contract_bid_bps": "int",
		"contract_penalty_bps": "int",
		"contract_deadline_rounds": "int",
	},
	"hoarder": {
		"float_commodities": "commodities", "hoard_trigger_depth_bps": "int", "hoard_cap_qty": "int",
		"release_after_rounds": "int", "corner_premium_bps": "int",
		"corner_inventory_qty": "qtymap", "corner_ask_depth_bps": "int", "release_ask_depth_bps": "int",
		"release_discount_bps": "int", "release_rounds": "int", "release_sell_qty": "int",
		"cooldown_rounds": "int", "food_decay_bps": "int",
	},
	"auctioneer": {
		"auction_every_rounds": "int", "rig_bps_max": "int", "indicative_leak": "leak",
	},
}

var data: Dictionary = {}
## BaronState by baron id.
var states: Dictionary = {}


func _init(p_data: Dictionary = {}) -> void:
	data = p_data if not p_data.is_empty() else Barons.load_data()
	for def in data.get("barons", []):
		var s: BaronState = BaronState.from_def(def)
		states[s.id] = s


## Parses the barons JSON; {} when missing or malformed.
static func load_data(path: String = DEFAULT_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("Barons: file not found: %s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("Barons: not a JSON object: %s" % path)
		return {}
	return parsed


## A world for a new run: the shipped barons.json, or null when it is missing or
## invalid (the run then plays as it always did, with no world attached).
static func for_new_run() -> Barons:
	if not Barons.validate(Barons.load_data()).is_empty():
		return null
	return Barons.new()


## Book mods the world emits this round (StationMarket.set_world_mods), in the
## fold order the market relies on: barons by sorted id, then rival fleets by
## sorted id. Today a baron emits its supply pipelines (Epic 3 task 3); archetype
## behaviours (tasks 4-6) and rivals (task 10) add to this.
func market_mods() -> Array:
	var out: Array = []
	for id in ids():
		out.append_array(_mods_of(id))
	return out


## One baron's mods, in its pipelines' file order. A pipeline is two ask-side
## effects on the anchor station's book for that commodity (design doc 3.3):
## `ask_depth_bps` more depth for everyone, and `ask_price_bps` of premium that
## only outsiders pay. The mods are the PLAYER's view of the book: the player is
## an insider only while they hold the baron, so taking it removes the premium
## and keeps the depth. (Rival fleets share the same books; their own insider
## prices arrive with Epic 3 task 10.)
func _mods_of(id: String) -> Array:
	var out: Array = []
	var d: Dictionary = def(id)
	if d.is_empty():
		return out
	var insider: bool = is_insider(StationMarket.PLAYER_ID, id)
	for pipe in d.get("privileges", {}).get("pipelines", []):
		out.append({
			"station": str(d.get("anchor", "")),
			"commodity": str(pipe.get("commodity", "")),
			"ask_depth_bps": int(pipe.get("depth_bps", 10000)),
			"ask_price_bps": 0 if insider else int(pipe.get("outsider_ask_bps", 0)),
		})
	if str(d.get("archetype", "")) == "short_squeezer":
		out.append_array(AresHeavy.squeeze_mods(self, id))
	elif str(d.get("archetype", "")) == "hoarder":
		out.append_array(TitanCryoHydro.mods(self, id))
	# The player's levers (task 8) come after the baron's own mods, so a book no lever
	# touches folds exactly as before.
	out.append_array(Levers.mods(self, id))
	return out


# --- Archetypes (Epic 3 task 4, design doc 4.1): Ares Heavy ---

## The once-per-round world step (design doc 2.2), run by M0Loop after the crisis
## deck and before the books are reseeded: barons by sorted id. Decides everything
## from (run_seed, round, world state, player state) and writes the result into
## BaronState.scratch, so market_mods() stays a pure function of saved state and a
## restored run re-emits exactly the mods the original did. Returns the events the
## UI turns into GalNet lines: dictionaries with a `kind`, a `baron` and the data.
## `market` (optional) lets Titan Cryo-Hydro read the anchor's ask depth for its
## hoard trigger; without it the trigger cannot fire.
func advance_round(round_num: int, rc: RunController, market: StationMarket = null) -> Array:
	var events: Array = []
	for id in ids():
		match str(def(id).get("archetype", "")):
			"short_squeezer":
				events.append_array(AresHeavy.advance(self, id, round_num, rc))
			"hoarder":
				events.append_array(TitanCryoHydro.advance(self, id, round_num, rc, market))
			"auctioneer":
				events.append_array(SolCentral.advance(self, id, round_num, rc, market))
	# The player's levers (task 8): corner cover, margin calls, credit maturities, and the
	# sell pressure's halving. Before the takeover core so a baron a lever just broke is
	# assessed, and offered for sale, the same boundary.
	for id in ids():
		events.append_array(Levers.advance(self, id, round_num, rc))
	# Takeover core (task 7): insolvency, the distress auction, bankruptcy and the
	# rent a held baron pays. After the archetypes, barons by sorted id; a baron
	# that is solvent and not held writes nothing.
	for id in ids():
		events.append_array(Takeover.advance(self, id, round_num, rc))
	return events


# --- The levers (Epic 3 task 8, design doc 5.2): see Levers ---

## A sale the player made (the trade StationMarket.execute filled): adds sell pressure
## at a baron's anchor. Returns the pressure standing on that commodity.
func record_trade(station: String, commodity: String, side: String, qty: int) -> int:
	return Levers.record_trade(self, station, commodity, side, qty)


## The player extends the standard credit line to the baron anchoring `station`.
func open_credit(rc: RunController, station: String) -> Dictionary:
	return Levers.open_credit(self, station, rc)


## The open credit line at `station` as {baron, principal, due, due_round, rate_bps}, {} when none.
func credit_at(station: String) -> Dictionary:
	var id: String = baron_at(station)
	if id == "":
		return {}
	var c: Dictionary = Levers.credit(self, id)
	if not c.is_empty():
		c["baron"] = id
	return c


## The corner standing on (station, commodity) as {baron, rounds, price_bps}, {} when none.
func corner_on(station: String, commodity: String) -> Dictionary:
	var id: String = baron_at(station)
	if id == "":
		return {}
	var rounds: int = int(Levers.corners(self, id).get(commodity.to_upper(), 0))
	if rounds <= 0:
		return {}
	return {"baron": id, "rounds": rounds, "price_bps": int(Levers.settings(self)["corner"]["squeeze_bps"])}


## The player's tender offer at `station`'s baron: see Takeover.tender.
func tender_shares(rc: RunController, station: String, n: int) -> Dictionary:
	var id: String = baron_at(station)
	if id == "":
		return {"ok": false, "reason": "NO_OFFER", "n": 0, "cost": 0, "held": 0, "events": []}
	return Takeover.tender(self, id, rc, n)


# --- Takeover and insolvency (Epic 3 task 7, design doc 5): see Takeover ---

## Chapter11.assess on a baron's balance sheet.
func assess_baron(id: String) -> Dictionary:
	return Takeover.assess(self, id)


## The distress offer standing at `station` as {baron, px, qty, round}, {} when the
## anchoring baron is not selling shares.
func distress_at(station: String) -> Dictionary:
	var id: String = baron_at(station)
	if id == "":
		return {}
	var o: Dictionary = Takeover.offer(self, id)
	if not o.is_empty():
		o["baron"] = id
	return o


## The player buys up to `n` shares of the distress offer at `station`'s baron.
## {ok, reason, n, cost, held, events}; see Takeover.buy for the refusals.
func buy_shares(rc: RunController, station: String, n: int) -> Dictionary:
	var id: String = baron_at(station)
	if id == "":
		return {"ok": false, "reason": "NO_OFFER", "n": 0, "cost": 0, "held": 0, "events": []}
	return Takeover.buy(self, id, rc, n)


## Seam for rival fleets (Epic 3 task 10): the bids {buyer, qty} for a distress lot,
## in sorted buyer id order. No rival exists yet, so there are none.
func rival_bids(_id: String, _round_num: int, _px: int, _qty: int) -> Array:
	return []


## Sells `n` treasury shares of the standing offer to a buyer other than the player
## (the stand-in a rival fleet will use). Capped at the lot; events as buy().
func sell_auction_shares(id: String, buyer: String, n: int, rc: RunController = null) -> Array:
	var o: Dictionary = Takeover.offer(self, id)
	if o.is_empty() or n <= 0 or buyer == "" or buyer == Takeover.PLAYER:
		return []
	return Takeover._transfer(self, id, buyer, mini(n, int(o["qty"])), int(o["px"]), rc)


## Adds debt to a baron, attributed to `creditor` ("" = the system). The door the
## levers (task 8) will use; nothing in play raises a baron's debt before them.
func add_debt(id: String, amount: int, creditor: String = "") -> void:
	Takeover.add_debt(self, id, amount, creditor)


## Ids of the barons `holder` holds, sorted.
func held_by(holder: String) -> Array:
	var out: Array = []
	for id in ids():
		if (states[id] as BaronState).holder == holder:
			out.append(id)
	return out


## Rent a baron pays its holder each round.
func rent_of(id: String) -> int:
	return Takeover.rent(self, id)


## A Chapter 11 filing: the failed corp's holdings revert (see Takeover.forfeit).
func forfeit_holdings() -> Array:
	return Takeover.forfeit(self)


# --- Sol Central (Epic 3 task 6, design doc 4.3): the call auction ---

## The auction open at `station` during `round_num` as {baron, station, commodity,
## round, close_round, ref_price}, {} when none (no auctioneer there, not an auction
## round, or the baron is held). A pure function of (run_seed, round).
func auction_at(station: String, round_num: int, run_seed: int) -> Dictionary:
	for id in ids():
		if str(def(id).get("archetype", "")) == "auctioneer" and str(def(id).get("anchor", "")) == station.to_lower():
			return SolCentral.open_auction(self, id, round_num, run_seed)
	return {}


## Queues a limit order into the open auction at `station`. {ok, reason, ...}.
func submit_auction_order(rc: RunController, station: String, side: String, qty: int, limit: int) -> Dictionary:
	var au: Dictionary = auction_at(station, rc.get_current_round(), rc.run_seed)
	if au.is_empty():
		return {"ok": false, "reason": "NO_AUCTION"}
	return SolCentral.submit(self, str(au["baron"]), rc, side, qty, limit)


## The orders queued for the auction open at `station`, sorted by (limit, seq).
func auction_orders(station: String, round_num: int, run_seed: int) -> Array:
	var au: Dictionary = auction_at(station, round_num, run_seed)
	if au.is_empty():
		return []
	return SolCentral.buffer(self, str(au["baron"]))


## The indicative-price row for the auction open at `station` ({} when none).
func indicative_at(station: String, round_num: int, run_seed: int, market: StationMarket) -> Dictionary:
	var au: Dictionary = auction_at(station, round_num, run_seed)
	if au.is_empty():
		return {}
	return SolCentral.indicative(self, str(au["baron"]), round_num, run_seed, market)


## Takes back every queued order at `station`; how many were withdrawn.
func withdraw_auction_orders(station: String) -> int:
	var id: String = baron_at(station)
	if id == "" or str(def(id).get("archetype", "")) != "auctioneer":
		return 0
	return SolCentral.withdraw(self, id)


## Drops every queued auction order (the ship left, or the corp failed).
func cancel_auctions() -> void:
	for id in ids():
		if str(def(id).get("archetype", "")) == "auctioneer":
			SolCentral.cancel(self, id)


## The hoard on a (station, commodity) book as {baron, phase, price_bps, age},
## {} when the book is not being hoarded (or no hoarder anchors the station).
func hoard_on(station: String, commodity: String) -> Dictionary:
	for id in ids():
		if str(def(id).get("archetype", "")) != "hoarder" or str(def(id).get("anchor", "")) != station.to_lower():
			continue
		var st: BaronState = state(id)
		if st == null or st.holder != "":
			continue
		var h: Dictionary = TitanCryoHydro.state_of(self, id, commodity.to_upper())
		if not h.is_empty():
			h["baron"] = id
			return h
	return {}


## Whether a defense contract offer waits for the player's answer.
func has_pending_offer() -> bool:
	return not pending_offer().is_empty()


## The contract offer awaiting an answer ({} when none), with its `baron` id.
func pending_offer() -> Dictionary:
	for id in ids():
		if str(def(id).get("archetype", "")) == "short_squeezer":
			var c: Dictionary = AresHeavy.contract(self, id)
			if str(c.get("state", "")) == "offered":
				var out: Dictionary = c.duplicate()
				out["baron"] = id
				return out
	return {}


## The contract the player accepted and has not yet settled ({} when none).
func open_contract() -> Dictionary:
	for id in ids():
		if str(def(id).get("archetype", "")) == "short_squeezer":
			var c: Dictionary = AresHeavy.contract(self, id)
			if str(c.get("state", "")) == "accepted":
				var out: Dictionary = c.duplicate()
				out["baron"] = id
				return out
	return {}


## The squeeze currently on a book as {baron, commodity, price_bps, depth_bps,
## rounds_short}, {} when the book is not squeezed.
func squeeze_on(station: String, commodity: String) -> Dictionary:
	for id in ids():
		if str(def(id).get("archetype", "")) != "short_squeezer" or str(def(id).get("anchor", "")) != station.to_lower():
			continue
		var q: Dictionary = AresHeavy.squeeze(self, id)
		if not q.is_empty() and str(q["commodity"]) == commodity.to_upper():
			var out: Dictionary = q.duplicate()
			out["baron"] = id
			return out
	return {}


func accept_offer(rc: RunController) -> Dictionary:
	var o: Dictionary = pending_offer()
	return AresHeavy.accept(self, str(o["baron"]), rc) if not o.is_empty() else {}


func decline_offer() -> bool:
	var o: Dictionary = pending_offer()
	return not o.is_empty() and AresHeavy.decline(self, str(o["baron"]))


## Settles an accepted contract if the ship is docked at the anchor holding the
## full quantity. Returns the delivered event, {} when nothing was settled.
func try_deliver(rc: RunController) -> Dictionary:
	var c: Dictionary = open_contract()
	return AresHeavy.deliver(self, str(c["baron"]), rc) if not c.is_empty() else {}


## The failed corp's obligations end with it (a Chapter 11 filing founds a new
## corp): open and offered contracts and any squeeze are dropped.
func cancel_contracts() -> void:
	for id in ids():
		if str(def(id).get("archetype", "")) == "short_squeezer":
			AresHeavy.cancel(self, id)


## Share of net worth a RANDOM baron event may cost at most, in bps.
func random_max_loss_bps() -> int:
	return clampi(int(data.get("consequence", {}).get("random_max_loss_bps", 0)), 0, 10000)


## Adds a baron fine to the player's principal debt, under the lethal guard
## (design doc 7, decision 4). `origin` is "consequence" (the player's own choices
## exposed them: an accepted contract that was missed) or "random".
##  - consequence: charged in full. It may tip the corp into Chapter 11, never
##    touches doomsday ticks, and reports `forced_ch11` when it did.
##  - random: clamped so net worth stays at or above its pre-event value minus
##    `random_max_loss_bps`, and so the corp stays solvent. A random event never
##    forces Chapter 11 alone.
## Returns {origin, requested, applied, clamped, forced_ch11}.
func penalize(rc: RunController, amount: int, origin: String) -> Dictionary:
	var want: int = maxi(0, amount)
	var pre: Dictionary = rc.assess()
	var applied: int = want
	if origin != "consequence":
		var nw: int = int(pre["liquidation_value"]) - int(pre["total_debt"])
		applied = mini(want, maxi(0, nw) * random_max_loss_bps() / 10000)
	applied = rc.doomsday.add_principal(applied)
	var post: Dictionary = rc.assess()
	return {
		"origin": origin if origin == "consequence" else "random",
		"requested": want,
		"applied": applied,
		"clamped": applied < want,
		"forced_ch11": not bool(pre["insolvent"]) and bool(post["insolvent"]),
	}


# --- Privileges (Epic 3 task 3, design doc 3.3) ---

## Participant ids a baron treats as insiders: its `toll_exempt` list plus
## whoever holds it ("player" after a takeover, a rival id later).
func insiders(id: String) -> Array:
	var out: Array = []
	for e in def(id).get("privileges", {}).get("toll_exempt", []):
		out.append(str(e))
	var s: BaronState = state(id)
	if s != null and s.holder != "" and not out.has(s.holder):
		out.append(s.holder)
	return out


func is_insider(participant: String, id: String) -> bool:
	return insiders(id).has(participant)


## The docking toll `participant` owes on arriving at `station`: the anchoring
## baron's `docking_toll_cr`, 0 for an insider or an unanchored station.
func docking_toll_due(participant: String, station: String) -> int:
	var id: String = baron_at(station)
	if id == "" or is_insider(participant, id):
		return 0
	return maxi(0, int(def(id).get("privileges", {}).get("docking_toll_cr", 0)))


## What is actually charged: the toll, capped at the CR the participant holds
## (agora/referee.py:2147 caps the same way).
func docking_toll(participant: String, station: String, cr_held: int) -> int:
	return mini(docking_toll_due(participant, station), maxi(0, cr_held))


## The pipeline on a (station, commodity) book as {baron, depth_bps,
## outsider_ask_bps}, {} when none. `viewer` sees base ask prices if an insider.
func pipeline(station: String, commodity: String) -> Dictionary:
	var id: String = baron_at(station)
	if id == "":
		return {}
	for pipe in def(id).get("privileges", {}).get("pipelines", []):
		if str(pipe.get("commodity", "")) == commodity.to_upper():
			return {"baron": id, "depth_bps": int(pipe.get("depth_bps", 0)), "outsider_ask_bps": int(pipe.get("outsider_ask_bps", 0))}
	return {}


## Baron ids in sorted order: the only order anything may iterate them in.
func ids() -> Array:
	var out: Array = states.keys()
	out.sort()
	return out


func state(id: String) -> BaronState:
	return states.get(id, null)


## The barons.json entry for an id, {} if unknown.
func def(id: String) -> Dictionary:
	for d in data.get("barons", []):
		if str(d.get("id", "")) == id:
			return d
	return {}


## The baron id anchored at a station, "" when none is.
func baron_at(station: String) -> String:
	for d in data.get("barons", []):
		if str(d.get("anchor", "")) == station.to_lower():
			return str(d.get("id", ""))
	return ""


func float_shares() -> int:
	return int(data.get("takeover", {}).get("float_shares", 0))


func threshold_shares() -> int:
	return int(data.get("takeover", {}).get("threshold_shares", 0))


# --- Save / load ---

func to_dict() -> Dictionary:
	var out: Dictionary = {}
	for id in ids():
		out[id] = (states[id] as BaronState).to_dict()
	return {"version": VERSION, "barons": out}


## Rebuilds the world from to_dict() output (directly or via JSON). The data
## file is re-read; a saved baron the file no longer lists is dropped, and a
## listed baron the save lacks starts from its opening state.
static func from_dict(d: Dictionary, p_data: Dictionary = {}) -> Barons:
	var w := Barons.new(p_data)
	var saved = d.get("barons", {})
	if saved is Dictionary:
		for id in w.states.keys():
			if saved.has(id) and saved[id] is Dictionary:
				var s: BaronState = BaronState.from_dict(saved[id])
				s.id = str(id)
				w.states[id] = s
	return w


# --- Validation ---

## Every problem with a parsed barons.json, as readable lines; empty = valid.
## Pure: it reads the dictionary and Transit's tables only.
static func validate(d: Dictionary) -> Array:
	var errs: Array = []
	if d.is_empty():
		return ["empty or unreadable barons data"]
	if not _is_int(d.get("version", null)) or int(d["version"]) != VERSION:
		errs.append("version must be %d" % VERSION)
	var barons = d.get("barons", null)
	if not (barons is Array) or (barons as Array).is_empty():
		errs.append("barons must be a non-empty array")
		return errs
	var take = d.get("takeover", null)
	var float_shares: int = 0
	if not (take is Dictionary):
		errs.append("takeover must be an object")
	else:
		for k in ["float_shares", "threshold_shares", "auction_cap", "auction_discount_bps", "bankrupt_rounds"]:
			if not _is_int(take.get(k, null)) or int(take[k]) <= 0:
				errs.append("takeover.%s must be a positive whole number" % k)
		if _is_int(take.get("float_shares", null)):
			float_shares = int(take.get("float_shares", 0))
		if _is_int(take.get("threshold_shares", null)) and float_shares > 0:
			var t: int = int(take["threshold_shares"])
			if t * 2 <= float_shares or t > float_shares:
				errs.append("takeover.threshold_shares must be a strict majority of float_shares")
		if _is_int(take.get("auction_discount_bps", null)) and int(take["auction_discount_bps"]) > 10000:
			errs.append("takeover.auction_discount_bps must be at most 10000")
		for k in ["auction_price_floor", "rent_units", "rent_spread_bps"]:
			if take.has(k) and (not _is_int(take[k]) or int(take[k]) < 0):
				errs.append("takeover.%s must be a whole number >= 0" % k)
		if take.has("reset_treasury_bps") and (not _is_int(take["reset_treasury_bps"]) or int(take["reset_treasury_bps"]) < 0 or int(take["reset_treasury_bps"]) > 10000):
			errs.append("takeover.reset_treasury_bps must be 0..10000")
	errs.append_array(_check_levers(d.get("levers", null)))
	var heat = d.get("heat", null)
	if not (heat is Dictionary):
		errs.append("heat must be an object")
	else:
		if not _is_int(heat.get("decay_per_round", null)) or int(heat["decay_per_round"]) < 0:
			errs.append("heat.decay_per_round must be a whole number >= 0")
		if not _is_int(heat.get("retaliation_at", null)) or int(heat["retaliation_at"]) <= 0:
			errs.append("heat.retaliation_at must be a positive whole number")
	var cons = d.get("consequence", null)
	if not (cons is Dictionary):
		errs.append("consequence must be an object")
	elif not _is_int(cons.get("random_max_loss_bps", null)) or int(cons["random_max_loss_bps"]) < 0 or int(cons["random_max_loss_bps"]) > 10000:
		errs.append("consequence.random_max_loss_bps must be 0..10000")
	var vic = d.get("victory", null)
	if not (vic is Dictionary):
		errs.append("victory must be an object")
	else:
		var req = vic.get("barons_required", null)
		var ok: bool = (req is String and req == "all") or (_is_int(req) and int(req) >= 1 and int(req) <= (barons as Array).size())
		if not ok:
			errs.append("victory.barons_required must be \"all\" or 1..%d" % (barons as Array).size())
	var seen_ids: Dictionary = {}
	var seen_anchors: Dictionary = {}
	for i in (barons as Array).size():
		var b = barons[i]
		var where: String = "barons[%d]" % i
		if not (b is Dictionary):
			errs.append("%s must be an object" % where)
			continue
		var id: String = str(b.get("id", ""))
		if id.is_empty() or not _is_id(id):
			errs.append("%s.id must be lowercase letters, digits and underscores" % where)
		else:
			where = "baron %s" % id
			if seen_ids.has(id):
				errs.append("%s: duplicate id" % where)
			seen_ids[id] = true
		if str(b.get("name", "")).is_empty():
			errs.append("%s: name is required" % where)
		var arch: String = str(b.get("archetype", ""))
		if not ARCHETYPES.has(arch):
			errs.append("%s: archetype must be one of %s" % [where, ", ".join(ARCHETYPES)])
		var anchor: String = str(b.get("anchor", ""))
		if not Transit.STATIONS.has(anchor):
			errs.append("%s: anchor '%s' is not a station" % [where, anchor])
		elif seen_anchors.has(anchor):
			errs.append("%s: anchor '%s' is already taken by %s" % [where, anchor, seen_anchors[anchor]])
		else:
			seen_anchors[anchor] = id
		for k in ["treasury_cr", "treasury_shares", "upkeep_cr_per_round", "margin_debt_cr"]:
			if not _is_int(b.get(k, null)) or int(b[k]) < 0:
				errs.append("%s: %s must be a whole number >= 0" % [where, k])
		if _is_int(b.get("treasury_shares", null)) and float_shares > 0 and int(b["treasury_shares"]) > float_shares:
			errs.append("%s: treasury_shares exceeds the float" % where)
		_check_commodity_map(b.get("inventory", null), "%s: inventory" % where, errs)
		_check_privileges(b.get("privileges", null), where, errs)
		_check_params(b.get("params", null), arch, where, errs)
	return errs


## `levers` is optional (defaults apply); when present every key of a group is a whole
## number >= 0; the share-of-a-whole bps keys are at most 10000.
static func _check_levers(v: Variant) -> Array:
	var errs: Array = []
	if v == null:
		return errs
	if not (v is Dictionary):
		return ["levers must be an object"]
	for group in v:
		if not Levers.DEFAULTS.has(group):
			errs.append("levers.%s is not a lever group" % group)
			continue
		if not (v[group] is Dictionary):
			errs.append("levers.%s must be an object" % group)
			continue
		for k in v[group]:
			if not Levers.DEFAULTS[group].has(k):
				errs.append("levers.%s.%s is not a lever key" % [group, k])
			elif not _is_int(v[group][k]) or int(v[group][k]) < 0:
				errs.append("levers.%s.%s must be a whole number >= 0" % [group, k])
			elif k in ["spend_bps", "liquidate_bps", "pressure_max_bps", "accept_below_bps"] and int(v[group][k]) > 10000:
				errs.append("levers.%s.%s must be at most 10000" % [group, k])
	return errs


static func _check_commodity_map(v: Variant, label: String, errs: Array) -> void:
	if not (v is Dictionary):
		errs.append("%s must be an object" % label)
		return
	for k in v:
		if not Transit.COMMODITIES.has(str(k)):
			errs.append("%s: unknown commodity '%s'" % [label, str(k)])
		if not _is_int(v[k]) or int(v[k]) < 0:
			errs.append("%s.%s must be a whole number >= 0" % [label, str(k)])


static func _check_privileges(p: Variant, where: String, errs: Array) -> void:
	if not (p is Dictionary):
		errs.append("%s: privileges must be an object" % where)
		return
	if not _is_int(p.get("docking_toll_cr", null)) or int(p["docking_toll_cr"]) < 0:
		errs.append("%s: privileges.docking_toll_cr must be a whole number >= 0" % where)
	var ex = p.get("toll_exempt", null)
	if not (ex is Array):
		errs.append("%s: privileges.toll_exempt must be an array" % where)
	else:
		for e in ex:
			if not (e is String) or (e as String).is_empty():
				errs.append("%s: privileges.toll_exempt holds only participant ids" % where)
				break
	var pipes = p.get("pipelines", null)
	if not (pipes is Array):
		errs.append("%s: privileges.pipelines must be an array" % where)
		return
	var seen: Dictionary = {}
	for pipe in pipes:
		if not (pipe is Dictionary):
			errs.append("%s: each pipeline must be an object" % where)
			continue
		var c: String = str(pipe.get("commodity", ""))
		if not Transit.COMMODITIES.has(c):
			errs.append("%s: pipeline commodity '%s' is unknown" % [where, c])
		elif seen.has(c):
			errs.append("%s: pipeline for %s listed twice" % [where, c])
		seen[c] = true
		if not _is_int(pipe.get("depth_bps", null)) or int(pipe["depth_bps"]) <= 0:
			errs.append("%s: pipeline %s depth_bps must be a positive whole number" % [where, c])
		if not _is_int(pipe.get("outsider_ask_bps", null)) or int(pipe["outsider_ask_bps"]) < 0:
			errs.append("%s: pipeline %s outsider_ask_bps must be a whole number >= 0" % [where, c])


static func _check_params(p: Variant, arch: String, where: String, errs: Array) -> void:
	if not (p is Dictionary):
		errs.append("%s: params must be an object" % where)
		return
	var kinds: Dictionary = PARAM_KINDS.get(arch, {})
	for k in kinds:
		if not p.has(k):
			errs.append("%s: params.%s is required for %s" % [where, k, arch])
			continue
		var v = p[k]
		var ok: bool = true
		match str(kinds[k]):
			"int":
				ok = _is_int(v) and int(v) >= 0
			"range":
				ok = v is Array and (v as Array).size() == 2 and _is_int(v[0]) and _is_int(v[1]) and int(v[0]) >= 1 and int(v[0]) <= int(v[1])
			"commodities":
				ok = v is Array and not (v as Array).is_empty()
				if ok:
					for c in v:
						if not Transit.COMMODITIES.has(str(c)):
							ok = false
			"leak":
				ok = v is String and LEAK_MODES.has(v)
			"qtymap":
				ok = v is Dictionary and not (v as Dictionary).is_empty()
				if ok:
					for c in v:
						if not Transit.COMMODITIES.has(str(c)) or not _is_int(v[c]) or int(v[c]) < 0:
							ok = false
		if not ok:
			errs.append("%s: params.%s is invalid" % [where, k])


## JSON numbers arrive as floats: a whole-valued float counts as an int.
static func _is_int(v: Variant) -> bool:
	if typeof(v) == TYPE_INT:
		return true
	return typeof(v) == TYPE_FLOAT and is_finite(v) and v == floorf(v)


static func _is_id(s: String) -> bool:
	for i in s.length():
		var c: String = s[i]
		if not ((c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_"):
			return false
	return true
