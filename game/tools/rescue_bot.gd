extends RefCounted
## The scripted Rescue Project player (#32 task 5, docs/design/rescue-project.md sections 7 and 11).
##
## Three jobs, all through the real game objects (RunController, OrbitalHUD, M0Loop, the real
## order entry in GamepadFocus, the real m0_project action), never a shortcut around a rule:
##
##   haul(seed)      the player already holds every baron; a greedy hauler builds the four
##                   phases. Its every press is logged as an `ops` list, so the run is a
##                   recording (tests/fixtures/world/rescue_goldens.json) that `replay` re-executes
##                   without the bot's logic. Used by tests/test_rescue_goldens.gd.
##   trade(seed)     a fresh 5000 CR corp trades for profit (no baron work), to measure how fast a
##                   simple policy earns capital.
##   chain(seed, cr) a staged lever chain (the design doc's section 7.1 probe, rebuilt on the
##                   real round step) to find how much capital a monopoly takes.
##
## tools/pacing_bot.gd is the command line over this. Not a class_name: callers load() it by path.

const SEEDS: Array = [84, 7]
## CR in hand when the monopoly lands in the golden run.
const GOLDEN_CR: int = 60000
## The golden plays on the sim's real 900-tick round so the doomsday clock and the Stabiliser
## Field run at their true ratio. A frame is 0.25 s (SimClock.MAX_DELTA_CLAMP), 15 ticks.
const TPR: int = 900
const FRAME_DELTA: float = 0.25
const MAX_FRAMES: int = 40000
## The doc's section 7.2 ideal route time, in rounds, that `k` is measured against.
const IDEAL_ROUNDS: int = 27
const START_STATION: String = "mars"
const HOLD: int = 100
const DEEPEST: int = 4


# --- Sessions -------------------------------------------------------------------------------

static func new_session(p_seed: int, with_rivals: bool = true) -> Replay.Session:
	var s := Replay.Session.new(p_seed, {}, FRAME_DELTA, TPR, true)
	if not with_rivals:
		s.controller.world.rivals.clear()
	s.loop.dock_at(START_STATION)
	return s


## The player owns every baron and has `cr` in hand: the state the monopoly leaves, built with the
## takeover core (not a hand edit of holders). The monopoly modal then rises at the first round
## boundary, exactly as in play, and the bot answers it.
static func give_monopoly(s: Replay.Session, cr: int) -> void:
	var rc: RunController = s.controller
	rc.cr = 1000000
	var last: Dictionary = {}
	for id in rc.world.ids():
		last = Takeover.take(rc.world, id, Takeover.PLAYER, rc)
	rc.cr = cr
	s.loop._refresh_world_mods()
	s.loop._post_baron_event(last)  # the loop raises the monopoly summary on the last takeover


# --- Op execution (shared by the live bot and the recording replay) -------------------------

class Log extends RefCounted:
	var ops: Array = []
	var recording: bool = true
	## The hauler is holding trickle FUEL as its way out of a site (see haul_next).
	var keep_fuel: bool = false
	## [round, op, reason] for every press the game refused (measurement only, never recorded).
	var refusals: Array = []

	func add(s: Replay.Session, op: Dictionary) -> void:
		if recording:
			var e: Dictionary = op.duplicate()
			e["frame"] = s.frames
			e["tick"] = s.controller.sim_clock.total_ticks
			ops.append(e)


## Runs one op against the session. Returns true when it did what it names.
static func do_op(s: Replay.Session, op: Dictionary) -> bool:
	var hud: OrbitalHUD = s.hud
	var rc: RunController = s.controller
	match str(op["op"]):
		"act":
			return s.loop.dispatch_action(str(op["action"]))
		"buy", "sell":
			var buying: bool = str(op["op"]) == "buy"
			s.loop.set_tab(M0Loop.Tab.MARKET)
			hud.set_station(rc.docked_at)
			hud.set_commodity(str(op["c"]))
			var gf: GamepadFocus = hud.gamepad_focus
			gf.set_order_side(GamepadFocus.OrderSide.BUY if buying else GamepadFocus.OrderSide.SELL)
			gf.ladder_index = _level_for(hud, buying, int(op["n"]))
			gf.set_quantity(int(op["n"]))
			return s.loop.dispatch_action(M0Loop.ACT_SUBMIT)
		"depart":
			s.loop.set_tab(M0Loop.Tab.MAP)
			hud.set_station(str(op["to"]))
			return s.loop.dispatch_action(M0Loop.ACT_SUBMIT)
		"deliver":
			return s.loop.dispatch_action(M0Loop.ACT_PROJECT)
	return false


