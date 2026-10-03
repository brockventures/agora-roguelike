class_name DoomsdayClock
extends RefCounted
## Sol System Doomsday Clock & Debt Burn Engine.
##
## Part of Epic 2 (#8) / Issue #9.
##
## Key Architectural Invariants:
## 1. Doomsday Countdown: Tracks the countdown toward Sol System collapse.
##    Progresses through discrete threat stages (NORMAL, UNSTABLE, CRITICAL, IMMINENT, COLLAPSED).
## 2. Escalating Fiscal Burn: Operating debt burn escalates non-linearly with collapse stages,
##    forcing high-risk arbitrage speculation to outrun compounding liability.
## 3. Stabilization Tributes: Delivering vital supplies or paying stabilization funding to Sol
##    station extends the countdown clock and can de-escalate crisis stages.
## 4. Atomic Interrupt Hook: Integrates with SimClock. Transitions between crisis stages or
##    terminal collapse trigger atomic auto-pause interrupts so players can react immediately.
## 5. Determinism & Serialization: Pure RefCounted with full to_dict() / from_dict() roundtrip.

signal stage_changed(old_stage: int, new_stage: int)
signal time_updated(time_remaining: float, total_time: float)
signal collapsed()
signal debt_burn_accrued(amount: float, total_debt: float)
signal debt_serviced(amount: int, remaining_debt: float)
signal tribute_paid(amount: int, time_added: float)

enum Stage {
	NORMAL = 0,
	UNSTABLE = 1,
	CRITICAL = 2,
	IMMINENT = 3,
	COLLAPSED = 4,
}

const DEFAULT_TOTAL_TIME: float = 600.0  # 10 minutes baseline
const DEFAULT_DEBT: float = 50000.0      # 50,000 credit opening obligation
const DEFAULT_BASE_BURN_RATE: float = 25.0  # 25 credits/sec baseline upkeep
const DEFAULT_INTEREST_RATE: float = 0.0005 # ~3%/min compounding interest

const UNSTABLE_RATIO: float = 0.75   # <= 75% time remaining -> UNSTABLE
const CRITICAL_RATIO: float = 0.40   # <= 40% time remaining -> CRITICAL
const IMMINENT_RATIO: float = 0.15   # <= 15% time remaining -> IMMINENT
const COLLAPSED_RATIO: float = 0.0   # <= 0.0s time remaining -> COLLAPSED

const STAGE_BURN_MULTIPLIERS := {
	Stage.NORMAL: 1.0,
	Stage.UNSTABLE: 1.5,
	Stage.CRITICAL: 2.5,
	Stage.IMMINENT: 5.0,
	Stage.COLLAPSED: 10.0,
}

var total_time: float = DEFAULT_TOTAL_TIME
var time_remaining: float = DEFAULT_TOTAL_TIME
var stage: Stage = Stage.NORMAL

var principal_debt: float = DEFAULT_DEBT
var accumulated_interest: float = 0.0
var total_burn_accrued: float = 0.0
var total_debt_serviced: float = 0.0
var total_time_added_by_tributes: float = 0.0

var base_burn_rate: float = DEFAULT_BASE_BURN_RATE
var interest_rate: float = DEFAULT_INTEREST_RATE

# Interrupt hook flag for SimClock integration
var stage_transition_pending_interrupt: bool = false

func _init(
	p_total_time: float = DEFAULT_TOTAL_TIME,
	p_debt: float = DEFAULT_DEBT,
	p_base_burn: float = DEFAULT_BASE_BURN_RATE,
	p_interest: float = DEFAULT_INTEREST_RATE
) -> void:
	total_time = p_total_time if p_total_time > 0.0 else DEFAULT_TOTAL_TIME
	time_remaining = total_time
	principal_debt = maxf(0.0, p_debt)
	base_burn_rate = maxf(0.0, p_base_burn)
	interest_rate = maxf(0.0, p_interest)
	stage = _compute_stage(time_remaining, total_time)

func get_stage_multiplier(p_stage: Stage) -> float:
	return STAGE_BURN_MULTIPLIERS.get(p_stage, 1.0)

func get_current_burn_rate() -> float:
	return base_burn_rate * get_stage_multiplier(stage)

func get_total_debt() -> float:
	return principal_debt + accumulated_interest

func get_time_ratio() -> float:
	if total_time <= 0.0:
		return 0.0
	return clampf(time_remaining / total_time, 0.0, 1.0)

