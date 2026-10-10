class_name RunController
extends RefCounted
## Run state container: wires SimClock, DoomsdayClock and Chapter 11 (#10, PR 2).
##
## State layer only, no UI. A UI binds to the signals below and drives advance().
## All money is integer CR.
##
## Design notes:
##  - The doomsday clock is stepped exactly one tick per SimClock sub-tick, from
##    the sub_ticked signal, which SimClock emits BEFORE it evaluates interrupt
##    hooks. So when a hook trips and aborts the sub-tick loop, the doomsday
##    clock has been stepped through that tick and not one tick further. This is
##    identical to per-tick DoomsdayClock.step_ticks(1).
##  - One interrupt hook is registered (not two) and it evaluates both checks
##    every sub-tick. SimClock stops at the first hook that returns true, so two
##    separate hooks would let a doomsday stage change mask a simultaneous
##    insolvency until the next sub-tick after resume.
##  - Bankruptcy is never filed mid-tick. Insolvency sets pending_bankruptcy and
##    pauses the clock; the caller then calls file_bankruptcy(). While pending,
##    or after collapse, advance() runs zero ticks.

signal bankruptcy_pending(assessment: Dictionary)
signal bankruptcy_filed(report: Dictionary)
signal run_collapsed()
## Emitted once per corp with the carry-over summary (Chapter 11 filing, or the
## final corp on collapse).
signal corp_ended(summary: Dictionary)
## Emitted once per run when Severance is banked into the profile (#11).
signal severance_awarded(points: int)
signal stage_changed(old_stage: int, new_stage: int)
signal round_advanced(round_num: int)
## A systemic margin collapse drained CR from the player this round (#12).
signal margin_call_applied(amount_cr: int)
## The player's ship left the docked station (see depart()); info is transit_info().
signal transit_departed(info: Dictionary)
## The player's ship docked at its destination; docked_at already names it.
signal transit_arrived(info: Dictionary)

## 15 seconds per round at 1x (60 ticks per second).
const DEFAULT_TICKS_PER_ROUND: int = 900
const DEFAULT_CARGO_CAPACITY: int = 100
## Sanity ceilings applied to loaded saves (D12). Far above anything reachable
## in play; they exist so a tampered file cannot carry absurd values.
const MAX_LOADED_CR: int = 1 << 40
const MAX_LOADED_CARGO_CAPACITY: int = 100000
const MAX_LOADED_MODIFIER_ADD: int = 1000000
const MAX_LOADED_MODIFIER_MUL_BPS: int = 1000000

var sim_clock: SimClock
var doomsday: DoomsdayClock
var profile: MetaProfile
var run_seed: int = 0
var cr: int = Chapter11.FRESH_START_CR
var cargo: Dictionary = {}
var ships: Array = []
var pending_bankruptcy: bool = false
var ticks_per_round: int = DEFAULT_TICKS_PER_ROUND
## The station the player is docked at; "" while in transit (no trading then).
var docked_at: String = "earth"
## The player's voyage, {} when docked: origin, destination, depart_tick,
## arrive_tick (absolute SimClock ticks), rounds and toll (CR paid on departure).
## Saved by to_dict() only while a voyage is under way, so a run that never
## travels serialises, and hashes, exactly as it did before travel existed.
var transit: Dictionary = {}
var cargo_capacity: int = DEFAULT_CARGO_CAPACITY
## Procedural crisis deck (#12). Null until a loop attaches one (M0Loop does), so
## a bare controller never draws or pauses for crises. Not part of to_dict()
## here; the deck has its own to_dict()/from_dict() for the save layer.
var crisis_deck: CrisisDeck = null
## The sector barons (Epic 3). Null until something attaches a world, so a bare
## controller has none and saves no `world` key, exactly like crisis_deck.
var world: Barons = null

# --- Travel (Epic 3 task 0, #111) ---

func is_in_transit() -> bool:
	return not transit.is_empty()