## The shallowest ladder level whose cumulative depth covers `qty` (the limit price of the sweep),
## or the deepest level there is.
static func _level_for(hud: OrbitalHUD, buying: bool, qty: int) -> int:
	var lad: Dictionary = hud.get_sidebar_telemetry().get("order_book_ladder", {})
	var levels: Array = lad.get("asks", []) if buying else lad.get("bids", [])
	var cum: int = 0
	for i in levels.size():
		cum += int((levels[i] as Dictionary).get("quantity", (levels[i] as Dictionary).get("qty", 0)))
		if cum >= qty:
			return i
	return maxi(0, levels.size() - 1)


## One press that answers whichever modal has halted the clock. True when one was up.
static func answer_overlay(s: Replay.Session, log: Log) -> bool:
	var act: String = ""
	match s.loop.overlay_state:
		M0Loop.OVERLAY_CRISIS, M0Loop.OVERLAY_MONOPOLY, M0Loop.OVERLAY_RESCUED:
			act = M0Loop.ACT_SUBMIT
		M0Loop.OVERLAY_CONTRACT:
			act = M0Loop.ACT_CANCEL
	if act == "" and s.loop.overlay_state == M0Loop.OVERLAY_NONE and s.controller.sim_clock.paused and not s.controller.pending_bankruptcy and not s.controller.is_run_over():
		act = M0Loop.ACT_PAUSE  # the clock halted itself on a stage change: press resume
	if act == "":
		return false
	var op := {"op": "act", "action": act}
	log.add(s, op)
	do_op(s, op)
	return true


# --- The hauler -----------------------------------------------------------------------------

## The next press for a docked hauler, or {} when there is nothing more to do here this visit.
##
## A site embargoes every commodity its phase needs, FUEL included, so a ship that has delivered
## its FUEL cannot buy the departure burn at the site: it has to carry it in, or wait for the
## book's five-unit trickle. `log.keep_fuel` is the bot's "I am waiting on the trickle" flag.
static func haul_next(s: Replay.Session, log: Log) -> Dictionary:
	var rc: RunController = s.controller
	var rp: RescueProject = rc.rescue
	if rp == null or not rp.is_open() or rc.docked_at == "" or not rc.transit.is_empty():
		return {}
	var site: String = str(rp.current()["site"])
	var need: Dictionary = rp.remaining()
	var at_site: bool = rc.docked_at == site
	if at_site:
		var pv: Dictionary = rp.preview(rc, site)
		if bool(pv["ok"]):
			var only_fuel: bool = (pv["units"] as Dictionary).size() == 1 and (pv["units"] as Dictionary).has("FUEL")
			if not (only_fuel and log.keep_fuel):
				return {"op": "deliver"}
	var held_useful: bool = false
	for c in need:
		if int(rc.cargo.get(c, 0)) > 0 and not (at_site and c == "FUEL" and log.keep_fuel):
			held_useful = true
	if held_useful and not at_site:
		# Carry it to the site; one commodity a trip is the doc's route plan.
		return {"op": "depart", "to": site}
	if held_useful:
		return {}  # at the site with goods the preview refused (CR short): wait a round
	# Hold has nothing the phase wants: pick the commodity with most still needed and a source.
	var com: String = ""
	var best: int = 0
	var keys: Array = need.keys()
	keys.sort()
	for c in keys:
		if int(need[c]) > best:
			best = int(need[c])
			com = str(c)
	var src: String = _source(rc, com, site)
	if rc.docked_at != src:
		var chk: Dictionary = rc.can_depart(src, s.loop.market)
		if not bool(chk["ok"]) and str(chk["reason"]) == "INSUFFICIENT_FUEL" and at_site:
			# Stranded at the site with no burn: buy what the trickle gives and hold it.
			var held_f: int = int(rc.cargo.get("FUEL", 0))
			var missing: int = int(chk["fuel_units"]) - held_f
			var avail: int = mini(missing, _asks_here(s, "FUEL"))
			if avail > 0 and rc.get_remaining_cargo_capacity() >= avail:
				log.keep_fuel = true
				return {"op": "buy", "c": "FUEL", "n": avail}
			return {}
		return {"op": "depart", "to": src}
	var free: int = rc.get_remaining_cargo_capacity()
	var qty: int = mini(free, best)
	if com == "FUEL":
		# The trip burns FUEL out of the hold first; and a site that wants FUEL embargoes it, so
		# carry the way out too (it survives the deposit only when this trip finishes the FUEL).
		var chk2: Dictionary = rc.can_depart(site, s.loop.market)
		qty = mini(free, best + int(chk2.get("fuel_units", 0)) + _leave_burn(site))
	qty = mini(qty, _asks_here(s, com))  # the book may be thin (fleets, levers, the embargo): buy what is there
	if qty <= 0:
		return {}
	return {"op": "buy", "c": com, "n": qty}


