extends RefCounted
## Station drydock ship upgrades UI & gamepad controls (#215):
## FleetView.upgrade_catalog, M0Loop.move_upgrade_cursor, and docked purchases on Tab.FLEET.


func _loop(p_seed: int = 215) -> Dictionary:
	var rc := RunController.new(null, p_seed)
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	return {"rc": rc, "hud": hud, "loop": lp}


func test_fleet_view_upgrade_catalog_and_cursor_clamping() -> String:
	if not FleetView.upgrade_catalog(null).is_empty():
		return "null controller must return an empty catalog"
	var rc := RunController.new(null, 7)
	var snap_before: Dictionary = rc.to_dict()
	var cat: Array[Dictionary] = FleetView.upgrade_catalog(rc)
	var expected_ids: Array[String] = Upgrades.ids()
	if cat.size() != expected_ids.size() or cat.is_empty():
		return "catalog size mismatch: got %d, wanted %d" % [cat.size(), expected_ids.size()]
	for i in expected_ids.size():
		if str(cat[i].get("id", "")) != expected_ids[i]:
			return "catalog entry %d id mismatch: %s vs %s" % [i, str(cat[i]), expected_ids[i]]
		if int(cat[i].get("current_tier", -1)) != 0:
			return "fresh run must start at tier 0: %s" % str(cat[i])
	# Thrusters tier 1 unlocks at round 10; cargo_hold, bulkheads, transponders unlock at round 0.
	if bool(cat[0].get("locked", true)) or not bool(cat[2].get("locked", false)):
		return "round 0 lock flags wrong: cargo_hold=%s thrusters=%s" % [str(cat[0]), str(cat[2])]
	if rc.upgrades != null or rc.to_dict() != snap_before:
		return "reading upgrade_catalog must not allocate upgrades or mutate save state"
	# Advance to round 10 and verify thrusters unlocks in catalog.
	rc.sim_clock.total_ticks = 10 * rc.ticks_per_round
	var cat_r10: Array[Dictionary] = FleetView.upgrade_catalog(rc)
	if bool(cat_r10[2].get("locked", true)):
		return "thrusters should unlock at round 10: %s" % str(cat_r10[2])
	var last_idx: int = expected_ids.size() - 1
	if FleetView.step_upgrade_cursor(0, -1) != 0:
		return "step_upgrade_cursor must clamp at 0"
	if FleetView.step_upgrade_cursor(0, 1) != 1:
		return "step_upgrade_cursor(0, 1) expected 1"
	if FleetView.step_upgrade_cursor(last_idx, 1) != last_idx:
		return "step_upgrade_cursor must clamp at max index"
	if FleetView.step_upgrade_cursor(99, 0) != last_idx:
		return "out-of-range cursor must clamp into catalog"
	return "ok"


func test_m0_loop_move_upgrade_cursor_on_fleet_tab_via_handle_action() -> String:
	var ctx := _loop()
	var lp: M0Loop = ctx["loop"]
	var hud: OrbitalHUD = ctx["hud"]
	var expected_ids: Array[String] = Upgrades.ids()
	if lp.selected_upgrade_id() != expected_ids[0] or lp.upgrade_cursor != 0:
		return "initial selected_upgrade_id expected %s, got %s" % [expected_ids[0], lp.selected_upgrade_id()]
	# On Tab.MAP, ACT_LEFT and ACT_RIGHT must not move upgrade_cursor.
	if lp.handle_action(M0Loop.ACT_RIGHT) or lp.upgrade_cursor != 0:
		return "ACT_RIGHT must stay inert on Tab.MAP"
	lp.set_tab(M0Loop.Tab.FLEET)
	var handled_actions: Array[String] = []
	lp.action_handled.connect(func(act: String): handled_actions.append(act))
	var heard: Array = []
	hud.tactile_audio.sound_played.connect(func(id, _bus, _db, _pitch): heard.append(id))
	hud.tactile_audio.advance_time(1.0)
	if lp.handle_action(M0Loop.ACT_LEFT) or lp.upgrade_cursor != 0 or not handled_actions.is_empty():
		return "ACT_LEFT at index 0 must be a no-op"
	if not lp.handle_action(M0Loop.ACT_RIGHT) or lp.upgrade_cursor != 1 or lp.selected_upgrade_id() != expected_ids[1]:
		return "ACT_RIGHT should select %s, got %s" % [expected_ids[1], lp.selected_upgrade_id()]
	if handled_actions.size() != 1 or handled_actions[0] != M0Loop.ACT_RIGHT or heard.size() != 1:
		return "ACT_RIGHT should emit action_handled and click once: %s / %s" % [str(handled_actions), str(heard)]
	# Walk to the end and verify clamping.
	while lp.move_upgrade_cursor(1):
		pass
	if lp.upgrade_cursor != expected_ids.size() - 1:
		return "cursor did not reach last upgrade"
	if lp.handle_action(M0Loop.ACT_RIGHT):
		return "ACT_RIGHT at last upgrade must be a no-op"
	if not lp.handle_action(M0Loop.ACT_LEFT) or lp.upgrade_cursor != expected_ids.size() - 2:
		return "ACT_LEFT should step back one upgrade"
	return "ok"