## Whether the ship could leave for `destination` now. {ok, reason, rounds, ticks, toll}:
## reason is one of RUN_OVER, IN_TRANSIT, SAME_STATION, NO_ROUTE, INSUFFICIENT_CR.
## Belt routes cost Transit.calculate_toll CR, payable up front. Fuel burn is not
## charged yet (Transit.calculate_fuel_burn has no caller in play).
func can_depart(destination: String) -> Dictionary:
	var dest: String = destination.to_lower().strip_edges()
	var out: Dictionary = {"ok": false, "reason": "", "rounds": 0, "ticks": 0, "toll": 0}
	if is_collapsed() or pending_bankruptcy:
		out["reason"] = "RUN_OVER"
	elif is_in_transit():
		out["reason"] = "IN_TRANSIT"
	elif dest == docked_at:
		out["reason"] = "SAME_STATION"
	elif not (dest in Transit.STATIONS) or Transit.get_route(docked_at, dest, get_current_round()) == null:
		out["reason"] = "NO_ROUTE"
	else:
		var rounds: int = Transit.calculate_trip_rounds(docked_at, dest, get_current_round(), 0)
		out["rounds"] = rounds
		out["ticks"] = Transit.calculate_transit_ticks(rounds, ticks_per_round)
		out["toll"] = Transit.calculate_toll(docked_at, dest)
		if cr < int(out["toll"]):
			out["reason"] = "INSUFFICIENT_CR"
		else:
			out["ok"] = true
	return out

## Leaves the docked station for `destination`. Returns can_depart()'s dictionary
## (plus origin / destination when it worked); on failure nothing changes.
func depart(destination: String) -> Dictionary:
	var check: Dictionary = can_depart(destination)
	if not bool(check["ok"]):
		return check
	var dest: String = destination.to_lower().strip_edges()
	var now: int = sim_clock.total_ticks
	cr -= int(check["toll"])
	transit = {
		"origin": docked_at,
		"destination": dest,
		"depart_tick": now,
		"arrive_tick": now + int(check["ticks"]),
		"rounds": int(check["rounds"]),
		"toll": int(check["toll"]),
	}
	docked_at = ""
	check["origin"] = str(transit["origin"])
	check["destination"] = dest
	transit_departed.emit(transit_info())
	return check

## Copy of the voyage plus live progress (0..1) and rounds left (rounded up), {} when docked.
func transit_info() -> Dictionary:
	if transit.is_empty():
		return {}
	var info: Dictionary = transit.duplicate()
	var span: int = maxi(1, int(transit["arrive_tick"]) - int(transit["depart_tick"]))
	var done: int = clampi(sim_clock.total_ticks - int(transit["depart_tick"]), 0, span)
	info["progress"] = float(done) / float(span)
	var left: int = maxi(0, int(transit["arrive_tick"]) - sim_clock.total_ticks)
	info["ticks_left"] = left
	info["eta_rounds"] = (left + ticks_per_round - 1) / ticks_per_round
	info["is_belt"] = Transit.route_key(str(transit["origin"]), str(transit["destination"])) in Transit.BELT_ROUTES
	return info

func _arrive() -> void:
	var info: Dictionary = transit_info()
	docked_at = str(transit["destination"])
	# Docking toll (Epic 3 task 3): an anchoring baron charges outsiders on
	# arrival, capped at the CR held, to SYSTEM. No world, no toll.
	var toll_due: int = 0
	var toll_paid: int = 0
	if world != null:
		toll_due = world.docking_toll_due(StationMarket.PLAYER_ID, docked_at)
		toll_paid = world.docking_toll(StationMarket.PLAYER_ID, docked_at, cr)
		cr -= toll_paid
	info["docking_toll_due"] = toll_due
	info["docking_toll"] = toll_paid
	info["toll_baron"] = world.baron_at(docked_at) if world != null else ""
	transit = {}
	info["ticks_left"] = 0
	info["eta_rounds"] = 0
	info["progress"] = 1.0
	transit_arrived.emit(info)

## Loaded voyage, or {} when it is not a believable one (unknown stations, no
## route, a span longer than any real trip, a corrupt tick pair).
static func _sanitise_transit(raw, p_ticks_per_round: int) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var o: String = str(raw.get("origin", "")).to_lower()
	var d: String = str(raw.get("destination", "")).to_lower()
	if not (o in Transit.STATIONS) or not (d in Transit.STATIONS) or o == d or not Transit.ROUTES.has(Transit.route_key(o, d)):
		return {}
	if not (raw.get("depart_tick") is int or raw.get("depart_tick") is float) or not (raw.get("arrive_tick") is int or raw.get("arrive_tick") is float):
		return {}
	var t0: int = int(raw["depart_tick"])
	var t1: int = int(raw["arrive_tick"])
	var max_span: int = 3 * p_ticks_per_round  # the longest route is 3 rounds
	if t0 < 0 or t1 <= t0 or t1 - t0 > max_span:
		return {}
	return {
		"origin": o, "destination": d, "depart_tick": t0, "arrive_tick": t1,
		"rounds": maxi(1, int(raw.get("rounds", 1))), "toll": maxi(0, int(raw.get("toll", 0))),
	}