## Units on the visible ask ladder of `com` where the ship is docked.
static func _asks_here(s: Replay.Session, com: String) -> int:
	var m: StationMarket = s.loop.market
	if m == null or not m.has_book(s.controller.docked_at, com):
		return 0
	var n: int = 0
	for lvl in m.ladder(s.controller.docked_at, com, s.hud.order_book_depth_levels)["asks"]:
		n += int((lvl as Dictionary)["quantity"])
	return n


## The cheapest burn out of `site` to any neighbour (FUEL units): what a ship must carry in.
static func _leave_burn(site: String) -> int:
	var lo: int = 1 << 30
	for st in Transit.STATIONS:
		if st != site:
			lo = mini(lo, int(Transit.ROUTES["%s:%s" % [site, st]]["fuel"]))
	return lo


## Where to buy `com` for a build at `site`: the station (never the embargoed site) that makes the
## whole leg, here -> source -> site, shortest in rounds; the cheaper base price breaks a tie.
static func _source(rc: RunController, com: String, site: String) -> String:
	var best_st: String = ""
	var best_rounds: int = 1 << 30
	var best_px: float = 0.0
	var now: int = rc.get_current_round()
	for st in Transit.STATIONS:
		if st == site:
			continue
		var r1: int = 0 if st == rc.docked_at else Transit.calculate_trip_rounds(rc.docked_at, st, now, 0)
		var r2: int = Transit.calculate_trip_rounds(st, site, now + r1, 0)
		var px: float = float(Transit.BASE_PRICES[st][com])
		if r1 + r2 < best_rounds or (r1 + r2 == best_rounds and px < best_px):
			best_st = st
			best_rounds = r1 + r2
			best_px = px
	return best_st


# --- Running ---------------------------------------------------------------------------------

## Plays the hauler from a monopoly start until the run is won (or `max_frames`). `observe`
## (optional) is called after every frame and must only look; `stop` (optional) returns true to
## halt at a frame boundary (for the save/restore split). Returns {"session", "log"}.
static func haul(p_seed: int, cr: int, observe: Callable = Callable(), stop: Callable = Callable(), with_rivals: bool = true, log: Log = null, idle: int = 0, start_round: int = 0) -> Dictionary:
	var s: Replay.Session = new_session(p_seed, with_rivals)
	if start_round > 0:
		# The monopoly lands late: both clocks are `start_round` rounds in (the world's state is
		# the day-one world, which is what the doc's section 7.2 table assumes too).
		s.controller.sim_clock.total_ticks = start_round * TPR
		s.controller.doomsday.step_ticks(start_round * TPR)
	give_monopoly(s, cr)
	var clock_start: int = s.controller.doomsday.ticks_remaining
	if log == null:
		log = Log.new()
	var last_key: String = ""
	var arrived_at: String = ""
	var ready_round: int = 0
	while s.frames < MAX_FRAMES and not s.controller.is_run_over():
		if not answer_overlay(s, log) and s.loop.overlay_state == M0Loop.OVERLAY_NONE:
			var rc: RunController = s.controller
			if rc.docked_at != "" and rc.transit.is_empty() and not rc.pending_bankruptcy:
				var key: String = "%s@%d" % [rc.docked_at, rc.get_current_round()]
				if key != last_key:
					last_key = key
					# `idle` is a slower player: wait that many rounds after each arrival.
					if rc.docked_at != arrived_at:
						arrived_at = rc.docked_at
						ready_round = rc.get_current_round() + idle
					if rc.get_current_round() >= ready_round:
						_visit(s, log)
						if rc.docked_at == "":
							arrived_at = ""
		s.advance()
		if observe.is_valid():
			observe.call(s)
		if stop.is_valid() and bool(stop.call(s)):
			break
	# The win leaves the RESCUED modal up; answer it so the run reaches the summary.
	while s.loop.overlay_state == M0Loop.OVERLAY_RESCUED or s.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
		answer_overlay(s, log)
	return {"session": s, "log": log, "clock_start": clock_start}


