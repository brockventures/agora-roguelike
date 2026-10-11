extends RefCounted
## #139: rated piracy and hazard corridors, the Dark Run smuggling lane, and
## black_market_corridors going live. Covers base piracy with and without the perk, the bounty
## stack, the smuggling lane skipping the belt toll, the hazard roll, the lethal guard, the
## HUD list entry, the route card, the ticker lines and determinism.

const TPR: int = 30
const BLACKWATER: String = "blackwater_lines"
const PERK: String = "black_market_corridors"


func _owned(ids: Array) -> MetaProfile:
	var p := MetaProfile.new()
	for id in ids:
		p.add_unlock(str(id))
	return p


## A run with the shipped world and its books, docked at `origin` at the start of `round_num`.
func _ctx(p_seed: int, perks: Array = [], origin: String = "mars", cr: int = 20000, round_num: int = 0) -> Dictionary:
	var rc := RunController.new(_owned(perks), p_seed, DoomsdayClock.new(36000, 0, 0, 0), {}, TPR)
	rc.world = Barons.for_new_run()
	for k in ["bounty_chance_bps", "react_chance_bps", "decide_chance_bps"]:
		rc.world.data["rivals"][k] = 0  # no fleet noise: only the corridor rolls
	rc.cr = cr
	rc.docked_at = origin
	rc.sim_clock.total_ticks = round_num * TPR
	var m := StationMarket.new()
	m.set_world(rc.world)
	return {"rc": rc, "w": rc.world, "m": m}


## Departs the way the loop does: the controller leaves (no fuel market), then the world reacts.
func _trip(c: Dictionary, dest: String, cargo: Dictionary, lane: String = "") -> Dictionary:
	var rc: RunController = c["rc"]
	rc.cargo = cargo.duplicate()
	var res: Dictionary = rc.depart(dest, null, lane)
	if not bool(res["ok"]):
		return {"res": res, "events": []}
	var events: Array = (c["w"] as Barons).react_to_departure(rc, c["m"], rc.transit_info())
	return {"res": res, "events": events}


func _kind(events: Array, kind: String) -> Array:
	return events.filter(func(e): return str(e["kind"]) == kind)


## A seed whose hot station (Piracy doubles odds at it) is not on the lane in `round_num`.
func _cool_seed(origin: String, dest: String, round_num: int = 0) -> int:
	for sd in range(1, 200):
		var hot: String = Piracy.new(true, null, null, StableHash.hash32("rival-raid-%d-%d" % [sd, round_num])).hot_station(round_num)
		if hot != origin and hot != dest:
			return sd
	return 1


## Runs `body` with the corridor data mutated, then puts the shipped data back.
func _with_data(mutate: Callable, body: Callable) -> Variant:
	var saved: Dictionary = Corridors.data().duplicate(true)
	mutate.call(Corridors.data())
	var out = body.call()
	Corridors._data = saved
	return out


# --- ratings ---

func test_every_route_is_rated_and_belt_lanes_are_riskier_than_inner_lanes() -> String:
	var lanes: Dictionary = Corridors.data()["lanes"]
	for k in lanes:
		var ends: PackedStringArray = str(k).split(":")
		if Corridors.pair_key(ends[0], ends[1]) != k:
			return "lane key %s is not in sorted order, so no lookup would ever find it" % k
	for k in Transit.ROUTES:
		var parts: PackedStringArray = str(k).split(":")
		if not lanes.has(Corridors.pair_key(parts[0], parts[1])):
			return "route %s has no rating in corridors.json" % k
	var inner_max_p: int = 0
	var inner_max_h: int = 0
	var belt_min_p: int = 1 << 30
	var belt_min_h: int = 1 << 30
	for k in lanes:
		var parts: PackedStringArray = str(k).split(":")
		var r: Dictionary = Corridors.rating(parts[0], parts[1])
		if bool(r["belt"]):
			belt_min_p = mini(belt_min_p, int(r["piracy_bps"]))
			belt_min_h = mini(belt_min_h, int(r["hazard_bps"]))
		else:
			inner_max_p = maxi(inner_max_p, int(r["piracy_bps"]))
			inner_max_h = maxi(inner_max_h, int(r["hazard_bps"]))
	if inner_max_p > belt_min_p or inner_max_h > belt_min_h:
		return "an inner lane is rated above a belt lane: piracy %d/%d hazard %d/%d" % [inner_max_p, belt_min_p, inner_max_h, belt_min_h]
	var c := _ctx(_cool_seed("earth", "luna"), [], "earth")
	var inner: Dictionary = Corridors.quote(c["rc"], "earth", "luna")
	c["rc"].cargo = {"MACHINERY": 80}
	inner = Corridors.quote(c["rc"], "earth", "luna")
	var belt: Dictionary = Corridors.quote(c["rc"], "earth", "ceres")
	if int(inner["piracy_bps"]) >= int(belt["piracy_bps"]) or int(inner["hazard_bps"]) >= int(belt["hazard_bps"]):
		return "inner %s is not safer than belt %s" % [str(inner), str(belt)]
	return "ok"


