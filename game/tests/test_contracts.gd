extends RefCounted
## Headless unit tests for timed station-to-station delivery contracts (#216):
## Contracts schema/fallback, seeded generation, accept_contract, fulfill_at_station,
## expire_overdue, to_dict/from_dict, and RunController + RunSave hash preservation.


static func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


static func _hash(rc: RunController) -> String:
	return RunSave.state_hash(rc, StationMarket.new(), Bags.new("t", null, 1))


func test_data_schema_catalog_and_fallback() -> String:
	Contracts.reset_cache()
	var data: Dictionary = Contracts.load_data()
	if int(data.get("version", 0)) != 1:
		return "expected schema version 1, got %s" % str(data.get("version"))
	var id_list: Array[String] = Contracts.ids()
	if id_list.size() < 5:
		return "expected curated contract templates in contracts.json, got %s" % str(id_list)
	for cid in id_list:
		var row: Dictionary = Contracts.entry(cid)
		var comm: String = str(row.get("commodity", ""))
		var orig: String = str(row.get("origin", ""))
		var dest: String = str(row.get("destination", ""))
		if not Transit.COMMODITIES.has(comm):
			return "template %s has invalid commodity %s" % [cid, comm]
		if not Transit.STATIONS.has(orig) or not Transit.STATIONS.has(dest) or orig == dest:
			return "template %s has invalid stations %s -> %s" % [cid, orig, dest]
		if int(row.get("qty", 0)) <= 0 or int(row.get("reward_cr", 0)) <= 0 or int(row.get("penalty_cr", 0)) <= 0:
			return "template %s missing positive qty/reward/penalty: %s" % [cid, str(row)]
		if Contracts.contract_name(cid) == "" or Contracts.contract_summary(cid) == "":
			return "template %s missing display name or summary" % cid
	var fb: Dictionary = Contracts.load_data("res://data/__nonexistent_contracts__.json")
	if not (fb.get("contracts") is Array) or (fb["contracts"] as Array).size() != id_list.size():
		return "fallback catalog size mismatch"
	if Contracts.cheapest_station_for("ORE") != "ceres" or Contracts.cheapest_station_for("FUEL") != "luna":
		return "cheapest_station_for disagreed with Transit.BASE_PRICES"
	return "ok"


func test_seeded_offer_generation_and_novice_penalty_schedule() -> String:
	var a := Contracts.new()
	var b := Contracts.new()
	var c := Contracts.new()
	for r in range(1, 17):
		var pa: Array[Dictionary] = a.post_round_offers(r, 84)
		var pb: Array[Dictionary] = b.post_round_offers(r, 84)
		c.post_round_offers(r, 7)
		if (r % Contracts.post_every_rounds()) == 0:
			if pa.size() != 1:
				return "expected 1 posted offer at cadence round %d, got %d" % [r, pa.size()]
		elif not pa.is_empty():
			return "unexpected offer posted on non-cadence round %d" % r
		if RunSave.canonical(pa) != RunSave.canonical(pb):
			return "seeded generation diverged at round %d" % r
	if RunSave.canonical(a.to_dict()) != RunSave.canonical(b.to_dict()):
		return "two identical seeds produced different contract boards"
	if RunSave.canonical(a.to_dict()) == RunSave.canonical(c.to_dict()):
		return "distinct seeds produced identical contract boards"
	for offer in a.available:
		if str(offer["origin"]) == str(offer["destination"]):
			return "generated offer must be station-to-station: %s" % str(offer)
		var expected_pen: int = Contracts.penalty_for_reward(int(offer["reward_cr"]), 0)
		if int(offer["penalty_cr"]) != expected_pen:
			return "fresh corp offer should use 25%% first_penalty_bps: got %d, want %d" % [int(offer["penalty_cr"]), expected_pen]
	# After one overdue lapse, newly generated offers step up to 50% penalty_bps.
	var d := Contracts.new()
	d.expired_count = 1
	var post_lapse: Dictionary = d.generate_offer(84, 4)
	var full_pen: int = Contracts.penalty_for_reward(int(post_lapse["reward_cr"]), 1)
	if int(post_lapse["penalty_cr"]) != full_pen or full_pen <= int(post_lapse["reward_cr"]) * Contracts.first_penalty_bps() / Contracts.BPS:
		return "post-lapse offer did not step up to 50%% penalty_bps: %s" % str(post_lapse)
	return "ok"


