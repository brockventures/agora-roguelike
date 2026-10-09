extends RefCounted
## Crisis deck (#12): data, tier / net-worth gating, deterministic draws, effect
## apply and revert, serialization. UI wiring lives in test_crisis_wiring.gd.

const STAGE_FOR_TIER: Dictionary = {"early": 0, "mid": 1, "endgame": 3}
const RICH: int = 20000
const MID_NW: int = 8000
const POOR: int = 1000


func _deck(p_seed: int = 11) -> CrisisDeck:
	return CrisisDeck.new(p_seed)


## Deck restricted to one crisis id with no grace period, then a forced draw.
func _force(deck: CrisisDeck, id: String, round_num: int = 3, nw: int = RICH) -> Dictionary:
	var only: Array = []
	for def in deck.data["crises"]:
		if def["id"] == id:
			only.append(def)
	deck.data["crises"] = only
	deck.data["grace_rounds"] = 0
	deck.bags.force("crisis", true)
	return deck.advance_round(round_num, int(STAGE_FOR_TIER[only[0]["tier"]]), nw)


func _snapshot(m: StationMarket) -> Array:
	var out: Array = []
	for key in m.books.keys():
		var parts: PackedStringArray = str(key).split(":")
		var l: Dictionary = m.ladder(parts[0], parts[1], 5)
		out.append([key, l["bids"], l["asks"]])
	out.sort_custom(func(a, b): return str(a[0]) < str(b[0]))
	return out


func test_data_file_is_well_formed() -> String:
	var d: Dictionary = CrisisDeck.load_data()
	if d.is_empty():
		return "crises.json did not load"
	var ids := {}
	for def in d["crises"]:
		if ids.has(def["id"]):
			return "duplicate id %s" % def["id"]
		ids[def["id"]] = true
		if not d["tiers"].has(def["tier"]):
			return "%s has unknown tier" % def["id"]
		if not (def["kind"] in ["shortage", "audit", "collapse"]):
			return "%s has unknown kind" % def["id"]
		if not (def.get("min_band", "low") in CrisisDeck.BAND_ORDER):
			return "%s has unknown band" % def["id"]
	for tier_id in CrisisDeck.TIER_ORDER:
		var any := false
		for def in d["crises"]:
			any = any or def["tier"] == tier_id
		if not any:
			return "tier %s has no crises" % tier_id
	return "ok"


func test_tiers_map_to_doomsday_stages() -> String:
	var deck := _deck()
	var want := {
		DoomsdayClock.Stage.NORMAL: "early", DoomsdayClock.Stage.UNSTABLE: "mid",
		DoomsdayClock.Stage.CRITICAL: "mid", DoomsdayClock.Stage.IMMINENT: "endgame",
		DoomsdayClock.Stage.COLLAPSED: "",
	}
	for stage in want:
		if deck.tier_for_stage(int(stage)) != want[stage]:
			return "stage %d -> '%s', want '%s'" % [stage, deck.tier_for_stage(int(stage)), want[stage]]
	return "ok"


func test_net_worth_bands() -> String:
	var deck := _deck()
	if deck.band_for(-5000) != "low" or deck.band_for(POOR) != "low":
		return "poor should be low"
	if deck.band_for(MID_NW) != "mid" or deck.band_for(6000) != "mid":
		return "mid band wrong"
	if deck.band_for(RICH) != "high" or deck.band_for(15000) != "high":
		return "high band wrong"
	return "ok"


func test_pool_gated_by_tier_and_net_worth() -> String:
	var deck := _deck()
	var ids := func(tier: String, band: String) -> Array:
		var out: Array = []
		for def in deck.eligible(tier, band):
			out.append(def["id"])
		return out
	if ids.call("early", "high") != ["localized_shortage"]:
		return "early pool wrong: %s" % str(ids.call("early", "high"))
	if "antitrust_audit" in ids.call("mid", "low"):
		return "a poor player must not draw the antitrust audit"
	if not ("antitrust_audit" in ids.call("mid", "mid")) or not ("antitrust_audit" in ids.call("mid", "high")):
		return "audit should be reachable from the mid band"
	if "emergency_antitrust_sweep" in ids.call("endgame", "mid"):
		return "the sweep is high-band only"
	if not ("emergency_antitrust_sweep" in ids.call("endgame", "high")):
		return "high band should reach the sweep"
	if ids.call("endgame", "low") != ["systemic_margin_collapse"]:
		return "endgame low pool wrong"
	if "localized_shortage" in ids.call("mid", "high") or "systemic_margin_collapse" in ids.call("mid", "high"):
		return "tiers must not bleed into each other"
	return "ok"


func test_odds_scale_with_net_worth_band() -> String:
	var deck := _deck()
	if not (deck.odds("mid", "high") > deck.odds("mid", "mid") and deck.odds("mid", "mid") > deck.odds("mid", "low")):
		return "mid-tier odds should rise with net worth"
	if absf(deck.odds("early", "low") - 0.15) > 1e-9:
		return "early base odds should be 0.15, got %f" % deck.odds("early", "low")
	return "ok"


