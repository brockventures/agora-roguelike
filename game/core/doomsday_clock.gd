class_name DoomsdayClock
extends RefCounted
## Sol System Doomsday Clock & Debt Burn Engine.
##
## Part of Epic 2 (#8) / Issue #9.
##
## Key Architectural Invariants:
## 1. Doomsday Countdown: Tracks the countdown toward Sol System collapse in discrete sim ticks.
##    Progresses through discrete threat stages (NORMAL, UNSTABLE, CRITICAL, IMMINENT, COLLAPSED).
##    Stage transitions use exact integer threshold comparisons.
## 2. Integer CR Accounting (Amos Review Invariant):
##    All debt (principal, accrued burn, accrued interest) and debt service payments are strictly
##    integer Credits (CR). No floats in the money path. Sub-credit burn and interest accrual use
##    explicit integer remainder accumulators to ensure zero ledger drift over millions of ticks.
## 3. Disjoint Debt & Burn Buckets:
##    Accrued operational burn and compounding loan interest are held in separate buckets.
##    Interest compounds strictly against principal debt (not on burn).
##    Debt service applies payments in priority order: accrued interest first, accrued burn second,
##    principal debt third.
## 4. Discrete Sim Tick Stepping (SimClock #60 Integration):
##    The clock advances via step_ticks(n: int) in discrete sim ticks rather than float seconds,
##    ensuring deterministic threshold crossings aligned with SimClock.
## 5. Stabilization Tributes: Delivering vital supplies or paying stabilization funding to Sol
##    station extends the countdown clock and can de-escalate crisis stages.
## 6. Atomic Interrupt Hook: Integrates with SimClock. Transitions between crisis stages or
##    terminal collapse trigger atomic auto-pause interrupts so players can react immediately.
## 7. Determinism & Serialization: Pure RefCounted with full to_dict() / from_dict() roundtrip.
##    from_dict() strictly recomputes stage via _compute_stage() to guarantee state validity.

signal stage_changed(old_stage: int, new_stage: int)
signal ticks_updated(ticks_remaining: int, total_ticks: int)
signal collapsed()
signal debt_burn_accrued(burn_cr: int, interest_cr: int, total_debt: int)
signal debt_serviced(amount: int, remaining_debt: int)
signal tribute_paid(amount: int, ticks_added: int)

enum Stage {
	NORMAL = 0,
	UNSTABLE = 1,
	CRITICAL = 2,
	IMMINENT = 3,
	COLLAPSED = 4,
}

# Baseline defaults (SimClock runs at 60 ticks/second)
const DEFAULT_TICKS_PER_SECOND: int = 60
## Run length (#134, Ryan: "40 rounds sounds very short"): 120 rounds at the default
## 900 ticks/round (RunController.DEFAULT_TICKS_PER_ROUND) is 108000 ticks, 30 min at 1x.
## Takeover pace is unchanged; the burn and interest below are the 40-round values divided
## by the 3x length so the TOTAL pressure over a run is about what it was, and the stage
## thresholds are ratios of the total, so they stretch with it. All tuning knobs live here.
const DEFAULT_RUN_ROUNDS: int = 120
const TICKS_PER_ROUND: int = 900
const DEFAULT_TOTAL_TICKS: int = DEFAULT_RUN_ROUNDS * TICKS_PER_ROUND   # 108000 = 1800s (30 min) at 60 tps
const DEFAULT_DEBT: int = 0                     # no opening debt: debt accrues only from burn and interest
const DEFAULT_BASE_BURN_PER_SECOND: int = 8     # was 25 over 40 rounds; /3 for the 3x run (8.33 rounded down)
const DEFAULT_INTEREST_RATE_BPS_PER_MINUTE: int = 100 # was 300 bps (3.0%/min); /3 for the 3x run

