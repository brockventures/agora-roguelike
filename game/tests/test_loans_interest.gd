extends RefCounted
## Tests for loans and interest system with corrupt_regulator perk (#137).

const ARES: String = "ares_heavy"
const TPR: int = 30

func _ctx(cr: int = 100000, mods: Dictionary = {}) -> Dictionary:
	var rc := RunController.new(null, 21, null, mods, TPR)
	rc.world = Barons.for_new_run()
	rc.world.rivals.clear()
	rc.cr = cr
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("mars")
	return {"rc": rc, "hud": hud, "loop": lp, "world": rc.world, "market": lp.market}

func _owned(ids: Array) -> MetaProfile:
	var p := MetaProfile.new()
	for id in ids:
		p.add_unlock(id)
	return p

func test_corrupt_regulator_lowers_interest_rate_bps() -> String:
	var t := Parachutes.load()
	var plain_rc := RunController.new(MetaProfile.new(), 1)
	if plain_rc.interest_rate_bps() != DoomsdayClock.DEFAULT_INTEREST_RATE_BPS_PER_MINUTE:
		return "expected default interest %d, got %d" % [DoomsdayClock.DEFAULT_INTEREST_RATE_BPS_PER_MINUTE, plain_rc.interest_rate_bps()]

	var p := _owned(["corrupt_regulator"])
	var perk_rc := RunController.new(p, 1, null, t.modifiers(p))
	var expected_rate: int = DoomsdayClock.DEFAULT_INTEREST_RATE_BPS_PER_MINUTE - 50
	if perk_rc.interest_rate_bps() != expected_rate:
		return "expected modified interest %d bps, got %d" % [expected_rate, perk_rc.interest_rate_bps()]
	return "ok"

func test_borrow_cr_adds_cash_and_principal() -> String:
	var rc := RunController.new(null, 1, DoomsdayClock.new(36000, 10000, 0, 100))
	var initial_cr := rc.cr
	var initial_debt := rc.doomsday.principal_debt

	# Invalid borrows return 0 and change nothing
	if rc.borrow_cr(0) != 0:
		return "zero borrow should return 0"
	if rc.borrow_cr(-500) != 0:
		return "negative borrow should return 0"
	if rc.cr != initial_cr or rc.doomsday.principal_debt != initial_debt:
		return "invalid borrow altered state"

	# Borrow 5000 CR
	var borrowed := rc.borrow_cr(5000)
	if borrowed != 5000:
		return "expected 5000 borrowed, got %d" % borrowed
	if rc.cr != initial_cr + 5000:
		return "expected CR %d, got %d" % [initial_cr + 5000, rc.cr]
	if rc.doomsday.principal_debt != initial_debt + 5000:
		return "expected principal debt %d, got %d" % [initial_debt + 5000, rc.doomsday.principal_debt]
	return "ok"

func test_interest_compounding_on_borrowed_debt() -> String:
	var t := Parachutes.load()
	var p := _owned(["corrupt_regulator"])
	# Start clock with 0 base burn and 0 initial debt to isolate interest
	var clock := DoomsdayClock.new(36000, 0, 0, 100, 1)
	var rc := RunController.new(p, 1, clock, t.modifiers(p), TPR)

	if rc.interest_rate_bps() != 50:
		return "expected 50 bps interest rate, got %d" % rc.interest_rate_bps()

	rc.borrow_cr(10000)
	if rc.doomsday.principal_debt != 10000:
		return "expected 10000 principal debt"

	# Advance 60 seconds (1 minute at 1 tick/sec)
	rc.doomsday.step_ticks(60)

	# 10,000 * 50 / 10,000 = 50 CR interest accrued
	if rc.doomsday.accrued_interest != 50:
		return "expected 50 accrued interest at 50 bps, got %d" % rc.doomsday.accrued_interest

	# Contrast with unmodded clock (100 bps)
	var unmod_clock := DoomsdayClock.new(36000, 0, 0, 100, 1)
	var plain_rc := RunController.new(null, 1, unmod_clock, {}, TPR)
	plain_rc.borrow_cr(10000)
	plain_rc.doomsday.step_ticks(60)
	if plain_rc.doomsday.accrued_interest != 100:
		return "expected 100 accrued interest at 100 bps for unmodded run, got %d" % plain_rc.doomsday.accrued_interest

	return "ok"