func get_total_cargo() -> int:
	var total: int = 0
	for q in cargo.values():
		total += maxi(0, int(q))
	return total

func get_remaining_cargo_capacity() -> int:
	return maxi(0, cargo_capacity - get_total_cargo())

## Golden Parachutes modifiers (see Parachutes). Empty = no perks.
var modifiers: Dictionary = {}

## Doomsday values before modifiers, captured at first apply so re-applying is
## idempotent instead of stacking.
var _doomsday_base: Dictionary = {}

## Run-end bookkeeping for Severance (#11). All integers, all saved.
## peak_net_worth: highest (liquidation value - total debt) seen, in CR.
## Reset for each new corp.
var peak_net_worth: int = 0
## corp_number: 1-based index of the current corp. _banked_corp is the corp whose
## Severance is already banked (once-only guard, per corp).
var corp_number: int = 1
var _banked_corp: int = 0
var severance_award: int = 0
## Why the run ended ("collapse", "bankruptcy", "manual") and what carries over;
## both empty until a corp ends. See _build_carry_over().
var end_reason: String = ""
var carry_over: Dictionary = {}
## Units traded so far this round while an audit cap was active (D5). Reset on
## every round boundary. Saved.
var audit_units_traded: int = 0
## Seed for the next corp, set when the run ends.
var next_seed: int = 0
## Consecutive sim ticks the corp has stayed insolvent while auto-filing waits
## out bankruptcy_grace_ticks(). Reset when solvent again and on filing. Saved.
var insolvent_ticks: int = 0
## True when the caller passed explicit modifiers; filing then keeps them instead
## of re-deriving from the profile. Saved.
var _modifiers_explicit: bool = false

var _hook: Callable

## p_modifiers: explicit Parachutes.modifiers() dict; when empty and the profile
## owns any unlocks, modifiers are derived from the profile's owned perks via the
## shipped tree. A profile with no unlocks yields no modifiers (identical to a run
## before Parachutes). NOTE: modifiers mutate the passed doomsday clock's
## interest and burn.
func _init(p_profile: MetaProfile = null, p_seed: int = 0, p_doomsday: DoomsdayClock = null, p_modifiers: Dictionary = {}, p_ticks_per_round: int = DEFAULT_TICKS_PER_ROUND) -> void:
	profile = p_profile if p_profile != null else MetaProfile.new()
	run_seed = p_seed
	doomsday = p_doomsday if p_doomsday != null else DoomsdayClock.new()
	ticks_per_round = maxi(1, p_ticks_per_round)
	sim_clock = SimClock.new()
	cr = Chapter11.FRESH_START_CR
	ships = [Chapter11.STARTER_SHIP.duplicate(true)]
	_wire()
	var mods: Dictionary = p_modifiers
	_modifiers_explicit = not p_modifiers.is_empty()
	if mods.is_empty():
		mods = _derive_modifiers(profile)
	if not mods.is_empty():
		apply_modifiers(mods)
		cr = Parachutes.apply_stat(modifiers, "starting_cr", Chapter11.FRESH_START_CR)
	_track_peak(assess())

