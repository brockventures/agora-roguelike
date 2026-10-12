class_name SovereignTakeover
extends RefCounted
## Secret Final Boss: Sol Government Nationalization & Sovereign Buyout (#33, Part of #8 Epic 2 & #32).
##
## Mechanics:
## 1. Sovereign Takeover Clock: Once the player achieves monopoly over Sector Barons and initiates
##    the Sol Rescue Project, the dying Sol System Government launches an emergency nationalization
##    decree with an asset seizure countdown timer.
## 2. Expropriation Threat: If the countdown reaches zero without counter-measures, the government
##    seizes corporate assets and the run ends in "nationalized".
## 3. Tri-Fold Counter-Strategies / Win Conditions:
##    - Cabinet Buyout (Liquid Liquidity): Bribe the corrupt cabinet ministers (base 45,000 CR,
##      discounted with corrupt_regulator or regulatory policies).
##    - Debt Choke (Sovereign Debt Leverage): Exploit high debt leverage (>= 35,000 CR principal debt,
##      or >= 20,000 CR with debt-leverage perks/policies) to force a sovereign treasury insolvency default.
##    - Sovereign Privatization (State Buyout): Outright hostile buyout and privatization of the Sol
##      System Government into a corporate subsidiary (requires monopoly + 75,000 CR, discounted with buyout perks).

const VERSION: int = 1
const DEFAULT_PATH: String = "res://data/sovereign.json"

const STATUS_INACTIVE: String = "inactive"
const STATUS_ACTIVE: String = "active"
const STATUS_BRIBED: String = "bribed"
const STATUS_DEBT_CHOKED: String = "debt_choked"
const STATUS_PRIVATIZED: String = "privatized"
const STATUS_EXPIRED: String = "expired"

var decree_title: String = "Emergency Sovereign Expropriation Decree"
var status: String = STATUS_INACTIVE
var total_ticks: int = 13500
var ticks_remaining: int = 13500
var start_tick: int = 0
var timer_rounds: int = 15
var ticks_per_round: int = 900

var bribe_cost_cr: int = 45000
var bribe_discount_bps: int = 2500
var debt_choke_required_debt: int = 35000
var debt_choke_leverage_debt: int = 20000
var privatize_cost_cr: int = 75000
var privatize_discount_bps: int = 3333

var severance_bonus: Dictionary = {
	STATUS_BRIBED: 300,
	STATUS_DEBT_CHOKED: 500,
	STATUS_PRIVATIZED: 800,
}

var resolution_method: String = ""
var resolution_award: int = 0


static func load_default(path: String = DEFAULT_PATH) -> SovereignTakeover:
	var st := SovereignTakeover.new()
	if not FileAccess.file_exists(path):
		return st
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return st
	var json_str := file.get_as_text()
	var test_json_conv := JSON.new()
	var parse_err := test_json_conv.parse(json_str)
	if parse_err != OK or not (test_json_conv.data is Dictionary):
		return st
	var data: Dictionary = test_json_conv.data
	st.decree_title = str(data.get("decree_title", st.decree_title))
	st.timer_rounds = int(data.get("timer_rounds", 15))
	st.ticks_per_round = int(data.get("ticks_per_round", 900))
	st.total_ticks = st.timer_rounds * st.ticks_per_round
	st.ticks_remaining = st.total_ticks
	st.bribe_cost_cr = int(data.get("bribe_cost_cr", 45000))
	st.bribe_discount_bps = int(data.get("bribe_discount_bps", 2500))
	st.debt_choke_required_debt = int(data.get("debt_choke_required_debt", 35000))
	st.debt_choke_leverage_debt = int(data.get("debt_choke_leverage_debt", 20000))
	st.privatize_cost_cr = int(data.get("privatize_cost_cr", 75000))
	st.privatize_discount_bps = int(data.get("privatize_discount_bps", 3333))
	var sev = data.get("severance_bonus")
	if sev is Dictionary:
		for k in sev:
			st.severance_bonus[str(k)] = int(sev[k])
	return st


func start(current_tick: int) -> void:
	status = STATUS_ACTIVE
	start_tick = current_tick
	ticks_remaining = total_ticks
	resolution_method = ""
	resolution_award = 0


