class_name Order
extends RefCounted
## Core Order and Trade data classes ported from market-sandbox Python referee
## (agora/order_book.py at commit e7fb174).

var order_id: String = ""
var agent_id: String = ""
var instrument: String = ""
var side: String = ""  # "bid" or "ask"
var qty: int = 0
var limit_price: int = 0
var seq_seen: int = 0
var submitted_at: float = 0.0
var filled_qty: int = 0
var acct = null        # Optional[str]: ledger goods account (e.g. ship "<corp>/<n>")
var vessel_id = null   # Optional[str]: vessel_id if ship order, null if agent/depot

func _init(
	p_order_id: String = "",
	p_agent_id: String = "",
	p_instrument: String = "",
	p_side: String = "",
	p_qty: int = 0,
	p_limit_price: int = 0,
	p_seq_seen: int = 0,
	p_submitted_at: float = -1.0,
	p_filled_qty: int = 0,
	p_acct = null,
	p_vessel_id = null
) -> void:
	order_id = p_order_id
	agent_id = p_agent_id
	instrument = p_instrument
	side = p_side
	qty = p_qty
	limit_price = p_limit_price
	seq_seen = p_seq_seen
	submitted_at = Time.get_unix_time_from_system() if p_submitted_at < 0.0 else p_submitted_at
	filled_qty = p_filled_qty
	acct = p_acct
	vessel_id = p_vessel_id

func goods_acct() -> String:
	if acct != null and str(acct) != "":
		return str(acct)
	return agent_id

func remaining_qty() -> int:
	return qty - filled_qty

func is_filled() -> bool:
	return remaining_qty() <= 0

func to_dict() -> Dictionary:
	return {
		"order_id": order_id,
		"agent_id": agent_id,
		"instrument": instrument,
		"side": side,
		"qty": qty,
		"limit_price": limit_price,
		"seq_seen": seq_seen,
		"submitted_at": submitted_at,
		"filled_qty": filled_qty,
		"acct": acct,
		"vessel_id": vessel_id,
	}

static func from_dict(d: Dictionary) -> Order:
	return Order.new(
		str(d.get("order_id", "")),
		str(d.get("agent_id", "")),
		str(d.get("instrument", "")),
		str(d.get("side", "")),
		int(d.get("qty", 0)),
		int(d.get("limit_price", 0)),
		int(d.get("seq_seen", 0)),
		float(d.get("submitted_at", -1.0)),
		int(d.get("filled_qty", 0)),
		d.get("acct", null),
		d.get("vessel_id", null)
	)

func _to_string() -> String:
	return "<Order %s %s %d %s @ %d (rem: %d)>" % [order_id, side, qty, instrument, limit_price, remaining_qty()]


class Trade extends RefCounted:
	var trade_id: String = ""
	var bid_order_id: String = ""
	var ask_order_id: String = ""
	var buyer_id: String = ""
	var seller_id: String = ""
	var instrument: String = ""
	var price: int = 0
	var qty: int = 0
	var seq: int = 0
	var timestamp: float = 0.0
	var buyer_acct = null
	var seller_acct = null

	func _init(
		p_trade_id: String = "",
		p_bid_order_id: String = "",
		p_ask_order_id: String = "",
		p_buyer_id: String = "",
		p_seller_id: String = "",
		p_instrument: String = "",
		p_price: int = 0,
		p_qty: int = 0,
		p_seq: int = 0,
		p_timestamp: float = -1.0,
		p_buyer_acct = null,
		p_seller_acct = null
	) -> void:
		trade_id = p_trade_id
		bid_order_id = p_bid_order_id
		ask_order_id = p_ask_order_id
		buyer_id = p_buyer_id
		seller_id = p_seller_id
		instrument = p_instrument
		price = p_price
		qty = p_qty
		seq = p_seq
		timestamp = Time.get_unix_time_from_system() if p_timestamp < 0.0 else p_timestamp
		buyer_acct = p_buyer_acct
		seller_acct = p_seller_acct

	func to_dict() -> Dictionary:
		return {
			"trade_id": trade_id,
			"bid_order_id": bid_order_id,
			"ask_order_id": ask_order_id,
			"buyer_id": buyer_id,
			"seller_id": seller_id,
			"instrument": instrument,
			"price": price,
			"qty": qty,
			"seq": seq,
			"timestamp": timestamp,
			"buyer_acct": buyer_acct,
			"seller_acct": seller_acct,
		}

	static func from_dict(d: Dictionary) -> Trade:
		return Trade.new(
			str(d.get("trade_id", "")),
			str(d.get("bid_order_id", "")),
			str(d.get("ask_order_id", "")),
			str(d.get("buyer_id", "")),
			str(d.get("seller_id", "")),
			str(d.get("instrument", "")),
			int(d.get("price", 0)),
			int(d.get("qty", 0)),
			int(d.get("seq", 0)),
			float(d.get("timestamp", -1.0)),
			d.get("buyer_acct", null),
			d.get("seller_acct", null)
		)

	func _to_string() -> String:
		return "<Trade %s %d %s @ %d (buyer: %s, seller: %s)>" % [trade_id, qty, instrument, price, buyer_id, seller_id]
