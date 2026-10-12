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

Grounded to `Transit.STATIONS` (earth, luna, mars, ceres). `station-*` are 1:1 tactical orbital nodes; `card-*` are 4:3 vignettes; `body-*` are Sol map bodies. Aligned with Ryan's #lounge sign-offs.

### station-earth
- batch: 6.3
- aspect: 1:1
- sample: yes
- source: Transit.STATIONS: earth
- prompt: Tactical map node icon: a blue-green ocean world with recognizable real continents, swirled white cloud bands, a warm yellow-amber atmospheric rim haze, a thick shroud of dead satellites and orbital scrap, an orbital dock ring half-buried in the debris, and a horizontal space elevator tether ribbon at the 3 o'clock equator ending at a massive orbital shipyard hub. Centered single subject, three-quarter view, generous empty margin, flat deep slate-black space behind, no stars beyond a few sparse dots.

### station-luna
- batch: 6.3
- aspect: 1:1
- sample: no
- source: Transit.STATIONS: luna
- prompt: Tactical map node icon: a pale monochrome cratered moon with dark charcoal basalt maria, long flat shadow cuts across craters, and a perimeter fuel depot spaceport with clustered spherical storage tanks and floodlit landing pads breaking the curved lunar limb. Zero rust, zero ochre, strictly monochrome greyscale. Centered single subject, three-quarter view, generous empty margin, flat deep slate-black space behind, no stars beyond a few sparse dots.

### station-mars
- batch: 6.3
- aspect: 1:1
- sample: yes
- source: Transit.STATIONS: mars
- prompt: Tactical map node icon: a rust-red desert world with dark-teal terraformed basin seas, polar ice cap in bone white, surface dome habitats, and squat industrial foundries and spaceports rooted firmly into bedrock on the visible face along the basin rim. Bold uniform-weight black ink contours, prominent linework around every structure, flat hard shadow cuts, clean outer limb. Centered single subject, three-quarter view, generous empty margin, flat deep slate-black space behind, no stars beyond a few sparse dots.

### station-ceres
- batch: 6.3
- aspect: 1:1
- sample: no
- source: Transit.STATIONS: ceres
- prompt: Tactical map node icon: a small asymmetrical dark rocky potato asteroid with pitted ochre mineral veins, a ragged mining platform clamped onto it and tethered ore sleds trailing in zero-g. Centered single subject, three-quarter view, generous empty margin, flat deep slate-black space behind, no stars beyond a few sparse dots.

### card-earth
- batch: 6.3
- aspect: 4:3
- sample: no
- ref: earth
- source: Transit.STATIONS: earth
- prompt: Card vignette illustration: wide view of a blue-green ocean world with recognizable real continents, swirled white cloud bands, a warm yellow-amber atmospheric rim haze, a thick hazardous cloud of dead satellites and metallic scrap in low orbit, the orbital dock ring half-buried in the debris, and the horizontal space elevator tether connecting to a massive orbital shipyard hub. Zero free-flying cargo haulers. Cinematic composition, low horizon, strong flat shadow cuts.

### card-luna
- batch: 6.3
- aspect: 4:3
- sample: no
- ref: luna
- source: Transit.STATIONS: luna
- prompt: Orbital vista of the cratered moon matching the reference icon: pale bone highland regolith sharply contrasted with large, prominent dark charcoal basalt maria plains across the lunar face, long flat shadow cuts across craters, and a perimeter fuel depot spaceport with clustered spherical tanks and floodlit landing pads breaking the curved lunar limb against deep slate-black space. Strict monochrome greyscale, high contrast between dark basalt maria and pale highlands, zero rust, zero ochre.

### card-mars
- batch: 6.3
- aspect: 4:3
- sample: no
- ref: mars
- source: Transit.STATIONS: mars
- prompt: Orbital vista showing the full planetary globe of Mars matching the reference icon: centered rust-red desert world against flat deep slate-black space, with dark-teal terraformed basin seas spreading across the visible face, a crisp bone-white polar ice cap, and squat industrial foundries and surface dome habitats rooted firmly into bedrock on the basin rim. Clean outer limb, zero canyon scars, zero cargo haulers. Bold uniform-weight black ink contours, prominent linework around every structure, flat hard shadow cuts.