func test_an_alignment_window_halves_the_lane_hazard() -> String:
	var c := _ctx(5)
	var closed: Dictionary = Corridors.quote(c["rc"], "mars", "ceres")  # round 0: no window
	c["rc"].sim_clock.total_ticks = 5 * TPR  # mars:ceres opens at round 5 (period 10, offsets 5 and 6)
	var open: Dictionary = Corridors.quote(c["rc"], "mars", "ceres")
	if bool(closed["aligned"]) or not bool(open["aligned"]):
		return "alignment flags wrong: closed %s open %s" % [str(closed["aligned"]), str(open["aligned"])]
	if int(open["delay_bps"]) * 2 != int(closed["delay_bps"]) or int(open["loss_bps"]) * 2 != int(closed["loss_bps"]):
		return "an open window should halve hazard: %s vs %s" % [str(open), str(closed)]
	return "ok"


# --- base piracy, the perk and the bounty stack ---

func test_piracy_is_rolled_on_every_departure_without_a_bounty() -> String:
	var hits: int = 0
	for sd in range(1, 241):
		var c := _ctx(sd)
		var t: Dictionary = _trip(c, "ceres", {"MACHINERY": 80})
		var raids: Array = _kind(t["events"], "corridor_raid")
		if not _kind(t["events"], "rival_raid").is_empty():
			return "seed %d: a sponsored raid with no bounty" % sd
		if raids.is_empty():
			var breach: bool = not _kind(t["events"], "corridor_hazard").filter(func(e): return int(e["lost"]) > 0).is_empty()
			if (c["rc"].get_total_cargo() != 80 and not breach) or c["rc"].cr != 20000 - 25:
				return "seed %d: no raid but the hold or cash moved" % sd
			continue
		hits += 1
		var e: Dictionary = raids[0]
		if str(e["fleet"]) != "" or (int(e["ransom"]) <= 0 and int(e["qty_taken"]) <= 0):
			return "seed %d: a raid took nothing: %s" % [sd, str(e)]
	# About 7.5% on the belt lane, doubled at a hot station: 240 departures must show both outcomes.
	if hits < 8 or hits > 90:
		return "%d raids in 240 departures: the base roll is off" % hits
	return "ok"


func test_a_hold_under_the_floor_is_never_raided() -> String:
	for sd in range(1, 120):
		var c := _ctx(sd)
		var t: Dictionary = _trip(c, "ceres", {"FRAG": 10})  # 150 CR, under min_hold_value
		if not _kind(t["events"], "corridor_raid").is_empty():
			return "seed %d: a 150 CR hold was raided" % sd
	return "ok"