func test_accept_contract_validation_and_max_active_cap() -> String:
	var desk := Contracts.new()
	var offer: Dictionary = desk.post_from_template("ceres_earth_ore", 2)
	if offer.is_empty() or desk.available.size() != 1:
		return "post_from_template failed"
	if bool(desk.accept_contract("unknown_id", 2)["ok"]) or desk.accept_contract("unknown_id", 2)["reason"] != "NOT_FOUND":
		return "unknown id must fail with NOT_FOUND"
	var bad_same: Dictionary = {"commodity": "ORE", "qty": 40, "origin": "mars", "destination": "mars", "reward_cr": 800, "penalty_cr": 200, "deadline_round": 10}
	if desk.accept_contract(bad_same, 2)["reason"] != "INVALID_CONTRACT":
		return "same origin and destination must fail with INVALID_CONTRACT"
	var bad_comm: Dictionary = {"commodity": "UNOBTANIUM", "qty": 40, "origin": "mars", "destination": "earth", "reward_cr": 800, "penalty_cr": 200, "deadline_round": 10}
	if desk.accept_contract(bad_comm, 2)["reason"] != "INVALID_CONTRACT":
		return "unknown commodity must fail with INVALID_CONTRACT"
	var stale: Dictionary = Contracts.make_contract("ORE", 30, "ceres", "earth", 900, 225, 4, "stale_1")
	if desk.accept_contract(stale, 5)["reason"] != "EXPIRED":
		return "contract past deadline_round must fail with EXPIRED"
	if desk.accept_contract(offer["id"], 2, true)["reason"] != "RUN_OVER":
		return "run_over must refuse accept_contract with RUN_OVER"

	# Accept 1st contract by board offer ID: removes from available, adds to active.
	var r1: Dictionary = desk.accept_contract(offer["id"], 2)
	if not bool(r1["ok"]) or desk.available.size() != 0 or desk.active.size() != 1:
		return "accepting board offer failed: %s" % str(r1)
	if desk.accept_contract(offer["id"], 2)["reason"] != "ALREADY_ACTIVE":
		return "re-accepting active contract id must fail with ALREADY_ACTIVE"

	# Accept 2nd contract by direct Dictionary (commodity alias ORGANICS -> FOOD).
	var c2: Dictionary = {
		"id": "manual_food",
		"commodity": "ORGANICS",
		"qty": 40,
		"origin": "earth",
		"destination": "luna",
		"reward_cr": 1200,
		"penalty_cr": 300,
		"deadline_round": 9,
	}
	var r2: Dictionary = desk.accept_contract(c2, 3)
	if not bool(r2["ok"]) or str(r2["contract"]["commodity"]) != "FOOD" or desk.active.size() != 2:
		return "accepting 2nd contract dict failed: %s" % str(r2)

	# 3rd contract exceeds max_active() == 2.
	var c3: Dictionary = Contracts.make_contract("FUEL", 35, "luna", "mars", 1050, 260, 12, "manual_fuel")
	var r3: Dictionary = desk.accept_contract(c3, 3)
	if bool(r3["ok"]) or r3["reason"] != "MAX_ACTIVE" or desk.active.size() != 2:
		return "3rd active contract should be refused with MAX_ACTIVE: %s" % str(r3)
	return "ok"


