extends RefCounted
## Unit tests for res://core/order_book.gd (OrderBook storage, depth, sorted insertion, and matching engine).

const Loader = preload("res://tests/golden/golden_loader.gd")

func test_order_book_init_and_defaults() -> String:
	var ob = OrderBook.new("FRAG")
	if ob.instrument != "FRAG":
		return "expected instrument 'FRAG', got '%s'" % ob.instrument
	if not ob.bids.is_empty() or not ob.asks.is_empty():
		return "expected empty bids and asks on init"
	if ob.best_bid() != null:
		return "expected best_bid null on empty book"
	if ob.best_ask() != null:
		return "expected best_ask null on empty book"
	var d = ob.depth()
	if d[0] != 0 or d[1] != 0:
		return "expected depth [0, 0] on empty book, got %s" % str(d)
	return "ok"

func test_order_book_bids_sorted_descending() -> String:
	var ob = OrderBook.new("FRAG")
	var b1 = Order.new("b-1", "m", "FRAG", "bid", 10, 12, 1)
	var b2 = Order.new("b-2", "m", "FRAG", "bid", 5, 15, 2)
	var b3 = Order.new("b-3", "m", "FRAG", "bid", 8, 12, 3)
	var b4 = Order.new("b-4", "m", "FRAG", "bid", 20, 10, 4)

	ob.insert_order(b1)
	ob.insert_order(b2)
	ob.insert_order(b3)
	ob.insert_order(b4)

	if ob.bids.size() != 4:
		return "expected 4 bids, got %d" % ob.bids.size()

	# Expected price-time priority: b2 (15), b1 (12, seq 1), b3 (12, seq 3), b4 (10)
	var expected_ids := ["b-2", "b-1", "b-3", "b-4"]
	for i in range(4):
		if ob.bids[i].order_id != expected_ids[i]:
			return "bid at index %d expected %s, got %s" % [i, expected_ids[i], ob.bids[i].order_id]

	if ob.best_bid() != 15:
		return "expected best_bid 15, got %s" % str(ob.best_bid())
	return "ok"

func test_order_book_asks_sorted_ascending() -> String:
	var ob = OrderBook.new("FRAG")
	var a1 = Order.new("a-1", "m", "FRAG", "ask", 10, 20, 1)
	var a2 = Order.new("a-2", "m", "FRAG", "ask", 5, 18, 2)
	var a3 = Order.new("a-3", "m", "FRAG", "ask", 8, 18, 3)
	var a4 = Order.new("a-4", "m", "FRAG", "ask", 20, 25, 4)

	ob.insert_order(a1)
	ob.insert_order(a2)
	ob.insert_order(a3)
	ob.insert_order(a4)

	if ob.asks.size() != 4:
		return "expected 4 asks, got %d" % ob.asks.size()

	# Expected price-time priority: a2 (18, seq 2), a3 (18, seq 3), a1 (20), a4 (25)
	var expected_ids := ["a-2", "a-3", "a-1", "a-4"]
	for i in range(4):
		if ob.asks[i].order_id != expected_ids[i]:
			return "ask at index %d expected %s, got %s" % [i, expected_ids[i], ob.asks[i].order_id]

	if ob.best_ask() != 18:
		return "expected best_ask 18, got %s" % str(ob.best_ask())
	return "ok"

func test_order_book_depth_calculation() -> String:
	var ob = OrderBook.new("FRAG")
	var b1 = Order.new("b-1", "m", "FRAG", "bid", 10, 12, 1)
	var b2 = Order.new("b-2", "m", "FRAG", "bid", 15, 11, 2)
	b2.filled_qty = 5 # remaining: 10

	var a1 = Order.new("a-1", "m", "FRAG", "ask", 7, 20, 3)
	var a2 = Order.new("a-2", "m", "FRAG", "ask", 20, 22, 4)
	a2.filled_qty = 12 # remaining: 8

	ob.insert_order(b1)
	ob.insert_order(b2)
	ob.insert_order(a1)
	ob.insert_order(a2)

	var d = ob.depth()
	if d[0] != 20:
		return "expected total bid depth 20 (10 + 10), got %d" % d[0]
	if d[1] != 15:
		return "expected total ask depth 15 (7 + 8), got %d" % d[1]
	return "ok"

