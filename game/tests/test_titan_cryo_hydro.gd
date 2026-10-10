extends RefCounted
## Epic 3 task 5 (part of #16, Baron Archetype AIs): Titan Cryo-Hydro. The hoard
## state machine (trigger, hoarding, cornered, releasing, cooldown), the corner and
## release mods in the Ceres book, the FOOD decay link, determinism, a held baron,
## the random-never-forces-Chapter-11 rule, GalNet lines and tags, and
## save/load/continue equality (seeds 84 and 7) including in the middle of a hoard.

const FRAME: float = 1.0 / 60.0 + 0.0001
const TPR: int = 30
const TITAN: String = "titan_cryo_hydro"


## A docked run with a world on a 30-tick round, starting at Ceres (Titan's).
func _ctx(p_seed: int = 21) -> Dictionary:
	var rc := RunController.new(null, p_seed, null, {}, TPR)
	rc.world = Barons.for_new_run()
	rc.world.rivals.clear()  # not what this test is about; test_rival_fleets.gd covers the fleets
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("ceres")
	return {"rc": rc, "hud": hud, "loop": lp, "world": rc.world, "market": lp.market}


func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d))


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


func _kinds(events: Array) -> Array:
	var out: Array = []
	for e in events:
		out.append(str(e["kind"]))
	return out


## The player eats `qty` units of Ceres ask in the commodity.
func _eat(c: Dictionary, commodity: String, qty: int) -> void:
	(c["market"] as StationMarket).execute("ceres", commodity, "BUY", qty, 9999.0)


## One round boundary the way M0Loop runs it: world step, mods, reseed.
func _round(c: Dictionary, r: int) -> Array:
	var w: Barons = c["world"]
	var m: StationMarket = c["market"]
	var ev: Array = w.advance_round(r, c["rc"], m)
	m.set_world_mods(w.market_mods())
	m.replenish()
	# Titan's events only: Ares posts its own contract offers on the same clock.
	return ev.filter(func(e): return str(e.get("baron", "")) == TITAN)


## A hoard in progress on `commodity`, started by eating the ask at round 1.
func _start(c: Dictionary, commodity: String = "FUEL", r: int = 1) -> Array:
	_eat(c, commodity, 60)
	return _round(c, r)


func _phase(c: Dictionary, commodity: String) -> String:
	return str(TitanCryoHydro.hoard(c["world"], TITAN, commodity).get("phase", ""))


# --- the trigger ---

func test_an_untouched_book_never_triggers_a_hoard() -> String:
	var c := _ctx()
	for r in range(1, 20):
		if not _round(c, r).is_empty():
			return "round %d: Titan hoarded against an untouched book" % r
	if not (c["world"] as Barons).state(TITAN).scratch.is_empty():
		return "an idle Titan left state behind"
	return "ok"


func test_the_book_has_to_be_eaten_into_the_trigger_depth() -> String:
	var c := _ctx()
	_eat(c, "FUEL", 20)  # ~92% left of the pipeline-deep ask, above the 85% trigger
	if not _round(c, 1).is_empty():
		return "a small bite tripped the trigger"
	var ratio: int = (c["market"] as StationMarket).ask_depth_ratio_bps("ceres", "FUEL")
	if ratio != 10000:
		return "the replenished book reads %d bps of nominal, want 10000" % ratio
	_eat(c, "FUEL", 60)
	var ev := _round(c, 2)
	if _kinds(ev) != ["hoard"] or str(ev[0]["commodity"]) != "FUEL" or str(ev[0]["station"]) != "ceres":
		return "a deep bite did not start a FUEL hoard: %s" % str(ev)
	return "ok"


func test_without_a_market_the_trigger_cannot_fire() -> String:
	var c := _ctx()
	_eat(c, "FUEL", 80)
	if not (c["world"] as Barons).advance_round(1, c["rc"]).is_empty():
		return "Titan hoarded with no book to read"
	return "ok"


func test_the_treasury_has_to_cover_a_rounds_buy() -> String:
	var c := _ctx()
	(c["world"] as Barons).state(TITAN).treasury_cr = 100  # 40 units x 25 CR = 1000
	_eat(c, "FUEL", 80)
	if not _round(c, 1).is_empty():
		return "a broke Titan started a hoard"
	return "ok"


# --- hoarding ---

