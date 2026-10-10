extends RefCounted
## Epic 2 review-gate engineering fixes (#13): D3 save divergence, D5 audit cap
## per round, D8 interest overflow, D9 burn rounding, D10 stable hashes and seeds,
## D12 loaded-save validation, and the PR #71 ticks_remaining clamp.

const TMP_ROOT := "user://test_tmp"
const RICH: int = 20000
var _counter: int = 0


func _store() -> SaveStore:
	_counter += 1
	return SaveStore.new("%s/audit_%d_%d" % [TMP_ROOT, Time.get_ticks_usec(), _counter])


func _cleanup(store: SaveStore) -> void:
	_rm_rf(store.dir)
	DirAccess.remove_absolute(TMP_ROOT)


static func _rm_rf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


# --- D3: profile / run-slot divergence ---

func test_d3_perk_buy_survives_crash_before_run_autosave() -> String:
	var st := _store()
	var main := MainScene.new()
	main.enable_persistence(st)
	var rc := main.start_new_run(5)
	rc.profile.severance_points = 500
	main.save_all()  # run slot now embeds a profile WITHOUT the perk
	var res: Dictionary = Parachutes.load().buy(rc.profile, "seed_capital")
	if not bool(res["ok"]):
		_cleanup(st)
		main.free()
		return "could not buy the perk: %s" % str(res)
	# Crash: only profile.json was written, the run slot was not.
	main._save_profile()
	var main2 := MainScene.new()
	main2.enable_persistence(st)
	var ok := main2.continue_saved_run()
	var kept: bool = ok and main2.controller.profile.has_unlock("seed_capital") and main2.controller.profile.severance_points == 400
	_cleanup(st)
	main.free()
	main2.free()
	if not ok:
		return "continue failed"
	if not kept:
		return "perk lost: the stale embedded profile replaced profile.json"
	return "ok"


func test_d3_perk_purchase_refreshes_embedded_profile() -> String:
	var st := _store()
	var main := MainScene.new()
	main.enable_persistence(st)
	var rc := main.start_new_run(5)
	rc.profile.severance_points = 500
	main.save_all()
	Parachutes.load().buy(rc.profile, "seed_capital")
	main._on_action_handled("m0_submit")
	var r: Dictionary = st.load_run()
	var embedded_has: bool = bool(r["ok"]) and (r["controller"] as RunController).profile.has_unlock("seed_capital")
	_cleanup(st)
	main.free()
	return "ok" if embedded_has else "run slot still embeds the pre-purchase profile"


# --- D5: audit cap is per round, cumulative ---

func _audit_ctx() -> Dictionary:
	var rc := RunController.new(null, 9, null, {}, 4)
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.lock_station("mars")
	var deck: CrisisDeck = rc.crisis_deck
	var keep: Array = []
	for def in deck.data["crises"]:
		if def["id"] == "antitrust_audit":
			keep.append(def)
	deck.data["crises"] = keep
	deck.data["grace_rounds"] = 0
	deck.bags.force("crisis", true)
	var c: Dictionary = deck.advance_round(3, 1, RICH)
	deck.acknowledge()
	lp.set_tab(M0Loop.Tab.MARKET)
	return {"rc": rc, "hud": hud, "lp": lp, "f": hud.gamepad_focus, "deck": deck, "c": c}


func test_d5_splitting_orders_cannot_exceed_the_cap() -> String:
	var ctx := _audit_ctx()
	var rc: RunController = ctx["rc"]
	var f: GamepadFocus = ctx["f"]
	var cap: int = rc.trade_cap_qty()
	if cap != 20:
		return "expected cap 20, got %d" % cap
	var traded: int = 0
	for i in 5:
		f.set_quantity(8)
		var res: Dictionary = f.execute_focused_order()
		if bool(res.get("ok", false)):
			traded += 8
		elif f.last_rejection_reason != "AUDIT_TRADE_CAP":
			return "unexpected rejection %s %s" % [f.last_rejection_reason, str(res)]
	if traded > cap:
		return "split orders traded %d units against a cap of %d" % [traded, cap]
	if traded != 16:
		return "expected exactly two 8-unit fills (16), got %d" % traded
	if f.last_rejection_reason != "AUDIT_TRADE_CAP":
		return "last rejection was %s" % f.last_rejection_reason
	f.set_quantity(3)  # 4 units of cap left; the top book level holds 19, 16 are gone
	var last: Dictionary = f.execute_focused_order()
	if not bool(last.get("ok", false)):
		return "the remaining cap should still allow a small order: %s" % str(last)
	return "ok"


