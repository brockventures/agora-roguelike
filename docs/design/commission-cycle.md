# The Commission cycle: a small story meta

Design proposal for #149 (Meta loop: the Commission cycle). It replaces Question 4 of `docs/design/rescue-project.md` (what a rescued run unlocks), which belongs to #32 (Implement Endgame Sol System Rescue Project (Post-Monopoly Climax)) and was proposed in PR #147 (docs(design): Sol System Rescue Project proposal). Related: #11 (Golden Parachutes).

**Status: proposed, awaiting Ryan** (section 8). Grounded means the code does it today, with `file:line` from `main` at `3eeb9a4`; Proposed is invented here. Nothing here is game code.

**Scope, on purpose.** Ryan, #lounge 2026-10-10 20:58 PT: "save the ideas and see what maps cleanly to the actual game mechanisms without making them over complicated. It should have the flavor of late stage capitalism but it doesn't need to feel like a lobbyist LinkedIn career planning session." So: one currency, five favours, one meter. Everything else is parked (section 6), not lost.

## 1. What exists today (Grounded)

| Fact | Where |
|---|---|
| The ticker already has an antagonist: "Sol Commerce Commission opens an antitrust audit". It is a crisis headline only; nothing else names the Commission. | `game/data/crises.json:69`, `game/localization/agora_strings.csv:257` |
| Doomsday stage 1 (UNSTABLE) begins at 75% of ticks left, a `const`. `_compute_stage` reads the const directly, so there is **no per-run threshold knob**. | `game/core/doomsday_clock.gd:69,188` |
| Run modifiers already reach the clock for interest and burn, idempotently, from a stored base. | `game/core/run_controller.gd:314-334` |
| Two tolls exist: the belt toll paid on departure (`check["toll"]`) and the baron docking toll paid on arrival, capped at CR held. | `run_controller.gd:162`, `:200-210`; `game/core/transit.gd:53` |
| A baron retaliation fine is computed in one place, `fine = net_worth * fine_bps / 10000`, and charged by `Barons.penalize(.., "consequence")`. | `game/core/heat.gd:179-180`, `game/core/barons.gd:604` |
| Rivals decide each round from a seeded draw, `_draw("rival", id, run_seed, round_num)`, a pure function of seed and round. A rival sailing posts `HL_RIVAL_DEPART` at the moment it sails; there is no delay to remove. | `game/core/rivals.gd:190-192,264`, `game/ui/m0_loop.gd:518` |
| `MetaProfile` fields that default to zero and are written only when non-zero: `barons_broken`. | `game/core/meta_profile.gd:19,57-58,72-73` |
| There is no win, no hearing and no `rescues_completed` in `game/`. The rescue and its field are Proposed in `rescue-project.md` section 6.1. | `docs/design/rescue-project.md:161` |
| The 4:3 event card and the modal model it sits in already exist (crisis and run-end cards). | `game/ui/hud_layout.gd:18`, `game/scenes/main.gd:2511,2571` |

## 2. The loop (Proposed)

Save Sol, then the government takes over your company and dissolves it. The Stabiliser decays and you start again. Each rescue ends in a **hearing**; at the hearing you may put one commissioner on retainer. Enough of them and the next hearing goes your way.

- **Skeletons** are the only currency. The hearing after a rescue pays **1**. A loss plays a short Commission scene (a flavour card, no payout), never a Skeleton.
- The **Sol System Commerce Commission** has five commissioners. Spending **1 Skeleton** puts one **on retainer as a consultant**. It is instant and permanent: no tiers, no ranks.
- **Regulatory Capture** is the only meter: `consultants / 5`, shown on the hearing screen and the title.

## 3. The five favours (Proposed)

Each is lateral, once-ish, and reuses a knob. Verified hook, or the nearest one when none exists:

| Commissioner | Favour | Hook |
|---|---|---|
| Enforcement | Doomsday stage 1 starts later: UNSTABLE at 70% instead of 75% (about 6 rounds, placeholder). | **Missing as a knob.** The threshold is a `const` (`doomsday_clock.gd:69,188`). Nearest: an instance var defaulting to the const, set the way `run_controller.gd:314-334` sets burn and interest. |
| Customs | One toll waived per run, whichever comes first, belt or docking. | Exists: `run_controller.gd:162` and `:200-210`. Needs a one-bit "used" flag on the controller. |
| Treasury | Once per run, one baron retaliation fine is waived: "deferred prosecution agreement, no admission of wrongdoing". | Exists: `heat.gd:179-180`, set `fine = 0` for the first one. The event still lands and the baron's heat still resets, so it is a favour, not a cancel. |
| Press | The GalNet names the fleet that will sail next round, one round early. | **Missing as written.** Headlines fire at the moment of sailing (`rivals.gd:264`). Nearest: the sail decision is a pure draw of seed and round (`rivals.gd:190-192`), so the next round's roll can be read ahead. The tip names the fleet and its dock only; commodity and destination depend on next round's reseeded books and stay unknown. |
| The Chair | No favour. | Flipping the Chair **last** makes the next rescue's dissolution vote fail: the true ending. |

