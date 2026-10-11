# AGORA Location Character Sheets

Grounded source of truth for location visual consistency across all viewports. Part of #73 (Epic 6: Visual Identity & Art Asset Pipeline).

---

## 🏛️ Invariant Rule of Character Consistency

Every location has a fixed set of physical and architectural design tokens. Whether viewed from high orbit (1:1 node) or in a command deck overview (4:3 card), **the same geographical landmarks, megastructures, and industrial silhouettes must persist verbatim**.

---

## 1. Sol (The Dying Star & Stabiliser)
- **Palette Tokens:** Ochre yellow (`#c99a2e`), bone white (`#e6dcc3`), ink black (`#1c1a17`), slate grey (`#2c353b`).
- **Surface / Stellar Anatomy:** Unstable, flaring amber sun with darkening coronal scars, volatile plasma ejection loops, and turbulent convection cells.
- **Megastructure Anchor:** The **Stabiliser** under construction. A massive curved skeletal industrial scaffolding framework encircling ~30-40% of the stellar limb with structural gantry clamps attempting to contain coronal eruptions.
- **Camera Viewports:**
  - *Tactical Node (1:1 - Live in Godot `tactical_map_panel`):* Macro star disk with prominent Stabiliser scaffolding arc and flaring limb.
  - *Crisis / Flare Card (4:3 - Live in Godot `card_panel`):* Close-up perspective along the scaffolding truss facing a massive solar prominence.

---

## 2. Earth (Orbital Graveyard & Kennedy Elevator)
- **Palette Tokens:** Desaturated teal ocean (`#2f6f6a`), earthy paper-tan continents (`#d9cdb0`), atmospheric yellow/ochre haze (`#c99a2e`), slate scrap (`#2c353b`), rust accents (`#a8431f`).
- **Planetary Geography:** Desaturated teal ocean world with recognizable real continental outlines (Africa, Eurasia, Americas) in earthy paper-tan, swirling white cloud bands, and a warm yellowed/ochre atmospheric haze on the perimeter.
- **Megastructure Anchors:**
  1. **The Debris Shroud:** Dense, hazardous halo of dead satellites, scrap metal, and orbital wreckage encircling low Earth orbit.
  2. **The Space Elevator (Kennedy Elevator):** Leaves the planet at the 3 o'clock equatorial waist with a heavy base anchor structure on the limb. A straight, thick horizontal tension ribbon extends outward into the debris halo (~1 Earth radius long) without crossing in front of the planetary disk.
  3. **The Orbital Station Hub:** Sprawling heavy industrial space station dock and counterweight hub at the outer head of the horizontal tether, distinctly wider than the ribbon.
