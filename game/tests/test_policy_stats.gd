extends RefCounted
## #160 PR 2 (Three new stats): toll_discount_bps, assumed_debt_bps and severance_bps are live
## stats, each read from the effective RunController.modifiers (docs/design/corporate-policies.md
## section 5.2). With the stat absent every consumer is byte-identical to before.

const TPR: int = 30
const ARES := "ares_heavy"

func _mods(stat: String, add: int, mul: int) -> Dictionary:
	return {stat: {"add": add, "mul_bps": mul}}

func _rc(cr: int = 1000) -> RunController:
	var rc := RunController.new(null, 21, null, {}, TPR)
	rc.world = Barons.for_new_run()
	rc.cr = cr
	rc.sim_clock.total_ticks = 0
	return rc

func test_the_three_stats_are_live_and_nothing_is_pending() -> String:
	for s in ["toll_discount_bps", "assumed_debt_bps", "severance_bps"]:
		if Parachutes.STATS.get(s, "") != "live":
			return "%s is not live" % s
	for s in Parachutes.STATS:
		if Parachutes.STATS[s] != "live":
			return "%s is %s" % [s, Parachutes.STATS[s]]
	if not Parachutes.load_policies().validate().is_empty():
		return "policies.json no longer validates"
	return "ok"

# --- toll_discount_bps ---

func test_belt_toll_scales_and_truncates() -> String:
	if Transit.calculate_toll("ceres", "mars", 0.0, 0) != 25 or Transit.calculate_toll("ceres", "mars") != 25:
		return "absent discount changed the toll"
	if Transit.calculate_toll("ceres", "mars", 0.0, 2000) != 20:
		return "20%% off 25 should be 20, got %d" % Transit.calculate_toll("ceres", "mars", 0.0, 2000)
	# 25 * 6667 / 10000 = 16.67 -> 16 (truncates in the player's favour)
	if Transit.calculate_toll("ceres", "mars", 0.0, 3333) != 16:
		return "33.33%% off 25 should truncate to 16, got %d" % Transit.calculate_toll("ceres", "mars", 0.0, 3333)
	if Transit.calculate_toll("ceres", "mars", 0.0, 10000) != 0 or Transit.calculate_toll("ceres", "mars", 0.0, 25000) != 0:
		return "a full or over-full discount should be free"
	if Transit.calculate_toll("earth", "mars", 0.0, 5000) != 0:
		return "a non-belt route stays 0"
	# The float discount still applies first, then the bps one.
	if Transit.calculate_toll("ceres", "mars", 0.20, 5000) != 10:
		return "float then bps: %d" % Transit.calculate_toll("ceres", "mars", 0.20, 5000)
	return "ok"

func test_can_depart_and_depart_charge_the_discounted_belt_toll() -> String:
	var rc := _rc()
	if int(rc.can_depart("ceres")["toll"]) != 25:
		return "baseline toll changed"
	rc.modifiers = _mods("toll_discount_bps", 3333, 10000)
	if rc.toll_discount_bps() != 3333:
		return "toll_discount_bps() = %d" % rc.toll_discount_bps()
	if int(rc.can_depart("ceres")["toll"]) != 16:
		return "can_depart toll %d, want 16" % int(rc.can_depart("ceres")["toll"])
	rc.depart("ceres")
	if rc.cr != 984:
		return "cr %d after departing, want 984" % rc.cr
	return "ok"

func test_discount_is_clamped_to_zero_and_full() -> String:
	var rc := _rc()
	rc.modifiers = _mods("toll_discount_bps", -500, 10000)
	if rc.toll_discount_bps() != 0 or int(rc.can_depart("ceres")["toll"]) != 25:
		return "a negative discount must clamp to 0"
	rc.modifiers = _mods("toll_discount_bps", 10000, 12000)
	if rc.toll_discount_bps() != 10000 or int(rc.can_depart("ceres")["toll"]) != 0:
		return "an over-full discount must clamp to free"
	return "ok"

func _dock_toll(mods: Dictionary, cr: int) -> Array:
	var rc := _rc(cr)
	rc.modifiers = mods
	rc.depart("mars")
	var after_depart: int = rc.cr
	rc._arrive()
	return [after_depart - rc.cr, rc.docked_at]

func test_docking_toll_scales_truncates_and_caps_at_cr() -> String:
	var base := _dock_toll({}, 1000)
	if base[1] != "mars" or base[0] != 15:
		return "baseline docking toll %s" % str(base)
	# 15 * 6667 / 10000 = 10.0005 -> 10
	var third := _dock_toll(_mods("toll_discount_bps", 3333, 10000), 1000)
	if third[0] != 10:
		return "33.33%% off 15 should be 10, got %d" % third[0]
	# 15 * 9999 / 10000 = 14.9985 -> 14
	var tiny := _dock_toll(_mods("toll_discount_bps", 1, 10000), 1000)
	if tiny[0] != 14:
		return "0.01%% off 15 should truncate to 14, got %d" % tiny[0]
	var free := _dock_toll(_mods("toll_discount_bps", 10000, 10000), 1000)
	if free[0] != 0:
		return "a full discount should waive the docking toll, got %d" % free[0]
	# Short purse: the cap applies to the discounted toll.
	var rc := _rc(1000)
	rc.modifiers = _mods("toll_discount_bps", 3333, 10000)
	rc.depart("mars")
	rc.cr = 4
	rc._arrive()
	if rc.cr != 0:
		return "cr %d, want 0 (discounted toll 10 capped at the 4 held)" % rc.cr
	return "ok"

