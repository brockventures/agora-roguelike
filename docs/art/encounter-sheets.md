# AGORA Encounter Deck Character Sheets

Grounded source of truth for encounter and crisis card illustrations across the 4:3 viewport in `card_panel` (`game/scenes/main.gd`). Part of #73 (Epic 6: Visual Identity & Art Asset Pipeline), sub-task 6.5.

---

## 🃏 Invariant Rule of Encounter Consistency

Every encounter card represents an active crisis (`game/data/crises.json`), spatial hazard (`game/core/hazards.gd`), or rated corridor event (`game/core/corridors.gd`) in the Sol system. Cards are rendered as pure **4:3 viewports** inside Godot's `card_panel` Control frame. Telemetry, crisis tier headers, expiration round counters, and systemic trade effects are rendered dynamically in Godot for #40 localization. The raster artwork must remain **100% text-free**.

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

## 1. Systemic & Regulatory Crises (`game/data/crises.json`)

Keyed 1:1 to the crisis IDs in `game/data/crises.json`:

### `antitrust_audit` (`card-antitrust-audit` - Sample Gate)
- **Name in Data:** "Antitrust Audit" (`tier: mid`, `kind: audit`)
- **Visual Anatomy:** A squad of stern regulatory officials in grey trench coats boarding an industrial warehouse dock; harsh conical overhead floodlamp illuminating stacked shipping crates; an empty hearing podium with an emblem-free scale of justice; glowing rust-red inspection light.

### `emergency_antitrust_sweep` (`card-emergency-antitrust-sweep`)
- **Name in Data:** "Emergency Antitrust Sweep" (`tier: endgame`, `kind: audit`)
- **Visual Anatomy:** Armored customs cutters swarming a station docking slip with crossing searchlight beams; shipping containers being sealed with magnetic security bands; dockworkers and traders scattering from gangways.

### `localized_shortage` (`card-localized-shortage`)
- **Name in Data:** "Localized Shortage" (`tier: early`, `kind: shortage`)
- **Visual Anatomy:** Cavernous Mars subterranean warehouse with endless rows of barren shelving; a single lonely crate under an amber worklight; a rust-red window overlooking the dusty Martian desert; a worker gesturing at an empty freight lift.

### `supply_chain_shortage` (`card-supply-chain-shortage`)
- **Name in Data:** "Supply Chain Shortage" (`tier: mid`, `kind: shortage`)
- **Visual Anatomy:** A stalled convoy of cargo haulers parked dead in a dark lane with cold unlit thrusters; a stranded dock crane waiting beside an empty berth.

### `systemic_margin_collapse` (`card-systemic-margin-collapse`)
- **Name in Data:** "Systemic Margin Collapse" (`tier: endgame`, `kind: collapse`)
- **Visual Anatomy:** Chaos across an orbital trading exchange floor; shattered glass-slate holographic quote boards; scattered physical paper transaction slips; toppled operator stools; stark rust-red emergency strobes reflecting on alarmed traders.

---

## 2. Baron Retaliations & Opportunistic Moves (`game/data/crises.json`)

Keyed 1:1 to the baron event IDs in `game/data/crises.json`:

### `ares_retaliation` (`card-ares-retaliation`)
- **Name in Data:** "Ares Markers" (`baron_archetype: short_squeezer`, `origin: consequence`)
- **Visual Anatomy:** Heavy industrial enforcers from a rust-coloured arms combine calling in debts: broad-shouldered figures in heavy suits at a dock gangway, a ledger-less contract slab held out menacingly.

### `titan_retaliation` (`card-titan-retaliation`)
- **Name in Data:** "Titan Embargo" (`baron_archetype: hoarder`, `origin: consequence`)
- **Visual Anatomy:** A frozen cryo-hydro depot sealed shut: icy blockade barriers across a dock, frost-covered tanks, dark teal glow, a lone trader locked outside.

### `sol_retaliation` (`card-sol-retaliation`)
- **Name in Data:** "Sol Audit" (`baron_archetype: auctioneer`, `origin: consequence`)
- **Visual Anatomy:** A central government audit fleet looming over a small trader ship; a tall pale-bone administrative tower station behind; one tractor beam locking onto the hull.

### `ares_opportunistic_squeeze` (`card-ares-opportunistic-squeeze`)
- **Name in Data:** "Ares Squeeze" (`baron_archetype: short_squeezer`, `origin: random`)
- **Visual Anatomy:** Ares Heavy syndicate leaning on a station trading desk: armored syndicate managers in rust-trimmed work suits watching an automated order terminal flicker; bulk gantry cranes idling; traders negotiating under harsh orange sodium lamps.

### `titan_opportunistic_hoard` (`card-titan-opportunistic-hoard`)
- **Name in Data:** "Titan Hoard" (`baron_archetype: hoarder`, `origin: random`)
- **Visual Anatomy:** Titan Cryo-Hydro hoarding propellant and cornering the book: massive frost-caked propellant storage spheres sealed behind security barricades; automated cryo-pumps draining terminal fuel lines; chilled teal vapor clouds; dock workers locked out at the gate.

### `sol_opportunistic_levy` (`card-sol-opportunistic-levy`)
- **Name in Data:** "Sol Levy" (`baron_archetype: auctioneer`, `origin: random`)
- **Visual Anatomy:** A surprise levy at a dock: a toll gate dropping across a berth; customs collectors sliding an armored lockbox into a pneumatic intake hopper while a trader hands over cargo canisters.

---

## 3. Spatial Hazard Outcomes (`game/core/hazards.gd`)

Keyed to concrete hazard mechanics in `game/core/hazards.gd`:

### CME Relay Blackout (`card-cme-flare` - Sample Gate)
- **Source:** `Hazards.check_cme_relay_interference` / `CME_RELAY_CORRIDORS`
- **Visual Anatomy:** A coronal mass ejection engulfing the inner system: a huge ochre and rust solar flare arc rolling toward a small hauler; radio relay dishes sparking electrical discharges; shock-front bands rippling through dark teal space.

### Transit Storm Delay (`card-storm-delay`)
- **Source:** `Hazards.P_DELAY` (`DELAY_ROUNDS: 1-3 rounds`)
- **Visual Anatomy:** A cargo vessel caught in a high-radiation solar storm: ion turbulence battering the hull; glowing static discharges along the radiator panels; a blown thruster coil glowing hot while crew race to repair propulsion.

### Hull Breach & Cargo Loss (`card-hull-breach`)
- **Source:** `Hazards.P_LOSS` (`LOSS_FRACTION: 10-20% cargo`)
- **Visual Anatomy:** Micro-meteoroid puncture or containment breach: jagged tear along the container rack; frozen atmosphere venting into the void; container canisters spilling loose into zero-g.

---

## 4. Corridor Piracy & Smuggling (`game/core/corridors.gd`)

Keyed to rated corridors and smuggling lanes in `game/data/corridors.json`:

### Asteroid Belt Corridor Raid (`card-pirate-raid`)
- **Source:** `Corridors.data().piracy` / `is_belt` raid odds
- **Visual Anatomy:** A pirate raider ambush in the asteroid belt: a ragged raider swooping out of a rock shadow toward a lone hauler; grappling lines flying; dust and debris; rust-red running lights.

### Dark Run Smuggle Lane (`card-dark-run`)
- **Source:** `Corridors.data().smuggle_lanes.dark_run` / `black_market_corridors` perk
- **Visual Anatomy:** Running silent on the unmonitored Mars-Ceres Dark Run: a blacked-out hauler slipping through a craggy asteroid trench with running lights extinguished; illicit fluid canisters strapped to the keel; scanning sensors sweeping harmlessly overhead.
