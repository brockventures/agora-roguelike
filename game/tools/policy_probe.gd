extends SceneTree
## The corporate-policy balance probe (#160 row 6, docs/design/corporate-policies.md sections 12
## and 13). It plays the shipped world with the existing pacing trader (tools/rescue_bot.gd's
## `trade`: sell the hold, take the best profit-per-round leg) for 120 rounds with a fixed policy
## build, and measures what the build did to the run.
##
##   godot --headless --path game -s res://tools/policy_probe.gd -- nodes  [seeds]   # baseline + each root, each root+capstone
##   godot --headless --path game -s res://tools/policy_probe.gd -- builds [seeds]   # baseline + all 49 legal 4-pick builds
##   godot --headless --path game -s res://tools/policy_probe.gd -- all    [seeds]
##   godot --headless --path game -s res://tools/policy_probe.gd -- one    <seed> <id,id,...>
##
## Seeds are comma separated (default 84,7,21,3,11,42, the pacing bot's six).
##
## Picks go straight through the core API, `RunController.adopt_policy(id)` (PolicyState.pick plus
## the modifier rebuild and the `policy_adopted` signal), then resume the clock: the same calls the
## pick modal makes, with no dependence on a replay input or on Main/UI. The bot has no baron work, so the "first takeover" pick is
## stood in for by `on_takeover()` at round TAKEOVER_ROUND, and a build with fewer than four picks
## switches the surplus grants off (the milestones list is cut, the takeover pick disabled) on
## the run's own PolicyState, so the clock never stalls on a pick the build does not take. A pick
## order is roots first (file order), then capstones; a build's k-th pick lands on its k-th grant
## round (20, TAKEOVER_ROUND, 50, 80 for four picks; 20, 50, 80 for three; 20, 50 for two). A
## filing rescinds the policies; a milestone that fires afterwards is a grant the player must take
## (picks are mandatory), so the bot rebuilds the plan from its first node still on offer.
##
## A Chapter 11 filing is filed by the bot (the policies are rescinded, section 7) and the run
## goes on in the new corp. Not Main, not UI. Not a class_name: callers load() it by path.

const RB := "res://tools/rescue_bot.gd"
const DEFAULT_SEEDS: Array = [84, 7, 21, 3, 11, 42]
const ROUNDS: int = 120
const CHECKPOINTS: Array = [40, 80, 120]
const TAKEOVER_ROUND: int = 35
const MAX_FRAMES: int = 60000
## A node "dominates" when it has the best net worth at round 120 among its peers in more than
## this share of seeds, or when it also lifts the mean net worth over the baseline by DOMINANT_LIFT.
const DOMINANT_SHARE: float = 0.6
const DOMINANT_LIFT: float = 0.5
## A node is "useless" when its mean net worth at round 120 is within this share of the baseline's
## (or below it) and it does not reduce Chapter 11 filings.
const USELESS_BAND: float = 0.03
## Stats the pacing trader never exercises: it does no baron work, so no takeover happens and no
## debt is assumed. A build made only of these cannot show an effect here, and is flagged
## UNREACHED rather than USELESS.
const UNREACHED_STATS: Array = ["takeover_threshold_shares", "assumed_debt_bps"]


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var mode: String = args[0] if args.size() > 0 else "nodes"
	var seeds: Array = _seeds(args[1] if args.size() > 1 else "")
	match mode:
		"one":
			var ids: Array = Array(str(args[2]).split(",")) if args.size() > 2 else []
			var r: Dictionary = run(int(seeds[0]), ids)
			r.erase("session")
			print(JSON.stringify(r))
		"builds":
			_report(builds(), seeds)
		"all":
			_report(node_builds() + builds(), seeds)
		_:
			_report(node_builds(), seeds)
	quit(0)


func _seeds(txt: String) -> Array:
	if txt == "":
		return DEFAULT_SEEDS
	var out: Array = []
	for p in txt.split(","):
		out.append(int(p))
	return out


# --- Builds ---------------------------------------------------------------------------------

## [[], [root], ..., [root, capstone] ...]: the no-policy baseline, each root alone, and each of
## the eight capstones with its root (two picks, at rounds 20 and 50).
static func node_builds() -> Array:
	var out: Array = [[]]
	var tree: Parachutes = Parachutes.load_policies()
	var ids: Array = tree.perks.keys()
	for id in ids:
		if (tree.perks[id]["requires"] as Array).is_empty():
			out.append([id])
	for id in ids:
		var req: Array = tree.perks[id]["requires"]
		if not req.is_empty():
			out.append([req[0], id])
	return out


## Every legal four-pick build (49), each in pick order: roots in file order, then capstones.
static func builds() -> Array:
	var tree: Parachutes = Parachutes.load_policies()
	var ids: Array = tree.perks.keys()
	var out: Array = []
	var n: int = ids.size()
	for a in n:
		for b in range(a + 1, n):
			for c in range(b + 1, n):
				for d in range(c + 1, n):
					var set: Array = [ids[a], ids[b], ids[c], ids[d]]
					if _legal(tree, set):
						out.append(_ordered(tree, set))
	return out


