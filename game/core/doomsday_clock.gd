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
const DEFAULT_TOTAL_TICKS: int = 36000          # 600s (10 min) at 60 tps
const DEFAULT_DEBT: int = 50000                 # 50,000 CR opening debt obligation
const DEFAULT_BASE_BURN_PER_SECOND: int = 25    # 25 CR/sec baseline upkeep burn
const DEFAULT_INTEREST_RATE_BPS_PER_MINUTE: int = 300 # 300 bps (3.0%/min) compounding interest

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
var interest_rate_bps_per_minute: int = DEFAULT_INTEREST_RATE_BPS_PER_MINUTE

# Remainder accumulators for fractional CR accrual across discrete ticks
var _burn_subunits: int = 0
var _interest_subunits: int = 0

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
	principal_debt = maxi(0, p_debt)
	base_burn_per_second = maxi(0, p_base_burn)
	interest_rate_bps_per_minute = maxi(0, p_interest_bps)
	stage = _compute_stage(ticks_remaining, total_ticks)

func get_stage_multiplier_tenths(p_stage: Stage) -> int:
	return STAGE_BURN_MULTIPLIER_TENTHS.get(p_stage, 10)

func get_current_burn_rate_cr_per_sec() -> float:
	return float(base_burn_per_second * get_stage_multiplier_tenths(stage)) / 10.0

func get_total_debt() -> int:
	return principal_debt + accrued_burn + accrued_interest

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

## Advance the doomsday clock by a discrete count of simulation ticks.
## Primary clock stepping method.
func step_ticks(ticks: int = 1) -> void:
	if ticks <= 0:
		return
	if stage == Stage.COLLAPSED:
		return

	# Advance countdown (exact integer subtraction)
	ticks_remaining = maxi(0, ticks_remaining - ticks)

	# Accrue operating burn (integer math with remainder accumulator)
	# burn_divisor: ticks_per_second * 10
	var multiplier_tenths := get_stage_multiplier_tenths(stage)
	var burn_units := base_burn_per_second * multiplier_tenths * ticks
	_burn_subunits += burn_units
	var burn_divisor := ticks_per_second * 10
	var burn_cr := _burn_subunits / burn_divisor
	_burn_subunits %= burn_divisor

	accrued_burn += burn_cr
	total_burn_accrued += burn_cr

	# Accrue interest on principal debt (integer math in basis points per minute)
	# divisor: 10,000 bps * ticks_per_second * 60 seconds
	var interest_cr := 0
	if principal_debt > 0 and interest_rate_bps_per_minute > 0:
		var interest_units := principal_debt * interest_rate_bps_per_minute * ticks
		_interest_subunits += interest_units
		var interest_divisor := 10000 * ticks_per_second * 60
		interest_cr = _interest_subunits / interest_divisor
		_interest_subunits %= interest_divisor

		accrued_interest += interest_cr
		total_interest_accrued += interest_cr

	if burn_cr > 0 or interest_cr > 0:
		debt_burn_accrued.emit(burn_cr, interest_cr, get_total_debt())

	ticks_updated.emit(ticks_remaining, total_ticks)

	# Check stage progression with exact integer comparisons
	var new_stage := _compute_stage(ticks_remaining, total_ticks)
	if new_stage != stage:
		var old_stage := stage
		stage = new_stage
		stage_transition_pending_interrupt = true
		stage_changed.emit(old_stage, new_stage)

		if stage == Stage.COLLAPSED:
			collapsed.emit()

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

	total_debt_serviced += paid
	debt_serviced.emit(paid, get_total_debt())
	return paid

## Pay stabilization tribute in credits, extending countdown by discrete ticks.
## Default conversion: 3 ticks per credit (at 60 tps, 3 ticks = 0.05 seconds/CR).
## Returns the exact count of ticks added.
func apply_tribute(amount_cr: int, ticks_per_credit: int = 3) -> int:
	if amount_cr <= 0 or stage == Stage.COLLAPSED:
		return 0

	var ticks_added := amount_cr * ticks_per_credit
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
		"interest_rate_bps_per_minute": interest_rate_bps_per_minute,
		"_burn_subunits": _burn_subunits,
		"_interest_subunits": _interest_subunits,
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
	clock.ticks_remaining = maxi(0, int(d.get("ticks_remaining", clock.total_ticks)))
	clock.accrued_burn = maxi(0, int(d.get("accrued_burn", 0)))
	clock.accrued_interest = maxi(0, int(d.get("accrued_interest", 0)))
	clock.total_burn_accrued = maxi(0, int(d.get("total_burn_accrued", 0)))
	clock.total_interest_accrued = maxi(0, int(d.get("total_interest_accrued", 0)))
	clock.total_debt_serviced = maxi(0, int(d.get("total_debt_serviced", 0)))
	clock.total_ticks_added_by_tributes = maxi(0, int(d.get("total_ticks_added_by_tributes", 0)))
	clock._burn_subunits = maxi(0, int(d.get("_burn_subunits", 0)))
	clock._interest_subunits = maxi(0, int(d.get("_interest_subunits", 0)))
	# Recompute stage strictly from ticks_remaining and total_ticks to prevent save-state divergence
	clock.stage = clock._compute_stage(clock.ticks_remaining, clock.total_ticks)
	clock.stage_transition_pending_interrupt = bool(d.get("stage_transition_pending_interrupt", false))
	return clock