func test_hoarding_thins_the_ask_and_buys_stock_with_treasury() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	var st: BaronState = w.state(TITAN)
	var cr0: int = st.treasury_cr
	var inv0: int = int(st.inventory["FUEL"])
	_start(c)
	if _phase(c, "FUEL") != "hoarding":
		return "phase '%s', want hoarding" % _phase(c, "FUEL")
	var bought: int = int(st.inventory["FUEL"]) - inv0
	if bought < 36 or bought > 40:
		return "Titan stocked %d units, want about hoard_cap_qty (40)" % bought
	if cr0 - st.treasury_cr != bought * 25:
		return "paid %d CR for %d units at 25 base" % [cr0 - st.treasury_cr, bought]
	# The mod shows in the reseeded book: about `bought` fewer units on the ask.
	var m: StationMarket = c["market"]
	var left: int = 0
	for o in m.get_book("ceres", "FUEL").asks:
		left += o.remaining_qty()
	var plain: int = StationMarket.ask_qty_at(15000)
	if plain - left != bought:
		return "the book lost %d units of ask, Titan stocked %d" % [plain - left, bought]
	if not m.get_book("ceres", "FOOD").asks.is_empty() and m.ask_depth_ratio_bps("ceres", "FOOD") != 10000:
		return "the FOOD book was touched by a FUEL hoard"
	return "ok"


func test_the_hoard_never_touches_the_players_money() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var cr: int = rc.cr
	var principal: int = rc.doomsday.principal_debt
	var pre: bool = bool(rc.assess()["insolvent"])
	_start(c)
	for r in range(2, 20):
		_round(c, r)
		if rc.cr != cr or rc.doomsday.principal_debt != principal:
			return "round %d: a Titan step moved the player's CR or debt" % r
	if bool(rc.assess()["insolvent"]) != pre:
		return "a full hoard cycle changed whether the corp is insolvent"
	return "ok"


# --- cornered ---

func test_stock_reaching_the_corner_line_corners_the_book() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	var events: Array = _start(c)
	var r: int = 1
	while _phase(c, "FUEL") == "hoarding" and r < 12:
		r += 1
		events.append_array(_round(c, r))
	if _phase(c, "FUEL") != "cornered":
		return "never cornered (phase '%s')" % _phase(c, "FUEL")
	if int(w.state(TITAN).inventory["FUEL"]) < 330:
		return "cornered with only %d FUEL, line is 330" % int(w.state(TITAN).inventory["FUEL"])
	if _kinds(events).count("corner") != 1:
		return "the corner was announced %d times" % _kinds(events).count("corner")
	var mods: Array = w.market_mods().filter(func(m): return str(m.get("station", "")) == "ceres" and str(m.get("commodity", "")) == "FUEL" and m.has("price_bps"))
	if mods.size() != 1 or int(mods[0]["price_bps"]) != 2500 or int(mods[0]["ask_depth_bps"]) != 4000:
		return "corner mod wrong: %s" % str(mods)
	var lad: Dictionary = (c["market"] as StationMarket).ladder("ceres", "FUEL", 1)
	# Base FUEL at Ceres 24.5: a corner lifts the mid ~25% over an unmodified book.
	var plain := StationMarket.new(["ceres"])
	if float(lad["best_ask"]) < float(plain.ladder("ceres", "FUEL", 1)["best_ask"]) * 1.2:
		return "the cornered ask %.1f is not ~25%% over the plain %.1f" % [lad["best_ask"], plain.ladder("ceres", "FUEL", 1)["best_ask"]]
	if float(lad["best_bid"]) <= float(plain.ladder("ceres", "FUEL", 1)["best_bid"]):
		return "the corner did not lift the bid the player sells into"
	var tag: String = (c["loop"] as M0Loop).hoard_tag("ceres", "FUEL")
	if tag != "CORNER +25%":
		return "tag '%s', want CORNER +25%%" % tag
	return "ok"


# --- releasing ---

## Plays rounds until `phase` shows on FUEL (or `max` rounds pass); returns the rounds used.
func _until_phase(c: Dictionary, phase: String, from_round: int, commodity: String = "FUEL", max_rounds: int = 20) -> int:
	var r: int = from_round
	while _phase(c, commodity) != phase and r < from_round + max_rounds:
		r += 1
		_round(c, r)
	return r


