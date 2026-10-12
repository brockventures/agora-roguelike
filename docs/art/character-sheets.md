# AGORA Location Character Sheets

Grounded source of truth for location visual consistency across all viewports. Part of #73 (Epic 6: Visual Identity & Art Asset Pipeline), aligned with Ryan's #lounge sign-offs.

---

## 🏛️ Invariant Rule of Character Consistency

Every location has a fixed set of physical and architectural design tokens. Whether viewed from high orbit (1:1 node) or in a command deck overview (4:3 card), **the same geographical landmarks, megastructures, and industrial silhouettes must persist verbatim**.

---

## 1. Sol (The Dying Star & Stabiliser)
- **Palette Tokens:** Ochre yellow (`#c99a2e`), bone white (`#e6dcc3`), ink black (`#1c1a17`), slate grey (`#2c353b`).
- **Surface / Stellar Anatomy:** Unstable, flaring amber sun with darkening coronal scars, volatile plasma ejection loops, and turbulent convection cells.
- **Megastructure Anchor:** The **Stabiliser** under construction. A massive curved skeletal industrial scaffolding framework encircling ~30-40% of the stellar limb with structural gantry clamps attempting to contain coronal eruptions.
- **Camera Viewports:**
  - *Tactical Node (1:1 - Live in Godot `tactical_map_panel`):* Macro star disk with prominent Stabiliser scaffolding arc and flaring limb. [Map Icon](../../game/assets/map_icons/sol_256.png)
  - *Crisis / Flare Card (4:3 - Live in Godot `card_panel`):* Close-up perspective along the scaffolding truss facing a massive solar prominence.

---

## 2. Earth (Orbital Graveyard & Kennedy Elevator)
- **Palette Tokens:** Desaturated teal ocean (`#2f6f6a`), warm amber/yellow atmospheric haze halo (`#c99a2e`), bone clouds (`#e6dcc3`), earthy paper-tan continents (`#d9cdb0`), slate scrap (`#2c353b`), rust accents (`#a8431f`).
- **Planetary Geography:** Desaturated teal ocean world with recognizable real continental outlines (Africa, Eurasia, the Americas) in earthy paper-tan, swirling white cloud bands, and a distinct warm yellow-amber atmospheric industrial haze glowing around the perimeter.
- **Megastructure Anchors:**
  1. **The Debris Shroud:** Dense, hazardous halo of dead satellites, scrap metal, and orbital wreckage encircling low Earth orbit. The orbital dock ring is half-buried directly inside this debris cloud. Zero free-flying cargo haulers.
  2. **The Space Elevator (Kennedy Elevator):** Leaves the planet at the 3 o'clock equatorial waist with a heavy base anchor structure on the limb. A straight, thick horizontal tension ribbon extends outward into the debris halo (~1 Earth radius long) without crossing in front of the planetary disk.
  3. **The Massive Orbital Station Hub:** Sprawling heavy industrial space station dock and counterweight hub at the outer head of the horizontal tether, distinctly massive and substantially wider than the ribbon.
