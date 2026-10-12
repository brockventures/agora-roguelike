extends RefCounted
## #160 row 6: the balance probe (tools/policy_probe.gd) runs. One seed, a few builds, picks through
## the controller. The full measurement is the command line (see the tool's header); this only
## proves the harness still plays 120 rounds and reports.

const PP := "res://tools/policy_probe.gd"


func test_the_build_lists_are_the_documented_sizes() -> String:
	var pp = load(PP)
	var nodes: Array = pp.node_builds()
	if nodes.size() != 13 or not (nodes[0] as Array).is_empty():
		return "expected baseline + 4 roots + 8 capstone pairs, got %d builds" % nodes.size()
	var four: Array = pp.builds()
	if four.size() != 49:
		return "expected the 49 legal four-pick builds, got %d" % four.size()
	for b in four:
		if (b as Array).size() != 4 or (b as Array).has(null):
			return "a four-pick build is malformed: %s" % str(b)
	return "ok"


func test_a_run_takes_its_picks_and_measures() -> String:
	var pp = load(PP)
	var base: Dictionary = pp.run(84, [])
	var one: Dictionary = pp.run(84, ["supply_chain", "risk_transfer"])
	if str(one["error"]) != "" or str(base["error"]) != "":
		return "a run failed: %s %s" % [str(base["error"]), str(one["error"])]
	var picks: Array = one["picks"]
	if picks.is_empty() or picks[0] != "20:supply_chain":
		return "the first pick should be supply_chain at round 20, got %s" % str(picks)
	if (one["session"] as Replay.Session).controller.policies.pending() > 0:
		return "a grant was left unanswered, so the clock stalled"
	for r in [base, one]:
		for cp in [40, 80, 120]:
			if not (r["nw"] as Dictionary).has(cp):
				return "no net worth recorded at round %d" % cp
		if int(r["end_round"]) < 120:
			return "the run stopped at round %d" % int(r["end_round"])
	if not (base["picks"] as Array).is_empty() or (base["session"] as Replay.Session).controller.policies != null:
		return "the no-policy baseline must attach no policies"
	return "ok"


func test_a_four_pick_build_stands_in_the_takeover_pick() -> String:
	var pp = load(PP)
	var r: Dictionary = pp.run(7, ["supply_chain", "cost_containment", "risk_transfer", "wind_down"])
	if str(r["error"]) != "":
		return str(r["error"])
	var rounds: Array = []
	for p in r["picks"]:
		rounds.append(int(str(p).split(":")[0]))
	if rounds.size() < 2 or rounds.slice(0, 2) != [20, pp.TAKEOVER_ROUND]:
		return "picks landed at %s" % str(rounds)
	return "ok"


func test_the_table_flags_a_dominant_and_a_useless_build() -> String:
	var pp = load(PP)
	var seeds: Array = [1, 2, 3, 4]
	var base_runs: Array = []
	var win_runs: Array = []
	var flat_runs: Array = []
	for i in 4:
		base_runs.append({"nw": {40: 1000, 80: 1000, 120: 1000}, "filings": 2, "sev": 100, "rescued": false, "end": 120})
		win_runs.append({"nw": {40: 2000, 80: 3000, 120: 4000}, "filings": 0, "sev": 100, "rescued": false, "end": 120})
		flat_runs.append({"nw": {40: 1000, 80: 1000, 120: 1010}, "filings": 2, "sev": 100, "rescued": false, "end": 120})
	var rows: Array = [{"build": [], "runs": base_runs}, {"build": ["supply_chain"], "runs": win_runs}, {"build": ["cost_containment"], "runs": flat_runs}]
	var out: String = "\n".join(PackedStringArray(pp.table(rows, seeds)))
	if not out.contains("DOMINANT") or not out.contains("USELESS"):
		return "the table lost a flag:\n" + out
	return "ok"