## Set the active modifiers and apply the live doomsday knobs (interest_bps,
## burn_rate) from their pre-modifier base. Idempotent. Does not touch cr:
## starting_cr is applied once by _init, fresh_start_cr by file_bankruptcy().
## fuel_discount_bps, hazard_odds_bps and piracy_odds_bps are consumed by the
## transit and encounter code through the accessors below.
func apply_modifiers(mods: Dictionary) -> void:
	modifiers = mods.duplicate(true)
	if _doomsday_base.is_empty():
		_doomsday_base = {
			"interest": doomsday.interest_rate_bps_per_minute,
			"burn": doomsday.base_burn_per_second,
		}
	doomsday.interest_rate_bps_per_minute = maxi(0, Parachutes.apply_stat(modifiers, "interest_bps", int(_doomsday_base["interest"])))
	var burn_mod = modifiers.get("burn_rate")
	if burn_mod is Dictionary:
		# Keep the exact product (D9): a x0.85 perk on a 25 CR/s base is 21.25,
		# which integer truncation would turn into 21 (x0.84).
		doomsday.set_burn_scaled(int(_doomsday_base["burn"]), int(burn_mod.get("add", 0)), int(burn_mod.get("mul_bps", Parachutes.BPS)))
	else:
		doomsday.base_burn_per_second = maxi(0, int(_doomsday_base["burn"]))
		doomsday.burn_per_second_bps = -1

## Liquidation haircut in bps after modifiers.
func haircut_bps() -> int:
	return clampi(Parachutes.apply_stat(modifiers, "liquidation_haircut_bps", Chapter11.LIQUIDATION_HAIRCUT_BPS), 0, 10000)

## Engine fuel discount in bps, 0..10000. Pass to Transit.calculate_fuel_burn.
func fuel_discount_bps() -> int:
	return clampi(Parachutes.apply_stat(modifiers, "fuel_discount_bps", 0), 0, 10000)

## Hazard odds factor in bps (10000 = x1.0). Pass to Hazards.quote/roll as odds_bps.
func hazard_odds_bps() -> int:
	return maxi(0, Parachutes.apply_stat(modifiers, "hazard_odds_bps", Parachutes.BPS))

## Piracy odds factor in bps (10000 = x1.0). Pass to Piracy.chance/roll_departure as odds_bps.
func piracy_odds_bps() -> int:
	return maxi(0, Parachutes.apply_stat(modifiers, "piracy_odds_bps", Parachutes.BPS))

## Unit cap per round while an antitrust audit is active, 0 = uncapped.
func trade_cap_qty() -> int:
	return crisis_deck.order_cap() if crisis_deck != null else 0

## Units still tradable this round under an active audit cap (D5). The cap is
## cumulative over the round, so splitting an order cannot get around it.
## Returns -1 when no audit cap is active (uncapped).
func audit_units_remaining() -> int:
	var cap := trade_cap_qty()
	if cap <= 0:
		return -1
	return maxi(0, cap - audit_units_traded)

## Records a fill against the round's audit cap. No-op with no active cap.
func record_audit_trade(qty: int) -> void:
	if trade_cap_qty() > 0 and qty > 0:
		audit_units_traded += qty

## Audit trade fee in CR on a fill worth `cost` CR (0 with no audit).
func trade_fee(cost: int) -> int:
	return crisis_deck.fee_for(cost) if crisis_deck != null else 0

## Net worth in CR: liquidation value minus total debt. May be negative.
func net_worth() -> int:
	var a := assess()
	return int(a["liquidation_value"]) - int(a["total_debt"])

func _track_peak(a: Dictionary) -> void:
	var nw: int = int(a["liquidation_value"]) - int(a["total_debt"])
	if nw > peak_net_worth:
		peak_net_worth = nw

## True once the doomsday clock has collapsed: the only true end of the run.
## Chapter 11 filing is NOT a game over; it founds a new corp in place.
func is_run_over() -> bool:
	return is_collapsed()

## Fresh-start CR for the next corp: the Chapter 11 stake through fresh_start_cr perks.
## New corp stake = the fresh_start_cr stat applied to FRESH_START_CR, plus the
## starting_cr bonus (so Seed Capital funds every new corp, not just the first).
func fresh_start_cr() -> int:
	var stake := Parachutes.apply_stat(modifiers, "fresh_start_cr", Chapter11.FRESH_START_CR)
	var start_bonus := Parachutes.apply_stat(modifiers, "starting_cr", Chapter11.FRESH_START_CR) - Chapter11.FRESH_START_CR
	return maxi(0, stake + start_bonus)