func _compute_stage(rem: float, tot: float) -> Stage:
	if rem <= 0.0:
		return Stage.COLLAPSED
	if tot <= 0.0:
		return Stage.COLLAPSED
	var ratio := rem / tot
	if ratio <= IMMINENT_RATIO:
		return Stage.IMMINENT
	elif ratio <= CRITICAL_RATIO:
		return Stage.CRITICAL
	elif ratio <= UNSTABLE_RATIO:
		return Stage.UNSTABLE
	else:
		return Stage.NORMAL

func should_auto_pause() -> bool:
	if stage_transition_pending_interrupt:
		stage_transition_pending_interrupt = false
		return true
	return false

func step(delta: float) -> void:
	if delta <= 0.0 or is_nan(delta) or not is_finite(delta):
		return
	if stage == Stage.COLLAPSED:
		return

	# Advance countdown
	time_remaining = maxf(0.0, time_remaining - delta)

	# Accrue operating burn & compounding debt
	var current_multiplier := get_stage_multiplier(stage)
	var burn_this_step := delta * base_burn_rate * current_multiplier
	var interest_this_step := delta * interest_rate * get_total_debt()

	accumulated_interest += burn_this_step + interest_this_step
	total_burn_accrued += burn_this_step

	debt_burn_accrued.emit(burn_this_step + interest_this_step, get_total_debt())
	time_updated.emit(time_remaining, total_time)

	# Check stage progression
	var new_stage := _compute_stage(time_remaining, total_time)
	if new_stage != stage:
		var old_stage := stage
		stage = new_stage
		stage_transition_pending_interrupt = true
		stage_changed.emit(old_stage, new_stage)

		if stage == Stage.COLLAPSED:
			collapsed.emit()

func service_debt(amount: int) -> int:
	if amount <= 0:
		return 0

	var payment := float(amount)
	var paid: float = 0.0

	# Pay off accumulated interest/burn first
	if accumulated_interest > 0.0:
		var pay_interest := minf(payment, accumulated_interest)
		accumulated_interest -= pay_interest
		payment -= pay_interest
		paid += pay_interest

	# Then pay down principal debt
	if payment > 0.0 and principal_debt > 0.0:
		var pay_principal := minf(payment, principal_debt)
		principal_debt -= pay_principal
		paid += pay_principal

	total_debt_serviced += paid
	var int_paid := int(round(paid))
	debt_serviced.emit(int_paid, get_total_debt())
	return int_paid

func apply_tribute(amount: int, seconds_per_credit: float = 0.05) -> float:
	if amount <= 0 or stage == Stage.COLLAPSED:
		return 0.0

	var time_added: float = float(amount) * seconds_per_credit
	time_remaining += time_added
	total_time_added_by_tributes += time_added

	# De-escalate stage if stabilization achieved sufficient threshold
	var new_stage := _compute_stage(time_remaining, total_time)
	if new_stage != stage:
		var old_stage := stage
		stage = new_stage
		stage_transition_pending_interrupt = true
		stage_changed.emit(old_stage, new_stage)

	time_updated.emit(time_remaining, total_time)
	tribute_paid.emit(amount, time_added)
	return time_added

func to_dict() -> Dictionary:
	return {
		"total_time": total_time,
		"time_remaining": time_remaining,
		"stage": int(stage),
		"principal_debt": principal_debt,
		"accumulated_interest": accumulated_interest,
		"total_burn_accrued": total_burn_accrued,
		"total_debt_serviced": total_debt_serviced,
		"total_time_added_by_tributes": total_time_added_by_tributes,
		"base_burn_rate": base_burn_rate,
		"interest_rate": interest_rate,
		"stage_transition_pending_interrupt": stage_transition_pending_interrupt,
	}

static func from_dict(d: Dictionary) -> DoomsdayClock:
	var clock := DoomsdayClock.new(
		float(d.get("total_time", DEFAULT_TOTAL_TIME)),
		float(d.get("principal_debt", DEFAULT_DEBT)),
		float(d.get("base_burn_rate", DEFAULT_BASE_BURN_RATE)),
		float(d.get("interest_rate", DEFAULT_INTEREST_RATE))
	)
	clock.time_remaining = maxf(0.0, float(d.get("time_remaining", clock.total_time)))
	clock.accumulated_interest = maxf(0.0, float(d.get("accumulated_interest", 0.0)))
	clock.total_burn_accrued = maxf(0.0, float(d.get("total_burn_accrued", 0.0)))
	clock.total_debt_serviced = maxf(0.0, float(d.get("total_debt_serviced", 0.0)))
	clock.total_time_added_by_tributes = maxf(0.0, float(d.get("total_time_added_by_tributes", 0.0)))
	clock.stage = Stage(int(d.get("stage", Stage.NORMAL)))
	clock.stage_transition_pending_interrupt = bool(d.get("stage_transition_pending_interrupt", false))
	return clock
