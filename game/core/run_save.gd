class_name RunSave
extends RefCounted
## Complete run state as one JSON-safe Dictionary, plus a stable hash of it (#35).
##
## Composed from the components' own to_dict()/from_dict():
##   controller  RunController (ledger CR, cargo, ships, sim clock, doomsday
##               clock, profile copy, perk modifiers, bankruptcy bookkeeping)
##   market      StationMarket (every resting order book)
##   crisis      CrisisDeck (#12): active crises with their expiry rounds, the
##               unacknowledged list, and the deck's Bags/draw counters. Present
##               only when the controller carries a deck.
##   world       Barons (Epic 3): every baron's state. Present only when the
##               controller carries a world, so a run without barons hashes as before.
##   bags        Bags (streak counters, drawn/remaining marbles, forced queue),
##               so bad-luck protection is never wiped by a save/load cycle
##
## state_hash() hashes the canonical JSON form of that Dictionary. It is what
## seeded replays compare, so it must not depend on Dictionary insertion order
## or on whether a number passed through JSON (ints come back as floats).


static func capture(controller: RunController, market: StationMarket, bags: Bags) -> Dictionary:
	var out: Dictionary = {
		"controller": controller.to_dict(),
		"market": market.to_dict() if market != null else {},
		"bags": bags.to_dict() if bags != null else {},
	}
	if controller.crisis_deck != null:
		out["crisis"] = controller.crisis_deck.to_dict()
	if controller.world != null:
		out["world"] = controller.world.to_dict()
	return out


## Rebuilds the objects from capture() output (directly or via JSON).
## Returns {"ok", "error", "controller", "market", "bags"}.
static func restore(data: Dictionary) -> Dictionary:
	for key in ["controller", "market", "bags"]:
		if not (data.get(key, null) is Dictionary):
			return {"ok": false, "error": "corrupt: missing '%s'" % key}
	var bags := Bags.new()
	bags.from_dict(data["bags"])
	var rc: RunController = RunController.from_dict(data["controller"])
	var mkt: StationMarket = StationMarket.from_dict(data["market"])
	var cd = data.get("crisis", null)
	if cd is Dictionary:
		rc.crisis_deck = CrisisDeck.from_dict(cd)
		# Books were saved already shaped by the active crises: restore the
		# modifiers without reseeding them.
		mkt.crisis_mods = rc.crisis_deck.market_mods()
	var wd = data.get("world", null)
	if wd is Dictionary:
		rc.world = Barons.from_dict(wd)
		# Like crisis_mods: the saved books are already made by their barons, so
		# wire the world in without reseeding.
		mkt.world = rc.world
		mkt.world_mods = rc.world.market_mods()
	return {
		"ok": true,
		"error": "",
		"controller": rc,
		"market": mkt,
		"bags": bags,
	}


static func state_hash(controller: RunController, market: StationMarket, bags: Bags) -> String:
	return hash_dict(capture(controller, market, bags))


static func hash_dict(d: Dictionary) -> String:
	return canonical(d).sha256_text()


## Deterministic text form: sorted dictionary keys, integral floats written as
## ints (so 5 and 5.0 hash alike), no whitespace.
static func canonical(v: Variant) -> String:
	match typeof(v):
		TYPE_DICTIONARY:
			var keys: Array = (v as Dictionary).keys()
			keys.sort_custom(func(a, b): return str(a) < str(b))
			var parts: PackedStringArray = []
			for k in keys:
				parts.append("%s:%s" % [JSON.stringify(str(k)), canonical(v[k])])
			return "{" + ",".join(parts) + "}"
		TYPE_ARRAY:
			var items: PackedStringArray = []
			for e in v:
				items.append(canonical(e))
			return "[" + ",".join(items) + "]"
		TYPE_FLOAT:
			var f: float = v
			if is_finite(f) and f == floorf(f) and absf(f) < 9.0e15:
				return str(int(f))
			return str(f)
		TYPE_STRING, TYPE_STRING_NAME:
			return JSON.stringify(str(v))
		TYPE_NIL:
			return "null"
		TYPE_BOOL, TYPE_INT:
			return str(v)
		_:
			return JSON.stringify(str(v))
