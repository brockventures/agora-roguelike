class_name StationMarket
extends RefCounted
## Resting order books for the stations the M0 slice trades at (#84).
##
## One OrderBook per (station, commodity), seeded with market-maker orders
## around Transit.BASE_PRICES. The player trades by sending an immediate-or-cancel
## order that crosses the resting book (price-time priority, executing at the
## resting price), so liquidity is consumed and refilled on round boundaries.
## Prices are integer CR; the book models stay presentation-free.

signal book_changed(station: String, commodity: String)

## Stations that carry a live book, with their trading-post names.
const STATION_NAMES: Dictionary = {
	"earth": "Kennedy Elevator",
	"mars": "Arcadia Foundries",
}
const PLAYER_ID: String = "player"
## The default resting-book maker: the Ares Heavy syndicate (M0 counterparty, #34).
## It makes every station's book unless a world with barons is attached and a
## baron anchors that station (maker_for), so a run with no world is unchanged.
const MAKER_ID: String = "ares_heavy"
const MAKER_NAME: String = "ARES HEAVY"
const DEPTH_LEVELS: int = 5

var books: Dictionary = {}
## Active crisis modifiers (CrisisDeck.market_mods()): entries of
## {station, commodity ("*" = any), depth_bps, price_bps, spread_bps}. seed_book()
## folds them in, so they survive the per-round replenish(); with none set, a
## book is byte-identical to the unmodified one.
var crisis_mods: Array = []
## The sector barons (Epic 3, docs/design/epic3-barons.md 3.2). Null = no world:
## every book is made by MAKER_ID and counterparty_name knows only that maker.
## Set through set_world(); a restored market gets it from RunSave without a reseed.
var world: Barons = null
## Mods the world emits each round (Barons.market_mods()), same shape as
## crisis_mods plus the optional side-specific "ask_price_bps". Folded BEFORE
## crisis_mods, see _mods_for.
var world_mods: Array = []
var _seq: int = 0
var _order_counter: int = 0


func _init(p_stations: Array = []) -> void:
	var stations: Array = p_stations if not p_stations.is_empty() else STATION_NAMES.keys()
	for s in stations:
		for c in Transit.COMMODITIES:
			seed_book(str(s), c)


static func book_key(station: String, commodity: String) -> String:
	return "%s:%s" % [station.to_lower(), commodity.to_upper()]


static func station_name(station: String) -> String:
	return str(STATION_NAMES.get(station.to_lower(), station.capitalize()))


func has_book(station: String, commodity: String) -> bool:
	return books.has(book_key(station, commodity))


func get_book(station: String, commodity: String) -> OrderBook:
	return books.get(book_key(station, commodity), null)


## (Re)builds the resting book for one instrument from the station base price.
func seed_book(station: String, commodity: String) -> bool:
	var s: String = station.to_lower()
	var c: String = commodity.to_upper()
	if not Transit.BASE_PRICES.has(s) or not Transit.BASE_PRICES[s].has(c):
		return false
	var fx: Dictionary = _mods_for(s, c)
	var base: float = float(Transit.BASE_PRICES[s][c])
	if int(fx["price_bps"]) != 0:
		base *= float(10000 + int(fx["price_bps"])) / 10000.0
	var half: int = maxi(1, int(round(base * 0.02)))
	if int(fx["spread_bps"]) != 10000:
		# Scale the integer half-spread (books quote whole CR, so scaling the raw
		# float would round most cheap commodities back to one CR).
		half = maxi(1, int(round(float(half) * float(fx["spread_bps"]) / 10000.0)))
	var depth_bps: int = int(fx["depth_bps"])
	var ask_bps: int = int(fx["ask_price_bps"])
	var ask_depth_bps: int = int(fx["ask_depth_bps"])
	var maker: String = maker_for(s)
	var mid: int = maxi(2, int(round(base)))
	var best_bid: int = maxi(1, mid - half)
	var best_ask: int = best_bid + 2 * half
	var step: int = half
	var book := OrderBook.new(c)
	for i in DEPTH_LEVELS:
		_seq += 1
		book.insert_order(_maker_order(maker, c, "bid", maxi(1, (15 + (i + 1) * 8) * depth_bps / 10000), maxi(1, best_bid - i * step)))
		var ask_px: int = best_ask + i * step
		if ask_bps != 0:
			# Side-specific price: the ask ladder only (bids are untouched).
			ask_px = maxi(1, int(round(float(ask_px) * float(10000 + ask_bps) / 10000.0)))
		book.insert_order(_maker_order(maker, c, "ask", maxi(1, (12 + (i + 1) * 7) * ask_depth_bps / 10000), ask_px))
	books[book_key(s, c)] = book
	book_changed.emit(s, c)
	return true


