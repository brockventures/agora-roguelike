# Sol System Rescue Project: the post-monopoly climax

Design proposal for #32 (Implement Endgame Sol System Rescue Project (Post-Monopoly Climax)), part of #8 (Epic 2) and #14 (Epic 3: Planetary Sector Barons & Rival Syndicate AI). It builds on `docs/design/epic3-barons.md` section 5.4 and decision 9.1 (victory is every baron and station, then the Rescue Project wins the run) and on the monopoly state that task 9 shipped.

**Status: proposed, awaiting Ryan** (section 12). Every section separates what the code already does (**Grounded**, with `file:line` from `main` at `0bea1d9`) from what this doc invents (**Proposed**). Nothing here is game code. Every number marked "placeholder" is a tuning guess for Ryan, in CR, units, bps or rounds. The pacing numbers in section 7 were measured with a throwaway probe against `main` (`scratch/e32probe/`, not committed); the method and its limits are stated there.

## 1. What exists today (Grounded)

| Fact | Where |
|---|---|
| The run is **120 rounds**: 108000 ticks at 900 ticks per round, 60 ticks per second, so 30 minutes at 1x. Burn is 8 CR/s, interest 100 bps per minute on principal plus accrued interest. | `game/core/doomsday_clock.gd:52-57` |
| The clock has five stages by ratio of ticks left: UNSTABLE at 75% (round 30), CRITICAL at 40% (round 72), IMMINENT at 15% (round 102), COLLAPSED at 0. Burn multipliers are 1.0x, 1.5x, 2.5x, 5.0x, 10x. In CR per round (15 s) that is 120, 180, 300, 600. | `doomsday_clock.gd:69-81`, `_compute_stage` :180 |
| The clock advances one tick per sim sub-tick: `RunController._on_sub_ticked` calls `doomsday.step_ticks(1)` unconditionally, then handles arrival and the round boundary. Rounds come from the **sim clock's** total ticks, not from the doomsday clock. | `game/core/run_controller.gd:697-705` |
| `DoomsdayClock.apply_tribute(amount_cr, ticks_per_credit)` already adds ticks back (3 per CR, never past `total_ticks`) and de-escalates the stage. **Nothing calls it**: no caller in `core/` or `ui/`. | `doomsday_clock.gd:382-407` |
| Collapse is the only run end. `_on_collapsed` banks Severance through `_bank_corp(reason)` once per corp (the `_banked_corp` guard) and emits `run_collapsed`. `is_run_over()` is `is_collapsed()`. There is no victory end. | `run_controller.gd:347,382,391,749`, `doomsday_clock.gd` |
| `Barons.monopoly_achieved()` is derived from holders (never stored): every baron held by the player. `RunController.check_monopoly()` fires `monopoly_achieved` once per monopoly and is re-armed by a Chapter 11 filing, which forfeits the holdings. | `game/core/barons.gd:441`, `run_controller.gd:333-345` |
| `M0Loop.OVERLAY_MONOPOLY` pauses the clock when the player takes the last baron (unless a filing is pending or the takeover left the corp insolvent). A continues. The body string already promises the next step: "The Sol System Rescue Project is the last step." The model comment says the win "is #32, so A only continues". | `game/ui/m0_loop.gd:55,368-402`, `game/scenes/main.gd:2653`, `game/localization/agora_strings.csv:409` |
| A held baron pays its holder **rent** each round: `rent_units` (100) of each pipeline commodity at its anchor's BASE price, at `rent_spread_bps` (600). Paid straight into `rc.cr` at the round boundary. For the shipped three barons the rent totals **675 CR a round**. | `game/core/takeover.gd:245-253,284-286`, `game/data/barons.json` |
| Docking tolls exist (Ares 15, Titan 10, Sol Central 12 CR) but go to SYSTEM: `_arrive` subtracts the toll from the arriving player's CR and credits nobody. A held baron makes the player toll-exempt. **There is no toll income for a holder.** | `run_controller.gd:147-168`, `barons.gd:642-654` |
| A taken baron's treasury is absorbed into the player's CR and its debt onto doomsday principal at the moment of takeover. Along the lever route (corner, credit, default) the treasury is already drained: all three read `treasury=0` after the probe's takeovers. A held baron keeps its warehouse (`inventory`); after the probe's takeovers that was Ares 200 MACHINERY, Sol Central 150 FOOD, Titan 200 FOOD (section 4). | `takeover.gd` (`take`), `epic3-barons.md` 5.3, probe in section 7 |
| Pipelines: each baron's anchor has two commodities with extra ask depth, and outsiders pay a premium on the ask; insiders (the holder) see the base price. Mars: ORE and MACHINERY. Ceres: FUEL and FOOD. Earth: FRAG and FOOD. **Luna has no baron.** | `barons.json`, `barons.gd:657` |
| The transit loop: four stations (`earth`, `luna`, `mars`, `ceres`), five commodities (`FRAG`, `FUEL`, `FOOD`, `ORE`, `MACHINERY`), a **100-unit hold**, route times of 1 to 3 rounds (Earth-Luna 1, Earth-Mars 2, Luna-Mars 2, Mars-Ceres 2, Earth-Ceres 3, Luna-Ceres 3). `StationMarket.unlock_station` seeds books for any of the four. Fuel burn is computed but nothing in play charges it. | `game/core/transit.gd:10-45`, `run_controller.gd:43-44`, `station_market.gd:109`, `epic3-barons.md` section 1 |
| Base prices (CR per unit): Earth FRAG 20.2 FUEL 14.5 FOOD 10.2 ORE 27.5 MACHINERY 18.5; Luna 15.8 / 8.5 / 22.0 / 21.5 / 23.0; Mars 12.8 / 16.5 / 17.5 / 16.5 / 13.8; Ceres 11.2 / 24.5 / 27.5 / 11.5 / 29.5. | `transit.gd:20-26` |
| Severance is `rounds x 1 + 0.5% of peak net worth + 400 per baron held at the end`, banked into `profile.severance_points` and `profile.barons_broken` (saved only when non-zero). The perk tree in `parachutes.json` costs 2050 points in total (tiers 100 / 250 / 500). | `game/core/parachutes.gd:62-66,301-307`, `game/core/meta_profile.gd:21,69`, `game/data/parachutes.json` |
| Chapter 11 assessment is `Chapter11.assess`: insolvent when total debt exceeds liquidation value (CR plus cargo at a 50% haircut). A fresh corp starts with 5000 CR. Filing forfeits held barons. | `game/core/chapter11.gd:24-34`, `epic3-barons.md` 5.3 |
| Random vs consequence: baron events carry `origin`; the lethal guard `Barons.penalize(.., "random")` cannot make the player insolvent. The random `margin_call_bps` drain in `_advance_crisis_deck` is **not** under that guard. Raids are real: a bounty-sponsored raid on a departure either takes a ransom or, when the player cannot pay, seizes the cargo. | `epic3-barons.md` 7 and 6.3, `run_controller.gd:710-720` |
| Determinism tooling: `StableHash.hash32`, `RunSave.capture` composing optional keys (`crisis`, `world`) only when attached, `state_hash` over canonical JSON, replays record player inputs only (world_golden dispatches `M0Loop.ACT_*`). | `game/core/run_save.gd:30-47`, `game/core/replay.gd`, `game/tools/world_golden.gd` |
| HUD v3 pieces a project can reuse: `HudKit.tag`/`set_tag` chips, `pad_glyph` button prompts, sidebar row dictionaries `{kind: "chip"|"line", text, tone}` built by `M0Loop` (`takeover_lines`, the lever rows), the card region `CARD_RECT`, the two-line GalNet `TICKER_RECT`, `OrbitalHUD.post_headline_tr`, `ToastTray`, and modal models (`rows` of `kv`/`text`, `band`, `actions`) in `main.gd`. | `game/ui/hud_kit.gd:216,265,275`, `m0_loop.gd:719,816-895`, `hud_layout.gd:18,31`, `orbital_hud.gd:434`, `toast_tray.gd`, `main.gd:2630-2660` |

