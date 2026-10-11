# Corporate policies: a run-only tech tree

Design proposal for #160 (Corporate policies: a run-only tech tree that resets each run). It follows Ryan's answer to Question 7 in `docs/design/onboarding.md` (decided in PR #159, docs(design): first-hour onboarding and terminal tutorial): the permanent Golden Parachutes perks stay exactly as they are, and a second, run-scoped layer is added on top. Ryan, #lounge 2026-10-11: each run should feel different, "like build variety in *Hades*".

**Status: proposed, awaiting Ryan** (section 13). Every section separates what the code already does (**Grounded**, with `file:line` from `main` at `5e4a9f8`) from what this doc invents (**Proposed**). Nothing here is game code. Every number marked "placeholder" is a tuning guess for Ryan.

**Headline finding.** A policy is a perk that lives for one run. The perk machinery already does almost everything: `Parachutes.modifiers` folds effects into `{stat: {add, mul_bps}}` and `Parachutes.apply_stat` resolves them (`parachutes.gd:269,292`), and most of the ten stats it knows are already the levers Ryan listed (fuel burn, raid and hazard odds, takeover threshold, interest). So the design is **a second perk tree, `policies.json`, in the same shape, folded into the same modifiers dictionary**. Three things need care:

1. **`RunController.modifiers` is re-derived from the profile in three places** (`_init`, `file_bankruptcy`, `from_dict`: `run_controller.gd:335,684,817`). A policy added to that dictionary by hand would silently vanish at the first Chapter 11 filing or load. Section 5 makes the policies part of the derivation instead.
2. **The existing replay goldens run past round 20** (`world_golden.gd:15`, 40 rounds). A pick granted at round 20 would stop the clock and move both pins. Section 8 keeps them green by attaching policies only where the world is attached by `Main`, never by default.
3. **Three of the six levers Ryan named have no stat yet**: belt and docking tolls, the debt a taker assumes, and Severance. Each is a one-line consumer on a lever that exists (section 5.2); no new system.

## 1. What exists today (Grounded)

