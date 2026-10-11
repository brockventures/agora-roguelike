class_name Corridors
extends RefCounted
## Rated piracy and hazard corridors (#139), the system that gives the
## `black_market_corridors` perk (piracy_odds_bps x0.8) and the hazard odds factor a live
## effect. Pure functions over data/corridors.json; nothing here is saved.
##
## Every lane carries two ratings in bps (10000 = x1.0): `piracy_bps` multiplies the raid
## odds Piracy.chance already computes (belt 0.15, inner 0.04, hot station, hold value) and
## `hazard_bps` multiplies the base delay and loss odds of Hazards. An orbital alignment
## window on the lane multiplies the hazard again by `hazard.aligned_bps`. The perks ride on
## top: rc.piracy_odds_bps() and rc.hazard_odds_bps(). Lanes are listed once and apply in
## both directions ("earth:luna" is also luna to earth).
##
## A smuggle lane (data `smuggle_lanes`) is a second way between two stations, picked as
## its own entry in the LT/RT station list. It runs the belt route's rounds and fuel, skips
## the belt toll (`toll_cr`, 0) and carries its own, higher ratings. Its raid odds start from
## the belt base because it still crosses the belt.
##
## Rolls happen once per departure, in Barons.react_to_departure, each from a source seeded
## by (run seed, round) alone, so they are a pure function of the run and replay exactly:
##   raid:   hash32("rival-raid-<run_seed>-<round>")      (the bounty raid's stream, #134)
##   hazard: hash32("corridor-hazard-<run_seed>-<round>")
## The lethal guard (Barons.lethal_headroom) bounds what either may take from the player.
## Every number is a placeholder (see the data file).

const PATH := "res://data/corridors.json"
const BPS: int = 10000

static var _data: Dictionary = {}


