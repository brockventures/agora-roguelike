import os
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


class TestDemoLauncher(unittest.TestCase):
    def test_run_demo_exists_and_executable(self):
        script_path = REPO_ROOT / "run_demo.sh"
        self.assertTrue(script_path.is_file(), "run_demo.sh must exist in repo root")
        self.assertTrue(os.access(script_path, os.X_OK), "run_demo.sh must be executable")

    def test_run_demo_help(self):
        res = subprocess.run(
            ["./run_demo.sh", "--help"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(res.returncode, 0, f"--help failed: {res.stderr}")
        self.assertIn("--deck", res.stdout)
        self.assertIn("--fullscreen", res.stdout)
        self.assertIn("--windowed", res.stdout)

    def test_run_demo_headless_smoke(self):
        godot_bin = REPO_ROOT / ".godot-bin" / "Godot_v4.7.2-stable_linux.x86_64"
        if not godot_bin.exists():
            self.skipTest("Godot binary not present for headless smoke test")
        res = subprocess.run(
            ["./run_demo.sh", "--headless", "--quit-after", "10"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(res.returncode, 0, f"Headless run failed: {res.stderr}")
        self.assertNotIn("SCRIPT ERROR", res.stdout)
        self.assertNotIn("SCRIPT ERROR", res.stderr)

    def test_project_godot_settings(self):
        project_godot = REPO_ROOT / "game" / "project.godot"
        self.assertTrue(project_godot.exists())
        content = project_godot.read_text()
        self.assertIn('run/main_scene="res://scenes/main.tscn"', content)
        self.assertIn("window/size/viewport_width=1280", content)
        self.assertIn("window/size/viewport_height=800", content)
        self.assertIn('window/stretch/mode="canvas_items"', content)
        self.assertIn('window/stretch/aspect="keep"', content)


if __name__ == "__main__":
    unittest.main()