func test_order_book_to_dict_structure() -> String:
	var ob = OrderBook.new("FRAG")
	ob.insert_order(Order.new("b-1", "m1", "FRAG", "bid", 25, 14, 1, 100.0, 5, "ship-1", "v-1"))
	ob.insert_order(Order.new("a-1", "m2", "FRAG", "ask", 30, 16, 2, 101.0, 10, "ship-2", "v-2"))

	var d = ob.to_dict()
	if d["instrument"] != "FRAG":
		return "instrument mismatch in to_dict"
	if d["bids"].size() != 1 or d["asks"].size() != 1:
		return "bids/asks size mismatch in to_dict"
	if d["bids"][0]["qty"] != 20 or d["asks"][0]["qty"] != 20:
		return "remaining qty mismatch in to_dict"
	if d["bids"][0]["vessel_id"] != "v-1" or d["asks"][0]["vessel_id"] != "v-2":
		return "vessel_id mismatch in to_dict"
	return "ok"

func _replay_golden_fixture(fixture_name: String) -> String:
	var fix_path := "res://tests/golden/orderbook/%s.json" % fixture_name
	var res := Loader.load_fixture(fix_path)
	if res["error"] != "":
		return "could not load golden fixture '%s': %s" % [fixture_name, res["error"]]

	var fixture_data: Dictionary = res["data"]
	var steps: Array = fixture_data["steps"]
	var ob = OrderBook.new(str(fixture_data["instrument"]))
	var current_seq: int = 0

	for step_idx in range(steps.size()):
		var step: Dictionary = steps[step_idx]
		var payload: Dictionary = step["input"]["payload"]
		var expected_book: Dictionary = step["book"]

		# Derive vessel_id from payload or default to <agent_id>/1 (per referee resolve without peeking at expected book)
		var vessel_id = payload.get("vessel_id")
		if vessel_id == null or str(vessel_id) == "":
			vessel_id = "%s/1" % payload["agent_id"]

		var order = Order.new(
			str(payload["order_id"]),
			str(payload["agent_id"]),
			str(payload["instrument"]),
			str(payload["side"]),
			int(payload["qty"]),
			int(payload["limit_price"]),
			int(payload["seq_seen"]),
			-1.0,
			0,
			null,
			vessel_id
		)

		var next_seq: int = current_seq + 1
		var add_res: Array = ob.add_order(order, next_seq)
		var actual_trades: Array = add_res[0]
		current_seq = next_seq + actual_trades.size()

		# Verify fills/trades against step["fills"]
		var expected_fills: Array = step.get("fills", [])
		if actual_trades.size() != expected_fills.size():
			return "%s step %d: expected %d fills, got %d" % [fixture_name, step_idx, expected_fills.size(), actual_trades.size()]

		for fill_idx in range(expected_fills.size()):
			var ef: Dictionary = expected_fills[fill_idx]
			var at: Order.Trade = actual_trades[fill_idx]
			if at.trade_id != str(ef["trade_id"]):
				return "%s step %d fill %d: expected trade_id %s, got %s" % [fixture_name, step_idx, fill_idx, ef["trade_id"], at.trade_id]
			if at.buyer_id != str(ef["buyer_id"]):
				return "%s step %d fill %d: expected buyer_id %s, got %s" % [fixture_name, step_idx, fill_idx, ef["buyer_id"], at.buyer_id]
			if at.seller_id != str(ef["seller_id"]):
				return "%s step %d fill %d: expected seller_id %s, got %s" % [fixture_name, step_idx, fill_idx, ef["seller_id"], at.seller_id]
			if at.price != int(ef["price"]):
				return "%s step %d fill %d: expected price %d, got %d" % [fixture_name, step_idx, fill_idx, ef["price"], at.price]
			if at.qty != int(ef["qty"]):
				return "%s step %d fill %d: expected qty %d, got %d" % [fixture_name, step_idx, fill_idx, ef["qty"], at.qty]

		# Compare entire snapshot dictionary using JSON normalization
		var actual_normalized = JSON.parse_string(JSON.stringify(ob.to_dict()))
		var expected_normalized = JSON.parse_string(JSON.stringify(expected_book))
		if actual_normalized != expected_normalized:
			return "%s step %d snapshot mismatch.\nActual: %s\nExpected: %s" % [fixture_name, step_idx, actual_normalized, expected_normalized]

	return "ok"