## Seeds a station's books the first time the player has a reason to trade
## there (travel, #111). A station that already has books is left alone, so
## calling this is idempotent; from then on replenish() refills the new books
## with the rest. Returns true when books were created. Stations are not
## seeded up front: a run that never travels keeps its market byte-identical.
func unlock_station(station: String) -> bool:
	var s: String = station.to_lower()
	if not Transit.BASE_PRICES.has(s):
		return false
	var created: bool = false
	for c in Transit.COMMODITIES:
		if not has_book(s, c):
			created = seed_book(s, c) or created
	return created


## Replaces the active crisis modifiers and reseeds every book the old or new
## set touches, so an effect starts (and reverts) immediately.
func set_crisis_mods(mods: Array) -> void:
	var old: Array = crisis_mods
	if old == mods:
		return
	crisis_mods = mods.duplicate(true)
	for key in _book_keys():
		var parts: PackedStringArray = str(key).split(":")
		if _mods_touch(old, parts[0], parts[1]) or _mods_touch(crisis_mods, parts[0], parts[1]):
			seed_book(parts[0], parts[1])


## Attaches (or detaches, with null) the world and reseeds every book, so each
## station is made by its anchoring baron from now on. Idempotent for the same
## world. A restored market is wired by RunSave instead (its books are already
## the saved ones).
func set_world(w: Barons) -> void:
	if w == world:
		return
	world = w
	_reseed_all()


## Replaces the world's mods and reseeds the books the old or new set touches.
func set_world_mods(mods: Array) -> void:
	var old: Array = world_mods
	if old == mods:
		return
	world_mods = mods.duplicate(true)
	for key in _book_keys():
		var parts: PackedStringArray = str(key).split(":")
		if _mods_touch(old, parts[0], parts[1]) or _mods_touch(world_mods, parts[0], parts[1]):
			seed_book(parts[0], parts[1])


## The participant id that makes a station's book: its anchoring baron when a
## world is attached, else (no world, or an unanchored station such as Luna)
## the default maker.
func maker_for(station: String) -> String:
	if world != null:
		var id: String = world.baron_at(station)
		if id != "":
			return id
	return MAKER_ID


func _reseed_all() -> void:
	for key in _book_keys():
		var parts: PackedStringArray = str(key).split(":")
		seed_book(parts[0], parts[1])


func _mods_touch(mods: Array, station: String, commodity: String) -> bool:
	for m in mods:
		if _mod_matches(m, station, commodity):
			return true
	return false


static func _mod_matches(m: Dictionary, station: String, commodity: String) -> bool:
	var ms: String = str(m.get("station", "*")).to_lower()
	var mc: String = str(m.get("commodity", "*")).to_upper()
	return (ms == "*" or ms == station) and (mc == "*" or mc == commodity)


## Combined modifier for one book: depth and spread multiply, price adds.
## FOLD ORDER IS PART OF THE REPLAY CONTRACT: depth and spread multiply with
## integer division one mod at a time, so the result depends on the order.
## world_mods fold first (barons by id, then rivals by id, as the world emits
## them), then crisis_mods in the deck's own order. Pinned by the golden
## fixture tests/fixtures/world/fold_order.json.
## ask_price_bps is the side-specific price: it adds like price_bps but moves
## only the ask ladder (absent = 0, so a mod without it is untouched).
## ask_depth_bps is the side-specific depth: it multiplies the ask ladder's
## depth on top of depth_bps and leaves the bids alone (absent = 10000).
func _mods_for(station: String, commodity: String) -> Dictionary:
	var depth: int = 10000
	var spread: int = 10000
	var price: int = 0
	var ask_price: int = 0
	var ask_depth: int = 10000
	for group in [world_mods, crisis_mods]:
		for m in group:
			if _mod_matches(m, station, commodity):
				depth = depth * int(m.get("depth_bps", 10000)) / 10000
				spread = spread * int(m.get("spread_bps", 10000)) / 10000
				price += int(m.get("price_bps", 0))
				ask_price += int(m.get("ask_price_bps", 0))
				ask_depth = ask_depth * int(m.get("ask_depth_bps", 10000)) / 10000
	# The ask ladder's own depth is the shared depth scaled by the ask-only factor
	# (with no ask_depth_bps anywhere this is exactly depth).
	return {"depth_bps": depth, "spread_bps": spread, "price_bps": price, "ask_price_bps": ask_price, "ask_depth_bps": depth * ask_depth / 10000}


