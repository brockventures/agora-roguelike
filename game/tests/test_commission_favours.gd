extends RefCounted
## Commission favours (#149, PR 1b): Enforcement (a tighter Unstable threshold), Customs (one
## belt toll and one docking toll waived per corp, never on a smuggle lane) and Treasury (one
## retaliation fine deferred per corp). Active only when the commissioner is retained; with no
## consultants every number below is the pre-favour one.

const TPR: int = 30
const ARES: String = "ares_heavy"

func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))

func _rc(consultants: Array[String] = [], cr: int = 100000) -> RunController:
	var p := MetaProfile.new()
	p.consultants = consultants.duplicate()
	var rc := RunController.new(p, 21, null, {}, TPR)
	rc.cr = cr
	return rc

# --- Enforcement ---

func test_enforcement_lowers_the_unstable_threshold_only_when_retained() -> String:
	if Commission.param("enforcement", "unstable_ratio_bps", 0) != 7000:
		return "data param is not 7000"
	if Commission.has_favour(null, "enforcement") or Commission.has_favour(_rc(["enforcement"] as Array[String]).profile, "chair"):
		return "has_favour must be false for null profile and chair"
	var on := _rc(["enforcement"] as Array[String])
	if on.doomsday.unstable_ratio_bps != 7000:
		return "retained: %d" % on.doomsday.unstable_ratio_bps
	var off := _rc()
	if off.doomsday.unstable_ratio_bps != 7500:
		return "not retained: %d" % off.doomsday.unstable_ratio_bps
	return "ok"

func test_enforcement_survives_a_save() -> String:
	var rc := _rc(["enforcement"] as Array[String])
	var back := RunController.from_dict(_json(rc.to_dict()))
	if back.doomsday.unstable_ratio_bps != 7000:
		return "after from_dict: %d" % back.doomsday.unstable_ratio_bps
	return "ok"

# --- Customs ---

func _belt_hop(rc: RunController) -> Dictionary:
	# Put the ship back at earth with an empty transit, so the next departure is a fresh belt leg.
	rc.transit = {}
	rc.docked_at = "earth"
	var before: int = rc.cr
	var res: Dictionary = rc.depart("ceres")
	res["cr_paid"] = before - rc.cr
	return res

func test_customs_waives_the_first_belt_toll_once() -> String:
	var rc := _rc(["customs"] as Array[String])
	var first := _belt_hop(rc)
	if not bool(first["ok"]) or int(first["cr_paid"]) != 0 or not rc.customs_waiver_used:
		return "first: ok %s paid %d used %s" % [str(first["ok"]), int(first["cr_paid"]), str(rc.customs_waiver_used)]
	var second := _belt_hop(rc)
	if not bool(second["ok"]) or int(second["cr_paid"]) != Transit.calculate_toll("earth", "ceres", 0.0, rc.toll_discount_bps()) or int(second["cr_paid"]) <= 0:
		return "second should pay the normal toll, paid %d" % int(second["cr_paid"])
	return "ok"

func test_no_customs_favour_means_the_normal_belt_toll() -> String:
	var rc := _rc()
	var first := _belt_hop(rc)
	if int(first["cr_paid"]) <= 0 or rc.customs_waiver_used:
		return "normal toll expected, paid %d used %s" % [int(first["cr_paid"]), str(rc.customs_waiver_used)]
	return "ok"

func test_smuggle_lanes_are_never_waived() -> String:
	var rc := _rc(["customs"] as Array[String])
	var lanes: Dictionary = Corridors.data().get("smuggle_lanes", {})
	if lanes.is_empty():
		return "no smuggle lanes in data"
	var id: String = str(lanes.keys()[0])
	rc.docked_at = str(lanes[id]["a"])
	var dest: String = str(lanes[id]["b"])
	# The shipped dark_run lane carries toll_cr 0, so the check is the flag: a lane leg never
	# claims the customs waiver, whatever its toll.
	var check: Dictionary = rc.can_depart(dest, null, id)
	if bool(check.get("customs_waived", false)):
		return "lane leg claimed the waiver"
	var res: Dictionary = rc.depart(dest, null, id)
	if not bool(res["ok"]) or rc.customs_waiver_used:
		return "lane departure set the flag: ok %s used %s" % [str(res["ok"]), str(rc.customs_waiver_used)]
	return "ok"

