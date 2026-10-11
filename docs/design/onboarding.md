# First-hour onboarding and the terminal tutorial

Design proposal for #36 (Design First-Hour Onboarding Flow & Interactive Terminal Tutorial), on the Steam Deck track in `ROADMAP.md` ("Tier 3"). The issue's goal is to keep a new player past the two-hour Steam refund window with a contextual tutorial that teaches order execution, transit risk and debt burn, is easy to skip on later roguelite runs, and does not break the terminal aesthetic. The issue lists two dependencies, both closed and both shipped:

- #21 (Build 1280x800 Orbital Bloomberg Terminal Screen Layout in Godot), closed. It gave the HUD this doc places things in: order ladder, Doomsday header, fleet status, GalNet ticker.
- #22 (Implement Godot Control Node Gamepad Focus Graph & Controller UX), closed. It gave the controller bindings this doc teaches: LB/RB tabs, LT/RT stations, face-button order execution.

Both are children of #20 (Epic 4: Steam Deck Controller-First UI & CRT Aesthetics), also closed.

**Status: proposed, awaiting Ryan** (section 15). Every section separates what the code already does (**Grounded**, with `file:line` from `main` at `613a547`) from what this doc invents (**Proposed**). Nothing here is game code. Every number marked "placeholder" is a tuning guess for Ryan. The doc was written from a read of the code; nothing was played or measured, and where a figure is computed from constants the doc says so.

**Headline finding.** Three things in the code decide the design, and none of them is obvious from the issue text.

1. **Tutorial state cannot live where it looks natural.** `RunController.to_dict()` embeds the whole `MetaProfile` (`run_controller.gd:732`), `RunSave.capture` embeds that, and `state_hash` hashes it (`run_save.gd:24-36,78`). A "tutorial seen" flag on `MetaProfile` that changes mid-run therefore changes the run hash. Section 7 and 8 put the state beside the accessibility settings instead, which the code already documents as never reaching sim state, saves, replays or hashes (`accessibility_settings.gd:8`).
2. **"Later run" cannot be read from `runs_completed`.** That counter is bumped in `_bank_corp` (`run_controller.gd:543`), which a Chapter 11 filing also calls (`run_controller.gd:665-680`). A player who files once in their first twenty minutes would be treated as a veteran. Section 6 uses its own "done" flag.
3. **The roguelite hook arrives late.** Severance is banked at a filing, but perks are only bought when the run is over (`main.gd:288`, `m0_loop.gd:1698`), and a run ends at round 120, 30 minutes at 1x (`doomsday_clock.gd:52-53`). A player who requests a refund at minute 45 may never have seen the perk screen. That is Question 7.

## 1. What exists today (Grounded)

