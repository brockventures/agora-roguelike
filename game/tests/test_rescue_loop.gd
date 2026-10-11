extends RefCounted
## The Sol System Rescue Project, task 3 (#32, docs/design/rescue-project.md sections 3.2, 3.3, 9
## and 11): the m0_project action and its refusals, the site embargo and where it folds, the
## project opening when the player continues from the monopoly summary, rival route scoring on
## embargoed books, GalNet lines, and the embargo surviving a save.

const TPR: int = 30
const FIXTURE := "res://tests/fixtures/world/embargo_fold_order.json"


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


## A docked run (Luna) whose player holds every baron, with plenty of CR and no debt. Rival fleets
## stay on unless `fleets` is false. `open` opens the project the way the loop does.
func _ctx(open: bool = true, fleets: bool = true, cr: int = 1000000) -> Dictionary:
	var rc := RunController.new(null, 21, null, {}, TPR)
	rc.world = Barons.for_new_run()
	if not fleets:
		rc.world.rivals.clear()
	for id in rc.world.ids():
		Takeover.take(rc.world, id, Takeover.PLAYER, rc)
	rc.cr = cr
	rc.doomsday.clear_debt()
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("luna")
	if open:
		rc.open_rescue()
		lp._refresh_world_mods()
	return {"rc": rc, "hud": hud, "loop": lp, "market": lp.market, "world": rc.world}


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


func _ask_units(m: StationMarket, st: String, c: String) -> int:
	var n: int = 0
	for o: Order in m.get_book(st, c).asks:
		n += o.remaining_qty()
	return n


# --- The embargo and where it folds ---

func test_the_open_phase_embargoes_its_site_asks_and_nothing_else() -> String:
	var rp := RescueProject.open_new(1)
	var mods: Array = rp.embargo_mods()
	if mods != [{"station": "luna", "commodity": "MACHINERY", "ask_depth_bps": 0}, {"station": "luna", "commodity": "ORE", "ask_depth_bps": 0}]:
		return "phase 1 mods: %s" % str(mods)
	rp.phase = 1
	if rp.embargo_mods() != [{"station": "earth", "commodity": "FUEL", "ask_depth_bps": 0}, {"station": "earth", "commodity": "MACHINERY", "ask_depth_bps": 0}]:
		return "phase 2 mods: %s" % str(rp.embargo_mods())
	rp.phase = rp.phase_count()
	if not rp.embargo_mods().is_empty():
		return "a finished project still embargoes"
	return "ok"


func test_the_embargo_folds_after_every_baron_and_rival_mod() -> String:
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	var c := _ctx(true, true)
	var w: Barons = c["world"]
	var rc: RunController = c["rc"]
	# A standing front-run on the very book the embargo hits, from the first rival by sorted id.
	var f: RivalFleet = w.rival(w.rival_ids()[0])
	f.front = {"station": "luna", "commodity": "MACHINERY", "depth_bps": 6000, "until_round": 9}
	var plain: Array = w.market_mods()
	var full: Array = rc.world_mods()
	var tail: Array = full.slice(plain.size() - 1)
	if full.slice(0, plain.size()) != plain:
		return "the embargo moved an earlier mod"
	if _json({"t": tail}) != _json({"t": fx["tail"]}):
		return "tail %s, fixture %s" % [str(tail), str(fx["tail"])]
	if _json({"t": plain.slice(plain.size() - 1)}) != _json({"t": fx["last_before_embargo"]}):
		return "the mod just before the embargo is %s" % str(plain.slice(plain.size() - 1))
	# And the folded book: both mods apply; bids see the front-run only, asks are cut to a trickle.
	var m := StationMarket.new()
	m.unlock_station("luna")
	m.set_world_mods(full)
	var lad: Dictionary = m.ladder("luna", "MACHINERY", 5)
	for side in ["asks", "bids"]:
		for i in 5:
			var want: Array = fx["ladder_luna_machinery"][side][i]
			if int(lad[side][i]["price"]) != int(want[0]) or int(lad[side][i]["quantity"]) != int(want[1]):
				return "luna MACHINERY %s level %d is %s x%s, fixture says %s" % [side, i, lad[side][i]["price"], lad[side][i]["quantity"], str(want)]
	return "ok"


