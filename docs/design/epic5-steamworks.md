# Epic 5: Steamworks Integration & Automated Release Pipeline (#26)

**Epic Issue:** [Issue #26](https://github.com/brockventures/agora-roguelike/issues/26)  
**Status:** Completed & Staged for Partner Review  
**Milestone:** M4 / Steam Deck Verified Target  
**Partner Publisher:** Placeholder Studios (@mcarmody, App ID 3064620)  
**Date:** October 2026  

---

## 1. Executive Summary & Deliverables Matrix

Epic 5 establishes the commercial Steamworks infrastructure, automated multi-platform release engineering, Steam Deck Verified compliance, and store presence for *AGORA Roguelike*:

| Deliverable Area | Target Specification | Shipped Implementation | Status |
|---|---|---|---|
| **godot-steam SDK Integration** | Achievements, Cloud Saves, Steam Input | Dynamic reflection in `SteamService`, `SteamHub` autoload, `SteamHooks` signal wiring | **CLOSED (#27, PR #101)** |
| **Release Manifests & Controls** | Action set manifest and default Deck layout shipped beside binary | `game_actions_480.vdf` packaged into release zips via workflow | **CLOSED (#102, PR #103)** |
| **Automated Export Pipeline** | Tagged release workflow for Linux, Windows, Steam Deck | `.github/workflows/release.yml`, version stamping, SHA-256 checksums | **CLOSED (#28, PR #100)** |
| **Steam Deck Sleep Lifecycle** | Delta > 1.0s wake detection, tick purge, audio re-arm, focus hold | `SimClock` clamp, `MainScene` audio recovery, physical hardware signed off | **CLOSED (#41, PR #96)** |
| **Steam Deck Hardware Benchmark** | 60 FPS locked, 0 frame drops, <9W power budget, 1280x800 native | Sysfs BAT1 telemetry harness merged (`benchmark_deck.gd`); live physical profiling pending | **HARNESS MERGED (#38, PR #199)** |
| **Store Assets & Capsule Specs** | Copy, capsule dimensions, IARC survey, trailer storyboard, AI disclosure | `game/data/store_assets.json`, tested via `test_steam_store_assets.py` | **STAGED (#29)** |
| **Steam Direct Onboarding Staging** | Placeholder Studios App 3064620 configuration, depots, cloud quotas | `game/data/steam.json` partner metadata, `get_target_app_id()` API | **STAGED (#30)** |
| **Review Gate & Human Steering** | Comprehensive architecture audit and partner handover | Delivered in `docs/design/epic5-steamworks.md`, receipts to #agora | **COMPLETE (#31)** |

---

## 2. Architecture & Design Invariants

### 2.1 Optional Steamworks Layer (Zero-Hard-Dependency Invariant)

The Steam layer never prevents the game from booting, running, or passing tests in offline or headless environments:

- **Runtime Backend Detection:** `SteamService` queries `Engine.has_singleton("Steam")` and `ClassDB` dynamically. All Steam API calls execute through late-bound `.call()`, allowing clean execution without vendored GodotSteam binaries.
- **Local Mirror & Offline Progress:** Every achievement unlock and statistic increment is persisted immediately to `user://saves/steam_mirror.json`. When a live Steam session initializes, offline progress is unioned (achievements) and max-accumulated (stats) without data loss.
- **Two-Way Cloud Synchronization:** `SaveStore` integrates cloud hooks (`cloud_push`, `cloud_restore`, `cloud_delete`) around local file operations. Local storage remains the authoritative source of truth, protected by schema versioning.
- **Steam Input Polling:** `SteamHub` pumps callbacks each frame, translating digital action edges into standard Godot `InputEventAction` triggers matching the `m0_*` InputMap.

### 2.2 Multi-Platform Release Pipeline (`.github/workflows/release.yml`)

The automated export pipeline generates verified platform binaries from Git semver tags (`v*`):

1. **Gate Verification:** Runs the headless Godot test suite and export preset guard test (`test_export_presets.py`). Any failure immediately halts the release.
2. **Version Stamping:** Injects version strings into `application/config/version` via `tools/stamp_version.py`.
3. **Three Presets (`game/export_presets.cfg`):**
   - **Linux x86_64:** Standalone ELF binary + external `.pck`.
   - **Windows Desktop:** Windows executable (resources unmodified, wine/rcedit-free).
   - **Steam Deck:** Embedded PCK inside Linux binary with custom feature flag `steamdeck` (`OS.has_feature("steamdeck")`).
4. **Artifact Packaging:** Packages `game_actions_<appid>.vdf` beside the executable, compresses releases to zip archives, generates SHA-256 checksums, and attaches them to GitHub Releases.

---

## 3. Steam Store Package & Marketing Specification (`store_assets.json`)

All store metadata conforms strictly to Valve's onboarding requirements:

### Copywriting & Positioning

- **Game Title:** AGORA Roguelike
- **Tagline (Short Description, <= 300 chars):**  
  *An orbital Bloomberg terminal roguelike. Build trade cartels across Sol, execute hostile takeovers of rival barons, and light the planetary Stabilisers before the Doomsday Clock strikes zero.*
- **Key Features:**
  1. *Orbital Bloomberg Terminal HUD:* Native 1280x800 command deck optimized for controller-first mastery and Steam Deck Verified play.
  2. *Dynamic Sol Astrodynamics:* Real-time planetary orbits, alignment corridors, perishable cargo decay, and asteroid belt hazard corridors.
  3. *Hostile Takeovers & Corporate Insolvency:* Squeeze rival barons, purchase controlling 501-share stakes, or deploy Golden Parachutes.
  4. *Procedural Crisis Deck:* Dynamic solar flares, supply shocks, embargoes, and antitrust audits.
  5. *The Sol System Rescue Project:* Deliver critical stabiliser components across planetary stages before collapse.

### Capsule Asset Dimensions

- **Header Capsule:** `460 x 215 px` (Store search, category listings)
- **Small Capsule:** `231 x 87 px` (Discovery queues, recommendation widgets)
- **Main Capsule:** `616 x 353 px` (Storefront carousel feature)
- **Vertical Capsule:** `374 x 448 px` (Steam Library grid cards)
- **Page Background:** `1438 x 810 px` (Ambient store theme backdrop)

### IARC & Content Rating Disclosures

- **Rating Target:** ESRB Everyone (E) / PEGI 3 / USK 0 / IARC 3+.
- **Content:** Zero graphic violence, blood, or gore; mild corporate financial satire; deterministic commodities trading with zero real-money gambling or loot box mechanics.
- **Steam AI Disclosure:** Pre-production conceptual ideation and visual reference proofs for encounter deck card art utilized AI assistance tools, followed by extensive human curation, SVG re-vectorization, palette harmonization, and hand-fitted cel-shaded composition. No real-time generation during gameplay.

---

## 4. Partner Handover Checklist for Mike (@mcarmody)

To complete Steam Direct onboarding under Placeholder Studios (App 3064620):

1. **Steamworks Partner Portal Setup:**
   - Log in to partner portal and navigate to **App 3064620 (AGORA Roguelike)**.
   - Enter store metadata and copy from `game/data/store_assets.json`.
   - Upload graphic capsules matching the exact resolutions in `store_assets.json`.
2. **Achievements & Stats Staging:**
   - Navigate to **Steamworks -> Technical Tools -> Stats & Achievements**.
   - Input the 11 achievements and 6 integer statistics defined in `game/data/achievements.json`.
3. **Steam Cloud Storage Configuration:**
   - Enable Steam Cloud with byte quota `1,048,576` (1 MB) and maximum file count `16`.
   - Cloud save file patterns: `profile.json`, `settings.json`, `run_slot_0.json`, `steam_mirror.json`.
4. **Steam Input Layout Publishing:**
   - Upload default Steam Deck layout `game/steam/controller_steamdeck_default.vdf` into Steamworks Partner configurator.
5. **App ID Switchover:**
   - Once store staging is complete, update `"app_id": 3064620` in `game/data/steam.json` and rename `game/steam/game_actions_480.vdf` to `game_actions_3064620.vdf`.