## One dock visit: press until the bot departs or has nothing more to do.
static func _visit(s: Replay.Session, log: Log) -> void:
	for i in 8:
		var op: Dictionary = haul_next(s, log)
		if op.is_empty():
			return
		var ok: bool = do_op(s, op)
		if ok:
			log.add(s, op)  # only presses that did something are recorded; a refusal changes nothing
		else:
			log.refusals.append([s.controller.get_current_round(), s.controller.docked_at, str(op), s.hud.get_order_book_ladder().get("asks", []), s.hud.gamepad_focus.last_rejection_reason if str(op["op"]) in ["buy", "sell"] else s.loop.last_depart_reason if str(op["op"]) == "depart" else s.loop.last_project_reason])
		if str(op["op"]) == "depart" and ok:
			log.keep_fuel = false
			return
		if not ok:
			return  # a refusal changes nothing; try again next round


## Re-executes a recording's ops from a fresh monopoly start. `until_frame` stops the run at a
## frame boundary (for the split replay; `tail` false leaves that frame's own ops undone so a
## restored session can do them); pass a session to continue one. Returns the session.
static func replay(rec: Dictionary, s: Replay.Session = null, until_frame: int = -1, tail: bool = true) -> Replay.Session:
	if s == null:
		s = new_session(int(rec["seed"]), bool(rec.get("rivals", true)))
		give_monopoly(s, int(rec["cr"]))
	var ops: Array = rec["ops"]
	var idx: int = 0
	while idx < ops.size() and int(ops[idx]["frame"]) < s.frames:
		idx += 1
	var end_frame: int = int(rec["frames"]) if until_frame < 0 else until_frame
	while s.frames < end_frame:
		while idx < ops.size() and int(ops[idx]["frame"]) == s.frames:
			do_op(s, ops[idx])
			idx += 1
		if s.controller.is_run_over() and s.loop.overlay_state == M0Loop.OVERLAY_NONE:
			break
		s.advance()
	while tail and idx < ops.size() and int(ops[idx]["frame"]) == s.frames:
		do_op(s, ops[idx])
		idx += 1
	return s


## The recording of a finished haul: seed, start, ops, frames and the final state hash.
static func to_recording(res: Dictionary, p_seed: int, cr: int, with_rivals: bool = true) -> Dictionary:
	var s: Replay.Session = res["session"]
	var rec := {
		"seed": p_seed, "cr": cr, "frames": s.frames, "ticks_per_round": TPR,
		"final_tick": s.controller.sim_clock.total_ticks,
		"state_hash": s.state_hash(),
		"ops": (res["log"] as Log).ops.duplicate(true),
	}
	if not with_rivals:
		rec["rivals"] = false
	return rec


# --- Measurement ------------------------------------------------------------------------------

## What the finished haul says, for the pacing bot and the golden's summary: rounds from the
## project opening to each phase and the win, and the clock left.
static func haul_report(s: Replay.Session) -> Dictionary:
	var rc: RunController = s.controller
	var rp: RescueProject = rc.rescue
	var out := {
		"won": rc.is_rescued(), "round_end": rc.get_current_round(),
		"phases_done": rp.phases_done() if rp != null else 0,
		"opened_round": rp.opened_round if rp != null else -1,
		"completed": [],
		"clock_rounds_left": int(rc.doomsday.ticks_remaining / rc.ticks_per_round),
		"units": rp.units_delivered() if rp != null else 0,
		"stage": rc.doomsday.stage,
		"cr": rc.cr, "net_worth": rc.net_worth(),
	}
	if rp != null:
		out["completed"] = rp.completed.duplicate(true)
	return out


# --- The trader (trading-up time) ----------------------------------------------------------------

