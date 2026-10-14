extends RefCounted
## The Sol System Rescue Project, task 2 (#32, docs/design/rescue-project.md sections 5, 6, 8):
## the staged clock slowdown, the rescued win, both Severance paths (and the run summary rows
## that add up to them), the derived rent bonus across a save, the margin-call clamp, the raid
## rule and a Chapter 11 filing mid-project. Plus the proof that a run with no project is
## unchanged: same clock, same Severance, no new saved keys.

const TPR: int = 30


func _rc(cr: int = 100000) -> RunController:
	var rc := RunController.new(null, 21, null, {}, TPR)
	rc.cr = cr
	return rc


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


## A controller that holds every baron, with plenty of CR.
func _monopoly(cr: int = 1000000) -> RunController:
	var rc := _rc(cr)
	rc.world = Barons.for_new_run()
	for id in rc.world.ids():
		Takeover.take(rc.world, id, Takeover.PLAYER, rc)
	rc.cr = cr
	rc.doomsday.clear_debt()
	return rc


## Delivers whole phases through the real deposit until `n` are done. Returns the last result.
func _build(rc: RunController, n: int) -> Dictionary:
	var res: Dictionary = {}
	while rc.rescue.is_open() and rc.rescue.phase < n:
		var ph: Dictionary = rc.rescue.current()
		var need: Dictionary = rc.rescue.remaining()
		var keys: Array = need.keys()
		keys.sort()
		for c in keys:
			rc.cargo = {c: int(need[c])}
			res = rc.rescue.deposit(rc, str(ph["site"]), 50)
	return res


func _ticks_lost(rc: RunController, ticks: int) -> int:
	var before: int = rc.doomsday.ticks_remaining
	for t in range(1, ticks + 1):
		rc._on_sub_ticked(t)
	return before - rc.doomsday.ticks_remaining


# --- The clock ---

func test_each_finished_phase_slows_the_clock_to_its_share() -> String:
	var want: Array = [10000, 6000, 3500, 1500, 0]
	for phases in 5:
		var rc := _monopoly()
		if not rc.open_rescue():
			return "the project did not open"
		_build(rc, phases)
		if rc.rescue.keep_bps != int(want[phases]):
			return "after %d phases keep_bps is %d, want %d" % [phases, rc.rescue.keep_bps, int(want[phases])]
		var lost: int = _ticks_lost(rc, 10000)
		if lost != int(want[phases]):
			return "after %d phases 10000 ticks cost the clock %d, want %d" % [phases, lost, int(want[phases])]
	return "ok"


func test_the_gate_runs_through_the_real_sim_clock() -> String:
	var rc := _monopoly()
	rc.open_rescue()
	_build(rc, 4)  # keep_bps 0: halted
	rc.sim_clock.resume()
	var before: int = rc.doomsday.ticks_remaining
	var ticks_before: int = rc.sim_clock.total_ticks
	rc.advance(1.0)
	if rc.sim_clock.total_ticks <= ticks_before:
		return "the sim clock did not run"
	if rc.doomsday.ticks_remaining != before:
		return "a halted field still ticked the doomsday clock"
	return "ok"


func test_a_run_with_no_project_has_the_same_clock_and_severance() -> String:
	var plain := _rc()
	var with_p := _rc()
	with_p.rescue = RescueProject.open_new(1)  # phase 1 open: full speed
	var a: int = _ticks_lost(plain, 3000)
	var b: int = _ticks_lost(with_p, 3000)
	if a != 3000 or b != 3000:
		return "full speed must count every tick (%d, %d)" % [a, b]
	if plain.doomsday.ticks_remaining != with_p.doomsday.ticks_remaining or plain.doomsday.get_total_debt() != with_p.doomsday.get_total_debt():
		return "the clocks differ"
	# Severance: no project, no new terms, no new saved keys.
	plain.peak_net_worth = 20000
	var award: int = plain.end_run("collapse")
	var want: int = plain.peak_net_worth * Parachutes.SEVERANCE_NET_WORTH_BPS / Parachutes.BPS + plain.rounds_survived_award * Parachutes.SEVERANCE_PER_ROUND
	if award != want or plain.rescue_severance_award != 0 or plain.consolation_severance_award != 0:
		return "no-project award %d, want %d" % [award, want]
	var d: Dictionary = plain.to_dict()
	if d.has("rescue_severance_award") or d.has("consolation_severance_award"):
		return "new keys saved with no project"
	var p := MetaProfile.new()
	if Parachutes.award_severance(p, 1, 40000, 2, 17) != 40000 * Parachutes.SEVERANCE_NET_WORTH_BPS / Parachutes.BPS + 2 * Parachutes.SEVERANCE_PER_BARON + 17 * Parachutes.SEVERANCE_PER_ROUND:
		return "the default award moved"
	return "ok"