func test_gating_by_stage_in_a_draw() -> String:
	# Forced hit: the drawn crisis always belongs to the tier of the stage.
	for stage in [0, 1, 2, 3]:
		var deck := _deck(5)
		deck.data["grace_rounds"] = 0
		deck.bags.force("crisis", true)
		var c: Dictionary = deck.advance_round(4, stage, RICH)
		if c.is_empty():
			return "no draw at stage %d" % stage
		if c["tier"] != deck.tier_for_stage(stage):
			return "stage %d drew tier %s" % [stage, c["tier"]]
	var dead := _deck(5)
	dead.data["grace_rounds"] = 0
	dead.bags.force("crisis", true)
	if not dead.advance_round(4, DoomsdayClock.Stage.COLLAPSED, RICH).is_empty():
		return "COLLAPSED must draw nothing"
	return "ok"


func test_poor_player_never_draws_audit() -> String:
	for s in range(40):
		var deck := _deck(s)
		deck.data["grace_rounds"] = 0
		deck.bags.force("crisis", true)
		var c: Dictionary = deck.advance_round(5, DoomsdayClock.Stage.UNSTABLE, POOR)
		if c.is_empty() or c["kind"] == "audit":
			return "seed %d: poor player drew %s" % [s, str(c.get("id", "nothing"))]
	return "ok"


func test_grace_rounds_and_one_draw_per_round() -> String:
	var deck := _deck()
	deck.bags.force("crisis", [true, true, true])
	if not deck.advance_round(1, 0, RICH).is_empty() or not deck.advance_round(2, 0, RICH).is_empty():
		return "no draws inside the grace rounds"
	var first: Dictionary = deck.advance_round(3, 0, RICH)
	if first.is_empty():
		return "round 3 should draw"
	if not deck.advance_round(3, 0, RICH).is_empty():
		return "a second advance of the same round must not draw"
	if deck.draw_count != 1:
		return "draw_count %d" % deck.draw_count
	return "ok"


func test_max_active_caps_concurrent_crises() -> String:
	var deck := _deck(2)
	deck.data["grace_rounds"] = 0
	deck.data["max_active"] = 1
	deck.bags.force("crisis", [true, true])
	deck.advance_round(3, 0, RICH)
	if not deck.advance_round(4, 0, RICH).is_empty():
		return "max_active 1 should block a second crisis"
	return "ok"


func test_deterministic_for_a_seed() -> String:
	var run := func(p_seed: int) -> Array:
		var deck := CrisisDeck.new(p_seed)
		var out: Array = []
		for r in range(1, 41):
			var stage: int = 0 if r < 10 else (1 if r < 24 else (2 if r < 34 else 3))
			var c: Dictionary = deck.advance_round(r, stage, 3000 + r * 500)
			if not c.is_empty():
				out.append([r, c["id"], c["station"], c["commodity"], c["rounds"], c["effects"]])
		return out
	var a: Array = run.call(77)
	if a.is_empty():
		return "40 rounds drew nothing; odds too low to test"
	if a != run.call(77):
		return "same seed diverged"
	var differs := false
	for s in [1, 2, 3, 4, 5, 6]:
		differs = differs or run.call(s) != a
	if not differs:
		return "different seeds all matched"
	return "ok"


func test_shortage_applies_and_reverts() -> String:
	var deck := _deck(3)
	var m := StationMarket.new()
	var fresh := StationMarket.new()
	var c: Dictionary = _force(deck, "localized_shortage", 3)
	if c.is_empty():
		return "no shortage drawn"
	if c["station"] != "mars" or not Transit.COMMODITIES.has(c["commodity"]):
		return "bad target %s/%s" % [c["station"], c["commodity"]]
	m.set_crisis_mods(deck.market_mods())
	var before: Dictionary = fresh.ladder("mars", c["commodity"], 5)
	var during: Dictionary = m.ladder("mars", c["commodity"], 5)
	if float(during["best_ask"]) <= float(before["best_ask"]):
		return "shortage should lift prices: %f vs %f" % [during["best_ask"], before["best_ask"]]
	if int(during["asks"][0]["quantity"]) >= int(before["asks"][0]["quantity"]):
		return "shortage should thin the book"
	# Other commodities and stations are untouched.
	var other: String = "FUEL" if c["commodity"] != "FUEL" else "ORE"
	if m.ladder("mars", other, 5) != fresh.ladder("mars", other, 5) or m.ladder("earth", c["commodity"], 5) != fresh.ladder("earth", c["commodity"], 5):
		return "shortage leaked beyond one station and commodity"
	# It survives the per-round replenish.
	m.replenish()
	if m.ladder("mars", c["commodity"], 5) != during:
		return "replenish dropped the shortage"
	# Expiry reverts the book exactly.
	var expire_round: int = int(c["expires_round"])
	deck.advance_round(expire_round, 0, RICH)
	if not deck.active.is_empty():
		return "crisis should have expired"
	m.set_crisis_mods(deck.market_mods())
	if _snapshot(m) != _snapshot(fresh):
		return "book did not revert to the unmodified state"
	return "ok"


