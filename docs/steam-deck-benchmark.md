# Steam Deck Physical Hardware Benchmark (#38, Steam Deck hardware benchmark)

**Issue Reference:** [Issue #38](https://github.com/brockventures/agora-roguelike/issues/38) (Steam Deck hardware benchmark)
**Target Hardware:** Valve Steam Deck (LCD and OLED)
**Status:** No results have been measured on Deck hardware yet. Every row below is PENDING.

---

## 1. Acceptance Criteria Matrix

| Acceptance Criterion | Target Specification | Result | Status |
|---|---|---|---|
| **Frame Rate & Pacing** | Solid 60 FPS locked with 0 frame drops during transit/news | not yet measured on Deck hardware | PENDING |
| **Power Envelope** | Total system draw < 9.0 W | not yet measured | PENDING |
| **Battery Endurance** | >= 4.5 hours continuous gameplay | not yet measured | PENDING |
| **Native Resolution & Scaling** | 1280x800 native 16:10 aspect ratio | configured, not yet verified on device | PENDING |

The benchmark tool no longer models power. It reads real values from sysfs when run undocked on the Deck. On any other machine the power criterion reports `UNMEASURED` and the overall result is `INCOMPLETE`, never `PASS`.

---

## 2. Reference: Hardware Specifications

Background only. These are the published specs of the two Deck revisions, not measurements from this project.

- **Valve Steam Deck LCD:** AMD Aerith APU (Zen 2, 4 cores / 8 threads; RDNA 2, 8 CUs), 16 GB LPDDR5, 7-inch 1280x800 60 Hz LCD, 40 Wh battery.
- **Valve Steam Deck OLED:** AMD Sephiroth APU (Zen 2, 4 cores / 8 threads; RDNA 2, 8 CUs), 16 GB LPDDR5, 7.4-inch 1280x800 90 Hz OLED, 50 Wh battery.

---

## 3. Resolution & Scaling (configured, not yet verified on device)

`game/project.godot` sets the following. The benchmark checks these values at startup, but whether the Deck actually displays them without letterboxing is not yet verified.

```ini
[display]
window/size/viewport_width=1280
window/size/viewport_height=800
window/stretch/mode="canvas_items"
window/stretch/aspect="keep"

[application]
run/max_fps=60
```

The `OrbitalHUD` panels are sized to tile the 1280x800 viewport (header 64 px, map 880x672, sidebar 400x672, ticker 64 px). That tiling is checked by the unit tests, not by looking at the screen on a Deck.

---

## 4. Frame Rate Workload

The benchmark tool (`game/tools/benchmark_deck.gd`) drives a transit corridor (Mars to Ceres) with GalNet headline posts every 20 frames and samples frame timings after a warmup period. Results are reported as:

- Average, median, P95, P99 and max frame process time against the 16.67 ms budget.
- Frame drops (frames over 18 ms).

When the display server is `headless`, the frame results are labelled `(headless: engine work only, not display pacing)`. Headless numbers do not show on-device frame pacing, and must not be quoted as Deck results.

---

## 5. Power & Battery Method

Power is read from the device while it runs on battery:

- **APU power:** `/sys/class/hwmon/hwmon*/power1_average` for the `amdgpu` hwmon device, in microwatts.
- **System power:** `|current_now| x voltage_now` from `/sys/class/power_supply/BAT1`, sampled only while `status` reads `Discharging`.
- **Battery capacity:** `charge_full` x `voltage_min_design` from BAT1, falling back to 40 Wh if either is unreadable.
- **Battery life:** capacity divided by mean system power.

Verdict rules:

- `UNMEASURED`: no discharging BAT1 was seen (docked, on AC, or not a Deck). The overall result is `INCOMPLETE`.
- `PASS`: mean system power < 9.0 W and battery life >= 4.5 h.
- `FAIL`: otherwise.

---

## 6. How to Run on the Deck

1. Undock the Deck and unplug the charger. The power criterion cannot be measured otherwise.
2. From a terminal in the repo (Desktop Mode), run:

   ```bash
   ./run_demo.sh --deck --benchmark -- --frames 600 --out ~/agora-test/benchmark_deck.json
   ```

   `--deck` sets fullscreen at 1280x800 and `--benchmark` runs `res://tools/benchmark_deck.gd`. Arguments after `--` go to the benchmark (`--frames`, `--warmup`, `--out`, `--verbose`).
3. Read the `OVERALL RESULT` line. `PASS` or `FAIL` are real results. `INCOMPLETE` means the power criterion was not measured and the run needs repeating undocked.
4. Record the numbers in this document and mark the rows as measured, with the date and the Deck revision.

Steam Game Mode is also possible: add `./run_demo.sh` as a Non-Steam Game with launch options `--deck --benchmark -- --out <path>`.

### Automated checks (not a Deck result)

```bash
game/tests/run.sh <godot-binary> benchmark
python3 -m unittest tests.test_deck_benchmark
```

These check the tool's logic and the project settings. They do not measure frame pacing or power.