| Fact | Where |
|---|---|
| A run starts docked at Mars on the Map tab, 5,000 CR, no debt, one starter hull, a 100-unit hold. Only the docked station's books are seeded; the others are seeded on the first departure toward them. | `m0_loop.gd:67,124`, `chapter11.gd:24,28`, `doomsday_clock.gd:55`, `run_controller.gd:46`, `game/README.md:96`, `m0_loop.gd:1164` |
| The run is 120 rounds of 900 ticks at 60 ticks per second: 30 minutes at 1x. Speeds are 1x, 2x, 5x, so 30, 15 and 6 minutes. A paused clock processes zero ticks, so a player who reads while paused adds wall time but no sim time. | `doomsday_clock.gd:46,52-53`, `sim_clock.gd:9,40,123` |
| Debt burn is 8 CR per second, 120 CR per 15-second round at the NORMAL stage. Interest is 100 bps per minute, compounding on principal plus accrued interest only, not on accrued burn, so a corp with no principal accrues burn and nothing else. The stages (NORMAL, UNSTABLE, CRITICAL, IMMINENT, COLLAPSED) are ratios of ticks left; UNSTABLE starts at 75% remaining, round 30. | `doomsday_clock.gd:56-57,69-71,131,245` |
| `get_header_telemetry` already exposes CR, total debt, principal, interest, stage, speed, round and docked/in-transit; the header has CREDITS, DEBT, SPEED and DOOMSDAY chips. | `orbital_hud.gd:168`, `agora_strings.csv:322-326` |
| Controls: LB/RB tabs (Map, Market, Fleet), LT/RT stations, right stick commodity, D-pad or left stick up/down the ladder (crossing the spread flips BUY/SELL) and left/right quantity, A submit, B back, X Chapter 11, Y speed, Start pause, View settings. | `m0_loop.gd:3-17`, `project.godot` (`m0_*` actions), `docs/steam.md` ("Steam Deck input") |
| On the Map tab A is not an order: it departs for the station LT/RT selected. Order entry actions are inert off the Market tab. | `m0_loop.gd:1498-1503`, `MARKET_ONLY_ACTIONS` |
| Order results are signals: `order_executed` on a fill, `order_rejected` with a reason. `M0Loop` counts fills; the desk-notes card already shows the last rejection or fill line, and `rejection_message` maps reasons to localized text. | `gamepad_focus.gd:24-25,366,448`, `m0_loop.gd:1733-1745`, `main.gd:1938-1948` |
| The route card appears on the Map tab, docked, with another station picked. It shows ETA, belt toll, fuel, and `PIRACY n% . HAZARD n%` from `Corridors.quote`. Piracy is 0% when the hold is worth less than `piracy.min_hold_value` (500 CR). | `main.gd:1136-1179`, `corridors.gd:48,131,145`, `data/corridors.json` |
| A raid or hazard on departure is rolled in `Barons.react_to_departure`, from a source seeded by (run seed, round) alone, and posts `HL_RAID_*` / `HL_CORRIDOR_*` headlines. | `barons.gd:214`, `corridors.gd` header, `m0_loop.gd:557-577` |
| Insolvency sets `pending_bankruptcy`, pauses the clock and raises `OVERLAY_CHAPTER_11`; X files. `file_bankruptcy` returns `{}` unless the corp is insolvent or pending, so a stray X press while solvent does nothing. A filing founds a new corp inside the same run, wipes debt buckets, does not reset the clock, replaces `profile`, and banks Severance. | `m0_loop.gd:1747-1751`, `run_controller.gd:665-680`, `chapter11.gd` header |
| Collapse pauses the clock and raises the run summary, then the Golden Parachutes perk screen, then START NEW RUN. Severance is `rounds x 1 + 0.5% of peak net worth` (+400 per baron held); the cheapest perks cost 100. | `m0_loop.gd:1628,1704,1764`, `parachutes.gd:63-67,305`, `data/parachutes.json` |
| Modal overlays: crisis, contract, monopoly, Chapter 11, collapsed, rescued. Each pauses the clock through `sim_clock.pause()`, which is serialized (`paused`, `auto_paused_reason`). | `m0_loop.gd:1764-1778,1496`, `sim_clock.gd:168` |
| The settings screen freezes the sim from `Main`, not from the clock: `_process` returns before `loop.advance`. Toasts wait (neither drawn nor aged) while any modal, the settings screen or the sleep banner owns the screen. | `main.gd:160-170,3225-3228` |
| GalNet: two visible ticker lines, 20 items of history, and a sound per post (blip, warning or critical alarm). `post_headline_tr(key, args, category, severity)` keeps key and args so a language swap re-translates. | `orbital_hud.gd:38-39,436-466` |
| Toasts: three kinds (`filled`, `rejected`, `info`), 3.5 s life, at most 3 visible, aged on UI time only. | `toast_tray.gd:13-16,26` |
| The desk-notes card (`CARD_RECT` 408x264) takes ordered entries `{kind: "chip"|"line", text, tone}`. The rescue block is the first block after the last fill or rejection line. Art height shrinks with text scale (120, 100, 84 px). | `hud_layout.gd:18`, `main.gd:1938-1950,2082`, `m0_loop.gd:812` |
| Pad prompts along the ticket foot are built from `HUD_PAD_*` and `HUD_PROMPT_*` keys: A Depart/Submit, B Back, X Ch. 11, Y Speed. They are fixed text, not read from the live bindings, although the player can rebind. | `main.gd:1769-1773`, `agora_strings.csv:327-342`, `input_remap.gd:185` |
| Settings: text scale 100/115/130%, palette (colorblind), language (en, pseudo), CRT filter (off by default), alert volume and mute, reduced motion, per-action rebinding. Stored in `settings.json` through `SaveStore`, which is mirrored to Steam Cloud. View and F1 open settings and cannot be rebound. Header comment: display and input only, nothing reaches sim state, run saves, replays or hashes. | `accessibility_settings.gd:8,12,14,32`, `settings_menu.gd:18,50`, `save_store.gd:28`, `input_remap.gd:17`, `docs/steam.md` ("Cloud saves") |
| Localization: every player-visible string is a CSV key. Tests: all keys used in code exist, all CSV keys are reachable, no raw English in `ui/`, `scenes/`, `core/`, and pseudo-locale (+30% length, brackets) plus all three text scales must fit labels, modals, toasts and desk notes. | `test_localization.gd:76,92`, `test_i18n_audit.gd:86`, `test_i18n_fit.gd:758,771,992`, `loc.gd` header |
| Persistence is only enabled outside headless mode, so tests, screenshot scripts and replays never write saves. | `main.gd:143-144` |
| Steam stats and achievements are the only measurement channel in the repo (`achievements.json`, `SteamHooks`, a local mirror). There is no analytics or telemetry code. The real App ID is still blocked on #30 (Execute Steamworks Onboarding & Build Review under Mike's Account), open. | `docs/steam.md`, `data/achievements.json` |
| Bots drive the real game objects headless (`rescue_bot.gd`, `pacing_bot.gd`), the precedent for a scripted first-hour check. | `game/tools/` |

