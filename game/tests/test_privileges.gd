extends RefCounted
## Epic 3 task 3 (part of #15, Baron Framework design): baron privileges. The
## docking toll on arrival (with its exemption set and the CR cap), the exclusive
## supply pipelines as world mods, the book and sidebar tag strings, the GalNet
## lines, and save/load/continue across an arrival toll.

const FRAME: float = 1.0 / 60.0 + 0.0001


## A docked run with a world on a 30-tick round, starting at Earth (Sol Central's).
func _ctx(p_seed: int = 21, with_world: bool = true) -> Dictionary:
	var rc := RunController.new(null, p_seed, null, {}, 30)
	if with_world:
		rc.world = Barons.for_new_run()
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("earth")
	return {"rc": rc, "hud": hud, "loop": lp}


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


## Flies until docked (or the guard runs out), acknowledging crises.
func _fly(lp: M0Loop, rc: RunController, max_ticks: int = 400) -> void:
	var guard: int = max_ticks * 4
	while rc.is_in_transit() and guard > 0:
		guard -= 1
		if lp.overlay_state == M0Loop.OVERLAY_CRISIS:
			lp.acknowledge_crisis()
		elif lp.overlay_state == M0Loop.OVERLAY_CONTRACT:
			lp.decline_contract()
		lp.advance(FRAME)


func _texts(hud: OrbitalHUD) -> Array:
	var out: Array = []
	for h in hud.galnet_headlines:
		out.append(str(h["text"]))
	return out


func _any(texts: Array, needle: String) -> bool:
	for t in texts:
		if str(t).contains(needle):
			return true
	return false


# --- privilege rules ---

func test_toll_is_the_anchor_barons_and_exempt_participants_pay_nothing() -> String:
	var w := Barons.for_new_run()
	var want := {"mars": 15, "ceres": 10, "earth": 12}
	for st in want:
		if w.docking_toll_due("player", st) != want[st]:
			return "%s toll is %d, want %d" % [st, w.docking_toll_due("player", st), want[st]]
	if w.docking_toll_due("player", "luna") != 0:
		return "an unanchored station charged a toll"
	if w.docking_toll_due("ares_heavy", "mars") != 0 or w.docking_toll_due("titan_cryo_hydro", "ceres") != 0:
		return "a baron paid a toll at its own station"
	# The exemption is per anchoring baron: Ares is not exempt at Ceres.
	if w.docking_toll_due("ares_heavy", "ceres") != 10:
		return "an outsider baron was waved through another baron's station"
	return "ok"


func test_holding_the_baron_puts_the_player_in_the_exemption_set() -> String:
	var w := Barons.for_new_run()
	w.state("ares_heavy").holder = "player"
	if w.docking_toll_due("player", "mars") != 0:
		return "the holder still pays at its own station"
	if w.docking_toll_due("player", "ceres") != 10:
		return "holding Ares exempted the player at Ceres"
	if w.docking_toll_due("rival_1", "mars") != 15:
		return "holding the baron exempted other participants"
	return "ok"


func test_toll_is_capped_at_the_cr_held() -> String:
	var w := Barons.for_new_run()
	if w.docking_toll("player", "mars", 100) != 15:
		return "full toll expected with CR to spare"
	if w.docking_toll("player", "mars", 7) != 7:
		return "toll not capped at the 7 CR held"
	if w.docking_toll("player", "mars", 0) != 0 or w.docking_toll("player", "mars", -5) != 0:
		return "toll charged against no CR"
	return "ok"


# --- arrival ---

func test_arrival_charges_the_docking_toll_and_posts_galnet() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var lp: M0Loop = c["loop"]
	rc.cr = 1000
	if not bool(rc.depart("mars")["ok"]):
		return "departure refused"
	if rc.cr != 1000:
		return "the docking toll was charged on departure (cr %d)" % rc.cr
	_fly(lp, rc)
	if rc.docked_at != "mars":
		return "did not arrive (docked '%s')" % rc.docked_at
	if rc.cr != 985:
		return "cr %d after arriving at Mars, want 985 (15 CR toll)" % rc.cr
	var texts: Array = _texts(c["hud"])
	if not _any(texts, "ARES HEAVY: 15 CR docking toll charged at ARCADIA FOUNDRIES"):
		return "no GalNet toll line: %s" % str(texts)
	return "ok"


func test_a_held_baron_waives_the_toll_and_says_so() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	rc.cr = 1000
	rc.world.state("ares_heavy").holder = "player"
	rc.depart("mars")
	_fly(c["loop"], rc)
	# Rent (task 7) pays a held baron's holder each round of the flight, so CR may only rise.
	if rc.docked_at != "mars" or rc.cr < 1000:
		return "docked '%s' cr %d: the holder was charged" % [rc.docked_at, rc.cr]
	if not _any(_texts(c["hud"]), "docking toll waived at ARCADIA FOUNDRIES"):
		return "no GalNet waiver line"
	return "ok"