func test_embargoed_books_keep_a_mid_and_a_trickle_of_asks() -> String:
	var c := _ctx(true, false)
	var m: StationMarket = c["market"]
	var bare := StationMarket.new()
	bare.unlock_station("luna")
	bare.set_world(c["world"])
	bare.set_world_mods(c["world"].market_mods())
	m.unlock_station("luna")
	m.set_world_mods(c["rc"].world_mods())
	for com in ["MACHINERY", "ORE"]:
		if _ask_units(m, "luna", com) > StationMarket.DEPTH_LEVELS or _ask_units(m, "luna", com) < 1:
			return "%s asks: %d units" % [com, _ask_units(m, "luna", com)]
		if Rivals._mid(m, "luna", com) <= 0 or Rivals._mid(m, "luna", com) != Rivals._mid(bare, "luna", com):
			return "%s mid %d vs %d unembargoed" % [com, Rivals._mid(m, "luna", com), Rivals._mid(bare, "luna", com)]
		if m.ladder("luna", com, 5)["bids"] != bare.ladder("luna", com, 5)["bids"]:
			return "%s bids moved" % com
	# Other commodities at the site, and the same commodity elsewhere, are untouched.
	if _ask_units(m, "luna", "FUEL") != _ask_units(bare, "luna", "FUEL") or _ask_units(m, "mars", "ORE") != _ask_units(bare, "mars", "ORE"):
		return "the embargo leaked onto another book"
	return "ok"


func test_rival_route_scoring_reads_a_mid_on_an_embargoed_book() -> String:
	var c := _ctx(true, true)
	var w: Barons = c["world"]
	var rc: RunController = c["rc"]
	var bare := StationMarket.new()
	var embargoed := StationMarket.new()
	for m in [bare, embargoed]:
		m.set_world(w)
		for st in ["earth", "luna", "mars", "ceres"]:
			m.unlock_station(st)
	bare.set_world_mods(w.market_mods())
	embargoed.set_world_mods(rc.world_mods())
	var f: RivalFleet = w.rival(w.rival_ids()[0])
	f.at = "earth"
	f.cr = 100000
	f.cargo = {}
	f.route = {}
	# Luna is the destination of this scan: scoring reads its mid (and its bids), neither embargoed.
	var a: Dictionary = Rivals.plan(w, f, bare, 5)
	var b: Dictionary = Rivals.plan(w, f, embargoed, 5)
	if _json(a) != _json(b):
		return "an embargo at the destination changed the plan: %s vs %s" % [str(a), str(b)]
	# And from Luna itself the origin asks are thin, but the mids the score is built from are not.
	f.at = "luna"
	for com in Transit.COMMODITIES:
		if Rivals._mid(embargoed, "luna", com) != Rivals._mid(bare, "luna", com):
			return "luna %s mid moved under the embargo" % com
	var d: Dictionary = Rivals.plan(w, f, embargoed, 5)
	if not d.is_empty() and int(d["qty"]) <= 0:
		return "a plan with no quantity: %s" % str(d)
	return "ok"


# --- m0_project ---

func test_the_project_action_is_bound_named_and_off_the_other_controls() -> String:
	if not InputMap.has_action(M0Loop.ACT_PROJECT) or not M0Loop.ALL_ACTIONS.has(M0Loop.ACT_PROJECT):
		return "m0_project is not bound or not remappable"
	for e in InputMap.action_get_events(M0Loop.ACT_PROJECT):
		for a in InputMap.get_actions():
			if not str(a).begins_with("m0_") or str(a) == M0Loop.ACT_PROJECT:
				continue
			for o in InputMap.action_get_events(a):
				if e is InputEventJoypadButton and o is InputEventJoypadButton and e.button_index == o.button_index:
					return "the pad button is also bound to %s" % a
				if e is InputEventKey and o is InputEventKey and e.physical_keycode == o.physical_keycode:
					return "the key is also bound to %s" % a
	if Loc.t("SET_ACT_PROJECT") != "Deliver to the Rescue Project":
		return "no settings label"
	return "ok"