**Gaps (not features).** None of these exist in `game/`:

- Any win. `grep -ri rescue game/` finds comments and one localization string only.
- Any way to give the clock time back in play, other than the unused `apply_tribute`.
- Income for the baron holder beyond rent. Tolls go to SYSTEM; treasuries are spent before the takeover.
- A destination that is not a market. Stations are only places with books.
- A sink for commodities. Cargo leaves the hold only by selling into a book.

## 2. Design goals

1. The Rescue Project is **the same game with a new reason to travel.** It uses the hold, the routes, the books and the pipelines. No new minigame, no new currency.
2. **Monopoly pays for the rescue; the player supplies the legs.** Rent funds the CR cost, the pipelines make the goods cheap, and the work is hauling them to four named stations.
3. **Progress is never taken away by chance** (Ryan's rule, section 8). The clock can end the run only because the player was too slow.
4. **No new randomness.** The project is a pure function of the player's deliveries, so replays and saves need no new draw streams.
5. A strong run **fits with room to spare**; a slow run fails by a margin the player can see coming (section 7).

## 3. The project (Proposed)

### 3.1 The thing being built

A **Magnetic Solar Stabiliser** ("the Stabiliser"): a ring of superconducting coils that holds the Sun's flare cycle steady. Four phases, each at a named station, each needing a bill of commodities from the hold and a CR fee. Fiction only; the mechanics do not depend on the name, so a Dyson Swarm variant (issue text) is a data swap in `rescue.json`.

`game/data/rescue.json`, loaded like `barons.json` (`Barons.load_data` pattern), validated, all numbers through `int()`:

```json
{
  "version": 1,
  "_placeholder": "Every number is a tuning guess for Ryan, in CR / units / bps / rounds.",
  "unlock": "monopoly",
  "rent_multiplier_bps": 20000,
  "phases": [
    {"id": "anchor_yard", "name": "Anchor Yard", "site": "luna", "needs": {"MACHINERY": 100, "ORE": 100},
     "cr": 4000, "keep_bps": 6000},
    {"id": "coil_foundry", "name": "Coil Foundry", "site": "earth", "needs": {"FUEL": 100, "MACHINERY": 100},
     "cr": 5000, "keep_bps": 3500},
    {"id": "containment_shell", "name": "Containment Shell", "site": "mars", "needs": {"FOOD": 100, "FRAG": 100},
     "cr": 7000, "keep_bps": 1500},
    {"id": "ignition_array", "name": "Ignition Array", "site": "ceres",
     "needs": {"MACHINERY": 100, "ORE": 100, "FUEL": 100}, "cr": 8000, "keep_bps": 0}
  ],
  "win": {"severance_base": 1000, "severance_per_round_left": 20}
}
```

Total: **900 units** (nine full holds) and **24,000 CR** in fees. Each phase's site is where its goods are scarcest by construction (section 3.3), so every phase needs hauling from somewhere else.

### 3.2 The phase loop

The project **opens** when `monopoly_achieved` fires and the player continues from the monopoly summary (A now also opens Phase 1; the `MONO_BODY` line becomes true). Phases run **strictly in order**: only the open phase accepts deliveries.

- **Deliver.** Docked at the open phase's site, with the needed commodity in the hold, the player presses one new action, `m0_project` (a face button not yet bound; nothing locked is rebound, as in Epic 3). It moves `min(held, still needed)` units of each needed commodity from the hold into the project and charges the fee **pro rata** (`cr x units / phase_units`, rounded up, whole CR). Pay-as-you-deliver means CR is never stranded in a half-built phase and the player decides how much cash to commit and when.
- **Refusals** (the `m0_shares` precedent): `NOT_OPEN`, `WRONG_SITE`, `NO_CARGO`, `NO_CR`, and `WOULD_BANKRUPT` (the fee would leave `Chapter11.assess` insolvent, so the project can never push the player into Chapter 11 by itself).
- **Phase complete** when every need is met. Progress is monotonic: deposits are never withdrawn, decayed or seized (section 8). Completing a phase sets the clock's new `keep_bps` (section 5), posts a ticker line and a toast, and opens the next phase.
- **Phase 4 complete = the run is won** (section 6).

### 3.3 Sites: why hauling is mandatory

Every station sells every commodity (`unlock_station` seeds all five), so on its own a site that is also a seller would let the player buy and deposit in place and never travel. The rule that prevents it uses machinery that already exists:

> While a phase is open, the site's books **carry no ask depth** for that phase's commodities: `{station: site, commodity: X, depth_bps: -10000}` world mods, emitted from project state each round like every baron effect (epic3 constraint 1: persistence cannot live in the book, because `replenish()` reseeds it).

The fiction: the yard has bought up the local stock. The player's other trades at the site are untouched (bids stay). The mods fold **after** every baron and rival mod and before crisis mods, with a golden fixture for the order, exactly as epic3 constraint 3 requires.

Where the goods are bought is the player's choice, and that is the design:

- **Far and cheap**: a pipeline station (insider base price, extra depth) or the cheapest book. Costs rounds, saves CR.
- **Near and dear**: any station that is not the site. Costs CR, saves rounds.

The bill, with the source each line uses in the section 7.2 route (BASE prices; the pipeline stations give the holder the base price with extra depth). Cheaper books exist for some lines (Ceres FRAG 11.2, Ceres ORE 11.5) but sit further away, which is the CR-for-rounds trade the player makes:

| Phase | Site | Needs | Source used (CR/unit) | Goods at base |
|---|---|---|---|---|
| 1 Anchor Yard | Luna | MACHINERY 100, ORE 100 | Mars pipeline 13.8; Mars pipeline 16.5 | 3,030 |
| 2 Coil Foundry | Earth | FUEL 100, MACHINERY 100 | Luna 8.5; Mars pipeline 13.8 | 2,230 |
| 3 Containment Shell | Mars | FOOD 100, FRAG 100 | Earth pipeline 10.2; Earth pipeline 20.2 | 3,040 |
| 4 Ignition Array | Ceres | MACHINERY 100, ORE 100, FUEL 100 | Mars 13.8; Mars 16.5; Mars 16.5 | 4,680 |
| | | 900 units | | **12,980** |

Every line has its source 1 to 2 rounds from the site. The pipelines of all three barons are used: Mars (ORE, MACHINERY) feeds phases 1, 2 and 4, Earth (FOOD, FRAG) feeds phase 3, and the Ceres pipeline is the site of the last phase, so its FUEL and FOOD must come from elsewhere.

## 4. How owning every baron helps

Honest accounting against the code, not the brief's wish list:

| Source | Today | Use in the project |
|---|---|---|
| **Rent** | Real: 675 CR a round across the three barons (`takeover.gd:245`). | **The main funding.** While the project is open, rent is multiplied by `rent_multiplier_bps` (20000, placeholder), so **1,350 CR a round**. `Takeover.rent` stays a pure function of saved state (the multiplier reads the saved project state), so rent previews and the sidebar line stay correct. |
| **Pipelines** | Real: insider base price and extra depth on six commodity lines. | The cheap source for four of the five commodities (section 3.3). Without the monopoly the same goods cost an outsider's ask premium (+6% to +8%, `barons.json` `outsider_ask_bps`) and thinner depth: a visible edge. |
| **Warehouses** | Real: a taken baron keeps its `inventory`. The probe left Ares 200 MACHINERY, Sol Central 150 FOOD, Titan 200 FOOD (the lever route drains the pipeline lines it covers, not the rest). | **Pledge**: stock in a held baron's warehouse **at the open phase's site station** counts as already delivered, no hauling, CR fee still charged. Because the lever route decides what is left, the pacing in section 7 does **not** count on it; it is upside. Phase 3 at Mars with Ares's machinery is the only case that matches the shipped stock, so this is a small bonus. |
| **Treasuries** | A takeover absorbs the treasury into CR at once. The shipped lever route leaves it near 0. | **Not a funding source**, and the doc does not pretend otherwise. They paid for themselves at takeover. |
| **Toll income** | None. Tolls go to SYSTEM. | **Not a funding source.** Even if tolls were redirected to the holder, a fleet docking pays 10 to 15 CR, a rounding error beside 1,350 a round. Proposal: leave tolls alone. The exemption stays the benefit. |

Self-funding arithmetic at the **ideal** pace (27 rounds of hauling, section 7): rent is 1,350 x 27 = **36,450 CR**; the project costs 24,000 (fees) + 12,980 (goods) = **36,980 CR**. The monopoly pays for the project to within 1.5% if the player keeps the ideal pace, and pays more the slower they are (rent is per round). What it does **not** pay is the doomsday debt that keeps accruing (section 5), which the player's net-worth buffer has to carry.

## 5. How the Doomsday Clock interacts

### 5.1 The Stabiliser Field (Proposed)

Each completed phase sets the share of sim ticks that count against the doomsday clock (`keep_bps`): 10000 until Phase 1 completes, then **6000, 3500, 1500**, and 0 (halted) when Phase 4 completes (the win). A tick that does not count skips `doomsday.step_ticks(1)` entirely, so **ticks, burn and interest all slow together**. Rounds, markets, rivals and baron steps are on the sim clock and do not change speed.

```gdscript
# RunController._on_sub_ticked, the one changed line (the rest is untouched)
if rescue == null or rescue.counts_tick(total):
    doomsday.step_ticks(1)
# RescueProject
func counts_tick(total: int) -> bool:
    return total * keep_bps / 10000 != (total - 1) * keep_bps / 10000
```

`counts_tick` is a pure function of the absolute tick and the saved `keep_bps`: an integer Bresenham count with no accumulator to save, so a save at any tick and a restore continue identically. `keep_bps = 10000` counts every tick, so a run with no project hashes as before.

Why dilation and not `apply_tribute`: a tribute is a flat exchange of 3 ticks per CR that bypasses the hauling entirely, and it is capped at the clock's full length. Dilation makes each milestone worth more the earlier it lands, which is the pressure the climax wants. `apply_tribute` stays unused.

### 5.2 What the player feels

- Phase 1 is the only phase done at full burn. It is also the smallest (200 units, 4,000 CR), so the exposed stretch is short.
- Each phase changes the HUD's doomsday readout from a countdown to a countdown **plus a speed**: "CLOCK 60%". The stage colour stays tied to ticks left, so a field that holds the clock at IMMINENT is visibly a field, not a safe place.
- Debt still accrues, slower. At CRITICAL the base is 300 CR a round plus interest (about 160 CR a round on 65,000 principal, 1% a minute and 15 seconds a round), roughly 460 CR a round. At `keep_bps` 3500 that is about 160 CR a round, **less than the 675 CR rent alone**, so the corp gets richer while the rescue runs. That is the intended reward feeling for the last two phases.

## 6. Win and loss

### 6.1 Win (Proposed)

Phase 4 complete -> `RescueProject.completed` -> `RunController.finish_rescue()`:

- `end_run("rescued")` (existing path: `_bank_corp` once per corp, `end_reason = "rescued"`), the sim clock pauses, `is_run_over()` returns true for a rescued run (it must not read `is_collapsed()` alone), and the collapse path cannot double-bank because of the `_banked_corp` guard.
- `M0Loop.OVERLAY_RESCUED` raises a wide teal modal (the `_monopoly_model` shape: eyebrow "SOL SYSTEM RESCUED", body, `kv` rows, A continues), then the **existing** summary -> Golden Parachutes perks -> new run flow (`PHASE_SUMMARY`, `m0_loop.gd:1512`). The collapse overlay is not reused; the cause text for `reason == "rescued"` is new.
- **Run summary rows** (additions to `run_summary()`, `m0_loop.gd:1326`, and `_summary_model`, `main.gd:2630`): `RESCUED IN ROUND N`, `ROUNDS OF CLOCK LEFT`, `PHASES x/4`, `UNITS HAULED`, `PROJECT CR PAID`, plus the existing net worth, peak, rounds, per-baron Severance rows.
- **Severance for a rescued run** (`Parachutes.award_severance` gains a `rescued` argument, default false): the normal terms **plus** `severance_base + severance_per_round_left x clock-rounds left` (1000 + 20 per round). A rescue at round 106 with 14 clock-rounds left adds 1,280. A normal strong run banks about 1,600 (106 rounds + 3 x 400 + 0.5% of a 60,000 peak), so a rescue roughly doubles it; one rescued run buys most of the 2,050-point tree. Placeholder.
- **Meta-progression reward**: `MetaProfile.rescues_completed` (default 0, saved only when non-zero, the `barons_broken` pattern, so old profiles and hashes hold), shown as "SOL RESCUED x N" on the summary and the title. A new achievement `SOL_RESCUED` ("Sol Saved", hook `rescue_completed`) and a stat entry in `achievements.json`. **No gameplay power** for winning (see Question 4).

### 6.2 Loss (Proposed)

The clock reaches zero with the project unfinished: the existing collapse, existing summary, existing Severance. The summary gains a row `STABILISER: PHASE x OF 4` and a consolation of `phase_consolation` (100, placeholder) Severance per completed phase, so a near miss pays something and a failed attempt does not read as a wasted run (Question 3).

The hard edge case: **the player files Chapter 11 mid-project.** Proposed (Question 5): the project is **world state, like the doomsday clock** (epic3 section 2.5: "every corp lives in the same Sol"): progress and the deposits of the open phase **survive the filing**, the barons revert, CR and cargo are lost, the rent bonus ends with the holdings. A new corp can finish the job from the same Sol, with no rent and no pipelines. That is a real penalty (the economy the plan relied on is gone) without erasing the player's work.

## 7. Pacing (with arithmetic)

### 7.1 Measured: how fast the monopoly arrives

Method. A throwaway probe (`scratch/e32probe/takeover_pace.gd` and `full_chain2.gd`, run headless on Godot 4.7.2 as `godot --headless --path game -s <probe>`) builds the shipped world with the rival fleets removed, parks the player at each baron's anchor with 100 units of a pipeline commodity, and drives the real round step (`Barons.advance_round`, `open_credit`, `buy_shares`) exactly as the lever chain test does (corner, credit line, default, distress lot, buy). Doomsday is stepped 900 ticks a round. The player visits Sol Central (Earth), then Titan (Ceres, 3 idle rounds of travel), then Ares (Mars, 2 idle rounds).

| | Titan Cryo-Hydro (Ceres) | Sol Central (Earth) | Ares Heavy (Mars) |
|---|---|---|---|
| Rounds from first corner to takeover, alone | **19** | **24** | **31** |
| Credit line opened | round 7 | round 9 | round 11 |
| First distress lot | round 13 | round 18 | round 25 |

All three seeds tested (21, 84, 7) gave identical numbers: with no rivals and no random baron events in the probe's path, the lever chain is deterministic. In sequence with travel the monopoly lands at **round 79 of 120** (Sol 24, Titan 46, Ares 79), leaving **41 rounds**. At round 79 the clock is in CRITICAL (it entered at round 72) and enters IMMINENT at round 102, 23 rounds later.

Capital is the binding constraint, not time. The takeover refuses a bid that would leave the corp insolvent (`WOULD_BANKRUPT`), and the baron's debt lands on the player's principal. Re-running the same chain with different starting CR:

| CR at the start of the chain | Result |
|---|---|
| 5,000 (the fresh-start stake) | Refused (`WOULD_BANKRUPT`) from round 25; nothing taken by the probe's round-160 cap |
| 25,000 | Sol Central taken round 24; Titan refused from round 46; nothing more by round 160 |
| 40,000 | Sol Central round 24, Titan round 46; Ares refused from round 77, taken only at round 136 and the corp is insolvent (net worth -146,680) |
| 55,000 | Monopoly at round 79, but net worth -5,763: insolvent, so the filing would forfeit the lot |
| 70,000 | Monopoly at round 79, net worth **+6,835** |
| 85,000 | Monopoly at round 79, net worth +19,434 |
| 100,000 | Monopoly at round 79, net worth **+32,031**, CR 116,030, total debt 83,999 |

So a monopoly that survives needs about **70,000 CR in hand when the chain starts**, and the net worth left at the end is roughly what the player had above 63,000 to 68,000 (rent flows in during the chain). **I did not measure how long it takes to earn 70,000 CR**: nothing in the repo plays the trading game. It is the largest assumption in this section, and it moves the whole schedule: every round spent earning the capital is a round off the 41.

### 7.2 Modelled: the haul

Ideal play, no hazards, no audit cap, no crisis modal, no waiting. The hold is 100 units, so a phase of 200 units is two holds. Routes: Earth-Luna 1, Earth-Mars 2, Luna-Mars 2, Mars-Ceres 2.

| Phase | Route (rounds) | Total |
|---|---|---|
| 1 at Luna (start Mars) | Mars buy MACHINERY -> Luna 2; Luna -> Mars 2, buy ORE -> Luna 2 | **6** |
| 2 at Earth (start Luna) | Luna buy FUEL -> Earth 1; Earth -> Mars 2, buy MACHINERY -> Earth 2 | **5** |
| 3 at Mars (start Earth) | Earth buy FOOD -> Mars 2; Mars -> Earth 2, buy FRAG -> Mars 2 | **6** |
| 4 at Ceres (start Mars) | Mars buy MACHINERY -> Ceres 2; Ceres -> Mars 2, buy ORE -> Ceres 2; Ceres -> Mars 2, buy FUEL -> Ceres 2 | **10** |
| | | **27** |

The Earth-Mars alignment window (period 8, offsets 4 and 5, 50% transit cut, `transit.gd`) can only shorten this; the figures ignore it.

Clock-rounds consumed with the Stabiliser Field (each phase's rounds times the `keep_bps` in force while it is hauled; Phase 1 at 1.0, Phase 2 at 0.6, Phase 3 at 0.35, Phase 4 at 0.15):

`6 x 1.00 + 5 x 0.60 + 6 x 0.35 + 10 x 0.15 = 6 + 3 + 2.1 + 1.5 = 12.6`

Against what is left when the monopoly lands, scaled by how much slower than ideal the player is (`k`; k = 1 is ideal, k = 2 means twice the rounds on every leg):

| Monopoly lands | Clock-rounds left | Fits with the field up to | Fits without the field up to |
|---|---|---|---|
| Round 79 (measured floor) | 41 | **k = 3.25** (41 / 12.6) | k = 1.5 (41 / 27) |
| Round 90 | 30 | k = 2.4 | k = 1.1 |
| Round 100 | 20 | k = 1.6 | no |
| Round 110 | 10 | no (k = 0.8) | no |

Read it this way. A strong run, defined as "holds 70,000 CR early enough that the monopoly lands by round 90", finishes the project even at **2.4 times** the ideal route time. Without the field it would need to be within 10% of perfect. Round 100 is the edge of "winnable by a good player", round 110 is not, and that is the intended climax shape: the late baron is a race, not a stroll. A player who wants slack should not wait for round 79.

Burn check at k = 2 (54 haul rounds) from round 79: debt grows about 460 CR a round while the clock is at full speed (CRITICAL) and about 70 to 280 CR a round at the later `keep_bps`; rent is 1,350 a round throughout. Debt growth stays under the rent, so the project's own spending (fees and goods) is what lowers net worth, not the clock.

### 7.3 What is not measured

Trading-up time to 70,000 CR; rival-fleet bidding (the probe removed the fleets, so lots can be taken slower in a real world); raids and front-runs on a loaded hold; crisis modals; audit caps (`trade_cap_qty`) which could limit a purchase per round; the real distribution of player efficiency `k`. Section 11's task 5 is a headless bot that measures `k` and the trading-up time so the placeholders in `rescue.json` get a number to move, as epic3 task 12 did for the barons.

## 8. Failure modes and Ryan's rule

**Ryan's rule (from epic3 section 7, restated): only the player's choices can end a run.** For the project that means a random event must not lose progress, refuse a delivery or touch the clock.

| Threat | Rule |
|---|---|
| Random crises (`origin: random`) | Cannot change `keep_bps`, `phase`, deposits or the sites' embargo. Crises never touch doomsday ticks today (epic3 section 1) and the project adds no crisis effect that does. |
| Random baron events | Moot after the monopoly (a held baron takes no heat and posts no events); the lethal guard stays as the backstop. |
| The random margin-call drain | Today it can drain CR with no solvency guard (`run_controller.gd:710-720`) and so can trip an automatic Chapter 11, which forfeits the barons. **While a project is open, the drain is clamped so it cannot by itself make `Chapter11.assess` insolvent** (the same shape as `Barons.penalize(.., "random")`). Task 2 includes it. This is the only existing code path a random event could use to hurt the project, so it is the one gap closed. |
| Raids on a loaded hold (rival `privateer_sponsor` bounties) | They come from rival AI, not from the player's choice, so they are treated as random for this rule. **A raid on a hold carrying project goods settles as ransom only**: never seizure, ransom floored at the CR held. A bounty the player earned through heat is a consequence and keeps the full cargo loss (after the monopoly the player holds every baron, so this is rare). |
| Deposits | Monotonic. No event, crisis, filing or fleet removes a delivered unit. |
| The fee | Refused if it would leave the corp insolvent (`WOULD_BANKRUPT`), so the player's own spending can never put them in Chapter 11 through the project. |
| Rival fleets | Cannot deliver, block or buy the project's stock; the embargo is a book mod, not an order. A front-run still dents depth for two rounds (`rivals.front_run_*`), which can cost a trip's price, not progress. |
| The clock | The only way the run ends against the player. It is the player's pace. |

What **can** go wrong, and is the player's choice: slow routing; buying near and dear until CR is short; spending past the solvency line elsewhere so a fee is refused; filing Chapter 11 (Question 5); not starting. Each of those is a decision visible on screen before it bites (section 9, UI).

## 9. UI surfaces (HUD v3, reused)

No new widget kinds. Everything is built from the components in section 1.

- **Project panel.** The card region (`HudLayout.CARD_RECT`) shows a Stabiliser card at any station while the project is open, built like the baron sidebar: `M0Loop.rescue_lines(station)` returns `{kind: "chip"|"line", text, tone}` rows (`takeover_lines`, `m0_loop.gd:719`, is the template) with a new `rescue` tone mapped to the theme's teal. Rows: the phase title and site ("PHASE 2 OF 4  COIL FOUNDRY  EARTH"), one `kv` per need ("MACHINERY 40 / 100"), the fee left ("FEE 3,100 CR LEFT"), the field ("CLOCK 60%"), and, docked at the site with the right cargo, the prompt row `[pad_glyph] DELIVER 100 MACHINERY  -2,500 CR`.
- **Delivery chips.** `HudKit.tag` chips on the order ladder header: `NEEDED: ORE` on a book whose commodity the open phase needs and whose station is not its site; `SITE: NO ASK` on the site's embargoed asks; `PIPELINE (YOURS)` already exists. On the map, the open phase's site gets the same label chip as the existing baron anchors. A refused deposit raises a `ToastTray` `rejected` toast with the reason.
- **Ticker lines.** `post_headline_tr` keys `HL_RESCUE_OPEN`, `HL_RESCUE_DELIVER`, `HL_RESCUE_PHASE`, `HL_RESCUE_FIELD` ("STABILISER FIELD UP: DOOMSDAY CLOCK AT 60% SPEED"), `HL_RESCUE_REFUSED`, in the `CRISIS` and `MARKET` categories as the existing baron headlines do.
- **Header.** The doomsday readout gains a `CLOCK 60%` suffix once `keep_bps < 10000`.
- **Modals.** The monopoly modal's A now opens Phase 1 and its body names the first site. `OVERLAY_RESCUED` (win) is wide and teal. A phase completion is a toast and a ticker line, not a modal: the clock keeps running.
- **Localization.** Every string is an `agora_strings.csv` key; `test_localization` and `test_i18n_audit` gate each UI task (epic3 constraint 7).

## 10. Determinism and saves (matching epic3 section 6.3)

- The project is a pure function of `(player deposits, tick)`. It adds **no RNG at all**: no draws, no `Bags`, no fresh `NativeDrawSource`. The embargo and the field are derived from saved phase state; the player's `m0_project` presses are the only input and replays already record player actions (`world_golden.gd` dispatches `M0Loop.ACT_*`).
- State is `RescueProject.to_dict()` / `from_dict()`: `phase` (int), `deposits` (`{commodity: int}` for the open phase), `fee_paid` (int), `completed` (`[phase id, round]` pairs), `keep_bps` (int), `opened_round`. Integers and strings only; all dictionaries iterated in sorted key order.
- It lives on `RunController.rescue` (null until the monopoly opens it), saved under a new `rescue` key in `RunSave.capture`, **present only when a project is open or done**, copying the `crisis` and `world` pattern (`run_save.gd:30-38`). No `schema_version` bump. A run that never reaches the monopoly captures byte-identical state, so every pinned hash stays.
- `MetaProfile.rescues_completed` is read with default 0 and saved only when non-zero. `Parachutes.award_severance` takes a defaulted `rescued` argument.
- `counts_tick` is a pure integer function of the absolute sim tick and `keep_bps` (section 5.1): the same save at any tick restores to the same future.
- New goldens: `counts_tick` over a tick range for each `keep_bps`; the mod fold order with the embargo; a scripted-player project run (deposits at the right sites) hashed for two seeds; save mid-phase / JSON round trip / restore / continue equal to the uninterrupted run; a filing mid-project that keeps progress and ends the rent bonus.

## 11. Implementation plan

Sizing follows the house format: a specced Sonnet build is 5 to 15 minutes and 0.1 to 0.2%, a medium one 20 to 30 minutes and 0.3 to 0.5%. Total for the plan: about 100 minutes, ~1.5% of the weekly limit. Each PR is Sonnet-built in a worktree with scoped Godot tests only (no full-project build); each UI task adds `agora_strings.csv` keys.

| # | Task (one PR each) | Estimate |
|---|---|---|
| 1 | **Core.** `game/core/rescue_project.gd` and `game/data/rescue.json` with loader/validator; phases, deposit with pro rata fee and refusals, completion, `to_dict`/`from_dict`, `counts_tick`; `RunController.rescue` and the `rescue` key in `RunSave`; `MetaProfile.rescues_completed`. Unit tests for the arithmetic and the hash-unchanged-without-a-project test. | ~25 min agent time · ~0.4% of the weekly limit |
| 2 | **Clock, win and guards.** The `counts_tick` gate in `_on_sub_ticked`; `finish_rescue`, `is_run_over`, `end_run("rescued")`; `Parachutes` rescue Severance and phase consolation; rent multiplier in `Takeover.rent`; project-open clamp on the random margin-call drain; raid-as-ransom rule; Chapter 11 keeps progress and drops the rent bonus. | ~25 min agent time · ~0.4% of the weekly limit |
| 3 | **Loop wiring.** `m0_project` action (`ACT_PROJECT`) and `M0Loop` handler; embargo world mods emitted after rival mods with the fold-order fixture; open on the monopoly continue; pledge of a held baron's warehouse stock at the site; GalNet events. | ~20 min agent time · ~0.3% of the weekly limit |
| 4 | **UI.** `rescue_lines`, the Stabiliser card, delivery chips, header suffix, toasts, `OVERLAY_RESCUED` modal and its summary rows, achievement and stat entries, localization keys, a `shots_epic3_rescue.gd` screenshot script. | ~25 min agent time · ~0.4% of the weekly limit |
| 5 | **Goldens, bot, tuning, guide.** Whole-run golden with a scripted rescue (two seeds, save/restore), a headless pacing bot that measures trading-up time and the `k` of section 7, `docs/game-guide.md` note, and the placeholder pass on `rescue.json`. | ~12 min agent time · ~0.2% of the weekly limit |

Order: 1 -> 2 -> 3 -> 4, then 5. Tasks 2 and 3 can run in parallel worktrees once 1 lands. Balance numbers in `rescue.json` are placeholders until task 5.

## 12. Questions for Ryan

1. **How should each finished phase help against the clock?**
   - (a) **Staged slowdown**: the clock runs at 60%, then 35%, then 15% of speed as phases finish, stopping at the win. The player can see the pressure ease as they build.
   - (b) **Stop the clock on the first phase.** Simple, but after Phase 1 nothing can go wrong and Phases 2 to 4 become a victory lap.
   - (c) **No slowdown**: pure race against 41-ish rounds. By the numbers a player must be within 50% of perfect routing even in the best case, and within 10% if the monopoly lands at round 90.
   - **Recommend (a).** It turns the 41 rounds left into room for a player who is up to 3 times slower than ideal, and the late phases still feel like a final push.

2. **When does the project open?**
   - (a) **Only after all three barons** (your earlier decision). The fastest measured monopoly is round 79, so the project gets at most 41 rounds.
   - (b) **Phase 1 opens at two barons**, later phases still need all three. Lets the player start hauling while the last takeover plays out.
   - (c) As (a), but lengthen the run past 120 once the monopoly lands.
   - **Recommend (a)**, with (b) as the fix if playtests show the monopoly landing after round 90. The numbers say (a) works for a strong run; I could not measure how long earning the 70,000 CR needed for the chain takes.

3. **What does a failed rescue pay?**
   - (a) Nothing extra: the normal collapse.
   - (b) **A small consolation** per finished phase (100 Severance each), so a near miss still feels like progress.
   - (c) Full credit for any phase finished.
   - **Recommend (b).** Enough to feel fair, too small to farm.

4. **What does a rescued run unlock?**
   - (a) **Bonus Severance plus a "Sol Rescued x N" counter and an achievement**: bragging rights, no power.
   - (b) Bonus Severance plus a permanent perk that makes the next project cheaper.
   - (c) Bonus Severance only.
   - **Recommend (a).** A project discount would make the second win easier than the first and the climax stops being a climax.

5. **If the player files Chapter 11 mid-project, what happens to the project?**
   - (a) **Progress stays** (it belongs to Sol, not the corp); the barons revert, cash and cargo are lost, the rent bonus ends. A new corp can finish the job the hard way.
   - (b) Progress resets to the last finished phase.
   - (c) The project is lost and the run is effectively over.
   - **Recommend (a).** It matches "every corp lives in the same Sol", and filing is already a heavy penalty without also deleting hours of hauling.

## 13. What this doc does not decide

The name of the machine (Stabiliser vs Dyson Swarm: data only); the phase sites, bills and fees (placeholders, task 5 tunes them against a measured `k`); the exact face button for `m0_project`; whether rival fleets should ever compete for the same stock. None blocks tasks 1 and 2.