func test_black_market_corridors_cuts_the_quoted_and_rolled_odds_by_a_fifth() -> String:
	var sd: int = _cool_seed("mars", "ceres")
	var base := _ctx(sd)
	var perked := _ctx(sd, [PERK])
	base["rc"].cargo = {"MACHINERY": 80}
	perked["rc"].cargo = {"MACHINERY": 80}
	var q0: Dictionary = Corridors.quote(base["rc"], "mars", "ceres")
	var q1: Dictionary = Corridors.quote(perked["rc"], "mars", "ceres")
	# Belt base 0.15, hold-value step 0.5: 7.5%; the perk takes it to 6%.
	if int(q0["piracy_bps"]) != 750 or int(q1["piracy_bps"]) != 600:
		return "belt odds %d / %d, want 750 / 600" % [int(q0["piracy_bps"]), int(q1["piracy_bps"])]
	if bool(q0["perk"]) or not bool(q1["perk"]) or int(q1["perk_bps"]) != 8000:
		return "perk flags wrong: %s / %s" % [str(q0), str(q1)]
	if Corridors.piracy_odds_bps(perked["rc"], "mars", "ceres") != 8000 or Corridors.piracy_odds_bps(base["rc"], "mars", "ceres") != 10000:
		return "the odds_bps handed to Piracy is not the perk times the rating"
	# The same factor reaches the roll: the desk's own chance() with the same inputs.
	var desk := Piracy.new(true, null, null, StableHash.hash32("rival-raid-%d-0" % sd))
	var c0: Dictionary = desk.chance("player", "mars", "ceres", true, "MACHINERY", 80, false, 0, 1696, false, 1.0, 0, 1.0, 0, false, "", Corridors.piracy_odds_bps(perked["rc"], "mars", "ceres"))
	if absf(float(c0["exact_odds"]) - 0.06) > 1e-9:
		return "roll odds %s, want 0.06" % str(c0["exact_odds"])
	return "ok"


func test_a_standing_bounty_stacks_its_bonus_on_the_lane_odds_and_the_card_shows_it_once_traced() -> String:
	var sd: int = _cool_seed("mars", "ceres")
	var out: Array = []
	for perks in [[], [PERK]]:
		var c := _ctx(sd, perks)
		c["rc"].cargo = {"MACHINERY": 80}
		var plain: int = int(Corridors.quote(c["rc"], "mars", "ceres")["piracy_bps"])
		var w: Barons = c["w"]
		w.desk().hire(BLACKWATER, "player", 0, 20000)
		var secret: int = int(Corridors.quote(c["rc"], "mars", "ceres")["piracy_bps"])
		w.mark_bounty_traced(str(w.bounty_on_player(0)["contract_id"]))
		var traced: int = int(Corridors.quote(c["rc"], "mars", "ceres")["piracy_bps"])
		out.append([plain, secret, traced])
	# No perk: 7.5%, the secret contract is not priced in, traced it adds +15%: 22.5%. With the perk the
	# whole figure is x0.8: 6% and 18%.
	if out[0] != [750, 750, 2250] or out[1] != [600, 600, 1800]:
		return "quotes %s, want [[750, 750, 2250], [600, 600, 1800]]" % str(out)
	# The roll stacks the bonus whether or not it is traced (test_a_bounty_raid_is_one_roll...).
	return "ok"


func test_a_bounty_raid_is_one_roll_that_names_the_sponsor_and_writes_the_contract_back() -> String:
	var hits: int = 0
	for sd in range(1, 80):
		var c := _ctx(sd)
		(c["w"] as Barons).desk().hire(BLACKWATER, "player", 0, 20000)
		var t: Dictionary = _trip(c, "ceres", {"MACHINERY": 80})
		var raids: Array = _kind(t["events"], "rival_raid")
		if not _kind(t["events"], "corridor_raid").is_empty():
			return "seed %d: a bounty departure rolled two raids" % sd
		if raids.is_empty():
			continue
		hits += 1
		if str(raids[0]["fleet"]) != BLACKWATER or int((c["w"] as Barons).bounty_on_player(0)["raids"]) != 1:
			return "seed %d: the sponsored raid is wrong: %s" % [sd, str(raids[0])]
	if hits < 8:
		return "only %d sponsored raids in 79 departures" % hits
	return "ok"


# --- the smuggling lane ---

