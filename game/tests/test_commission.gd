extends RefCounted
## Commission cycle core (#149, PR 1a): the five commissioners, retain rules,
## capture and dissolution, and the Skeleton payout on a Rescue win.

func _p(skeletons: int = 0, consultants: Array[String] = []) -> MetaProfile:
	var p := MetaProfile.new()
	p.skeletons = skeletons
	p.consultants = consultants.duplicate()
	return p

func test_ids_in_file_order() -> String:
	var want: Array[String] = ["enforcement", "customs", "treasury", "press", "chair"]
	if Commission.ids() != want:
		return "ids %s" % str(Commission.ids())
	if Commission.skeletons_per_rescue() != 1 or Commission.cost("press") != 1:
		return "payout or cost wrong"
	if Commission.cost("nobody") != 0:
		return "unknown cost should be 0"
	return "ok"

func test_can_retain_reasons_in_order() -> String:
	var r: Dictionary = Commission.can_retain(_p(5), "nobody")
	if r != {"ok": false, "reason": "UNKNOWN_COMMISSIONER"}:
		return "unknown: %s" % str(r)
	r = Commission.can_retain(_p(5, ["press"] as Array[String]), "press")
	if r != {"ok": false, "reason": "ALREADY_RETAINED"}:
		return "already: %s" % str(r)
	r = Commission.can_retain(_p(5), "chair")
	if r != {"ok": false, "reason": "CHAIR_LAST"}:
		return "chair: %s" % str(r)
	r = Commission.can_retain(_p(0), "press")
	if r != {"ok": false, "reason": "INSUFFICIENT_SKELETONS"}:
		return "insufficient: %s" % str(r)
	r = Commission.can_retain(_p(1), "press")
	if r != {"ok": true, "reason": ""}:
		return "ok case: %s" % str(r)
	# Unknown id beats already-retained-ness checks and everything else.
	r = Commission.can_retain(_p(0), "nobody")
	if r["reason"] != "UNKNOWN_COMMISSIONER":
		return "unknown should be checked first"
	return "ok"

func test_retain_deducts_and_appends() -> String:
	var p := _p(2)
	var r: Dictionary = Commission.retain(p, "customs")
	if not r["ok"] or p.skeletons != 1 or p.consultants != ["customs"]:
		return "success: %s skel %d %s" % [str(r), p.skeletons, str(p.consultants)]
	var before_s: int = p.skeletons
	var before_c: Array[String] = p.consultants.duplicate()
	r = Commission.retain(p, "customs")
	if r["ok"] or r["reason"] != "ALREADY_RETAINED" or p.skeletons != before_s or p.consultants != before_c:
		return "failure must change nothing: %s" % str(r)
	r = Commission.retain(_p(0), "press")
	if r["ok"] or r["reason"] != "INSUFFICIENT_SKELETONS":
		return "insufficient: %s" % str(r)
	return "ok"

func test_chair_only_after_the_other_four() -> String:
	var p := _p(10)
	for id in ["enforcement", "customs", "treasury"]:
		Commission.retain(p, id)
	if Commission.retain(p, "chair")["reason"] != "CHAIR_LAST" or p.consultants.has("chair"):
		return "chair before four others must fail"
	Commission.retain(p, "press")
	if not Commission.retain(p, "chair")["ok"] or not p.consultants.has("chair"):
		return "chair should retain after the other four"
	return "ok"

func test_capture_pct() -> String:
	if Commission.capture_pct(_p()) != 0:
		return "empty capture should be 0"
	if Commission.capture_pct(_p(0, ["press"] as Array[String])) != 20:
		return "one of five should be 20"
	var all: Array[String] = ["enforcement", "customs", "treasury", "press", "chair", "nobody"]
	if Commission.capture_pct(_p(0, all)) != 100:
		return "all five should be 100 (unknown ids ignored)"
	return "ok"

func test_dissolution_fails_at_five_only() -> String:
	var four: Array[String] = ["enforcement", "customs", "treasury", "press"]
	var five: Array[String] = ["enforcement", "customs", "treasury", "press", "chair"]
	if Commission.dissolution_fails(_p(0, four)):
		return "four should not fail dissolution"
	if not Commission.dissolution_fails(_p(0, five)):
		return "five should fail dissolution"
	return "ok"