func test_the_hold_runs_out_and_the_book_floods() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	_start(c)
	var st: BaronState = w.state(TITAN)
	var hold: int = int(TitanCryoHydro.hoard(w, TITAN, "FUEL")["hold"])
	if hold < 5 or hold > 7:
		return "hold %d is outside release_after_rounds +/- 1" % hold
	var r: int = _until_phase(c, "releasing", 1)
	if _phase(c, "FUEL") != "releasing":
		return "never released"
	if r != hold:
		return "released at round %d, the hold was %d (age counts from the first buy)" % [r, hold]
	var mods: Array = w.market_mods().filter(func(m): return str(m.get("commodity", "")) == "FUEL" and str(m.get("station", "")) == "ceres" and m.has("price_bps"))
	if mods.size() != 1 or int(mods[0]["price_bps"]) != -1500 or int(mods[0]["ask_depth_bps"]) != 20000:
		return "release mod wrong: %s" % str(mods)
	var tag: String = (c["loop"] as M0Loop).hoard_tag("ceres", "FUEL")
	if tag != "RELEASE -15%":
		return "tag '%s', want RELEASE -15%%" % tag
	var stock: int = int(st.inventory["FUEL"])
	var cr: int = st.treasury_cr
	_round(c, r + 1)
	if int(st.inventory["FUEL"]) >= stock or st.treasury_cr <= cr:
		return "releasing did not sell stock back into treasury"
	if int(st.inventory["FUEL"]) < 250:
		return "Titan sold below its opening stock (%d)" % int(st.inventory["FUEL"])
	return "ok"


func test_release_ends_idle_then_a_cooldown_holds_off_a_new_hoard() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	_start(c)
	var r: int = _until_phase(c, "releasing", 1)
	while _phase(c, "FUEL") != "" and r < 40:
		r += 1
		_round(c, r)
	if _phase(c, "FUEL") != "":
		return "never went back to idle"
	if not w.hoard_on("ceres", "FUEL").is_empty():
		return "hoard_on still reports a hoard"
	_eat(c, "FUEL", 80)
	if not _round(c, r + 1).is_empty():
		return "a new hoard started inside the cooldown"
	_eat(c, "FUEL", 80)
	r += 4
	if _kinds(_round(c, r)) != ["hoard"]:
		return "no new hoard once the cooldown ended"
	return "ok"


func test_a_treasury_that_cannot_cover_the_buy_trips_the_release() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	_start(c)
	w.state(TITAN).treasury_cr = 10
	var ev := _round(c, 2)
	if _phase(c, "FUEL") != "releasing" or not _kinds(ev).has("release"):
		return "treasury strain did not release (phase '%s')" % _phase(c, "FUEL")
	return "ok"


# --- the FOOD decay link ---

func test_hoarded_food_decays_and_fuel_does_not() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	var st: BaronState = w.state(TITAN)
	_eat(c, "FOOD", 70)
	_eat(c, "FUEL", 70)
	_round(c, 1)
	var food: int = int(st.inventory["FOOD"])
	var h: Dictionary = TitanCryoHydro.hoard(w, TITAN, "FOOD")
	if int(h["spoiled"]) != 10:
		return "first-round decay was %d, want 5%% of 200 = 10" % int(h["spoiled"])
	var fuel_h: Dictionary = TitanCryoHydro.hoard(w, TITAN, "FUEL")
	if int(fuel_h["spoiled"]) != 0:
		return "FUEL decayed (%d)" % int(fuel_h["spoiled"])
	if food <= 200:
		return "FOOD stock %d, want 200 - 10 + about 40 bought" % food
	return "ok"


func test_idle_food_does_not_decay() -> String:
	var c := _ctx()
	for r in range(1, 10):
		_round(c, r)
	if int((c["world"] as Barons).state(TITAN).inventory["FOOD"]) != 200:
		return "an idle Titan's FOOD moved"
	return "ok"


func test_the_spoilage_is_reported_on_release() -> String:
	var c := _ctx()
	_eat(c, "FOOD", 70)
	var events: Array = _round(c, 1)
	for r in range(2, 14):
		events.append_array(_round(c, r))
	var spoil: Array = events.filter(func(e): return str(e["kind"]) == "spoil")
	if spoil.size() != 1 or str(spoil[0]["commodity"]) != "FOOD" or int(spoil[0]["qty"]) < 30:
		return "spoil events wrong: %s" % str(spoil)
	if not _kinds(events).has("release"):
		return "FOOD was never released"
	return "ok"


func test_decay_below_the_corner_line_lapses_the_premium() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	_eat(c, "FOOD", 70)
	_round(c, 1)
	var r: int = _until_phase(c, "cornered", 1, "FOOD")
	if _phase(c, "FOOD") != "cornered":
		return "FOOD never cornered"
	w.state(TITAN).inventory["FOOD"] = 100  # a heavy spoilage event
	w.state(TITAN).scratch["hoard"]["FOOD"]["hold"] = 30  # keep the hold out of the way
	_round(c, r + 1)
	if _phase(c, "FOOD") != "hoarding":
		return "phase '%s' after the stock fell under the line, want hoarding" % _phase(c, "FOOD")
	if w.market_mods().any(func(m): return str(m.get("commodity", "")) == "FOOD" and int(m.get("price_bps", 0)) != 0):
		return "the corner premium outlived the corner"
	return "ok"