static func _legal(tree: Parachutes, set: Array) -> bool:
	for id in set:
		for r in tree.perks[id]["requires"]:
			if not set.has(r):
				return false
		for x in tree.perks[id]["excludes"]:
			if set.has(x):
				return false
	return true


static func _ordered(tree: Parachutes, set: Array) -> Array:
	var roots: Array = []
	var caps: Array = []
	for id in tree.perks:  # file order
		if set.has(id):
			(roots if (tree.perks[id]["requires"] as Array).is_empty() else caps).append(id)
	return roots + caps


# --- One run --------------------------------------------------------------------------------

## Plays one run of `build` (policy ids in pick order; [] is the no-policy baseline, which attaches
## no PolicyState) on `p_seed`. Returns the measurements and the finished session.
static func run(p_seed: int, build: Array) -> Dictionary:
	var rb = load(RB)
	var s := Replay.start_recording(p_seed, {}, rb.FRAME_DELTA, rb.TPR, true, not build.is_empty())
	var rc: RunController = s.controller
	if not build.is_empty():
		var ms: Array[int] = rc.policies.tree().milestones
		var keep: int = build.size() - (1 if build.size() == 4 else 0)  # four picks: three milestones + the takeover
		rc.policies.tree().milestones = ms.slice(0, mini(keep, ms.size()))
		rc.policies.tree().takeover_pick = false
	s.loop.dock_at("earth")
	var log = rb.Log.new()
	log.recording = false
	var nw: Dictionary = {}
	var filings: int = 0
	var sev: int = 0  # Severance banked by filings
	var taken: Array = []
	var pick_log: Array = []
	var plan: Array = build.duplicate()
	var stood_in: bool = build.size() == 4
	var stood: bool = false
	var last_key: String = ""
	var last_round: int = -1
	var rescued: bool = false
	while s.frames < MAX_FRAMES and rc.get_current_round() < ROUNDS and not rc.is_run_over():
		var r: int = rc.get_current_round()
		if stood_in and not stood and r >= TAKEOVER_ROUND:
			stood = true
			rc.policies.takeover_granted = true
			rc.policies.earned += 1  # what on_takeover() does with takeover_pick on; the build keeps it off
		if rc.policies != null and rc.policies.pending() > 0:
			var id: String = _next_pick(rc, plan)
			if not rc.adopt_policy(id):
				return {"error": "refused pick %s (taken %s)" % [id, str(taken)], "session": s}
			rc.sim_clock.resume()  # the pick modal's A press does this in play
			taken.append(id)
			pick_log.append("%d:%s" % [r, id])
		elif rc.pending_bankruptcy:
			var rep: Dictionary = s.loop.file_chapter_11()
			if not rep.is_empty():
				filings += 1
				sev += rc.severance_award
				taken.clear()  # rescinded (section 7); later milestone grants rebuild from the plan
		elif not rb.answer_overlay(s, log) and s.loop.overlay_state == M0Loop.OVERLAY_NONE:
			if rc.docked_at != "" and rc.transit.is_empty():
				var key: String = "%s@%d" % [rc.docked_at, r]
				if key != last_key:
					last_key = key
					rb._trade_visit(s)
		s.advance()
		var r2: int = rc.get_current_round()
		if r2 != last_round:
			last_round = r2
			for cp in CHECKPOINTS:
				if r2 == int(cp):
					nw[int(cp)] = rc.net_worth()
	rescued = rc.is_rescued()
	var end_round: int = rc.get_current_round()
	# What the corp still alive would bank if the run ended now, with this corp's own Severance
	# multiplier (the only effect that reaches the permanent profile).
	var tail := MetaProfile.new()
	var tail_sev: int = Parachutes.award_severance(tail, 0, rc.peak_net_worth, 0, end_round - int(rc._corp_start_tick / rc.ticks_per_round), 0, 0, Parachutes.apply_stat(rc.modifiers, "severance_bps", Parachutes.BPS))
	if rc.is_run_over() and rc.end_reason == "collapse" and rc._banked_corp == rc.corp_number:
		tail_sev = rc.severance_award
	return {"session": s, "nw": nw, "filings": filings, "severance": sev + tail_sev, "rescued": rescued,
		"end_round": end_round, "collapsed": rc.is_collapsed(), "picks": pick_log, "error": ""}


## The next pick: the first node of the plan still on offer (so a corp re-founded by a filing
## rebuilds the plan from its root), else the first listed offer. "" when nothing is on offer.
static func _next_pick(rc: RunController, plan: Array) -> String:
	var offers: Array[String] = rc.policies.offers()
	for id in plan:
		if offers.has(str(id)):
			return str(id)
	return offers[0] if not offers.is_empty() else ""


# --- Report ---------------------------------------------------------------------------------

func _report(list: Array, seeds: Array) -> void:
	var rows: Array = []
	for build in list:
		var runs: Array = []
		for sd in seeds:
			var r: Dictionary = run(int(sd), (build as Array).duplicate())
			if str(r.get("error", "")) != "":
				push_error(str(r["error"]))
			runs.append({"nw": r.get("nw", {}), "filings": r.get("filings", 0), "sev": r.get("severance", 0), "rescued": r.get("rescued", false), "end": r.get("end_round", 0)})
		rows.append({"build": build, "runs": runs})
	for line in table(rows, seeds):
		print(line)