# --- The win ---

func test_finishing_the_last_phase_wins_the_run() -> String:
	var rc := _monopoly()
	rc.open_rescue()
	var res: Dictionary = _build(rc, 4)
	if not bool(res.get("won", false)):
		return "the last deposit did not report a win"
	if rc.is_run_over() or rc.is_rescued():
		return "the run ended before finish_rescue"
	var got: Array = []
	rc.run_rescued.connect(func(): got.append(1))
	var left: int = int(rc.doomsday.ticks_remaining / rc.ticks_per_round)
	rc.peak_net_worth = 10000
	var award: int = rc.finish_rescue()
	if not rc.is_run_over() or not rc.is_rescued() or rc.is_collapsed():
		return "a rescued run must be over without being collapsed"
	if rc.end_reason != "rescued" or got.size() != 1 or not rc.sim_clock.paused:
		return "end state wrong: %s %s paused=%s" % [rc.end_reason, str(got), str(rc.sim_clock.paused)]
	var bonus: int = 500 + 10 * left
	if rc.rescue_severance_award != bonus:
		return "rescue bonus %d, want %d" % [rc.rescue_severance_award, bonus]
	var base: int = rc.peak_net_worth * Parachutes.SEVERANCE_NET_WORTH_BPS / Parachutes.BPS + rc.rounds_survived_award * Parachutes.SEVERANCE_PER_ROUND + rc.barons_broken_award * Parachutes.SEVERANCE_PER_BARON
	if award != base + bonus or rc.profile.severance_points != award:
		return "award %d, want %d (profile %d)" % [award, base + bonus, rc.profile.severance_points]
	if rc.barons_broken_award != 3 or rc.profile.rescues_completed != 1:
		return "broken %d, rescues %d" % [rc.barons_broken_award, rc.profile.rescues_completed]
	if rc.profile.skeletons != 1:
		return "a rescue win should pay one Skeleton, got %d" % rc.profile.skeletons
	# Once only: a second call, a late collapse and a filing attempt change nothing.
	if rc.finish_rescue() != 0:
		return "banked twice"
	rc._on_collapsed()
	if rc.severance_award != award or rc.profile.severance_points != award or rc.end_reason != "rescued":
		return "the collapse path double banked"
	if rc.advance(1.0) != 0 or not rc.file_bankruptcy().is_empty():
		return "a rescued run kept running"
	if rc.can_depart("luna")["ok"]:
		return "a rescued run can still depart"
	return "ok"


func test_finish_rescue_needs_a_finished_project() -> String:
	var rc := _monopoly()
	if rc.finish_rescue() != 0:
		return "finished with no project"
	rc.open_rescue()
	_build(rc, 3)
	if rc.finish_rescue() != 0 or rc.is_run_over():
		return "finished with a phase left"
	return "ok"


func test_the_project_only_opens_on_the_monopoly() -> String:
	var rc := _rc()
	rc.world = Barons.for_new_run()
	if rc.open_rescue() or rc.rescue != null:
		return "opened without the monopoly"
	var held := _monopoly()
	if not held.open_rescue() or held.open_rescue():
		return "open_rescue should open once"
	return "ok"


func test_the_win_and_save_round_trip() -> String:
	var rc := _monopoly()
	rc.open_rescue()
	_build(rc, 4)
	rc.finish_rescue()
	var back: RunController = RunController.from_dict(_json(rc.to_dict()))
	back.rescue = RescueProject.from_dict(_json(rc.rescue.to_dict()))
	if back.rescue_severance_award != rc.rescue_severance_award or back.end_reason != "rescued" or not back.is_run_over():
		return "the rescued state did not survive a save"
	return "ok"


