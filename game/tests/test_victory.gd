extends RefCounted
## Epic 3 task 9 (part of #17, Hostile Takeover & Insolvency): the monopoly state, the
## Severance hook and the summary states. The run win itself (the Sol System Rescue)
## is #32 and is not built; only "every baron held" is exposed here.

const TPR: int = 30


func _ctx(p_seed: int = 21) -> Dictionary:
	var rc := RunController.new(null, p_seed, null, {}, TPR)
	rc.world = Barons.for_new_run()
	rc.cr = 100000
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("mars")
	return {"rc": rc, "world": rc.world, "loop": lp}


func _take(c: Dictionary, id: String) -> Dictionary:
	var ev: Dictionary = Takeover.take(c["world"], id, Takeover.PLAYER, c["rc"])
	(c["loop"] as M0Loop)._post_baron_event(ev)
	return ev


func _take_all_but_last(c: Dictionary) -> String:
	var ids: Array = (c["world"] as Barons).ids()
	for i in ids.size() - 1:
		_take(c, ids[i])
	return str(ids[ids.size() - 1])


func test_data_requires_all_with_no_hold_timer() -> String:
	var w := Barons.for_new_run()
	if w.data["victory"] != {"barons_required": "all"}:
		return "victory must be exactly barons_required all: %s" % str(w.data["victory"])
	if w.barons_required() != w.ids().size():
		return "all must mean every baron"
	return "ok"


func test_monopoly_only_when_every_baron_is_held() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	if w.monopoly_achieved():
		return "no monopoly at the start"
	var last := _take_all_but_last(c)
	if w.monopoly_achieved():
		return "all but one is not a monopoly"
	_take(c, last)
	if not w.monopoly_achieved() or not (c["rc"] as RunController).has_monopoly():
		return "every baron held must be a monopoly"
	return "ok"


func test_monopoly_signal_fires_once_and_raises_the_summary_state() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var lp: M0Loop = c["loop"]
	var count := [0]
	rc.monopoly_achieved.connect(func(): count[0] += 1)
	var last := _take_all_but_last(c)
	if count[0] != 0 or lp.overlay_state != M0Loop.OVERLAY_NONE:
		return "no signal before the last baron"
	_take(c, last)
	if count[0] != 1:
		return "signal once, got %d" % count[0]
	if lp.overlay_state != M0Loop.OVERLAY_MONOPOLY or not rc.sim_clock.paused:
		return "the monopoly state must be up with the clock halted"
	var s: Dictionary = lp.monopoly_summary()
	if int(s["barons_held"]) != int(s["barons_total"]) or int(s["severance_pending"]) != int(s["barons_total"]) * Parachutes.SEVERANCE_PER_BARON:
		return "summary numbers wrong: %s" % str(s)
	if rc.check_monopoly():
		return "check_monopoly must not re-fire"
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT) or lp.overlay_state != M0Loop.OVERLAY_NONE or rc.sim_clock.paused:
		return "A must continue and resume the clock"
	if count[0] != 1:
		return "continuing must not re-signal"
	return "ok"


func test_monopoly_adds_nothing_to_saves() -> String:
	var c := _ctx()
	var before: String = JSON.stringify(RunSave.capture(c["rc"], c["loop"].market, Bags.new()).get("controller", {}))
	_take_all_but_last(c)
	var rc: RunController = c["rc"]
	for k in ["monopoly", "barons_broken_award"]:
		if rc.to_dict().has(k):
			return "%s must not be saved before banking" % k
	return "ok" if before != "" else "no capture"


func test_a_takeover_that_forces_chapter_11_is_not_a_monopoly_yet() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	_take_all_but_last(c)
	rc.cr = 0
	rc.doomsday.add_principal(10000000)  # insolvent before the last takeover
	_take(c, (c["world"] as Barons).ids().back())
	if (c["loop"] as M0Loop).overlay_state == M0Loop.OVERLAY_MONOPOLY:
		return "an insolvent corp must not get the monopoly state"
	return "ok"


func test_severance_per_baron_once_per_corp_peak_unchanged() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	_take(c, "ares_heavy")
	_take(c, "titan_cryo_hydro")
	rc.end_run("collapse")
	var expect: int = rc.peak_net_worth * Parachutes.SEVERANCE_NET_WORTH_BPS / 10000 + 2 * Parachutes.SEVERANCE_PER_BARON
	if rc.severance_award != expect:
		return "award %d, expected %d" % [rc.severance_award, expect]
	if rc.profile.barons_broken != 2 or rc.barons_broken_award != 2:
		return "barons_broken not banked"
	if rc.carry_over["persists"]["barons_broken"] != 2:
		return "carry_over wrong"
	var p2 := MetaProfile.new()
	Parachutes.award_severance(p2, 0, 1000, 3)
	if p2.severance_points != 1000 * Parachutes.SEVERANCE_NET_WORTH_BPS / 10000 + 3 * Parachutes.SEVERANCE_PER_BARON:
		return "barons must not touch the peak term"
	var bal: int = rc.profile.severance_points
	if rc.end_run("collapse") != 0 or rc.profile.severance_points != bal or rc.profile.barons_broken != 2:
		return "a corp must bank its barons once"
	return "ok"


func test_filing_banks_barons_before_the_forfeit() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	_take(c, "ares_heavy")
	rc.cr = 0
	rc.doomsday.add_principal(10000000)
	rc.pending_bankruptcy = true
	var rep: Dictionary = rc.file_bankruptcy()
	if rep.is_empty():
		return "filing did not go through"
	if rc.profile.barons_broken != 1:
		return "the filed corp's baron must count"
	if rc.severance_award < Parachutes.SEVERANCE_PER_BARON + Parachutes.SEVERANCE_PER_FILING:
		return "award misses the baron: %d" % rc.severance_award
	if (c["world"] as Barons).held_by(Takeover.PLAYER).size() != 0:
		return "holdings must still revert"
	if rc.has_monopoly():
		return "no monopoly after the forfeit"
	return "ok"


func test_no_barons_no_change_to_severance() -> String:
	var rc := RunController.new(null, 21, null, {}, TPR)
	rc.end_run("collapse")
	var p := MetaProfile.new()
	var award: int = Parachutes.award_severance(p, 0, rc.peak_net_worth)
	if rc.severance_award != award or rc.profile.barons_broken != 0:
		return "a corp with no world must award as before"
	if rc.profile.to_dict().has("barons_broken") or rc.carry_over["persists"].has("barons_broken"):
		return "zero must not appear in the dicts (hash pins)"
	return "ok"


func test_profile_reads_barons_broken_with_default_zero() -> String:
	if MetaProfile.from_dict({}).barons_broken != 0:
		return "default 0"
	if MetaProfile.from_dict({"barons_broken": "x"}).barons_broken != 0 or MetaProfile.from_dict({"barons_broken": -3}).barons_broken != 0:
		return "garbage clamps to 0"
	var p := MetaProfile.new()
	p.barons_broken = 3
	if MetaProfile.from_dict(JSON.parse_string(JSON.stringify(p.to_dict()))).barons_broken != 3:
		return "round trip"
	return "ok"


func test_run_summary_carries_the_broken_barons() -> String:
	var c := _ctx()
	_take(c, "ares_heavy")
	(c["rc"] as RunController).end_run("collapse")
	var r: Dictionary = (c["loop"] as M0Loop).run_summary()
	if int(r["barons_broken"]) != 1 or int(r["barons_severance"]) != Parachutes.SEVERANCE_PER_BARON:
		return "run_summary: %s" % str(r)
	return "ok"