## Pure formatting and flagging over the measured rows, so a test can feed it canned numbers.
## rows: [{build: [ids], runs: [{nw: {40,80,120}, filings, sev, rescued, end}]}], rows[0] the baseline.
static func table(rows: Array, seeds: Array) -> Array:
	var out: Array = []
	var base: Dictionary = _summ(rows[0]["runs"])
	out.append("seeds %s, %d rounds; nw = mean net worth CR; ch11 = mean Chapter 11 filings per run; surv = runs with no filing / runs; resc = Rescue wins (the trader never holds the monopoly); sev = mean Severance" % [str(seeds), ROUNDS])
	out.append("%-60s %7s %7s %7s %5s %6s %5s %5s %8s %4s  %s" % ["build", "nw@40", "nw@80", "nw@120", "ch11", "surv", "resc", "sev", "d@120", ">base", "flags"])
	var wins: Dictionary = _win_counts(rows)
	for row in rows:
		var b: Array = row["build"]
		var m: Dictionary = _summ(row["runs"])
		var d: float = (float(m["nw120"]) - float(base["nw120"])) / maxf(1.0, absf(float(base["nw120"]))) * 100.0
		var flags: Array = []
		if not b.is_empty():
			var share: float = float(wins.get(str(b), 0)) / float(maxi(1, seeds.size()))
			if share > DOMINANT_SHARE:
				flags.append("DOMINANT(%d%% of seeds best in group)" % int(share * 100.0))
			if d / 100.0 > DOMINANT_LIFT:
				flags.append("LIFT>%d%%" % int(DOMINANT_LIFT * 100.0))
			if _unreached(b):
				flags.append("UNREACHED(no baron work)")
			elif absf(d) / 100.0 <= USELESS_BAND and float(m["ch11"]) >= float(base["ch11"]) and float(m["sev"]) <= float(base["sev"]) * 1.02:
				flags.append("USELESS")
		out.append("%-60s %7d %7d %7d %5.2f %3d/%-2d %5d %5d %+7.1f%% %2d/%-2d  %s" % ["(none)" if b.is_empty() else "+".join(PackedStringArray(b)), m["nw40"], m["nw80"], m["nw120"], m["ch11"], m["surv"], seeds.size(), m["resc"], m["sev"], d, _beats(row["runs"], rows[0]["runs"]), seeds.size(), " ".join(PackedStringArray(flags))])
	return out


static func _unreached(build: Array) -> bool:
	var tree: Parachutes = Parachutes.load_policies()
	for id in build:
		for e in tree.perks[id]["effects"]:
			if not UNREACHED_STATS.has(str(e["stat"])):
				return false
	return true


## Seeds where the build's net worth at round 120 beat the baseline's on the same seed.
static func _beats(runs: Array, base: Array) -> int:
	var n: int = 0
	for i in runs.size():
		if int((runs[i]["nw"] as Dictionary).get(120, 0)) > int((base[i]["nw"] as Dictionary).get(120, 0)):
			n += 1
	return n


static func _summ(runs: Array) -> Dictionary:
	var n: float = float(maxi(1, runs.size()))
	var nw := {40: 0.0, 80: 0.0, 120: 0.0}
	var ch: float = 0.0
	var sev: float = 0.0
	var surv: int = 0
	var resc: int = 0
	for r in runs:
		for k in nw:
			nw[k] += float((r["nw"] as Dictionary).get(k, 0))
		ch += float(r["filings"])
		sev += float(r["sev"])
		surv += 1 if int(r["filings"]) == 0 else 0
		resc += 1 if bool(r["rescued"]) else 0
	return {"nw40": int(nw[40] / n), "nw80": int(nw[80] / n), "nw120": int(nw[120] / n), "ch11": ch / n, "sev": int(sev / n), "surv": surv, "resc": resc}


## Per build, in how many seeds it has the best net worth at round 120 among its peers: the builds
## of its own size (roots alone, root+capstone pairs, and the four-pick set).
static func _win_counts(rows: Array) -> Dictionary:
	var out: Dictionary = {}
	var by_size: Dictionary = {}
	for row in rows:
		var sz: int = (row["build"] as Array).size()
		if sz == 0:
			continue
		if not by_size.has(sz):
			by_size[sz] = []
		(by_size[sz] as Array).append(row)
	for sz in by_size:
		var group: Array = by_size[sz]
		var n: int = (group[0]["runs"] as Array).size()
		for i in n:
			var best: int = -1
			var best_nw: int = -(1 << 60)
			for j in group.size():
				var v: int = int(((group[j]["runs"] as Array)[i]["nw"] as Dictionary).get(120, -(1 << 60)))
				if v > best_nw:
					best_nw = v
					best = j
			if best >= 0:
				var key: String = str(group[best]["build"])
				out[key] = int(out.get(key, 0)) + 1
	return out
