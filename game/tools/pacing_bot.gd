extends SceneTree
## The Rescue Project's headless pacing bot (#32 task 5, docs/design/rescue-project.md sections 7 and 11).
##
##   godot --headless --path game -s res://tools/pacing_bot.gd -- haul  [seeds]   # k, clock used, money
##   godot --headless --path game -s res://tools/pacing_bot.gd -- slow  [seed]    # k against clock used, slower players
##   godot --headless --path game -s res://tools/pacing_bot.gd -- late  [seeds]   # monopoly at round R: win or collapse
##   godot --headless --path game -s res://tools/pacing_bot.gd -- trade [seeds]   # trading-up time and income
##   godot --headless --path game -s res://tools/pacing_bot.gd -- chain [seed] [cr ...]  # capital for the monopoly
##   godot --headless --path game -s res://tools/pacing_bot.gd -- all
##
## Seeds are comma separated (default 84,7,21,3,11,42). Everything is the shipped world on the
## real 900-tick round with rival fleets on (except `chain`, which removes them as the doc's
## probe did). The bot's logic is tools/rescue_bot.gd; this file only runs it and prints.
## "k" is the section 7.2 ratio: rounds the haul took / the ideal 27 rounds (k = 1 is ideal).

const DEFAULT_SEEDS: Array = [84, 7, 21, 3, 11, 42]
const TPR: int = 900


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var mode: String = args[0] if args.size() > 0 else "all"
	var rb = load("res://tools/rescue_bot.gd")
	var seeds: Array = _seeds(args[1] if args.size() > 1 else "")
	match mode:
		"haul":
			_haul(rb, seeds)
		"slow":
			_slow(rb, seeds[0])
		"late":
			_late(rb, seeds)
		"trade":
			_trade(rb, seeds)
		"chain":
			var crs: Array = []
			for i in range(2, args.size()):
				crs.append(int(args[i]))
			_chain(rb, seeds[0], crs)
		_:
			_haul(rb, seeds)
			_slow(rb, seeds[0])
			_late(rb, seeds)
			_trade(rb, seeds)
			_chain(rb, seeds[0], [])
	quit(0)


func _seeds(txt: String) -> Array:
	if txt == "":
		return DEFAULT_SEEDS
	var out: Array = []
	for p in txt.split(","):
		out.append(int(p))
	return out


## One haul: [rounds, per-phase rounds, clock rounds used, money].
func _one(rb, sd: int, idle: int) -> Dictionary:
	var cr0: int = 60000
	var res: Dictionary = rb.haul(sd, cr0, Callable(), Callable(), true, null, idle)
	var rep: Dictionary = rb.haul_report(res["session"])
	var rounds: int = int(rep["round_end"])
	var comp: Array = rep["completed"]
	var phases: Array = []
	var prev: int = int(rep["opened_round"])
	for e in comp:
		phases.append(int(e[1]) - prev)
		prev = int(e[1])
	return {
		"won": rep["won"], "rounds": rounds - int(rep["opened_round"]), "phases": phases,
		"k": float(rounds - int(rep["opened_round"])) / float(rb.IDEAL_ROUNDS),
		"clock_used": float(int(res["clock_start"]) - int(res["session"].controller.doomsday.ticks_remaining)) / float(TPR),
		"cr_delta": int(rep["cr"]) - cr0, "refusals": res["log"].refusals.size(),
	}


func _haul(rb, seeds: Array) -> void:
	print("== HAUL: a greedy hauler from the monopoly, CR 60000, rivals on ==")
	print("seed  won  haul_rounds  k      phase_rounds       clock_rounds_used  cr_change  refused")
	var ks: Array = []
	var used: Array = []
	for sd in seeds:
		var r: Dictionary = _one(rb, int(sd), 0)
		ks.append(r["k"])
		used.append(r["clock_used"])
		print("%-5d %-4s %-12d %-6.2f %-18s %-18.1f %-10d %d" % [sd, str(r["won"]), r["rounds"], r["k"], str(r["phases"]), r["clock_used"], r["cr_delta"], r["refusals"]])
	print("mean k %.2f, min %.2f, max %.2f; mean clock rounds used %.1f, max %.1f" % [_mean(ks), ks.min(), ks.max(), _mean(used), used.max()])


