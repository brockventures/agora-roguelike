class_name SteamHooks
extends RefCounted
## Wires gameplay events to the Steam layer (#27). Bound to one RunController
## (and its CrisisDeck); Main re-binds whenever the controller is replaced.
## Owner must keep a reference: the controller's signals do not keep this alive.

const ACH_FIRST_CHAPTER_11: String = "FIRST_CHAPTER_11"
const ACH_WITNESS_COLLAPSE: String = "WITNESS_COLLAPSE"
## Event-hook achievements this class unlocks directly (the rest are stat thresholds).
const EVENT_ACHIEVEMENTS: Array[String] = [ACH_FIRST_CHAPTER_11, ACH_WITNESS_COLLAPSE]

var service: SteamService = null
var _rc: RunController = null
var _deck: CrisisDeck = null


func _init(p_service: SteamService = null) -> void:
	service = p_service if p_service != null else SteamService.shared()


func bind(rc: RunController) -> void:
	unbind()
	_rc = rc
	if rc == null:
		return
	rc.bankruptcy_filed.connect(_on_filed)
	rc.run_collapsed.connect(_on_collapsed)
	rc.corp_ended.connect(_on_corp_ended)
	rc.round_advanced.connect(_on_round)
	_deck = rc.crisis_deck
	if _deck != null:
		_deck.crisis_expired.connect(_on_crisis_expired)


func unbind() -> void:
	if _rc != null:
		_disconnect(_rc.bankruptcy_filed, _on_filed)
		_disconnect(_rc.run_collapsed, _on_collapsed)
		_disconnect(_rc.corp_ended, _on_corp_ended)
		_disconnect(_rc.round_advanced, _on_round)
	if _deck != null:
		_disconnect(_deck.crisis_expired, _on_crisis_expired)
	_rc = null
	_deck = null


static func _disconnect(sig: Signal, c: Callable) -> void:
	if sig.is_connected(c):
		sig.disconnect(c)


func _on_filed(_report: Dictionary) -> void:
	service.unlock(ACH_FIRST_CHAPTER_11)
	if _rc != null:
		service.max_stat("bankruptcies_filed", _rc.profile.bankruptcies_filed)


func _on_collapsed() -> void:
	service.unlock(ACH_WITNESS_COLLAPSE)


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
