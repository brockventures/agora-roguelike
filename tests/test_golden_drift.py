"""CI drift guard (#5, checklist 5e): tools/golden/check_drift.py must report no drift."""
import importlib.util
import os
import shutil
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
GOLDEN = os.path.join(ROOT, 'game', 'tests', 'golden')


def _load():
    spec = importlib.util.spec_from_file_location(
        'check_drift', os.path.join(ROOT, 'tools', 'golden', 'check_drift.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _snapshot(mod):
    out = {}
    for rel, path in mod._list_fixtures(GOLDEN).items():
        with open(path, 'rb') as f:
            out[rel] = f.read()
    return out


class TestGoldenDrift(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = _load()

    def test_no_drift_in_committed_fixtures(self):
        self.assertEqual(self.mod.main([]), 0)

    def test_mutated_fixture_copy_is_reported_as_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            dst = os.path.join(tmp, 'golden')
            shutil.copytree(GOLDEN, dst)
            with open(os.path.join(dst, 'orderbook', 'cancel_resting.json'), 'ab') as f:
                f.write(b' ')
            problems = self.mod.check(dst)
            self.assertEqual(len(problems), 1, problems)
            self.assertTrue(problems[0].startswith('DIFFERS: orderbook/cancel_resting.json'))
            self.assertEqual(self.mod.main([], golden_root=dst), 1)

    def test_orphan_and_missing_fixtures_are_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            dst = os.path.join(tmp, 'golden')
            shutil.copytree(GOLDEN, dst)
            with open(os.path.join(dst, 'draws', 'stray.json'), 'w') as f:
                f.write('[]\n')
            os.remove(os.path.join(dst, 'settlement', 'idle_fee.json'))
            kinds = sorted(p.split(':')[0] for p in self.mod.check(dst))
            self.assertEqual(kinds, ['MISSING', 'ORPHAN'])

    def test_committed_tree_untouched_by_check(self):
        before = _snapshot(self.mod)
        self.mod.check()
        self.assertEqual(before, _snapshot(self.mod))


if __name__ == '__main__':
    unittest.main()