func test_service_debt_order_of_payments() -> String:
	# Clock with 1000 principal, 50 accrued interest, 100 burn
	var clock := DoomsdayClock.new(36000, 1000, 0, 100, 1)
	clock.accrued_interest = 50
	clock.accrued_burn = 100
	var rc := RunController.new(null, 1, clock)
	rc.cr = 1000

	# 1. Partial payment: Pay 30 CR (pays portion of interest)
	var paid := rc.service_debt(30)
	if paid != 30 or rc.cr != 970:
		return "payment 1 failed: paid %d, cr %d" % [paid, rc.cr]
	if clock.accrued_interest != 20:
		return "expected 20 remaining interest, got %d" % clock.accrued_interest
	if clock.accrued_burn != 100:
		return "expected 100 remaining burn, got %d" % clock.accrued_burn
	if clock.principal_debt != 1000:
		return "expected 1000 remaining principal, got %d" % clock.principal_debt

	# 2. Pay 50 CR: clears remaining 20 interest and 30 burn
	paid = rc.service_debt(50)
	if paid != 50 or rc.cr != 920:
		return "payment 2 failed: paid %d, cr %d" % [paid, rc.cr]
	if clock.accrued_interest != 0:
		return "expected 0 remaining interest, got %d" % clock.accrued_interest
	if clock.accrued_burn != 70:
		return "expected 70 remaining burn, got %d" % clock.accrued_burn
	if clock.principal_debt != 1000:
		return "expected 1000 remaining principal, got %d" % clock.principal_debt

	# 3. Pay cannot exceed available CR
	rc.cr = 40
	paid = rc.service_debt(100)
	if paid != 40 or rc.cr != 0:
		return "clamped payment failed: paid %d, cr %d" % [paid, rc.cr]
	if clock.accrued_burn != 30:
		return "expected 30 remaining burn, got %d" % clock.accrued_burn

	return "ok"

func test_levers_credit_rate_bps_with_and_without_perk() -> String:
	var t := Parachutes.load()
	var w := Barons.for_new_run()

	var plain_rc := RunController.new(MetaProfile.new(), 1)
	if Levers.credit_rate_bps(w, plain_rc) != 2000:
		return "expected base credit rate 2000 bps, got %d" % Levers.credit_rate_bps(w, plain_rc)

	var p := _owned(["corrupt_regulator"])
	var perk_rc := RunController.new(p, 1, null, t.modifiers(p))
	if Levers.credit_rate_bps(w, perk_rc) != 1950:
		return "expected modified credit rate 1950 bps, got %d" % Levers.credit_rate_bps(w, perk_rc)
	return "ok"

func test_open_credit_uses_modified_rate() -> String:
	var t := Parachutes.load()
	var p := _owned(["corrupt_regulator"])
	var c := _ctx(100000, t.modifiers(p))
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	var s: BaronState = w.state(ARES)
	s.treasury_cr = 42000  # press baron to 70%

	var r: Dictionary = w.open_credit(rc, "mars")
	if not bool(r["ok"]):
		return "open_credit failed: %s" % str(r)

	var principal: int = int(r["principal"])
	var expected_due: int = principal * (10000 + 1950) / 10000
	if int(r["due"]) != expected_due:
		return "expected due %d, got %d" % [expected_due, int(r["due"])]

	var credit_record: Dictionary = s.scratch.get("credit", {})
	if int(credit_record.get("rate_bps", 0)) != 1950:
		return "scratch credit rate_bps expected 1950, got %s" % str(credit_record.get("rate_bps"))

	var events: Array = r.get("events", [])
	if events.is_empty() or int(events[0].get("rate_bps", 0)) != 1950:
		return "credit_open event missing rate_bps 1950: %s" % str(events)

	return "ok"

func test_controller_save_load_preserves_loan_debt() -> String:
	var clock := DoomsdayClock.new(36000, 10000, 0, 100)
	var rc := RunController.new(null, 1, clock)
	rc.cr = 50000
	rc.borrow_cr(20000)
	rc.service_debt(5000)

	var d := rc.to_dict()
	var loaded := RunController.from_dict(d)

	if loaded.cr != rc.cr:
		return "cr mismatch after save/load: %d vs %d" % [loaded.cr, rc.cr]
	if loaded.doomsday.principal_debt != rc.doomsday.principal_debt:
		return "principal debt mismatch after save/load: %d vs %d" % [loaded.doomsday.principal_debt, rc.doomsday.principal_debt]
	if loaded.interest_rate_bps() != rc.interest_rate_bps():
		return "interest rate mismatch after save/load: %d vs %d" % [loaded.interest_rate_bps(), rc.interest_rate_bps()]

	return "ok"