func test_refusals_say_why_and_change_nothing() -> String:
	# NOT_OPEN: the monopoly exists but nothing has opened the project yet.
	var c := _ctx(false)
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	rc.cargo = {"MACHINERY": 100}
	var before: String = JSON.stringify(rc.snapshot())
	if lp.dispatch_action(M0Loop.ACT_PROJECT) or lp.last_project_reason != "NOT_OPEN":
		return "not open: '%s'" % lp.last_project_reason
	if not _any(_texts(c["hud"]), "Delivery refused: the Rescue Project is not open"):
		return "no headline: %s" % str(_texts(c["hud"]))
	rc.open_rescue()
	# WRONG_SITE: Mars is not the phase 1 site.
	lp.dock_at("mars")
	if lp.dispatch_action(M0Loop.ACT_PROJECT) or lp.last_project_reason != "WRONG_SITE":
		return "wrong site: '%s'" % lp.last_project_reason
	# NO_CARGO at the right site.
	lp.dock_at("luna")
	rc.cargo = {"FOOD": 40}
	if lp.dispatch_action(M0Loop.ACT_PROJECT) or lp.last_project_reason != "NO_CARGO":
		return "no cargo: '%s'" % lp.last_project_reason
	# NO_CR: the fee is more than the corp holds.
	rc.cargo = {"MACHINERY": 100}
	rc.cr = 10
	var snap: String = JSON.stringify(rc.snapshot())
	var proj: String = JSON.stringify(rc.rescue.to_dict())
	if lp.dispatch_action(M0Loop.ACT_PROJECT) or lp.last_project_reason != "NO_CR":
		return "no cr: '%s'" % lp.last_project_reason
	if JSON.stringify(rc.snapshot()) != snap or JSON.stringify(rc.rescue.to_dict()) != proj:
		return "a refusal changed state"
	if not _any(_texts(c["hud"]), "Delivery refused: not enough CR for the fee"):
		return "no CR headline: %s" % str(_texts(c["hud"]))
	if before == "":
		return "unreachable"
	return "ok"


func test_a_delivery_moves_cargo_and_cr_and_posts_a_line() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	rc.cargo = {"MACHINERY": 60, "FOOD": 10}
	var cr0: int = rc.cr
	if not lp.dispatch_action(M0Loop.ACT_PROJECT):
		return "refused: '%s'" % lp.last_project_reason
	# 60 of 200 units of a 4000 CR phase: 1200 CR.
	if rc.cr != cr0 - 1200 or rc.cargo != {"FOOD": 10} or rc.rescue.deposits != {"MACHINERY": 60}:
		return "cr %d cargo %s deposits %s" % [rc.cr - cr0, str(rc.cargo), str(rc.rescue.deposits)]
	if not _any(_texts(c["hud"]), "Stabiliser: 60 units delivered at LUNA for 1200 CR"):
		return "no delivery line: %s" % str(_texts(c["hud"]))
	return "ok"


func test_a_finished_phase_moves_the_embargo_and_posts_its_lines() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	var m: StationMarket = c["market"]
	rc.cargo = {"MACHINERY": 100, "ORE": 100}
	if not lp.dispatch_action(M0Loop.ACT_PROJECT) or rc.rescue.phase != 1:
		return "phase 1 did not finish"
	var tail: Array = m.world_mods.slice(-2)
	if tail != [{"station": "earth", "commodity": "FUEL", "ask_depth_bps": 0}, {"station": "earth", "commodity": "MACHINERY", "ask_depth_bps": 0}]:
		return "the market kept the old embargo: %s" % str(tail)
	if _ask_units(m, "luna", "MACHINERY") <= StationMarket.DEPTH_LEVELS:
		return "luna was not reseeded after the embargo lifted"
	var t: Array = _texts(c["hud"])
	if not _any(t, "Stabiliser phase 1 of 4 complete. Next: Coil Foundry at KENNEDY ELEVATOR") or not _any(t, "Stabiliser field up: doomsday clock at 60% speed"):
		return "lines: %s" % str(t)
	return "ok"


