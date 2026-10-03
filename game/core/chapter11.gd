class_name Chapter11
extends RefCounted
## Chapter 11 bankruptcy: insolvency assessment and filing (#10, PR 1).
##
## Pure core logic, no UI. All money is integer CR (matches the ledger).
## Every number below is a named constant so it can be tuned.
##
## Defaults chosen in the #10 spec (Ryan may overrule any of them):
##  - AUTO_FILE: filing is automatic at insolvency (via a SimClock interrupt).
##  - The doomsday clock is NOT reset: ticks_remaining and stage survive a
##    filing. Only the debt buckets are wiped.
##  - FRESH_START_CR: a single starting stake of 5,000 CR.
##  - LIQUIDATION_HAIRCUT_BPS: cargo and hulls count at 50% in liquidation.
##
## Snapshot shape (Dictionary):
##   cr: int                      liquid credits
##   cargo: Dictionary            commodity -> qty
##   ships: Array                 each a Dictionary with hull_value_cr: int
##   doomsday: DoomsdayClock | Dictionary
##                                a clock, or a dict carrying principal_debt,
##                                accrued_interest and accrued_burn

const LIQUIDATION_HAIRCUT_BPS: int = 5000
const FRESH_START_CR: int = 5000
const AUTO_FILE: bool = true

## Placeholder starter hull; the real hull catalogue arrives with the ship PRs.
const STARTER_SHIP: Dictionary = {"id": "starter_hull", "hull_value_cr": 0}

## Decide whether the run is insolvent. Debt equal to liquidation value is
## solvent; insolvent only when total_debt > liquidation_value.
static func assess(snapshot: Dictionary) -> Dictionary:
	var cr: int = maxi(0, int(snapshot.get("cr", 0)))
	var cargo_value := 0
	var cargo_lines := {}
	var cargo = snapshot.get("cargo", {})
	if cargo is Dictionary:
		for commodity in cargo:
			var line: int = Piracy.cargo_value(str(commodity), int(cargo[commodity])) * LIQUIDATION_HAIRCUT_BPS / 10000
			cargo_lines[str(commodity)] = line
			cargo_value += line
	var ship_value := 0
	var ships = snapshot.get("ships", [])
	if ships is Array:
		for ship in ships:
			if ship is Dictionary:
				ship_value += maxi(0, int(ship.get("hull_value_cr", 0))) * LIQUIDATION_HAIRCUT_BPS / 10000
	var debt := _debt_fields(snapshot.get("doomsday"))
	var total_debt: int = debt["principal"] + debt["accrued_interest"] + debt["accrued_burn"]
	var liquidation_value: int = cr + cargo_value + ship_value
	return {
		"insolvent": total_debt > liquidation_value,
		"total_debt": total_debt,
		"liquidation_value": liquidation_value,
		"shortfall": maxi(0, total_debt - liquidation_value),
		"breakdown": {
			"cr": cr,
			"cargo": cargo_value,
			"cargo_lines": cargo_lines,
			"ships": ship_value,
			"principal": debt["principal"],
			"accrued_interest": debt["accrued_interest"],
			"accrued_burn": debt["accrued_burn"],
		},
	}

## Interrupt predicate for SimClock.register_interrupt_hook, e.g.
## clock.register_interrupt_hook(func(): return Chapter11.should_auto_file(snapshot_fn.call()))
static func should_auto_file(snapshot: Dictionary) -> bool:
	return AUTO_FILE and bool(assess(snapshot)["insolvent"])

## File for Chapter 11. Does not mutate the snapshot dictionary or the passed
## profile (a new profile is returned). A DoomsdayClock in the snapshot IS
## mutated: its debt buckets are cleared in place, its countdown is untouched.
static func file(snapshot: Dictionary, profile: MetaProfile, run_seed: int) -> Dictionary:
	var assessment := assess(snapshot)
	var forfeited_cargo := {}
	var cargo = snapshot.get("cargo", {})
	if cargo is Dictionary:
		forfeited_cargo = cargo.duplicate(true)
	var forfeited_ships: Array = []
	var ships = snapshot.get("ships", [])
	if ships is Array:
		forfeited_ships = ships.duplicate(true)

	var new_profile := MetaProfile.from_dict(profile.to_dict())
	var seed_basis: int = new_profile.bankruptcies_filed
	new_profile.bankruptcies_filed += 1

	var doomsday = snapshot.get("doomsday")
	var new_doomsday = null
	if doomsday is DoomsdayClock:
		doomsday.clear_debt()
		new_doomsday = doomsday
	elif doomsday is Dictionary:
		new_doomsday = doomsday.duplicate(true)
		for k in ["principal_debt", "principal", "accrued_interest", "accrued_burn"]:
			if new_doomsday.has(k):
				new_doomsday[k] = 0

	var next_seed := next_seed_for(run_seed, seed_basis)
	return {
		"new_run": {
			"cr": FRESH_START_CR,
			"cargo": {},
			"ships": [STARTER_SHIP.duplicate(true)],
			"doomsday": new_doomsday,
			"debt_cleared": true,
			"seed": next_seed,
		},
		"profile": new_profile,
		"report": {
			"forfeited": {
				"cr": maxi(0, int(snapshot.get("cr", 0))),
				"cargo": forfeited_cargo,
				"ships": forfeited_ships,
			},
			"kept": {
				"patents": new_profile.patents.duplicate(),
				"unlocks": new_profile.unlocks.duplicate(),
				"contracts": new_profile.contracts.duplicate(),
				"bankruptcies_filed": new_profile.bankruptcies_filed,
			},
			"debt_wiped": assessment["total_debt"],
			"liquidation_value": assessment["liquidation_value"],
			"next_seed": next_seed,
		},
	}

## Deterministic seed for the next run: depends only on the old seed and how many
## bankruptcies the profile had filed before this one. Non-negative 31-bit.
static func next_seed_for(run_seed: int, bankruptcies_before: int) -> int:
	return hash("ch11-%d-%d" % [run_seed, bankruptcies_before]) & 0x7FFFFFFF

static func _debt_fields(doomsday) -> Dictionary:
	var out := {"principal": 0, "accrued_interest": 0, "accrued_burn": 0}
	if doomsday is DoomsdayClock:
		out["principal"] = maxi(0, doomsday.principal_debt)
		out["accrued_interest"] = maxi(0, doomsday.accrued_interest)
		out["accrued_burn"] = maxi(0, doomsday.accrued_burn)
	elif doomsday is Dictionary:
		out["principal"] = maxi(0, int(doomsday.get("principal_debt", doomsday.get("principal", 0))))
		out["accrued_interest"] = maxi(0, int(doomsday.get("accrued_interest", 0)))
		out["accrued_burn"] = maxi(0, int(doomsday.get("accrued_burn", 0)))
	return out