## A fresh 5000 CR corp with no baron work, trading the shipped world's books by a plain rule: at
## each dock sell the hold, then take the single best (commodity, destination) by estimated profit
## per round, from what the live asks cost here and the destination's base price less a 3% slip.
## Returns a trace: [{round, net_worth, cr}] once per round, plus the session.
static func trade(p_seed: int, rounds: int, with_rivals: bool = true) -> Dictionary:
	var s: Replay.Session = new_session(p_seed, with_rivals)
	s.loop.dock_at("earth")
	var log := Log.new()
	log.recording = false
	var trace: Array = []
	var last_key: String = ""
	var last_round: int = -1
	while s.frames < MAX_FRAMES and s.controller.get_current_round() < rounds and not s.controller.is_run_over() and not s.controller.pending_bankruptcy:
		var rc: RunController = s.controller
		if not answer_overlay(s, log) and s.loop.overlay_state == M0Loop.OVERLAY_NONE:
			if rc.docked_at != "" and rc.transit.is_empty() and not rc.pending_bankruptcy:
				var key: String = "%s@%d" % [rc.docked_at, rc.get_current_round()]
				if key != last_key:
					last_key = key
					_trade_visit(s)
		s.advance()
		var r: int = rc.get_current_round()
		if r != last_round:
			last_round = r
			trace.append({"round": r, "net_worth": rc.net_worth(), "cr": rc.cr, "debt": int(rc.assess()["total_debt"])})
	return {"session": s, "trace": trace}


static var visits: Array = []


static func _trade_visit(s: Replay.Session) -> void:
	var rc: RunController = s.controller
	var cr0: int = rc.cr
	var cargo0: Dictionary = rc.cargo.duplicate()
	var m: StationMarket = s.loop.market
	# Sell the hold here.
	var held: Array = rc.cargo.keys()
	held.sort()
	for c in held:
		var n: int = int(rc.cargo[c])
		if n <= 0:
			continue
		var bids: int = 0
		for lvl in m.ladder(rc.docked_at, str(c), s.hud.order_book_depth_levels)["bids"]:
			bids += int((lvl as Dictionary)["quantity"])
		n = mini(n, bids)
		if n > 0:
			do_op(s, {"op": "sell", "c": str(c), "n": n})
	var pick: Dictionary = _best_trade(s)
	visits.append([rc.get_current_round(), rc.docked_at, cr0, rc.cr, cargo0, pick])
	if pick.is_empty():
		return
	if not do_op(s, {"op": "buy", "c": pick["c"], "n": pick["n"]}):
		return
	do_op(s, {"op": "depart", "to": pick["to"]})


static func _best_trade(s: Replay.Session) -> Dictionary:
	var rc: RunController = s.controller
	var m: StationMarket = s.loop.market
	var here: String = rc.docked_at
	var now: int = rc.get_current_round()
	var best: Dictionary = {}
	var best_score: float = 0.0
	var free: int = rc.get_remaining_cargo_capacity()
	for d in Transit.STATIONS:
		if d == here or Transit.get_route(here, d, now) == null:
			continue
		var rounds: int = Transit.calculate_trip_rounds(here, d, now, 0)
		var burn: int = Transit.calculate_fuel_burn(here, d, now, 0, false, 0.0, rc.fuel_discount_bps())
		var toll: int = Transit.calculate_toll(here, d)
		var fuel_px: float = float(Transit.BASE_PRICES[here]["FUEL"])
		var overhead: float = float(toll) + float(burn) * fuel_px * 1.3
		for c in Transit.COMMODITIES:
			if c == "FUEL":
				continue  # FUEL is the ship's own burn; the bot never carries it as cargo
			var n: int = mini(free, _asks_here(s, c))
			var q: Dictionary = m.sweep_quote(here, c, "BUY", n, 1000000000.0) if n > 0 else {}
			while n > 0 and int(q["cost"]) + int(overhead) > rc.cr:
				n = int(n * 0.8)
				q = m.sweep_quote(here, c, "BUY", n, 1000000000.0) if n > 0 else {}
			if n <= 0:
				continue
			# What the destination's bids pay: the live book when the ship has seen it, else the
			# base price less a 10% slip (the cost of sweeping a hold into five levels).
			var revenue: float = float(n) * float(Transit.BASE_PRICES[d][c]) * 0.90
			if m.has_book(d, c):
				var sq: Dictionary = m.sweep_quote(d, c, "SELL", n, 0.0)
				revenue = float(sq["cost"]) if int(sq["filled"]) >= n else float(sq["cost"]) * 0.9
			var profit: float = revenue - float(q["cost"]) - overhead
			var score: float = profit / float(rounds)
			if score > best_score:
				best_score = score
				best = {"c": c, "n": n, "to": d}
	return best