| Fact | Where |
|---|---|
| Perks are data: `game/data/parachutes.json`, eight perks in four branches (Regulatory Capture, Asset Laundering, Logistics & Smuggling, Monopoly Drive), tiers 1 to 3 costing 100 / 250 / 500 Severance. A perk has `requires` (AND) and `requires_any` (OR), and `effects: [{stat, op, value}]`. | `parachutes.json`, `parachutes.gd:5-12` |
| Ops are `add` and `mul_bps`, integers only. `modifiers()` folds owned perks **in sorted-id order**, so purchase order never matters: `add` sums, `mul_bps` multiplies as `a * v / 10000`. | `parachutes.gd:269-289` |
| `apply_stat(mods, stat, base)` = `(base + add) * mul_bps / 10000`, integer division; a missing stat returns the base. | `parachutes.gd:292-296` |
| Ten stats are known and live: `starting_cr`, `fresh_start_cr`, `interest_bps`, `burn_rate`, `liquidation_haircut_bps`, `fuel_discount_bps`, `hazard_odds_bps`, `piracy_odds_bps`, `bankruptcy_grace_ticks`, `takeover_threshold_shares`. An unknown stat fails `validate()` and is dropped by `_sanitise_modifiers`. | `parachutes.gd:47-58,172`, `run_controller.gd:847-861` |
| **Fuel burn.** The `fuel_hedge` perk is `fuel_discount_bps +1000`. `RunController.fuel_discount_bps()` (clamped 0..10000) feeds `Transit.calculate_fuel_burn`, charged on every departure (hold FUEL first, then a buy on the station's FUEL book). | `parachutes.json` (`fuel_hedge`), `run_controller.gd:368-370`, `transit.gd:290-322`, `run_controller.gd:162-200` |
| **Raid and hazard odds.** `black_market_corridors` is `piracy_odds_bps mul 8000`. `Corridors.piracy_odds_bps` is `rc.piracy_odds_bps() * lane rating / 10000`; the hazard factor reads `rc.hazard_odds_bps()`. Lane ratings come from `corridors.json` (piracy 6000 to 12000 bps, hazard 2000 to 15000 bps, per lane). | `parachutes.json`, `corridors.gd:89-99,147-151`, `data/corridors.json`, `run_controller.gd:372-378` |
| **Takeover threshold.** `Takeover.threshold_for` cuts the player's 501 shares by the `takeover_threshold_shares` stat, clamped to `[1, base]`. `tender_unlocked` is true whenever that stat is present in the modifiers at all. | `takeover.gd:152-160` |
| **Assumed debt.** A takeover moves `debt * player_assumed_debt_bps / 10000` onto the doomsday principal; the shipped value is 5000 (half). It is a barons.json setting, not a stat. | `takeover.gd:664-667`, `data/barons.json` (`takeover.player_assumed_debt_bps`) |
| **Tolls.** A belt departure pays `BELT_TOLL_CR` (25) up front; `Transit.calculate_toll` already takes an unused `corp_opex_discount` parameter that `can_depart` never passes. Docking at a baron's anchor charges outsiders 10 to 15 CR (`docking_toll_cr`) on arrival, capped at CR held, to SYSTEM; insiders pay nothing. | `transit.gd:53,329-336`, `run_controller.gd:128,179,219-229`, `barons.gd:665-676`, `data/barons.json` |
| **Interest and loans.** `interest_bps` sets the doomsday clock's interest per minute (base 100) and, through `Levers.credit_rate_bps`, the credit-line rate. `corrupt_regulator` is `interest_bps add -50`. | `run_controller.gd:353`, `levers.gd:417-423`, `parachutes.json` (`corrupt_regulator`), `doomsday_clock.gd:52-57` |
| **Burn.** `burn_rate` goes through `doomsday.set_burn_scaled(base, add, mul)` so a x0.85 on 8 CR/s stays exact. `corporate_shielding` is `burn_rate mul 8500`. | `run_controller.gd:354-360` |
| **Chapter 11 grace and stake.** `bankruptcy_grace_ticks` (`deferred_audit` +1800) is how many ticks of insolvency pass before auto-filing; `fresh_start_cr` sets the new corp's stake; `liquidation_haircut_bps` is the share kept in liquidation (50% base, `asset_protection` +1000). | `run_controller.gd:365-366,502-505,525`, `parachutes.json` |
| **Severance** is `rounds x 1 + 0.5% of peak net worth + 400 per baron held`, banked once per corp by `_bank_corp` through `Parachutes.award_severance`; there is no Severance stat. | `parachutes.gd:305-312`, `run_controller.gd:535-565` |
| **Where modifiers come from.** `modifiers` is a controller field set by `apply_modifiers`; `_init` derives it from the profile's unlocks (`_derive_modifiers`), `file_bankruptcy` re-derives it, `from_dict` re-derives it again. The saved `modifiers` key is part of the run hash. Runs started with explicit modifiers keep them. | `run_controller.gd:277,323-340,346-361,684,711-715,738,810-820` |
| **A new run is a new controller.** `next_run_for` builds a fresh `RunController` from the profile; `M0Loop.start_next_run` attaches a fresh `Barons` world to it. Nothing but the profile carries over. | `run_controller.gd:600-609`, `m0_loop.gd:1705-1712`, `main.gd:235-240` |
| **Filing is not a run end.** `file_bankruptcy` founds a new corp in place, keeps the clock and the controller, re-derives modifiers, forfeits held barons, and banks Severance for the failed corp. | `run_controller.gd:665-706` |
| **Optional run-state keys.** `RunSave.capture` adds `crisis`, `world` and `rescue` only when attached, so a run without them hashes as before; the state hash is over canonical JSON of the whole capture. | `run_save.gd:30-47,77-79` |
| **Modals that stop the clock.** `OVERLAY_CRISIS`, `OVERLAY_CONTRACT`, `OVERLAY_MONOPOLY`, Chapter 11, collapsed, rescued. The contract modal is the model: `_interrupt_check` trips on `world.has_pending_offer()`, `SimClock` pauses with `auto_paused_reason = "interrupt"` (serialized), `_raise_contract_if_pending` raises the modal if nothing outranks it, and A / B answer it. `_sync_overlay_from_controller` re-raises after a load. | `run_controller.gd:898-905`, `sim_clock.gd:146-154`, `m0_loop.gd:313-345,1482-1495,1812-1826`, `main.gd:2930-2931,2961-2981` |
| **A cursor list exists.** The perk screen is a modal of `perk` rows (`tier`, `name`, `branch`, `tag`, `cursor`), moved by D-pad `m0_up` / `m0_down` (`perk_cursor`) and bought with A. It also takes an onboarding `text` row (`ONB_PERKS_1`) pushed to the front. | `main.gd:3066-3077`, `m0_loop.gd:144,1674-1696` |
| **Controller-first actions.** `ALL_ACTIONS` holds 19 `m0_*` actions mirrored in `project.godot` and the Steam Input manifest; a modal reuses `m0_up` / `m0_down` / `m0_submit` / `m0_cancel` and adds none. | `m0_loop.gd:64-99`, `docs/design/onboarding.md` section 4 |
| **Replays** record player inputs only; `Replay.start_recording(seed, profile, delta, tpr, world)` attaches a world only when asked. The whole-world goldens play 40 rounds at 30 ticks per round, so they cross rounds 20 and 40. | `replay.gd:88-91`, `world_golden.gd:15-17`, `tests/fixtures/world/world_goldens.json` |
| **Onboarding** has a conditional beat for the perk screen that adds one `text` row to that modal, and says a later beat will teach the first policy pick once #160 exists. | `docs/design/onboarding.md` section 3 ("Later"), `main.gd:3074`, `data/onboarding.json` |
| **Localization.** Every player-visible string is a CSV key; tests require every used key to exist, every key to be reachable, no raw English in `ui/`, `scenes/`, `core/`, and the modals fit at 100 / 115 / 130% in English and in the pseudo locale (+30% length). | `tests/test_localization.gd`, `tests/test_i18n_audit.gd`, `tests/test_i18n_fit.gd:768-797` |

**Gaps (not features).** None of these exist: any run-scoped modifier layer, any stat for tolls, assumed debt or Severance, any mid-run pick, any in-run list of what the player has adopted.

## 2. Design goals

1. **Small.** One new data file, one small state object, one modal. No currency, no draw stream, no new `m0_*` action.
2. **Every effect is an existing lever.** A policy changes a number a perk already changes, or one the game already computes.
3. **Policies stack with perks by the same rule perks stack with each other** (section 5.3), so a player who owns Fuel Hedge simply gets more.
4. **Runs diverge by choice.** More nodes than picks, with forks the player cannot take both sides of.
5. **Goldens stay green with no picks**, and a policy honestly changes the hash when one is taken.

## 3. The tree (Proposed)

Four branches, three nodes each: one **root** (tier 1, pickable any time a pick is available) and a **fork** of two **capstones** (tier 2) that need the root and **exclude each other**. 12 nodes; a run grants 4 picks (section 4), so no run can own more than 4 of 12 and no run can own both capstones of a branch. Counting legal 4-pick builds from the rules (a pick is a root, or a capstone whose root is owned and whose sibling is not), there are 49, which is the "build variety" without any randomness; the figure is a count of choices, not a balance claim.

Voice: corporate HR speak, the register Ryan asked for in onboarding Question 6. Effects below are **placeholders**.

| Branch | Node | Tier | Needs / excludes | Effect (stat, op, value) | Copy (the card line) |
|---|---|---|---|---|---|
| **Logistics & Supply Chain** | Synergized Supply Chain | 1 | none | `fuel_discount_bps` add +1500 | Cross-functional alignment cuts fuel burn 15% on every departure. |
| | Risk Transfer Framework | 2 | needs Synergized Supply Chain; excludes Expedited Corridor Access | `piracy_odds_bps` mul 7000 | Raid exposure is transferred to a third party. Piracy odds down 30%. |
| | Expedited Corridor Access | 2 | needs Synergized Supply Chain; excludes Risk Transfer Framework | `hazard_odds_bps` mul 6000; `toll_discount_bps` add +10000 | Fast-tracked lane permits. Hazard odds down 40%, tolls waived. |
| **Treasury & Finance** | Cost Containment Initiative | 1 | none | `burn_rate` mul 9000 | Headcount-neutral savings cut the clock's burn 10%. |
| | Covenant Relief Package | 2 | needs Cost Containment Initiative; excludes Managed Wind-Down Plan | `interest_bps` add -30 | Lender-friendly restructuring. Interest down 30 bps a minute. |
| | Managed Wind-Down Plan | 2 | needs Cost Containment Initiative; excludes Covenant Relief Package | `liquidation_haircut_bps` add +1500 | Orderly asset disposal. Liquidation keeps 15 points more. |
| **Compliance & Risk** | Mandatory Training Module | 1 | none | `bankruptcy_grace_ticks` add +1800 | Staff completes training before any filing. Two more rounds of grace. |
| | Pre-Packaged Reorganization | 2 | needs Mandatory Training Module; excludes Exit Package Optimization | `fresh_start_cr` add +3000 | The next corp launches funded. Fresh-start stake +3,000 CR. |
| | Exit Package Optimization | 2 | needs Mandatory Training Module; excludes Pre-Packaged Reorganization | `severance_bps` mul 12500 | Departing executives negotiate better terms. Severance +25%. |
| **Mergers & Acquisitions** | Strategic Synergy Review | 1 | none | `takeover_threshold_shares` add -20 | Due diligence trims the control stake by 20 shares. |
| | Leveraged Buyout Framework | 2 | needs Strategic Synergy Review; excludes Aggressive Roll-Up Mandate | `assumed_debt_bps` mul 6000 | Acquired debt is largely written off. You assume 40% less of it. |
| | Aggressive Roll-Up Mandate | 2 | needs Strategic Synergy Review; excludes Leveraged Buyout Framework | `takeover_threshold_shares` add -30 | Board pre-approves the deal. Control stake trimmed by 30 more shares. |

Why these. Each branch is one question the player already asks. Logistics: how do I stop losing cargo and fuel? Finance: how do I last longer on the clock? Compliance: how bad can Chapter 11 get, and what do I take from it? M&A: how fast can I take barons? Each fork trades two different answers (odds vs time, interest vs liquidation, safety net vs payout, cheaper vs faster).

**Sizing principle (placeholder).** A root is worth about a tier 1 perk, a capstone about a tier 2 perk, and nothing here exceeds a tier 3 perk by itself (burn x0.85, threshold -50). The perks cost 100 to 500 Severance and last forever; a policy is free but lasts one run and costs a pick.

**What is not in the tree, on purpose.** No `starting_cr` (it is applied once at construction, `run_controller.gd:338`, before any pick could exist). No rent, treasury or rescue-project effect (the Rescue Project and baron rent are Epic 3 numbers Ryan tuned separately). No Chapter 11 forfeits.

## 4. What grants a pick (Proposed)

The hooks are all events the controller already sees: the round boundary (`_on_sub_ticked`, `run_controller.gd:864-877`), a takeover (`Takeover.take`, `takeover.gd:652-684`) and a filing (`file_bankruptcy`).

| Source | Grants | Why |
|---|---|---|
| **Round milestones** | 1 pick at rounds 20, 50 and 80 (`policies.json` `milestones`) | Predictable, replay-safe, and spaced inside the clock's stages (UNSTABLE at 30, CRITICAL at 72, IMMINENT at 102). A player who is losing still gets all three. |
| **First baron takeover** | 1 pick, once per run | Rewards the Epic 3 loop without letting a snowball earn unlimited picks; a baron the player loses and re-takes grants nothing. |
| **Chapter 11 filing** | none | A filing already forfeits barons and writes off debt; paying a pick for it would reward failing on purpose. |

That is **4 picks per run**, 3 certain and 1 earned. **Recommendation: milestones plus the first takeover (Question 1).** The alternatives, milestones only (simplest) or milestones plus every baron plus a consolation pick on each filing, are in section 13.

A grant is a counter, not a draw: `earned += 1`. No randomness is introduced, so nothing about a grant depends on the run seed.

## 5. Effects and stacking (Proposed)

### 5.1 The data

`game/data/policies.json` has the **same perk shape** as `parachutes.json`, plus `excludes`, and the copy is CSV keys instead of English (policies are new, and the localization tests forbid raw English in code; the data carries only keys).

```json
{
  "version": 1,
  "_placeholder": "Every number is a tuning guess for Ryan, in bps / shares / ticks / CR.",
  "milestones": [20, 50, 80],
  "takeover_pick": true,
  "policies": [
    {"id": "supply_chain", "branch": "logistics", "tier": 1, "requires": [], "excludes": [],
     "name_key": "POLICY_SUPPLY_CHAIN", "desc_key": "POLICY_SUPPLY_CHAIN_DESC",
     "effects": [{"stat": "fuel_discount_bps", "op": "add", "value": 1500}]},
    {"id": "risk_transfer", "branch": "logistics", "tier": 2, "requires": ["supply_chain"], "excludes": ["corridor_access"],
     "name_key": "POLICY_RISK_TRANSFER", "desc_key": "POLICY_RISK_TRANSFER_DESC",
     "effects": [{"stat": "piracy_odds_bps", "op": "mul_bps", "value": 7000}]}
  ]
}
```

(Two of the twelve entries shown.) Loading and validation reuse `Parachutes.load_from_dict`: it already checks ids, integer values, ops, unknown stats, `requires` cycles. Needed changes: keep `excludes` in `_normalise`, validate it (ids exist, symmetric, never equal to a `requires`), and add `modifiers_for(ids)` so `modifiers(profile)` becomes a thin wrapper (the fold is unchanged).

### 5.2 Three new stats, each a one-line consumer

| Stat | Consumer | Where |
|---|---|---|
| `toll_discount_bps` | Belt toll: `Transit.calculate_toll` gets an integer bps parameter beside the unused float `corp_opex_discount`, passed by `can_depart`. Docking toll: scale `toll_due` in `_arrive`. One stat, both tolls. | `transit.gd:329`, `run_controller.gd:128,224` |
| `assumed_debt_bps` | `Takeover.take`: `assumed = debt * apply_stat(rc.modifiers, "assumed_debt_bps", player_assumed_debt_bps) / 10000`. Base stays the barons.json 5000. | `takeover.gd:666` |
| `severance_bps` | `Parachutes.award_severance` takes a trailing `severance_bps: int = 10000` and scales the whole award; `_bank_corp` passes `apply_stat(modifiers, "severance_bps", 10000)`. | `parachutes.gd:305`, `run_controller.gd:559` |

They are added to `Parachutes.STATS` as `"live"`. Perks may use them later; no perk does now, so no perk changes.

### 5.3 How stacking works, exactly

Perks and policies are folded **separately by the existing fold**, then combined:

```gdscript
# Parachutes (new, static): per stat, add sums and mul_bps multiplies, truncating like the fold.
static func combine(a: Dictionary, b: Dictionary) -> Dictionary
#   out[stat].add     = a.add + b.add
#   out[stat].mul_bps = a.mul_bps * b.mul_bps / 10000
```

`RunController` keeps `modifiers` as the **effective** dictionary every consumer already reads, and adds one more field, `perk_modifiers`, which is what `modifiers` was (the profile-derived or explicit base). `apply_modifiers(mods)` keeps its signature and meaning: it sets the base and rebuilds `modifiers = combine(perk_modifiers, policies.modifiers())`. With no policies `modifiers` equals `perk_modifiers`, byte for byte. The saved `modifiers` key stays the base, so it never double counts on load.

So `apply_stat` sees `(base + perk_add + policy_add) * (perk_mul * policy_mul / 10000) / 10000`. Adds are summed **before** the multiplier, as two perks already do; the fold is order independent because adds commute and the combine is a fixed pair (perk side first). All placeholder multipliers are multiples of 100 bps, so the truncation in the product is exact today.

Worked, with every perk and policy that touches the stat owned (a worst case):

| Stat | Base | Perks | Policies | Result |
|---|---|---|---|---|
| `fuel_discount_bps` | 0 | Fuel Hedge +1000 | Synergized Supply Chain +1500 | 2500, so 25% off fuel burn (min 1) |
| `piracy_odds_bps` | 10000 | Black-Market Corridors x8000 | Risk Transfer Framework x7000 | 5600, so x0.56 (then x the lane rating) |
| `hazard_odds_bps` | 10000 | none | Expedited Corridor Access x6000 | 6000 |
| `interest_bps` | 100 | Corrupt Regulator -50 | Covenant Relief Package -30 | 20 bps a minute (and a smaller credit-line rate) |
| `burn_rate` | 8 CR/s | Corporate Shielding x8500 | Cost Containment Initiative x9000 | x7650, 6.12 CR/s kept exact by `set_burn_scaled` |
| `takeover_threshold_shares` | 501 | Hostile Buyout Line -50 | Strategic Synergy Review -20, Aggressive Roll-Up Mandate -30 | 401, clamped to `[1, 501]` |
| `liquidation_haircut_bps` | 5000 | Asset Liquidation Recovery +1000 | Managed Wind-Down Plan +1500 | 7500, clamped to 10000 |
| `bankruptcy_grace_ticks` | 0 | Deferred Audit +1800 | Mandatory Training Module +1800 | 3600 ticks, four rounds |
| `assumed_debt_bps` | 5000 | none | Leveraged Buyout Framework x6000 | 3000, so the player assumes 30% of a baron's debt |
| `severance_bps` | 10000 | none | Exit Package Optimization x12500 | 12500 |

Rule for Ryan, in one line: **adds add, multipliers multiply, perks and policies are the same kind of thing.**

**Two guards.** Policies must not unlock tender offers: `tender_unlocked` tests `rc.modifiers.has("takeover_threshold_shares")`, which a policy would now satisfy. It is changed to test `perk_modifiers`, so the Hostile Buyout Line perk keeps owning that unlock. And `_derive_modifiers` becomes the instance rebuild above, so `file_bankruptcy` (`run_controller.gd:684`) and `from_dict` (`:817`) keep the policies: section 7 explains why this is the first thing the tests pin.

## 6. State and lifecycle (Proposed)

`PolicyState` (`core/policy_state.gd`, `RefCounted`), held as `RunController.policies`, `null` when not attached, exactly like `world` and `rescue` (`run_controller.gd:81-83`):

| Field | Meaning | Saved |
|---|---|---|
| `picks: Array[String]` | Owned policy ids, in pick order | yes |
| `earned: int` | Picks granted so far | yes |
| `milestones_done: int` | How many of `milestones` have fired | yes |
| `takeover_granted: bool` | The one takeover pick is spent | yes |

`pending() = earned - picks.size()`. `on_round(round)` fires milestones; `on_takeover()` grants the takeover pick; `offers()` lists every node the player can take now (a root not owned, or a capstone whose root is owned and whose sibling is not); `pick(id)` validates against `offers()`. No node is ever refunded or swapped.

**Reset.** A run's policies live on the controller. `next_run_for` builds a new controller, so they are gone: no code is needed for "resets at run end", and nothing is written to the `MetaProfile`. A policy therefore cannot reach the profile or the settings file.

**Attached by `Main`, not by default.** `Main.start_new_run` and `M0Loop.start_next_run` attach `policies` beside `world`. The `RunController` constructor does not, and `Replay.Session` does not unless asked (a new optional argument, default off). Section 8 explains why this matters.

## 7. Chapter 11 (Proposed)

A filing is not a run end (`file_bankruptcy` founds a new corp inside the same controller). **Policies survive a filing**: they belong to the run, and the run continues. `PolicyState` is untouched by `file_bankruptcy`, and the modifier rebuild keeps them. Reasons:

- The player is already punished: debt wiped but liquid assets forfeited, barons forfeited, a new corp on the fresh-start stake. Taking their build too would end most runs.
- Two nodes only make sense after a filing (Pre-Packaged Reorganization, Managed Wind-Down Plan, Mandatory Training Module). If a filing dropped them they would be traps.
- Severance is banked per corp, so Exit Package Optimization applies to the failed corp's award too. This is the intended price of that capstone.

A pick granted by a takeover is **not** clawed back when the barons are forfeited (`takeover_granted` stays true). The pick for a baron the player loses a round later is the player's to keep; this is the same posture as the Rescue Project, whose progress is kept across a filing (`run_controller.gd:703`). **Question 2** asks Ryan whether he wants it harder.

## 8. Saves and the run hash (Proposed)

Policies are run state, so they change the hash when they exist.

- **Shape.** `RunSave.capture` adds `out["policies"] = controller.policies.to_dict()` only when `controller.policies != null` **and** `earned > 0`. Before the first milestone a run with policies attached hashes exactly as it does today. `restore` rebuilds `PolicyState` and then `rebuild modifiers`, after the world is restored (the same place `sync_rent_bonus` runs, `run_save.gd:69-70`).
- **`modifiers` does not change.** The saved key stays the perk base (section 5.3), so a run that owns policies adds `policies` and nothing else; the base is not rewritten.
- **Sanitising on load.** `from_dict` trusts nothing: unknown ids dropped, picks that violate `requires` or `excludes` dropped, `picks.size()` clamped to `earned`, `earned` clamped to `milestones.size() + 1`. A corrupt save cannot own a forbidden pair.
- **Which pins move.** None of the existing ones, because the goldens never attach policies: `tests/fixtures/world/world_goldens.json` (seeds 84 and 7, 40 rounds at 30 ticks, so rounds 20 and 40 are inside), `tests/fixtures/world/rescue_goldens.json`, `fold_order.json`, `embargo_fold_order.json`, and the hashes in `test_fleet_view.gd`, `test_travel.gd`, `test_rival_fleets.gd`, `test_market_wiring.gd`. `Replay.start_recording` gains `p_policies: bool = false`; the whole-world bot in `world_golden.gd` is unchanged and keeps answering only the overlays it already knows.
- **What moves, on purpose.** A new fixture, `tests/fixtures/world/policy_goldens.json`, plays a scripted bot that takes the first listed offer at each pick. It pins the picks, the round each lands on and the final hash. A pick is a recorded input (`m0_submit`, with `m0_up` / `m0_down` for the cursor), so a replay lands on the same hash.
- **Pending picks survive a save.** `pending()` is derived from the saved counters, `_sync_overlay_from_controller` re-raises the modal after a load, exactly as it does for a contract offer.
- **Tests that must exist before the UI lands:** a run with no picks hashes identically to one without a `PolicyState`; a pick adds exactly the `policies` key; a filing keeps `modifiers` equal to `combine(perks, policies)`; a save round-trip keeps it; a hand-edited save with both capstones loads with only one.

## 9. The pick UI (Proposed)

**An existing modal pattern, on the serialized path.** A new `M0Loop.OVERLAY_POLICY = "policy"`, built the way `OVERLAY_CONTRACT` is:

1. **The pause.** `RunController._interrupt_check` also trips when `policies != null and policies.pending() > 0`. `SimClock` then pauses itself (`sim_clock.gd:146-154`, `auto_paused_reason = "interrupt"`): the same serialized path as every other modal. The sim stops on the sub-tick the grant lands, so replays reproduce the same stop.
2. **The raise.** `M0Loop._raise_policy_if_pending()` mirrors `_raise_contract_if_pending` (`m0_loop.gd:313-320`): it does nothing while another overlay is up, pauses the clock and sets the overlay. It is called from the same six places the contract raise is, and from `_sync_overlay_from_controller`, so Chapter 11, collapse, a crisis, a contract and the monopoly summary all outrank it and it appears when they close. Two pending picks show one after the other.
3. **The model.** `Main._policy_model()` returns `{eyebrow: "POLICY COMMITTEE n OF 4", title: "Quarterly Policy Review", band: "teal", wide: true, rows, actions}`. The rows reuse the **`perk` row kind** the perk screen uses (`main.gd:3066-3077`): one per offered node, with `tier`, `name`, `branch` and a `tag` that shows `ROOT` or `FORK`. The cursor row's `desc_key` text follows as a single `muted` row (one description at a time bounds the height), then the HUD_CLOCK_HALTED line. Actions are `[D-pad, SELECT]` and `[A, ADOPT]`. There is **no B**: a pick may not be declined (Question 5).
4. **The input.** `dispatch_action` gets a branch like the contract's: `ACT_UP` / `ACT_DOWN` move `policy_cursor` (UI state, like `perk_cursor`, never saved), `ACT_SUBMIT` calls `RunController.adopt_policy(id)`, and nothing else is live behind the modal except Chapter 11. No new `m0_*` action, so `project.godot`, the Steam Input manifest and `docs/steam.md` are untouched. Keyboard and gamepad work the same through the existing actions.
5. **After the pick.** The modal closes, the clock resumes (as `accept_contract` does), a GalNet headline posts (`HL_POLICY_ADOPTED`), `_refresh_world_mods` runs if the stat affects books (none do today), and a one-line chip joins the desk-notes card: `POLICIES 2/4`, with the adopted names in the lines under it. Without this the player could not see what they own.

**Rows at the worst case.** Up to 7 rows (three roots owned, no capstones taken: six capstones and one root). The test in section 11 measures it at 130% pseudo; if it overflows, the list shows a five-row window that scrolls with the cursor (the perk screen already scrolls its list).

## 10. The onboarding hook (Proposed)

`docs/design/onboarding.md` leaves "a later beat teaches the first policy pick" for #160. Its mechanics are the perk beat's (beat 8): **one new conditional beat**, `policy`, in `data/onboarding.json`:

- `kind: conditional`, `holds: false` (the modal already stops the clock through the serialized path, so the `Main`-level freeze is not needed), `fires` on a new `policy_pending` event, `done` on a new `policy_adopted` event.
- The text is one `text` row pushed to the front of the policy modal, as `_perks_model` does at `main.gd:3074`: what a policy is, that it lasts one run and that the permanent perks are unchanged. In the HR voice, three lines, for example: "Welcome to the Policy Committee. Adopt one directive. It remains in force until this run ends. Your Golden Parachutes are unaffected."
- Two signals are added to `RunController`: `policy_pending(count)` and `policy_adopted(id)`. `Onboarding` already connects to controller signals and never calls into the sim.
- It shows once per player (the `seen` list), whenever the first pick arrives, including in run 2.

A new player's first pick lands at round 20, after the five core beats are done, which is the order the onboarding doc wants: the core loop is learned before a build decision is asked for.

## 11. Localization and the 130% pseudo fit (Proposed)

- **Keys.** `POLICY_EYEBROW`, `POLICY_TITLE`, `POLICY_TAG_ROOT`, `POLICY_TAG_FORK`, `POLICY_CARD_CHIP`, `HL_POLICY_ADOPTED`, `HUD_ACT_ADOPT`, `ONB_POLICY_1`, one `POLICY_BRANCH_*` per branch, and a `POLICY_<ID>` plus `POLICY_<ID>_DESC` per node (24 for the tree). The JSON carries keys only.
- **Numbers in copy.** A `_DESC` string takes its numbers as format arguments computed from the node's own `effects` (for example `value / 100` for a percent), so the CSV can never disagree with the JSON; a test asserts every `_DESC` has the arguments its format string needs.
- **Length budget.** Names at most 28 characters (the longest, Pre-Packaged Reorganization, is 27), one `desc` at most two lines at 130% in the wide modal, branch labels at most 24. `HudKit.fit_text` already shrinks single-line labels; the `perk` rows use it.
- **Tests added to `test_i18n_fit.gd`'s modal case** (`:768`): the policy modal at its worst case (section 9) in English and pseudo at 100, 115 and 130%, the desk-notes chip and lines, and the onboarding row. The "judged only N labels" floor there is raised by the rows added. `test_localization.gd` and `test_i18n_audit.gd` pass if the keys exist and are used.

## 12. Balance placeholders and risks

**Placeholders to tune (all in `policies.json`).**

| Knob | Placeholder | Note |
|---|---|---|
| Milestones | rounds 20, 50, 80 | 120-round run; a pick before each stage change |
| Takeover pick | yes, first baron only | the snowball guard |
| Fuel | +1500 bps | stacks with Fuel Hedge to 25% |
| Piracy | x7000 | with the perk x0.56, before lane ratings of 6000 to 12000 |
| Hazard | x6000 | the perk has none, so this is the only reduction |
| Tolls | waived | 25 CR belt, 10 to 15 CR docking: small beside the hazard cut |
| Burn | x9000 | with the perk x0.765 |
| Interest | -30 bps | with the perk 20 bps a minute |
| Liquidation | +1500 bps | with the perk 75% kept |
| Grace | +1800 ticks | two rounds; with the perk four |
| Fresh start | +3000 CR | the 5,000 CR stake becomes 8,000 |
| Severance | x12500 | the only effect that reaches the permanent profile |
| Threshold | -20, -30 | with the perk 401 shares |
| Assumed debt | x6000 | 5000 becomes 3000 |

**Risks.**

1. **The modifier rebuild is the riskiest change.** `modifiers` is re-derived at three sites. If one forgets the policies, a filing or a load silently drops the build, and the failure looks like "my perk stopped working", not an error. The section 8 tests pin all three paths before any other work lands.
2. **Goldens crossing round 20.** If anyone attaches policies to `Replay.Session` by default, both world pins move. The default-off flag and a test that the shipped goldens contain no `policies` key guard it.
3. **Severance feeds the permanent profile.** A +25% capstone is the one run-scoped effect that pays into permanent progression; it is also the one the player picks instead of a safety net. Question 4.
4. **Hazard is the real value of Expedited Corridor Access.** The toll waiver saves 25 CR on a belt leg and 10 to 15 CR at a baron's dock, which is small next to a hold. The node is carried by the hazard cut; if Ryan wants tolls to matter, the toll is data (`BELT_TOLL_CR`, `docking_toll_cr`).
5. **Takeover snowball.** Threshold cuts let the player take barons sooner, and a takeover is itself a pick source. Capped to one takeover pick; the 401 floor with every cut is about 20% under the base.
6. **A strictly dominant node.** With only 4 of 12 picked, a dominant root would become a mandatory first pick and kill divergence. Row 6 of the plan runs `pacing_bot` per root, and flags any one that wins in more than 60% of runs.
7. **Perk-screen overflow is already known** (`test_i18n_fit.gd:1107` mentions pseudo overflows in perk branch labels); the policy modal reuses its row kind and must not inherit it.
8. **Offer list is deterministic, not Hades-random.** Variety comes from the player's choices and the forks. A random three-of-N offer is a later change behind `offers()` (Question 6) but would add a draw stream and a hash input.

## 13. Implementation plan

One Sonnet PR per row. Order: 1, then 2, then 3. Rows 4 and 5 can run in parallel after 3. Row 6 needs row 3.

| # | PR | Scope | Estimate |
|---|---|---|---|
| 1 | **Policy data and the stacking seam** | `policies.json` (12 nodes), `excludes` in `Parachutes` normalise and validate, `modifiers_for(ids)`, static `combine`, `perk_modifiers` plus the rebuilt effective `modifiers` in `RunController` (`apply_modifiers`, `_init`, `file_bankruptcy`, `from_dict`), `tender_unlocked` on the perk base. Tests: stacking table, filing and load keep policies, no-policy run byte-identical. | ~25 min agent time · ~0.4% of the weekly limit |
| 2 | **Three new stats** | `toll_discount_bps` (belt and docking), `assumed_debt_bps`, `severance_bps`, added to `STATS`, with consumers and focused tests; no perk changes. | ~10 min agent time · ~0.15% of the weekly limit |
| 3 | **Grants, state and saves** | `PolicyState`, `on_round`, `on_takeover`, `offers`, `pick`, the `policies` capture key and sanitising restore, `_interrupt_check` trip, `policy_pending` / `policy_adopted` signals, `Replay.start_recording(..., p_policies)`, `policy_goldens.json` and its test. | ~25 min agent time · ~0.4% of the weekly limit |
| 4 | **Pick modal, card chip, CSV** | `OVERLAY_POLICY`, `_raise_policy_if_pending`, `dispatch_action` branch, `_policy_model` on `perk` rows, desk-notes chip, `HL_POLICY_ADOPTED`, all CSV keys, `test_i18n_fit.gd` and localization tests, screenshots script. | ~30 min agent time · ~0.5% of the weekly limit |
| 5 | **Onboarding beat** | `policy` beat in `onboarding.json`, the `text` row in the modal, event wiring, `onboarding_bot.gd` case. Waits on the onboarding implementation PRs. | ~10 min agent time · ~0.15% of the weekly limit |
| 6 | **Balance probe** | A `pacing_bot` pass per root and capstone to find a dominant node, results recorded in the PR; retune numbers in `policies.json` only. | ~15 min agent time · ~0.2% of the weekly limit |

Total about 1.8% of the weekly limit across six PRs (placeholder, sized from the shipped single-PR Sonnet builds).

## 14. Questions for Ryan

1. **What grants a pick?**
   - (a) Round milestones only: three picks, at rounds 20, 50 and 80.
   - (b) Milestones plus a pick for the first baron takeover: four picks. **Recommended.** It rewards the barons loop without letting a snowball earn unlimited picks.
   - (c) Milestones, a pick for every baron, and a consolation pick on each Chapter 11 filing: up to seven picks, more build, more snowball.
2. **Do policies survive a Chapter 11 filing?**
   - (a) Yes, all of them. **Recommended.** A filing is not a run end, and three nodes only pay off after one.
   - (b) No, a filing resets the tree and refunds the picks.
   - (c) Capstones are lost, roots are kept.
3. **Tree shape: a fork or a chain?**
   - (a) Each branch is a root plus a fork of two capstones that exclude each other. **Recommended.** Four picks, 12 nodes, 49 legal builds.
   - (b) Each branch is a three-node chain, and the exclusivity is across branches (only two branches may be started).
4. **Does the Compliance capstone "Exit Package Optimization" keep its Severance bonus?** Severance is the one thing a policy can add to the permanent profile.
   - (a) Keep it at x1.25. **Recommended.** It is the price of skipping a safety net and Ryan listed Severance as a lever.
   - (b) Keep it at a smaller x1.10.
   - (c) Replace it with a run-only effect, so nothing a policy does reaches the permanent profile.
5. **Can the player decline or defer a pick?**
   - (a) No, every pick is taken when it is offered, as a crisis is acknowledged. **Recommended.** It is the simplest and it keeps the clock off for one decision only.
   - (b) B defers the pick to the next dock, with a reminder chip.
6. **How are the choices offered?**
   - (a) The full list of nodes the player can take now. **Recommended.** Deterministic and replay-safe; variety comes from choosing among 12 nodes.
   - (b) Three random eligible nodes per pick, Hades-style. More replay variety, but it adds a draw stream seeded by run seed and pick number, and the player may not see the one they planned for.

## 15. Not in this doc

Final copy for each node (the table's lines are intent in the HR voice); art for the modal or the card; whether the run summary lists adopted policies (a single `kv` row is the cheap version); a policy that interacts with the Rescue Project; rebalancing any permanent perk; any change to the Golden Parachutes screen. None blocks rows 1 and 2.
