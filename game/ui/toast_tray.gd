class_name ToastTray
extends RefCounted
## Design system Toast (Toast.dc.html): a short-lived notice for trading fills, rejected
## orders and GalNet alerts. This is the model only: a queue of {kind, text, age}.
## The age moves by advance(delta) with the UI's frame delta, never by the sim clock or
## a wall-clock read, and nothing here reads or writes sim state, saves or hashes, so a
## toast can never change a run. The view (Main) draws the visible toasts as plain
## Controls that ignore the mouse and take no focus.

const KIND_FILLED: String = "filled"
const KIND_REJECTED: String = "rejected"
const KIND_INFO: String = "info"
const KINDS: Array[String] = [KIND_FILLED, KIND_REJECTED, KIND_INFO]

## Seconds a toast stays up, and how many show at once (older ones are dropped first).
const LIFETIME: float = 3.5
const MAX_VISIBLE: int = 3
## The pop / shake of the design (250 ms in 3 steps).
const ANIM_SECONDS: float = 0.25
## One frame's delta is clamped to this, so a wake-sized spike cannot eat a toast whole.
const MAX_STEP: float = 0.25

var toasts: Array = []  ## newest last: {"kind": String, "text": String, "age": float}


func push(kind: String, text: String) -> void:
	if not KINDS.has(kind) or text == "":
		return
	toasts.append({"kind": kind, "text": text, "age": 0.0})
	while toasts.size() > MAX_VISIBLE:
		toasts.pop_front()


## Ages every toast and drops the expired ones. Returns true when the set changed.
func advance(delta: float) -> bool:
	var step: float = clampf(delta, 0.0, MAX_STEP)
	var before: int = toasts.size()
	var keep: Array = []
	for t in toasts:
		t["age"] = float(t["age"]) + step
		if float(t["age"]) < LIFETIME:
			keep.append(t)
	toasts = keep
	return keep.size() != before


func clear() -> void:
	toasts = []


func is_empty() -> bool:
	return toasts.is_empty()


## 0, 1 or 2 for the three animation steps while the toast is young, -1 once settled.
static func anim_step(age: float) -> int:
	if age >= ANIM_SECONDS:
		return -1
	return clampi(int(age / ANIM_SECONDS * 3.0), 0, 2)


## The pop scale (ag-pop) of a step: .86 -> 1.06 -> 1.
static func pop_scale(step: int) -> float:
	return [0.86, 1.06, 1.0][clampi(step, 0, 2)] if step >= 0 else 1.0


## The shake offset in px (ag-shake) of a step: -6, +6, 0.
static func shake_offset(step: int) -> float:
	return [-6.0, 6.0, 0.0][clampi(step, 0, 2)] if step >= 0 else 0.0