## Saturation ceiling for every CR bucket (2^60). Debt, interest and burn accrual
## clamp here instead of wrapping int64 negative (Epic 2 audit D8). Leaves
## headroom so two buckets can be summed without overflowing.
const MAX_CR: int = 1 << 60
## Ceiling for the configured burn rate (CR/sec), so the per-chunk burn product
## below stays inside int64: MAX_BURN_PER_SECOND * 10000 * 100 * 216000 < 2^63.
const MAX_BURN_PER_SECOND: int = 100_000_000
const BPS: int = 10000

# Stage thresholds in basis points (10000 bps = 100%)
const UNSTABLE_RATIO_BPS: int = 7500   # <= 75% ticks remaining -> UNSTABLE
const CRITICAL_RATIO_BPS: int = 4000   # <= 40% ticks remaining -> CRITICAL
const IMMINENT_RATIO_BPS: int = 1500   # <= 15% ticks remaining -> IMMINENT
const COLLAPSED_RATIO_BPS: int = 0     # <= 0 ticks remaining -> COLLAPSED

# Stage burn rate multipliers expressed in tenths (10 = 1.0x, 15 = 1.5x, etc.)
const STAGE_BURN_MULTIPLIER_TENTHS := {
	Stage.NORMAL: 10,
	Stage.UNSTABLE: 15,
	Stage.CRITICAL: 25,
	Stage.IMMINENT: 50,
	Stage.COLLAPSED: 100,
}

# Clock state (all discrete integers)
var total_ticks: int = DEFAULT_TOTAL_TICKS
var ticks_remaining: int = DEFAULT_TOTAL_TICKS
var ticks_per_second: int = DEFAULT_TICKS_PER_SECOND
var stage: Stage = Stage.NORMAL

# Financial ledger buckets (strictly integer CR)
var principal_debt: int = DEFAULT_DEBT
var accrued_burn: int = 0
var accrued_interest: int = 0
var total_burn_accrued: int = 0
var total_interest_accrued: int = 0
var total_debt_serviced: int = 0
var total_ticks_added_by_tributes: int = 0

# Configuration rates
var base_burn_per_second: int = DEFAULT_BASE_BURN_PER_SECOND
## Exact burn rate in CR/sec x 10000, or -1 to use base_burn_per_second * 10000.
## A burn perk (x0.85) set through RunController keeps the untruncated product
## here, so accrual is exact over time; base_burn_per_second holds its truncated
## integer for display and compatibility (audit D9: 25 * 0.85 is 21.25, not 21).
var burn_per_second_bps: int = -1
var interest_rate_bps_per_minute: int = DEFAULT_INTEREST_RATE_BPS_PER_MINUTE

# Remainder accumulators for fractional CR accrual across discrete ticks
var _burn_subunits: int = 0
var _interest_subunits: int = 0
var _ticks_in_minute: int = 0
var _compounding_base: int = DEFAULT_DEBT

# Interrupt hook flag for SimClock integration
var stage_transition_pending_interrupt: bool = false

func _init(
	p_total_ticks: int = DEFAULT_TOTAL_TICKS,
	p_debt: int = DEFAULT_DEBT,
	p_base_burn: int = DEFAULT_BASE_BURN_PER_SECOND,
	p_interest_bps: int = DEFAULT_INTEREST_RATE_BPS_PER_MINUTE,
	p_ticks_per_sec: int = DEFAULT_TICKS_PER_SECOND
) -> void:
	ticks_per_second = maxi(1, p_ticks_per_sec)
	total_ticks = maxi(1, p_total_ticks)
	ticks_remaining = total_ticks
	principal_debt = clampi(p_debt, 0, MAX_CR)
	base_burn_per_second = clampi(p_base_burn, 0, MAX_BURN_PER_SECOND)
	interest_rate_bps_per_minute = maxi(0, p_interest_bps)
	stage = _compute_stage(ticks_remaining, total_ticks)
	_ticks_in_minute = 0
	_compounding_base = _sat_add(principal_debt, accrued_interest)