func test_fulfill_at_station_full_and_partial_delivery() -> String:
	var desk := Contracts.new()
	var c1: Dictionary = Contracts.make_contract("ORE", 50, "ceres", "earth", 2000, 500, 10, "ore_earth")
	if not bool(desk.accept_contract(c1, 2)["ok"]):
		return "setup accept failed"

	var hold: Dictionary = {"ORE": 65, "FUEL": 10}
	# Wrong station: nothing fulfilled, cargo untouched.
	var wrong_st: Dictionary = desk.fulfill_at_station("ceres", hold, 4)
	if int(wrong_st["count"]) != 0 or int(hold["ORE"]) != 65:
		return "must not fulfill at origin station"

	# Insufficient cargo when allow_partial == false: nothing fulfilled, cargo untouched.
	var small_hold: Dictionary = {"ORE": 30}
	var short_res: Dictionary = desk.fulfill_at_station("earth", small_hold, 6, false)
	if int(short_res["count"]) != 0 or int(small_hold["ORE"]) != 30 or desk.active.size() != 1:
		return "partial hold must not fulfill when allow_partial is false"

	# Exact deadline round (round 10 <= deadline_round 10) still fulfills cleanly!
	var ok_res: Dictionary = desk.fulfill_at_station("earth", hold, 10)
	if int(ok_res["count"]) != 1 or int(ok_res["reward_cr"]) != 2000:
		return "expected full fulfillment on deadline round: %s" % str(ok_res)
	if int(hold.get("ORE", 0)) != 15 or int(hold.get("FUEL", 0)) != 10:
		return "cargo deduction wrong: %s" % str(hold)
	if not desk.active.is_empty() or desk.fulfilled_count != 1:
		return "fulfilled contract must leave active and bump fulfilled_count"

	# Exact cargo quantity erases key cleanly; oversized contract supports incremental allow_partial.
	var heavy: Dictionary = Contracts.make_contract("MACHINERY", 120, "mars", "luna", 3600, 900, 15, "heavy_luna", 1, Contracts.LOT_OVERSIZED)
	desk.accept_contract(heavy, 1)
	var trip1_hold: Dictionary = {"MACHINERY": 60}
	var part_res: Dictionary = desk.fulfill_at_station("luna", trip1_hold, 6, true)
	if int(part_res["count"]) != 0 or (part_res["partial"] as Array).size() != 1 or int(part_res["reward_cr"]) != 1800:
		return "partial trip 1 payout mismatch: %s" % str(part_res)
	if trip1_hold.has("MACHINERY") or int(desk.active[0]["qty_remaining"]) != 60:
		return "partial trip 1 should erase MACHINERY from hold and leave 60 remaining"
	var trip2_hold: Dictionary = {"MACHINERY": 60}
	var fin_res: Dictionary = desk.fulfill_at_station("luna", trip2_hold, 9, true)
	if int(fin_res["count"]) != 1 or int(fin_res["reward_cr"]) != 1800 or trip2_hold.has("MACHINERY"):
		return "partial trip 2 completion mismatch: %s" % str(fin_res)
	if not desk.active.is_empty() or desk.fulfilled_count != 2:
		return "oversized contract did not finish cleanly"
	return "ok"


func test_expire_overdue_prunes_offers_and_penalizes_overdue_active_only() -> String:
	var desk := Contracts.new()
	desk.post_offer(Contracts.make_contract("FUEL", 30, "luna", "mars", 900, 225, 7, "offer_r7"), 1)
	desk.accept_contract(Contracts.make_contract("FOOD", 40, "earth", "ceres", 1800, 450, 8, "act_r8"), 2)

	# Round 7: neither offer (deadline 7) nor active (deadline 8) is overdue.
	var r7: Dictionary = desk.expire_overdue(7)
	if int(r7["count"]) != 0 or not (r7["expired_offers"] as Array).is_empty() or int(r7["penalty_cr"]) != 0:
		return "nothing should expire on deadline round 7: %s" % str(r7)

	# Round 8: unaccepted offer expires with 0 penalty; active contract on its deadline round stays open.
	var r8: Dictionary = desk.expire_overdue(8)
	if int(r8["count"]) != 0 or int(r8["penalty_cr"]) != 0 or (r8["expired_offers"] as Array) != ["offer_r7"]:
		return "round 8 should prune offer_r7 with zero penalty: %s" % str(r8)
	if desk.available.size() != 0 or desk.active.size() != 1:
		return "round 8 state wrong"

	# Round 9: active contract is now overdue (8 < 9) and incurs 450 CR penalty.
	var r9: Dictionary = desk.expire_overdue(9)
	if int(r9["count"]) != 1 or int(r9["penalty_cr"]) != 450:
		return "round 9 should expire act_r8 for 450 CR penalty: %s" % str(r9)
	if not desk.active.is_empty() or desk.expired_count != 1:
		return "overdue contract was not cleared or counted"
	return "ok"


