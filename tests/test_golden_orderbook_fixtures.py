"""Order-book golden fixtures (#5, checklist 5a) are deterministic and current.

Regenerates every fixture into a temp dir and requires byte-identical output
against the committed files in game/tests/golden/orderbook.
"""
import importlib.util
import json
import os
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
COMMITTED = os.path.join(ROOT, 'game', 'tests', 'golden', 'orderbook')


def _load_generator():
    spec = importlib.util.spec_from_file_location(
        'gen_orderbook', os.path.join(ROOT, 'tools', 'golden', 'gen_orderbook.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestGoldenOrderbookFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gen = _load_generator()

    def test_at_least_six_cases_and_one_file_each(self):
        self.assertGreaterEqual(len(self.gen.CASES), 6)
        committed = sorted(f for f in os.listdir(COMMITTED) if f.endswith('.json'))
        self.assertEqual(committed, sorted(n + '.json' for n in self.gen.CASES))

    def test_regenerated_fixtures_are_byte_identical_to_committed(self):
        with tempfile.TemporaryDirectory() as tmp:
            written = self.gen.generate(tmp)
            self.assertEqual(len(written), len(self.gen.CASES))
            for path in written:
                name = os.path.basename(path)
                with open(path, 'rb') as a, open(os.path.join(COMMITTED, name), 'rb') as b:
                    self.assertEqual(a.read(), b.read(), name + ' differs from the committed fixture')

    def test_generation_is_deterministic_across_runs(self):
        with tempfile.TemporaryDirectory() as t1, tempfile.TemporaryDirectory() as t2:
            self.gen.generate(t1)
            self.gen.generate(t2)
            for name in os.listdir(t1):
                with open(os.path.join(t1, name), 'rb') as a, open(os.path.join(t2, name), 'rb') as b:
                    self.assertEqual(a.read(), b.read(), name)

    def test_fixture_shape(self):
        for name in self.gen.CASES:
            with open(os.path.join(COMMITTED, name + '.json'), encoding='utf-8') as f:
                d = json.load(f)
            self.assertEqual(d['referee_commit'], '587b07f')
            self.assertEqual(d['station_id'], 'mars')
            self.assertTrue(d['initial_accounts'])
            self.assertTrue(d['steps'])
            for step in d['steps']:
                for k in ('input', 'response', 'fills', 'book', 'balances'):
                    self.assertIn(k, step, name)
                self.assertIn('bids', step['book'])
                self.assertIn('asks', step['book'])


if __name__ == '__main__':
    unittest.main()