## Saturating helpers: operands are non-negative and at most MAX_CR.
static func _sat_add(a: int, b: int) -> int:
	return mini(MAX_CR, a + b)

static func _sat_mul(a: int, b: int) -> int:
	if a <= 0 or b <= 0:
		return 0
	if a > MAX_CR / b:
		return MAX_CR
	return a * b

## Burn rate in CR/sec x 10000 (exact).
func effective_burn_bps() -> int:
	if burn_per_second_bps >= 0:
		return mini(burn_per_second_bps, MAX_BURN_PER_SECOND * BPS)
	return base_burn_per_second * BPS

## Sets the burn rate from a pre-multiplier base plus add, scaled by mul_bps,
## without truncating: the exact product is kept for accrual (D9).
func set_burn_scaled(p_base: int, p_add: int, p_mul_bps: int) -> void:
	var exact: int = clampi((p_base + p_add) * maxi(0, p_mul_bps), 0, MAX_BURN_PER_SECOND * BPS)
	burn_per_second_bps = exact
	base_burn_per_second = exact / BPS

func get_stage_multiplier_tenths(p_stage: Stage) -> int:
	return STAGE_BURN_MULTIPLIER_TENTHS.get(p_stage, 10)

func get_current_burn_rate_cr_per_sec() -> float:
	return float(effective_burn_bps() * get_stage_multiplier_tenths(stage)) / float(BPS * 10)

func get_total_debt() -> int:
	return _sat_add(_sat_add(principal_debt, accrued_burn), accrued_interest)

func get_compounding_debt_base() -> int:
	return _compounding_base

func get_time_remaining_seconds() -> float:
	return float(ticks_remaining) / float(ticks_per_second)

func get_total_time_seconds() -> float:
	return float(total_ticks) / float(ticks_per_second)

func get_time_ratio() -> float:
	if total_ticks <= 0:
		return 0.0
	return clampf(float(ticks_remaining) / float(total_ticks), 0.0, 1.0)

func _compute_stage(rem: int, tot: int) -> Stage:
	if rem <= 0 or tot <= 0:
		return Stage.COLLAPSED
	# Exact integer comparison using basis points
	if rem * 10000 <= tot * IMMINENT_RATIO_BPS:
		return Stage.IMMINENT
	elif rem * 10000 <= tot * CRITICAL_RATIO_BPS:
		return Stage.CRITICAL
	elif rem * 10000 <= tot * UNSTABLE_RATIO_BPS:
		return Stage.UNSTABLE
	else:
		return Stage.NORMAL

func should_auto_pause() -> bool:
	if stage_transition_pending_interrupt:
		stage_transition_pending_interrupt = false
		return true
	return false

func _get_ticks_until_next_stage() -> int:
	if ticks_remaining <= 0 or total_ticks <= 0:
		return 0
	match stage:
		Stage.NORMAL:
			var thresh := (total_ticks * UNSTABLE_RATIO_BPS) / 10000
			return maxi(0, ticks_remaining - thresh)
		Stage.UNSTABLE:
			var thresh := (total_ticks * CRITICAL_RATIO_BPS) / 10000
			return maxi(0, ticks_remaining - thresh)
		Stage.CRITICAL:
			var thresh := (total_ticks * IMMINENT_RATIO_BPS) / 10000
			return maxi(0, ticks_remaining - thresh)
		Stage.IMMINENT:
			return ticks_remaining
		_:
			return 0

