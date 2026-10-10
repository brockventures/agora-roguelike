class_name CrisisDeck
extends RefCounted
## Procedural crisis event deck (#12, part of Epic 2 #8).
##
## Tiered by run depth and player net worth, entirely data-driven from
## res://data/crises.json (odds, bands, magnitudes, durations: all PLACEHOLDER
## numbers for the designer to tune).
##
##  - Tiers map onto DoomsdayClock stages: early (NORMAL), mid (UNSTABLE,
##    CRITICAL), endgame (IMMINENT). COLLAPSED draws nothing.
##  - Net worth is bucketed into bands. A band scales the tier's odds
##    (p_mult_bps) and gates / weights individual crises (min_band, max_band,
##    weights).
##  - advance_round() is the only entry point that draws, and it draws at most
##    once per round. The fire / no-fire roll goes through Bags (bad-luck
##    protection, the same engine Hazards and Piracy use); the follow-up pick
##    (which crisis, how long, which commodity) uses a DrawSource seeded from
##    (seed, round), so the deck keeps NO RNG state outside Bags and a saved
##    deck replays identically.
##  - Effects are derived from the active list (market_mods(), order_cap(),
##    fee_bps(), margin_call_bps()), never applied destructively, so expiry
##    reverts them by simply dropping the entry.
##  - A drawn crisis is "pending" until acknowledge(); RunController folds
##    has_pending_ack() into its single SimClock interrupt hook so the clock
##    stops on the same sub-tick.
##
## Everything stateful is integers and strings: to_dict()/from_dict() round-trip
## through JSON (Godot parses every JSON number as a float, so all reads int()).

signal crisis_drawn(crisis: Dictionary)
signal crisis_expired(crisis: Dictionary)
## The active list changed (a crisis started or expired).
signal changed()

const DEFAULT_PATH: String = "res://data/crises.json"
const EVENT: String = "crisis"
const TIER_ORDER: Array[String] = ["early", "mid", "endgame"]
const BAND_ORDER: Array[String] = ["low", "mid", "high"]

var seed_val: int = 0
var data: Dictionary = {}
var bags: Bags = null
## Active crisis instances (Dictionaries, see _instantiate).
var active: Array = []
## uids drawn but not yet acknowledged.
var awaiting_ack: Array = []
var last_round: int = -1
var draw_count: int = 0
## Margin-call bps owed for the round that just advanced (set by advance_round,
## from crises that were already active before this round's draw).
var last_margin_call_bps: int = 0
var _uid: int = 0


func _init(p_seed: int = 0, p_data: Dictionary = {}, p_bags: Bags = null) -> void:
	seed_val = p_seed
	data = p_data if not p_data.is_empty() else CrisisDeck.load_data()
	bags = p_bags if p_bags != null else Bags.new("crisis", null, p_seed)