func test_docking_toll_is_waived_once_when_the_flag_is_unused() -> String:
	var rc := _rc(["customs"] as Array[String])
	rc.world = Barons.for_new_run()
	var station := "mars"
	var due: int = rc.world.docking_toll_due(StationMarket.PLAYER_ID, station)
	if due <= 0:
		return "no docking toll due at %s to waive" % station
	rc.transit = {"origin": "earth", "destination": station, "depart_tick": 0, "arrive_tick": 1, "rounds": 1, "toll": 0}
	var cr0: int = rc.cr
	rc._arrive()
	if rc.cr != cr0 or not rc.customs_waiver_used:
		return "docking toll not waived: cr %d -> %d" % [cr0, rc.cr]
	# The second arrival is charged the normal toll, after any toll discount the run holds.
	var want: int = due * (10000 - rc.toll_discount_bps()) / 10000
	rc.transit = {"origin": "earth", "destination": station, "depart_tick": 0, "arrive_tick": 1, "rounds": 1, "toll": 0}
	rc._arrive()
	if want <= 0 or rc.cr != cr0 - want:
		return "second docking toll should be %d, cr %d -> %d (due %d)" % [want, cr0, rc.cr, due]
	return "ok"

# --- Treasury ---

func _fine(rc: RunController, seed_: int) -> Dictionary:
	var deck := CrisisDeck.new(seed_)
	rc.crisis_deck = deck
	rc.world = Barons.for_new_run()
	deck.active.clear()
	return Heat._fire(rc.world, ARES, 2, rc, "consequence")

func test_treasury_defers_the_first_retaliation_fine_only() -> String:
	var rc := _rc(["treasury"] as Array[String])
	var first: Dictionary = _fine(rc, 21)
	if int(first["fine"]) != 0 or not bool(first["deferred"]) or not rc.treasury_waiver_used:
		return "first: fine %s deferred %s" % [str(first["fine"]), str(first["deferred"])]
	var second: Dictionary = _fine(rc, 21)
	if int(second["fine"]) <= 0 or bool(second["deferred"]):
		return "second should be charged: fine %s" % str(second["fine"])
	return "ok"

func test_no_treasury_favour_means_the_fine_is_charged() -> String:
	var rc := _rc()
	var res: Dictionary = _fine(rc, 21)
	if int(res["fine"]) <= 0 or bool(res["deferred"]) or rc.treasury_waiver_used:
		return "charged expected: fine %s deferred %s" % [str(res["fine"]), str(res["deferred"])]
	return "ok"

# --- Saves ---

func test_waiver_flags_round_trip_and_are_absent_when_false() -> String:
	var rc := _rc(["customs", "treasury"] as Array[String])
	if RunController.new(rc.profile, 21, null, {}, TPR).to_dict().has("customs_waiver_used"):
		return "false flag saved"
	rc.customs_waiver_used = true
	rc.treasury_waiver_used = true
	var d: Dictionary = rc.to_dict()
	if not bool(d.get("customs_waiver_used", false)) or not bool(d.get("treasury_waiver_used", false)):
		return "flags not saved"
	var back := RunController.from_dict(_json(d))
	if not back.customs_waiver_used or not back.treasury_waiver_used:
		return "flags not restored"
	return "ok"

# --- Press ---

func test_press_tips_name_fleets_sailing_next_round_only_when_retained() -> String:
	var rc_off := _rc()
	rc_off.world = Barons.for_new_run()
	if not Rivals.press_tips(rc_off.world, 1, rc_off).is_empty():
		return "tips emitted without press favour"
	var rc_on := _rc(["press"] as Array[String])
	rc_on.world = Barons.for_new_run()
	var found_tip: Dictionary = {}
	for rd in range(1, 30):
		var tips: Array = Rivals.press_tips(rc_on.world, rd, rc_on)
		if not tips.is_empty():
			found_tip = tips[0]
			break
	if found_tip.is_empty():
		return "no press tip generated across 30 rounds"
	if str(found_tip.get("kind", "")) != "rival_press_tip" or str(found_tip.get("fleet", "")) == "" or str(found_tip.get("station", "")) == "":
		return "malformed press tip: %s" % str(found_tip)
	return "ok"
