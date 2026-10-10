extends RefCounted
## StationMarket serialisation order (Epic 3 task 1, fix for a quirk found in PR #112
## "feat(epic3): travel loop between stations"): books are saved and refilled in
## canonical (sorted) order, so a JSON save/load cannot change which resting order
## gets which id, and the raw market hash survives a save.

const FRAME: float = 1.0 / 60.0 + 0.0001


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


## Earth and Mars seeded, then Ceres and Luna unlocked: insertion order is then
## deliberately NOT sorted order (ceres and luna sort before mars).
func _travelled_market() -> StationMarket:
	var m := StationMarket.new()
	m.unlock_station("ceres")
	m.unlock_station("luna")
	return m


func test_to_dict_lists_books_in_sorted_order() -> String:
	var keys: Array = _travelled_market().to_dict()["books"].keys()
	var sorted_keys: Array = ["ceres:FRAG", "ceres:FUEL", "ceres:FOOD", "ceres:ORE", "ceres:MACHINERY"]
	if keys.slice(0, 5) != sorted_keys:
		return "books not saved station-first in canonical order: %s" % str(keys.slice(0, 6))
	var stations: Array = []
	for k in keys:
		var st: String = str(k).split(":")[0]
		if stations.is_empty() or stations[-1] != st:
			stations.append(st)
	if stations != ["ceres", "earth", "luna", "mars"]:
		return "stations out of order: %s" % str(stations)
	return "ok"


func test_json_round_trip_then_refills_matches_an_uninterrupted_market() -> String:
	var a := _travelled_market()
	var b := StationMarket.from_dict(_json(a.to_dict()))
	if RunSave.canonical(a.to_dict()) != RunSave.canonical(b.to_dict()):
		return "market changed across the JSON round trip"
	for i in 4:
		# Some trading so the refills have something to replace, then a round boundary.
		a.execute("mars", "ORE", "BUY", 20, 99.0)
		b.execute("mars", "ORE", "BUY", 20, 99.0)
		a.replenish()
		b.replenish()
		if RunSave.canonical(a.to_dict()) != RunSave.canonical(b.to_dict()):
			return "markets diverged after refill %d" % (i + 1)
	return "ok"


func test_restored_dictionary_order_is_canonical_whatever_the_file_order() -> String:
	var d: Dictionary = _travelled_market().to_dict()
	var shuffled: Dictionary = {}
	var keys: Array = d["books"].keys()
	keys.reverse()
	for k in keys:
		shuffled[k] = d["books"][k]
	d["books"] = shuffled
	var m := StationMarket.from_dict(d)
	var want: Array = _travelled_market().to_dict()["books"].keys()
	if m.books.keys() != want:
		return "restored books in file order, not canonical order"
	return "ok"


func test_crisis_mod_changes_reseed_in_canonical_order() -> String:
	var a := _travelled_market()
	var b := StationMarket.from_dict(_json(a.to_dict()))
	var mods := [{"station": "*", "commodity": "*", "depth_bps": 5000, "price_bps": 0, "spread_bps": 10000}]
	a.set_crisis_mods(mods)
	b.set_crisis_mods(mods)
	if RunSave.canonical(a.to_dict()) != RunSave.canonical(b.to_dict()):
		return "set_crisis_mods reseeded in an order that depends on the save"
	return "ok"


## save -> load -> continue N ticks gives the same market hash as never stopping,
## with a real loop (crisis deck, round boundaries) over a market that has travelled.
func test_save_load_continue_gives_the_same_market_hash() -> String:
	var ctxs: Array = []
	for i in 2:
		var rc := RunController.new(null, 55, null, {}, 30)
		var lp := M0Loop.new(OrbitalHUD.new(rc))
		lp.dock_at("mars")
		lp.market.unlock_station("ceres")
		lp.market.unlock_station("luna")
		ctxs.append({"rc": rc, "loop": lp})
	for ctx in ctxs:
		_run(ctx["loop"], ctx["rc"], 100)
	var bags_a := Bags.new("m0", null, 55)
	var loaded: Dictionary = RunSave.restore(_json(RunSave.capture(ctxs[0]["rc"], ctxs[0]["loop"].market, bags_a)))
	if not bool(loaded["ok"]):
		return "restore failed: %s" % loaded["error"]
	var rc_a: RunController = loaded["controller"]
	var lp_a := M0Loop.new(OrbitalHUD.new(rc_a))
	lp_a.set_market(loaded["market"])
	var rc_b: RunController = ctxs[1]["rc"]
	var lp_b: M0Loop = ctxs[1]["loop"]
	_run(lp_a, rc_a, 300)
	_run(lp_b, rc_b, 300)
	if rc_a.sim_clock.total_ticks != rc_b.sim_clock.total_ticks:
		return "tick counts differ: %d vs %d" % [rc_a.sim_clock.total_ticks, rc_b.sim_clock.total_ticks]
	var ha: String = RunSave.hash_dict(lp_a.market.to_dict())
	var hb: String = RunSave.hash_dict(lp_b.market.to_dict())
	if ha != hb:
		return "market hash differs after save/load/continue: %s vs %s" % [ha, hb]
	if lp_b.market.to_dict()["order_counter"] < 100:
		return "the run barely refilled; the test proves nothing"
	return "ok"


func _run(lp: M0Loop, rc: RunController, n: int) -> void:
	var target: int = rc.sim_clock.total_ticks + n
	var guard: int = n * 4 + 100
	while rc.sim_clock.total_ticks < target and guard > 0:
		guard -= 1
		if lp.overlay_state == M0Loop.OVERLAY_CRISIS:
			lp.acknowledge_crisis()
		elif lp.overlay_state == M0Loop.OVERLAY_CONTRACT:
			lp.decline_contract()
		lp.advance(FRAME)