**Gaps (not features).** Nothing in `game/` teaches anything today: no tutorial, hint, first-run or "seen" state exists (`grep -ri tutorial game/` finds nothing). The game has no title screen; `_ready` resumes the autosave or starts a run directly (`main.gd:139-150`). A new player's first screen is the Map tab at Mars with no instruction, and A does not do what a trader would expect there.

## 2. Design goals

1. **Teach by doing, in the order the player will need it.** Every beat is triggered by something the player just did or something the sim just did, and completes on an event, not on a button labelled "Next".
2. **Three lessons, not a manual:** order execution, transit risk, debt burn. Everything else the game already explains with its own modals (crisis, contract, monopoly, Chapter 11, rescue) stays out.
3. **Never stop the player and never touch the sim.** The tutorial observes; it does not pause, input, draw or save in the run (sections 5 and 8).
4. **Terminal voice.** Plain rows in the existing desk-notes card and header chips. No popups, arrows or highlights drawn over the CRT.
5. **Gone after hour one, one switch away at any time.**

## 3. The first hour (Proposed)

The first hour in sim terms: run 1 is 30 minutes at 1x (less if the player speeds up, more in wall time if they pause), then the summary and perk screen, then the start of run 2. The tutorial covers the first of these and stays quiet for the second.

Beats are in the order a player meets them. "Fires when" is an existing signal or state, never a timer. "Done when" is the event the beat teaches, so a player who does the thing first marks the beat done without ever seeing it.

| # | Beat | Fires when | The row says (intent) | Done when |
|---|---|---|---|---|
| 1 | **Tabs** | Tutorial on, beat 1 not yet seen, Map tab, no fill yet | `LB/RB` change tab; open MARKET. `Start` pauses the clock. | `tab_changed("MARKET")` |
| 2 | **Order execution** | First time on the Market tab | `R-STICK` picks the commodity, `D-PAD` walks the ladder (crossing the spread flips BUY/SELL), `LEFT/RIGHT` sets quantity, `A` submits. | First `order_executed` |
| 3 | **Debt burn** | First `round_advanced` after beat 2 | The DEBT chip is climbing about 120 CR a round; burn does not compound; DOOMSDAY is the deadline and UNSTABLE starts at round 30. Waiting costs debt, not cash. | Two more `round_advanced` events |
| 4 | **Leave the dock** | Hold non-empty, Map tab, route card showing for another station | `LT/RT` pick the destination, the card shows ETA, toll, fuel and PIRACY/HAZARD; `A` departs. A hold worth under 500 CR is never raided, and the card says 0% in that case. | `transit_departed` |
| 5 | **Sell elsewhere** | `transit_arrived` | Books at the new station are live; sell where the price is higher; you cannot trade in transit. | First SELL fill at a station other than the buy station |
| 6 | **A raid or a storm** (conditional) | First `corridor_raid` / `corridor_hazard` event | What the headline meant: ransom paid, cargo taken or spared; a delay; a loss. Risk is on the route card before every departure. | Two rounds |
| 7 | **Chapter 11** (conditional) | After `bankruptcy_filed` (the existing modal already explains the choice) | Debt wiped, clock not; Severance banked: N; perks are bought when this run ends. | Two rounds |
| 8 | **Perks** (conditional) | First entry to the perk screen | One `text` row in the existing perk modal: what Severance buys and what the cheapest perk costs. | Leaving the screen |