## Advance the doomsday clock by a discrete count of simulation ticks.
## Primary clock stepping method.
func step_ticks(ticks: int = 1) -> void:
	if ticks <= 0 or stage == Stage.COLLAPSED or ticks_remaining <= 0:
		return

	# Stop at 0: clamp total ticks stepped to ticks_remaining
	var rem_ticks := mini(ticks, ticks_remaining)
	var ticks_per_minute := ticks_per_second * 60
	var burn_divisor := ticks_per_second * 10 * BPS
	var burn_bps := effective_burn_bps()
	var interest_divisor := 10000 * ticks_per_minute if ticks_per_minute > 0 else 1

	var total_burn_cr_this_step := 0
	var total_interest_cr_this_step := 0

	while rem_ticks > 0 and ticks_remaining > 0 and stage != Stage.COLLAPSED:
		# Calculate chunk size bounded by:
		# 1. Remaining ticks in caller request
		var chunk := rem_ticks

		# 2. Clamped to remaining ticks before collapse
		chunk = mini(chunk, ticks_remaining)

		# 3. Minute boundary for interest compounding
		if ticks_per_minute > 0:
			if _ticks_in_minute >= ticks_per_minute:
				_ticks_in_minute = 0
				_compounding_base = _sat_add(principal_debt, accrued_interest)
			var ticks_until_boundary := ticks_per_minute - _ticks_in_minute
			chunk = mini(chunk, ticks_until_boundary)

		# 4. Stage transition boundary for burn multiplier
		var ticks_until_stage := _get_ticks_until_next_stage()
		if ticks_until_stage > 0:
			chunk = mini(chunk, ticks_until_stage)

		if chunk <= 0:
			push_warning("DoomsdayClock.step_ticks: computed non-positive chunk %d, aborting step" % chunk)
			break

		# Advance countdown (exact integer subtraction)
		ticks_remaining -= chunk

		# Accrue operating burn for this chunk
		var multiplier_tenths := get_stage_multiplier_tenths(stage)
		var burn_units := burn_bps * multiplier_tenths * chunk
		_burn_subunits += burn_units
		var burn_cr := _burn_subunits / burn_divisor
		_burn_subunits %= burn_divisor

		accrued_burn = _sat_add(accrued_burn, burn_cr)
		total_burn_accrued = _sat_add(total_burn_accrued, burn_cr)
		total_burn_cr_this_step += burn_cr

		# Accrue interest for this chunk
		var interest_cr := 0
		if interest_rate_bps_per_minute > 0 and ticks_per_minute > 0 and _compounding_base > 0:
			# interest = base * rate * chunk / interest_divisor, computed without
			# forming the full product (it wraps int64 near a 2^50 principal, D8):
			# split base = q * divisor + r so q * k is the whole-credit part and
			# only the small r * k term goes through the remainder accumulator.
			var k := interest_rate_bps_per_minute * chunk
			var q := _compounding_base / interest_divisor
			var r := _compounding_base % interest_divisor
			var rem_units := r * k + _interest_subunits
			interest_cr = _sat_add(_sat_mul(q, k), rem_units / interest_divisor)
			_interest_subunits = rem_units % interest_divisor

			accrued_interest = _sat_add(accrued_interest, interest_cr)
			total_interest_accrued = _sat_add(total_interest_accrued, interest_cr)
			total_interest_cr_this_step += interest_cr

		# Advance minute counter and re-snapshot compounding base at boundary
		if ticks_per_minute > 0:
			_ticks_in_minute += chunk
			if _ticks_in_minute >= ticks_per_minute:
				_ticks_in_minute = 0
				_compounding_base = _sat_add(principal_debt, accrued_interest)

		rem_ticks -= chunk

		# Check stage progression after this chunk
		var new_stage := _compute_stage(ticks_remaining, total_ticks)
		if new_stage != stage:
			var old_stage := stage
			stage = new_stage
			stage_transition_pending_interrupt = true
			stage_changed.emit(old_stage, new_stage)

			if stage == Stage.COLLAPSED:
				collapsed.emit()
				break

	ticks_updated.emit(ticks_remaining, total_ticks)
	if total_burn_cr_this_step > 0 or total_interest_cr_this_step > 0:
		debt_burn_accrued.emit(total_burn_cr_this_step, total_interest_cr_this_step, get_total_debt())

## Alias for step_ticks(ticks) for compatibility
func step(ticks: int = 1) -> void:
	step_ticks(ticks)