func test_m0_loop_buy_selected_upgrade_docked_via_handle_action() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	rc.cr = 20000
	var base_cap: int = rc.cargo_capacity
	var purchased_events: Array = []
	rc.upgrade_purchased.connect(func(id: String, tier: int, price: int):
		purchased_events.append({"id": id, "tier": tier, "price": price})
	)
	var handled_actions: Array[String] = []
	lp.action_handled.connect(func(act: String): handled_actions.append(act))
	# Cannot buy upgrades directly unless on Tab.FLEET.
	if lp.buy_selected_upgrade():
		return "buy_selected_upgrade must refuse when not on Tab.FLEET"
	lp.set_tab(M0Loop.Tab.FLEET)
	# Index 0 is cargo_hold (T1 price 2500, unlock round 0, +50 capacity).
	var expected_price: int = Upgrades.price_for_tier(Upgrades.ID_CARGO_HOLD, 1)
	var expected_bonus: int = Upgrades.cargo_bonus_for_tier(1)
	if not lp.handle_action(M0Loop.ACT_SUBMIT):
		return "ACT_SUBMIT on Tab.FLEET while docked should purchase cargo_hold T1"
	if rc.cr != 20000 - expected_price:
		return "expected cr %d after purchase, got %d" % [20000 - expected_price, rc.cr]
	if rc.cargo_capacity != base_cap + expected_bonus:
		return "expected cargo_capacity %d, got %d" % [base_cap + expected_bonus, rc.cargo_capacity]
	if rc.upgrades == null or rc.upgrades.tier(Upgrades.ID_CARGO_HOLD) != 1:
		return "upgrades state did not record cargo_hold tier 1"
	if int(rc.ships[0].get("hull_value_cr", 0)) != expected_price:
		return "upgrade price should capitalize into hull_value_cr, got %s" % str(rc.ships[0])
	if purchased_events.size() != 1 or purchased_events[0]["id"] != Upgrades.ID_CARGO_HOLD or purchased_events[0]["tier"] != 1:
		return "upgrade_purchased signal mismatch: %s" % str(purchased_events)
	if not handled_actions.has(M0Loop.ACT_SUBMIT):
		return "ACT_SUBMIT was not emitted on action_handled"
	# Tier 2 of cargo_hold unlocks at round 30: immediate second press at round 0 must refuse.
	if lp.handle_action(M0Loop.ACT_SUBMIT) or rc.cr != 20000 - expected_price:
		return "locked tier 2 must not be purchasable at round 0"
	var cat: Array[Dictionary] = FleetView.upgrade_catalog(rc)
	if int(cat[0].get("current_tier", 0)) != 1 or not bool(cat[0].get("locked", false)):
		return "catalog should show cargo_hold at tier 1 with tier 2 locked: %s" % str(cat[0])
	return "ok"


func test_m0_loop_upgrade_purchase_guards_locked_funds_transit_and_bankruptcy() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	lp.set_tab(M0Loop.Tab.FLEET)
	# Move to thrusters (index 2, unlock round 10): refused at round 0.
	lp.handle_action(M0Loop.ACT_RIGHT)
	lp.handle_action(M0Loop.ACT_RIGHT)
	if lp.selected_upgrade_id() != Upgrades.ID_THRUSTERS:
		return "expected thrusters at cursor 2, got %s" % lp.selected_upgrade_id()
	if lp.handle_action(M0Loop.ACT_SUBMIT) or rc.upgrades != null:
		return "locked thrusters must be refused at round 0 without allocating upgrades"
	# Move back to bulkheads (index 1, price 3000) with insufficient CR.
	lp.handle_action(M0Loop.ACT_LEFT)
	rc.cr = 500
	if lp.handle_action(M0Loop.ACT_SUBMIT) or rc.upgrades != null:
		return "insufficient CR must refuse upgrade purchase"
	# Fund CR, depart into transit, and verify drydock purchases are refused mid-flight.
	rc.cr = 50000
	var dest: String = "ceres" if rc.docked_at != "ceres" else "earth"
	if not bool(rc.depart(dest).get("ok", false)) or not rc.is_in_transit():
		return "failed to depart for transit guard test"
	var cr_in_flight: int = rc.cr
	if lp.handle_action(M0Loop.ACT_SUBMIT) or rc.cr != cr_in_flight:
		return "cannot fit drydock upgrades while in transit"
	# Complete voyage so ship docks, then buy cargo_hold T1 and verify Chapter 11 resets upgrades.
	var arrive_tick: int = int(rc.transit.get("arrive_tick", 0))
	while rc.is_in_transit() and rc.sim_clock.total_ticks <= arrive_tick + rc.ticks_per_round:
		rc.sim_clock.paused = false
		rc.advance(1.0)
	if rc.is_in_transit():
		return "ship did not arrive at destination"
	lp.handle_action(M0Loop.ACT_LEFT)
	if lp.selected_upgrade_id() != Upgrades.ID_CARGO_HOLD or not lp.handle_action(M0Loop.ACT_SUBMIT):
		return "docked purchase of cargo_hold should succeed after arrival"
	if rc.cargo_capacity != RunController.DEFAULT_CARGO_CAPACITY + Upgrades.cargo_bonus_for_tier(1):
		return "cargo_capacity did not increase after buying cargo_hold"
	rc.doomsday.add_principal(500000)
	var report: Dictionary = lp.file_chapter_11()
	if report.is_empty():
		return "expected Chapter 11 filing to succeed when insolvent"
	if rc.upgrades != null and rc.upgrades.has_any():
		return "Chapter 11 filing must forfeit fitted upgrades"
	if rc.cargo_capacity != RunController.DEFAULT_CARGO_CAPACITY:
		return "Chapter 11 filing must reset cargo_capacity to default, got %d" % rc.cargo_capacity
	return "ok"