Beats 1 to 5 are the **core**; 6 to 8 are **conditional** and show once per player, whenever their event first happens, including in later runs. A beat the player already did is marked done silently. Beat 3 and 6 to 8 reuse numbers the HUD already shows (`orbital_hud.gd:168`, the route card); the tutorial never computes a risk of its own.

Why this order. Beat 1 first because the opening screen is a Map tab where A departs, and the thing a trader wants (an order) lives one bump away. Beat 3 waits for a first fill so the player has a position to care about the clock for. Transit risk comes after they have cargo, because the route card's piracy figure is 0% for an empty or cheap hold (`corridors.gd:145`) and a lesson about a number that reads 0 teaches nothing. Raid, Chapter 11 and perks are consequences, not prerequisites, so they wait for the event.

## 4. Triggers and surfaces (Proposed)

**One new model, owned by `Main`.** A `RefCounted` (working name `Onboarding`) beside `ToastTray` and `SettingsMenu`. It is not referenced by `RunController`, `M0Loop` or `RunSave`. It connects to signals that already fire: `loop.tab_changed`, `gamepad_focus.order_executed` / `order_rejected`, `controller.round_advanced`, `transit_departed` / `transit_arrived`, `bankruptcy_filed`, `run_collapsed`, `loop.overlay_changed`. Connecting another listener does not change what any of them emits.

**It reads, never calls.** The tutorial reads values the HUD already computes (header telemetry, `_route_card_plan()`, cargo) and never calls a model method the HUD does not, so it cannot add a draw, a lazily built object or a state change. Beat 4's piracy and hazard percentages are the route card's own text.

**Surface: the desk-notes card.** The active beat is one `chip` (the beat title, `OPS NOTE n/5` style, tone `info`) plus at most three `line` entries, inserted into `_card_notes` after the last fill or rejection line and before the rescue block (`main.gd:1938-1950`). The card is always on screen and already carries fill, rejection, baron and rescue notes in this form. A tutorial entry is never the only thing that explains a rejection: the rejection line stays first.

**Why not the others.**

- *GalNet ticker.* Two visible lines, 20-item history, and every post plays a sound (`orbital_hud.gd:38-39,436-466`). A tutorial would push real news out of the history and blip over the market bell. Not used.
- *Toasts.* 3.5 seconds and three at a time (`toast_tray.gd:13-16`) is too short to read a controller instruction. Optional use: a `info` toast when a beat completes ("ORDER FILLED"), so the card change has an ack. Section 11 notes the reduced-motion check this needs.
- *Modals.* They pause the clock through the serialized path (`m0_loop.gd:1764`) and grab all input (`m0_loop.gd:1496`). The one exception is the single `text` row in the existing perk modal (beat 8).
- *A new `m0_*` action to advance or skip.* Every action is mirrored in `project.godot`, the Steam Input manifest (20 actions, kept in step by `tests/test_steam_files.py`) and `docs/steam.md`. Beats complete on events; skipping is a settings row (section 6).

**When a row is hidden.** While `_modal_has_focus()` is true (any overlay, the settings screen, the sleep banner; `main.gd:3225`), the same rule toasts use. At most one beat is active; if two would fire in the same frame the lower-numbered one shows and the other queues.

## 5. The clock: pause or not (Proposed)

**Recommended: the tutorial never pauses.** Section 1 shows why the pause path is dangerous: `sim_clock.pause()` writes `paused` and `auto_paused_reason` into the saved state, and an interrupt hook would change the sim-tick loop itself. The tutorial must use neither.

What a new player loses by not pausing is debt, not cash. Burn accrues into the debt bucket at 120 CR a round and a 5,000 CR corp is not insolvent until debt exceeds liquidation value (`chapter11.gd` `assess`), so reading a row for one or two rounds costs a few hundred CR of debt, and the player can press Start at any time. Beat 1 says so.

If Ryan wants a hold (Question 2), the only hash-free one is the `Main`-level freeze the settings screen already uses (`main.gd:166-170`): `_process` skips `loop.advance` while a beat flag is up. That freezes the sim without writing the clock. It would still need a visible "HELD" state so the player knows why the clock stopped.

## 6. Skipping, disabling and replaying (Proposed)

