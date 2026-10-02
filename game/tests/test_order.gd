extends RefCounted
## Unit tests for res://core/order.gd (Order and Trade data classes).

func test_order_creation_and_defaults() -> String:
	var o = Order.new("o-1", "trader-a", "FRAG", "bid", 10, 100, 1)
	if o.order_id != "o-1":
		return "expected order_id 'o-1', got '%s'" % o.order_id
	if o.agent_id != "trader-a":
		return "expected agent_id 'trader-a', got '%s'" % o.agent_id
	if o.instrument != "FRAG":
		return "expected instrument 'FRAG', got '%s'" % o.instrument
	if o.side != "bid":
		return "expected side 'bid', got '%s'" % o.side
	if o.qty != 10:
		return "expected qty 10, got %d" % o.qty
	if o.limit_price != 100:
		return "expected limit_price 100, got %d" % o.limit_price
	if o.seq_seen != 1:
		return "expected seq_seen 1, got %d" % o.seq_seen
	if o.filled_qty != 0:
		return "expected filled_qty 0, got %d" % o.filled_qty
	if o.submitted_at <= 0.0:
		return "expected positive submitted_at, got %f" % o.submitted_at
	if o.acct != null:
		return "expected default acct null, got %s" % str(o.acct)
	if o.vessel_id != null:
		return "expected default vessel_id null, got %s" % str(o.vessel_id)
	return "ok"

func test_order_remaining_and_filled() -> String:
	var o = Order.new("o-2", "trader-b", "FRAG", "ask", 25, 105, 2)
	if o.remaining_qty() != 25:
		return "expected remaining_qty 25, got %d" % o.remaining_qty()
	if o.is_filled():
		return "order should not be filled initially"

	o.filled_qty = 10
	if o.remaining_qty() != 15:
		return "expected remaining_qty 15, got %d" % o.remaining_qty()
	if o.is_filled():
		return "order should not be filled at partial fill"

	o.filled_qty = 25
	if o.remaining_qty() != 0:
		return "expected remaining_qty 0, got %d" % o.remaining_qty()
	if not o.is_filled():
		return "order should be filled when remaining_qty is 0"

	o.filled_qty = 30
	if o.remaining_qty() != -5:
		return "expected remaining_qty -5, got %d" % o.remaining_qty()
	if not o.is_filled():
		return "order should be filled when remaining_qty < 0"
	return "ok"

func test_order_goods_acct() -> String:
	var o1 = Order.new("o-3", "agent-x", "FRAG", "bid", 5, 50, 3)
	if o1.goods_acct() != "agent-x":
		return "expected default goods_acct 'agent-x', got '%s'" % o1.goods_acct()

	var o2 = Order.new("o-4", "agent-y", "FRAG", "bid", 5, 50, 4, 1000.0, 0, "ship-99", "v-1")
	if o2.goods_acct() != "ship-99":
		return "expected goods_acct 'ship-99', got '%s'" % o2.goods_acct()
	if o2.vessel_id != "v-1":
		return "expected vessel_id 'v-1', got '%s'" % str(o2.vessel_id)
	return "ok"

func test_order_dict_roundtrip() -> String:
	var o = Order.new("o-5", "trader-c", "FRAG", "ask", 12, 95, 5, 1234567.89, 4, "corp/1", "v-42")
	var d = o.to_dict()
	if d["order_id"] != "o-5" or d["agent_id"] != "trader-c" or d["qty"] != 12:
		return "to_dict failed to preserve basic fields"
	if d["submitted_at"] != 1234567.89 or d["filled_qty"] != 4:
		return "to_dict failed on timestamp/fill fields"
	if d["acct"] != "corp/1" or d["vessel_id"] != "v-42":
		return "to_dict failed on account/vessel fields"

	var restored = Order.from_dict(d)
	if restored.order_id != o.order_id or restored.remaining_qty() != 8:
		return "from_dict roundtrip failed"
	if restored.goods_acct() != "corp/1" or restored.vessel_id != "v-42":
		return "from_dict failed to restore acct/vessel_id"

	var s = str(o)
	if not s.begins_with("<Order o-5 ask 12 FRAG @ 95 (rem: 8)>"):
		return "unexpected string representation: %s" % s
	return "ok"

func test_order_json_string_roundtrip() -> String:
	var o = Order.new("o-json-1", "trader-j", "FRAG", "bid", 50, 110, 8, 1700000.5, 15, "corp/alpha", "v-99")
	var json_str = JSON.stringify(o.to_dict())
	var parsed = JSON.parse_string(json_str)
	if parsed == null or not (parsed is Dictionary):
		return "JSON.parse_string failed to parse serialized order"

	var restored = Order.from_dict(parsed)
	if restored.order_id != "o-json-1" or restored.qty != 50 or restored.remaining_qty() != 35:
		return "restored order from JSON string has mismatched values"
	if restored.goods_acct() != "corp/alpha" or restored.vessel_id != "v-99":
		return "restored order failed on acct/vessel_id"
	return "ok"

func test_trade_creation_and_dict_roundtrip() -> String:
	var t = Order.Trade.new(
		"t-100", "bid-1", "ask-2", "buyer-1", "seller-1",
		"FRAG", 102, 7, 42, 999999.0, "ship-b", "ship-s"
	)
	if t.trade_id != "t-100":
		return "expected trade_id 't-100', got '%s'" % t.trade_id
	if t.price != 102 or t.qty != 7 or t.seq != 42:
		return "trade numbers mismatch"
	if t.buyer_acct != "ship-b" or t.seller_acct != "ship-s":
		return "trade accts mismatch"

	var d = t.to_dict()
	if d["trade_id"] != "t-100" or d["price"] != 102 or d["qty"] != 7:
		return "trade to_dict mismatch"

	var restored = Order.Trade.from_dict(d)
	if restored.trade_id != t.trade_id or restored.price != 102 or restored.qty != 7:
		return "trade from_dict mismatch"
	if restored.buyer_acct != "ship-b" or restored.seller_acct != "ship-s":
		return "trade restored accounts mismatch"

	var s = str(t)
	if not s.begins_with("<Trade t-100 7 FRAG @ 102 (buyer: buyer-1, seller: seller-1)>"):
		return "unexpected trade string representation: %s" % s
	return "ok"

func test_trade_json_string_roundtrip() -> String:
	var t = Order.Trade.new(
		"t-200", "bid-10", "ask-20", "buyer-x", "seller-y",
		"FRAG", 105, 14, 88, 1750000.0, "ship-bx", "ship-sy"
	)
	var json_str = JSON.stringify(t.to_dict())
	var parsed = JSON.parse_string(json_str)
	if parsed == null or not (parsed is Dictionary):
		return "JSON.parse_string failed for trade"

	var restored = Order.Trade.from_dict(parsed)
	if restored.trade_id != "t-200" or restored.price != 105 or restored.qty != 14:
		return "restored trade from JSON has mismatch"
	if restored.buyer_acct != "ship-bx" or restored.seller_acct != "ship-sy":
		return "restored trade accounts mismatch"
	return "ok"