### card-ceres
- batch: 6.3
- aspect: 4:3
- sample: no
- ref: ceres
- source: Transit.STATIONS: ceres
- prompt: Card vignette illustration: wide view of a small asymmetrical dark rocky potato asteroid with pitted ochre mineral veins, a ragged mining platform clamped onto it and tethered ore sleds trailing in zero-g. Cinematic composition, low horizon, strong flat shadow cuts.

### body-sol
- batch: 6.3
- aspect: 1:1
- sample: no
- source: Sol / planetary bodies
- prompt: Sol system map body: the Sun as a flat ochre disc with a few clean concentric corona bands, flaring prominence loops, and the skeletal curved Stabiliser gantry truss scaffolding arc hugging the stellar limb. Centered single subject, flat deep slate-black space behind, generous empty margin.

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
- ref: hull-hauler
- source: dynamic map transit icons
- prompt: Tiny map transit marker icon: top-down plan view seen directly from above, pointing straight up. The hauler hull reduced to a bold readable rectangular silhouette with a blunt nose at the top and a flared rear thruster bell at the bottom, in ochre (#c99a2e) armor and dark ink (#1c1a17) structure with thick ink outlines. Exactly one single vessel, centered, filling 85% of the frame. No insets, no circular badges, no frames, no other ships, centered on a plain flat pale paper background.

### icon-interceptor
- batch: 6.4
- aspect: 1:1
- sample: no
- ref: hull-interceptor
- source: dynamic map transit icons
- prompt: Tiny map transit marker icon: top-down plan view seen directly from above, pointing straight up. The interceptor hull reduced to a sharp wedge chevron silhouette pointing up, with swept rust-red (#a8431f) wings, bone-white (#e6dcc3) fuselage accents, and twin aft thrusters with thick ink outlines. Exactly one single vessel, centered, filling 85% of the frame, on a plain flat pale paper background.

### icon-freighter
- batch: 6.4
- aspect: 1:1
- sample: no
- ref: hull-freighter
- source: dynamic map transit icons
- prompt: Tiny map transit marker icon: top-down plan view seen directly from above, pointing straight up. The freighter hull reduced to a long elongated central bar spine with cross-strut cargo racks in dark teal-green (#2f6f6a), bone-white (#e6dcc3) forward bridge pod at the top, and a wide heavy engine block at the bottom with thick ink outlines. Exactly one single vessel, centered, filling 85% of the frame. No secondary ships, no cut-off objects, centered on a plain flat pale paper background.

### icon-scout
- batch: 6.4
- aspect: 1:1
- sample: no
- ref: hull-scout
- source: dynamic map transit icons
- prompt: Tiny map transit marker icon: top-down plan view seen directly from above, pointing straight up. The scout hull reduced to a bold readable dart-like silhouette with a forward sensor antenna spike pointing up at the top, bubble canopy, bone-white (#e6dcc3) hull with dark ink (#1c1a17) accents, and a slim aft drive with thick ink outlines. Exactly one large single vessel, centered, filling 85% of the frame, on a plain flat pale paper background.

### icon-scrap_barge
- batch: 6.4
- aspect: 1:1
- sample: no
- ref: hull-scrap_barge
- source: dynamic map transit icons
- prompt: Tiny map transit marker icon: top-down plan view seen directly from above, pointing straight up. The scrap barge hull reduced to an asymmetrical, blocky industrial salvage rig silhouette pointing up with crane booms extending outward, in dark ink-grey (#1c1a17) with bone-white (#e6dcc3) salvage plates and thick ink outlines. Strictly ink and bone tones, no rust, no teal. Exactly one large single vessel, centered, filling 85% of the frame, on a plain flat pale paper background.

## Batch 6.5: encounter deck (16 cards, 4:3)

Eleven cards come 1:1 from real ids in `game/data/crises.json` (the 8 standard and 3 opportunistic crises); CME flare, storm delay, and hull breach come from `hazards.gd`; pirate raid and dark run come from `corridors.gd`.

### card-antitrust-audit
- batch: 6.5
- aspect: 4:3
- sample: yes
- source: antitrust_audit
- prompt: Encounter card illustration, wide 4:3 composition: Regulatory auditors boarding a trading station: a row of stern officials in plain grey coats inspecting stacked crates under a harsh overhead lamp, an empty hearing podium and a scale of justice emblem-free, rust-red warning light.

### card-emergency-antitrust-sweep
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

### card-supply-chain-shortage
- batch: 6.5
- aspect: 4:3
- sample: no
- source: supply_chain_shortage
- prompt: Encounter card illustration, wide 4:3 composition: A stalled convoy of cargo haulers parked dead in a dark lane, thrusters cold, a stranded dock crane waiting beside an empty berth.

### card-systemic-margin-collapse
- batch: 6.5
- aspect: 4:3
- sample: no
- source: systemic_margin_collapse
- prompt: Encounter card illustration, wide 4:3 composition: A trading floor in cascade collapse: shattered holographic panels, scattered paper slips, a toppled chair and rust-red emergency light, traders frozen in alarm.

### card-ares-retaliation
- batch: 6.5
- aspect: 4:3
- sample: no
- source: ares_retaliation
- prompt: Encounter card illustration, wide 4:3 composition: Heavy industrial enforcers from a rust-coloured arms combine calling in debts: broad-shouldered figures in heavy suits at a dock gangway, a ledger-less contract slab held out menacingly.

### card-titan-retaliation
- batch: 6.5
- aspect: 4:3
- sample: no
- source: titan_retaliation
- prompt: Encounter card illustration, wide 4:3 composition: A frozen cryo-hydro depot sealed shut: icy blockade barriers across a dock, frost-covered tanks, teal glow, a lone trader locked outside.

### card-sol-retaliation
- batch: 6.5
- aspect: 4:3
- sample: no
- source: sol_retaliation
- prompt: Encounter card illustration, wide 4:3 composition: A central government audit fleet looming over a small trader ship, a tall pale-bone administrative tower station behind, one beam locking onto the hull.

### card-ares-opportunistic-squeeze
- batch: 6.5
- aspect: 4:3
- sample: no
- source: ares_opportunistic_squeeze
- prompt: Encounter card illustration, wide 4:3 composition: Ares Heavy syndicate market squeeze: armored industrial syndicate managers in heavy rust-trimmed work suits watching an automated order terminal flicker, bulk gantry cranes idling, traders negotiating under harsh orange sodium worklights.

### card-titan-opportunistic-hoard
- batch: 6.5
- aspect: 4:3
- sample: no
- source: titan_opportunistic_hoard
- prompt: Encounter card illustration, wide 4:3 composition: Titan Cryo-Hydro hoarding market supply: massive frost-caked propellant storage spheres sealed behind security barricades, automated cryo-pumps draining terminal fuel lines, chilled teal vapor clouds, dock workers standing locked out at the gate.

### card-sol-opportunistic-levy
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
### card-storm-delay
- batch: 6.5
- aspect: 4:3
- sample: no
- source: hazards.P_DELAY
- prompt: Encounter card illustration, wide 4:3 composition: A cargo vessel caught in a high-radiation solar storm: ion turbulence battering the hull, glowing static discharges along radiator panels, a blown thruster coil glowing hot while crew race to repair propulsion in zero-g.

### card-hull-breach
- batch: 6.5
- aspect: 4:3
- sample: no
- source: hazards.P_LOSS
- prompt: Encounter card illustration, wide 4:3 composition: Micro-meteoroid puncture and containment breach: a jagged tear along a container rack, frozen atmosphere venting into the void in white vapor crystals, cargo canisters spilling loose into zero-g.

### card-pirate-raid
- batch: 6.5
- aspect: 4:3
- sample: no
- source: corridors.piracy
- prompt: Encounter card illustration, wide 4:3 composition: A pirate raider ambush in the asteroid belt: a ragged raider swooping out of a rock shadow toward a lone hauler, magnetic grappling lines flying, dust and debris, rust-red running lights.

### card-dark-run
- batch: 6.5
- aspect: 4:3
- sample: no
- source: corridors.dark_run
- prompt: Encounter card illustration, wide 4:3 composition: Running silent on the unmonitored Mars-Ceres Dark Run: a blacked-out hauler slipping through a craggy asteroid trench with running lights extinguished, illicit fluid canisters strapped to the keel, scanning sensors sweeping harmlessly overhead.
