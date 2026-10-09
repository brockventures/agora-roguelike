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
## The resting book's maker: the Ares Heavy syndicate (M0 counterparty, #34).
## Identity and label only; the Baron AI framework is out of scope for M0.
const MAKER_ID: String = "ares_heavy"
const MAKER_NAME: String = "ARES HEAVY"
const DEPTH_LEVELS: int = 5

var books: Dictionary = {}
## Active crisis modifiers (CrisisDeck.market_mods()): entries of
## {station, commodity ("*" = any), depth_bps, price_bps, spread_bps}. seed_book()
## folds them in, so they survive the per-round replenish(); with none set, a
## book is byte-identical to the unmodified one.
var crisis_mods: Array = []
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
	var mid: int = maxi(2, int(round(base)))
	var best_bid: int = maxi(1, mid - half)
	var best_ask: int = best_bid + 2 * half
	var step: int = half
	var book := OrderBook.new(c)
	for i in DEPTH_LEVELS:
		_seq += 1
		book.insert_order(_maker_order(c, "bid", maxi(1, (15 + (i + 1) * 8) * depth_bps / 10000), maxi(1, best_bid - i * step)))
		book.insert_order(_maker_order(c, "ask", maxi(1, (12 + (i + 1) * 7) * depth_bps / 10000), best_ask + i * step))
	books[book_key(s, c)] = book
	book_changed.emit(s, c)
	return true


## Replaces the active crisis modifiers and reseeds every book the old or new
## set touches, so an effect starts (and reverts) immediately.
func set_crisis_mods(mods: Array) -> void:
	var old: Array = crisis_mods
	if old == mods:
		return
	crisis_mods = mods.duplicate(true)
	for key in books.keys():
		var parts: PackedStringArray = str(key).split(":")
		if _mods_touch(old, parts[0], parts[1]) or _mods_touch(crisis_mods, parts[0], parts[1]):
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
func _mods_for(station: String, commodity: String) -> Dictionary:
	var depth: int = 10000
	var spread: int = 10000
	var price: int = 0
	for m in crisis_mods:
		if _mod_matches(m, station, commodity):
			depth = depth * int(m.get("depth_bps", 10000)) / 10000
			spread = spread * int(m.get("spread_bps", 10000)) / 10000
			price += int(m.get("price_bps", 0))
	return {"depth_bps": depth, "spread_bps": spread, "price_bps": price}


## Refills every book to full depth (called once per round).
func replenish() -> void:
	for key in books.keys():
		var parts: PackedStringArray = str(key).split(":")
		seed_book(parts[0], parts[1])


## Aggregated ladder in the shape OrbitalHUD.get_order_book_ladder() returns.
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
	var book: OrderBook = get_book(station, commodity)
	if book == null or qty <= 0:
		return {"filled": 0, "cost": 0, "trades": [], "counterparty": ""}
	_seq += 1
	_order_counter += 1
	var is_buy: bool = side == "BUY"
	var order := Order.new(
		"player-%d" % _order_counter, PLAYER_ID, commodity.to_upper(),
		"bid" if is_buy else "ask", qty,
		int(ceil(limit_px)) if is_buy else int(floor(limit_px)), _seq
	)
	var result: Array = book.add_order(order, _seq)
	var trades: Array = result[0]
	if result[1] != null:
		book.remove_order(order.order_id, PLAYER_ID)
	var cost: int = 0
	var counterparty: String = ""
	for t: Order.Trade in trades:
		cost += t.price * t.qty
		var other: String = t.seller_id if is_buy else t.buyer_id
		counterparty = counterparty_name(other)
	book_changed.emit(station.to_lower(), commodity.to_upper())
	return {"filled": order.filled_qty, "cost": cost, "trades": trades, "counterparty": counterparty}


## Display name of a resting-book participant id ("" for an unknown id).
static func counterparty_name(participant_id: String) -> String:
	return MAKER_NAME if participant_id == MAKER_ID else ""


func to_dict() -> Dictionary:
	var out: Dictionary = {}
	for key in books:
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
		for key in raw:
			if raw[key] is Dictionary:
				m.books[str(key)] = OrderBook.from_dict(raw[key])
	return m


func _maker_order(commodity: String, side: String, qty: int, price: int) -> Order:
	_order_counter += 1
	return Order.new("maker-%d" % _order_counter, MAKER_ID, commodity, side, qty, price, _seq)


func _aggregate(orders: Array, levels: int) -> Array:
	var out: Array = []
	for o: Order in orders:
		if out.size() > 0 and int(out[-1]["price"]) == o.limit_price:
			out[-1]["quantity"] = int(out[-1]["quantity"]) + o.remaining_qty()
			continue
		if out.size() >= levels:
			break
		out.append({"price": float(o.limit_price), "quantity": o.remaining_qty()})
	return out