func test_the_dark_run_skips_the_belt_toll_and_rides_the_same_route() -> String:
	var c := _ctx(1)
	var belt: Dictionary = (c["rc"] as RunController).can_depart("ceres")
	var run: Dictionary = (c["rc"] as RunController).can_depart("ceres", null, "dark_run")
	if int(belt["toll"]) != 25 or int(run["toll"]) != 0 or not bool(run["ok"]):
		return "tolls %d / %d, want 25 / 0" % [int(belt["toll"]), int(run["toll"])]
	if int(run["rounds"]) != int(belt["rounds"]) or int(run["fuel_units"]) != int(belt["fuel_units"]):
		return "the lane changed the route's rounds or fuel"
	var cr0: int = (c["rc"] as RunController).cr
	var t: Dictionary = _trip(c, "ceres", {}, "dark_run")
	if not bool(t["res"]["ok"]) or (c["rc"] as RunController).cr != cr0 or str((c["rc"] as RunController).transit.get("lane", "")) != "dark_run":
		return "the Dark Run charged a toll or lost its lane: cr %d -> %d" % [cr0, (c["rc"] as RunController).cr]
	var plain := _ctx(1)
	_trip(plain, "ceres", {})
	if (plain["rc"] as RunController).cr != cr0 - 25 or (plain["rc"] as RunController).transit.has("lane"):
		return "the ordinary belt lane lost its toll or gained a lane key"
	# A lane that does not join the two stations is no route.
	if str(_ctx(1)["rc"].can_depart("earth", null, "dark_run")["reason"]) != "NO_ROUTE":
		return "dark_run accepted on a lane that is not its own"
	return "ok"


func test_the_dark_run_carries_higher_piracy_odds_and_the_perk_makes_it_worth_taking() -> String:
	var sd: int = _cool_seed("mars", "ceres")
	var rows: Array = []
	for perks in [[], [PERK]]:
		var c := _ctx(sd, perks)
		c["rc"].cargo = {"MACHINERY": 80}
		rows.append([int(Corridors.quote(c["rc"], "mars", "ceres")["piracy_bps"]), int(Corridors.quote(c["rc"], "mars", "ceres", "dark_run")["piracy_bps"])])
	# Belt 7.5%, Dark Run x1.5 = 11.25%; with the perk 6% and 9%.
	if rows != [[750, 1125], [600, 900]]:
		return "belt / dark_run odds %s" % str(rows)
	var q: Dictionary = Corridors.quote(_ctx(sd)["rc"], "mars", "ceres", "dark_run")
	if not bool(q["smuggle"]) or not bool(q["toll_free"]):
		return "the quote does not mark the lane as a toll-free smuggle run"
	return "ok"


func test_the_station_list_gets_a_dark_run_entry_only_where_the_lane_runs() -> String:
	var rc := RunController.new(null, 3)
	rc.world = Barons.for_new_run()
	var hud := OrbitalHUD.new(rc, "mars")
	rc.docked_at = "mars"
	var at_mars: Array = hud.station_entries()
	rc.docked_at = "earth"
	var at_earth: Array = hud.station_entries()
	if at_earth.size() != Transit.STATIONS.size():
		return "Earth should list the four stations only: %s" % str(at_earth)
	if at_mars.size() != Transit.STATIONS.size() + 1 or at_mars[4] != ["ceres", "dark_run"] or at_mars[3] != ["ceres", ""]:
		return "Mars entries wrong: %s" % str(at_mars)
	rc.docked_at = "mars"
	hud.set_station("ceres")
	hud.cycle_station(1)
	if hud.active_station != "ceres" or hud.active_lane != "dark_run":
		return "RT from Ceres should pick the Dark Run: %s / %s" % [hud.active_station, hud.active_lane]
	hud.cycle_station(1)
	if hud.active_station != "earth" or hud.active_lane != "":
		return "RT again should wrap to Earth on the ordinary lane: %s / %s" % [hud.active_station, hud.active_lane]
	hud.cycle_station(-1)
	if hud.active_station != "ceres" or hud.active_lane != "dark_run":
		return "LT should come back to the Dark Run"
	hud.set_station("ceres")
	if hud.active_lane != "":
		return "picking a station by name must clear the lane"
	return "ok"