- **Camera Viewports:**
  - *Tactical Node (1:1 - Live in Godot `tactical_map_panel`):* Full globe with recognizable continents, warm yellowed atmospheric rim haze, thick debris belt with half-buried dock ring, 3 o'clock horizontal elevator ribbon, and sprawling terminal orbital station hub. [Map Icon](../../game/assets/map_icons/earth_256.png)
  - *Overview Card (4:3 - Live in Godot `card_panel`):* Orbital vista showing Earth's recognizable coastlines, yellowed atmospheric haze, the thick cloud of dead satellites and scrap with the dock ring half-buried in it, and the elevator hub. No cargo haulers. [Card Proof](../screens/station-cards/card-earth.png)
  - *Proposed Extra Views (Pending Ryan approval in #lounge; no current Godot slot):*
    - *Arrival Vista / Spaceport (4:3):* Low-orbit approach looking along the elevator ribbon into the orbital dock ring enveloped in scrap.
    - *Trading Floor (4:3):* Pressurized freight transfer deck inside the orbital elevator hub overlooking Earth below.

---

## 3. Luna (The Interstellar Gas Station / Fuel Depot)
- **Station:** Luna Fuel Depot (working name).
- **Palette Tokens:** STRICT MONOCHROME GREYSCALE. Pale bone-white / light-grey highland regolith (`#e6dcc3`), dark charcoal / slate-black basalt maria (`#2c353b`), stark ink-black shadow cuts (`#1c1a17`). Zero rust, zero brown, zero yellow, zero ochre on the lunar surface.
- **Planetary Geography:** The authentic Moon. Realistic cratered highland regolith contrasted with stark, dark charcoal lunar basalt plains (maria) across the face.
- **Industrial Anchors:**
  1. **Perimeter Fuel Depot Spaceport:** Clustered strictly along the outer perimeter/limb of the moon (breaking the circular silhouette against black space, following the silhouette language of Mars's industrial structures per Ryan's #lounge direction).
  2. **Depot Geometry:** Clustered spherical pressurized fuel storage tanks, hexagonal illuminated landing pads with floodlights, fuel transfer pipelines, and overhead gantry crane arms projecting past the curved lunar limb.
  3. **Uncluttered Face:** The center disk remains clean cratered regolith and dark charcoal maria without surface sticker clutter.
- **Camera Viewports:**
  - *Tactical Node (1:1 - Live in Godot `tactical_map_panel`):* Pure monochrome moon disk with dark maria and perimeter-anchored fuel storage spheres and illuminated pads. [Map Icon](../../game/assets/map_icons/luna_256.png)
  - *Overview Card (4:3 - Live in Godot `card_panel`):* Low-orbit vista over lunar craters toward the illuminated fuel pads and tanker berths on the horizon. [Card Proof](../screens/station-cards/card-luna.png)
  - *Proposed Extra Views (Pending Ryan approval in #lounge; no current Godot slot):*
    - *Arrival Vista / Spaceport (4:3):* Descending approach over lunar craters toward the illuminated fuel pads and tanker berths in the mare basin.
    - *Trading Floor (4:3):* Gritty, pressurized propellant brokerage deck with fuel gauges and tanker docking airlocks.

---

## 4. Mars (Arcadia Foundries & Basin Seas)
- **Palette Tokens:** Rust-red bedrock (`#a8431f`), dark teal terraformed basin sea (`#2f6f6a`), bone-white polar ice (`#e6dcc3`), ink linework (`#1c1a17`).
- **Planetary Geography:** Rust-red desert bedrock, bone-white polar ice cap, and dark teal terraformed basin seas (strictly dark teal, zero bright green). Clean geological tectonic bedrock with zero fictional canyon scars or exaggerated split chasms.
- **Industrial Anchors:**
  1. **Arcadia Foundries & Spaceports:** Squat, heavy industrial manufacturing hubs, smelting stacks, dome habitats, and shipyard gantry towers rooted firmly onto the visible face of the planet along the shoreline/bedrock rim of the dark-teal basin sea. Foundries sit grounded on the planetary surface face, never projecting off or perched on the planet's outer limb.
  2. **Surface Domes:** Clustered pressurized dome habitats embedded in the bedrock near the basin sea.
- **Camera Viewports:**
  - *Tactical Node (1:1 - Live in Godot `tactical_map_panel`):* Mars globe showing dark-teal basin sea, polar cap, surface dome habitats, and foundries rooted onto the basin rim on the visible face. Clean outer limb. [Map Icon](../../game/assets/map_icons/mars_256.png)
  - *Overview Card (4:3 - Live in Godot `card_panel`):* Orbital vista looking across the terraformed basin sea at the dome habitats, spaceports, and foundry complex rooted on the bedrock shore. No canyon scar, no cargo haulers. [Card Proof](../screens/station-cards/card-mars.png)
  - *Proposed Extra Views (Pending Ryan approval in #lounge; no current Godot slot):*
    - *Arrival Vista / Spaceport (4:3):* Atmospheric entry angle sweeping past the foundry exhaust stacks and heavy orbital shipyard moorings.
    - *Trading Floor (4:3):* Heavy machinery trading exchange overlooking molten slag channels and fabrication bays.

---

## 5. Ceres (The Asteroid Mining Rig)
- **Station:** Agora Station, the system's main trading junction, built into the Ceres hub.
- **Palette Tokens:** Deep graphite slate (`#2c353b`), bone white impact ejecta (`#e6dcc3`), exposed ochre mineral veins (`#c99a2e`), ink black shadows (`#1c1a17`).
- **Geological Anatomy:** Deliberately stylized as an asymmetrical, craggy, heavily pockmarked grey asteroid rock with an irregular potato silhouette. While the real astronomical dwarf planet is in hydrostatic equilibrium (nearly round), this deliberate visual stylization ensures immediate silhouette readability and distinct contrast against spherical planets on the tactical map and card frames.
- **Industrial Anchors:**
  1. **Clamped Mining Gantry:** Massive structural truss scaffolds clamped directly onto the craggy rock ridges.
  2. **Extraction Rigging:** Deep core drill derricks, magnetic crane booms, and tethered mineral rock sleds trailing in zero-g.
- **Camera Viewports:**
  - *Tactical Node (1:1 - Live in Godot `tactical_map_panel`):* Craggy grey asteroid silhouette with external clamped gantry and tethered ore sleds. [Map Icon](../../game/assets/map_icons/ceres_256.png)
  - *Overview Card (4:3 - Live in Godot `card_panel`):* Wide view of the craggy asteroid with the clamped mining platform and trailing ore sleds. [Card Proof](../screens/station-cards/card-ceres.png)
  - *Proposed Extra Views (Pending Ryan approval in #lounge; no current Godot slot):*
    - *Arrival Vista / Spaceport (4:3):* Close approach along a tether cable toward the clamped asteroid mining platform.
    - *Trading Floor (4:3):* Cramped, zero-g roughneck ore exchange bolted directly into excavated asteroid rock.