## Service outstanding debt in integer CR.
## Payment priority order:
## 1. Accrued interest first
## 2. Accrued operational burn second
## 3. Principal debt third
## Returns the exact integer amount paid.
func service_debt(amount: int) -> int:
	if amount <= 0:
		return 0

	var remaining_payment := amount
	var paid := 0

	# 1. Pay off accrued interest first
	if accrued_interest > 0:
		var pay_interest := mini(remaining_payment, accrued_interest)
		accrued_interest -= pay_interest
		remaining_payment -= pay_interest
		paid += pay_interest

	# 2. Pay off accrued burn second
	if remaining_payment > 0 and accrued_burn > 0:
		var pay_burn := mini(remaining_payment, accrued_burn)
		accrued_burn -= pay_burn
		remaining_payment -= pay_burn
		paid += pay_burn

	# 3. Pay down principal debt third
	if remaining_payment > 0 and principal_debt > 0:
		var pay_principal := mini(remaining_payment, principal_debt)
		principal_debt -= pay_principal
		remaining_payment -= pay_principal
		paid += pay_principal

	# Immediately reduce compounding base if debt is paid down mid-minute
	_compounding_base = mini(_compounding_base, _sat_add(principal_debt, accrued_interest))

	total_debt_serviced += paid
	debt_serviced.emit(paid, get_total_debt())
	return paid

## Adds a fine to the principal (Epic 3 Ares Heavy default penalty). Saturates at
## MAX_CR and keeps the compounding base in step, as the constructor does, so the
## new principal accrues interest from the next tick. Returns the amount added.
func add_principal(amount: int) -> int:
	var add: int = maxi(0, amount)
	var before: int = principal_debt
	principal_debt = _sat_add(principal_debt, add)
	_compounding_base = _sat_add(principal_debt, accrued_interest)
	return principal_debt - before

## Wipe every debt bucket (Chapter 11 filing, #10). Zeroes principal, accrued
## interest, accrued burn, the sub-credit remainders and the compounding base.
## Deliberately leaves ticks_remaining, stage and the lifetime totals untouched:
## bankruptcy cleans the balance sheet, it does not buy time.
func clear_debt() -> void:
	principal_debt = 0
	accrued_interest = 0
	accrued_burn = 0
	_burn_subunits = 0
	_interest_subunits = 0
	_compounding_base = 0

## Pay stabilization tribute in credits, extending countdown by discrete ticks.
## Default conversion: 3 ticks per credit (at 60 tps, 3 ticks = 0.05 seconds/CR).
## Returns the exact count of ticks added.
func apply_tribute(amount_cr: int, ticks_per_credit: int = 3) -> int:
	if amount_cr <= 0 or stage == Stage.COLLAPSED:
		return 0

	# Tribute restores the clock but never past its full length, so the
	# in-play value always matches what from_dict() accepts on reload.
	var headroom: int = maxi(0, total_ticks - ticks_remaining)
	var ticks_added: int = mini(amount_cr * ticks_per_credit, headroom)
	if ticks_added <= 0:
		return 0
	ticks_remaining += ticks_added
	total_ticks_added_by_tributes += ticks_added

	# De-escalate stage if stabilization achieved sufficient threshold
	var new_stage := _compute_stage(ticks_remaining, total_ticks)
	if new_stage != stage:
		var old_stage := stage
		stage = new_stage
		stage_transition_pending_interrupt = true
		stage_changed.emit(old_stage, new_stage)

	ticks_updated.emit(ticks_remaining, total_ticks)
	tribute_paid.emit(amount_cr, ticks_added)
	return ticks_added