- **Camera Viewports:**
  - *Tactical Node (1:1 - Live in Godot `tactical_map_panel`):* Full globe with recognizable continents, yellowed atmospheric rim haze, debris belt, 3 o'clock horizontal elevator ribbon, and terminal orbital station hub.
  - *Overview Card (4:3 - Live in Godot `card_panel`):* Orbital vista showing Earth's recognizable coastlines, yellowed atmospheric haze, and the elevator hub with docked haulers.
  - *Proposed Extra Views (Pending Ryan approval in #lounge; no current Godot slot):*
    - *Arrival Vista / Spaceport (4:3):* Low-orbit approach looking along the elevator ribbon into the orbital dock ring.
    - *Trading Floor (4:3):* Pressurized freight transfer deck inside the orbital elevator hub overlooking Earth below.

---

## 3. Luna (The Interstellar Gas Station / Fuel Depot)
- **Palette Tokens:** Pale bone-grey regolith (`#e6dcc3`), dark slate-blue basalt maria (`#2c353b`), ink shadow cuts (`#1c1a17`), ochre industrial framing (`#c99a2e`).
- **Planetary Geography:** The authentic Moon. Realistic cratered highland regolith contrasted with stark, dark lunar basalt plains (maria) across the face.
- **Industrial Anchors:**
  1. **Perimeter Fuel Depot Spaceport:** Clustered strictly along the outer perimeter/limb of the moon (breaking the circular silhouette against black space, matching Mars's industrial silhouette contrast).
  2. **Depot Geometry:** Clustered spherical pressurized fuel storage tanks, hexagonal illuminated landing pads with floodlights, fuel transfer pipelines, and overhead gantry crane arms projecting past the curved lunar limb.
  3. **Uncluttered Face:** The center disk remains clean cratered regolith and maria without surface sticker clutter.
- **Camera Viewports:**
  - *Tactical Node (1:1 - Live in Godot `tactical_map_panel`):* Pale moon disk with dark maria and perimeter-anchored fuel storage spheres and illuminated pads.
  - *Overview Card (4:3 - Live in Godot `card_panel`):* Low-orbit vista over lunar craters toward the illuminated fuel pads and tanker berths on the horizon.
  - *Proposed Extra Views (Pending Ryan approval in #lounge; no current Godot slot):*
    - *Arrival Vista / Spaceport (4:3):* Descending approach over lunar craters toward the illuminated fuel pads and tanker berths.
    - *Trading Floor (4:3):* Gritty, pressurized propellant brokerage deck with fuel gauges and tanker docking airlocks.

---

## 4. Mars (Arcadia Foundries & Basin Seas)
- **Palette Tokens:** Rust-red bedrock (`#a8431f`), dark teal terraformed basin sea (`#2f6f6a`), bone-white polar ice (`#e6dcc3`), ink linework (`#1c1a17`).
- **Planetary Geography:** Rust-red desert bedrock, bone-white polar ice cap, and dark teal terraformed basin seas (strictly dark teal, zero bright green).
- **Industrial Anchors:**
  1. **Arcadia Foundries:** Squat, heavy industrial manufacturing hubs, smelting stacks, and shipyard gantry towers rooted firmly onto the visible face of the planet along the shoreline/bedrock rim of the basin sea. Foundries sit grounded on the planetary surface face, never projecting off or perched on the planet's outer limb.
  2. **No Fictional Canyons:** Clean geological tectonic bedrock without exaggerated split chasms.
- **Camera Viewports:**
  - *Tactical Node (1:1 - Live in Godot `tactical_map_panel`):* Mars globe showing teal basin sea, polar cap, and foundries rooted onto the basin rim on the visible face.
  - *Overview Card (4:3 - Live in Godot `card_panel`):* Orbital vista looking across the terraformed basin sea at the foundry complex rooted on the bedrock shore.
  - *Proposed Extra Views (Pending Ryan approval in #lounge; no current Godot slot):*
    - *Arrival Vista / Spaceport (4:3):* Atmospheric entry angle sweeping past the foundry exhaust stacks and heavy orbital shipyard moorings.
    - *Trading Floor (4:3):* Heavy machinery trading exchange overlooking molten slag channels and fabrication bays.

---

## 5. Ceres (The Asteroid Mining Rig)
- **Palette Tokens:** Deep graphite slate (`#2c353b`), bone white impact ejecta (`#e6dcc3`), exposed ochre mineral veins (`#c99a2e`), ink black shadows (`#1c1a17`).
- **Geological Anatomy:** Deliberately stylized as an asymmetrical, craggy, heavily pockmarked grey asteroid rock with an irregular potato silhouette. While the real astronomical dwarf planet is in hydrostatic equilibrium (nearly round), this deliberate visual stylization ensures immediate silhouette readability and distinct contrast against spherical planets on the tactical map and card frames.
- **Industrial Anchors:**
  1. **Clamped Mining Gantry:** Massive structural truss scaffolds clamped directly onto the craggy rock ridges.
  2. **Extraction Rigging:** Deep core drill derricks, magnetic crane booms, and tethered mineral rock sleds trailing in zero-g.
- **Camera Viewports:**
  - *Tactical Node (1:1 - Live in Godot `tactical_map_panel`):* Craggy grey asteroid silhouette with external clamped gantry and tethered ore sleds.
  - *Overview Card (4:3 - Live in Godot `card_panel`):* Wide view of the craggy asteroid with the clamped mining platform and trailing ore sleds.
  - *Proposed Extra Views (Pending Ryan approval in #lounge; no current Godot slot):*
    - *Arrival Vista / Spaceport (4:3):* Close approach along a tether cable toward the clamped asteroid mining platform.
    - *Trading Floor (4:3):* Cramped, zero-g roughneck ore exchange bolted directly into excavated asteroid rock.