func test_a_short_purse_pays_what_it_has() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	rc.cr = 1000
	rc.depart("mars")
	# Mid-voyage the purse runs low (a CR of 9 would also trip Chapter 11 and stop the
	# clock, so land the ship directly).
	rc.cr = 9
	rc._arrive()
	if rc.cr != 0:
		return "cr %d, want 0 (toll capped at the 9 CR held)" % rc.cr
	if not _any(_texts(c["hud"]), "took your last 9 CR"):
		return "no capped-toll GalNet line"
	return "ok"


func test_belt_toll_on_departure_and_docking_toll_on_arrival_both_apply() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	rc.cr = 1000
	rc.depart("ceres")  # belt route: 25 CR up front
	if rc.cr != 975:
		return "belt toll not charged on departure (cr %d)" % rc.cr
	_fly(c["loop"], rc)
	if rc.cr != 965:
		return "cr %d after Ceres, want 965 (25 belt + 10 docking)" % rc.cr
	return "ok"


func test_no_world_means_no_docking_toll() -> String:
	var c := _ctx(21, false)
	var rc: RunController = c["rc"]
	rc.cr = 1000
	rc.depart("mars")
	_fly(c["loop"], rc)
	if rc.docked_at != "mars" or rc.cr != 1000:
		return "a world-less run was charged (cr %d)" % rc.cr
	if _any(_texts(c["hud"]), "docking toll"):
		return "a world-less run posted a toll line"
	return "ok"


# --- pipelines ---

func test_pipeline_mods_are_ask_side_and_ordered_by_baron_id() -> String:
	var mods: Array = Barons.for_new_run().market_mods()
	if mods.size() != 6:
		return "want 2 pipelines per baron (6 mods), got %d" % mods.size()
	var stations: Array = []
	for m in mods:
		if stations.is_empty() or stations[-1] != m["station"]:
			stations.append(m["station"])
		if m.has("depth_bps") or m.has("price_bps"):
			return "a pipeline moved the bid side: %s" % str(m)
	if stations != ["mars", "earth", "ceres"]:  # ares_heavy, sol_central, titan_cryo_hydro
		return "mods not emitted in sorted baron-id order: %s" % str(stations)
	var first: Dictionary = mods[0]
	if first["commodity"] != "ORE" or int(first["ask_depth_bps"]) != 16000 or int(first["ask_price_bps"]) != 800:
		return "Ares ORE pipeline wrong: %s" % str(first)
	return "ok"


func test_outsider_pays_the_premium_on_the_ask_and_gets_depth() -> String:
	var plain := StationMarket.new()
	var c := _ctx()
	var m: StationMarket = c["loop"].market
	var a: Dictionary = plain.ladder("mars", "ORE", 5)
	var b: Dictionary = m.ladder("mars", "ORE", 5)
	for i in 5:
		var want: int = int(round(float(a["asks"][i]["price"]) * 1.08))
		if int(b["asks"][i]["price"]) != want:
			return "ask level %d is %s, want %d (+8%%)" % [i, b["asks"][i]["price"], want]
		if int(b["asks"][i]["quantity"]) != int(a["asks"][i]["quantity"]) * 16000 / 10000:
			return "ask level %d depth %s is not 1.6x %s" % [i, b["asks"][i]["quantity"], a["asks"][i]["quantity"]]
		if b["bids"][i]["price"] != a["bids"][i]["price"] or b["bids"][i]["quantity"] != a["bids"][i]["quantity"]:
			return "bid level %d changed: the pipeline is ask-side only" % i
	# A commodity with no pipeline at Mars is untouched.
	if m.ladder("mars", "FOOD", 5)["asks"] != plain.ladder("mars", "FOOD", 5)["asks"].map(func(r): var x: Dictionary = r.duplicate(); x["maker"] = "ares_heavy"; return x):
		return "a non-pipeline commodity changed"
	return "ok"


func test_holding_the_baron_drops_the_premium_but_keeps_the_depth() -> String:
	var plain := StationMarket.new()
	var c := _ctx()
	var rc: RunController = c["rc"]
	var m: StationMarket = c["loop"].market
	rc.world.state("ares_heavy").holder = "player"
	m.set_world_mods(rc.world.market_mods())
	var a: Dictionary = plain.ladder("mars", "ORE", 5)
	var b: Dictionary = m.ladder("mars", "ORE", 5)
	for i in 5:
		if b["asks"][i]["price"] != a["asks"][i]["price"]:
			return "a holder still pays the outsider premium at level %d" % i
		if int(b["asks"][i]["quantity"]) != int(a["asks"][i]["quantity"]) * 16000 / 10000:
			return "a holder lost the pipeline depth at level %d" % i
	return "ok"


