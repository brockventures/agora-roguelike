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
## The player holds every baron (Epic 3 phase 1 of the win, design doc 5.4). The run
## win itself, the Sol System Rescue, is #32; the loop opens it when the player continues from the monopoly summary.
signal monopoly_achieved()
## The Sol System Rescue Project was finished and the run won (#32): end_run("rescued") has banked.
signal run_rescued()
signal stage_changed(old_stage: int, new_stage: int)
signal round_advanced(round_num: int)
## #160: a policy pick was granted (count = picks now waiting), and one was adopted.
signal policy_pending(count: int)
signal policy_adopted(id: String)
## A systemic margin collapse drained CR from the player this round (#12).
signal margin_call_applied(amount_cr: int)
## The player's ship left the docked station (see depart()); info is transit_info().
signal transit_departed(info: Dictionary)
## The player's ship docked at its destination; docked_at already names it.
signal transit_arrived(info: Dictionary)

## 15 seconds per round at 1x (60 ticks per second).
const DEFAULT_TICKS_PER_ROUND: int = DoomsdayClock.TICKS_PER_ROUND
const DEFAULT_CARGO_CAPACITY: int = 100
## Sanity ceilings applied to loaded saves (D12). Far above anything reachable
## in play; they exist so a tampered file cannot carry absurd values.
const MAX_LOADED_CR: int = 1 << 40
## Worst price a fuel purchase may pay: no cap, the player pays the whole ladder it eats.
const FUEL_LIMIT_PX: float = 1000000000.0
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
## The Sol System Rescue Project (#32). Null until the monopoly opens it, so a run that never
## gets there has none and saves no `rescue` key (RunSave), exactly like `world`. It is Sol's,
## not the corp's: a Chapter 11 filing leaves it alone (Ryan, #32 Q5 a).
var rescue: RescueProject = null
## Severance a won run banked for the rescue (#32), and what a lost one banked for the phases
## it finished. Both are 0 except on the run that ended that way, saved only when non-zero.
var rescue_severance_award: int = 0
var consolation_severance_award: int = 0

# --- Travel (Epic 3 task 0, #111) ---

func is_in_transit() -> bool:
	return not transit.is_empty()