- **State per player, in two parts:** `enabled` (bool, default true) and `seen` (a sorted list of beat ids).
- **Core beats stop when `enabled` is false.** `enabled` becomes false by itself the first time beat 5 completes (the core loop is learned) or the first run ends, whichever comes first, and by the player at any time.
- **Conditional beats ignore `enabled`.** They show once each, from the `seen` list, so run 2 can still explain its first raid. They can be turned off with the rest by a second switch (Question 3).
- **Never use `runs_completed`** as the veteran test (headline finding 2). A player who has not finished the core loop is not a veteran however many corps they have filed.
- **Settings row.** One row in `SettingsMenu` (`settings_menu.gd:18,50,65`), same shape as CRT or Reduced motion: `TUTORIAL  < ON | OFF >`. Left/Right changes it. Turning it on again clears `seen` for the core beats (a replay). `reset_defaults` (`accessibility_settings.gd:122`) does not touch the tutorial, like language.
- **Reaching settings.** View or F1 opens settings in every state and cannot be rebound (`input_remap.gd:17`). Beat 1's chip carries a permanent `VIEW: Tutorial off` hint.
- **No in-run "skip" button.** There is no free `m0_*` action and adding one costs a manifest change (section 4); the settings row is two presses from anywhere.

## 7. State, saves and restore (Proposed)

**Where.** Next to the accessibility settings: two optional keys in `settings.json`, written through the existing `AccessibilitySettings.to_dict` / `from_dict` / `SaveStore.save_settings` path (`accessibility_settings.gd:142-166`, `save_store.gd:28`). Reasons from the code:

- `settings.json` is already in the Steam Cloud list (`docs/steam.md`), so a player who finishes the tutorial on a desktop does not meet it again on the Deck, and no new save file or Partner-site setup is needed.
- `from_dict` validates every field and keeps defaults on anything bad, and the header states the file never reaches sim state or hashes (`accessibility_settings.gd:8,148`). A hostile or old file cannot break a run.
- Option (b) in Question 1 puts the flag in `MetaProfile`. That works for a flag written only at a corp boundary (the `rescues_completed` pattern, `meta_profile.gd:21,61`), but a per-beat list written mid-run changes the run hash, and `Chapter11.file` replaces the profile object at every filing (`run_controller.gd:676`).

**Written when.** A beat completes or the setting changes: the existing `settings.changed` path already saves (`main.gd:706-716`).

**Restore.** Only `enabled` and `seen` persist. The *active* beat is recomputed from live state on load: the current tab, whether a fill has happened, the cargo, whether the route card is showing. A player who quits mid-beat comes back to the same beat, or to none if they finished it. Nothing about the tutorial is in the run slot, so a loaded run from before this feature, or a run slot copied between machines, behaves as it always did.

**New game.** The run slot (`save_store.delete_run`, `save_store.gd:187`) and the settings file are separate files, so starting over keeps the tutorial state. That is intended: it is a property of the player, not of the corp.

## 8. Determinism (Proposed)

The rule: **nothing the tutorial does may be visible to `RunSave.capture`, `state_hash`, a replay, or any golden.**

- **Where it lives.** `Main` only. `Replay.Session` builds `RunController` + `OrbitalHUD` + `M0Loop` and no `Main` (`replay.gd:28-50`), so replays and the world and rescue goldens (`test_world_goldens`, `test_rescue_goldens`) never construct it.
- **No input.** It consumes no `m0_*` action, so the recorded inputs of a replay are the player's alone.
- **No draws.** It makes no draw from a `DrawSource`, `Bags` or `StableHash` stream; the raid and hazard streams stay "a pure function of (run seed, round)" (`corridors.gd` header).
- **No clock writes.** It calls neither `pause()`, `resume()`, `set_speed()` nor `register_interrupt_hook`. Section 5.
- **No save key.** It adds nothing to `RunSave.capture` or `RunController.to_dict`, and nothing to `MetaProfile.to_dict`. `RunSave` is not touched at all, so no `schema_version` bump.
- **Off by default in headless.** `Main` constructs it only when persistence is enabled (`main.gd:143-144`), so every fit test, `shots_*.gd` screenshot script and bot keeps today's screens. A test that wants it builds it explicitly.

**How the tests prove it** (stronger than "no golden moved"):