## Seed schemes (D10), two on purpose, both StableHash (SHA-256) based:
##  - corp_seed(n): per-corp seed, authoritative for bankruptcy filings (the
##    value file_bankruptcy() reports and banks as next_seed).
##  - Chapter11.next_seed_for(run_seed, filings): seed for the next RUN after a
##    collapse (next_run()); it is keyed on filings so it differs per run.
## They are not unified: unifying would change which seeds existing runs and
## replays reach.
##
## Per-corp seed, derived from (run_seed, corp_number) only. Filing never touches
## run_seed or any world RNG: every corp lives in the same Sol (same doomsday
## clock, rivals, markets). Anything per-corp that needs randomness uses this.
func corp_seed(p_corp_number: int = -1) -> int:
	var n := corp_number if p_corp_number < 0 else p_corp_number
	return StableHash.hash32("corp-%d-%d" % [run_seed, n]) & 0x7FFFFFFF

## Sim ticks of continued insolvency tolerated before automatic filing
## (Deferred Audit). Base 0 = file on the first insolvent tick.
func bankruptcy_grace_ticks() -> int:
	return maxi(0, Parachutes.apply_stat(modifiers, "bankruptcy_grace_ticks", 0))

## End the current corp from outside the normal paths (e.g. quit-to-menu): bank
## Severance for it exactly once (guarded per corp) and build the summary. Idempotent
## per corp; returns the award, 0 if already banked. Collapse calls this with
## reason "collapse"; filing goes through file_bankruptcy(), not here.
func end_run(reason: String = "manual") -> int:
	if _banked_corp == corp_number:
		return 0
	_track_peak(assess())
	return _bank_corp(reason, _lost_snapshot(), 0, Chapter11.next_seed_for(run_seed, profile.bankruptcies_filed))

## Banks Severance for the corp that is ending and builds carry_over. Peak must
## already be measured (never re-measure after a debt wipe). `filings` is 1 when
## the corp ended by Chapter 11 filing.
func _bank_corp(reason: String, lost: Dictionary, filings: int, p_next_seed: int) -> int:
	_banked_corp = corp_number
	end_reason = reason
	profile.runs_completed += 1
	severance_award = Parachutes.award_severance(profile, filings, peak_net_worth)
	next_seed = p_next_seed
	carry_over = _build_carry_over(lost)
	severance_awarded.emit(severance_award)
	corp_ended.emit(carry_over)
	return severance_award

func _lost_snapshot() -> Dictionary:
	var a := assess()
	return {
		"debt": int(a["total_debt"]),
		"cargo": cargo.duplicate(true),
		"cr": cr,
		"ships": ships.duplicate(true),
	}

## What survives into the next corp and what was lost. Data only, for a UI.
func _build_carry_over(lost: Dictionary) -> Dictionary:
	return {
		"reason": end_reason,
		"corp_number": corp_number,
		"persists": {
			"unlocks": profile.unlocks.duplicate(),
			"patents": profile.patents.duplicate(),
			"contracts": profile.contracts.duplicate(),
			"severance_balance": profile.severance_points,
			"severance_awarded": severance_award,
			"runs_completed": profile.runs_completed,
			"bankruptcies_filed": profile.bankruptcies_filed,
			"fresh_start_cr": fresh_start_cr(),
			"next_seed": next_seed,
		},
		"lost": lost.duplicate(true),
	}

## Start a brand-new run (after doomsday collapse) from this run's profile:
## fresh seed, default doomsday clock, perks derived from the profile, and the
## fresh-start CR stake in place of starting_cr.
func next_run() -> RunController:
	var sd := next_seed if _banked_corp == corp_number else Chapter11.next_seed_for(run_seed, profile.bankruptcies_filed)
	return RunController.next_run_for(profile, sd, ticks_per_round)

static func next_run_for(p_profile: MetaProfile, p_seed: int, p_ticks_per_round: int = DEFAULT_TICKS_PER_ROUND) -> RunController:
	var rc := RunController.new(p_profile, p_seed, null, {}, p_ticks_per_round)
	rc.cr = rc.fresh_start_cr()
	rc.peak_net_worth = 0
	rc._track_peak(rc.assess())
	return rc

func _wire() -> void:
	_hook = Callable(self, "_interrupt_check")
	sim_clock.sub_ticked.connect(_on_sub_ticked)
	sim_clock.register_interrupt_hook(_hook)
	doomsday.stage_changed.connect(_on_stage_changed)
	doomsday.collapsed.connect(_on_collapsed)