## Total ask quantity a freshly seeded book carries at a folded ask-depth factor
## (the integer ladder seed_book builds: 12 + 7 x level units, scaled and floored
## per level). Titan Cryo-Hydro (Epic 3 task 5) sizes its hoard in these units.
static func ask_qty_at(ask_depth_bps: int) -> int:
	var total: int = 0
	for i in DEPTH_LEVELS:
		total += maxi(1, (12 + (i + 1) * 7) * ask_depth_bps / 10000)
	return total


## The ask quantity still resting on a book as bps of what the current mods seed
## (10000 = untouched; below it the round's trading has eaten into the ask).
## -1 when there is no such book.
func ask_depth_ratio_bps(station: String, commodity: String) -> int:
	var book: OrderBook = get_book(station, commodity)
	if book == null:
		return -1
	var nominal: int = StationMarket.ask_qty_at(int(_mods_for(station.to_lower(), commodity.to_upper())["ask_depth_bps"]))
	var left: int = 0
	for o: Order in book.asks:
		left += o.remaining_qty()
	return left * 10000 / maxi(1, nominal)


## Refills every book to full depth (called once per round).
func replenish() -> void:
	_reseed_all()


## Every book key in the canonical order: station name, then the commodity's
## place in Transit.COMMODITIES (unknown commodities after, by name). Anything
## that reseeds more than one book walks this order, never the Dictionary's own
## insertion order: seeding assigns maker order ids from a running counter, and
## insertion order does not survive a JSON save (keys come back sorted), so the
## ids, and with them the raw market hash, would otherwise differ after a load.
func _book_keys() -> Array:
	var keys: Array = books.keys()
	keys.sort_custom(StationMarket._key_before)
	return keys


static func _key_before(a: Variant, b: Variant) -> bool:
	var pa: PackedStringArray = str(a).split(":")
	var pb: PackedStringArray = str(b).split(":")
	if pa[0] != pb[0]:
		return pa[0] < pb[0]
	var ia: int = Transit.COMMODITIES.find(pa[1]) if pa.size() > 1 else -1
	var ib: int = Transit.COMMODITIES.find(pb[1]) if pb.size() > 1 else -1
	if ia < 0:
		ia = Transit.COMMODITIES.size()
	if ib < 0:
		ib = Transit.COMMODITIES.size()
	if ia != ib:
		return ia < ib
	return str(a) < str(b)


## Aggregated ladder in the shape OrbitalHUD.get_order_book_ladder() returns.
## Each row also carries `maker`: the participant id when one maker owns the
## level, "" when several do.
func ladder(station: String, commodity: String, levels: int = DEPTH_LEVELS) -> Dictionary:
	var book: OrderBook = get_book(station, commodity)
	if book == null:
		return {}
	var bids: Array = _aggregate(book.bids, levels)
	var asks: Array = _aggregate(book.asks, levels)
	var best_bid: float = float(bids[0]["price"]) if not bids.is_empty() else 0.0
	var best_ask: float = float(asks[0]["price"]) if not asks.is_empty() else 0.0
	var both: bool = not bids.is_empty() and not asks.is_empty()
	return {
		"synthetic": false,
		"spread": best_ask - best_bid if both else 0.0,
		"best_bid": best_bid,
		"best_ask": best_ask,
		"mid_price": (best_bid + best_ask) * 0.5 if both else 0.0,
		"bids": bids,
		"asks": asks,
	}


## Non-mutating sweep of the book for a player order. side is "BUY" or "SELL";
## limit_px is the worst acceptable price. Returns the fillable quantity and
## the CR it would cost (BUY) or pay (SELL).
func sweep_quote(station: String, commodity: String, side: String, qty: int, limit_px: float) -> Dictionary:
	var book: OrderBook = get_book(station, commodity)
	var filled: int = 0
	var cost: int = 0
	if book != null and qty > 0:
		var resting: Array = book.asks if side == "BUY" else book.bids
		for o: Order in resting:
			var crosses: bool = float(o.limit_price) <= limit_px if side == "BUY" else float(o.limit_price) >= limit_px
			if not crosses or filled >= qty:
				break
			var take: int = mini(qty - filled, o.remaining_qty())
			filled += take
			cost += take * o.limit_price
	return {"filled": filled, "cost": cost}


