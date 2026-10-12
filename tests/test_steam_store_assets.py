"""Tests for Steam Store assets, capsule specifications, copy, and surveys (#29, part of Epic 5 #26)."""

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / "game"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
STORE_ASSETS_PATH = GAME / "data" / "store_assets.json"
STEAM_CONFIG_PATH = GAME / "data" / "steam.json"


class TestSteamStoreAssets(unittest.TestCase):
    def setUp(self):
        self.assertTrue(STORE_ASSETS_PATH.is_file(), "store_assets.json must exist")
        self.data = json.loads(STORE_ASSETS_PATH.read_text(encoding="utf-8"))
        self.steam_cfg = json.loads(STEAM_CONFIG_PATH.read_text(encoding="utf-8"))

    def test_basic_metadata_and_partner_alignment(self):
        self.assertEqual(self.data["app_name"], "Agora Station")
        self.assertEqual(self.data["app_id_target"], 0)
        self.assertEqual(self.data["publisher"], "Placeholder Studios")
        self.assertEqual(self.steam_cfg.get("target_app_id"), 0)
        self.assertEqual(self.steam_cfg.get("publisher"), "Placeholder Studios")

    def test_no_borrowed_app_id_under_game(self):
        # 3064620 is The Atlas Problem, a different released game on the same partner account.
        warning = "3064620 is The Atlas Problem, never use it."
        skip = {GAME / "tests" / "test_steam.gd"}  # the guard assertion names the ID on purpose
        hits = []
        for path in sorted(GAME.rglob("*")):
            if not path.is_file() or path in skip or path.suffix in {".png", ".import"}:
                continue
            if b"\x00" in path.read_bytes()[:4096]:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore").replace(warning, "")
            if "3064620" in text:
                hits.append(str(path.relative_to(ROOT)))
        self.assertEqual(hits, [], "3064620 (The Atlas Problem) must not appear under game/")

    def test_descriptions_length_and_structure(self):
        short_desc = self.data["short_description"]
        self.assertTrue(short_desc, "Short description cannot be empty")
        self.assertLessEqual(
            len(short_desc),
            300,
            f"Steam short description must be <= 300 chars, got {len(short_desc)}",
        )

        about = self.data["about_the_game"]
        self.assertTrue(len(about) > 100, "About the game must have substantive copy")

        features = self.data["key_features"]
        self.assertIsInstance(features, list)
        self.assertGreaterEqual(len(features), 4, "Must highlight at least 4 key features")

    def test_capsule_asset_dimensions_valve_compliance(self):
        capsules = self.data["capsules"]
        expected = {
            "header_capsule": (920, 430),
            "small_capsule": (462, 174),
            "main_capsule": (1232, 706),
            "vertical_capsule": (748, 896),
            "page_background": (1438, 810),
            "library_capsule": (600, 900),
            "library_hero": (3840, 1240),
        }
        for name, (w, h) in expected.items():
            self.assertIn(name, capsules, f"Missing capsule spec: {name}")
            self.assertEqual(capsules[name]["width"], w, f"{name} width mismatch")
            self.assertEqual(capsules[name]["height"], h, f"{name} height mismatch")

    def test_capsule_files_exist_at_spec_size(self):
        for name, spec in self.data["capsules"].items():
            rel = spec.get("file")
            self.assertTrue(rel, f"{name} has no file")
            path = ROOT / rel
            self.assertTrue(path.is_file(), f"{name}: {rel} missing")
            raw = path.read_bytes()
            self.assertEqual(raw[:8], PNG_MAGIC, f"{name}: not a PNG")
            w = int.from_bytes(raw[16:20], "big")
            h = int.from_bytes(raw[20:24], "big")
            self.assertEqual((w, h), (spec["width"], spec["height"]), f"{name} pixel size mismatch")

    def test_system_requirements(self):
        reqs = self.data["system_requirements"]
        for platform in ["linux", "windows"]:
            self.assertIn(platform, reqs)
            for tier in ["minimum", "recommended"]:
                self.assertIn(tier, reqs[platform])
                tier_spec = reqs[platform][tier]
                for key in ["os", "processor", "memory", "graphics", "storage"]:
                    self.assertIn(key, tier_spec)
                    self.assertTrue(tier_spec[key])

    def test_content_survey_and_iarc(self):
        survey = self.data["content_survey_iarc"]
        self.assertIn("violence", survey)
        self.assertIn("rating_target", survey)
        self.assertIn("E", survey["rating_target"])

    def test_steam_ai_disclosure(self):
        ai = self.data["steam_ai_disclosure"]
        self.assertTrue(ai["has_generative_ai"])
        self.assertTrue(ai["pre_generated_content"])
        self.assertIn("Gemini", ai["pre_generated_content"])
        self.assertFalse(ai["live_generated_content"])

    def test_supported_languages_are_english_only(self):
        self.assertEqual(self.data["supported_languages"], ["English"])

    def test_steam_deck_verified_is_not_claimed_as_a_feature(self):
        self.assertNotIn("Steam Deck Verified", self.data["steam_features"])

    def test_trailer_storyboard(self):
        trailer = self.data["trailer_storyboard"]
        self.assertIsInstance(trailer, list)
        self.assertGreaterEqual(len(trailer), 3)
        total_duration = sum(step["duration_sec"] for step in trailer)
        self.assertGreaterEqual(total_duration, 20)
        self.assertLessEqual(total_duration, 60)


if __name__ == "__main__":
    unittest.main()