func test_to_dict_from_dict_json_roundtrip_and_tamper_sanitisation() -> String:
	var desk := Contracts.new()
	desk.post_from_template("luna_ceres_fuel", 4)
	desk.accept_contract(Contracts.make_contract("ORE", 50, "ceres", "earth", 1950, 487, 12, "c_ore"), 4)
	desk.fulfilled_count = 2
	desk.expired_count = 1
	var snap: Dictionary = desk.to_dict()
	var restored: Contracts = Contracts.from_dict(_json(snap))
	if RunSave.canonical(restored.to_dict()) != RunSave.canonical(snap):
		return "JSON roundtrip altered Contracts dict: %s vs %s" % [str(restored.to_dict()), str(snap)]

	# Tampered input: non-dict, bogus commodities, duplicate IDs, > max_active entries, negative counters.
	if not Contracts.from_dict(null).is_empty() or not Contracts.from_dict("corrupt").is_empty():
		return "non-dictionary input must yield empty Contracts"
	var tampered: Contracts = Contracts.from_dict({
		"fulfilled_count": -9,
		"expired_count": -3,
		"next_seq": -10,
		"active": [
			"not_a_dict",
			{"id": "bad_st", "commodity": "ORE", "qty": 20, "origin": "earth", "destination": "earth", "reward_cr": 100, "deadline_round": 5},
			{"id": "dup", "commodity": "ORE", "qty": 30.0, "origin": "ceres", "destination": "earth", "reward_cr": 900.0, "penalty_cr": 200.0, "deadline_round": 10.0},
			{"id": "dup", "commodity": "FUEL", "qty": 25, "origin": "luna", "destination": "mars", "reward_cr": 600, "penalty_cr": 150, "deadline_round": 11},
			{"id": "extra_3", "commodity": "FOOD", "qty": 25, "origin": "earth", "destination": "luna", "reward_cr": 500, "penalty_cr": 125, "deadline_round": 11},
		],
		"available": [
			{"id": "dup", "commodity": "FRAG", "qty": 20, "origin": "ceres", "destination": "earth", "reward_cr": 400, "deadline_round": 9},
			{"id": "ok_offer", "commodity": "FRAG", "qty": 20, "origin": "ceres", "destination": "earth", "reward_cr": 400, "deadline_round": 9},
		],
	})
	if tampered.fulfilled_count != 0 or tampered.expired_count != 0 or tampered.next_seq < 1:
		return "negative counters were not clamped"
	if tampered.active.size() != Contracts.max_active():
		return "active contracts were not clamped to max_active: %d" % tampered.active.size()
	if str(tampered.active[0]["id"]) == str(tampered.active[1]["id"]):
		return "duplicate active contract IDs were not disambiguated"
	if tampered.available.size() != 1 or str(tampered.available[0]["id"]) != "ok_offer":
		return "available offer with colliding active ID was not dropped: %s" % str(tampered.available)
	return "ok"