# --- determinism ---

func test_the_hold_is_a_pure_function_of_run_seed_and_round() -> String:
	var a := _ctx(21)
	var b := _ctx(21)
	_start(a)
	_start(b)
	if TitanCryoHydro.hoard(a["world"], TITAN, "FUEL") != TitanCryoHydro.hoard(b["world"], TITAN, "FUEL"):
		return "same seed, different hoard"
	var seen: Dictionary = {}
	for sd in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]:
		var c := _ctx(sd)
		_start(c)
		seen[int(TitanCryoHydro.hoard(c["world"], TITAN, "FUEL")["hold"])] = true
	for k in seen:
		if k < 5 or k > 7:
			return "hold %d outside 6 +/- 1" % k
	if seen.size() < 2:
		return "ten seeds produced one hold length: no jitter"
	return "ok"


func test_a_round_with_no_decision_leaves_the_state_alone() -> String:
	var a := _ctx()
	var b := _ctx()
	_start(a)
	_start(b)
	for r in range(2, 6):
		_round(a, r)
		_round(b, r)
	if (a["world"] as Barons).to_dict() != (b["world"] as Barons).to_dict():
		return "two identical runs drifted apart"
	return "ok"


# --- held baron, Chapter 11, no world ---

func test_a_held_baron_hoards_nothing_and_drops_its_mods() -> String:
	var c := _ctx()
	var w: Barons = c["world"]
	_start(c)
	w.state(TITAN).holder = "player"
	_eat(c, "FOOD", 80)
	var ev := _round(c, 2)
	if not ev.is_empty() or not w.state(TITAN).scratch.is_empty():
		return "a held Titan kept hoarding: %s" % str(ev)
	if not w.market_mods().filter(func(m): return m.has("price_bps")).is_empty():
		return "a held Titan still emitted a price mod"
	if w.hoard_on("ceres", "FUEL") != {}:
		return "a held Titan still reports a hoard"
	return "ok"


func test_filing_chapter_11_is_not_forced_by_titan_and_the_hoard_is_the_worlds() -> String:
	var c := _ctx()
	var rc: RunController = c["rc"]
	var w: Barons = c["world"]
	_start(c)
	for r in range(2, 8):
		_round(c, r)
	if bool(rc.assess()["insolvent"]) or rc.pending_bankruptcy:
		return "a Titan hoard pushed a solvent corp toward Chapter 11"
	# The hoard is the baron's own strategy, not the failed corp's obligation (unlike
	# Ares's contract): the world persists through a filing.
	var before: String = JSON.stringify(w.state(TITAN).scratch)
	rc.file_bankruptcy()
	if JSON.stringify(w.state(TITAN).scratch) != before:
		return "filing Chapter 11 rewrote Titan's hoard"
	return "ok"


func test_no_world_means_none_of_it() -> String:
	var rc := RunController.new(null, 21, null, {}, TPR)
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at("ceres")
	for i in 600:
		lp.advance(FRAME)
	if lp.hoard_tag("ceres", "FUEL") != "":
		return "a world-less run grew a hoard tag"
	if lp.market.ask_depth_ratio_bps("nowhere", "FUEL") != -1:
		return "ask_depth_ratio_bps invented a book"
	return "ok"


func test_validation_requires_the_new_hoarder_params() -> String:
	var d: Dictionary = _json(Barons.load_data())
	if not Barons.validate(d).is_empty():
		return "the shipped file is invalid: %s" % str(Barons.validate(d))
	for k in ["corner_inventory_qty", "release_discount_bps", "food_decay_bps", "cooldown_rounds"]:
		var bad: Dictionary = _json(d)
		(bad["barons"][1]["params"] as Dictionary).erase(k)
		if Barons.validate(bad).is_empty():
			return "a hoarder without %s validated" % k
	var bad2: Dictionary = _json(d)
	bad2["barons"][1]["params"]["corner_inventory_qty"] = {"GOLD": 5}
	if Barons.validate(bad2).is_empty():
		return "an unknown commodity in corner_inventory_qty validated"
	return "ok"


# --- GalNet lines and tags through the loop ---

