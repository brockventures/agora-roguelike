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
const MAKER_ID: String = "maker"
const DEPTH_LEVELS: int = 5

var books: Dictionary = {}
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
	var base: float = float(Transit.BASE_PRICES[s][c])
	var half: int = maxi(1, int(round(base * 0.02)))
	var mid: int = maxi(2, int(round(base)))
	var best_bid: int = maxi(1, mid - half)
	var best_ask: int = best_bid + 2 * half
	var step: int = half
	var book := OrderBook.new(c)
	for i in DEPTH_LEVELS:
		_seq += 1
		book.insert_order(_maker_order(c, "bid", 15 + (i + 1) * 8, maxi(1, best_bid - i * step)))
		book.insert_order(_maker_order(c, "ask", 12 + (i + 1) * 7, best_ask + i * step))
	books[book_key(s, c)] = book
	book_changed.emit(s, c)
	return true


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
		return {"filled": 0, "cost": 0, "trades": []}
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
	for t: Order.Trade in trades:
		cost += t.price * t.qty
	book_changed.emit(station.to_lower(), commodity.to_upper())
	return {"filled": order.filled_qty, "cost": cost, "trades": trades}


func to_dict() -> Dictionary:
	var out: Dictionary = {}
	for key in books:
		out[key] = (books[key] as OrderBook).to_dict()
	return out


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