func step_tick() -> bool:
	if status != STATUS_ACTIVE:
		return false
	if ticks_remaining > 0:
		ticks_remaining -= 1
		if ticks_remaining == 0:
			status = STATUS_EXPIRED
			return true
	return false


func is_active() -> bool:
	return status == STATUS_ACTIVE


func is_resolved() -> bool:
	return status in [STATUS_BRIBED, STATUS_DEBT_CHOKED, STATUS_PRIVATIZED]


func is_expired() -> bool:
	return status == STATUS_EXPIRED


func rounds_remaining(tpr: int = 900) -> int:
	var denom: int = maxi(1, tpr if tpr > 0 else ticks_per_round)
	return ceili(float(ticks_remaining) / float(denom))


func get_bribe_cost(has_regulatory_perk: bool) -> int:
	if has_regulatory_perk:
		return bribe_cost_cr * (10000 - bribe_discount_bps) / 10000
	return bribe_cost_cr


func can_bribe(cr: int, has_regulatory_perk: bool) -> bool:
	return is_active() and cr >= get_bribe_cost(has_regulatory_perk)


func can_debt_choke(debt_cr: int, has_debt_leverage: bool) -> bool:
	if not is_active():
		return false
	var req: int = debt_choke_leverage_debt if has_debt_leverage else debt_choke_required_debt
	return debt_cr >= req


func get_privatize_cost(has_buyout_perk: bool) -> int:
	if has_buyout_perk:
		return privatize_cost_cr * (10000 - privatize_discount_bps) / 10000
	return privatize_cost_cr


func can_privatize(cr: int, has_monopoly: bool, has_buyout_perk: bool) -> bool:
	return is_active() and has_monopoly and cr >= get_privatize_cost(has_buyout_perk)


func resolve(method: String) -> int:
	if not (method in [STATUS_BRIBED, STATUS_DEBT_CHOKED, STATUS_PRIVATIZED]):
		return 0
	status = method
	resolution_method = method
	resolution_award = int(severance_bonus.get(method, 0))
	return resolution_award


func to_dict() -> Dictionary:
	return {
		"status": status,
		"decree_title": decree_title,
		"total_ticks": total_ticks,
		"ticks_remaining": ticks_remaining,
		"start_tick": start_tick,
		"timer_rounds": timer_rounds,
		"ticks_per_round": ticks_per_round,
		"bribe_cost_cr": bribe_cost_cr,
		"bribe_discount_bps": bribe_discount_bps,
		"debt_choke_required_debt": debt_choke_required_debt,
		"debt_choke_leverage_debt": debt_choke_leverage_debt,
		"privatize_cost_cr": privatize_cost_cr,
		"privatize_discount_bps": privatize_discount_bps,
		"severance_bonus": severance_bonus.duplicate(),
		"resolution_method": resolution_method,
		"resolution_award": resolution_award,
	}


static func from_dict(d: Dictionary) -> SovereignTakeover:
	var st := SovereignTakeover.new()
	st.status = str(d.get("status", STATUS_INACTIVE))
	st.decree_title = str(d.get("decree_title", st.decree_title))
	st.total_ticks = int(d.get("total_ticks", 13500))
	st.ticks_remaining = int(d.get("ticks_remaining", st.total_ticks))
	st.start_tick = int(d.get("start_tick", 0))
	st.timer_rounds = int(d.get("timer_rounds", 15))
	st.ticks_per_round = int(d.get("ticks_per_round", 900))
	st.bribe_cost_cr = int(d.get("bribe_cost_cr", 45000))
	st.bribe_discount_bps = int(d.get("bribe_discount_bps", 2500))
	st.debt_choke_required_debt = int(d.get("debt_choke_required_debt", 35000))
	st.debt_choke_leverage_debt = int(d.get("debt_choke_leverage_debt", 20000))
	st.privatize_cost_cr = int(d.get("privatize_cost_cr", 75000))
	st.privatize_discount_bps = int(d.get("privatize_discount_bps", 3333))
	var sb = d.get("severance_bonus")
	if sb is Dictionary:
		for k in sb:
			st.severance_bonus[str(k)] = int(sb[k])
	st.resolution_method = str(d.get("resolution_method", ""))
	st.resolution_award = int(d.get("resolution_award", 0))
	return st
