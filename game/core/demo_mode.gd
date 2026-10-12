class_name DemoMode
extends RefCounted
## Steam Next Fest & Standalone Public Demo Target Rules (#39).
##
## Enforces demo constraints for Steam Next Fest and public showcase builds:
## 1. 3-Quarter Run Limit: Standard campaign runs for 120 rounds (4 quarters of 30 rounds).
##    Demo builds cap runs at 3 quarters (90 rounds) of market simulation and astrodynamics.
## 2. Detection: Activates if:
##    - Godot custom feature tag 'demo' is present (OS.has_feature("demo"))
##    - Environment variable AGORA_DEMO == "1"
##    - Command line argument '--demo' passed to engine/launcher
## 3. Completion Callout: Upon reaching round 90, the demo run finishes gracefully,
##    awarding severance and displaying the Steam Next Fest Wishlist prompt.

const DEMO_MAX_QUARTERS: int = 3
const ROUNDS_PER_QUARTER: int = 30
const DEMO_MAX_ROUNDS: int = DEMO_MAX_QUARTERS * ROUNDS_PER_QUARTER # 90 rounds
const FULL_RUN_ROUNDS: int = DoomsdayClock.DEFAULT_RUN_ROUNDS # 120 rounds

## Forced override for testing (-1: use auto-detection, 0: force disabled, 1: force enabled).
static var _forced_mode: int = -1

static func is_demo() -> bool:
	if _forced_mode >= 0:
		return _forced_mode == 1
	if OS.has_feature("demo"):
		return true
	if OS.get_environment("AGORA_DEMO") == "1":
		return true
	var args := OS.get_cmdline_args()
	for a in args:
		if a == "--demo":
			return true
	var uargs := OS.get_cmdline_user_args()
	for a in uargs:
		if a == "--demo":
			return true
	return false

static func set_forced_mode(val: int) -> void:
	_forced_mode = val

static func get_max_rounds() -> int:
	return DEMO_MAX_ROUNDS if is_demo() else FULL_RUN_ROUNDS

static func is_round_limit_reached(round_num: int) -> bool:
	return is_demo() and round_num >= DEMO_MAX_ROUNDS
