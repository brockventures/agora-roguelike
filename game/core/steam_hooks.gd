class_name SteamHooks
extends RefCounted
## Wires gameplay events to the Steam layer (#27). Bound to one RunController
## (and its CrisisDeck); Main re-binds whenever the controller is replaced.
## Owner must keep a reference: the controller's signals do not keep this alive.

const ACH_FIRST_CHAPTER_11: String = "FIRST_CHAPTER_11"
const ACH_WITNESS_COLLAPSE: String = "WITNESS_COLLAPSE"
## Event-hook achievements this class unlocks directly (the rest are stat thresholds).
const ACH_SOL_RESCUED: String = "SOL_RESCUED"
## Finishing the last core beat of the first-hour tutorial (#36, design section 12).
const ACH_ORIENTATION_COMPLETE: String = "ORIENTATION_COMPLETE"
const EVENT_ACHIEVEMENTS: Array[String] = [ACH_FIRST_CHAPTER_11, ACH_WITNESS_COLLAPSE, ACH_SOL_RESCUED, ACH_ORIENTATION_COMPLETE]

var service: SteamService = null
var _rc: RunController = null
var _deck: CrisisDeck = null
var _onb: Onboarding = null


func _init(p_service: SteamService = null) -> void:
	service = p_service if p_service != null else SteamService.shared()


func bind(rc: RunController) -> void:
	unbind()
	_rc = rc
	if rc == null:
		return
	rc.bankruptcy_filed.connect(_on_filed)
	rc.run_collapsed.connect(_on_collapsed)
	rc.run_rescued.connect(_on_rescued)
	rc.corp_ended.connect(_on_corp_ended)
	rc.round_advanced.connect(_on_round)
	_deck = rc.crisis_deck
	if _deck != null:
		_deck.crisis_expired.connect(_on_crisis_expired)


func unbind() -> void:
	if _rc != null:
		_disconnect(_rc.bankruptcy_filed, _on_filed)
		_disconnect(_rc.run_collapsed, _on_collapsed)
		_disconnect(_rc.run_rescued, _on_rescued)
		_disconnect(_rc.corp_ended, _on_corp_ended)
		_disconnect(_rc.round_advanced, _on_round)
	if _deck != null:
		_disconnect(_deck.crisis_expired, _on_crisis_expired)
	_rc = null
	_deck = null


## Follows the tutorial model (#36). Reports the highest core beat done as the max-stat
## `onboarding_step` and unlocks ORIENTATION_COMPLETE with the last core beat. Reads the model
## only: no run state, no draw stream, no network. A saved tutorial is reported on bind too, so
## progress made offline or before Steam arrived is not lost.
func bind_onboarding(model: Onboarding) -> void:
	unbind_onboarding()
	_onb = model
	if model == null:
		return
	model.beat_completed.connect(_on_beat_completed)
	_report_onboarding()


func unbind_onboarding() -> void:
	if _onb != null:
		_disconnect(_onb.beat_completed, _on_beat_completed)
	_onb = null


func _on_beat_completed(_id: String) -> void:
	_report_onboarding()


func _report_onboarding() -> void:
	if _onb == null:
		return
	var step: int = _onb.core_step()
	if step > 0:
		service.max_stat("onboarding_step", step)
	var last: String = _onb.last_core_id()
	if last != "" and _onb.is_seen(last):
		service.unlock(ACH_ORIENTATION_COMPLETE)


static func _disconnect(sig: Signal, c: Callable) -> void:
	if sig.is_connected(c):
		sig.disconnect(c)


func _on_filed(_report: Dictionary) -> void:
	service.unlock(ACH_FIRST_CHAPTER_11)
	if _rc != null:
		service.max_stat("bankruptcies_filed", _rc.profile.bankruptcies_filed)


func _on_collapsed() -> void:
	service.unlock(ACH_WITNESS_COLLAPSE)


## The Rescue Project was finished (#32): the win achievement and its stat.
func _on_rescued() -> void:
	service.unlock(ACH_SOL_RESCUED)
	if _rc != null:
		service.max_stat("rescues_completed", _rc.profile.rescues_completed)


## A corp ended (filing or collapse): its peak is final and the profile counts moved.
func _on_corp_ended(_summary: Dictionary) -> void:
	if _rc == null:
		return
	service.max_stat("peak_net_worth", _rc.peak_net_worth)
	service.max_stat("runs_completed", _rc.profile.runs_completed)


func _on_round(_round_num: int) -> void:
	if _rc != null:
		service.max_stat("peak_net_worth", _rc.peak_net_worth)


## A crisis ran its course: the player survived it.
func _on_crisis_expired(_crisis: Dictionary) -> void:
	service.add_stat("crises_survived", 1)
