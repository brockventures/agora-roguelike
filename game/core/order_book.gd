class_name OrderBook
extends RefCounted
## Two-sided limit order book for a single commodity instrument against credits (CR).
## Ported from market-sandbox Python referee (agora/order_book.py:59-198, 211-227 at commit e7fb174).
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

func add_order(order: Order, current_seq: int) -> Array:
	## Cross order against resting book.
	## Any remaining unfilled quantity rests on the book.
	## Returns [Array of Trade, Optional resting Order (or null)]
	var trades: Array = []

	if order.side == "bid":
		# Match against resting asks (ask.limit_price <= order.limit_price)
		while not asks.is_empty() and order.remaining_qty() > 0:
			var best_ask: Order = asks[0]
			if best_ask.limit_price > order.limit_price:
				break  # Cannot cross

			# Trade executes at resting order's limit price (price-time priority)
			var exec_price: int = best_ask.limit_price
			var match_qty: int = mini(order.remaining_qty(), best_ask.remaining_qty())

			_trade_counter += 1
			var trade := Order.Trade.new(
				"trd-%d-%d" % [current_seq, _trade_counter],
				order.order_id,
				best_ask.order_id,
				order.agent_id,
				best_ask.agent_id,
				instrument,
				exec_price,
				match_qty,
				current_seq,
				-1.0,
				order.goods_acct(),
				best_ask.goods_acct()
			)
			trades.append(trade)

			order.filled_qty += match_qty
			best_ask.filled_qty += match_qty

			if best_ask.is_filled():
				asks.pop_front()

		# Rest remaining unfilled bid
		if not order.is_filled():
			_insert_bid(order)
			return [trades, order]
		return [trades, null]

	elif order.side == "ask":
		# Match against resting bids (bid.limit_price >= order.limit_price)
		while not bids.is_empty() and order.remaining_qty() > 0:
			var best_bid: Order = bids[0]
			if best_bid.limit_price < order.limit_price:
				break  # Cannot cross

			# Trade executes at resting order's limit price
			var exec_price: int = best_bid.limit_price
			var match_qty: int = mini(order.remaining_qty(), best_bid.remaining_qty())

			_trade_counter += 1
			var trade := Order.Trade.new(
				"trd-%d-%d" % [current_seq, _trade_counter],
				best_bid.order_id,
				order.order_id,
				best_bid.agent_id,
				order.agent_id,
				instrument,
				exec_price,
				match_qty,
				current_seq,
				-1.0,
				best_bid.goods_acct(),
				order.goods_acct()
			)
			trades.append(trade)

			order.filled_qty += match_qty
			best_bid.filled_qty += match_qty

			if best_bid.is_filled():
				bids.pop_front()

		# Rest remaining unfilled ask
		if not order.is_filled():
			_insert_ask(order)
			return [trades, order]
		return [trades, null]

	else:
		push_error("Invalid order side: %s" % order.side)
		return [trades, null]

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