## The same hauler made slower (it waits `idle` rounds after every arrival): the k that a monopoly
## landing in a given round can still afford. Section 7.2's table, measured.
func _slow(rb, sd: int) -> void:
	print("== SLOW: seed %d, the hauler waits N rounds after each arrival ==" % sd)
	print("idle  k      haul_rounds  clock_rounds_used  won  fits_if_monopoly_at_round: 79(41 left) 90(30) 100(20) 110(10)")
	for idle in [0, 1, 2, 3, 4, 6]:
		var r: Dictionary = _one(rb, sd, idle)
		var u: float = r["clock_used"]
		print("%-5d %-6.2f %-12d %-18.1f %-4s %s %s %s %s" % [idle, r["k"], r["rounds"], u, str(r["won"]), _fit(u, 41), _fit(u, 30), _fit(u, 20), _fit(u, 10)])


func _mean(a: Array) -> float:
	var t: float = 0.0
	for v in a:
		t += float(v)
	return t / float(maxi(1, a.size()))


## The monopoly lands at round R (both clocks R rounds in): does the greedy hauler win, and with
## what Severance? Section 7.2's table, played out rather than inferred.
func _late(rb, seeds: Array) -> void:
	print("== LATE: the monopoly lands at round R (CR 60000), the same hauler ==")
	print("R    seed  outcome    win_round  clock_left_at_end  rescue_sev  total_sev")
	for r0 in [79, 90, 100, 105, 110]:
		for sd in seeds:
			var res: Dictionary = rb.haul(int(sd), 60000, Callable(), Callable(), true, null, 0, r0)
			var rc: RunController = res["session"].controller
			var won: bool = rc.is_rescued()
			print("%-4d %-5d %-10s %-10d %-18d %-11d %d" % [r0, sd, "RESCUED" if won else ("collapsed" if rc.is_collapsed() else "stuck"), rc.get_current_round(), int(rc.doomsday.ticks_remaining / TPR), rc.rescue_severance_award, rc.severance_award])


func _fit(used: float, left: int) -> String:
	return "yes" if used <= float(left) else "no "


func _trade(rb, seeds: Array) -> void:
	print("== TRADE: a fresh 5000 CR corp, greedy best-profit-per-round trader, no baron work ==")
	print("seed  rounds_run  end                 cr@20  cr@40  cr@60  peak_net_worth  gross_cr_per_round(r10..end)")
	for sd in seeds:
		var res: Dictionary = rb.trade(int(sd), 119)
		var tr: Array = res["trace"]
		var rc: RunController = res["session"].controller
		var peak: int = 0
		for e in tr:
			peak = maxi(peak, int(e["net_worth"]))
		var end: String = "bankrupt (pending)" if rc.pending_bankruptcy else ("run over" if rc.is_run_over() else "round 119")
		var n: int = tr.size()
		var per: float = 0.0
		if n > 11:
			per = float(int(tr[n - 1]["cr"]) - int(tr[10]["cr"])) / float(n - 11)
		print("%-5d %-11d %-19s %-6s %-6s %-6s %-15d %.0f" % [sd, n, end, _at(tr, 20), _at(tr, 40), _at(tr, 60), peak, per])


func _at(tr: Array, r: int) -> String:
	return str(tr[r]["cr"]) if r < tr.size() else "-"


func _chain(rb, sd: int, crs: Array) -> void:
	if crs.is_empty():
		crs = [55000, 70000, 85000, 100000, 115000]
	print("== CHAIN: seed %d, rivals removed, corner -> credit -> default -> distress lot at Sol Central, Titan, Ares ==" % sd)
	print("cr_start  taken(round)                                    held  monopoly  net_worth  debt    insolvent")
	for bps in [5000, 10000]:
		print("player_assumed_debt_bps = %d (%s)" % [bps, "shipped, half the baron's debt" if bps == 5000 else "the pre-Q1a full assumption, for comparison"])
		for cr in crs:
			var r: Dictionary = rb.chain(sd, int(cr), 119, bps)
			print("%-9d %-47s %-5d %-9s %-10d %-7d %s" % [cr, str(r["taken"]), r["held"], str(r["monopoly"]), r["net_worth"], r["debt"], str(r["insolvent"])])
