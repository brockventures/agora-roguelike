"""Transit and hazard golden fixtures (Issue #4, checklist PR 5).

Verifies that tools/golden/gen_transit_hazards.py produces deterministic output,
validates shape and keys, and ensures byte-identical parity with committed fixtures.
"""
import importlib.util
import json
import os
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
COMMITTED_DIR = os.path.join(ROOT, 'game', 'tests', 'golden', 'transit_hazards')
COMMITTED_FILE = os.path.join(COMMITTED_DIR, 'transit_hazards_golden.json')


def _load_generator():
    spec = importlib.util.spec_from_file_location(
        'gen_transit_hazards', os.path.join(ROOT, 'tools', 'golden', 'gen_transit_hazards.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestGoldenTransitHazardFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gen = _load_generator()

    def test_committed_fixture_exists(self):
        self.assertTrue(os.path.exists(COMMITTED_FILE), f"{COMMITTED_FILE} must exist")

    def test_fixture_shape_and_metadata(self):
        with open(COMMITTED_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
        self.assertEqual(data.get('referee_commit'), '587b07f')
        self.assertIn('spatial', data)
        self.assertIn('hazards', data)
        self.assertIn('piracy', data)

        # Spatial assertions
        spatial = data['spatial']
        self.assertEqual(spatial['stations'], ['earth', 'luna', 'mars', 'ceres'])
        self.assertEqual(spatial['belt_toll_cr'], 25)
        self.assertGreater(len(spatial['route_cases']), 50)

        # Hazard assertions
        hazards = data['hazards']
        self.assertEqual(hazards['default_p_delay'], 0.20)
        self.assertEqual(hazards['default_p_loss'], 0.25)
        self.assertGreater(len(hazards['quotes']), 0)

        # Piracy assertions
        piracy = data['piracy']
        self.assertEqual(piracy['default_p_belt'], 0.15)
        self.assertEqual(piracy['default_p_inner'], 0.04)
        self.assertGreater(len(piracy['chance_samples']), 10)
        self.assertGreater(len(piracy['bag_odds_samples']), 5)

    def test_regenerated_fixture_is_byte_identical(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_file = self.gen.generate(tmp)
            with open(out_file, 'rb') as a, open(COMMITTED_FILE, 'rb') as b:
                self.assertEqual(a.read(), b.read(), "Generated fixture differs from committed file")

    def test_generation_is_deterministic(self):
        with tempfile.TemporaryDirectory() as t1, tempfile.TemporaryDirectory() as t2:
            f1 = self.gen.generate(t1)
            f2 = self.gen.generate(t2)
            with open(f1, 'rb') as a, open(f2, 'rb') as b:
                self.assertEqual(a.read(), b.read(), "Fixture generation is not deterministic across runs")


if __name__ == '__main__':
    unittest.main()