# --- Severance on a lost rescue ---

func test_a_lost_rescue_pays_the_consolation_per_finished_phase() -> String:
	for done in [0, 1, 2, 3]:
		var rc := _monopoly()
		rc.open_rescue()
		_build(rc, done)
		rc.peak_net_worth = 0
		rc.doomsday.ticks_remaining = 1
		rc.doomsday.step_ticks(5)
		if not rc.is_collapsed() or rc.end_reason != "collapse":
			return "%d phases: the clock did not collapse the run" % done
		if rc.consolation_severance_award != 100 * done or rc.rescue_severance_award != 0:
			return "%d phases: consolation %d rescue %d" % [done, rc.consolation_severance_award, rc.rescue_severance_award]
		var base: int = rc.peak_net_worth * Parachutes.SEVERANCE_NET_WORTH_BPS / Parachutes.BPS + rc.rounds_survived_award * Parachutes.SEVERANCE_PER_ROUND + 3 * Parachutes.SEVERANCE_PER_BARON
		if rc.severance_award != base + 100 * done:
			return "%d phases: award %d, want %d" % [done, rc.severance_award, base + 100 * done]
		if rc.profile.rescues_completed != 0 or rc.is_rescued():
			return "a lost rescue counted as a win"
	return "ok"


func test_a_filing_pays_no_consolation_and_keeps_the_progress() -> String:
	var rc := _monopoly()
	rc.open_rescue()
	_build(rc, 2)
	var before: Dictionary = rc.rescue.to_dict()
	rc.cr = 0
	rc.cargo = {}
	rc.doomsday.add_principal(900000)
	var rep: Dictionary = rc.file_bankruptcy()
	if rep.is_empty():
		return "no filing"
	if rc.consolation_severance_award != 0 or rc.rescue_severance_award != 0:
		return "a filing paid project Severance"
	if rc.rescue == null or rc.rescue.to_dict() != before:
		return "the filing disturbed the project (Q5 a)"
	if rc.is_run_over():
		return "a filing must not end the run"
	return "ok"


# --- The rent bonus ---

func _rent_total(w: Barons) -> int:
	var n: int = 0
	for id in w.ids():
		n += Takeover.rent(w, id)
	return n


func test_the_rent_bonus_doubles_rent_while_the_project_is_open() -> String:
	var rc := _monopoly()
	var plain: int = _rent_total(rc.world)
	if plain != 675:
		return "baseline rent %d, the design says 675" % plain
	rc.open_rescue()
	if rc.world.rent_bonus_bps != 20000 or _rent_total(rc.world) != 1350:
		return "bonus not applied: %d / %d" % [rc.world.rent_bonus_bps, _rent_total(rc.world)]
	# The round-boundary payout uses it.
	var id: String = rc.world.ids()[0]
	var cr0: int = rc.cr
	Takeover.advance(rc.world, id, 5, rc)
	if rc.cr - cr0 != Takeover.rent(rc.world, id) or Takeover.rent(rc.world, id) != 2 * (plain_rent(id)):
		return "the payout %d is not the doubled rent" % (rc.cr - cr0)
	_build(rc, 4)
	rc.sync_rent_bonus()
	if rc.world.rent_bonus_bps != 10000:
		return "a finished project must not keep the bonus"
	return "ok"


func plain_rent(id: String) -> int:
	var w := Barons.for_new_run()
	return Takeover.rent(w, id)