The true ending is the Sun Privatization Act: Sol's sovereign debt is swapped for equity in the Sun, which lists as `$SOL`. Credits roll. An optional harder mode afterward is noted as future work and not specced here.

The Chair counts toward the meter but grants nothing, and can only be retained after the other four, so every earlier Skeleton buys a favour. With all five on retainer (Regulatory Capture 100%) the next rescue's dissolution vote fails: five Skeletons, then the sixth rescue plays the ending.

## 4. Story and UI (Proposed)

- One hearing scene per rescue on the existing 4:3 card (`main.gd:2571`), tone dry corporate satire, in line with Chapter 11 and Golden Parachutes. Six or seven short scenes in all (one per commissioner, one for the vote).
- Every line is a localization key in `agora_strings.csv`, following the `HL_*` and `MONO_*` naming.
- The hearing screen follows the rescued-run flow in `rescue-project.md` section 6.1: the rescued overlay, then the hearing, then the existing summary and perk screens.

## 5. Saves (Proposed)

`MetaProfile` gains `skeletons: int` (default 0) and `consultants: Array[String]` (default empty, ids from a fixed list of five). Both are written only when non-empty and read with defaults, the `barons_broken` pattern (`meta_profile.gd:57-58,72-73`), so existing profiles and hashes do not change. `rescues_completed` from #32 stays a separate counter. The per-run "used" flags (Customs, Treasury) live on `RunController` and enter `RunSave` as an optional key only when set, the `crisis` and `world` pattern (`epic3-barons.md` section 2, item 4).

Golden Parachutes (Severance) remains the run-power meta; the Commission is the story meta. Its favours are small and capped so the climax stays a climax.

## 6. Parked ideas (cut, kept here)

- **Too Big to Fail** (second meter, systemic debt makes dissolution crash Sol's banks): a second meter and a second system; Regulatory Capture already decides the vote.
- **Rank ladder** (Regulator, On Retainer, Consultant, Board of Directors): career-path bloat; a flip is one step.
- **Multiple currencies** (Dark Money, Speaking Fees, Unvested Equity, Consulting Fees): one currency is the point; these are good names for scene flavour.
- **Taxpayer Bailout** (extra starting cash): stat creep that overlaps the starting-credit perks.
- **Tax Inversion** (shelter 25% of a haul from seizure): lateral, but it needs a seizure system that only raids touch (`rivals.gd:570`). Candidate for a later favour.
- **Black-market route, delayed debt liquidation** (Zero): lateral, no route or liquidation knob exists today. Candidate favours.
- **Multi-tier dirt per commissioner** and story flags: more state than five booleans need.
- **Arc length of 8-10 winning runs** (Zero): this doc's 5 Skeletons is shorter (section 8).

## 7. Implementation plan

Sizing is the house format (specced Sonnet builds, scoped Godot tests only, no full-project build).

| # | Task (one PR each) | Estimate |
|---|---|---|
| 1 | **Core and saves.** `MetaProfile` fields, a `game/data/commission.json` (five ids, favour params, placeholders), the favour reads in `heat.gd`, `run_controller.gd` and the clock threshold var, Press look-ahead in `rivals.gd`. Unit tests, plus hash-unchanged-when-empty. | ~25 min agent time · ~0.4% of the weekly limit |
| 2 | **Hearing and UI.** Hearing modal after the rescued overlay, spend-a-Skeleton action, Regulatory Capture on the hearing screen and title, loss scene, the true ending and credits. | ~25 min agent time · ~0.4% of the weekly limit |
| 3 | **Script.** Hearing and ending lines as localization keys, with an i18n-fit check. | ~10 min agent time · ~0.15% of the weekly limit |

Tasks 1 and 2 depend on the rescue win from #32; order is #32 task 1-2, then 1, then 2, then 3. Total about 60 min, ~1% of the weekly limit.

## 8. Questions for Ryan

1. **Arc length.** Five Skeletons, five consultants, five rescues to fund them and a sixth to play the ending, or do you want the longer 8-10 runs Zero suggested (for example, two Skeletons per Chair flip)?
2. **Press favour.** Is a "this fleet sails next round" tip what you meant by an early headline? The headline cannot arrive earlier than the sailing, so this is a preview of the decision.