# --- hazards ---

func test_hazards_roll_on_the_departure_and_a_delay_pushes_the_arrival_back() -> String:
	var delayed: int = 0
	var clear: int = 0
	for sd in range(1, 80):
		var c := _ctx(sd)
		var rc: RunController = c["rc"]
		rc.cargo = {}
		var res: Dictionary = rc.depart("ceres")
		var arrive0: int = int(rc.transit["arrive_tick"])
		var events: Array = []
		Corridors.hazard(c["w"], rc, rc.transit_info(), 0, events)
		if int(rc.transit["arrive_tick"]) == arrive0:
			clear += 1
			if rc.transit.has("delay_rounds") or not events.is_empty():
				return "seed %d: no delay but a delay record or event" % sd
			continue
		delayed += 1
		var e: Dictionary = events[0]
		var d: int = int(e["delay"])
		if str(e["kind"]) != "corridor_hazard" or d < 1 or d > 3 or int(rc.transit["arrive_tick"]) != arrive0 + d * TPR or int(rc.transit["delay_rounds"]) != d:
			return "seed %d: delay record wrong: %s %s" % [sd, str(e), str(rc.transit)]
		if int(rc.transit_info()["eta_rounds"]) != int(res["rounds"]) + d:
			return "seed %d: the ETA does not show the delay" % sd
	if delayed < 5 or clear < 20:
		return "delays %d clear %d in 79 departures" % [delayed, clear]
	return "ok"


func test_a_hull_breach_takes_cargo_and_the_hazard_perk_factor_reaches_the_roll() -> String:
	var lost_runs: int = 0
	for sd in range(1, 80):
		var c := _ctx(sd)
		var rc: RunController = c["rc"]
		rc.cargo = {"ORE": 60}
		rc.depart("ceres")
		var events: Array = []
		Corridors.hazard(c["w"], rc, rc.transit_info(), 0, events)
		var lost: int = 0 if events.is_empty() else int(events[0]["lost"])
		if lost > 0:
			lost_runs += 1
			if rc.get_total_cargo() != 60 - lost or lost < 6 or lost > 12:
				return "seed %d: breach lost %d but the hold holds %d" % [sd, lost, rc.get_total_cargo()]
		elif rc.get_total_cargo() != 60:
			return "seed %d: cargo moved with no breach" % sd
	if lost_runs < 3:
		return "only %d breaches in 79 departures" % lost_runs
	# hazard_odds_bps 0 (a perk that removes hazards): nothing ever fires.
	for sd in range(1, 60):
		var c := _ctx(sd)
		var rc: RunController = c["rc"]
		rc.apply_modifiers({"hazard_odds_bps": {"add": 0, "mul_bps": 0}})
		rc.cargo = {"ORE": 60}
		rc.depart("ceres")
		var events: Array = []
		Corridors.hazard(c["w"], rc, rc.transit_info(), 0, events)
		if not events.is_empty():
			return "seed %d: a hazard fired with the hazard factor at 0" % sd
	return "ok"


func test_a_delayed_voyage_saves_with_its_delay_and_a_clear_one_saves_as_before() -> String:
	var found: bool = false
	for sd in range(1, 80):
		var c := _ctx(sd)
		var rc: RunController = c["rc"]
		rc.depart("ceres")
		var plain: Dictionary = rc.to_dict()["transit"]
		var events: Array = []
		Corridors.hazard(c["w"], rc, rc.transit_info(), 0, events)
		var saved: Dictionary = rc.to_dict()["transit"]
		if events.is_empty():
			if saved.has("delay_rounds") or saved.has("lane") or str(saved) != str(plain):
				return "a clear departure saved extra keys: %s" % str(saved)
			continue
		if int(events[0]["delay"]) == 0:
			continue
		found = true
		var back: RunController = RunController.from_dict(JSON.parse_string(JSON.stringify(rc.to_dict())))
		if int(back.transit.get("delay_rounds", 0)) != int(events[0]["delay"]) or int(back.transit["arrive_tick"]) != int(rc.transit["arrive_tick"]):
			return "seed %d: the delay did not survive a save: %s" % [sd, str(back.transit)]
		break
	return "ok" if found else "no delayed voyage found to save"


