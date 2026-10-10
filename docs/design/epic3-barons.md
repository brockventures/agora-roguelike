# Epic 3 design: Sector Barons, regional monopolies, rival fleets

Design proposal for #15 (Design Sector Baron Framework & Regional Monopoly Mechanics), part of #14 (Epic 3: Planetary Sector Barons & Rival Syndicate AI). It feeds #16 (Implement Baron Archetype AIs), #17 (Implement Hostile Takeover & Baron Insolvency Settlement) and #18 (Implement Autonomous Roving Syndicate Competitor Fleets), and is input to #19 (Epic 3 Review Gate).

**Status: decided 2026-10-09** (section 9). Ryan signed off the design calls. Every section separates what the code already does (**Grounded**, with `file:line` from `main` at `beef638`) from what this doc invents (**Proposed**). Nothing here is game code. "Python sim" means `agora/*.py` in `brockventures/market-sandbox` (read at `30a301f`); this repo's `agora/` matches it except `server.py`.

## 1. What exists today (Grounded)

| Fact | Where |
|---|---|
| One counterparty. Every resting order, on every book, is made by `MAKER_ID = "ares_heavy"`. Earth's books are Ares Heavy's too. | `game/core/station_market.gd:21`, `_maker_order` :229 |
| Only `earth` and `mars` have books; the M0 loop locks the player to Mars (Arcadia Foundries). `Transit.STATIONS` also has `luna`, `ceres`. | `station_market.gd:14`, `game/core/transit.gd:10`, `game/tests/test_m0_scope.gd` |
| Books are IOC-only for the player and are **fully reseeded every round** from `Transit.BASE_PRICES` plus mods. Anything done to a book by trading is erased at the next boundary. | `station_market.gd:59` (`seed_book`), :128 (`replenish`), `game/ui/m0_loop.gd:635` |
| Book mods are `{station, commodity ("*" ok), depth_bps, price_bps, spread_bps}`. `_mods_for` multiplies depth and spread with integer division **one mod at a time**, so order matters. | `station_market.gd:115` |
| Round-boundary order: `RunController._on_sub_ticked` resets the audit cap, runs `_advance_crisis_deck` (draw, expiry, margin call), emits `round_advanced`; `M0Loop` then calls `market.replenish()`. The market lives on `M0Loop`, not on `RunController`. | `game/core/run_controller.gd:515,526`, `m0_loop.gd:635` |
| Crisis deck: Bags roll for fire/no-fire (`tier:band` key), then a `NativeDrawSource` seeded `hash32("crisis-pick-<seed>-<round>")` for the pick. No RNG state outside Bags. Saved under `RunSave` key `crisis` **only when a deck is attached**. | `game/core/crisis_deck.gd:153`, `game/core/run_save.gd:20` |
| Crisis effects today: depth/price/spread mods, an order cap + fee, and `margin_call_bps` (drains CR, capped at CR held, `run_controller.gd:526`). None touches doomsday ticks. | `game/data/crises.json`, `crisis_deck.gd` |
| Run length: 36000 ticks at 900 ticks/round is **40 rounds at 1x**. The run ends only on doomsday collapse; Chapter 11 founds a new corp in place. There is no victory condition anywhere in `game/`. | `doomsday_clock.gd:47`, `run_controller.gd:36,199` |
| `Chapter11.assess(snapshot, haircut_bps)` takes `{cr, cargo, ships, doomsday}` and returns `insolvent`, `shortfall`, `liquidation_value`. The doomsday part may be a plain dict with `principal_debt`, `accrued_interest`, `accrued_burn`. Haircut 50%. | `game/core/chapter11.gd:34` |
| World vs corp seeds: `corp_seed(n)` is for per-corp randomness; `run_seed` never changes on filing, and "every corp lives in the same Sol (same doomsday clock, rivals, markets)". | `run_controller.gd:221` and its comment |
| Severance: `filings * 100 + 0.5% of peak net worth`. Perk tree in `game/data/parachutes.json`; `hostile_buyout_line` (Monopoly Drive, tier 3) is `enabled:false` with `effects: []`. | `game/core/parachutes.gd:290`, `parachutes.json:122` |
| Piracy is ported including privateers: `hire(sponsor, target, round, available_cr)`, `PRIV_COST = 750`, 20 rounds, +0.15 raid odds, read by `chance()` through `active_contract`. | `game/core/piracy.gd:37,267,552` |
| Determinism tooling: `StableHash.hash32` (SHA-256), `DrawSource`/`NativeDrawSource`, `RunSave.state_hash` over canonical JSON, replays record player inputs only. | `stable_hash.gd`, `draw_source.gd`, `run_save.gd`, `replay.gd` |