## Whether the ship could leave for `destination` now. {ok, reason, rounds, ticks, toll,
## fuel_units, fuel_hold, fuel_buy, fuel_cr, fuel_fee, fuel_bps}: reason is one of
## RUN_OVER, IN_TRANSIT, SAME_STATION, NO_ROUTE, INSUFFICIENT_CR, INSUFFICIENT_FUEL.
## Belt routes cost Transit.calculate_toll CR, payable up front.
## Fuel (#138): the trip burns Transit.calculate_fuel_burn units (corridor cut and the
## fuel_hedge discount included). FUEL in the hold goes first (fuel_hold); the rest
## (fuel_buy) is bought at the departure station's live FUEL asks in `mkt`, priced by
## sweeping the book (fuel_cr, plus the audit fee fuel_fee). The departure is refused,
## never put into debt, when CR cannot cover toll + fuel_cr + fuel_fee or the book is
## too thin. With no `mkt` (a bare controller) no fuel is charged and the fuel_* are 0.
## `lane` (#139) names a smuggle lane (Corridors) to take instead of the ordinary lane: it
## must join the docked station and `destination` or the reason is NO_ROUTE; it skips the
## belt toll and rides the same route's rounds and fuel.
func can_depart(destination: String, mkt: StationMarket = null, lane: String = "") -> Dictionary:
	var dest: String = destination.to_lower().strip_edges()
	var out: Dictionary = {
		"ok": false, "reason": "", "rounds": 0, "ticks": 0, "toll": 0, "lane": lane,
		"fuel_units": 0, "fuel_hold": 0, "fuel_buy": 0, "fuel_cr": 0, "fuel_fee": 0,
		"fuel_bps": fuel_discount_bps(),
	}
	if is_run_over() or pending_bankruptcy:
		out["reason"] = "RUN_OVER"
	elif is_in_transit():
		out["reason"] = "IN_TRANSIT"
	elif dest == docked_at:
		out["reason"] = "SAME_STATION"
	elif not (dest in Transit.STATIONS) or Transit.get_route(docked_at, dest, get_current_round()) == null:
		out["reason"] = "NO_ROUTE"
	elif lane != "" and Corridors.smuggle_lane(docked_at, dest, lane).is_empty():
		out["reason"] = "NO_ROUTE"
	else:
		var rounds: int = Transit.calculate_trip_rounds(docked_at, dest, get_current_round(), 0)
		out["rounds"] = rounds
		out["ticks"] = Transit.calculate_transit_ticks(rounds, ticks_per_round)
		out["toll"] = Transit.calculate_toll(docked_at, dest, 0.0, toll_discount_bps())
		if lane != "":
			out["toll"] = int(Corridors.smuggle_lane(docked_at, dest, lane).get("toll_cr", 0))
		if cr < int(out["toll"]):
			out["reason"] = "INSUFFICIENT_CR"
		else:
			var short_of_fuel: bool = false
			if mkt != null:
				var units: int = Transit.calculate_fuel_burn(docked_at, dest, get_current_round(), 0, false, 0.0, fuel_discount_bps())
				var from_hold: int = mini(units, maxi(0, int(cargo.get("FUEL", 0))))
				var to_buy: int = units - from_hold
				var cost: int = 0
				var supplied: bool = true
				if to_buy > 0:
					var q: Dictionary = mkt.sweep_quote(docked_at, "FUEL", "BUY", to_buy, FUEL_LIMIT_PX)
					cost = int(q["cost"])
					supplied = int(q["filled"]) >= to_buy
				var fee: int = trade_fee(cost) if cost > 0 else 0
				out["fuel_units"] = units
				out["fuel_hold"] = from_hold
				out["fuel_buy"] = to_buy
				out["fuel_cr"] = cost
				out["fuel_fee"] = fee
				short_of_fuel = not supplied or cr < int(out["toll"]) + cost + fee
			if short_of_fuel:
				out["reason"] = "INSUFFICIENT_FUEL"
			else:
				out["ok"] = true
	return out