func test_d5_cap_resets_each_round() -> String:
	var ctx := _audit_ctx()
	var rc: RunController = ctx["rc"]
	var f: GamepadFocus = ctx["f"]
	f.set_quantity(19)  # the top book level holds 19; cap is 20
	var first: Dictionary = f.execute_focused_order()
	if not bool(first.get("ok", false)):
		return "first order rejected: %s" % str(first)
	if rc.audit_units_remaining() != 1:
		return "remaining %d, want 1" % rc.audit_units_remaining()
	f.set_quantity(2)
	if bool(f.execute_focused_order().get("ok", true)) or f.last_rejection_reason != "AUDIT_TRADE_CAP":
		return "cap not exhausted: %s" % f.last_rejection_reason
	rc._on_sub_ticked(rc.ticks_per_round)  # round boundary
	if rc.audit_units_traded != 0 or rc.audit_units_remaining() != rc.trade_cap_qty():
		return "round boundary did not reset the tally"
	return "ok"


func test_d5_tally_survives_save_roundtrip() -> String:
	var rc := RunController.new()
	rc.audit_units_traded = 7
	var back := RunController.from_dict(JSON.parse_string(JSON.stringify(rc.to_dict())))
	return "ok" if back.audit_units_traded == 7 else "tally lost"


# --- D8: interest overflow ---

func test_d8_huge_principal_never_wraps_negative() -> String:
	var p: int = 1 << 50
	var clock := DoomsdayClock.new(1000000, p, 0, 300, 60)
	clock.step_ticks(3600)  # one minute: 3% compounding
	var want: int = p * 300 / 10000
	if clock.accrued_interest <= 0:
		return "interest wrapped or vanished: %d" % clock.accrued_interest
	if absi(clock.accrued_interest - want) > 1:
		return "interest %d, want about %d" % [clock.accrued_interest, want]
	if clock.get_total_debt() <= p:
		return "total debt did not grow: %d" % clock.get_total_debt()
	return "ok"


func test_d8_saturates_at_the_ceiling() -> String:
	var clock := DoomsdayClock.new(1000000, DoomsdayClock.MAX_CR, 25, 10000, 60)
	for i in 5:
		clock.step_ticks(3600)
	if clock.accrued_interest < 0 or clock.accrued_burn < 0 or clock.total_interest_accrued < 0:
		return "a bucket went negative"
	if clock.accrued_interest > DoomsdayClock.MAX_CR or clock.get_total_debt() < clock.principal_debt:
		return "bucket exceeded the ceiling or total wrapped"
	return "ok"


func test_d8_small_principal_interest_unchanged() -> String:
	# 50,000 CR at 3%/min for one minute is exactly 1,500 CR.
	var clock := DoomsdayClock.new(1000000, 50000, 0, 300, 60)
	clock.step_ticks(3600)
	return "ok" if clock.accrued_interest == 1500 else "interest %d, want 1500" % clock.accrued_interest


# --- D9: burn perk rounding ---

func test_d9_burn_perk_is_exact_over_time() -> String:
	var plain := DoomsdayClock.new(600000, 0, 25, 0, 60)
	var perked := DoomsdayClock.new(600000, 0, 25, 0, 60)
	var mods := {"burn_rate": {"add": 0, "mul_bps": 8500}}
	var rc := RunController.new(null, 1, perked, mods)
	plain.step_ticks(60000)  # 1000 s, stays in NORMAL
	rc.doomsday.step_ticks(60000)
	if plain.accrued_burn != 25000:
		return "baseline burn %d" % plain.accrued_burn
	if rc.doomsday.accrued_burn != 21250:
		return "x0.85 burn gave %d, want 21250 (truncating 25*0.85 to 21 would give 21000)" % rc.doomsday.accrued_burn
	if rc.doomsday.base_burn_per_second != 21:
		return "display rate should stay the truncated integer"
	return "ok"


func test_d9_burn_rate_survives_save_roundtrip() -> String:
	var rc := RunController.new(null, 1, DoomsdayClock.new(600000, 0, 25, 0, 60), {"burn_rate": {"add": 0, "mul_bps": 8500}})
	var back := RunController.from_dict(JSON.parse_string(JSON.stringify(rc.to_dict())))
	back.doomsday.step_ticks(60000)
	if back.doomsday.accrued_burn != 21250:
		return "burn after reload %d" % back.doomsday.accrued_burn
	return "ok"