func to_dict() -> Dictionary:
	return {
		"total_ticks": total_ticks,
		"ticks_remaining": ticks_remaining,
		"ticks_per_second": ticks_per_second,
		"stage": int(stage),
		"principal_debt": principal_debt,
		"accrued_burn": accrued_burn,
		"accrued_interest": accrued_interest,
		"total_burn_accrued": total_burn_accrued,
		"total_interest_accrued": total_interest_accrued,
		"total_debt_serviced": total_debt_serviced,
		"total_ticks_added_by_tributes": total_ticks_added_by_tributes,
		"base_burn_per_second": base_burn_per_second,
		"burn_per_second_bps": burn_per_second_bps,
		"burn_subunit_scale": BPS,
		"interest_rate_bps_per_minute": interest_rate_bps_per_minute,
		"_burn_subunits": _burn_subunits,
		"_interest_subunits": _interest_subunits,
		"_ticks_in_minute": _ticks_in_minute,
		"_compounding_base": _compounding_base,
		"stage_transition_pending_interrupt": stage_transition_pending_interrupt,
	}

static func from_dict(d: Dictionary) -> DoomsdayClock:
	var clock := DoomsdayClock.new(
		int(d.get("total_ticks", DEFAULT_TOTAL_TICKS)),
		int(d.get("principal_debt", DEFAULT_DEBT)),
		int(d.get("base_burn_per_second", DEFAULT_BASE_BURN_PER_SECOND)),
		int(d.get("interest_rate_bps_per_minute", DEFAULT_INTEREST_RATE_BPS_PER_MINUTE)),
		int(d.get("ticks_per_second", DEFAULT_TICKS_PER_SECOND))
	)
	# Defensive state validation (PR #71 gap): never more time than the clock's
	# own total, whatever a tampered or corrupt save claims.
	clock.ticks_remaining = clampi(int(d.get("ticks_remaining", clock.total_ticks)), 0, clock.total_ticks)
	clock.accrued_burn = clampi(int(d.get("accrued_burn", 0)), 0, MAX_CR)
	clock.accrued_interest = clampi(int(d.get("accrued_interest", 0)), 0, MAX_CR)
	clock.total_burn_accrued = clampi(int(d.get("total_burn_accrued", 0)), 0, MAX_CR)
	clock.total_interest_accrued = clampi(int(d.get("total_interest_accrued", 0)), 0, MAX_CR)
	clock.total_debt_serviced = clampi(int(d.get("total_debt_serviced", 0)), 0, MAX_CR)
	# Exact burn rate: only trusted when consistent with the integer rate.
	var bps_raw := int(d.get("burn_per_second_bps", -1))
	if bps_raw >= 0 and bps_raw / BPS == clock.base_burn_per_second:
		clock.burn_per_second_bps = bps_raw
	clock.total_ticks_added_by_tributes = maxi(0, int(d.get("total_ticks_added_by_tributes", 0)))
	# Burn remainders are now x10000 finer; a save from before that has no
	# burn_subunit_scale, so scale its remainder up to keep the fraction.
	var burn_sub := maxi(0, int(d.get("_burn_subunits", 0)))
	if int(d.get("burn_subunit_scale", 1)) != BPS:
		burn_sub = mini(burn_sub, clock.ticks_per_second * 10) * BPS
	clock._burn_subunits = mini(burn_sub, clock.ticks_per_second * 10 * BPS - 1)
	clock._interest_subunits = clampi(int(d.get("_interest_subunits", 0)), 0, maxi(0, 10000 * clock.ticks_per_second * 60 - 1))
	var ticks_per_min := clock.ticks_per_second * 60
	if ticks_per_min > 0:
		clock._ticks_in_minute = posmod(int(d.get("_ticks_in_minute", 0)), ticks_per_min)
	else:
		clock._ticks_in_minute = 0
	var max_base := _sat_add(clock.principal_debt, clock.accrued_interest)
	clock._compounding_base = clampi(int(d.get("_compounding_base", max_base)), 0, max_base)
	# Recompute stage strictly from ticks_remaining and total_ticks to prevent save-state divergence
	clock.stage = clock._compute_stage(clock.ticks_remaining, clock.total_ticks)
	clock.stage_transition_pending_interrupt = bool(d.get("stage_transition_pending_interrupt", false))
	return clock
