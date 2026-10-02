class_name OrderBook
extends RefCounted
## Two-sided limit order book for a single commodity instrument against credits (CR).
## Ported from market-sandbox Python referee (agora/order_book.py:59-110, 211-227 at commit 587b07f).
##
## Bids sorted: price descending, arrival time (seq_seen / insertion) ascending.
## Asks sorted: price ascending, arrival time (seq_seen / insertion) ascending.

var instrument: String = "FRAG"
var bids: Array = []
var asks: Array = []
var _trade_counter: int = 0

func _init(p_instrument: String = "FRAG") -> void:
	instrument = p_instrument
	bids = []
	asks = []
	_trade_counter = 0

func best_bid() -> Variant:
	if bids.is_empty():
		return null
	return bids[0].limit_price

func best_ask() -> Variant:
	if asks.is_empty():
		return null
	return asks[0].limit_price

func depth() -> Array:
	var total_bid_qty: int = 0
	for o in bids:
		total_bid_qty += o.remaining_qty()
	var total_ask_qty: int = 0
	for o in asks:
		total_ask_qty += o.remaining_qty()
	return [total_bid_qty, total_ask_qty]

func _insert_bid(order: Order) -> void:
	# Insert maintaining price descending, time (arrival) ascending
	var idx: int = 0
	while idx < bids.size():
		if bids[idx].limit_price < order.limit_price:
			break
		idx += 1
	bids.insert(idx, order)

func _insert_ask(order: Order) -> void:
	# Insert maintaining price ascending, time (arrival) ascending
	var idx: int = 0
	while idx < asks.size():
		if asks[idx].limit_price > order.limit_price:
			break
		idx += 1
	asks.insert(idx, order)

func insert_order(order: Order) -> void:
	if order.side == "bid":
		_insert_bid(order)
	elif order.side == "ask":
		_insert_ask(order)
	else:
		push_error("Invalid order side: %s" % order.side)

func to_dict() -> Dictionary:
	var bid_dicts: Array = []
	for o in bids:
		bid_dicts.append({
			"order_id": o.order_id,
			"agent_id": o.agent_id,
			"side": o.side,
			"qty": o.remaining_qty(),
			"limit_price": o.limit_price,
			"seq_seen": o.seq_seen,
			"vessel_id": o.vessel_id,
		})
	var ask_dicts: Array = []
	for o in asks:
		ask_dicts.append({
			"order_id": o.order_id,
			"agent_id": o.agent_id,
			"side": o.side,
			"qty": o.remaining_qty(),
			"limit_price": o.limit_price,
			"seq_seen": o.seq_seen,
			"vessel_id": o.vessel_id,
		})
	return {
		"instrument": instrument,
		"bids": bid_dicts,
		"asks": ask_dicts,
	}