func _unwire() -> void:
	if sim_clock.sub_ticked.is_connected(_on_sub_ticked):
		sim_clock.sub_ticked.disconnect(_on_sub_ticked)
	sim_clock.unregister_interrupt_hook(_hook)
	if doomsday.stage_changed.is_connected(_on_stage_changed):
		doomsday.stage_changed.disconnect(_on_stage_changed)
	if doomsday.collapsed.is_connected(_on_collapsed):
		doomsday.collapsed.disconnect(_on_collapsed)

## Advance by a real-time frame delta. Returns sub-ticks executed.
func advance(delta: float) -> int:
	if pending_bankruptcy or is_collapsed():
		return 0
	return sim_clock.step(delta)

func is_collapsed() -> bool:
	return doomsday.stage == DoomsdayClock.Stage.COLLAPSED

## Snapshot in the shape Chapter11 expects. cargo and ships are copies; the
## doomsday entry is the live clock.
func snapshot() -> Dictionary:
	return {
		"cr": cr,
		"cargo": cargo.duplicate(true),
		"ships": ships.duplicate(true),
		"doomsday": doomsday,
	}

func assess() -> Dictionary:
	return Chapter11.assess(snapshot(), haircut_bps())

## Re-evaluate a pending filing, e.g. after the player sold cargo. Clears
## pending if the run is solvent again. Returns the resulting pending state.
func reassess() -> bool:
	if pending_bankruptcy and not bool(assess()["insolvent"]):
		pending_bankruptcy = false
	return pending_bankruptcy

## File for Chapter 11. Valid only when pending or currently insolvent (and the
## run has not collapsed); otherwise returns {} and changes nothing. Filing is
## NOT a game over: the corp fails and a new one is founded in place on this
## controller. Debt is wiped and liquid assets forfeited (Chapter11.file), the
## fresh-start stake (with fresh_start_cr perks) and a new corp_seed() apply, perks
## are re-derived from the profile unless the caller passed explicit modifiers (the
## world seed run_seed never changes), Severance is banked once for the failed corp,
## and corp_ended(summary) fires. The Sol world and its doomsday clock keep running
## (never reset); the sim clock is left paused for the caller to resume.
func file_bankruptcy() -> Dictionary:
	if is_collapsed():
		return {}
	if not pending_bankruptcy and not bool(assess()["insolvent"]):
		return {}
	# Measure peak and loss BEFORE filing: Chapter11.file wipes the live clock's
	# debt in place, which would make the failed corp look solvent.
	_track_peak(assess())
	var lost := _lost_snapshot()
	var result := Chapter11.file(snapshot(), profile, run_seed, haircut_bps())
	var new_run: Dictionary = result["new_run"]
	profile = result["profile"]
	var report: Dictionary = result["report"]
	# Bank for the failed corp (peak already measured), using the new profile.
	_bank_corp("bankruptcy", lost, 1, corp_seed(corp_number + 1))
	# Found the new corp in place.
	corp_number += 1
	insolvent_ticks = 0
	if not _modifiers_explicit:
		apply_modifiers(_derive_modifiers(profile))
	cr = fresh_start_cr()
	cargo = (new_run["cargo"] as Dictionary).duplicate(true)
	ships = (new_run["ships"] as Array).duplicate(true)
	pending_bankruptcy = false
	sim_clock.accumulator = 0.0
	sim_clock.pause()
	peak_net_worth = 0
	_track_peak(assess())
	report["next_seed"] = corp_seed()
	# The failed corp's baron obligations end with it (Epic 3 task 4): a dead
	# corp's open contract must not fine the new one.
	if world != null:
		world.cancel_contracts()
	bankruptcy_filed.emit(report)
	return report

## Modifiers for a profile's owned perks; {} when it owns none.
static func _derive_modifiers(p: MetaProfile) -> Dictionary:
	if p.unlocks.is_empty():
		return {}
	return Parachutes.load().modifiers(p)

## Returns current simulation round derived from total_ticks and ticks_per_round.
func get_current_round() -> int:
	if ticks_per_round <= 0:
		return 0
	return int(sim_clock.total_ticks / ticks_per_round)

## Returns fractional progress [0.0, 1.0) through the current simulation round.
func get_round_progress() -> float:
	if ticks_per_round <= 0:
		return 0.0
	return float(sim_clock.total_ticks % ticks_per_round) / float(ticks_per_round)

