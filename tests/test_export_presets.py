"""Guards for the release pipeline (#28, multi-platform export pipeline; part of
#26, Epic 5 Steamworks): game/export_presets.cfg and tools/stamp_version.py."""
import configparser
import re
import unittest
from pathlib import Path

from tools import stamp_version

ROOT = Path(__file__).resolve().parent.parent
PRESETS = ROOT / 'game' / 'export_presets.cfg'
WORKFLOW = ROOT / '.github' / 'workflows' / 'release.yml'


def load():
    cp = configparser.RawConfigParser(strict=False)
    cp.optionxform = str
    cp.read_string(PRESETS.read_text(encoding='utf-8'))
    out = {}
    i = 0
    while cp.has_section(f'preset.{i}'):
        p = dict(cp.items(f'preset.{i}'))
        p = {k: v.strip('"') for k, v in p.items()}
        o = {k: v.strip('"') for k, v in cp.items(f'preset.{i}.options')}
        out[p['name']] = (p, o)
        i += 1
    return out


class ExportPresets(unittest.TestCase):
    def setUp(self):
        self.presets = load()

    def test_exactly_the_three_presets(self):
        self.assertEqual(set(self.presets),
                         {'Linux x86_64', 'Windows Desktop', 'Steam Deck'})

    def test_platforms_and_architecture(self):
        for name, plat in [('Linux x86_64', 'Linux'),
                           ('Windows Desktop', 'Windows Desktop'),
                           ('Steam Deck', 'Linux')]:
            p, o = self.presets[name]
            self.assertEqual(p['platform'], plat, name)
            self.assertEqual(o['binary_format/architecture'], 'x86_64', name)
            self.assertEqual(p['runnable'], 'true', name)

    def test_tests_and_dev_dirs_excluded(self):
        for name, (p, _) in self.presets.items():
            patterns = [s.strip() for s in p['exclude_filter'].split(',')]
            self.assertIn('tests/*', patterns, name)
            self.assertIn('tools/*', patterns, name)

    def test_windows_needs_no_rcedit_or_signing(self):
        _, o = self.presets['Windows Desktop']
        self.assertEqual(o['application/modify_resources'], 'false')
        self.assertEqual(o['codesign/enable'], 'false')

    def test_steam_deck_tuning(self):
        p, o = self.presets['Steam Deck']
        self.assertEqual(o['binary_format/embed_pck'], 'true')
        self.assertIn('steamdeck', p['custom_features'].split(','))
        self.assertNotIn('steamdeck',
                         self.presets['Linux x86_64'][0]['custom_features'])

    def test_export_paths_distinct_and_under_build(self):
        paths = [p['export_path'] for p, _ in self.presets.values()]
        self.assertEqual(len(set(paths)), 3)
        for path in paths:
            self.assertTrue(path.startswith('../build/'), path)

    def test_workflow_exports_every_preset(self):
        text = WORKFLOW.read_text(encoding='utf-8')
        for name in self.presets:
            self.assertIn(f'preset: "{name}"', text)
        self.assertIn('--export-release', text)
        self.assertRegex(text, r'tags:\s*\["v\*"\]')


class StampVersion(unittest.TestCase):
    BASE = '[application]\n\nconfig/name="X"\nrun/max_fps=60\n'

    def test_inserts_after_name(self):
        out = stamp_version.stamp(self.BASE, '1.2.3')
        self.assertIn('config/name="X"\nconfig/version="1.2.3"\n', out)

    def test_replaces_existing_and_is_idempotent(self):
        once = stamp_version.stamp(self.BASE, '1.2.3')
        twice = stamp_version.stamp(once, '2.0.0-rc.1')
        self.assertEqual(len(re.findall(r'config/version=', twice)), 1)
        self.assertIn('config/version="2.0.0-rc.1"', twice)

    def test_rejects_bad_version(self):
        with self.assertRaises(ValueError):
            stamp_version.stamp(self.BASE, '1.0"\n[evil]')

    def test_real_project_file_accepts_stamp(self):
        text = (ROOT / 'game' / 'project.godot').read_text(encoding='utf-8')
        self.assertIn('config/version="9.9.9"', stamp_version.stamp(text, '9.9.9'))


if __name__ == '__main__':
    unittest.main()
