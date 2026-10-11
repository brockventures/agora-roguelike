# AGORA Vessel Archetype Character Sheets

Grounded source of truth for vessel visual consistency across all viewports. Part of #73 (Epic 6: Visual Identity & Art Asset Pipeline), sub-task 6.4.

---

## 🚀 Invariant Rule of Vessel Consistency

Every ship archetype is grounded directly to `FleetView.ARCHETYPES` and `FLEET_ARCH_TONES` in `game/scenes/main.gd`. Whether viewed as a command deck fleet profile (3:2 design sheet), an orbital transit marker on the Sol tactical map (1:1 icon), or under combat/hazard strain (damage overlay), **the vessel's distinctive industrial silhouette, primary color tone, and mechanical anatomy must persist verbatim**.

---

## 🎨 Design Rules & Technical Grammar

1. **Heavy Ligne Claire:** Uniform-weight black ink contours (`#1c1a17`), flat hard-edged graphic shadow cuts (zero gradients, zero glow, zero airbrushing), flat fills with at most two tones per surface.
2. **Text-Free Invariant:** 100% text-free rasters. Hull numbers, registration codes, faction logos, and telemetry are rendered dynamically in Godot for #40 localization.
3. **Orientation & Framing:**
   - **Profile Sheets (`hull-*`, 3:2):** Strict side profile facing right, centered, flat pale paper background (`#d9cdb0`) with zero cast ground shadows for clean compositing.
   - **Transit Markers (`icon-*`, 1:1):** Top-down readable silhouette, pointing up, bold ink outlines, flat primary archetype tone plus black.
4. **Color Tokens:** Grounded to `docs/design-system/tokens/colors.css`:
   - Ink: `#1c1a17`
   - Slate: `#2c353b`
   - Bone: `#e6dcc3`
   - Paper: `#d9cdb0`
   - Ochre: `#c99a2e`
   - Rust: `#a8431f`
   - Teal: `#2f6f6a`

---

## 1. Hauler (The Heavy Workhorse)
- **Fleet View Token:** `HAULER` (`FLEET_ARCH_TONES`: Ochre `#c99a2e`, Ink `#1c1a17`).
- **Role:** Workhorse industrial freight transport; reliable bulk carrier for ore, grain, and heavy machinery.
- **Anatomy & Silhouette:**
  - **Bow:** Blunt, angular reinforced nose with enclosed bridge module and heavy forward collision bumpers.
  - **Midsection:** Exposed structural keel with stacked cylindrical pressurized cargo pods slung underneath in steel truss rigging. Ochre armor plating across the dorsal spine.
  - **Stern:** Elevated aft engineering section tapering into a single massive conical thruster bell with slate-grey cowling and rust trim.
- **Viewports:**
  - *Profile Sheet (3:2 - `hull-hauler`):* Strict right-facing side profile highlighting stacked cylindrical pods and massive thruster.
  - *Transit Marker (1:1 - `icon-hauler`):* Bold top-down rectangular silhouette with flared rear thruster bell.

---

## 2. Interceptor (The High-G Strike Craft)
- **Fleet View Token:** `INTERCEPTOR` (`FLEET_ARCH_TONES`: Rust `#a8431f`, Bone `#e6dcc3`).
- **Role:** High-speed patrol cutter, corporate enforcement interceptor, and rapid courier.
- **Anatomy & Silhouette:**
  - **Bow:** Needle-sharp forward fuselage with a narrow, heavily recessed cockpit canopy.
  - **Midsection:** Swept angular delta wings in bold rust-red with hard chisel-edged panel cuts and maneuvering thruster ports.
  - **Stern:** Compact twin-nozzle high-output propulsion block with active vector flaps.
- **Viewports:**
  - *Profile Sheet (3:2 - `hull-interceptor`):* Sleek, low-drag silhouette with swept rust wings and twin thrusters.
  - *Transit Marker (1:1 - `icon-interceptor`):* Sharp wedge/chevron silhouette pointing up.

---

## 3. Freighter (The Bulk Container Spine)
- **Fleet View Token:** `FREIGHTER` (`FLEET_ARCH_TONES`: Teal `#2f6f6a`, Bone `#e6dcc3`).
- **Role:** Deep-space trans-orbital bulk carrier; massive capacity across planetary transfer lanes.
- **Anatomy & Silhouette:**
  - **Bow:** Compact command and life-support pod perched at the forward end of the spine.
  - **Midsection:** Long, rigid structural truss spine in deep dark-teal, carrying multiple modular container blocks and heavy magnetic lock clamps.
  - **Stern:** Wide, industrial engine block with reinforced radiator panels and multi-chamber exhaust manifold.
- **Viewports:**
  - *Profile Sheet (3:2 - `hull-freighter`):* Extended length-to-beam ratio, visible container rows along the teal spine, wide aft block.
  - *Transit Marker (1:1 - `icon-freighter`):* Long elongated bar silhouette with cross-struts and wide rear block.

---

## 4. Scout (The Light Long-Range Surveyor)
- **Fleet View Token:** `SCOUT` (`FLEET_ARCH_TONES`: Bone `#e6dcc3`, Ink `#1c1a17`).
- **Role:** Fast reconnaissance, navigational beacon surveyor, and stealth courier.
- **Anatomy & Silhouette:**
  - **Bow:** Prominent forward communications and sensor antenna mast, followed by a panoramic bubble observation cockpit.
  - **Midsection:** Lightweight bone-white fuselage with low-profile auxiliary thruster nacelles and folded sensor arrays.
  - **Stern:** Slim, high-efficiency ion drive assembly with minimal heat signature.
- **Viewports:**
  - *Profile Sheet (3:2 - `hull-scout`):* Light, agile proportions with extended antenna mast and bubble canopy.
  - *Transit Marker (1:1 - `icon-scout`):* Dart-like silhouette with forward sensor spike.

---

## 5. Scrap Barge (The Outlaw Salvage Rig)
- **Fleet View Token:** `SCRAP_BARGE` (`FLEET_ARCH_TONES`: Ink `#1c1a17`, Bone `#e6dcc3`).
- **Role:** Gritty belt scow, asteroid salvage platform, and unregulated hauler.
- **Anatomy & Silhouette:**
  - **Bow:** Asymmetrical, heavily patched armored bridge cabin with welded viewport bars.
  - **Midsection:** Exposed dirty framework in dark ink-grey with mismatched rust-red patch plates, hydraulic crane booms, cutting rig booms, and an underslung magnetic grapple.
  - **Stern:** Over-clocked, mismatched salvage thrusters with exposed fuel lines and trailing conduit bundles.
- **Viewports:**
  - *Profile Sheet (3:2 - `hull-scrap_barge`):* Asymmetrical, heavily welded silhouette with cranes and magnetic grab slung underneath.
  - *Transit Marker (1:1 - `icon-scrap_barge`):* Irregular, blocky silhouette with crane booms extending outward.

---

## 6. Hull Damage Overlays (3:2)

Designed on flat pale paper ground for transparent compositing across any archetype profile:
- **`damage-light`:** Scattered thermal scorch marks, small micrometeoroid impact pits, and fine ink hairline fracture stress cracks.
- **`damage-heavy`:** Large torn exterior plating sections, exposed structural frame ribs, deep charcoal blast scoring, and active venting atmosphere plumes.
- **`damage-breach`:** Catastrophic open hull rupture, bent internal bulkheads, shattered conduit rings, and frozen decompression debris shards.
