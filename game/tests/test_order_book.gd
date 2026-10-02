extends RefCounted
## Unit tests for res://core/order_book.gd (OrderBook storage, depth, and sorted insertion).

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

func test_order_book_rest_no_cross_full_replay() -> String:
	var fix_path := "res://tests/golden/orderbook/rest_no_cross.json"
	var res := Loader.load_fixture(fix_path)
	if res["error"] != "":
		return "could not load golden fixture: %s" % res["error"]

	var fixture_data: Dictionary = res["data"]
	var steps: Array = fixture_data["steps"]
	var ob = OrderBook.new(str(fixture_data["instrument"]))

	for step_idx in range(steps.size()):
		var step: Dictionary = steps[step_idx]
		var payload: Dictionary = step["input"]["payload"]
		var expected_book: Dictionary = step["book"]

		# Find vessel_id of the new order from expected book
		var target_side: String = "bids" if payload["side"] == "bid" else "asks"
		var vessel_id = null
		for entry in expected_book[target_side]:
			if entry["order_id"] == payload["order_id"]:
				vessel_id = entry.get("vessel_id", null)
				break

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
		ob.insert_order(order)

		# Compare entire snapshot dictionary using JSON normalization
		var actual_normalized = JSON.parse_string(JSON.stringify(ob.to_dict()))
		var expected_normalized = JSON.parse_string(JSON.stringify(expected_book))
		if actual_normalized != expected_normalized:
			return "step %d snapshot mismatch:\nactual: %s\nexpected: %s" % [
				step_idx, JSON.stringify(actual_normalized), JSON.stringify(expected_normalized)
			]
	return "ok"