1. *On vs off equality.* Same seed, same scripted inputs, run once with an `Onboarding` attached and once without, to a fixed tick. `RunSave.state_hash` must be identical, and so must `RunSave.capture` as canonical JSON. This fails if the tutorial ever mutates the sim, the profile or a draw stream.
2. *Existing goldens untouched.* The full suite, including `test_world_goldens` and `test_rescue_goldens`, passes with no fixture regenerated.
3. *Settings round trip.* `settings.json` with and without the new keys loads to the same defaults; a hostile value (a string for `enabled`, a number for `seen`) falls back to defaults, like the existing hostile-file test (`test_accessibility.gd:410`).
4. *Signal neutrality.* Count the emissions of each connected signal with and without the listener; they are equal.

## 9. Localization (Proposed)

- **Every string is a CSV key** (`TUT_<BEAT>_TITLE`, `TUT_<BEAT>_L1..L3`, plus the chip and hint keys), added to `agora_strings.csv`. The raw-English lint scans `lines.append("` and `.text =` sinks (`test_i18n_audit.gd:86`), so rows are built from `Loc.t` / `Loc.format` and nothing is concatenated from English fragments.
- **Controller glyphs are arguments, not words in the sentence.** A line like `PRESS %s TO SUBMIT` takes the button name as an argument so a translation can reorder it. Plural and unit text uses the existing `%d` conventions.
- **Fit.** Each row is checked under pseudo-locale (+30% length, brackets) and at 100, 115 and 130% text scale by the existing desk-notes tests (`test_i18n_fit.gd:758,771,992`). The card is 408x264 and the notes area shrinks with the scale (`main.gd:2082`), and desk notes scroll as whole entries, so **the instruction must be in the first line of the beat** and every line must be short enough to survive 130% pseudo. A beat body is at most three lines of about 40 characters in English.
- **A language swap re-translates a live row.** Rows are stored as key plus args and rendered at draw time, like GalNet items (`orbital_hud.gd:466`), so `m0_locale` mid-beat works.
- **Adding a language is a new CSV column** (`loc.gd` header); the tutorial adds rows to that work, not a separate pipeline.

## 10. Controller-first prompts and the Deck (Proposed)

- **Prompts show the button the player actually has.** The existing foot prompts are fixed text (`main.gd:1769-1773`) although the player can rebind. The tutorial reads `settings.bindings` and formats with `InputRemap.code_label`, falling back to the shipped name, so a player who moved Submit to X is told X. This is a small helper, not a change to the existing prompts (Question 8).
- **Names match the Deck.** The shipped layout maps A/B/X/Y, D-pad or left stick, right stick X to commodity, triggers to stations and bumpers to tabs (`docs/steam.md`), the same names the beats use. `JOY_NAMES` has no entry for button 16 (it would print "Btn16"); the first hour never names it (`m0_project`, the rescue delivery), so it is out of scope but noted.
- **Keyboard players** see the key beside the pad name in the `binding_text` shape (`Pad: LB  Key: Q`, `input_remap.gd:185`). The code does not track the last-used device, so the doc does not promise to show only one.
- **Steam Input vs Godot input.** SteamHub turns Steam Input edges into the same `InputEventAction`s (`docs/steam.md`), so beat completion by event works under either.
- **Handheld legibility.** The Deck-verified floor is 12 px (`accessibility_settings.gd:14`); tutorial text uses the same body role and size as the other desk notes and never goes below it.

## 11. Accessibility (Proposed)

- **Text scale.** Fits at all three scales is a test gate (section 9).
- **Colorblind palettes.** Tone is never the only signal: a beat is a chip with text (`OPS NOTE 2/5`) and the row says what to do; the `bad` tone in rescue rows is already paired with words. The tutorial uses the `info` tone only.
- **Reduced motion.** The tutorial adds no animation of its own. If beat-complete toasts are used, they use the existing pop/shake, which must be checked against the reduced-motion setting before shipping; if they do not already honour it, beat-complete is a card change only.
- **Alert audio.** The tutorial plays no sounds and posts no GalNet items, so alert mute and volume are unaffected.
- **No time pressure.** Nothing expires on wall-clock time. Beat 3, 6, 7 end after rounds of sim time, so a paused game keeps the row.
- **Screen readers.** The repo has no screen-reader support for any HUD text. That is not addressed here.

## 12. Measurement (Proposed)

The repo has no analytics and this doc does not add network telemetry. What can show whether the tutorial worked:

- **Steam, via the channel that exists.** `achievements.json` and `SteamHooks` already report unlocks and max-stats to Steam, with a local mirror for offline play (`docs/steam.md`). One new max-stat, `onboarding_step` (0 to 5, the highest core beat completed), gives a drop-off funnel on the Steamworks partner site once the real App ID exists (#30, Execute Steamworks Onboarding & Build Review under Mike's Account, open). One achievement for finishing beat 5 would give a percentage-of-players figure. Refund rate and total playtime are Steam's own dashboards, not in the repo.
- **Headless, before any player.** A scripted first-hour bot in the style of `rescue_bot.gd` that drives the real objects and asserts each beat fires, completes on its event, and that the on/off hash is equal. This proves the tutorial works; it does not prove it teaches.
- **Local only, optional.** A counter file of beats shown and completed, written next to `steam_mirror.json`, for playtest sessions with testers who agree to send it. Question 5.
- **What would count as success** (placeholder, for Ryan): 80% of players who start reach a first fill; median time to first fill under 3 minutes of sim time; median time to first departure under 8; fewer than 5% of players turn the tutorial off before beat 2 (a high rate means it is intrusive); and the first-hour Chapter 11 filing rate does not rise.

## 13. Risks

| Risk | Why it is real | Mitigation |
|---|---|---|
| **The card is small.** 408x264, art shrinks with scale, desk notes scroll by entry. | `main.gd:1938,2082`, `test_i18n_fit.gd:992` | At most 1 chip + 3 short lines; instruction first; fit tests at 3 scales and pseudo. |
| **Tutorial hides a rejection or fill.** Both live in the same card. | `main.gd:1938-1948` | Tutorial entries come after them; section 4. |
| **Hash drift from a "harmless" pause or flag.** | `run_controller.gd:732`, `sim_clock.gd:168` | Sections 5 and 8; the on/off equality test is the gate. |
| **Veteran misdetected.** `runs_completed` counts filings. | `run_controller.gd:543` | Own `enabled` flag (section 6). |
| **Prompts lie after a rebind.** | `main.gd:1769` | Read live bindings (section 10). |
| **Roguelite hook arrives at round 120.** Perks are only bought when the run is over. | `m0_loop.gd:1698` | Beat 7 tells the player the promise early; Question 7 asks whether to move it. |
| **A fixed 3-lesson script is wrong for good traders.** Someone who already trades well sees a card telling them to open Market. | Beat 1 | "Done when" fires on the event, so a player who has already done it never sees the row. |
| **Locale growth.** A third language adds text to fit. | `loc.gd` | All text is keys; fit tests are per locale. |
| **Cloud conflict.** `settings.json` is cloud-synced; two devices could disagree. | `docs/steam.md` | Merge rule (union of `seen`; `enabled` false if either side is false) is specified and tested in task 1. |

## 14. Implementation plan

Sizing follows the house format: a specced Sonnet build is 5 to 15 minutes and 0.1 to 0.2%, a medium one 20 to 30 minutes and 0.3 to 0.5%. Each PR is built by a Sonnet agent in a worktree with scoped Godot tests only (no full-project build, per `AGENTS.md`); each UI task adds `agora_strings.csv` keys. Total: about 105 minutes, ~1.7% of the weekly limit.

| # | Task (one PR each) | Estimate |
|---|---|---|
| 1 | **Model, data and persistence.** `Onboarding` (`RefCounted`) with the beat table as data (`game/data/onboarding.json`), `enabled` / `seen` in `AccessibilitySettings` (`to_dict` / `from_dict` with validation), pure transitions (event in, active beat out). The on/off `state_hash` equality test and the hostile-settings test. | ~25 min agent time · ~0.4% of the weekly limit |
| 2 | **Main wiring.** Construct only when persistence is on; connect the signals of section 4; recompute the active beat on load; queue rule; hide while `_modal_has_focus()`. No visuals yet beyond a debug string. | ~25 min agent time · ~0.4% of the weekly limit |
| 3 | **Surface, keys and fit.** Desk-notes entries in `_card_notes`, the beat copy as CSV keys, the live-binding glyph helper, the perk-modal `text` row, fit and pseudo tests at all three scales, a `shots_onboarding.gd` screenshot script. | ~25 min agent time · ~0.4% of the weekly limit |
| 4 | **Settings row.** `Row.TUTORIAL` in `SettingsMenu`, `row_text`, replay-on-enable, tests; the settings-text fit test already covers the screen. | ~10 min agent time · ~0.15% of the weekly limit |
| 5 | **First-hour bot.** A headless scripted player in the style of `rescue_bot.gd` that walks beats 1 to 5 through the real objects and asserts each fires and completes, and that the run hash equals the tutorial-off run. | ~12 min agent time · ~0.2% of the weekly limit |
| 6 | **Steam stat and guide note** (after Question 5). `onboarding_step` in `achievements.json` and `SteamHooks`, `docs/steam.md` and `docs/game-guide.md` notes. | ~8 min agent time · ~0.12% of the weekly limit |

Order: 1, then 2, then 3. Tasks 4 and 5 can run in parallel after 2. Task 6 waits for Ryan.

## 15. Questions for Ryan

1. **Where does the tutorial's saved state live?**
   - (a) **`settings.json`**, next to the accessibility settings. Cloud-synced already, never in a run hash, validated on load.
   - (b) A `MetaProfile` bool, written only at a corp boundary and saved only when true (the `rescues_completed` pattern). It travels with the profile, but a per-beat list cannot live there without changing run hashes, and the profile object is replaced at every filing.
   - (c) `MetaProfile` per beat. Simplest to read, and breaks the on/off hash equality.
   - **Recommend (a).** It is the only option that keeps the on/off hash equality test true.

2. **Does the tutorial ever hold the clock?**
   - (a) **Never.** The player presses Start. Waiting costs debt, not cash.
   - (b) Hold at beats 1 and 2 with a visible HELD state, using the `Main`-level freeze the settings screen uses.
   - (c) A pausing modal at the start.
   - **Recommend (a).** (b) is the fallback if playtests show people losing rounds to reading; (c) is the pattern the issue asks us to avoid.

3. **What does "easy to skip on later runs" mean?**
   - (a) **Core beats turn themselves off** after beat 5 or the first run end; conditional beats (raid, Chapter 11, perks) show once each and can be turned off with the rest; one settings row replays it.
   - (b) One switch only; the player turns it off.
   - (c) Ask at the start of run 2: "Replay tutorial?"
   - **Recommend (a).** It needs no question mid-flow and still explains a first raid in run 2.

4. **How does a first-time player skip it in run 1?**
   - (a) **The settings row** (View or F1, two presses), with a permanent `VIEW: Tutorial off` hint on the first row.
   - (b) A new `m0_*` action (for example, hold B). Faster, but it adds an action to `project.godot`, the Steam Input manifest and `docs/steam.md`.
   - **Recommend (a).** No other change ripples.

5. **How do we measure it?**
   - (a) **One new Steam max-stat `onboarding_step`** plus one achievement for finishing the core loop.
   - (b) No new stats; rely on the bot, Steam refund and playtime dashboards, and existing achievements (`FIRST_CHAPTER_11`, `WITNESS_COLLAPSE`).
   - (c) Add an opt-in local counter file for playtesters.
   - **Recommend (a), and (c) for the playtest build only.** Network telemetry is not proposed.

6. **Whose voice are the rows in?**
   - (a) **Terse operator console:** "OPS NOTE 2/5. R-STICK: COMMODITY. D-PAD: LADDER. A: SUBMIT."
   - (b) Friendly second person.
   - **Recommend (a).** It matches the HUD, saves characters at 130% pseudo, and costs nothing to translate into a third column. Ryan owns the final copy.

7. **The perk screen is first reachable at round 120. Is that acceptable for the refund window?**
   - (a) **Leave it** and use beat 7 to name the promise when a first Chapter 11 happens.
   - (b) Offer the perk screen at a first filing, so Severance can be spent mid-run. A game-design change in its own issue.
   - (c) Shorten the first run.
   - **Recommend (a) here.** (b) is worth its own issue: it changes when the roguelite loop starts and is not a tutorial question.

8. **Should the existing foot prompts also read live bindings?**
   - (a) **Tutorial rows only.** Smaller change; the foot stays fixed text.
   - (b) Both, in one follow-up PR, because they are the same bug.
   - **Recommend (a) now, (b) as a follow-up issue.**

## 16. What this doc does not decide

The final copy of every row; the exact success thresholds in section 12 (placeholders); whether a beat-complete toast is used (it depends on the reduced-motion check); a tutorial for the late game (barons, Sol Central, the rescue project), which already has its own modals and notes; any title screen or main menu; localization beyond English and the pseudo locale; screen-reader support. None blocks tasks 1 and 2.