## Leaves the docked station for `destination`. Returns can_depart()'s dictionary
## (plus origin / destination when it worked); on failure nothing changes. With `mkt`
## the fuel is paid first from the hold, then by an immediate-or-cancel buy on the
## station's FUEL book, so the purchase dents the book like any other fill.
func depart(destination: String, mkt: StationMarket = null, lane: String = "") -> Dictionary:
	var check: Dictionary = can_depart(destination, mkt, lane)
	if not bool(check["ok"]):
		return check
	var dest: String = destination.to_lower().strip_edges()
	var now: int = sim_clock.total_ticks
	var fuel_paid: int = 0
	if int(check["fuel_units"]) > 0:
		cargo["FUEL"] = int(cargo.get("FUEL", 0)) - int(check["fuel_hold"])
		if int(cargo["FUEL"]) <= 0:
			cargo.erase("FUEL")
		if int(check["fuel_buy"]) > 0:
			var fill: Dictionary = mkt.execute(docked_at, "FUEL", "BUY", int(check["fuel_buy"]), FUEL_LIMIT_PX)
			fuel_paid = int(fill["cost"])
			check["fuel_cr"] = fuel_paid
			check["fuel_fee"] = trade_fee(fuel_paid)
			cr -= fuel_paid + int(check["fuel_fee"])
	cr -= int(check["toll"])
	transit = {
		"origin": docked_at,
		"destination": dest,
		"depart_tick": now,
		"arrive_tick": now + int(check["ticks"]),
		"rounds": int(check["rounds"]),
		"toll": int(check["toll"]),
		"fuel_burned": int(check["fuel_units"]),
		"fuel_hold": int(check["fuel_hold"]),
		"fuel_bought": int(check["fuel_buy"]),
		"fuel_cr": int(check["fuel_cr"]) + int(check["fuel_fee"]),
	}
	if lane != "":
		transit["lane"] = lane  # saved only for a smuggle lane, so an ordinary voyage saves as before
	docked_at = ""
	if world != null:
		world.cancel_auctions()  # queued call-auction orders do not follow the ship
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
		var disc: int = toll_discount_bps()
		if disc > 0:
			toll_due = toll_due * (10000 - disc) / 10000
		toll_paid = mini(toll_due, maxi(0, cr))
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
	var max_span: int = (3 + Hazards.DELAY_ROUNDS[1]) * p_ticks_per_round  # the longest route, plus the worst storm delay (#139)
	if t0 < 0 or t1 <= t0 or t1 - t0 > max_span:
		return {}
	var out: Dictionary = {
		"origin": o, "destination": d, "depart_tick": t0, "arrive_tick": t1,
		"rounds": maxi(1, int(raw.get("rounds", 1))), "toll": maxi(0, int(raw.get("toll", 0))),
		"fuel_burned": maxi(0, int(raw.get("fuel_burned", 0))), "fuel_hold": maxi(0, int(raw.get("fuel_hold", 0))),
		"fuel_bought": maxi(0, int(raw.get("fuel_bought", 0))), "fuel_cr": maxi(0, int(raw.get("fuel_cr", 0))),
	}
	# Non-default keys only (#139): a smuggle lane the route really has, a storm delay of 1..3 rounds.
	var lane: String = str(raw.get("lane", ""))
	if lane != "" and not Corridors.smuggle_lane(o, d, lane).is_empty():
		out["lane"] = lane
	var delay: int = clampi(int(raw.get("delay_rounds", 0)), 0, Hazards.DELAY_ROUNDS[1])
	if delay > 0:
		out["delay_rounds"] = delay
	return out

func get_total_cargo() -> int:
	var total: int = 0
	for q in cargo.values():
		total += maxi(0, int(q))
	return total

func get_remaining_cargo_capacity() -> int:
	return maxi(0, cargo_capacity - get_total_cargo())

## The EFFECTIVE modifiers every consumer reads (see Parachutes): `perk_modifiers` stacked with
## the held run-only policies by Parachutes.combine (#160 section 5.3). Always derived, never
## assigned by hand: apply_modifiers() and _refresh_modifiers() are the only writers. With no
## policies held it equals `perk_modifiers`, byte for byte. Empty = no perks.
var modifiers: Dictionary = {}
## The permanent base: what `modifiers` was before policies (profile-derived, or the explicit
## dict the caller passed). This is what to_dict() saves under "modifiers", so a load never
## double counts a policy. tender_unlocked reads it, so a policy cannot unlock tender offers.
var perk_modifiers: Dictionary = {}
## The run-only corporate policies (#160). Null until a loop attaches one (attach_policies), so
## a bare controller grants nothing, never pauses for a pick and saves no `policies` key (RunSave
## writes it only after the first grant). A Chapter 11 filing rescinds them (section 7).
var policies: PolicyState = null

## Doomsday values before modifiers, captured at first apply so re-applying is
## idempotent instead of stacking.
var _doomsday_base: Dictionary = {}

## Run-end bookkeeping for Severance (#11). All integers, all saved.
## peak_net_worth: highest (liquidation value - total debt) seen, in CR.
## Reset for each new corp.
var peak_net_worth: int = 0
## Absolute sim tick when the current corporation started (for per-corp rounds survived).
var _corp_start_tick: int = 0
## corp_number: 1-based index of the current corp. _banked_corp is the corp whose
## Severance is already banked (once-only guard, per corp).
var corp_number: int = 1
var _banked_corp: int = 0
var severance_award: int = 0
## Barons this corp held when it was banked (Epic 3 task 9); saved only when non-zero.
var barons_broken_award: int = 0
## rounds_survived_award: rounds survived by this corp when it ended, for Severance (#97).
var rounds_survived_award: int = 0
## Transient: the monopoly signal fired for this corp (derived from holders, not saved).
var _monopoly_signalled: bool = false
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
	perk_modifiers = mods.duplicate(true)
	modifiers = _effective_modifiers()
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