# --- The monopoly chain (how much capital a takeover route takes) ------------------------------

## The design doc's section 7.1 probe on the real round step: rival fleets removed, the player
## visits Sol Central (Earth), Titan (Ceres) and Ares (Mars) in that order with `cr` in hand and
## the hold staged at 100 units of the baron's pipeline commodity (the one staged thing: the
## doc's probe did the same, since earning the stock is the trader's job). At each anchor it
## sits on the stock (a corner), dumps 50 units once for margin pressure, extends a credit line
## when the baron's treasury is thin, and bids for the distress lot when one is offered.
## Returns {taken: {baron: round}, monopoly_round, net_worth, insolvent, rounds, cr}.
static func chain(p_seed: int, cr: int, max_rounds: int = 119, assumed_debt_bps: int = -1) -> Dictionary:
	var s: Replay.Session = new_session(p_seed, false)
	var rc: RunController = s.controller
	var w: Barons = rc.world
	rc.cr = cr
	if assumed_debt_bps >= 0:
		(w.data["takeover"] as Dictionary)["player_assumed_debt_bps"] = assumed_debt_bps  # 10000 = the pre-Q1a full assumption
	var order: Array = []
	for id in ["sol_central", "titan_cryo_hydro", "ares_heavy"]:
		order.append(id)
	var log := Log.new()
	log.recording = false
	var taken: Dictionary = {}
	var arrived: Dictionary = {}
	var dumped: Dictionary = {}
	var last_key: String = ""
	var result := {"taken": taken, "monopoly_round": -1, "insolvent": false}
	while s.frames < MAX_FRAMES and rc.get_current_round() < max_rounds and not rc.is_run_over() and not rc.pending_bankruptcy:
		if not answer_overlay(s, log) and s.loop.overlay_state == M0Loop.OVERLAY_NONE:
			var r: int = rc.get_current_round()
			# The next baron not yet taken.
			var target: String = ""
			for id in order:
				if w.state(id).holder != Takeover.PLAYER:
					target = id
					break
			for id in order:
				if w.state(id).holder == Takeover.PLAYER and not taken.has(id):
					taken[id] = r
			if target == "":
				result["monopoly_round"] = r
				break
			var anchor: String = str(w.def(target).get("anchor", ""))
			if rc.docked_at != "" and rc.transit.is_empty():
				if rc.docked_at != anchor:
					var key0: String = "go@%s@%d" % [rc.docked_at, r]
					if key0 != last_key:
						last_key = key0
						s.loop.set_tab(M0Loop.Tab.MAP)
						s.hud.set_station(anchor)
						s.loop.dispatch_action(M0Loop.ACT_SUBMIT)
				else:
					if not arrived.has(target):
						arrived[target] = r
					var key: String = "%s@%d" % [target, r]
					if key != last_key:
						last_key = key
						_chain_visit(s, target, r, arrived, dumped)
		s.advance()
	for id in order:
		if w.state(id).holder == Takeover.PLAYER and not taken.has(id):
			taken[id] = rc.get_current_round()
	result["rounds"] = rc.get_current_round()
	result["cr"] = rc.cr
	result["net_worth"] = rc.net_worth()
	result["insolvent"] = bool(rc.assess()["insolvent"])
	result["debt"] = int(rc.assess()["total_debt"])
	result["held"] = w.held_by(Takeover.PLAYER).size()
	result["monopoly"] = rc.has_monopoly()
	result["pending_bankruptcy"] = rc.pending_bankruptcy
	return result


static func _chain_visit(s: Replay.Session, id: String, r: int, arrived: Dictionary, dumped: Dictionary) -> void:
	var rc: RunController = s.controller
	var w: Barons = rc.world
	var st: BaronState = w.state(id)
	var com: String = str(Levers.float_commodities(w, id)[0])
	if int(rc.cargo.get(com, 0)) < 100:
		rc.cargo[com] = 100  # staged: the stock the corner sits on
	if not dumped.has(id) and r >= int(arrived[id]) + 1:
		dumped[id] = true
		w.record_trade(rc.docked_at, com, "SELL", 50)  # margin pressure, as the lever tests drive it
	if not w.distress_at(rc.docked_at).is_empty():
		s.loop.buy_shares()
	elif st.treasury_cr < 40000 and Levers.credit(w, id).is_empty() and not Takeover.claims(w, id).has("player") and rc.cr > 20000:
		s.loop.extend_credit()