## Sends an immediate-or-cancel player order into the book. Any unfilled
## remainder is cancelled, never left resting. Returns {filled, cost, trades}.
func execute(station: String, commodity: String, side: String, qty: int, limit_px: float) -> Dictionary:
	return execute_as(PLAYER_ID, station, commodity, side, qty, limit_px)


## execute() for any participant id (rival fleets, Epic 3 task 10): the same IOC
## sweep, with the order owned by `participant_id`. For PLAYER_ID the order ids
## and result are exactly execute()'s. Returns {filled, cost, trades,
## counterparty (display name), counterparty_id}.
func execute_as(participant_id: String, station: String, commodity: String, side: String, qty: int, limit_px: float) -> Dictionary:
	var book: OrderBook = get_book(station, commodity)
	if book == null or qty <= 0:
		return {"filled": 0, "cost": 0, "trades": [], "counterparty": "", "counterparty_id": ""}
	_seq += 1
	_order_counter += 1
	var is_buy: bool = side == "BUY"
	var order := Order.new(
		"%s-%d" % [participant_id, _order_counter], participant_id, commodity.to_upper(),
		"bid" if is_buy else "ask", qty,
		int(ceil(limit_px)) if is_buy else int(floor(limit_px)), _seq
	)
	var result: Array = book.add_order(order, _seq)
	var trades: Array = result[0]
	if result[1] != null:
		book.remove_order(order.order_id, participant_id)
	var cost: int = 0
	var counterparty: String = ""
	var counterparty_id: String = ""
	for t: Order.Trade in trades:
		cost += t.price * t.qty
		counterparty_id = t.seller_id if is_buy else t.buyer_id
		counterparty = counterparty_name(counterparty_id)
	book_changed.emit(station.to_lower(), commodity.to_upper())
	return {"filled": order.filled_qty, "cost": cost, "trades": trades, "counterparty": counterparty, "counterparty_id": counterparty_id}


## Display name of a resting-book participant id ("" for an unknown id). The
## default maker is always known; barons come from the attached world's
## registry, so a fill at Ceres announces TITAN CRYO-HYDRO.
func counterparty_name(participant_id: String) -> String:
	if participant_id == MAKER_ID:
		return MAKER_NAME
	if world != null:
		var d: Dictionary = world.def(participant_id)
		if not d.is_empty():
			return str(d.get("name", "")).to_upper()
	return ""


func to_dict() -> Dictionary:
	var out: Dictionary = {}
	for key in _book_keys():
		out[key] = (books[key] as OrderBook).to_dict()
	return {"books": out, "seq": _seq, "order_counter": _order_counter}


## Rebuilds a market from to_dict() output. Unlike _init, no book is reseeded:
## the restored books are exactly the saved ones (an empty "books" stays empty).
static func from_dict(d: Dictionary) -> StationMarket:
	var m := StationMarket.new([])
	m.books.clear()  # _init seeds the default stations; a restore keeps only saved books
	m._seq = int(d.get("seq", 0))
	m._order_counter = int(d.get("order_counter", 0))
	var raw = d.get("books", {})
	if raw is Dictionary:
		# Insert in canonical order whatever order the file listed them in.
		var keys: Array = (raw as Dictionary).keys()
		keys.sort_custom(StationMarket._key_before)
		for key in keys:
			if raw[key] is Dictionary:
				m.books[str(key)] = OrderBook.from_dict(raw[key])
	return m


func _maker_order(maker: String, commodity: String, side: String, qty: int, price: int) -> Order:
	_order_counter += 1
	return Order.new("maker-%d" % _order_counter, maker, commodity, side, qty, price, _seq)


func _aggregate(orders: Array, levels: int) -> Array:
	var out: Array = []
	for o: Order in orders:
		if out.size() > 0 and int(out[-1]["price"]) == o.limit_price:
			out[-1]["quantity"] = int(out[-1]["quantity"]) + o.remaining_qty()
			if str(out[-1]["maker"]) != o.agent_id:
				out[-1]["maker"] = ""  # a mixed level has no single maker
			continue
		if out.size() >= levels:
			break
		out.append({"price": float(o.limit_price), "quantity": o.remaining_qty(), "maker": o.agent_id})
	return out