func to_dict() -> Dictionary:
	var out: Dictionary = {
		"sim_clock": sim_clock.to_dict(),
		"doomsday": doomsday.to_dict(),
		"profile": profile.to_dict(),
		"run_seed": run_seed,
		"cr": cr,
		"cargo": cargo.duplicate(true),
		"ships": ships.duplicate(true),
		"pending_bankruptcy": pending_bankruptcy,
		"modifiers": modifiers.duplicate(true),
		"doomsday_base": _doomsday_base.duplicate(),
		"ticks_per_round": ticks_per_round,
		"peak_net_worth": peak_net_worth,
		"corp_number": corp_number,
		"end_reason": end_reason,
		"carry_over": carry_over.duplicate(true),
		"next_seed": next_seed,
		"audit_units_traded": audit_units_traded,
		"banked_corp": _banked_corp,
		"severance_award": severance_award,
		"insolvent_ticks": insolvent_ticks,
		"modifiers_explicit": _modifiers_explicit,
		"docked_at": docked_at,
		"cargo_capacity": cargo_capacity,
	}
	if not transit.is_empty():
		out["transit"] = transit.duplicate()
	return out

static func from_dict(d: Dictionary) -> RunController:
	var rc := RunController.new()
	rc._unwire()
	var sc = d.get("sim_clock", {})
	rc.sim_clock = SimClock.from_dict(sc if sc is Dictionary else {})
	var dd = d.get("doomsday", {})
	rc.doomsday = DoomsdayClock.from_dict(dd if dd is Dictionary else {})
	var pd = d.get("profile", {})
	rc.profile = MetaProfile.from_dict(pd if pd is Dictionary else {})
	rc.run_seed = int(d.get("run_seed", 0))
	rc.cr = clampi(_int_or(d.get("cr", Chapter11.FRESH_START_CR), Chapter11.FRESH_START_CR), 0, MAX_LOADED_CR)
	var sh = d.get("ships", [])
	rc.ships = sh.duplicate(true) if sh is Array else []
	rc.pending_bankruptcy = bool(d.get("pending_bankruptcy", false))
	rc._modifiers_explicit = bool(d.get("modifiers_explicit", false))
	var db = d.get("doomsday_base", {})
	if db is Dictionary and db.has("interest") and db.has("burn"):
		rc._doomsday_base = {"interest": maxi(0, int(db["interest"])), "burn": maxi(0, int(db["burn"]))}
	rc.ticks_per_round = maxi(1, int(d.get("ticks_per_round", DEFAULT_TICKS_PER_ROUND)))
	rc.peak_net_worth = maxi(0, int(d.get("peak_net_worth", 0)))
	rc.corp_number = maxi(1, int(d.get("corp_number", 1)))
	rc._banked_corp = maxi(0, int(d.get("banked_corp", 0)))
	rc.severance_award = maxi(0, int(d.get("severance_award", 0)))
	rc.end_reason = str(d.get("end_reason", ""))
	var co = d.get("carry_over", {})
	rc.carry_over = co.duplicate(true) if co is Dictionary else {}
	rc.next_seed = int(d.get("next_seed", 0))
	rc.insolvent_ticks = maxi(0, int(d.get("insolvent_ticks", 0)))
	rc.audit_units_traded = maxi(0, int(d.get("audit_units_traded", 0)))
	rc.docked_at = str(d.get("docked_at", "earth")).to_lower()
	rc.transit = _sanitise_transit(d.get("transit", {}), rc.ticks_per_round)
	if not rc.transit.is_empty():
		rc.docked_at = ""
	elif not (rc.docked_at in Transit.STATIONS):
		rc.docked_at = "earth"
	rc.cargo_capacity = clampi(_int_or(d.get("cargo_capacity", DEFAULT_CARGO_CAPACITY), DEFAULT_CARGO_CAPACITY), 1, MAX_LOADED_CARGO_CAPACITY)
	rc.cargo = _sanitise_cargo(d.get("cargo", {}), rc.cargo_capacity)
	# Perks must agree with the profile (D12): drop modifiers for unknown or
	# unowned perks by re-deriving them from the profile's unlocks. A run that
	# was started with explicit modifiers cannot be re-derived, so those are only
	# bounded to known stats and sane values.
	if rc._modifiers_explicit:
		rc.modifiers = _sanitise_modifiers(d.get("modifiers", {}))
	else:
		rc.modifiers = _derive_modifiers(rc.profile)
	if not rc._doomsday_base.is_empty():
		rc.apply_modifiers(rc.modifiers)
	rc._wire()
	return rc