static func data() -> Dictionary:
	if _data.is_empty():
		var f := FileAccess.open(PATH, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				_data = parsed
	return _data


static func pair_key(a: String, b: String) -> String:
	var x: String = a.to_lower().strip_edges()
	var y: String = b.to_lower().strip_edges()
	return "%s:%s" % ([x, y] if x < y else [y, x])


static func min_hold_value() -> int:
	return int((data().get("piracy", {}) as Dictionary).get("min_hold_value", 0))


## The smuggle lane named `lane_id` if it joins origin and dest, else {}. The result is the
## data row plus its `id`.
static func smuggle_lane(origin: String, dest: String, lane_id: String) -> Dictionary:
	var lanes: Dictionary = data().get("smuggle_lanes", {})
	if lane_id == "" or not lanes.has(lane_id):
		return {}
	var row: Dictionary = lanes[lane_id]
	if pair_key(str(row["a"]), str(row["b"])) != pair_key(origin, dest):
		return {}
	var out: Dictionary = row.duplicate()
	out["id"] = lane_id
	return out


## The smuggle lane ids that leave `origin` for `dest`, sorted ([] for most pairs).
static func smuggle_lanes_between(origin: String, dest: String) -> Array:
	var out: Array = []
	var ids: Array = (data().get("smuggle_lanes", {}) as Dictionary).keys()
	ids.sort()
	for id in ids:
		if not smuggle_lane(origin, dest, str(id)).is_empty():
			out.append(str(id))
	return out


## Ratings of a lane in bps: {piracy_bps, hazard_bps, belt, smuggle, toll_free}. `belt` says
## the lane crosses the belt (raid odds start from the belt base). An unrated lane is x1.0.
static func rating(origin: String, dest: String, lane_id: String = "") -> Dictionary:
	var sm: Dictionary = smuggle_lane(origin, dest, lane_id)
	if not sm.is_empty():
		return {"piracy_bps": int(sm["piracy_bps"]), "hazard_bps": int(sm["hazard_bps"]), "belt": true, "smuggle": true, "toll_free": true}
	var row: Dictionary = (data().get("lanes", {}) as Dictionary).get(pair_key(origin, dest), {})
	return {"piracy_bps": int(row.get("piracy_bps", BPS)), "hazard_bps": int(row.get("hazard_bps", BPS)),
		"belt": Transit.route_key(origin, dest) in Transit.BELT_ROUTES, "smuggle": false, "toll_free": false}


## The hazard factor of a lane in bps for this round: its rating, cut by an open alignment window.
static func hazard_factor_bps(origin: String, dest: String, lane_id: String, round_num: int) -> int:
	var f: int = int(rating(origin, dest, lane_id)["hazard_bps"])
	var r = Transit.get_route(origin, dest, round_num)
	if r is Dictionary and bool((r as Dictionary).get("is_aligned", false)):
		f = f * int((data().get("hazard", {}) as Dictionary).get("aligned_bps", BPS)) / BPS
	return f


## The perk-adjusted odds_bps handed to Piracy.chance / roll_departure.
static func piracy_odds_bps(rc: RunController, origin: String, dest: String, lane_id: String = "") -> int:
	return rc.piracy_odds_bps() * int(rating(origin, dest, lane_id)["piracy_bps"]) / BPS


## A throwaway Piracy desk carrying the world's privateer contracts and seeded for the roll.
static func _desk(w: Barons, rc: RunController, round_num: int) -> Piracy:
	var desk := Piracy.new(true, null, null, StableHash.hash32("rival-raid-%d-%d" % [rc.run_seed, round_num]))
	if w != null:
		desk.load_privateer_contracts(w.desk().privateer_contracts())
	return desk


## The player's most valuable commodity aboard and the whole hold's value, commodities in sorted
## order, the first of equal value winning.
static func hold_value(rc: RunController) -> Dictionary:
	var keys: Array = rc.cargo.keys()
	keys.sort()
	var best: String = ""
	var best_v: int = 0
	var total: int = 0
	for c in keys:
		var v: int = Piracy.cargo_value(str(c), int(rc.cargo[c]))
		total += v
		if v > best_v:
			best_v = v
			best = str(c)
	return {"commodity": best, "value": total}


## What the route card shows for a lane, after perks and for the hold aboard now:
## {piracy_bps (the raid chance, 0..10000), delay_bps, loss_bps, hazard_bps (a storm delay or a
## hull breach, either), aligned, smuggle, toll_free, perk (true when black_market_corridors
## lowers the odds), perk_bps}.
static func quote(rc: RunController, origin: String, dest: String, lane_id: String = "") -> Dictionary:
	var round_num: int = rc.get_current_round()
	var rate: Dictionary = rating(origin, dest, lane_id)
	var hold: Dictionary = hold_value(rc)
	var w: Barons = rc.world
	var desk: Piracy = _desk(w, rc, round_num)
	var raid_min: int = min_hold_value()
	# A bounty is secret until it is traced (the sidebar shows it only then): the card prices it in
	# only once the player knows. The roll itself always stacks it.
	var contract: Dictionary = w.bounty_on_player(round_num) if w != null else {}
	var priv: bool = not contract.is_empty() and int(contract.get("traced", 0)) > 0
	if not contract.is_empty():
		raid_min = maxi(raid_min, int(Rivals.settings(w)["raid_min_value"]))
	var piracy_bps: int = 0
	if int(hold["value"]) >= raid_min and int(hold["value"]) > 0:
		var c: Dictionary = desk.chance(StationMarket.PLAYER_ID, origin, dest, bool(rate["belt"]), str(hold["commodity"]), int(rc.cargo.get(str(hold["commodity"]), 0)), false, round_num,
			int(hold["value"]), not priv, 1.0, 0, 1.0, 0, false, "", piracy_odds_bps(rc, origin, dest, lane_id))
		piracy_bps = int(roundf(float(c["odds"]) * float(BPS)))
	var hz: Hazards = _hazards(rc, round_num)
	var f: float = float(hazard_factor_bps(origin, dest, lane_id, round_num)) / float(BPS)
	var hq: Dictionary = hz.quote(f, f, 1.0, "", null, rc.hazard_odds_bps())
	var r = Transit.get_route(origin, dest, round_num)
	var delay_bps: int = int(roundf(float(hq["p_delay"]) * float(BPS)))
	var loss_bps: int = int(roundf(float(hq["p_loss"]) * float(BPS)))
	return {
		"piracy_bps": piracy_bps,
		"delay_bps": delay_bps,
		"loss_bps": loss_bps,
		"hazard_bps": BPS - (BPS - delay_bps) * (BPS - loss_bps) / BPS,
		"aligned": r is Dictionary and bool((r as Dictionary).get("is_aligned", false)),
		"smuggle": bool(rate["smuggle"]),
		"toll_free": bool(rate["toll_free"]),
		"perk": rc.piracy_odds_bps() < BPS,
		"perk_bps": rc.piracy_odds_bps(),
	}


static func _hazards(rc: RunController, round_num: int) -> Hazards:
	var d: Dictionary = data().get("hazard", {})
	var seed_v: int = StableHash.hash32("corridor-hazard-%d-%d" % [rc.run_seed, round_num])
	return Hazards.new([float(int(d.get("delay_bps", 0))) / float(BPS), float(int(d.get("loss_bps", 0))) / float(BPS)], null, null, seed_v)


## Takes `want` units from the hold, dearest commodity first (ties by id), stopping early
## when the liquidation value taken would exceed `headroom` (the lethal guard). Returns the
## units taken. Mutates rc.cargo.
static func _strip(rc: RunController, want: int, headroom: int) -> int:
	var left: int = want
	var budget: int = headroom
	var taken: int = 0
	var order: Array = rc.cargo.keys()
	order.sort_custom(func(a, b) -> bool:
		var va: int = Piracy.cargo_value(str(a), int(rc.cargo[a]))
		var vb: int = Piracy.cargo_value(str(b), int(rc.cargo[b]))
		return str(a) < str(b) if va == vb else va > vb)
	var haircut: int = rc.haircut_bps()
	for c in order:
		var have: int = int(rc.cargo[c])
		var n: int = 0
		while n < mini(left, have):
			# The exact change in this line's liquidation value (Chapter11.assess marks each line).
			var line_now: int = Piracy.cargo_value(str(c), have - n) * haircut / BPS
			var line_next: int = Piracy.cargo_value(str(c), have - n - 1) * haircut / BPS
			var cost: int = line_now - line_next
			if cost > budget:
				break
			budget -= cost
			n += 1
		if n <= 0:
			continue
		rc.cargo[c] = have - n
		if int(rc.cargo[c]) <= 0:
			rc.cargo.erase(c)
		left -= n
		taken += n
		if left <= 0:
			break
	return taken


## The departure's raid. Rolls Piracy.roll_departure on every departure with a hold worth at
## least the floor (`piracy.min_hold_value`, or the bounty raid floor `raid_min_value` while a
## privateer contract stands), on this lane's rated odds (perks included). A standing bounty
## stacks its +0.15 through the desk's contracts exactly as before (#134). The demand is
## auto-settled: pay the ransom when the player holds it and paying leaves the corp solvent,
## else surrender cargo; both are clamped by the lethal guard so a raid never pushes the
## corp into Chapter 11 on its own. Contract raid counts, traces and sponsor fines are
## written back to the world's desk. `bounty_min` is the floor while a bounty stands.
## Emits {kind: "rival_raid" (sponsored) or "corridor_raid", fleet, choice, ransom, qty_taken,
## commodity, value, station, clamped}.
static func raid(w: Barons, rc: RunController, info: Dictionary, round_num: int, bounty_min: int, events: Array) -> void:
	var origin: String = str(info.get("origin", ""))
	var dest: String = str(info.get("destination", ""))
	var lane_id: String = str(info.get("lane", ""))
	var bounty: bool = not w.bounty_on_player(round_num).is_empty()
	var floor_v: int = maxi(min_hold_value(), bounty_min) if bounty else min_hold_value()
	var hold: Dictionary = hold_value(rc)
	var value: int = int(hold["value"])
	if value <= 0 or value < floor_v:
		return
	var rate: Dictionary = rating(origin, dest, lane_id)
	var sp: RivalFleet = w.rival(str(w.bounty_on_player(round_num).get("sponsor", "")))
	var desk: Piracy = _desk(w, rc, round_num)
	var com: String = str(hold["commodity"])
	var tid: String = "raid-%d-%s-%s" % [round_num, origin, dest]
	var res = desk.roll_departure(tid, StationMarket.PLAYER_ID, origin, dest, bool(rate["belt"]), com, int(rc.cargo.get(com, 0)), false, round_num,
		"", value, rc.get_total_cargo(), 1.0, 0, 1.0, 0, false, sp.cr if sp != null else null, 1.0, "", piracy_odds_bps(rc, origin, dest, lane_id))
	w.desk().load_privateer_contracts(desk.privateer_contracts())
	if not (res is Dictionary) or not bool(res.get("raided", false)):
		return
	var demand: Dictionary = res["demand"]
	var head: int = w.lethal_headroom(rc)
	var ransom: int = int(demand["ransom"])
	var choice: String = "pay" if rc.cr >= ransom and ransom <= head else "surrender"
	# Ryan's rule (#32 design 8): a raid on a hold carrying the open Rescue phase's goods is
	# random, not the player's choice, so it settles as ransom only, never a seizure. The ransom
	# is floored at the CR held (and at the lethal headroom). A raid after the player earned
	# heat is a consequence and keeps the full loss.
	var ransom_only: bool = rc.rescue != null and rc.rescue.hold_carries_project_goods(rc) and Heat.total(w) == 0
	if ransom_only:
		choice = "pay"
		demand["ransom"] = mini(ransom, mini(rc.cr, head))
	var out: Dictionary = desk.respond(StationMarket.PLAYER_ID, tid, choice, rc.cr)
	var row: Dictionary = out.get("payload", {})
	var paid: int = int(row.get("cr_taken", 0))
	rc.cr -= paid
	var want: int = int(row.get("qty_taken", 0))
	var taken: int = _strip(rc, want, head) if want > 0 else 0
	var sponsor: String = str(demand.get("sponsor", "")) if demand.get("sponsor") != null else ""
	if sponsor != "":
		var f: RivalFleet = w.rival(sponsor)
		if f != null and int(demand.get("fine", 0)) > 0:
			f.cr = maxi(0, f.cr - int(demand["fine"]))
	var ev: Dictionary = {"kind": "rival_raid" if sponsor != "" else "corridor_raid", "fleet": sponsor, "choice": str(row.get("choice", choice)), "ransom": paid,
		"qty_taken": taken, "commodity": com, "value": value, "station": origin, "clamped": taken < want}
	if ransom_only:
		ev["ransom_only"] = true  # absent otherwise, so a raid with no project reads as before
	events.append(ev)


## The departure's hazards (a storm delay, a hull breach), on this lane's rated odds with an
## open alignment window and the hazard perk applied. Needs a voyage under way (the delay
## pushes its arrival back); with none it does nothing. The loss is clamped by the lethal guard
## and the delay is recorded on the voyage as `delay_rounds` (absent when 0, so a clear
## departure saves exactly as before). Emits {kind: "corridor_hazard", delay, lost, requested,
## commodity, origin, destination}.
static func hazard(w: Barons, rc: RunController, info: Dictionary, round_num: int, events: Array) -> void:
	if rc.transit.is_empty():
		return
	var origin: String = str(info.get("origin", ""))
	var dest: String = str(info.get("destination", ""))
	var lane_id: String = str(info.get("lane", ""))
	var hz: Hazards = _hazards(rc, round_num)
	var f: float = float(hazard_factor_bps(origin, dest, lane_id, round_num)) / float(BPS)
	var hold: Dictionary = hold_value(rc)
	var res: Dictionary = hz.roll(rc.get_total_cargo(), f, f, 1.0, StationMarket.PLAYER_ID, null, rc.hazard_odds_bps())
	var delay: int = int(res["delay"])
	var lost: int = int(res["lost"])
	if delay <= 0 and lost <= 0:
		return
	var taken: int = _strip(rc, lost, w.lethal_headroom(rc)) if lost > 0 else 0
	if delay > 0:
		rc.transit["arrive_tick"] = int(rc.transit["arrive_tick"]) + delay * rc.ticks_per_round
		rc.transit["delay_rounds"] = delay
	events.append({"kind": "corridor_hazard", "delay": delay, "lost": taken, "requested": lost, "commodity": str(hold["commodity"]),
		"origin": origin, "destination": dest, "station": origin})
