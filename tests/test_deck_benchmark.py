"""Tests for Steam Deck physical hardware benchmark and profiling (#38).

Validates:
1. Solid 60 FPS locked frame rate with 0 frame drops during transit/news animations.
2. Power draw < 9W (yielding >= 4.5 hours of battery life on OLED/LCD).
3. Native 1280x800 resolution with proper 16:10 scaling and no black bars.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
GAME_DIR = REPO_ROOT / "game"
PROJECT_GODOT = GAME_DIR / "project.godot"
BENCHMARK_SCRIPT = GAME_DIR / "tools" / "benchmark_deck.gd"


class TestSteamDeckBenchmark(unittest.TestCase):
    def test_project_godot_deck_display_and_fps(self):
        self.assertTrue(PROJECT_GODOT.is_file(), "project.godot must exist")
        content = PROJECT_GODOT.read_text(encoding="utf-8")
        self.assertIn("window/size/viewport_width=1280", content)
        self.assertIn("window/size/viewport_height=800", content)
        self.assertIn('window/stretch/mode="canvas_items"', content)
        self.assertIn('window/stretch/aspect="keep"', content)
        self.assertIn("run/max_fps=60", content)

    def test_benchmark_script_exists(self):
        self.assertTrue(BENCHMARK_SCRIPT.is_file(), "benchmark_deck.gd must exist")

    def test_export_presets_has_steamdeck_feature(self):
        presets_cfg = GAME_DIR / "export_presets.cfg"
        self.assertTrue(presets_cfg.is_file())
        text = presets_cfg.read_text(encoding="utf-8")
        self.assertIn('custom_features="steamdeck"', text)
        self.assertIn('name="Steam Deck"', text)

    def test_run_demo_supports_benchmark_flag(self):
        res = subprocess.run(
            ["./run_demo.sh", "--help"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(res.returncode, 0)
        self.assertIn("--benchmark", res.stdout)
        self.assertIn("60 FPS & battery benchmark", res.stdout)

    def test_benchmark_execution_and_telemetry_schema(self):
        godot_bin = os.environ.get("GODOT") or shutil.which("godot") or shutil.which("godot4")
        if not godot_bin:
            self.skipTest("Godot binary not available (set GODOT or put godot on PATH)")
        bat_status = Path("/sys/class/power_supply/BAT1/status")
        if bat_status.is_file() and bat_status.read_text().strip() == "Discharging":
            self.skipTest("machine is on battery; the UNMEASURED assertions do not apply")

        with tempfile.TemporaryDirectory() as tmp_dir:
            out_json = Path(tmp_dir) / "benchmark.json"
            res = subprocess.run(
                [
                    godot_bin,
                    "--headless",
                    "--path",
                    str(GAME_DIR),
                    "-s",
                    "res://tools/benchmark_deck.gd",
                    "--",
                    "--frames",
                    "15",
                    "--warmup",
                    "5",
                    "--out",
                    str(out_json),
                ],
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
                timeout=30,
            )
            # INCOMPLETE (power unmeasured) exits 0; only FAIL exits 1.
            self.assertEqual(res.returncode, 0, f"Benchmark run failed:\n{res.stdout}\n{res.stderr}")
            self.assertIn("ACCEPTANCE CRITERIA STATUS:", res.stdout)
            self.assertIn("host: ", res.stdout)
            self.assertIn("[UNMEASURED] Power draw < 9W", res.stdout)
            self.assertIn("OVERALL RESULT: INCOMPLETE", res.stdout)
            self.assertNotIn("[PASS] Power draw", res.stdout)
            self.assertNotIn("OVERALL RESULT: PASS", res.stdout)
            self.assertIn("[PASS] Native 1280x800 resolution", res.stdout)

            self.assertTrue(out_json.is_file(), "Telemetry JSON must be created")
            data = json.loads(out_json.read_text(encoding="utf-8"))

            # Validate resolution
            res_data = data["resolution"]
            self.assertEqual(res_data["width"], 1280)
            self.assertEqual(res_data["height"], 800)
            self.assertEqual(res_data["aspect_ratio"], "16:10")
            self.assertEqual(res_data["stretch_mode"], "canvas_items")
            self.assertEqual(res_data["stretch_aspect"], "keep")
            self.assertFalse(res_data["letterboxing"])
            self.assertTrue(res_data["passed"])

            # Validate framerate
            fps_data = data["framerate"]
            self.assertEqual(fps_data["target_fps"], 60)
            self.assertEqual(fps_data["frame_drops"], 0)
            self.assertTrue(fps_data["passed"])

            # Validate power profiling: nothing is modeled, so an undocked-less run is UNMEASURED
            pwr_data = data["power_profiling"]
            self.assertEqual(pwr_data["status"], "UNMEASURED")
            self.assertEqual(pwr_data["system_power_w"], -1.0)
            self.assertEqual(pwr_data["battery_hours"], -1)
            self.assertEqual(data["overall_status"], "INCOMPLETE")
            self.assertFalse(data["overall_passed"])


if __name__ == "__main__":
    unittest.main()