# --- the lethal guard ---

func _forced(piracy_bps: int, hazard_delay_bps: int, hazard_loss_bps: int) -> Callable:
	return func(d: Dictionary) -> void:
		d["lanes"]["ceres:mars"]["piracy_bps"] = piracy_bps
		d["hazard"]["delay_bps"] = hazard_delay_bps
		d["hazard"]["loss_bps"] = hazard_loss_bps


## Departs holding 80 MACHINERY, then sets the debt so `headroom` CR stands between liquidation
## value and debt (the toll is the player's own spend and is already paid), and lets the world react.
func _tight_trip(sd: int, headroom: int, bounty: bool = false) -> Dictionary:
	var c := _ctx(sd, [], "mars", 1000)
	var rc: RunController = c["rc"]
	rc.cargo = {"MACHINERY": 80}
	rc.depart("ceres")
	var liq: int = int(rc.assess()["liquidation_value"])
	rc.doomsday.principal_debt = liq - headroom
	if bounty:
		(c["w"] as Barons).desk().hire(BLACKWATER, "player", 0, 20000)
	c["events"] = (c["w"] as Barons).react_to_departure(rc, c["m"], rc.transit_info())
	return c


func test_a_raid_and_a_hull_breach_can_never_push_the_corp_into_chapter_11_alone() -> String:
	var problem: Variant = _with_data(_forced(1000000, 10000, 10000), func():
		var clamped: int = 0
		for headroom in [0, 40, 120, 300]:
			for sd in range(1, 25):
				var c := _tight_trip(sd, headroom)
				var rc: RunController = c["rc"]
				var events: Array = c["events"]
				if _kind(events, "corridor_raid").is_empty():
					return "headroom %d seed %d: the forced raid did not fire: %s" % [headroom, sd, str(events)]
				if bool(rc.assess()["insolvent"]):
					return "headroom %d seed %d: the corp is insolvent after %s" % [headroom, sd, str(events)]
				for e in _kind(events, "corridor_raid"):
					if bool(e["clamped"]):
						clamped += 1
				if headroom == 0 and (rc.get_total_cargo() != 80 or rc.cr != 1000 - 25):
					return "headroom 0 seed %d: raiders took %d units, cr %d" % [sd, 80 - rc.get_total_cargo(), rc.cr]
				if int((c["w"] as Barons).lethal_headroom(rc)) > headroom:
					return "headroom grew after the hit"
		return "clamped %d" % clamped if clamped == 0 else "")
	if str(problem) != "":
		return str(problem)
	return "ok"


func test_a_raid_on_a_corp_with_room_hits_hard_because_the_lane_was_the_players_choice() -> String:
	# No debt: the guard has plenty of headroom, so the full ransom (15% of the hold) is paid.
	var problem: Variant = _with_data(_forced(1000000, 0, 0), func():
		var c := _ctx(1, [], "mars", 20000)
		var rc: RunController = c["rc"]
		var t: Dictionary = _trip(c, "ceres", {"MACHINERY": 80})
		var raids: Array = _kind(t["events"], "corridor_raid")
		if raids.is_empty() or str(raids[0]["choice"]) != "pay" or int(raids[0]["ransom"]) != 254 or bool(raids[0]["clamped"]):
			return "a raid with room should take the full 254 CR ransom: %s" % str(raids)
		if rc.cr != 20000 - 25 - 254:
			return "cash %d" % rc.cr
		# A tight corp that cannot afford the ransom surrenders cargo (the bounty raid's rule).
		var d := _ctx(2, [], "mars", 100)
		var t2: Dictionary = _trip(d, "ceres", {"MACHINERY": 80})
		var r2: Array = _kind(t2["events"], "corridor_raid")
		if r2.is_empty() or str(r2[0]["choice"]) != "surrender" or int(r2[0]["qty_taken"]) != 20 or d["rc"].get_total_cargo() != 60:
			return "a corp that cannot pay should surrender 20 units: %s" % str(r2)
		return "")
	return "ok" if str(problem) == "" else str(problem)


