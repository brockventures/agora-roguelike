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
## Emitted once per run with the carry-over summary (collapse or bankruptcy).
signal run_ended(summary: Dictionary)
## Emitted once per run when Severance is banked into the profile (#11).
signal severance_awarded(points: int)
signal stage_changed(old_stage: int, new_stage: int)
signal round_advanced(round_num: int)

## 15 seconds per round at 1x (60 ticks per second).
const DEFAULT_TICKS_PER_ROUND: int = 900

var sim_clock: SimClock
var doomsday: DoomsdayClock
var profile: MetaProfile
var run_seed: int = 0
var cr: int = Chapter11.FRESH_START_CR
var cargo: Dictionary = {}
var ships: Array = []
var pending_bankruptcy: bool = false
var ticks_per_round: int = DEFAULT_TICKS_PER_ROUND

## Golden Parachutes modifiers (see Parachutes). Empty = no perks.
var modifiers: Dictionary = {}

## Doomsday values before modifiers, captured at first apply so re-applying is
## idempotent instead of stacking.
var _doomsday_base: Dictionary = {}

## Run-end bookkeeping for Severance (#11). All integers, all saved.
## peak_net_worth: highest (liquidation value - total debt) seen, in CR.
## filings_this_run: Chapter 11 filings since this run began (the profile's
## bankruptcies_filed is lifetime). severance_banked is the once-only guard.
var peak_net_worth: int = 0
var filings_this_run: int = 0
var severance_banked: bool = false
var severance_award: int = 0
## Why the run ended ("collapse", "bankruptcy", "manual") and what carries over;
## both empty until end_run(). See carry_over_summary().
var end_reason: String = ""
var carry_over: Dictionary = {}
## Seed for the next corp, set when the run ends.
var next_seed: int = 0

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
	if mods.is_empty() and not profile.unlocks.is_empty():
		mods = Parachutes.load().modifiers(profile)
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
	doomsday.base_burn_per_second = maxi(0, Parachutes.apply_stat(modifiers, "burn_rate", int(_doomsday_base["burn"])))

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

## Net worth in CR: liquidation value minus total debt. May be negative.
func net_worth() -> int:
	var a := assess()
	return int(a["liquidation_value"]) - int(a["total_debt"])

func _track_peak(a: Dictionary) -> void:
	var nw: int = int(a["liquidation_value"]) - int(a["total_debt"])
	if nw > peak_net_worth:
		peak_net_worth = nw

func is_run_over() -> bool:
	return severance_banked

## Fresh-start CR for the next corp: the Chapter 11 stake through fresh_start_cr perks.
func fresh_start_cr() -> int:
	return maxi(0, Parachutes.apply_stat(modifiers, "fresh_start_cr", Chapter11.FRESH_START_CR))

## End the run: bank Severance into the profile exactly once and build the
## carry-over summary. Idempotent; later calls return 0 and change nothing.
## Terminal paths: doomsday collapse and Chapter 11 filing (both call this);
## callers with another (e.g. quit-to-menu) may call it directly. Read the
## result from rc.profile, which file_bankruptcy() replaces with a fresh copy.
## `lost` overrides the forfeited-assets snapshot (file_bankruptcy captures it
## before the debt is wiped).
func end_run(reason: String = "manual", lost: Dictionary = {}) -> int:
	if severance_banked:
		return 0
	_track_peak(assess())
	if lost.is_empty():
		lost = _lost_snapshot()
	severance_banked = true
	end_reason = reason
	profile.runs_completed += 1
	severance_award = Parachutes.award_severance(profile, filings_this_run, peak_net_worth)
	# Matches Chapter11.file's basis: bankruptcies before this filing.
	next_seed = Chapter11.next_seed_for(run_seed, profile.bankruptcies_filed - (1 if reason == "bankruptcy" else 0))
	carry_over = _build_carry_over(lost)
	sim_clock.pause()
	severance_awarded.emit(severance_award)
	run_ended.emit(carry_over)
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