## Toll discount in bps, 0..10000 (#160): scales the belt toll and the docking toll.
func toll_discount_bps() -> int:
	return clampi(Parachutes.apply_stat(modifiers, "toll_discount_bps", 0), 0, 10000)

## Hazard odds factor in bps (10000 = x1.0). Pass to Hazards.quote/roll as odds_bps.
func hazard_odds_bps() -> int:
	return maxi(0, Parachutes.apply_stat(modifiers, "hazard_odds_bps", Parachutes.BPS))

## Piracy odds factor in bps (10000 = x1.0). Pass to Piracy.chance/roll_departure as odds_bps.
func piracy_odds_bps() -> int:
	return maxi(0, Parachutes.apply_stat(modifiers, "piracy_odds_bps", Parachutes.BPS))

## Live doomsday interest rate in bps per minute after modifiers (#137).
func interest_rate_bps() -> int:
	return doomsday.interest_rate_bps_per_minute

## Borrow liquid CR against the corporation's doomsday debt principal (#137).
## Adds amount to liquid cr and adds amount to doomsday principal debt.
## Returns the actual amount borrowed.
func borrow_cr(amount: int) -> int:
	var borrow_amt := maxi(0, amount)
	if borrow_amt == 0:
		return 0
	var added := doomsday.add_principal(borrow_amt)
	cr += added
	return added

## Service doomsday debt from liquid CR (#137).
## Pays off accrued interest first, then accrued burn, then principal debt.
## Returns the actual amount of debt paid.
func service_debt(amount: int) -> int:
	var payable := clampi(amount, 0, cr)
	var paid := doomsday.service_debt(payable)
	cr -= paid
	return paid

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

## True while the player holds every baron the victory rule needs.
func has_monopoly() -> bool:
	return world != null and world.monopoly_achieved()

## Emits monopoly_achieved once per monopoly (re-armed by a Chapter 11 filing, which
## forfeits the holdings). Returns true when it fired now. Nothing is stored.
func check_monopoly() -> bool:
	if _monopoly_signalled or not has_monopoly():
		return false
	_monopoly_signalled = true
	monopoly_achieved.emit()
	return true

## True once the doomsday clock has collapsed: the only true end of the run.
## Chapter 11 filing is NOT a game over; it founds a new corp in place.
## A rescued run is over too (#32): the clock is not what ended it.
func is_run_over() -> bool:
	return is_collapsed() or is_rescued()

## True once the Sol System Rescue Project won this corp's run. It reads the banked reason, so
## it needs no field of its own, and a later filing or new corp (which rewrites end_reason or
## bumps corp_number) can never read as rescued.
func is_rescued() -> bool:
	return end_reason == "rescued" and _banked_corp == corp_number

## Opens the Rescue Project (phase 1) once the player holds the monopoly. False when one exists
## already, the monopoly is not held, or rescue.json is invalid. The loop calls this when the
## player continues from the monopoly summary (task 3).
func open_rescue() -> bool:
	if rescue != null or not has_monopoly():
		return false
	var p: RescueProject = RescueProject.open_new(get_current_round())
	if p == null:
		return false
	rescue = p
	sync_rent_bonus()
	return true

## Every book mod the world emits: the barons', then the rivals', then the open Rescue Project's
## site embargo (#32). The one place the loop and RunSave ask, so the fold order is the same in both.
func world_mods() -> Array:
	return world.market_mods(rescue) if world != null else []