func test_a_standing_bounty_raid_is_under_the_same_guard() -> String:
	var problem: Variant = _with_data(_forced(1000000, 0, 0), func():
		for sd in range(1, 15):
			var c := _tight_trip(sd, 60, true)
			var rc: RunController = c["rc"]
			if _kind(c["events"], "rival_raid").is_empty() or bool(rc.assess()["insolvent"]):
				return "seed %d: bounty raid %s, insolvent %s" % [sd, str(c["events"]), str(rc.assess()["insolvent"])]
		return "")
	return "ok" if str(problem) == "" else str(problem)


# --- determinism ---

func test_the_rolls_are_a_pure_function_of_seed_round_and_inputs() -> String:
	for sd in [3, 11, 29, 47]:
		var a := _ctx(sd, [PERK])
		var b := _ctx(sd, [PERK])
		var ta: Dictionary = _trip(a, "ceres", {"MACHINERY": 80, "ORE": 30})
		var tb: Dictionary = _trip(b, "ceres", {"MACHINERY": 80, "ORE": 30})
		if str(ta["events"]) != str(tb["events"]):
			return "seed %d: two identical departures rolled differently" % sd
		if RunSave.canonical((a["rc"] as RunController).to_dict()) != RunSave.canonical((b["rc"] as RunController).to_dict()):
			return "seed %d: the controllers diverged" % sd
		if RunSave.canonical((a["w"] as Barons).to_dict()) != RunSave.canonical((b["w"] as Barons).to_dict()):
			return "seed %d: the worlds diverged" % sd
	# Another round is another draw.
	var seen: Dictionary = {}
	for r in range(0, 40):
		var c := _ctx(5, [], "mars", 20000, r)
		var t: Dictionary = _trip(c, "ceres", {"MACHINERY": 80})
		seen[str(t["events"].size()) + str((c["rc"] as RunController).get_total_cargo())] = true
	if seen.size() < 2:
		return "40 rounds all rolled the same outcome"
	return "ok"


func test_the_corridor_data_is_valid() -> String:
	var d: Dictionary = Corridors.data()
	for k in ["piracy", "hazard", "lanes", "smuggle_lanes"]:
		if not d.has(k):
			return "corridors.json lacks %s" % k
	for id in d["smuggle_lanes"]:
		var row: Dictionary = d["smuggle_lanes"][id]
		if not Transit.ROUTES.has(Transit.route_key(str(row["a"]), str(row["b"]))):
			return "smuggle lane %s joins two stations with no route" % id
		if int(row["toll_cr"]) != 0 or int(row["piracy_bps"]) <= 10000:
			return "smuggle lane %s should be toll free and riskier than a plain lane" % id
	if int(d["hazard"]["aligned_bps"]) <= 0 or int(d["hazard"]["aligned_bps"]) >= 10000:
		return "aligned_bps must cut the hazard"
	return "ok"


# --- UI: the route card and the ticker ---

func _scene(p_seed: int = 84, mode: Array = [1.0, "en"]) -> Node:
	Loc.set_locale(str(mode[1]))
	var scene = load("res://scenes/main.tscn").instantiate()
	var rc := RunController.new(null, p_seed)
	rc.world = Barons.for_new_run()
	scene.initialize_systems(rc)
	scene._resolve_child_nodes()
	scene._build_readouts()
	scene.settings.set_text_scale(float(mode[0]))
	scene.apply_text_scale()
	scene.controller.cr = 100000
	scene.loop.dock_at("mars")
	scene.controller.cargo = {"MACHINERY": 60, "ORE": 30}
	scene._refresh_readouts()
	return scene