## Parses the crisis JSON; {} when missing or malformed.
static func load_data(path: String = DEFAULT_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("CrisisDeck: file not found: %s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("CrisisDeck: not a JSON object: %s" % path)
		return {}
	return parsed


# --- Gating ---

## Tier id for a DoomsdayClock stage, "" when no tier covers it.
func tier_for_stage(stage: int) -> String:
	var tiers: Dictionary = data.get("tiers", {})
	for tier_id in TIER_ORDER:
		var t: Dictionary = tiers.get(tier_id, {})
		for s in t.get("stages", []):
			if DoomsdayClock.Stage.get(str(s), -1) == stage:
				return tier_id
	return ""


## Band id for a net worth: the highest band whose min_net_worth it reaches.
func band_for(net_worth: int) -> String:
	var best: String = "low"
	var best_min: int = -9223372036854775807
	for b in data.get("bands", []):
		var m: int = int(b.get("min_net_worth", 0))
		if net_worth >= m and m >= best_min:
			best = str(b.get("id", "low"))
			best_min = m
	return best


static func band_rank(band: String) -> int:
	return maxi(0, BAND_ORDER.find(band))


## Crisis definitions a (tier, band) may draw: right tier, band inside
## [min_band, max_band], and not already active.
func eligible(tier: String, band: String) -> Array:
	var out: Array = []
	var rank: int = band_rank(band)
	for def in data.get("crises", []):
		if str(def.get("tier", "")) != tier:
			continue
		if rank < band_rank(str(def.get("min_band", "low"))):
			continue
		if rank > band_rank(str(def.get("max_band", "high"))):
			continue
		if _is_active(str(def.get("id", ""))):
			continue
		out.append(def)
	return out


## Per-round fire probability for (tier, band).
func odds(tier: String, band: String) -> float:
	var t: Dictionary = data.get("tiers", {}).get(tier, {})
	var mult: int = int(t.get("p_mult_bps", {}).get(band, 10000))
	return clampf(float(t.get("p", 0.0)) * float(mult) / 10000.0, 0.0, 1.0)


# --- The draw ---

## Advances the deck to `round_num`: expires finished crises, then (at most once
## per round) rolls for a new one. Returns the crisis drawn, or {}.
func advance_round(round_num: int, stage: int, net_worth: int) -> Dictionary:
	last_margin_call_bps = 0
	if round_num <= last_round:
		return {}
	last_round = round_num
	var expired: Array = []
	for c in active.duplicate():
		if round_num >= int(c["expires_round"]):
			active.erase(c)
			awaiting_ack.erase(c["uid"])
			expired.append(c)
	last_margin_call_bps = margin_call_bps()
	for c in expired:
		crisis_expired.emit(c)
	var drawn: Dictionary = _roll(round_num, stage, net_worth)
	if not expired.is_empty() or not drawn.is_empty():
		changed.emit()
	if not drawn.is_empty():
		crisis_drawn.emit(drawn)
	return drawn


func _roll(round_num: int, stage: int, net_worth: int) -> Dictionary:
	if round_num <= int(data.get("grace_rounds", 0)):
		return {}
	if active.size() >= int(data.get("max_active", 1)):
		return {}
	var tier: String = tier_for_stage(stage)
	if tier.is_empty():
		return {}
	var band: String = band_for(net_worth)
	if not bags.draw(EVENT, "%s:%s" % [tier, band], odds(tier, band)):
		return {}
	var pool: Array = eligible(tier, band)
	if pool.is_empty():
		return {}
	var rng := NativeDrawSource.new(StableHash.hash32("crisis-pick-%d-%d" % [seed_val, round_num]))
	var total: float = 0.0
	for def in pool:
		total += _weight(def, band)
	var roll: float = rng.random() * total
	var chosen: Dictionary = pool[pool.size() - 1]
	for def in pool:
		roll -= _weight(def, band)
		if roll < 0.0:
			chosen = def
			break
	var inst: Dictionary = _instantiate(chosen, round_num, net_worth, band, rng)
	draw_count += 1
	active.append(inst)
	awaiting_ack.append(inst["uid"])
	return inst


func _weight(def: Dictionary, band: String) -> float:
	var w = def.get("weights", {})
	if w is Dictionary and w.has(band):
		return maxf(0.0, float(w[band]))
	return maxf(0.0, float(def.get("weight", 1)))


## Builds the live instance. All resolved numbers are ints/strings.
func _instantiate(def: Dictionary, round_num: int, net_worth: int, band: String, rng: DrawSource) -> Dictionary:
	_uid += 1
	var dur: Array = def.get("duration_rounds", [3, 3])
	var rounds: int = rng.randint(int(dur[0]), int(dur[maxi(0, dur.size() - 1)]))
	var fx: Dictionary = def.get("effects", {})
	var kind: String = str(def.get("kind", ""))
	var station: String = ""
	var commodity: String = ""
	var effects: Dictionary = {}
	match kind:
		"shortage":
			station = str(rng.choice(def.get("stations", ["mars"])))
			var coms: Array = def.get("commodities", [])
			if coms.is_empty():
				coms = Transit.COMMODITIES
			commodity = str(rng.choice(coms))
			effects = {"depth_bps": int(fx.get("depth_bps", 10000)), "price_bps": int(fx.get("price_bps", 0)), "spread_bps": int(fx.get("spread_bps", 10000))}
		"collapse":
			station = "*"
			commodity = "*"
			effects = {"depth_bps": int(fx.get("depth_bps", 10000)), "price_bps": int(fx.get("price_bps", 0)), "spread_bps": int(fx.get("spread_bps", 10000)), "margin_call_bps": int(fx.get("margin_call_bps", 0))}
		"audit":
			var scaled: int = int(fx.get("fee_base_bps", 0)) + (maxi(0, net_worth) / 10000) * int(fx.get("fee_bps_per_10k_net_worth", 0))
			effects = {"trade_cap_qty": int(fx.get("trade_cap_qty", 0)), "fee_bps": clampi(scaled, 0, int(fx.get("fee_max_bps", 10000)))}
	var text: String = str(def.get("headline", def.get("name", ""))).replace("{rounds}", str(rounds)).replace("{commodity}", commodity).replace("{station}", StationMarket.station_name(station))
	return {
		"uid": _uid,
		"id": str(def.get("id", "")),
		"kind": kind,
		"tier": str(def.get("tier", "")),
		"name": str(def.get("name", "")),
		"text": text,
		"band": band,
		"station": station,
		"commodity": commodity,
		"started_round": round_num,
		"expires_round": round_num + rounds,
		"rounds": rounds,
		"effects": effects,
	}


func _is_active(id: String) -> bool:
	for c in active:
		if str(c["id"]) == id:
			return true
	return false


# --- Interrupt ---

func has_pending_ack() -> bool:
	return not awaiting_ack.is_empty()


## The oldest unacknowledged crisis, {} if none.
func pending_crisis() -> Dictionary:
	for c in active:
		if awaiting_ack.has(c["uid"]):
			return c
	return {}


## Player acknowledged the modal. Returns how many crises it cleared.
func acknowledge() -> int:
	var n: int = awaiting_ack.size()
	awaiting_ack.clear()
	return n


# --- Derived effects ---

## Book modifiers for StationMarket.set_crisis_mods(): one entry per active
## crisis that touches the market. station / commodity may be "*".
func market_mods() -> Array:
	var out: Array = []
	for c in active:
		var fx: Dictionary = c["effects"]
		if fx.has("depth_bps") or fx.has("spread_bps") or fx.has("price_bps"):
			out.append({
				"station": str(c["station"]), "commodity": str(c["commodity"]),
				"depth_bps": int(fx.get("depth_bps", 10000)),
				"price_bps": int(fx.get("price_bps", 0)),
				"spread_bps": int(fx.get("spread_bps", 10000)),
			})
	return out


## Largest per-order unit cap among active audits, 0 = uncapped.
func order_cap() -> int:
	var cap: int = 0
	for c in active:
		var q: int = int(c["effects"].get("trade_cap_qty", 0))
		if q > 0 and (cap == 0 or q < cap):
			cap = q
	return cap


## Trade fee in bps (sum over active audits).
func fee_bps() -> int:
	var total: int = 0
	for c in active:
		total += int(c["effects"].get("fee_bps", 0))
	return total


## CR fee for a fill of `cost` CR, rounded up so a live audit never rounds to free.
func fee_for(cost: int) -> int:
	var bps: int = fee_bps()
	if bps <= 0 or cost <= 0:
		return 0
	return (cost * bps + 9999) / 10000


## Margin-call bps of cargo value drained per round by active collapses.
func margin_call_bps() -> int:
	var total: int = 0
	for c in active:
		total += int(c["effects"].get("margin_call_bps", 0))
	return total


## Short label of the active crises touching a book ("" if none), for the board.
func tag_for(station: String, commodity: String) -> String:
	var names: PackedStringArray = []
	for c in active:
		if not c["effects"].has("depth_bps"):
			continue
		var s: String = str(c["station"])
		var k: String = str(c["commodity"])
		if (s == "*" or s == station.to_lower()) and (k == "*" or k == commodity.to_upper()):
			names.append(str(c["name"]).to_upper())
	return ", ".join(names)


## Plain-English effect lines for the modal and sidebar.
static func describe(c: Dictionary, compact: bool = false) -> Array:
	var fx: Dictionary = c.get("effects", {})
	var lines: Array = []
	if fx.has("depth_bps"):
		var scope: String = "ALL BOOKS" if str(c.get("station", "")) == "*" else ("%s" % str(c.get("commodity", "")) if compact else "%s %s" % [StationMarket.station_name(str(c.get("station", ""))).to_upper(), str(c.get("commodity", ""))])
		lines.append("%s: depth x%.2f, spread x%.2f%s" % [scope, float(fx["depth_bps"]) / 10000.0, float(fx.get("spread_bps", 10000)) / 10000.0, (" px %+.0f%%" if compact else ", price %+.0f%%") % (float(fx.get("price_bps", 0)) / 100.0) if int(fx.get("price_bps", 0)) != 0 else ""])
	if int(fx.get("margin_call_bps", 0)) > 0:
		lines.append("Margin calls: %.2f%% of cargo value per round" % (float(fx["margin_call_bps"]) / 100.0))
	if int(fx.get("trade_cap_qty", 0)) > 0:
		lines.append("Orders capped at %d units" % int(fx["trade_cap_qty"]))
	if int(fx.get("fee_bps", 0)) > 0:
		lines.append("Trade fee %.2f%%" % (float(fx["fee_bps"]) / 100.0))
	return lines


# --- Serialization ---

func to_dict() -> Dictionary:
	return {
		"seed": seed_val,
		"bags": bags.to_dict(),
		"active": active.duplicate(true),
		"awaiting_ack": awaiting_ack.duplicate(),
		"last_round": last_round,
		"draw_count": draw_count,
		"uid": _uid,
	}


## Rebuilds a deck from to_dict() output (also after a JSON round trip).
static func from_dict(d: Dictionary, p_data: Dictionary = {}) -> CrisisDeck:
	var deck := CrisisDeck.new(int(d.get("seed", 0)), p_data)
	var bd = d.get("bags", {})
	if bd is Dictionary:
		deck.bags.from_dict(_int_bags(bd))
	deck.last_round = int(d.get("last_round", -1))
	deck.draw_count = maxi(0, int(d.get("draw_count", 0)))
	deck._uid = maxi(0, int(d.get("uid", 0)))
	var act = d.get("active", [])
	if act is Array:
		for raw in act:
			if raw is Dictionary:
				deck.active.append(_sanitise(raw))
	var aw = d.get("awaiting_ack", [])
	if aw is Array:
		for u in aw:
			deck.awaiting_ack.append(int(u))
	return deck


## JSON hands every number back as a float; restore the int fields Bags reads.
static func _int_bags(bd: Dictionary) -> Dictionary:
	var out: Dictionary = bd.duplicate(true)
	var rows = out.get("bags", {})
	if rows is Dictionary:
		for k in rows:
			var row = rows[k]
			if row is Dictionary:
				for f in ["seed", "refills", "draws", "hits"]:
					if row.has(f):
						row[f] = int(row[f])
	out["seed"] = int(out.get("seed", 0))
	return out


static func _sanitise(raw: Dictionary) -> Dictionary:
	var fx := {}
	var rfx = raw.get("effects", {})
	if rfx is Dictionary:
		for k in rfx:
			fx[str(k)] = int(rfx[k])
	return {
		"uid": int(raw.get("uid", 0)),
		"id": str(raw.get("id", "")),
		"kind": str(raw.get("kind", "")),
		"tier": str(raw.get("tier", "")),
		"name": str(raw.get("name", "")),
		"text": str(raw.get("text", "")),
		"band": str(raw.get("band", "low")),
		"station": str(raw.get("station", "")),
		"commodity": str(raw.get("commodity", "")),
		"started_round": int(raw.get("started_round", 0)),
		"expires_round": int(raw.get("expires_round", 0)),
		"rounds": int(raw.get("rounds", 0)),
		"effects": fx,
	}