func test_the_rent_bonus_is_derived_and_rebuilt_on_restore() -> String:
	var rc := _monopoly()
	rc.open_rescue()
	var bags := Bags.new()
	var market := StationMarket.new()
	var cap: Dictionary = RunSave.capture(rc, market, bags)
	var text: String = JSON.stringify(cap)
	if text.contains("rent_bonus"):
		return "the derived bonus leaked into the save"
	var r: Dictionary = RunSave.restore(_json(cap))
	if not bool(r["ok"]):
		return str(r)
	var back: RunController = r["controller"]
	if back.world.rent_bonus_bps != 20000 or _rent_total(back.world) != 1350:
		return "restore lost the bonus: %d" % back.world.rent_bonus_bps
	# Same hash with or without the bonus set: it is not state.
	var h1: String = RunSave.state_hash(rc, market, bags)
	rc.world.rent_bonus_bps = 10000
	if RunSave.state_hash(rc, market, bags) != h1:
		return "the bonus moved the state hash"
	# A run with no project restores to x1.
	var plain := _monopoly()
	var r2: Dictionary = RunSave.restore(_json(RunSave.capture(plain, market, bags)))
	if (r2["controller"] as RunController).world.rent_bonus_bps != 10000:
		return "no project, yet a bonus"
	return "ok"


func test_a_filing_drops_the_bonus_but_keeps_progress() -> String:
	var rc := _monopoly()
	rc.open_rescue()
	_build(rc, 1)
	if rc.world.rent_bonus_bps != 20000:
		return "bonus missing before the filing"
	rc.cr = 0
	rc.cargo = {}
	rc.doomsday.add_principal(900000)
	if rc.file_bankruptcy().is_empty():
		return "no filing"
	if rc.world.rent_bonus_bps != 10000 or _rent_total(rc.world) != 675 or not rc.world.held_by(Takeover.PLAYER).is_empty():
		return "bonus %d / rent %d after the holdings reverted" % [rc.world.rent_bonus_bps, _rent_total(rc.world)]
	if rc.rescue == null or rc.rescue.phase != 1:
		return "progress was lost"
	var r: Dictionary = RunSave.restore(_json(RunSave.capture(rc, StationMarket.new(), Bags.new())))
	var back: RunController = r["controller"]
	if back.world.rent_bonus_bps != 10000 or back.rescue.phase != 1:
		return "restore after a filing is wrong"
	return "ok"


# --- The margin-call clamp ---

func _margin_ctx() -> Dictionary:
	var rc := RunController.new(null, 9, null, {}, 4)
	var lp := M0Loop.new(OrbitalHUD.new(rc))
	lp.dock_at("mars")
	var deck: CrisisDeck = rc.crisis_deck
	var keep: Array = []
	for def in deck.data["crises"]:
		if def["id"] == "systemic_margin_collapse":
			keep.append(def)
	deck.data["crises"] = keep
	deck.data["grace_rounds"] = 0
	deck.bags.force("crisis", true)
	rc.cargo["ORE"] = 100
	rc.cr = 1000
	# Debt that leaves exactly 5 CR of headroom.
	var a: Dictionary = rc.assess()
	rc.doomsday.add_principal(int(a["liquidation_value"]) - int(a["total_debt"]) - 5)
	deck.advance_round(5, 3, 8000)
	return {"rc": rc, "loop": lp}


func test_an_open_project_clamps_the_random_margin_call() -> String:
	var open := _margin_ctx()
	var rc: RunController = open["rc"]
	if int(rc.assess()["liquidation_value"]) - int(rc.assess()["total_debt"]) != 5:
		return "setup: headroom is not 5"
	rc.rescue = RescueProject.open_new(1)
	var drained: Array = []
	rc.margin_call_applied.connect(func(n): drained.append(n))
	rc._advance_crisis_deck(6)
	if drained != [5] or bool(rc.assess()["insolvent"]):
		return "clamped drain %s, insolvent %s" % [str(drained), str(rc.assess()["insolvent"])]
	# Without a project the same call drains in full and tips the corp over.
	var free := _margin_ctx()
	var rc2: RunController = free["rc"]
	var d2: Array = []
	rc2.margin_call_applied.connect(func(n): d2.append(n))
	rc2._advance_crisis_deck(6)
	if d2.size() != 1 or int(d2[0]) <= 5 or not bool(rc2.assess()["insolvent"]):
		return "the unclamped drain should be larger and insolvent: %s" % str(d2)
	# A finished project clamps nothing.
	var done := _margin_ctx()
	var rc3: RunController = done["rc"]
	rc3.rescue = RescueProject.from_dict({"phase": 4, "keep_bps": 0})
	var d3: Array = []
	rc3.margin_call_applied.connect(func(n): d3.append(n))
	rc3._advance_crisis_deck(6)
	if d3.size() != 1 or int(d3[0]) <= 5:
		return "a finished project clamped the drain: %s" % str(d3)
	return "ok"