## Start the next corp's run from this (ended) run's profile: fresh seed, a
## default doomsday clock, perks derived from the profile, and the fresh-start
## CR stake in place of starting_cr.
func next_run() -> RunController:
	return RunController.next_run_for(profile, next_seed if severance_banked else Chapter11.next_seed_for(run_seed, profile.bankruptcies_filed), ticks_per_round)

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
	if pending_bankruptcy or is_collapsed() or severance_banked:
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

## File for Chapter 11. Valid only when pending or currently insolvent;
## otherwise returns {} and changes nothing. Filing is terminal: it ENDS the run
## (Severance banked, carry_over built, clock paused, advance() runs zero ticks).
## Start the next corp with next_run(). The report carries the same data the
## carry_over summary does, plus the Chapter11 forfeit lists.
func file_bankruptcy() -> Dictionary:
	if not pending_bankruptcy and not bool(assess()["insolvent"]):
		return {}
	_track_peak(assess())
	filings_this_run += 1
	var lost := _lost_snapshot()
	var result := Chapter11.file(snapshot(), profile, run_seed, haircut_bps())
	profile = result["profile"]
	pending_bankruptcy = false
	sim_clock.accumulator = 0.0
	var report: Dictionary = result["report"]
	end_run("bankruptcy", lost)
	bankruptcy_filed.emit(report)
	return report

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
	return {
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
		"filings_this_run": filings_this_run,
		"end_reason": end_reason,
		"carry_over": carry_over.duplicate(true),
		"next_seed": next_seed,
		"severance_banked": severance_banked,
		"severance_award": severance_award,
	}

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
	rc.cr = maxi(0, int(d.get("cr", Chapter11.FRESH_START_CR)))
	var cg = d.get("cargo", {})
	rc.cargo = cg.duplicate(true) if cg is Dictionary else {}
	var sh = d.get("ships", [])
	rc.ships = sh.duplicate(true) if sh is Array else []
	rc.pending_bankruptcy = bool(d.get("pending_bankruptcy", false))
	rc.modifiers = _sanitise_modifiers(d.get("modifiers", {}))
	var db = d.get("doomsday_base", {})
	if db is Dictionary and db.has("interest") and db.has("burn"):
		rc._doomsday_base = {"interest": maxi(0, int(db["interest"])), "burn": maxi(0, int(db["burn"]))}
	rc.ticks_per_round = maxi(1, int(d.get("ticks_per_round", DEFAULT_TICKS_PER_ROUND)))
	rc.peak_net_worth = maxi(0, int(d.get("peak_net_worth", 0)))
	rc.filings_this_run = maxi(0, int(d.get("filings_this_run", 0)))
	rc.severance_banked = bool(d.get("severance_banked", false))
	rc.severance_award = maxi(0, int(d.get("severance_award", 0)))
	rc.end_reason = str(d.get("end_reason", ""))
	var co = d.get("carry_over", {})
	rc.carry_over = co.duplicate(true) if co is Dictionary else {}
	rc.next_seed = int(d.get("next_seed", 0))
	rc._wire()
	return rc

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
			out[stat] = {"add": int(a), "mul_bps": maxi(0, int(b))}
	return out

func _on_sub_ticked(total: int) -> void:
	doomsday.step_ticks(1)
	if ticks_per_round > 0 and total > 0 and (total % ticks_per_round) == 0:
		round_advanced.emit(int(total / ticks_per_round))

func _interrupt_check() -> bool:
	var trip := doomsday.should_auto_pause()
	if not pending_bankruptcy:
		var a := assess()
		_track_peak(a)
		if Chapter11.AUTO_FILE and bool(a["insolvent"]):
			pending_bankruptcy = true
			bankruptcy_pending.emit(a)
			trip = true
	return trip

func _on_stage_changed(old_stage: int, new_stage: int) -> void:
	stage_changed.emit(old_stage, new_stage)

func _on_collapsed() -> void:
	end_run("collapse")
	run_collapsed.emit()