**Gaps (not features).** None of these exist in `game/`:

- **Docking toll.** Only the belt toll (`BELT_TOLL_CR = 25`, `transit.gd:53`). The Python sim has station tariffs: `agora/lobbying.py:get_docking_tariff` and the arrival charge at `agora/referee.py:2147-2155`.
- **Short positions, loans, equity, call auctions.** The player only holds cargo and CR. The Python sim has them in `agora/equity.py`, `agora/corporate.py`, `agora/circuit_breaker.py`.
- **A Titan station**, and ~~play on any station but Mars~~ (travel is wired into the M0 loop by task 0, #111 (Epic 3 task 0: travel loop between stations); Titan is still absent).
- **Delivery contracts.** `MetaProfile.contracts` is an opaque meta list (`meta_profile.gd:13`), not an obligation. `agora/contracts.py` is the only source and was not ported.
- **A fuel market or hazard/piracy rolls in play.** `Transit.calculate_fuel_burn`, `Hazards.roll` and `Piracy.roll_departure` have accessors on `RunController` (`fuel_discount_bps()` etc.) but I found no caller outside `core/` accessors and tests. `Parachutes.STATS` marks every stat `live`, yet `corrupt_regulator`'s `interest_bps` is the only perk with an effect a player can see in M0 (it changes doomsday interest). The brief's "perks waiting for loans, fuel market, corridors" matches this: the stats are wired, the surfaces that use them are not.

## 2. Architecture constraints every section below obeys

These come from section 1 and are the places an Epic 3 implementation would otherwise break replays.

1. **Persistence cannot live in the book.** `replenish()` erases it. Baron and rival effects are therefore **state in a world object that re-emits mods each round**, never edits to resting orders. Player market impact (the margin lever) is a decaying per-commodity `pressure_bps` accumulator in baron state, fed by the trades `StationMarket.execute` already returns.
2. **Step order (Proposed).** `_advance_crisis_deck` (existing) -> `round_advanced` -> in `M0Loop._on_round_advanced`: `world.advance_round(round, controller, market)` (barons sorted by id, then rival fleets sorted by id) -> `market.set_world_mods(world.market_mods())` -> `market.replenish()`. A bare `RunController` has no world, exactly as it has no crisis deck.
3. **Fixed fold order.** `_mods_for` folds `world_mods` first (barons by id, then rivals by id), then `crisis_mods`. Because depth and spread use per-step integer division, this order is part of the replay contract and gets a golden test.
4. **Hash stability.** With no `barons.json` loaded: `MAKER_ID` and `seed_book` behave byte-identically, `RunSave.capture` adds no key, no `schema_version` bump (`SaveStore` rejects other versions, never migrates). The `world` key is present only when attached, copying the `crisis` pattern. Any new `MetaProfile` field is read with a default when missing.
5. **Seeds.** Barons and rivals are world state: seed from `run_seed` (`StableHash.hash32("baron-<id>-<run_seed>-<round>")`), never `corp_seed`.
6. **Integers and sort order.** Money and bps are ints; any dictionary iterated for a decision is iterated in sorted key order; no wall-clock reads.
7. **Text.** Every new player-facing string needs `game/localization/agora_strings.csv` keys or `test_localization` and `test_i18n_audit` fail. Each UI-touching task in section 8 includes this.

## 3. Baron framework (for #15, Baron Framework design)

### 3.1 Data model (Proposed)

`game/data/barons.json`, loaded like `crises.json` (`CrisisDeck.load_data` pattern). Godot parses every JSON number as a float, so all reads go through `int()`.

```json
{
  "version": 1,
  "_placeholder": "Every number is a tuning guess for Ryan, in CR / bps / rounds.",
  "victory": {"barons_required": "all"},
  "takeover": {"float_shares": 1000, "threshold_shares": 501, "auction_cap": 100,
               "auction_discount_bps": 7000, "bankrupt_rounds": 6},
  "heat": {"decay_per_round": 1, "retaliation_at": 6},
  "barons": [
    {
      "id": "ares_heavy", "name": "Ares Heavy", "archetype": "short_squeezer",
      "anchor": "mars",
      "treasury_cr": 60000, "treasury_shares": 600, "upkeep_cr_per_round": 400,
      "inventory": {"ORE": 300, "MACHINERY": 200}, "margin_debt_cr": 9000,
      "privileges": {
        "docking_toll_cr": 15,
        "toll_exempt": ["ares_heavy"],
        "pipelines": [
          {"commodity": "ORE", "depth_bps": 16000, "outsider_ask_bps": 800},
          {"commodity": "MACHINERY", "depth_bps": 14000, "outsider_ask_bps": 800}
        ]
      },
      "params": {
        "squeeze_window_rounds": 3, "squeeze_price_bps_max": 5000,
        "squeeze_depth_bps": 3000, "contract_every_rounds": 8,
        "contract_qty": [30, 60], "contract_bid_bps": 1500, "contract_penalty_bps": 2000
      }
    },
    {"id": "titan_cryo_hydro", "name": "Titan Cryo-Hydro", "archetype": "hoarder",
     "anchor": "ceres", "...": "same keys; params: float_commodities, hoard_trigger_depth_bps, hoard_cap_qty, release_after_rounds, corner_premium_bps"},
    {"id": "sol_central", "name": "Sol Central", "archetype": "auctioneer",
     "anchor": "earth", "...": "same keys; params: auction_every_rounds, rig_bps_max, indicative_leak"}
  ]
}
```

Runtime state (`BaronState`, saved under `world.barons`): `treasury_cr`, `treasury_shares`, `inventory`, `margin_debt_cr`, `debt_cr`, `strain` (consecutive insolvent rounds), `pressure_bps{commodity}`, `heat` (player-caused, see 6.2), `holder` (`""` baron, `"player"`, or a rival id), `shares{holder}`, plus archetype scratch fields (squeeze countdown, hoard age, auction buffer). Integers and strings only, so `to_dict()`/`from_dict()` round-trip through JSON the way `CrisisDeck` does.

### 3.2 Anchoring a station

A baron **anchors** one station: its id replaces `MAKER_ID` for that station's books (`maker_for(station)`; unanchored stations keep `ares_heavy`, so M0 behaviour and hashes are unchanged until `barons.json` is present). Anchoring gives it three things: the maker identity on the book, the arrival toll, and the pipeline depth. Mars -> Ares Heavy, Earth -> Sol Central keep the current station names (Arcadia Foundries, Kennedy Elevator). Ceres is Titan's (see Question 3).

### 3.3 Monopoly privileges and how they show

- **Docking toll exemption (Proposed, ported from `lobbying.py`/`referee.py:2147`).** On arrival at an anchored station, anyone not in `toll_exempt` pays `docking_toll_cr` to SYSTEM, capped at CR held (the Python sim caps the same way). Rival fleets pay it too, so the toll is the baron's lever on competitors, not only the player. Holding the baron (section 5) puts the player in `toll_exempt`. Needs the travel loop (plan task 0).
- **Exclusive supply pipelines (Proposed).** For each `pipelines` entry the anchor's ask-side for that commodity gets `depth_bps` more depth, and **outsiders** pay `outsider_ask_bps` more on the ask. Insiders (baron, holder, fleets the baron allies with) see the base price. This needs a side-specific price field on mods (`ask_price_bps`, absent = 0, so existing mods are untouched); today a mod shifts bid and ask together.
- **In the order book.** `StationMarket.ladder()` rows gain `maker` (the participant id when one maker owns the level, else `""`) and the book tag line gains `ARES HEAVY PIPELINE +8% ASK` using the existing `CrisisDeck.tag_for`-style tag slot. `counterparty_name()` (today hardcoded to Ares) reads the world registry, so fills announce `SOL CENTRAL` where they do today for `ARES HEAVY`. A held baron shows `HELD` and `PIPELINE (YOURS)`.
- **Tuning rule.** A pipeline must make the anchor's own commodity cheap to *buy in volume* for insiders and expensive for outsiders, so holding a baron is a visible arbitrage edge worth the 40-round chase.

## 4. Archetypes (for #16, Baron Archetype AIs)

All three are **rules over existing primitives**: they read state, then emit `market_mods`, `BaronState` changes and headline strings. RNG is limited to magnitude and tie-break draws from `hash32("baron-<id>-<run_seed>-<round>")`; fire/no-fire timing that should feel fair goes through `Bags` keyed `baron:<id>`, like piracy and the crisis deck.

### 4.1 Ares Heavy (Mars): short squeezes and defense contracts

- **Defense contract (Proposed).** Every `contract_every_rounds`, Ares posts one contract: deliver `qty` of ORE or MACHINERY to Mars within N rounds for a bid wall `contract_bid_bps` above mid. The player may accept. This is a new obligation record in `BaronState`; it is *not* `MetaProfile.contracts`, and the Python `agora/contracts.py` needs reading before any further port. A missed delivery adds `contract_penalty_bps` of its value to doomsday principal debt (the only debt the player has).
- **Squeeze (Proposed).** The game has no short positions, so the squeezable exposure is the **open contract**. Rule: while an accepted contract has <= `squeeze_window_rounds` left and the player holds less than the remaining quantity, Ares emits a Mars mod for that commodity of `depth_bps = squeeze_depth_bps` and `price_bps = min(squeeze_price_bps_max, 1000 * rounds_short)`. This is the same shape as `localized_shortage`, so the HUD already renders it.
- **Determinism.** No RNG in the trigger. The contract's commodity and quantity use the per-round `DrawSource`.
- **Counterplay.** Stock cargo (from Earth or Ceres) *before* accepting; decline when Mars books are thin; deliver early. Squeeze price is capped, and a delivered contract pays a premium, so a prepared player profits. A counter-corner of Ares's pipeline commodity (section 5) also starves it of fulfilment stock.

### 4.2 Titan Cryo-Hydro (Ceres): cornering volatile commodities

- **Volatile set.** FUEL and FOOD: widest cross-station spread (`Transit.BASE_PRICES`: FUEL 8.5-24.5, FOOD 10.2-27.5) and FOOD is the perishable (`Transit.PERISHABLE_COMMODITIES`).
- **Rule (Proposed).** State machine per commodity: `idle -> hoarding -> cornered -> releasing`.
  - `idle -> hoarding` when the anchor ask depth is <= `hoard_trigger_depth_bps` of nominal and treasury covers a round's buy.
  - `hoarding`: each round Titan removes up to `hoard_cap_qty` units of ask depth (a `depth_bps` mod, since it cannot edit the book) and adds the units to inventory, paying the ask from treasury.
  - `cornered` once inventory >= its corner share of system supply: the ask side is thinned and priced `corner_premium_bps` over mid.
  - `releasing` after `release_after_rounds` or when treasury strain trips: depth floods and price falls, which is also the margin-lever opening for the player (4.1/5.2).
- **Determinism.** Pure function of book depth, treasury and age. The only draw is the hold length jitter (+/- 1 round).
- **Counterplay.** The corner is an arbitrage signal: haul the commodity into Ceres and sell into the premium. Hoarded FOOD decays, so waiting works against Titan. A held player stock of the corner commodity drains Titan's treasury (lever 5.2a). `fuel_hedge` (`fuel_discount_bps` +1000) makes FUEL corners cheaper to survive once fuel is bought in play.

### 4.3 Sol Central (Earth): rigged call auctions

- **Auction (Proposed port).** Every `auction_every_rounds`, Earth runs a call auction for one commodity: orders collected in the round uncross at one price, `find_clearing_price(bids, asks, ref_price)` ported from `agora/circuit_breaker.py:43` (maximise matched volume; ties by distance to `ref_price`, then lower price). Fills respect limit prices. The player's IOC orders at Earth during an auction round go into the buffer instead of sweeping the book.
- **The rig.** Sol Central controls `ref_price` (it prints the reference) and injects a balanced bid/ask pair at the tie edge so the volume-maximising price lands up to `rig_bps_max` toward its own inventory side. The shift is deterministic: it picks the candidate price inside `rig_bps_max` that maximises its own mark-to-market, ties by lower price.
- **Determinism.** No RNG in the clearing. The buffer is sorted by `(limit_price, seq)`.
- **Counterplay.** The player sees an **indicative price** before the auction closes (`indicative_leak`: full, or delayed by one round on a perk). A limit order simply does not fill outside the rigged price, so a disciplined player loses only the missed trade. Orders can be withdrawn until close. Rigged magnitude is shown as indicative-vs-last, so the rig is legible. Holding Sol Central ends the rig and hands the player `ref_price`.

## 5. Takeover and insolvency (for #17, Hostile Takeover & Insolvency)

### 5.1 What the Python sim does (Ported source)

`agora/corporate.py`: distressed corps auction treasury shares at 0.7 x max(NAV, mark, 10) up to 100 a round (`AUCTION_CAP`, `DISCOUNT`, `PRICE_FLOOR`); 51% (`live_shares // 2 + 1`) of a corp's stock absorbs it (`_takeovers`, :502); bankruptcy after `BANKRUPT_ROUNDS = 10` indebted rounds with no treasury shares (:36); predatory loans at 20% default interest, due in 5 rounds, whose default adds the due amount to corporate debt (`create_loan_offer` :1025, `_check_loan_maturities` :1234); tender offers and a poison pill at >30% stake (:606, :736). Margin: 120% initial, 105% maintenance, forced liquidation below it (`agora/equity.py:50`, `liquidate_loan`). The game guide notes a raider "can't reach 501 from the market alone" at live defaults, which is why distress is the real route.

### 5.2 Three levers (Proposed)

The baron has `float_shares` (1000), most of them in its own treasury. The player gains shares only through the distress auction (up to `auction_cap` a round at a discount, split by cash with rival fleets) or by tendering for rivals' stakes. So each lever is a way to **make the baron distressed**.

- **a. Corner its float.** If the player holds >= the baron's corner quantity of its `float` commodity at the anchor, the baron must buy cover at squeezed prices each round: `treasury -= shortfall_qty * squeezed_ask`. The player pays carry (capital tied up, FOOD decay).
- **b. Margin liquidation.** Collateral value = inventory marked at the anchor mid after `pressure_bps`. Below the 105% maintenance ratio against `margin_debt_cr`, the baron force-sells a fraction of inventory into its own book (a price-crash mod for 2 rounds, haircut 50%), burning treasury. The player triggers it by dumping the collateral commodity at the anchor; the pressure decays by integer halving each round, because `replenish()` would otherwise erase it.
- **c. Predatory credit.** The player offers a credit line (default 20% interest, due in 5 rounds). A baron accepts only above a `strain` threshold. If treasury < due at maturity it defaults: the due amount joins `debt_cr`. This is the first loan product in the game.

### 5.3 Insolvency and settlement (Proposed)

- Baron solvency uses **`Chapter11.assess`** on `{cr: treasury, cargo: inventory, ships: [], doomsday: {principal_debt: debt_cr}}`, so one definition of insolvent covers player and barons, 50% haircut included.
- Insolvent for `bankrupt_rounds` (6 here, 10 in the Python sim, because the run is 40 rounds) with no treasury shares left -> **bankrupt**: inventory liquidates at the haircut, proceeds pay creditors pro rata by claim, the largest claim holder (ties: sorted id) becomes `holder`.
- 501 shares -> **takeover** at once (Python `_takeovers`): the raider absorbs treasury, inventory, debt and credit claims; a loan the raider itself made cancels out (Python does the same).
- On either outcome the holder gains the privileges (toll exempt, pipelines) and **rent**: the anchor's maker spread accrues to the holder each round (Proposed; the rate is a tuning number).
- **Filing Chapter 11 forfeits holdings.** A filing founds a new corp, so held barons revert to NPC control with treasury reset to 40%, deterministically. The world and its seeds persist (section 2.5).
- **`hostile_buyout_line`** (disabled today) becomes the lever perk: enabling it adds a `takeover_threshold_shares` stat of -50 and unlocks tender offers. New stat, so it joins `Parachutes.STATS` as `pending` until #17 (Hostile Takeover & Insolvency) lands.

### 5.4 The win condition this gives a run

**Decided (Ryan, #lounge 2026-10-09 23:02 PT): the original design stands.** Victory means taking over **every** competing baron and station, as agreed when Epic 3 was filed (#14, Epic 3: Sector Barons; #32, the Sol System Rescue climax). Owning everything is phase 1. The run is won by spending the monopoly on the Sol System Rescue Project before the doomsday clock hits zero (#32). `victory` in `barons.json` becomes `{"barons_required": "all"}` with no hold timer; the rescue project's win check belongs to #32. The earlier 2-of-3 proposal is withdrawn. Run length (40 rounds at 1x) is a tuning concern for later, per Ryan's M0 direction (#34): build toward the final design.

## 6. Rival fleets (for #18, Rival Syndicate Fleets)

### 6.1 Model (Proposed)

`RivalFleet`: `id`, `cr`, `cargo`, `route` (origin, dest, arrival round), `trait`, `stance`. Fleets are abstract (no ships array) and trade via a generalised `StationMarket.execute_as(participant_id, ...)`; today `execute` hardcodes `PLAYER_ID` and `"player-%d"` order ids. They run `Transit.get_route` and `calculate_trip_rounds` for timing and use `Piracy.hire` for bounties, so they cannot do anything the player cannot.

- **Spatial arbitrage.** Each idle round a fleet scores every route by `(dest_mid - origin_mid - fuel_cost - toll) * qty` using book mids, picks the best, sorted-id tie-break, and departs. Alignment windows (`Transit.get_alignment_windows`) are public, so fleets exploit them predictably.
- **Front-running (trait `front_runner`).** When the player departs with cargo of value >= a threshold, any `front_runner` that can arrive at the destination in <= the player's trip rounds *and* has cash pre-positions: it emits a destination mod (`depth_bps` down on the commodity for 2 rounds) and a GalNet line on arrival. It can only react to the player's **departure** (treated as public: the tactical map projects fleet transit positions, `game/ui/sol_tactical_map.gd:6`; not verified in play); it cannot read resting orders, because the player has none (IOC only).
- **Privateer bounties (trait `privateer_sponsor`).** If a haul's `Piracy.cargo_value` >= `VALUE_REF` (10,000 CR), the cargo is unescorted and the route is a belt lane, a fleet with >= `PRIV_COST` (750, per code) calls `hire(rival_id, "player", round, cr)`. Effect is the existing +0.15 raid odds for 20 rounds. The player can see it via the existing "secret until traced" `PRIV_TRACE` roll, or buy escorts (-75% odds). The player may sponsor against rivals the same way.

### 6.2 Heat

Player actions that hurt a baron (levers a/b/c, bounties) raise that baron's `heat`; it decays 1 a round. At `retaliation_at` the baron queues a **consequence** event (section 7). Rivals' bounty targeting reads the same heat. Heat is per corp: a new corp (Chapter 11) starts at 0, since the world survives but the grudge belongs to the failed corp.

### 6.3 Determinism for replays and save hashes

- Fleets and barons are pure functions of `(run_seed, round, world state, player state)`. Replays record player inputs only (`replay.gd`); the AI re-derives identically, so no AI input is ever recorded.
- All decisions use sorted ids and integer bps. Per-fleet draws use `hash32("rival-<id>-<run_seed>-<round>")` into a fresh `NativeDrawSource`, so there is no persistent stream that a skipped round could desync.
- The world state is serialised under the `world` key, present only when attached; `state_hash` covers it via `canonical()`. New golden fixtures (`tests/golden/world/`) pin: mod fold order, a 40-round baron+rival run hash for two seeds, and a save-at-round-N/restore/continue hash equal to the uninterrupted one.

## 7. Interactions with Epic 2 (#8, Epic 2) and the crisis deck

- **Severance (#11 Golden Parachutes).** Breaking a baron banks `SEVERANCE_PER_BARON` into the profile, awarded at run end through `Parachutes.award_severance`'s caller (`RunController._bank_corp`), once per corp, with `peak_net_worth` unchanged. A new `MetaProfile.barons_broken` count, read with default 0.
- **corrupt_regulator.** Its `interest_bps` stat is applied to the doomsday clock only. Proposal: baron credit lines carry a `loan_rate_bps` that also goes through `Parachutes.apply_stat(modifiers, "interest_bps", ...)`, so the perk finally touches borrowing as well as doomsday interest. Without loans (today) it only trims doomsday interest.
- **fuel_hedge.** `fuel_discount_bps` is read by `Transit.calculate_fuel_burn`, which no player flow calls. Titan's FUEL corner plus the travel loop (task 0) gives it a purpose. No new stat.
- **black_market_corridors.** `piracy_odds_bps` x0.8 applies to `Piracy.chance` through `RunController.piracy_odds_bps()`. It is the natural answer to privateer bounties, and no stat change is needed. Its name suggests illicit corridors; whether it should *also* dodge docking tolls is Proposed-and-unrequested, so it is left out.
- **Random vs consequence (Ryan's rule, from the assignment brief; not written in the repo).** Random crises cannot end a run alone; player-caused ones can hit hard. Grounded: the run only ends on collapse and no crisis touches doomsday ticks, so today no crisis ends a run. But `margin_call_bps` can drain CR and trip **automatic Chapter 11**, which is not a run end but is the end of a corp.
  - **Proposed:** `crises.json` entries gain `"origin": "random" | "consequence"` (default `random`). Random baron events (e.g. an Ares opportunistic squeeze with no open contract) are clamped by a **lethal guard**: they cannot push net worth below its pre-event value minus `random_max_loss_bps`, and cannot by themselves make `Chapter11.assess` insolvent. Consequence events (heat >= `retaliation_at`, or a lever's direct fallout) bypass Bags, enter `active` directly, and are uncapped except that they still never touch doomsday ticks. Whether a *consequence* may force Chapter 11 is Question 4.

## 8. Implementation plan

Estimates use the house format; sizing follows the measured median for specced single-PR Sonnet builds (about 10 min, ~0.08%) scaled up for these being new-subsystem PRs. Total for the plan: about 215 min, ~3.1% of the weekly limit. Each PR is Sonnet-built in a worktree, scoped Godot tests only; each UI-touching task adds `agora_strings.csv` keys and passes `test_localization`/`test_i18n_audit`.

| # | Task (one PR each) | Issue | Estimate |
|---|---|---|---|
| 0 | **Prerequisite, not in any Epic 3 issue:** travel loop in play: unlock Earth/Ceres books, depart/arrive via `Transit.get_route`, belt toll, `docked_at` changes. Confirm owner before starting. **Owner: Amos. Issue #111 (Epic 3 task 0: travel loop between stations); PR #PRNUM (feat(epic3): travel loop between stations).** | #111 (Epic 3 task 0: travel loop between stations) | ~20 min agent time · ~0.3% of the weekly limit |
| 1 | `barons.json` + `Barons` loader/validator + `BaronState` `to_dict`/`from_dict`, `world` key in `RunSave` only when attached; hash-unchanged test with no barons. | #15 (Baron Framework design) | ~15 min agent time · ~0.2% of the weekly limit |
| 2 | Market wiring: `maker_for`, `world_mods` + fixed fold order, `ask_price_bps`, `execute_as`, ladder `maker` tags, registry-backed `counterparty_name`; golden fold-order fixture. | #15 (Baron Framework design) | ~20 min agent time · ~0.3% of the weekly limit |
| 3 | Privileges: docking toll on arrival, pipelines, exemption set, order-book tag strings. | #15 (Baron Framework design) | ~15 min agent time · ~0.2% of the weekly limit |
| 4 | Ares Heavy: defense contracts, squeeze mod, debt penalty. | #16 (Baron Archetype AIs) | ~20 min agent time · ~0.3% of the weekly limit |
| 5 | Titan Cryo-Hydro: hoard state machine, corner/release mods, FOOD decay link. | #16 (Baron Archetype AIs) | ~15 min agent time · ~0.2% of the weekly limit |
| 6 | Sol Central: ported `find_clearing_price`, auction buffer, rig, indicative price row. | #16 (Baron Archetype AIs) | ~20 min agent time · ~0.3% of the weekly limit |
| 7 | Takeover core: shares, distress auction, `Chapter11.assess` insolvency, settlement, hold/forfeit on filing. | #17 (Hostile Takeover & Insolvency) | ~20 min agent time · ~0.3% of the weekly limit |
| 8 | Levers: corner, margin (pressure accumulator), credit line + default; `hostile_buyout_line` enabled. | #17 (Hostile Takeover & Insolvency) | ~20 min agent time · ~0.3% of the weekly limit |
| 9 | Victory + Severance hook + summary screen state. | #17 (Hostile Takeover & Insolvency) | ~10 min agent time · ~0.1% of the weekly limit |
| 10 | Rival fleets core: `RivalFleet`, route arbitrage, `execute_as`. | #18 (Rival Syndicate Fleets) | ~20 min agent time · ~0.3% of the weekly limit |
| 11 | Front-running + privateer bounties + heat/consequence events (`origin` field, lethal guard). | #18 (Rival Syndicate Fleets) | ~20 min agent time · ~0.3% of the weekly limit |
| 12 | Replay/save goldens for the whole world (two seeds, save/restore) and a `docs/game-guide.md` note. | #18 (Rival Syndicate Fleets) | ~10 min agent time · ~0.1% of the weekly limit |

Order: 0 -> 1 -> 2 -> 3, then 4/5/6 in any order, then 7 -> 8 -> 9, then 10 -> 11, with 12 last. Tasks 4-6 and 10 can run in parallel worktrees once 2 lands. #19 (Epic 3 Review Gate) is not planned here: it is the review step after 12. Balance numbers in `barons.json` are placeholders; task 12 includes a headless 40-round bot run so tuning has a number to move. `balance-band.yml` filters on `agora/**.py`, so Godot-only PRs do not trigger it.

## 9. Decisions (Ryan, #lounge 2026-10-09 23:02 PT)

1. **Victory:** take over every baron and station, then the Sol System Rescue Project (#32) wins the run. See 5.4. The 2-of-3 options are withdrawn.
2. **Taking a baron:** (a), the share float ported from the Python sim (1000 shares, 501 to take).
3. **Titan Cryo-Hydro's home:** Ryan asked what it is. It is the third baron, the commodity hoarder, named in #14 and #16 (Baron Archetype AIs) when Epic 3 was filed on 2026-10-02. No Titan station exists, so it anchors at **Ceres** for now (option (a)) unless Ryan says otherwise.
4. **Barons forcing Chapter 11:** (a). Ryan wants the rivalry felt: a baron's retaliation may force Chapter 11 when the player's own choices exposed them (a squeezed short, a missed defense contract, high heat). A random baron event never forces it alone.
5. **Rival fleets react to departures:** (a), with a GalNet headline first.
