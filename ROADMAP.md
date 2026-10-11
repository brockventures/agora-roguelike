# Agora Roguelike — Engineering Roadmap & Priority Queue

This document defines the live engineering roadmap, epic sequencing, and priority queue for *Agora Roguelike*. It is dynamically synchronized with the autonomous sidecar coordinators (`agora_roguelike_pm.py` and `agora_roguelike_engineer.py`).

---

## 🏆 Completed Milestones & Epics

- [x] **Epic 1: Simulation Engine & Parity Harness (#1, #7)**
  - Core referee loop, order book matching, transit and hazard engine, golden orderbook fixtures, and simulation clock.
- [x] **Epic 2: Roguelite Run Loop & Chapter 11 Meta-Progression (#8, #13)**
  - Doomsday Clock burn rate, Chapter 11 bankruptcy mechanics, Golden Parachutes perk tree, and procedural crisis event deck (#12).
- [x] **Epic 3: Planetary Sector Barons & Rival Syndicate AI (#14, #19)**
  - Monopoly privileges (#15), Baron archetype AIs (Ares Heavy, Titan Cryo, Sol Central) (#16), hostile takeovers and roving fleets (#17, #18), and sealed-bid distress auctions with fleet insolvency and recapture tenders (#134, #141).
- [x] **Epic 4 (Foundation): Controller-First UI & Accessibility (#20, #37)**
  - Gamepad focus traps, CRT aesthetics, text scaling, colorblind modes, and Deck input remapping.
- [x] **Epic 6 (Phase 1): HUD Visual Overhaul (PRs #126, #133, #135, #142, #143, #144)**
  - Scavengers Reign command deck aesthetic, docked ledger, map orbital rings, route preview cards, and ticker motion.

---

## 🎯 Active Priority Queue (4-Tier Sequence)

### Tier 1: Immediate Engine & Loop Integrity (Current Focus)
The highest priority is eliminating "dead perks" from the Severance store so meta-progression mechanics are fully backed by live simulation systems, establishing the endgame Sol System Rescue win condition, and proving the 120-round run loop end-to-end.

1. **#137: `feat(perks): loans and interest system for corrupt_regulator`**
   - Wires dynamic credit line rates and interest settlement to give `corrupt_regulator` mechanical teeth.
   - *Assigned:* Zero (<@1542285964213358633>)
2. **#138: `feat(perks): fuel market system for fuel_hedge`**
   - Implements per-station fuel markets, departure fuel burn/refusal, and dynamic refueling price discounts for `fuel_hedge`.
   - *Assigned:* Amos (<@1468012353206354197>)
3. **#139: `feat(perks): hazard and piracy corridors system for black_market_corridors`**
   - Expands transit hazard ratings and risk discounts for black market smuggling routes.
4. **#32: `Implement Endgame Sol System Rescue Project (Post-Monopoly Climax)`**
   - Core victory condition: multi-stage capital and commodity sink to rescue Sol following the fall of all three barons (design proposal landed in PR #147).
5. **#34: `Build M0 Playable Vertical Slice (1 Station, 1 Baron, 120-Round Run)`**
   - Tasks #83–#85 merged. Complete end-to-end verification of a 120-round run via `./run_demo.sh` from launch to Chapter 11 or victory.

### Tier 2: Visual Asset Deck Production (Epic 6)
Populates visual content cards into the Scavengers Reign HUD.

- [x] **Sub-task 6.2: Generation Harness:** Python automation script with Gemini image generation and border sweeps (merged via PR #146).
6. **#73: `Epic 6: Visual Identity & Art Asset Pipeline (Cel-Shaded)`**
   - Tactical orbital station vignettes (Earth, Luna, Mars, Ceres) and celestial map nodes (6.3).
   - 5 vessel hulls and transit markers (6.4).
   - 12 encounter card illustrations (6.5).

### Tier 3: Steam Deck Hardware & Store Pipeline (Epics 4 & 5)
Optimizes first-hour retention, power efficiency on physical Deck hardware, and Steamworks release readiness.

7. **#36: `Design First-Hour Onboarding Flow & Interactive Terminal Tutorial`**
   - Contextual terminal tutorial to hook players within the 2-hour Steam refund window.
8. **#41: `Implement Steam Deck Suspend/Resume Lifecycle & Audio Buffer Recovery`**
   - Clock freezing during hardware sleep, delta spike clamps, and audio buffer recovery without crackle.
9. **#38: `Steam Deck Physical Hardware Benchmark: 60 FPS & Battery Profiling`**
   - Locked 60 FPS profiling and sub-9W power budget validation on OLED/LCD hardware.
10. **#26: `Epic 5: Steamworks Integration & Automated Release Pipeline`**
    - `godot-steam` integration and multi-platform CI build pipeline.
11. **#29: `Stage Steam Store Assets, Capsule Graphics & Content Survey`**
    - Capsule banners and content disclosure documentation.
12. **#30: `Execute Steamworks Onboarding & Build Review under Mike's Account`**
    - Steam backend configuration and build approval.
13. **#31: `Epic 5 Review Gate: Bot Audit, Human Steering to #lounge & Task Injection`**
14. **#39: `Steam Next Fest Demo Target & Store Page Milestone`**
    - 3-quarter demo build and 14-day Coming Soon store window.

### Tier 4: Endgame Boss Content
Late-game climax confrontation following Sol System Rescue.

15. **#33: `Implement Secret Final Boss: Sol Government Nationalization & Sovereign Buyout`**
    - Final bureaucratic showdown and sovereign buyout mechanics.