func test_an_insolvent_corp_loses_nothing_more_to_the_clamped_drain() -> String:
	var ctx := _margin_ctx()
	var rc: RunController = ctx["rc"]
	rc.doomsday.add_principal(1000)  # now insolvent
	rc.rescue = RescueProject.open_new(1)
	var cr0: int = rc.cr
	rc._advance_crisis_deck(6)
	return "ok" if rc.cr == cr0 else "an insolvent corp was drained %d" % (cr0 - rc.cr)


# --- The raid rule ---

func _raid(seed_: int, cr: int, cargo: Dictionary, project: bool, heat: int = 0) -> Dictionary:
	var rc := RunController.new(null, seed_, DoomsdayClock.new(36000, 0, 0, 0), {}, TPR)
	rc.world = Barons.for_new_run()
	for k in ["bounty_chance_bps", "react_chance_bps", "decide_chance_bps"]:
		rc.world.data["rivals"][k] = 0
	rc.cr = cr
	rc.cargo = cargo.duplicate()
	if project:
		rc.rescue = RescueProject.open_new(1)
	if heat > 0:
		rc.world.raise_heat(rc.world.ids()[0], heat)
	var events: Array = []
	Corridors.raid(rc.world, rc, {"origin": "mars", "destination": "ceres", "lane": ""}, 0, 1500, events)
	return {"rc": rc, "events": events}


## First seed whose belt departure is raided with this setup.
func _raided_seed(cargo: Dictionary) -> int:
	for sd in range(1, 400):
		if not (_raid(sd, 0, cargo, false)["events"] as Array).is_empty():
			return sd
	return 0


func test_a_raid_on_project_goods_is_ransom_only() -> String:
	var cargo: Dictionary = {"MACHINERY": 100}
	var sd: int = _raided_seed(cargo)
	if sd == 0:
		return "no seed produced a raid"
	# Control: with no project and no CR the pirates take the cargo.
	var free: Dictionary = _raid(sd, 0, cargo, false)
	var fe: Dictionary = (free["events"] as Array)[0]
	if int(fe["qty_taken"]) <= 0 or fe.has("ransom_only"):
		return "control raid should seize cargo: %s" % str(fe)
	# With the project open and no CR: nothing is seized, the ransom is floored at the CR held.
	var held: Dictionary = _raid(sd, 0, cargo, true)
	var he: Dictionary = (held["events"] as Array)[0]
	if int(he["qty_taken"]) != 0 or int((held["rc"] as RunController).cargo.get("MACHINERY", 0)) != 100:
		return "project goods were seized: %s" % str(he)
	if not bool(he.get("ransom_only", false)) or int(he["ransom"]) != 0 or (held["rc"] as RunController).cr != 0:
		return "ransom not floored at the CR held: %s" % str(he)
	# With some CR the ransom is capped at what is held and charged.
	var poor: Dictionary = _raid(sd, 40, cargo, true)
	var pe: Dictionary = (poor["events"] as Array)[0]
	var prc: RunController = poor["rc"]
	if int(pe["qty_taken"]) != 0 or int(pe["ransom"]) > 40 or prc.cr != 40 - int(pe["ransom"]) or int(prc.cargo["MACHINERY"]) != 100:
		return "poor corp: %s cr %d" % [str(pe), prc.cr]
	# Rich: the normal ransom.
	var rich: Dictionary = _raid(sd, 50000, cargo, true)
	var re: Dictionary = (rich["events"] as Array)[0]
	if int(re["qty_taken"]) != 0 or int(re["ransom"]) <= 0:
		return "rich corp: %s" % str(re)
	return "ok"


