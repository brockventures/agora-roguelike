# AGORA art prompt bible

Source of truth for `tools/art/generate.py`. The harness parses the entries below, so keep the entry format exactly. Part of #73 (Epic 6: Visual Identity & Art Asset Pipeline), sub-task 6.2.

## Invariants (from #73)

1. 100% text-free rasters. Typography, telemetry, labels, numbers and stats are rendered in Godot for #40 (localization).
2. Zero real-world brand names, trademarks or logos; zero fake signatures or watermarks.
3. Per-batch human sample gate: a 1-2 piece sample is signed off by @brockventures before a full run of that batch.
4. Cards are pure 4:3 viewports inside Godot Control frames.

## Influence

The approved v2 Heavy Cel register draws on the animated series *Scavengers Reign* and the work of Luke Humphris. These are named here as influence only. They are never written into a prompt, and `tools/art/banned_terms.txt` refuses any prompt that names them.

## Palette (design tokens)

The style block names colors in words; the matching tokens from `docs/design-system/tokens/colors.css` are: ink `#1c1a17`, slate `#2c353b`, bone `#e6dcc3`, paper `#d9cdb0`, ochre `#c99a2e`, rust `#a8431f`, teal `#2f6f6a`. Hex codes stay out of prompts on purpose, since image models sometimes paint them as text.

## Style block

Prepended to every prompt.

```
Heavy ligne claire illustration: confident, uniform-weight black ink contours around every shape, flat graphic shadow cuts with hard edges (no gradients, no airbrushing, no glow, no photographic texture), flat fills with at most two tones per surface, muted mineral and rust palette of ink black, slate blue-grey, bone cream, paper tan, ochre, rust red and deep teal, desaturated and earthy. Quiet, lonely, lived-in industrial science fiction mood, hand-drawn animation background feel, clear readable silhouettes.
```

## Negative prompt block

Gemini image models take no separate negative field, so the harness appends this as an "Avoid:" clause, after a fixed text-free sentence.

```
text, letters, words, numbers, digits, captions, labels, subtitles, speech bubbles, UI, HUD, interface, telemetry, gauges with numerals, signs with writing, logos, brand names, trademarks, emblems of real organizations, flags of real countries, watermarks, signatures, artist signatures, stamps, photorealism, 3D render, glossy gradients, neon glow, lens flare, bloom, motion blur, noise, film grain, frames, borders, vignettes, drop shadows, multiple panels, collage
```

## Entry format