# --- assumed_debt_bps ---

func _take_with(mods: Dictionary, debt: int) -> Dictionary:
	var rc := _rc(1000)
	rc.modifiers = mods
	rc.world.state(ARES).debt_cr = debt
	rc.world.state(ARES).treasury_cr = 0
	return Takeover.take(rc.world, ARES, Takeover.PLAYER, rc)

func test_assumed_debt_absent_is_the_shipped_half() -> String:
	var ev := _take_with({}, 1001)
	if int(ev["debt"]) != 500:
		return "baseline assumed %d, want 500" % int(ev["debt"])
	return "ok"

func test_assumed_debt_multiplier_and_rounding() -> String:
	# 5000 * 6000 / 10000 = 3000 bps: 1001 * 3000 / 10000 = 300.3 -> 300
	var ev := _take_with(_mods("assumed_debt_bps", 0, 6000), 1001)
	if int(ev["debt"]) != 300:
		return "x0.6 assumed %d, want 300" % int(ev["debt"])
	# 1003 * 3000 / 10000 = 300.9 -> 300 (truncates)
	ev = _take_with(_mods("assumed_debt_bps", 0, 6000), 1003)
	if int(ev["debt"]) != 300:
		return "truncation: assumed %d, want 300" % int(ev["debt"])
	# An add lands before the multiplier: (5000 + 1000) * 5000 / 10000 = 3000
	ev = _take_with(_mods("assumed_debt_bps", 1000, 5000), 1000)
	if int(ev["debt"]) != 300:
		return "add then mul: assumed %d, want 300" % int(ev["debt"])
	ev = _take_with(_mods("assumed_debt_bps", 0, 0), 1000)
	if int(ev["debt"]) != 0:
		return "x0 should assume nothing"
	return "ok"

func test_rival_takeover_ignores_the_stat() -> String:
	var rc := _rc(1000)
	rc.modifiers = _mods("assumed_debt_bps", 0, 0)
	var w: Barons = rc.world
	w.state(ARES).debt_cr = 400
	w.state(ARES).treasury_cr = 1000
	var ev := Takeover.take(w, ARES, "rival_a", rc)
	if int(ev["debt"]) != 400:
		return "a rival's takeover must not read the player's stat (debt %d)" % int(ev["debt"])
	return "ok"

# --- severance_bps ---

func test_severance_default_param_is_byte_identical() -> String:
	var a := MetaProfile.new()
	var b := MetaProfile.new()
	var x := Parachutes.award_severance(a, 1, 40000, 2, 17, 5, 3)
	var y := Parachutes.award_severance(b, 1, 40000, 2, 17, 5, 3, 10000)
	if x != y or a.severance_points != b.severance_points or a.barons_broken != b.barons_broken:
		return "default and explicit 10000 differ: %d vs %d" % [x, y]
	return "ok"

func test_severance_scales_the_whole_award_and_truncates() -> String:
	var base := Parachutes.award_severance(MetaProfile.new(), 1, 40000, 2, 17, 5, 3)
	var p := MetaProfile.new()
	var got := Parachutes.award_severance(p, 1, 40000, 2, 17, 5, 3, 12500)
	if got != base * 12500 / 10000 or p.severance_points != got:
		return "x1.25: got %d points %d, base %d" % [got, p.severance_points, base]
	if p.barons_broken != 2:
		return "barons_broken must stay the raw count"
	# A small award that does not divide evenly: 7 * 12500 / 10000 = 8.75 -> 8
	var q := MetaProfile.new()
	if Parachutes.award_severance(q, 0, 0, 0, 0, 7, 0, 12500) != 8 or q.severance_points != 8:
		return "7 x1.25 should truncate to 8"
	if Parachutes.award_severance(MetaProfile.new(), 0, 0, 0, 0, 7, 0, 0) != 0:
		return "x0 should award nothing"
	if Parachutes.award_severance(MetaProfile.new(), 0, 0, 0, 0, 7, 0, -300) != 0:
		return "a negative multiplier counts as zero"
	return "ok"

func test_bank_corp_reads_severance_bps_from_effective_modifiers() -> String:
	var rc_plain := RunController.new(MetaProfile.new(), 5, null, {}, TPR)
	rc_plain.peak_net_worth = 40000
	var plain: int = rc_plain.end_run("manual")
	var rc := RunController.new(MetaProfile.new(), 5, null, {}, TPR)
	rc.modifiers = _mods("severance_bps", 0, 12500)
	rc.peak_net_worth = 40000
	var scaled: int = rc.end_run("manual")
	if plain <= 0 or scaled != plain * 12500 / 10000:
		return "plain %d scaled %d" % [plain, scaled]
	if rc.profile.severance_points != scaled:
		return "profile banked %d, award %d" % [rc.profile.severance_points, scaled]
	return "ok"