## Sets Barons.rent_bonus_bps from the saved state it derives from: the project's multiplier
## while a phase is open and the player still holds every baron, x1 otherwise. A Chapter 11
## filing forfeits the holdings, so the bonus ends with them; a finished project has none.
## Call after anything that changes the project or the holdings; RunSave.restore calls it.
func sync_rent_bonus() -> void:
	if world == null:
		return
	world.rent_bonus_bps = rescue.rent_bonus_bps() if (rescue != null and has_monopoly()) else RescueProject.FULL_SPEED_BPS

## The deposit that finished the last phase calls this (task 3 wires it): pause the sim, bank
## the corp once with reason "rescued" (normal Severance plus the rescue bonus), and signal.
## Returns the Severance awarded, 0 when there is nothing to finish or the run already ended.
func finish_rescue() -> int:
	if rescue == null or not rescue.is_complete() or is_run_over():
		return 0
	sim_clock.pause()
	var award: int = end_run("rescued")
	sync_rent_bonus()
	run_rescued.emit()
	return award

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
	# Breaking a baron = holding it as the corp ends. Counted here, before a filing's
	# forfeit reverts the holdings, once per corp (the _banked_corp guard above).
	barons_broken_award = world.held_by(Takeover.PLAYER).size() if world != null else 0
	var corp_ticks: int = maxi(0, sim_clock.total_ticks - _corp_start_tick)
	rounds_survived_award = int(corp_ticks / ticks_per_round) if ticks_per_round > 0 else 0
	# The Rescue Project (#32): a win adds the rescue bonus, a collapse with phases built adds the
	# per-phase consolation. A filing or a manual end pays neither (progress is Sol's, not the corp's).
	rescue_severance_award = 0
	consolation_severance_award = 0
	if rescue != null:
		if reason == "rescued" and rescue.is_complete():
			rescue_severance_award = rescue.win_severance(int(doomsday.ticks_remaining / ticks_per_round) if ticks_per_round > 0 else 0)
			profile.rescues_completed += 1
		elif reason == "collapse":
			consolation_severance_award = rescue.consolation_severance()
	severance_award = Parachutes.award_severance(profile, filings, peak_net_worth, barons_broken_award, rounds_survived_award, rescue_severance_award, consolation_severance_award, Parachutes.apply_stat(modifiers, "severance_bps", Parachutes.BPS))
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
	var out: Dictionary = {
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
	if barons_broken_award > 0:  # absent otherwise, so a corp that broke none hashes as before
		out["persists"]["barons_broken"] = barons_broken_award
	return out

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
	if pending_bankruptcy or is_run_over():
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

## Re-apply the permanent base with the policies as they stand now (idempotent).
func _refresh_modifiers() -> void:
	apply_modifiers(perk_modifiers)

## perk_modifiers stacked with the held policies. No policies: a plain copy, so the result is
## identical to the pre-policy dictionary however odd the base is.
func _effective_modifiers() -> Dictionary:
	if policies == null or policies.picks.is_empty():
		return perk_modifiers.duplicate(true)
	return Parachutes.combine(perk_modifiers, policies.tree().modifiers_for(policies.picks))

## Attach a fresh PolicyState (idempotent). Whoever starts a run that should have policies calls
## this; the constructor never does, so goldens and bare controllers stay untouched.
func attach_policies() -> void:
	if policies == null:
		policies = PolicyState.new()

## Adopt a policy with the pending pick. The caller resumes the clock (as it does after a
## contract). False when nothing is pending or `id` is not on offer.
func adopt_policy(id: String) -> bool:
	if policies == null or not policies.pick(id):
		return false
	_refresh_modifiers()
	policy_adopted.emit(id)
	return true

## The first baron takeover (Takeover.take) grants the corp's one takeover pick.
func grant_takeover_policy() -> void:
	if policies != null and policies.on_takeover():
		policy_pending.emit(policies.pending())

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
	if is_run_over():
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
	_corp_start_tick = sim_clock.total_ticks
	insolvent_ticks = 0
	if not _modifiers_explicit:
		apply_modifiers(_derive_modifiers(profile))
	# The new corp's stake still reads the policies the failed corp held (Pre-Packaged
	# Reorganization); they are rescinded right after (#160 section 7).
	cr = fresh_start_cr()
	if policies != null:
		var held: bool = not policies.picks.is_empty()
		policies.reset_for_new_corp()
		if held:
			_refresh_modifiers()
	cargo = (new_run["cargo"] as Dictionary).duplicate(true)
	ships = (new_run["ships"] as Array).duplicate(true)
	pending_bankruptcy = false
	_monopoly_signalled = false
	sim_clock.accumulator = 0.0
	sim_clock.pause()
	peak_net_worth = 0
	_track_peak(assess())
	report["next_seed"] = corp_seed()
	# The failed corp's baron obligations end with it (Epic 3 task 4): a dead
	# corp's open contract must not fine the new one.
	if world != null:
		world.cancel_contracts()
		world.cancel_auctions()  # so are its queued call-auction orders
		Levers.cancel_all(world)  # and its corners and open credit lines
		world.forget_corp(self)  # and the barons' grudges, bounties and live retaliations (task 11)
		# Takeover core (task 7): the failed corp's holdings revert to NPC control.
		report["forfeited_barons"] = world.forfeit_holdings()
	# The Rescue Project keeps its progress (Q5 a) but its rent bonus ended with the holdings.
	sync_rent_bonus()
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
		"modifiers": perk_modifiers.duplicate(true),
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
	if _corp_start_tick > 0:
		out["corp_start_tick"] = _corp_start_tick
	if not transit.is_empty():
		out["transit"] = transit.duplicate()
	if barons_broken_award > 0:
		out["barons_broken_award"] = barons_broken_award
	if rounds_survived_award > 0:
		out["rounds_survived_award"] = rounds_survived_award
	if rescue_severance_award > 0:
		out["rescue_severance_award"] = rescue_severance_award
	if consolation_severance_award > 0:
		out["consolation_severance_award"] = consolation_severance_award
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
	rc.barons_broken_award = maxi(0, int(d.get("barons_broken_award", 0)))
	rc.rounds_survived_award = maxi(0, int(d.get("rounds_survived_award", 0)))
	rc.rescue_severance_award = maxi(0, int(d.get("rescue_severance_award", 0)))
	rc.consolation_severance_award = maxi(0, int(d.get("consolation_severance_award", 0)))
	rc._corp_start_tick = maxi(0, int(d.get("corp_start_tick", 0)))
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
		rc.perk_modifiers = _sanitise_modifiers(d.get("modifiers", {}))
	else:
		rc.perk_modifiers = _derive_modifiers(rc.profile)
	rc.modifiers = rc._effective_modifiers()
	if not rc._doomsday_base.is_empty():
		rc._refresh_modifiers()
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
	# The Stabiliser Field (#32 design 5.1): a finished phase lets only some ticks count against
	# the clock. No project means every tick counts, so a run without one is untouched.
	if rescue == null or rescue.counts_tick(total):
		doomsday.step_ticks(1)
	if not transit.is_empty() and total >= int(transit["arrive_tick"]):
		_arrive()
	if ticks_per_round > 0 and total > 0 and (total % ticks_per_round) == 0:
		var round_num: int = int(total / ticks_per_round)
		audit_units_traded = 0
		if policies != null and policies.on_round(round_num) > 0:
			policy_pending.emit(policies.pending())
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
		if rescue != null and rescue.is_open():
			# Ryan's rule (#32 design 8): a random margin call may not by itself tip the corp into
			# Chapter 11 (which forfeits the barons) while the project is open. Same shape as
			# Barons.penalize(.., "random"): clamp to liquidation value less debt.
			var a: Dictionary = assess()
			drain = mini(drain, maxi(0, int(a["liquidation_value"]) - int(a["total_debt"])))
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
	# A granted policy pick stops the clock on the sub-tick it landed (#160 section 9), through
	# the same serialized auto-pause as every modal.
	if policies != null and policies.pending() > 0:
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