func test_no_mods_leaves_books_untouched() -> String:
	var a := StationMarket.new()
	var b := StationMarket.new()
	b.set_crisis_mods([])
	if _snapshot(a) != _snapshot(b):
		return "empty mods changed a book"
	return "ok"


func test_audit_cap_fee_scale_and_revert() -> String:
	var rich := _deck(1)
	var c: Dictionary = _force(rich, "antitrust_audit", 3, RICH)
	var mid := _deck(1)
	var c2: Dictionary = _force(mid, "antitrust_audit", 3, MID_NW)
	if c.is_empty() or c2.is_empty():
		return "no audit drawn"
	if rich.order_cap() != 20:
		return "cap %d" % rich.order_cap()
	if rich.fee_bps() <= mid.fee_bps():
		return "fee should scale with net worth: %d vs %d" % [rich.fee_bps(), mid.fee_bps()]
	if rich.fee_for(1000) != (1000 * rich.fee_bps() + 9999) / 10000 or rich.fee_for(1) < 1:
		return "fee rounding wrong"
	if rich.fee_bps() > 400:
		return "fee exceeded the data cap"
	rich.advance_round(int(c["expires_round"]), 1, RICH)
	if rich.order_cap() != 0 or rich.fee_bps() != 0 or rich.fee_for(1000) != 0:
		return "audit did not revert"
	return "ok"


func test_collapse_widens_book_and_margin_call_follows_start() -> String:
	var deck := _deck(4)
	var m := StationMarket.new()
	var fresh := StationMarket.new()
	var c: Dictionary = _force(deck, "systemic_margin_collapse", 5, MID_NW)
	if c.is_empty():
		return "no collapse drawn"
	if deck.last_margin_call_bps != 0:
		return "no margin call on the round it starts"
	m.set_crisis_mods(deck.market_mods())
	for st in ["earth", "mars"]:
		for com in Transit.COMMODITIES:
			if float(m.ladder(st, com, 5)["spread"]) <= float(fresh.ladder(st, com, 5)["spread"]):
				return "spread not wider at %s %s" % [st, com]
	deck.advance_round(6, 3, MID_NW)
	if deck.last_margin_call_bps != 150:
		return "margin call bps %d" % deck.last_margin_call_bps
	deck.advance_round(int(c["expires_round"]), 3, MID_NW)
	if deck.last_margin_call_bps != 0 or deck.margin_call_bps() != 0:
		return "no margin call once expired"
	m.set_crisis_mods(deck.market_mods())
	if _snapshot(m) != _snapshot(fresh):
		return "collapse did not revert"
	return "ok"


func test_pending_ack_until_acknowledged() -> String:
	var deck := _deck()
	var c: Dictionary = _force(deck, "localized_shortage")
	if not deck.has_pending_ack() or deck.pending_crisis()["uid"] != c["uid"]:
		return "drawn crisis should be pending"
	deck.acknowledge()
	if deck.has_pending_ack():
		return "acknowledge should clear"
	return "ok"


func test_signals_fire() -> String:
	var deck := _deck()
	var seen := {"drawn": 0, "expired": 0, "changed": 0}
	deck.crisis_drawn.connect(func(_c): seen["drawn"] += 1)
	deck.crisis_expired.connect(func(_c): seen["expired"] += 1)
	deck.changed.connect(func(): seen["changed"] += 1)
	var c: Dictionary = _force(deck, "localized_shortage")
	deck.advance_round(int(c["expires_round"]), 0, RICH)
	if seen["drawn"] != 1 or seen["expired"] != 1 or seen["changed"] != 2:
		return "signal counts %s" % str(seen)
	return "ok"


func test_serialization_round_trip_through_json() -> String:
	var deck := _deck(21)
	var stage_for := func(r: int) -> int: return 0 if r < 10 else (1 if r < 24 else 3)
	for r in range(1, 19):
		deck.advance_round(r, stage_for.call(r), 3000 + r * 700)
	var text: String = JSON.stringify(deck.to_dict())
	var restored: CrisisDeck = CrisisDeck.from_dict(JSON.parse_string(text))
	if restored.to_dict() != deck.to_dict():
		return "round trip changed state"
	for r in range(19, 41):
		var a: Dictionary = deck.advance_round(r, stage_for.call(r), 3000 + r * 700)
		var b: Dictionary = restored.advance_round(r, stage_for.call(r), 3000 + r * 700)
		if a != b:
			return "round %d diverged after restore: %s vs %s" % [r, str(a), str(b)]
	if restored.to_dict() != deck.to_dict():
		return "final state diverged"
	if deck.draw_count == 0:
		return "scenario drew nothing"
	return "ok"


func test_round_trip_keeps_active_effects() -> String:
	var deck := _deck()
	_force(deck, "antitrust_audit", 3, RICH)
	var back: CrisisDeck = CrisisDeck.from_dict(JSON.parse_string(JSON.stringify(deck.to_dict())))
	if back.order_cap() != deck.order_cap() or back.fee_bps() != deck.fee_bps() or not back.has_pending_ack():
		return "active audit lost in the round trip"
	return "ok"