func test_golden_replay_rest_no_cross() -> String:
	return _replay_golden_fixture("rest_no_cross")

func test_golden_replay_price_time_priority() -> String:
	return _replay_golden_fixture("price_time_priority")

func test_golden_replay_partial_fill_remainder() -> String:
	return _replay_golden_fixture("partial_fill_remainder")

func test_golden_replay_self_cross() -> String:
	return _replay_golden_fixture("self_cross")

func test_golden_replay_sweep_multi_level() -> String:
	return _replay_golden_fixture("sweep_multi_level")

func test_add_order_no_cross_rests_on_book() -> String:
	var ob = OrderBook.new("ORE")
	var bid = Order.new("b-1", "buyer", "ORE", "bid", 10, 20, 1)
	var res_bid = ob.add_order(bid, 1)
	if res_bid[0].size() != 0:
		return "expected 0 trades on non-crossing bid"
	if res_bid[1] != bid:
		return "expected resting order to be the submitted bid"
	if ob.best_bid() != 20:
		return "expected best_bid 20"

	var ask = Order.new("a-1", "seller", "ORE", "ask", 5, 25, 2)
	var res_ask = ob.add_order(ask, 2)
	if res_ask[0].size() != 0:
		return "expected 0 trades on non-crossing ask"
	if res_ask[1] != ask:
		return "expected resting order to be the submitted ask"
	if ob.best_ask() != 25:
		return "expected best_ask 25"
	return "ok"

func test_add_order_full_cross() -> String:
	var ob = OrderBook.new("ORE")
	var resting_ask = Order.new("a-1", "seller", "ORE", "ask", 5, 12, 1)
	ob.add_order(resting_ask, 1)

	var incoming_bid = Order.new("b-1", "buyer", "ORE", "bid", 5, 15, 2)
	var res = ob.add_order(incoming_bid, 2)
	var trades: Array = res[0]
	var resting: Variant = res[1]

	if trades.size() != 1:
		return "expected 1 trade, got %d" % trades.size()
	if resting != null:
		return "expected no resting remainder"

	var t: Order.Trade = trades[0]
	if t.trade_id != "trd-2-1":
		return "expected trade_id trd-2-1, got %s" % t.trade_id
	if t.bid_order_id != "b-1" or t.ask_order_id != "a-1":
		return "order id mismatch in trade"
	if t.buyer_id != "buyer" or t.seller_id != "seller":
		return "agent id mismatch in trade"
	if t.price != 12: # Executes at resting order's limit price!
		return "expected trade price 12 (resting ask price), got %d" % t.price
	if t.qty != 5:
		return "expected trade qty 5, got %d" % t.qty
	if t.seq != 2:
		return "expected trade seq 2, got %d" % t.seq

	if not ob.asks.is_empty() or not ob.bids.is_empty():
		return "expected empty book after full cross"
	return "ok"

func test_add_order_partial_cross_leaves_incoming_remainder() -> String:
	var ob = OrderBook.new("ORE")
	var resting_ask = Order.new("a-1", "seller", "ORE", "ask", 3, 10, 1)
	ob.add_order(resting_ask, 1)

	var incoming_bid = Order.new("b-1", "buyer", "ORE", "bid", 7, 12, 2)
	var res = ob.add_order(incoming_bid, 2)
	var trades: Array = res[0]
	var resting: Variant = res[1]

	if trades.size() != 1:
		return "expected 1 trade"
	if trades[0].qty != 3 or trades[0].price != 10:
		return "expected trade of 3 @ 10, got %d @ %d" % [trades[0].qty, trades[0].price]
	if resting != incoming_bid:
		return "expected resting order to be incoming_bid"
	if incoming_bid.remaining_qty() != 4:
		return "expected remaining_qty 4 on incoming bid, got %d" % incoming_bid.remaining_qty()
	if ob.depth() != [4, 0]:
		return "expected depth [4, 0], got %s" % str(ob.depth())
	if ob.best_bid() != 12:
		return "expected best_bid 12, got %s" % str(ob.best_bid())
	return "ok"