Each entry is a `###` heading with the asset id, then `batch`, `aspect`, `sample` (`yes` marks a #73 sample-gate piece), `source` (what in the game grounds it) and `prompt`. Cards (batch 6.5) must be `4:3`.

Sample gates from #73: 6.3 Earth + Mars, 6.4 Hauler, 6.5 Audit + Flare.

## Batch 6.3: stations and Sol bodies

Grounded to `Transit.STATIONS` (earth, luna, mars, ceres). `station-*` are 1:1 tactical orbital nodes; `card-*` are 4:3 vignettes; `body-*` are Sol map bodies.

### station-earth
- batch: 6.3
- aspect: 1:1
- sample: yes
- source: Transit.STATIONS: earth
- prompt: Tactical map node icon: a blue-green ocean world with swirled white cloud bands and one dark continent mass, a thin orbital ring of docks hugging it. Centered single subject, three-quarter view, generous empty margin, flat deep slate-black space behind, no stars beyond a few sparse dots.

### station-luna
- batch: 6.3
- aspect: 1:1
- sample: no
- source: Transit.STATIONS: luna
- prompt: Tactical map node icon: a pale grey cratered moon with long flat shadow cuts across the craters and a small cluster of dome habitats on its rim. Centered single subject, three-quarter view, generous empty margin, flat deep slate-black space behind, no stars beyond a few sparse dots.

### station-mars
- batch: 6.3
- aspect: 1:1
- sample: yes
- source: Transit.STATIONS: mars
- prompt: Tactical map node icon: a rust-red desert world with a dark canyon scar, polar ice cap in bone white and a squat industrial dock tower on the limb. Centered single subject, three-quarter view, generous empty margin, flat deep slate-black space behind, no stars beyond a few sparse dots.

### station-ceres
- batch: 6.3
- aspect: 1:1
- sample: no
- source: Transit.STATIONS: ceres
- prompt: Tactical map node icon: a small dark rocky dwarf planet with pitted ochre mineral veins, a ragged mining platform clamped onto it and tethered ore sleds. Centered single subject, three-quarter view, generous empty margin, flat deep slate-black space behind, no stars beyond a few sparse dots.

### card-earth
- batch: 6.3
- aspect: 4:3
- sample: no
- source: Transit.STATIONS: earth
- prompt: Card vignette illustration: wide view of a blue-green ocean world with swirled white cloud bands and one dark continent mass, a thin orbital ring of docks hugging it, with a small cargo hauler silhouette crossing in the foreground. Cinematic composition, low horizon, strong flat shadow cuts.

### card-luna
- batch: 6.3
- aspect: 4:3
- sample: no
- source: Transit.STATIONS: luna
- prompt: Card vignette illustration: wide view of a pale grey cratered moon with long flat shadow cuts across the craters and a small cluster of dome habitats on its rim, with a small cargo hauler silhouette crossing in the foreground. Cinematic composition, low horizon, strong flat shadow cuts.

### card-mars
- batch: 6.3
- aspect: 4:3
- sample: no
- source: Transit.STATIONS: mars
- prompt: Card vignette illustration: wide view of a rust-red desert world with a dark canyon scar, polar ice cap in bone white and a squat industrial dock tower on the limb, with a small cargo hauler silhouette crossing in the foreground. Cinematic composition, low horizon, strong flat shadow cuts.

### card-ceres
- batch: 6.3
- aspect: 4:3
- sample: no
- source: Transit.STATIONS: ceres
- prompt: Card vignette illustration: wide view of a small dark rocky dwarf planet with pitted ochre mineral veins, a ragged mining platform clamped onto it and tethered ore sleds, with a small cargo hauler silhouette crossing in the foreground. Cinematic composition, low horizon, strong flat shadow cuts.

### body-sol
- batch: 6.3
- aspect: 1:1
- sample: no
- source: Sol / planetary bodies
- prompt: Sol system map body: the Sun as a flat ochre disc with a few clean concentric corona bands and bold black ink rim. Centered single subject, flat deep slate-black space behind, generous empty margin.

### body-mercury
- batch: 6.3
- aspect: 1:1
- sample: no
- source: Sol / planetary bodies
- prompt: Sol system map body: a tiny scorched grey-brown cratered planet with a hard terminator line. Centered single subject, flat deep slate-black space behind, generous empty margin.

### body-venus
- batch: 6.3
- aspect: 1:1
- sample: no
- source: Sol / planetary bodies
- prompt: Sol system map body: a thick ochre-cream cloud world with swirling flat bands and a rust haze edge. Centered single subject, flat deep slate-black space behind, generous empty margin.

### body-jupiter
- batch: 6.3
- aspect: 1:1
- sample: no
- source: Sol / planetary bodies
- prompt: Sol system map body: a banded gas giant in rust, ochre and bone stripes with one large storm eye and flat shadow cuts. Centered single subject, flat deep slate-black space behind, generous empty margin.

### body-saturn
- batch: 6.3
- aspect: 1:1
- sample: no
- source: Sol / planetary bodies
- prompt: Sol system map body: a ringed gas giant in muted ochre and bone, ring drawn as clean ink-outlined ellipses with a flat shadow cut across the planet. Centered single subject, flat deep slate-black space behind, generous empty margin.

## Batch 6.4: hulls, damage overlays, map icons

The five archetypes match `FleetView.ARCHETYPES` and `FLEET_ARCH_TONES` in `game/scenes/main.gd`. Backgrounds are a plain flat pale ground so they can be keyed out in 6.6.

### hull-hauler
- batch: 6.4
- aspect: 3:2
- sample: yes
- source: FLEET_ARCH_TONES: HAULER, ochre tone
- prompt: Spaceship hull design sheet, strict side profile facing right: a blunt workhorse cargo hauler with stacked cylindrical cargo pods, ochre hull plates and a single big thruster bell. Single vessel, centered, plain flat pale paper background for later cut-out, no cast ground shadow.

### hull-interceptor
- batch: 6.4
- aspect: 3:2
- sample: no
- source: FLEET_ARCH_TONES: INTERCEPTOR, rust tone
- prompt: Spaceship hull design sheet, strict side profile facing right: a sleek angular interceptor with swept rust-red wings, a narrow cockpit and twin small thrusters. Single vessel, centered, plain flat pale paper background for later cut-out, no cast ground shadow.

### hull-freighter
- batch: 6.4
- aspect: 3:2
- sample: no
- source: FLEET_ARCH_TONES: FREIGHTER, teal tone
- prompt: Spaceship hull design sheet, strict side profile facing right: a long heavy freighter with a teal-green spine, many container stacks and a wide engine block. Single vessel, centered, plain flat pale paper background for later cut-out, no cast ground shadow.

### hull-scout
- batch: 6.4
- aspect: 3:2
- sample: no
- source: FLEET_ARCH_TONES: SCOUT, bone tone
- prompt: Spaceship hull design sheet, strict side profile facing right: a small light scout craft in bone white with a long antenna mast, a bubble cockpit and a slim engine. Single vessel, centered, plain flat pale paper background for later cut-out, no cast ground shadow.

### hull-scrap_barge
- batch: 6.4
- aspect: 3:2
- sample: no
- source: FLEET_ARCH_TONES: SCRAP_BARGE, ink tone
- prompt: Spaceship hull design sheet, strict side profile facing right: a patched-together scrap barge in dark ink-grey with mismatched rust panels, welded cranes and a magnet grab slung underneath. Single vessel, centered, plain flat pale paper background for later cut-out, no cast ground shadow.

### damage-light
- batch: 6.4
- aspect: 3:2
- sample: no
- source: hull_pct / shield_pct damage states
- prompt: Damage overlay study for a spaceship hull: scattered scorch marks and a few small dents with thin ink cracks. Drawn on a plain flat pale paper background with no ship body, only the damage marks, heavy ink linework, for later compositing.

### damage-heavy
- batch: 6.4
- aspect: 3:2
- sample: no
- source: hull_pct / shield_pct damage states
- prompt: Damage overlay study for a spaceship hull: large torn plating, exposed ribs, dark char streaks and a venting breach. Drawn on a plain flat pale paper background with no ship body, only the damage marks, heavy ink linework, for later compositing.

### damage-breach
- batch: 6.4
- aspect: 3:2
- sample: no
- source: hull_pct / shield_pct damage states
- prompt: Damage overlay study for a spaceship hull: a gaping hull breach with bent frame members and frozen debris shards. Drawn on a plain flat pale paper background with no ship body, only the damage marks, heavy ink linework, for later compositing.

### icon-hauler
- batch: 6.4
- aspect: 1:1
- sample: no
- source: dynamic map transit icons
- prompt: Tiny map transit marker icon: the hauler hull reduced to a bold readable silhouette seen from above, pointing up, thick ink outline, two flat colors plus black, centered on a plain flat pale background.

### icon-interceptor
- batch: 6.4
- aspect: 1:1
- sample: no
- source: dynamic map transit icons
- prompt: Tiny map transit marker icon: the interceptor hull reduced to a bold readable silhouette seen from above, pointing up, thick ink outline, two flat colors plus black, centered on a plain flat pale background.

### icon-freighter
- batch: 6.4
- aspect: 1:1
- sample: no
- source: dynamic map transit icons
- prompt: Tiny map transit marker icon: the freighter hull reduced to a bold readable silhouette seen from above, pointing up, thick ink outline, two flat colors plus black, centered on a plain flat pale background.

### icon-scout
- batch: 6.4
- aspect: 1:1
- sample: no
- source: dynamic map transit icons
- prompt: Tiny map transit marker icon: the scout hull reduced to a bold readable silhouette seen from above, pointing up, thick ink outline, two flat colors plus black, centered on a plain flat pale background.

### icon-scrap_barge
- batch: 6.4
- aspect: 1:1
- sample: no
- source: dynamic map transit icons
- prompt: Tiny map transit marker icon: the scrap barge hull reduced to a bold readable silhouette seen from above, pointing up, thick ink outline, two flat colors plus black, centered on a plain flat pale background.

## Batch 6.5: encounter deck (12 cards, 4:3)

Nine cards come from real ids in `game/data/crises.json`; CME flare, pirate ambush and black market come from the hazard, piracy and underworld systems named in `source`. The remaining crises (e.g. `ares_opportunistic_squeeze`, `titan_opportunistic_hoard`) are left for a later pass.

### card-antitrust-audit
- batch: 6.5
- aspect: 4:3
- sample: yes
- source: antitrust_audit
- prompt: Encounter card illustration, wide 4:3 composition: Regulatory auditors boarding a trading station: a row of stern officials in plain grey coats inspecting stacked crates under a harsh overhead lamp, an empty hearing podium and a scale of justice emblem-free, rust-red warning light.

### card-emergency-sweep
- batch: 6.5
- aspect: 4:3
- sample: no
- source: emergency_antitrust_sweep
- prompt: Encounter card illustration, wide 4:3 composition: An emergency enforcement sweep: armored patrol cutters swarming a trading dock with searchlight beams, crates being sealed with plain bands, panicked traders at the rail.

### card-localized-shortage
- batch: 6.5
- aspect: 4:3
- sample: no
- source: localized_shortage
- prompt: Encounter card illustration, wide 4:3 composition: A bare Mars warehouse: rows of empty shelves and one lonely crate, a dust-red window onto the desert, a worker shrugging beside an empty loading lift.

### card-supply-chain-stall
- batch: 6.5
- aspect: 4:3
- sample: no
- source: supply_chain_shortage
- prompt: Encounter card illustration, wide 4:3 composition: A stalled convoy of cargo haulers parked dead in a dark lane, thrusters cold, a stranded dock crane waiting beside an empty berth.

### card-margin-collapse
- batch: 6.5
- aspect: 4:3
- sample: no
- source: systemic_margin_collapse
- prompt: Encounter card illustration, wide 4:3 composition: A trading floor in cascade collapse: shattered holographic panels, scattered paper slips, a toppled chair and rust-red emergency light, traders frozen in alarm.

### card-ares-markers
- batch: 6.5
- aspect: 4:3
- sample: no
- source: ares_retaliation
- prompt: Encounter card illustration, wide 4:3 composition: Heavy industrial enforcers from a rust-coloured arms combine calling in debts: broad-shouldered figures in heavy suits at a dock gangway, a ledger-less contract slab held out menacingly.

### card-titan-embargo
- batch: 6.5
- aspect: 4:3
- sample: no
- source: titan_retaliation
- prompt: Encounter card illustration, wide 4:3 composition: A frozen cryo-hydro depot sealed shut: icy blockade barriers across a dock, frost-covered tanks, teal glow, a lone trader locked outside.

### card-sol-audit
- batch: 6.5
- aspect: 4:3
- sample: no
- source: sol_retaliation
- prompt: Encounter card illustration, wide 4:3 composition: A central government audit fleet looming over a small trader ship, a tall pale-bone administrative tower station behind, one beam locking onto the hull.

### card-sol-levy
- batch: 6.5
- aspect: 4:3
- sample: no
- source: sol_opportunistic_levy
- prompt: Encounter card illustration, wide 4:3 composition: A surprise levy at a dock: a toll gate dropping across a berth, officials sliding a heavy strongbox into a collection hopper while a trader hands over crates.

### card-cme-flare
- batch: 6.5
- aspect: 4:3
- sample: yes
- source: hazards.check_cme_relay_interference
- prompt: Encounter card illustration, wide 4:3 composition: A coronal mass ejection engulfing the inner system: a huge ochre and rust solar flare arc rolling toward a small hauler, radio relay dishes sparking, shock-front bands rippling through space.

### card-pirate-ambush
- batch: 6.5
- aspect: 4:3
- sample: no
- source: agora/piracy.py
- prompt: Encounter card illustration, wide 4:3 composition: A pirate ambush in the asteroid belt: a ragged raider swooping out of a rock shadow toward a lone hauler, grappling lines flying, dust and debris, rust-red running lights.

### card-black-market
- batch: 6.5
- aspect: 4:3
- sample: no
- source: tests/test_underworld_syndicate.py (underworld syndicate)
- prompt: Encounter card illustration, wide 4:3 composition: A black-market deal in a dim docking bay: two hooded figures trading a sealed crate under a swinging lamp, stacked contraband barrels, a lookout watching the shadows.