func test_pipeline_survives_the_round_boundary() -> String:
	var c := _ctx()
	var m: StationMarket = c["loop"].market
	var before: Dictionary = m.ladder("mars", "MACHINERY", 5)
	m.execute("mars", "MACHINERY", "BUY", 20, 1000.0)
	m.replenish()
	if m.ladder("mars", "MACHINERY", 5) != before:
		return "replenish() did not restore the pipeline book"
	return "ok"


# --- tags ---

func test_book_and_sidebar_tags_come_through_loc() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	if lp.pipeline_tag("mars", "ORE") != "PIPELINE +8% ASK":
		return "pipeline tag '%s'" % lp.pipeline_tag("mars", "ORE")
	if lp.pipeline_tag("ceres", "FUEL") != "PIPELINE +7% ASK":
		return "ceres tag '%s'" % lp.pipeline_tag("ceres", "FUEL")
	if lp.pipeline_tag("mars", "FOOD") != "" or lp.pipeline_tag("luna", "ORE") != "":
		return "a book without a pipeline carries a tag"
	if lp.toll_line("mars") != "DOCKING TOLL 15 CR" or lp.toll_line("luna") != "":
		return "toll line '%s' / luna '%s'" % [lp.toll_line("mars"), lp.toll_line("luna")]
	c["rc"].world.state("ares_heavy").holder = "player"
	if lp.pipeline_tag("mars", "ORE") != "PIPELINE (YOURS)" or lp.toll_line("mars") != "DOCKING TOLL EXEMPT":
		return "held tags '%s' / '%s'" % [lp.pipeline_tag("mars", "ORE"), lp.toll_line("mars")]
	var bare := _ctx(21, false)
	if bare["loop"].pipeline_tag("mars", "ORE") != "" or bare["loop"].toll_line("mars") != "":
		return "a world-less run shows privilege tags"
	return "ok"


func test_tags_follow_the_locale() -> String:
	var c := _ctx()
	Loc.set_locale(Loc.LOCALE_PSEUDO)
	var tag: String = c["loop"].pipeline_tag("mars", "ORE")
	Loc.set_locale(Loc.LOCALE_EN)
	return "ok" if tag != "" and tag != "PIPELINE +8% ASK" else "the pipeline tag ignored the locale ('%s')" % tag


# --- save / load / continue ---

func test_save_mid_voyage_then_arrive_equals_the_run_that_kept_flying() -> String:
	var a := _ctx(33)
	var b := _ctx(33)
	for ctx in [a, b]:
		ctx["rc"].cr = 500
		ctx["rc"].world.state("ares_heavy").holder = ""
		ctx["rc"].depart("mars")
		var guard: int = 0
		while ctx["rc"].sim_clock.total_ticks < 30 and guard < 200:
			guard += 1
			ctx["loop"].advance(FRAME)
	if not (a["rc"] as RunController).is_in_transit():
		return "voyage ended too early to test a mid-voyage save"
	var bags_a := Bags.new("m0", null, 33)
	var loaded: Dictionary = RunSave.restore(_json(RunSave.capture(a["rc"], a["loop"].market, bags_a)))
	if not bool(loaded["ok"]):
		return "restore failed: %s" % loaded["error"]
	var rc_a: RunController = loaded["controller"]
	if rc_a.world == null or rc_a.world.market_mods() != (a["rc"] as RunController).world.market_mods():
		return "the restored world does not emit the same pipeline mods"
	var lp_a := M0Loop.new(OrbitalHUD.new(rc_a))
	lp_a.set_market(loaded["market"])
	_fly(lp_a, rc_a)
	_fly(b["loop"], b["rc"])
	if rc_a.docked_at != "mars" or b["rc"].docked_at != "mars":
		return "did not arrive: %s / %s" % [rc_a.docked_at, b["rc"].docked_at]
	if rc_a.cr != 485 or b["rc"].cr != 485:
		return "toll after load: cr %d vs %d, want 485 both" % [rc_a.cr, b["rc"].cr]
	var da: Dictionary = RunSave.capture(rc_a, lp_a.market, loaded["bags"])
	var db: Dictionary = RunSave.capture(b["rc"], b["loop"].market, bags_a)
	for key in ["controller", "bags", "world", "market"]:
		if RunSave.canonical(da[key]) != RunSave.canonical(db[key]):
			return "%s diverged between the saved-mid-voyage run and the one that kept flying" % key
	return "ok"


func test_a_held_baron_survives_a_save_with_its_exemption() -> String:
	var c := _ctx(5)
	var rc: RunController = c["rc"]
	rc.world.state("sol_central").holder = "player"
	var loaded: Dictionary = RunSave.restore(_json(RunSave.capture(rc, c["loop"].market, Bags.new("m0", null, 5))))
	var w: Barons = (loaded["controller"] as RunController).world
	if w.docking_toll_due("player", "earth") != 0 or w.docking_toll_due("player", "mars") != 15:
		return "the exemption did not survive the save"
	for m in w.market_mods():
		if m["station"] == "earth" and int(m["ask_price_bps"]) != 0:
			return "the restored pipeline still charges the holder"
	return "ok"