static func _int_or(v, fallback: int) -> int:
	return int(v) if (v is int or v is float) else fallback

## Known commodities only, positive integer quantities, total within capacity
## (trimmed in sorted commodity order so the result is deterministic).
static func _sanitise_cargo(raw, capacity: int) -> Dictionary:
	var out := {}
	if not (raw is Dictionary):
		return out
	var keys: Array = []
	for k in raw:
		if k is String and Transit.COMMODITIES.has(k):
			keys.append(k)
	keys.sort()
	var room: int = capacity
	for k in keys:
		var q: int = _int_or(raw[k], 0)
		q = mini(maxi(0, q), room)
		if q > 0:
			out[k] = q
			room -= q
	return out

## Keeps only known stats with integer add / mul_bps; anything else is dropped.
static func _sanitise_modifiers(raw) -> Dictionary:
	var out := {}
	if not (raw is Dictionary):
		return out
	for stat in raw:
		var m = raw[stat]
		if not (stat is String) or not Parachutes.STATS.has(stat) or not (m is Dictionary):
			continue
		var a = m.get("add", 0)
		var b = m.get("mul_bps", Parachutes.BPS)
		if (a is int or a is float) and (b is int or b is float):
			out[stat] = {
				"add": clampi(int(a), -MAX_LOADED_MODIFIER_ADD, MAX_LOADED_MODIFIER_ADD),
				"mul_bps": clampi(int(b), 0, MAX_LOADED_MODIFIER_MUL_BPS),
			}
	return out

func _on_sub_ticked(total: int) -> void:
	doomsday.step_ticks(1)
	if not transit.is_empty() and total >= int(transit["arrive_tick"]):
		_arrive()
	if ticks_per_round > 0 and total > 0 and (total % ticks_per_round) == 0:
		var round_num: int = int(total / ticks_per_round)
		audit_units_traded = 0
		if crisis_deck != null:
			_advance_crisis_deck(round_num)
		round_advanced.emit(round_num)

## Once per round, before round_advanced: expire / draw crises, then charge any
## margin call owed by collapses that were already live.
func _advance_crisis_deck(round_num: int) -> void:
	crisis_deck.advance_round(round_num, int(doomsday.stage), net_worth())
	var bps: int = crisis_deck.last_margin_call_bps
	if bps > 0:
		var value: int = 0
		for c in cargo:
			value += Piracy.cargo_value(str(c), int(cargo[c]))
		var drain: int = mini(cr, value * bps / 10000)
		if drain > 0:
			cr -= drain
			margin_call_applied.emit(drain)

func _interrupt_check() -> bool:
	var trip := doomsday.should_auto_pause()
	# An unacknowledged crisis stops the clock on the sub-tick it was drawn.
	if crisis_deck != null and crisis_deck.has_pending_ack():
		trip = true
	# Likewise an unanswered baron contract offer (Epic 3 task 4).
	if world != null and world.has_pending_offer():
		trip = true
	if not pending_bankruptcy:
		var a := assess()
		_track_peak(a)
		if Chapter11.AUTO_FILE and bool(a["insolvent"]):
			# Deferred Audit: tolerate bankruptcy_grace_ticks() ticks of continued
			# insolvency before filing. Zero grace files on the first insolvent tick.
			if insolvent_ticks >= bankruptcy_grace_ticks():
				pending_bankruptcy = true
				bankruptcy_pending.emit(a)
				trip = true
			else:
				insolvent_ticks += 1
		else:
			insolvent_ticks = 0
	return trip

func _on_stage_changed(old_stage: int, new_stage: int) -> void:
	stage_changed.emit(old_stage, new_stage)

func _on_collapsed() -> void:
	if _banked_corp != corp_number:
		_track_peak(assess())
		_bank_corp("collapse", _lost_snapshot(), 0, Chapter11.next_seed_for(run_seed, profile.bankruptcies_filed))
	run_collapsed.emit()
