# AGORA Encounter Deck Character Sheets

Grounded source of truth for encounter card illustrations across the 4:3 viewport in `card_panel` (`game/scenes/main.gd`). Part of #73 (Epic 6: Visual Identity & Art Asset Pipeline), sub-task 6.5.

---

## 🃏 Invariant Rule of Encounter Consistency

Every encounter card represents an active crisis, regulatory enforcement, corporate retaliation, space hazard, or underworld event in the Sol system. Cards are rendered as pure **4:3 viewports** inside Godot's `card_panel` Control frame. Telemetry, crisis tier headers, expiration round counters, and systemic trade effects are rendered dynamically in Godot for #40 localization. The raster artwork must remain **100% text-free**.

---

## 🎨 Visual Grammar & Design Rules

1. **Heavy Ligne Claire:** Uniform-weight black ink contours (`#1c1a17`), flat hard graphic shadow cuts (no gradients, no glow, no airbrushing), flat fills with at most two tones per surface.
2. **Palette Tokens:** Muted mineral and rust palette from `docs/design-system/tokens/colors.css`:
   - Ink: `#1c1a17`
   - Slate: `#2c353b`
   - Bone: `#e6dcc3`
   - Paper: `#d9cdb0`
   - Ochre: `#c99a2e`
   - Rust: `#a8431f`
   - Teal: `#2f6f6a`
3. **Framing & Aspect:** Pure 4:3 aspect ratio (`1152x864` source, scaled dynamically in Godot to `160x120` px or scaled variants). Cinematic, readable silhouettes with clear focal subjects.
4. **Text-Free Invariant:** Zero letters, numbers, captions, signs with writing, emblems of real organizations, or artist watermarks.

---

## 1. Regulatory Crises (Antitrust & Enforcement)

### `card-antitrust-audit` (Sample Gate)
- **Source:** `game/data/crises.json: antitrust_audit`
- **Theme:** Government scrutiny, bureaucratic weight, warehouse inspections.
- **Visual Anatomy:** A squad of stern regulatory officials in grey trench coats boarding an industrial warehouse dock; harsh conical overhead floodlamp illuminating stacked shipping crates; an empty hearing podium with an emblem-free scale of justice; glowing rust-red inspection light.

### `card-emergency-sweep`
- **Source:** `game/data/crises.json: emergency_antitrust_sweep`
- **Theme:** Urgent militarized regulatory raid.
- **Visual Anatomy:** Armored customs cutters swarming a station docking slip with crossing searchlight beams; shipping containers being sealed with magnetic security bands; dockworkers and traders scattering from gangways.

---

## 2. Supply Chain & Market Collapses

### `card-localized-shortage`
- **Source:** `game/data/crises.json: localized_shortage`
- **Theme:** Depleted planetary stocks, logistical drought.
- **Visual Anatomy:** Cavernous Mars subterranean warehouse with endless rows of barren shelving; a single lonely crate under an amber worklight; a rust-red window overlooking the dusty Martian desert; a worker gesturing at an empty freight lift.

### `card-supply-chain-stall`
- **Source:** `game/data/crises.json: supply_chain_shortage`
- **Theme:** Chokepoints, dead transit corridors.
- **Visual Anatomy:** A frozen convoy of heavy haulers parked bumper-to-bumper along a dark transit lane with cold, unlit thrusters; a stranded station cargo crane poised above an empty berth.

### `card-margin-collapse`
- **Source:** `game/data/crises.json: systemic_margin_collapse`
- **Theme:** Financial panic, cascading liquidations.
- **Visual Anatomy:** Chaos across an orbital trading exchange floor; shattered glass-slate holographic quote boards; scattered physical paper transaction slips; toppled operator stools; stark rust-red emergency strobes reflecting on alarmed traders.

---

## 3. Baron Retaliations & Sanctions

### `card-ares-markers`
- **Source:** `game/data/crises.json: ares_retaliation`
- **Theme:** Heavy industrial syndicate calling in debts.
- **Visual Anatomy:** Heavy syndicate enforcers in bulky pressurized suits standing menacingly at an airlock gangway; cold industrial foundry lighting; a blank slate contract tablet held out for payment.

### `card-titan-embargo`
- **Source:** `game/data/crises.json: titan_retaliation`
- **Theme:** Cryo-fuel cartel blockade.
- **Visual Anatomy:** A sealed outer cryo-hydro refueling terminal; heavy frozen barricades clamped across the docking collars; frost-caked propellant spheres; dark teal lighting; a locked-out hauler drifting outside.

### `card-sol-audit`
- **Source:** `game/data/crises.json: sol_retaliation`
- **Theme:** Inner-system sovereign intervention.
- **Visual Anatomy:** A colossal Sol administrative cruiser looming over a small merchant vessel; bone-white sovereign spire station in the background; a heavy containment tractor beam locking onto the merchant's hull.

### `card-sol-levy`
- **Source:** `game/data/crises.json: sol_opportunistic_levy`
- **Theme:** Surprise transit tariff at station gates.
- **Visual Anatomy:** A heavy toll barrier dropping across a docking bay throat; uniformed customs collectors sliding an armored lockbox into a pneumatic intake hopper while a trader hands over cargo canisters.

---

## 4. Space Hazards & Underworld

### `card-cme-flare` (Sample Gate)
- **Source:** `TransitHazards.check_cme_relay_interference`
- **Theme:** Violent solar space weather disrupting comms and nav.
- **Visual Anatomy:** A massive coronal mass ejection wave rolling through the inner system in layered ochre and rust prominence arcs; rocky asteroid relay dishes sparking electrical discharges; a lone cargo hauler racing through dark teal space ahead of the shock front.

### `card-pirate-ambush`
- **Source:** `TransitHazards / piracy system`
- **Theme:** Belt raiders, deep-space ambush.
- **Visual Anatomy:** A ragged outlaw raider swooping out of the shadow of an asteroid toward an isolated hauler; magnetic harpoons and grappling tethers firing; cloud of rocky shrapnel; hostile rust-red running lights.

### `card-black-market`
- **Source:** `Underworld syndicate system`
- **Theme:** Illicit transactions in unmonitored docking bays.
- **Visual Anatomy:** A clandestine deal in a decommissioned station maintenance bay; two hooded figures exchanging an unmarked reinforced strongbox under a swinging paper-yellow utility lamp; stacked illicit fluid barrels; a lookout keeping watch in the corridor shadows.