func test_add_order_partial_cross_leaves_resting_remainder() -> String:
	var ob = OrderBook.new("ORE")
	var resting_ask = Order.new("a-1", "seller", "ORE", "ask", 10, 15, 1)
	ob.add_order(resting_ask, 1)

	var incoming_bid = Order.new("b-1", "buyer", "ORE", "bid", 4, 15, 2)
	var res = ob.add_order(incoming_bid, 2)
	var trades: Array = res[0]
	var resting: Variant = res[1]

	if trades.size() != 1:
		return "expected 1 trade"
	if trades[0].qty != 4 or trades[0].price != 15:
		return "expected trade of 4 @ 15"
	if resting != null:
		return "expected incoming bid to be fully filled (resting=null)"
	if resting_ask.remaining_qty() != 6:
		return "expected resting ask remainder 6, got %d" % resting_ask.remaining_qty()
	if ob.depth() != [0, 6]:
		return "expected depth [0, 6], got %s" % str(ob.depth())
	return "ok"

func test_add_order_price_time_priority_sweep() -> String:
	var ob = OrderBook.new("FRAG")
	# Three resting asks:
	var a1 = Order.new("a-1", "s1", "FRAG", "ask", 2, 10, 1)
	var a2 = Order.new("a-2", "s2", "FRAG", "ask", 3, 10, 2) # Same price as a1, arrives second
	var a3 = Order.new("a-3", "s3", "FRAG", "ask", 5, 12, 3) # Higher price
	ob.add_order(a1, 1)
	ob.add_order(a2, 2)
	ob.add_order(a3, 3)

	# Incoming bid for 4 @ 11 crosses a1 (2) and part of a2 (2), stops before a3 (12 > 11)
	var bid = Order.new("b-1", "buyer", "FRAG", "bid", 4, 11, 4)
	var res = ob.add_order(bid, 4)
	var trades: Array = res[0]
	var resting: Variant = res[1]

	if trades.size() != 2:
		return "expected 2 trades, got %d" % trades.size()
	if resting != null:
		return "expected incoming bid fully filled"

	# First trade against a1 (price-time priority)
	if trades[0].ask_order_id != "a-1" or trades[0].qty != 2 or trades[0].price != 10:
		return "first trade did not prioritize a-1"
	# Second trade against a2
	if trades[1].ask_order_id != "a-2" or trades[1].qty != 2 or trades[1].price != 10:
		return "second trade did not match remainder against a-2"

	# Remaining asks on book: a2 has 1 remaining, a3 has 5 remaining
	if ob.asks.size() != 2:
		return "expected 2 resting asks on book"
	if ob.asks[0].order_id != "a-2" or ob.asks[0].remaining_qty() != 1:
		return "expected a-2 remaining qty 1 at top of book"
	if ob.asks[1].order_id != "a-3" or ob.asks[1].remaining_qty() != 5:
		return "expected a-3 remaining qty 5 at second level"
	return "ok"

func test_add_order_ask_crosses_resting_bids() -> String:
	var ob = OrderBook.new("FRAG")
	var b1 = Order.new("b-1", "b1", "FRAG", "bid", 5, 20, 1)
	var b2 = Order.new("b-2", "b2", "FRAG", "bid", 5, 18, 2)
	ob.add_order(b1, 1)
	ob.add_order(b2, 2)

	# Incoming ask @ 16 for 8 crosses b1 (5 @ 20) and b2 (3 @ 18)
	var ask = Order.new("a-1", "seller", "FRAG", "ask", 8, 16, 3)
	var res = ob.add_order(ask, 3)
	var trades: Array = res[0]
	var resting: Variant = res[1]

	if trades.size() != 2:
		return "expected 2 trades, got %d" % trades.size()
	if resting != null:
		return "expected incoming ask fully filled"

	if trades[0].bid_order_id != "b-1" or trades[0].price != 20 or trades[0].qty != 5:
		return "trade 1 mismatch: expected 5 @ 20 against b-1"
	if trades[1].bid_order_id != "b-2" or trades[1].price != 18 or trades[1].qty != 3:
		return "trade 2 mismatch: expected 3 @ 18 against b-2"

	if ob.bids.size() != 1:
		return "expected 1 resting bid remaining"
	if ob.bids[0].order_id != "b-2" or ob.bids[0].remaining_qty() != 2:
		return "expected b-2 remainder 2 on book"
	return "ok"