func test_the_route_card_shows_piracy_and_hazard_percents_and_the_perk_line() -> String:
	var scene := _scene()
	scene.hud.set_station("ceres")
	scene._refresh_readouts()
	var card: Control = scene._route_card["plate"]
	var risk: String = (scene._route_card["risk"] as Label).text
	var market_off: bool = (scene._route_card["market"] as Control).visible
	var risk_before: String = risk
	scene.controller.apply_modifiers({"piracy_odds_bps": {"add": 0, "mul_bps": 8000}})
	scene._refresh_readouts()
	var risk_after: String = (scene._route_card["risk"] as Label).text
	var market_on: bool = (scene._route_card["market"] as Control).visible
	var market_text: String = (scene._route_card["market"] as Label).text
	var shown: bool = card.visible
	scene.free()
	if not shown or not risk_before.contains("PIRACY") or not risk_before.contains("HAZARD") or not risk_before.contains("%"):
		return "risk line missing: %s" % risk_before
	if risk_before == risk_after:
		return "the perk did not change the percent on the card: %s" % risk_after
	if market_off or not market_on or not market_text.contains("20%"):
		return "perk line off/on wrong: %s %s %s" % [str(market_off), str(market_on), market_text]
	return "ok"


func test_the_smuggle_lane_card_and_departure_through_the_station_list() -> String:
	var scene := _scene()
	scene.hud.set_station("ceres")
	scene.hud.cycle_station(1)
	scene._refresh_readouts()
	var body: String = scene.panel_text(scene._route_card["plate"])
	var tag: bool = (scene._route_card["belt"] as Control).visible
	var map_text: String = scene.map_label.text
	var cr0: int = scene.controller.cr
	var left: bool = scene.loop.depart_to_selected()
	var lane: String = str(scene.controller.transit.get("lane", ""))
	var toll_paid: int = int(scene.controller.transit.get("toll", -1))
	scene.free()
	if not tag or not body.contains("DARK RUN") or not body.contains("NO BELT TOLL") or body.contains("BELT TOLL 25"):
		return "smuggle card text wrong: %s" % body
	if not map_text.contains("Dark Run"):
		return "the map status does not name the lane: %s" % map_text
	if not left or lane != "dark_run" or toll_paid != 0 or cr0 - 0 < 0:
		return "the Dark Run departure failed: left %s lane %s toll %d" % [str(left), lane, toll_paid]
	return "ok"


func test_raid_and_hazard_outcomes_post_ticker_lines() -> String:
	var scene := _scene()
	var lp: M0Loop = scene.loop
	lp._post_baron_event({"kind": "corridor_raid", "fleet": "", "choice": "pay", "ransom": 254, "qty_taken": 0, "commodity": "MACHINERY", "value": 1696, "station": "mars", "clamped": false})
	lp._post_baron_event({"kind": "corridor_raid", "fleet": "", "choice": "surrender", "ransom": 0, "qty_taken": 20, "commodity": "MACHINERY", "value": 1696, "station": "mars", "clamped": false})
	lp._post_baron_event({"kind": "corridor_raid", "fleet": "", "choice": "surrender", "ransom": 0, "qty_taken": 0, "commodity": "MACHINERY", "value": 1696, "station": "mars", "clamped": true})
	lp._post_baron_event({"kind": "corridor_hazard", "delay": 2, "lost": 7, "requested": 7, "commodity": "ORE", "origin": "mars", "destination": "ceres", "station": "mars"})
	lp._post_baron_event({"kind": "corridor_hazard", "delay": 0, "lost": 0, "requested": 9, "commodity": "ORE", "origin": "mars", "destination": "ceres", "station": "mars"})
	var texts: Array = scene.hud.galnet_headlines.map(func(h): return scene.hud.headline_text(h))
	scene.free()
	var joined: String = "\n".join(PackedStringArray(texts))
	for want in ["254 CR ransom", "seize 20", "nothing left worth taking", "STORM on the", "pushed back 2", "7 units of cargo lost", "sealed in time"]:
		if not joined.contains(want):
			return "ticker lacks '%s': %s" % [want, joined]
	return "ok"
