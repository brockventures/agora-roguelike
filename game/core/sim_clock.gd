class_name SimClock
extends RefCounted
## Deterministic fixed-step simulation clock with accumulator, multi-speed sub-ticks,
## and auto-pause interrupt hooks.
##
## Part of Epic 1 (#1) / Issue #6.
##
## Key Architectural Invariants:
## 1. Zero Time on Pause/Sleep (Ryan Rule): When paused or suspended, in-game time NEVER advances.
##    Zero ticks are processed while the game is frozen.
## 2. Fixed Sub-Ticks: Discrete fixed-step sub-ticks per game turn. Speeds (1x, 2x, 5x) execute N
##    discrete sub-ticks per frame rather than scaling delta or using an oversized tick.
## 3. Accumulator Pattern: Fixed-step accumulator carrying remainder to the next frame.
## 4. Suspend/Wake Detection (Marvin Finding): Evaluated prior to the lag clamp. Raw frame delta > 1.0s
##    indicates a system sleep freeze (e.g. Steam Deck suspend). Triggers immediate auto-pause and
##    resets accumulator remainder to 0.0s to discard missed real-world time completely.
## 5. Spiral-of-Death Clamp: Frame delta is clamped to 0.25s upper bound to prevent simulation
##    cascades on standard frame drops.
## 6. Deterministic Step Signature: step(delta: float) -> int returns the exact count of sub-ticks executed.
## 7. Atomic Interrupt Hooks: Registered callables evaluate strictly between sub-ticks. If any hook
##    returns true, the clock auto-pauses and aborts the sub-tick loop immediately.
## 8. Interpolation Decoupling: get_interpolation_alpha() returns normalized sub-frame progress [0.0, 1.0].

signal sub_ticked(total_ticks: int)
signal paused_changed(is_paused: bool)
signal auto_paused(reason: String)
signal speed_changed(new_speed: int)

const DEFAULT_TICK_DELTA: float = 1.0 / 60.0
const MAX_DELTA_CLAMP: float = 0.25
const SUSPEND_THRESHOLD: float = 1.0
const VALID_SPEEDS: Array[int] = [1, 2, 5]

var tick_delta: float = DEFAULT_TICK_DELTA
var speed: int = 1
var paused: bool = false
var accumulator: float = 0.0
var total_ticks: int = 0
var auto_paused_reason: String = ""
var interrupt_hooks: Array[Callable] = []

func _init(p_tick_delta: float = DEFAULT_TICK_DELTA, p_speed: int = 1) -> void:
	tick_delta = p_tick_delta if p_tick_delta > 0.0 else DEFAULT_TICK_DELTA
	set_speed(p_speed)

func set_speed(p_speed: int) -> bool:
	if p_speed not in VALID_SPEEDS:
		return false
	if speed != p_speed:
		speed = p_speed
		speed_changed.emit(speed)
	return true

func pause() -> void:
	set_paused(true)

func resume() -> void:
	set_paused(false)

func set_paused(p_paused: bool) -> void:
	if paused != p_paused:
		paused = p_paused
		if not paused:
			auto_paused_reason = ""
		paused_changed.emit(paused)

func reset() -> void:
	accumulator = 0.0
	total_ticks = 0
	paused = false
	auto_paused_reason = ""

func register_interrupt_hook(hook: Callable) -> void:
	if hook not in interrupt_hooks:
		interrupt_hooks.append(hook)

func unregister_interrupt_hook(hook: Callable) -> void:
	interrupt_hooks.erase(hook)

func clear_interrupt_hooks() -> void:
	interrupt_hooks.clear()

func get_interpolation_alpha() -> float:
	if tick_delta <= 0.0:
		return 0.0
	return clampf(accumulator / tick_delta, 0.0, 1.0)

func step(delta: float) -> int:
	# 1. Zero Time on Pause/Sleep: No simulation advance while paused
	if paused:
		return 0

	# 2. Suspend/Wake Detection (Evaluated BEFORE lag clamp)
	# Raw frame delta > 1.0s indicates host/device suspend (e.g. Steam Deck sleep)
	if delta > SUSPEND_THRESHOLD:
		paused = true
		auto_paused_reason = "system_suspend"
		accumulator = 0.0
		auto_paused.emit("system_suspend")
		paused_changed.emit(true)
		return 0

	# 3. Discard non-positive delta
	if delta <= 0.0:
		return 0

	# 4. Spiral-of-Death Clamp: Bound delta to 0.25s max to prevent lag cascades
	var effective_delta: float = minf(delta, MAX_DELTA_CLAMP)
	accumulator += effective_delta

	# 5. Fixed-step accumulator loop
	var ticks_executed: int = 0
	while accumulator >= tick_delta:
		accumulator -= tick_delta

		# Execute discrete sub-ticks for this tick step
		for _s in range(speed):
			total_ticks += 1
			ticks_executed += 1
			sub_ticked.emit(total_ticks)

			# Evaluate atomic interrupt hooks strictly between sub-ticks
			var interrupted: bool = false
			for hook in interrupt_hooks:
				if hook.call():
					paused = true
					auto_paused_reason = "interrupt"
					auto_paused.emit("interrupt")
					paused_changed.emit(true)
					interrupted = true
					break

			if interrupted:
				return ticks_executed

	return ticks_executed

func to_dict() -> Dictionary:
	return {
		"tick_delta": tick_delta,
		"speed": speed,
		"paused": paused,
		"accumulator": accumulator,
		"total_ticks": total_ticks,
		"auto_paused_reason": auto_paused_reason,
	}

static func from_dict(d: Dictionary) -> SimClock:
	var clock := SimClock.new(
		float(d.get("tick_delta", DEFAULT_TICK_DELTA)),
		int(d.get("speed", 1))
	)
	clock.paused = bool(d.get("paused", false))
	clock.accumulator = float(d.get("accumulator", 0.0))
	clock.total_ticks = int(d.get("total_ticks", 0))
	clock.auto_paused_reason = str(d.get("auto_paused_reason", ""))
	return clock