# --- D10: stable hashes and seeds ---

func test_d10_stable_hash_is_sha256_prefix() -> String:
	if StableHash.hash32("abc") != 0xba7816bf:
		return "hash32('abc') = %x" % StableHash.hash32("abc")
	return "ok"


func test_d10_derived_seeds_are_pinned() -> String:
	var rc := RunController.new(null, 5)
	if rc.corp_seed(1) != (StableHash.hash32("corp-5-1") & 0x7FFFFFFF):
		return "corp_seed does not use StableHash"
	if Chapter11.next_seed_for(5, 0) != (StableHash.hash32("ch11-5-0") & 0x7FFFFFFF):
		return "next_seed_for does not use StableHash"
	# Pinned (SHA-256 prefix, masked to 31 bits): must never move with the engine.
	if rc.corp_seed(1) != 1936096886 or Chapter11.next_seed_for(5, 0) != 2048200375:
		return "pinned seeds moved: %d %d" % [rc.corp_seed(1), Chapter11.next_seed_for(5, 0)]
	return "ok"


func test_d10_initial_run_seed_honours_env_and_is_random() -> String:
	OS.set_environment(MainScene.RUN_SEED_ENV, "1234")
	var fixed: int = MainScene.initial_run_seed()
	OS.unset_environment(MainScene.RUN_SEED_ENV)
	if fixed != 1234:
		return "env seed ignored: %d" % fixed
	var seen := {}
	for i in 8:
		seen[MainScene.initial_run_seed()] = true
	if seen.size() < 2:
		return "initial seed is not random: %s" % str(seen.keys())
	return "ok"


# --- D12: loaded-save validation ---

func test_d12_tampered_save_is_sanitised() -> String:
	var rc := RunController.new()
	var d: Dictionary = rc.to_dict()
	d["cr"] = -500
	d["cargo_capacity"] = 50
	d["cargo"] = {"ORE": 40, "FUEL": 40, "FOOD": -9, "GOLD": 999, 7: 3}
	d["modifiers"] = {
		"burn_rate": {"add": 0, "mul_bps": 1},
		"starting_cr": {"add": 99999999999, "mul_bps": 99999999999},
		"made_up_stat": {"add": 1, "mul_bps": 10000},
	}
	var back := RunController.from_dict(JSON.parse_string(JSON.stringify(d)))
	if back.cr != 0:
		return "negative cr not clamped: %d" % back.cr
	if back.cargo.has("GOLD") or back.cargo.has("FOOD") or back.cargo.size() != 2:
		return "unknown / negative cargo kept: %s" % str(back.cargo)
	if back.get_total_cargo() > back.cargo_capacity:
		return "cargo %d exceeds capacity %d" % [back.get_total_cargo(), back.cargo_capacity]
	if not back.modifiers.is_empty():
		return "modifiers not backed by the profile survived: %s" % str(back.modifiers)
	d["cr"] = 1 << 62
	var huge := RunController.from_dict(JSON.parse_string(JSON.stringify(d)))
	if huge.cr > RunController.MAX_LOADED_CR:
		return "huge cr not clamped"
	return "ok"


func test_d12_owned_perk_modifiers_survive() -> String:
	var p := MetaProfile.new()
	p.add_unlock("seed_capital")
	var rc := RunController.new(p, 3)
	var back := RunController.from_dict(JSON.parse_string(JSON.stringify(rc.to_dict())))
	if not back.modifiers.has("starting_cr"):
		return "owned perk modifier dropped"
	return "ok"


func test_d12_unowned_perk_modifier_is_dropped() -> String:
	var rc := RunController.new(null, 3, null, {})
	var d: Dictionary = rc.to_dict()
	d["modifiers"] = {"starting_cr": {"add": 2000, "mul_bps": 10000}}
	var back := RunController.from_dict(JSON.parse_string(JSON.stringify(d)))
	return "ok" if back.modifiers.is_empty() else "unowned perk applied: %s" % str(back.modifiers)


# --- PR #71 gap ---

func test_pr71_ticks_remaining_is_capped_at_total() -> String:
	var clock := DoomsdayClock.new(36000, 0, 25, 300, 60)
	var d := clock.to_dict()
	d["ticks_remaining"] = 3036000
	var back := DoomsdayClock.from_dict(JSON.parse_string(JSON.stringify(d)))
	if back.ticks_remaining != 36000:
		return "ticks_remaining %d not capped at total 36000" % back.ticks_remaining
	return "ok"