func test_the_last_delivery_wins_the_run() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	for n in 4:
		var ph: Dictionary = rc.rescue.current()
		lp.dock_at(str(ph["site"]))
		rc.cargo = {}
		for com in ph["needs"]:
			rc.cargo[com] = int(ph["needs"][com])
		if not lp.dispatch_action(M0Loop.ACT_PROJECT):
			return "phase %d refused: '%s'" % [n + 1, lp.last_project_reason]
	if not rc.rescue.is_complete() or not rc.is_rescued() or not rc.is_run_over():
		return "the last delivery did not win: phase %d, reason '%s'" % [rc.rescue.phase, rc.end_reason]
	if not rc.sim_clock.paused:
		return "the clock still runs after the win"
	if not _any(_texts(c["hud"]), "SOL SYSTEM RESCUED in round"):
		return "no win line: %s" % str(_texts(c["hud"]))
	if not rc.rescue.embargo_mods().is_empty() or not c["market"].world_mods.filter(func(x): return x.has("ask_depth_bps") and int(x["ask_depth_bps"]) == 0).is_empty():
		return "an embargo outlived the project"
	# Nothing more to deliver; the key does nothing once the run is over.
	rc.cargo = {"MACHINERY": 100}
	if lp.dispatch_action(M0Loop.ACT_PROJECT):
		return "delivery accepted after the win"
	return "ok"


# --- Opening on the monopoly continue ---

func test_continuing_from_the_monopoly_summary_opens_the_project() -> String:
	var c := _ctx(false)
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	var m: StationMarket = c["market"]
	lp._raise_monopoly_if_any()
	if lp.overlay_state != M0Loop.OVERLAY_MONOPOLY:
		return "no monopoly summary (overlay '%s')" % lp.overlay_state
	if rc.rescue != null:
		return "the project opened before A"
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "A did not continue"
	if rc.rescue == null or rc.rescue.phase != 0 or not rc.rescue.is_open():
		return "the project did not open"
	if rc.world.rent_bonus_bps != 20000:
		return "no rent bonus: %d" % rc.world.rent_bonus_bps
	var tail: Array = m.world_mods.slice(-2)
	if tail != rc.rescue.embargo_mods():
		return "the market has no embargo: %s" % str(tail)
	if not _any(_texts(c["hud"]), "Sol System Rescue Project open: build the Stabiliser in 4 phases. Phase 1, Anchor Yard, is at LUNA"):
		return "no open line: %s" % str(_texts(c["hud"]))
	# A second continue (a re-taken monopoly after a filing) keeps the project it has.
	var before: String = JSON.stringify(rc.rescue.to_dict())
	if rc.open_rescue() or JSON.stringify(rc.rescue.to_dict()) != before:
		return "a second open replaced the project"
	return "ok"


func test_a_run_that_never_reaches_the_monopoly_is_unchanged() -> String:
	var rc := RunController.new(null, 21, null, {}, TPR)
	rc.world = Barons.for_new_run()
	if _json({"m": rc.world_mods()}) != _json({"m": rc.world.market_mods()}):
		return "world_mods differs from market_mods with no project"
	if rc.world_mods() != rc.world.market_mods(null):
		return "a null project emits mods"
	return "ok"


# --- Saves ---

func test_the_embargo_survives_a_save() -> String:
	var c := _ctx(true, false)
	var rc: RunController = c["rc"]
	var m: StationMarket = c["market"]
	var bags := Bags.new()
	var cap: Dictionary = RunSave.capture(rc, m, bags)
	var r: Dictionary = RunSave.restore(_json(cap))
	if not bool(r["ok"]):
		return str(r)
	var back: StationMarket = r["market"]
	if back.world_mods != rc.world_mods() or back.world_mods.slice(-2) != rc.rescue.embargo_mods():
		return "restored mods %s" % str(back.world_mods.slice(-3))
	return "ok"