func test_run_controller_and_run_save_hash_invariance_fulfillment_expiry_and_bankruptcy() -> String:
	var tpr: int = 4
	var bare := RunController.new(null, 216, DoomsdayClock.new(36000, 0, 0, 100), {}, tpr)
	var empty_attached := RunController.new(null, 216, DoomsdayClock.new(36000, 0, 0, 100), {}, tpr)
	empty_attached.attach_contracts()

	var cap_bare: Dictionary = RunSave.capture(bare, StationMarket.new(), Bags.new("t", null, 1))
	var cap_empty: Dictionary = RunSave.capture(empty_attached, StationMarket.new(), Bags.new("t", null, 1))
	if cap_bare.has("contracts") or cap_empty.has("contracts"):
		return "RunSave.capture must omit contracts when null or empty"
	if _hash(bare) != _hash(empty_attached):
		return "attaching empty Contracts changed RunSave.state_hash"

	# Refused accept on bare controller must not allocate contracts.
	if bool(bare.accept_contract("missing")["ok"]) or bare.contracts != null:
		return "failed accept_contract on bare controller must leave contracts null"

	var accepted_ev: Array = []
	var fulfilled_ev: Array = []
	var expired_ev: Array = []
	bare.contract_accepted.connect(func(c: Dictionary): accepted_ev.append(c["id"]))
	bare.contract_fulfilled.connect(func(c: Dictionary, pay: int): fulfilled_ev.append({"id": c["id"], "pay": pay}))
	bare.contract_expired.connect(func(c: Dictionary, pen: int): expired_ev.append({"id": c["id"], "pen": pen}))

	# Accept 2 contracts: one to fulfill at luna, one to let expire with shortfall debt.
	var k_luna: Dictionary = Contracts.make_contract("FOOD", 40, "earth", "luna", 1400, 350, 6, "k_luna")
	var k_late: Dictionary = Contracts.make_contract("ORE", 50, "ceres", "mars", 2000, 1500, 3, "k_late")
	if not bool(bare.accept_contract(k_luna)["ok"]) or not bool(bare.accept_contract(k_late)["ok"]):
		return "controller accept_contract failed"
	if accepted_ev != ["k_luna", "k_late"]:
		return "contract_accepted signals mismatch: %s" % str(accepted_ev)

	# Active contracts appear in RunSave.capture and roundtrip identically through JSON.
	var cap_active: Dictionary = RunSave.capture(bare, StationMarket.new(), Bags.new("t", null, 1))
	if not cap_active.has("contracts"):
		return "RunSave.capture missing contracts key when active"
	var hash_before: String = _hash(bare)
	var restored_res: Dictionary = RunSave.restore(_json(cap_active))
	if not bool(restored_res["ok"]):
		return "RunSave.restore failed: %s" % str(restored_res["error"])
	var restored_rc: RunController = restored_res["controller"]
	if restored_rc.contracts == null or restored_rc.contracts.active.size() != 2 or _hash(restored_rc) != hash_before:
		return "RunSave roundtrip did not preserve contracts and state_hash"

	# Dock at luna with 45 FOOD and fulfill k_luna.
	bare.docked_at = "luna"
	bare.cargo["FOOD"] = 45
	var cr_before_fulfill: int = bare.cr
	var ful_res: Dictionary = bare.fulfill_at_station()
	if int(ful_res["count"]) != 1 or bare.cr != cr_before_fulfill + 1400 or int(bare.cargo.get("FOOD", 0)) != 5:
		return "controller fulfill_at_station failed: %s" % str(ful_res)
	if fulfilled_ev.size() != 1 or fulfilled_ev[0]["id"] != "k_luna" or int(fulfilled_ev[0]["pay"]) != 1400:
		return "contract_fulfilled signal mismatch: %s" % str(fulfilled_ev)

	# Set cr = 600 and step past round 3 (to round 4) so k_late (penalty 1500) expires automatically:
	# 600 CR paid from cash, 900 CR added as shortfall to doomsday.principal_debt.
	bare.cr = 600
	var debt_before: int = bare.doomsday.principal_debt
	var guard: int = 0
	while bare.get_current_round() < 4 and guard < 200:
		bare.sim_clock.paused = false
		bare.advance(bare.sim_clock.tick_delta + 0.0001)
		guard += 1
	if bare.get_current_round() < 4:
		return "clock did not reach round 4"
	if expired_ev.size() != 1 or expired_ev[0]["id"] != "k_late" or int(expired_ev[0]["pen"]) != 1500:
		return "overdue contract did not auto-expire on round advance: %s" % str(expired_ev)
	if bare.cr != 0 or bare.doomsday.principal_debt != debt_before + 900:
		return "shortfall penalty split wrong: cr=%d debt_delta=%d" % [bare.cr, bare.doomsday.principal_debt - debt_before]

	# Accept another contract, go insolvent, file Chapter 11 -> contracts reset for the new corp.
	bare.accept_contract(Contracts.make_contract("FUEL", 30, "luna", "ceres", 1200, 600, 20, "k_ch11"))
	bare.doomsday.add_principal(500000)
	bare.cr = 0
	if bare.file_bankruptcy().is_empty():
		return "expected Chapter 11 filing to succeed"
	if bare.contracts != null and bare.contracts.has_any():
		return "Chapter 11 filing must clear failed corp contracts: %s" % str(bare.contracts.to_dict())
	if RunSave.capture(bare, StationMarket.new(), Bags.new("t", null, 1)).has("contracts"):
		return "after Chapter 11 reset, empty contracts must be omitted from RunSave"
	return "ok"