func test_the_loop_posts_headlines_and_tags() -> String:
	var c := _ctx()
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	_eat(c, "FUEL", 80)
	lp._on_round_advanced(1)
	var t := _texts(c["hud"])
	if not _any(t, "TITAN CRYO-HYDRO") or not _any(t, "buying up"):
		return "no hoard headline: %s" % str(t)
	if lp.hoard_tag("ceres", "FUEL") != "HOARDED":
		return "tag '%s', want HOARDED" % lp.hoard_tag("ceres", "FUEL")
	for r in range(2, 9):
		lp._on_round_advanced(r)
	t = _texts(c["hud"])
	if not _any(t, "has cornered") or not _any(t, "price up 25%"):
		return "no corner headline: %s" % str(t)
	for r in range(9, 12):
		lp._on_round_advanced(r)
	t = _texts(c["hud"])
	if not _any(t, "releases its") or not _any(t, "price down 15%"):
		return "no release headline: %s" % str(t)
	if rc.cr != RunController.new(null, 21, null, {}, TPR).cr:
		return "a headline step moved the player's CR"
	return "ok"


# --- save / load / continue ---

## Eats the Ceres FUEL ask every `every` frames: the player's trading that trips Titan.
func _play(s: Replay.Session, frames: int, stop: Callable = Callable()) -> int:
	var used: int = 0
	for i in frames:
		if s.loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
			s.loop.decline_contract()
		elif s.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			s.loop.acknowledge_crisis()
		if i % 45 == 0:
			s.loop.market.execute("ceres", "FUEL", "BUY", 60, 9999.0)
			s.loop.market.execute("ceres", "FOOD", "BUY", 60, 9999.0)
		s.advance()
		used += 1
		if stop.is_valid() and bool(stop.call()):
			break
	return used


func _resume(cap: Dictionary) -> Dictionary:
	var r: Dictionary = RunSave.restore(cap.duplicate(true))
	var rc: RunController = r["controller"]
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.set_market(r["market"])
	lp.sync_hud_to_ship()
	hud.set_station(rc.docked_at)
	return {"rc": rc, "loop": lp, "market": r["market"], "bags": r["bags"]}


func _continue_equal(p_seed: int, mid_hoard: bool) -> String:
	var total: int = 1500
	var whole := Replay.Session.new(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	whole.loop.dock_at("ceres")
	_play(whole, total)
	if whole.controller.world.state(TITAN).scratch.is_empty():
		return "seed %d: the uninterrupted run never hoarded" % p_seed
	var split := Replay.Session.new(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)
	split.loop.dock_at("ceres")
	var stop: Callable = func(): return not split.controller.world.hoard_on("ceres", "FUEL").is_empty() and int(split.controller.world.hoard_on("ceres", "FUEL")["age"]) >= (2 if mid_hoard else 1)
	var used: int = _play(split, total, stop)
	if used >= total:
		return "seed %d: never reached the split point" % p_seed
	var cap: Dictionary = RunSave.capture(split.controller, split.loop.market, split.bags)
	var via_json: Dictionary = RunSave.restore(_json(cap))
	if not bool(via_json["ok"]) or RunSave.state_hash(via_json["controller"], via_json["market"], via_json["bags"]) != split.state_hash():
		return "seed %d: the save file round trip changed the hash" % p_seed
	if str((via_json["controller"] as RunController).world.market_mods()) != str(split.controller.world.market_mods()):
		return "seed %d: the restored world emits different mods" % p_seed
	var back := _resume(cap)
	var lp: M0Loop = back["loop"]
	if lp.hoard_tag("ceres", "FUEL") == "":
		return "seed %d: the hoard tag did not come back" % p_seed
	# Resume with the same player trading the original run did from frame `used` on.
	for i in total - used:
		if lp.overlay_state == M0Loop.OVERLAY_CONTRACT:
			lp.decline_contract()
		elif lp.overlay_state == M0Loop.OVERLAY_CRISIS:
			lp.acknowledge_crisis()
		if (used + i) % 45 == 0:
			lp.market.execute("ceres", "FUEL", "BUY", 60, 9999.0)
			lp.market.execute("ceres", "FOOD", "BUY", 60, 9999.0)
		lp.advance(Replay.DEFAULT_FRAME_DELTA)
	if RunSave.state_hash(back["rc"], lp.market, back["bags"]) != whole.state_hash():
		return "seed %d: save/load/continue diverged from the uninterrupted run" % p_seed
	return "ok"


func test_continue_equals_uninterrupted_early_in_a_hoard() -> String:
	for sd in [84, 7]:
		var r := _continue_equal(sd, false)
		if r != "ok":
			return r
	return "ok"


func test_continue_equals_uninterrupted_in_the_middle_of_a_hoard() -> String:
	for sd in [84, 7]:
		var r := _continue_equal(sd, true)
		if r != "ok":
			return r
	return "ok"