func test_the_raid_rule_needs_project_goods_and_no_heat() -> String:
	var cargo: Dictionary = {"MACHINERY": 100}
	var sd: int = _raided_seed(cargo)
	if sd == 0:
		return "no seed produced a raid"
	# Goods the open phase does not want are not protected (phase 1 wants MACHINERY and ORE).
	var other: int = _raided_seed({"FRAG": 100})
	if other == 0:
		return "no seed raids a FRAG hold"
	var fe: Dictionary = (_raid(other, 0, {"FRAG": 100}, true)["events"] as Array)[0]
	if int(fe["qty_taken"]) <= 0 or fe.has("ransom_only"):
		return "a hold with no project goods was protected: %s" % str(fe)
	# A raid after the player earned heat is a consequence: full loss.
	var hot: Array = _raid(sd, 0, cargo, true, 3)["events"]
	if hot.is_empty() or int(hot[0]["qty_taken"]) <= 0 or (hot[0] as Dictionary).has("ransom_only"):
		return "a heat-earned raid should keep the full loss: %s" % str(hot)
	return "ok"


# --- Run summary rows ---

func _scene(rc: RunController) -> Node:
	var scene = load("res://scenes/main.tscn").instantiate()
	scene.initialize_systems(rc)
	scene._resolve_child_nodes()
	scene._build_readouts()
	return scene


func _sev_rows_sum(scene: Node) -> int:
	var summed: int = 0
	for row in scene._summary_model()["rows"]:
		var k: String = str(row["key"])
		if k.begins_with("FILINGS") or k.begins_with("PEAK NET WORTH @") or k.begins_with("ROUNDS x") or k.begins_with("BROKEN") or k.begins_with("BARONS BROKEN") or k.begins_with("SOL RESCUED BONUS") or k.begins_with("STABILISER PHASES"):
			summed += int(str(row["value"]).trim_prefix("+"))
	return summed


func test_the_summary_rows_add_up_on_a_win() -> String:
	var rc := _monopoly()
	rc.open_rescue()
	_build(rc, 4)
	rc.peak_net_worth = 30000
	rc.finish_rescue()
	var scene := _scene(rc)
	var r: Dictionary = scene.loop.run_summary()
	if int(r["severance_rescue_pts"]) != rc.rescue_severance_award or int(r["severance_rescue_pts"]) <= 0:
		return "no rescue points in the summary: %s" % str(r)
	var parts: int = int(r["severance_filings_pts"]) + int(r["severance_peak_pts"]) + int(r["barons_severance"]) + int(r["severance_rounds_pts"]) + int(r["severance_rescue_pts"]) + int(r["severance_consolation_pts"])
	if parts != int(r["severance_awarded"]) or int(r["severance_filings_pts"]) != 0:
		return "breakdown %d != award %d (%s)" % [parts, int(r["severance_awarded"]), str(r)]
	var shown: int = _sev_rows_sum(scene)
	var cause: String = ""
	for row in scene._summary_model()["rows"]:
		if str(row["key"]) == scene.tr("SUM_CAUSE"):
			cause = str(row["value"])
	scene.free()
	if cause != "The Sol System was rescued":
		return "cause row says %s" % cause
	return "ok" if shown == rc.severance_award else "rows add to %d, not the award %d" % [shown, rc.severance_award]


func test_the_summary_rows_add_up_on_a_lost_rescue() -> String:
	var rc := _monopoly()
	rc.open_rescue()
	_build(rc, 2)
	rc.peak_net_worth = 30000
	rc.doomsday.ticks_remaining = 1
	rc.doomsday.step_ticks(5)
	if rc.end_reason != "collapse":
		return "no collapse"
	var scene := _scene(rc)
	var r: Dictionary = scene.loop.run_summary()
	var parts: int = int(r["severance_filings_pts"]) + int(r["severance_peak_pts"]) + int(r["barons_severance"]) + int(r["severance_rounds_pts"]) + int(r["severance_rescue_pts"]) + int(r["severance_consolation_pts"])
	if parts != int(r["severance_awarded"]) or int(r["severance_consolation_pts"]) != 200 or int(r["severance_filings_pts"]) != 0:
		return "breakdown %d != award %d (%s)" % [parts, int(r["severance_awarded"]), str(r)]
	var shown: int = _sev_rows_sum(scene)
	scene.free()
	return "ok" if shown == rc.severance_award else "rows add to %d, not the award %d" % [shown, rc.severance_award]
