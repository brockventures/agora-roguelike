"""Guards for the release pipeline (#28, multi-platform export pipeline; part of
#26, Epic 5 Steamworks): game/export_presets.cfg and tools/stamp_version.py."""
import configparser
import json
import re
import shutil
import subprocess
import tempfile
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


class SteamInputShipping(unittest.TestCase):
    """The release workflow copies the Steam Input action manifest beside the
    binary (docs/steam.md); it is not res:// content."""

    STEP = 'Add Steam Input action manifest beside the binary'

    def step(self):
        """Parse the step out of the workflow text (no PyYAML: the CI python
        has only the stdlib)."""
        text = WORKFLOW.read_text(encoding='utf-8')
        order = [m.group(1) for m in re.finditer(r'^      - name: (.+)$', text, re.M)]
        self.assertIn(self.STEP, order)
        # after export, before zipping
        self.assertLess(order.index('Export ${{ matrix.preset }}'), order.index(self.STEP))
        self.assertLess(order.index(self.STEP), order.index('Package'))
        m = re.search(r'^      - name: ' + re.escape(self.STEP) + r'\n(.*?)(?=^      - |\Z)',
                      text, re.M | re.S)
        body = m.group(1)
        r = re.search(r'^        run: \|\n((?:          .*\n|\n)+)', body, re.M)
        script = ''.join(l[10:] if l.strip() else l for l in r.group(1).splitlines(True))
        return {'run': script}

    def test_manifest_exists_for_configured_app_id(self):
        app_id = json.loads((ROOT / 'game' / 'data' / 'steam.json').read_text())['app_id']
        self.assertTrue((ROOT / 'game' / 'steam' / f'game_actions_{app_id}.vdf').is_file())

    def test_step_reads_app_id_from_config_not_hardcoded(self):
        run = self.step()['run']
        self.assertIn('game/data/steam.json', run)
        self.assertIn('game/steam/game_actions_${app_id}.vdf', run)
        self.assertNotRegex(run, r'game_actions_\d')
        self.assertNotIn('controller_steamdeck_default', run)

    def test_export_does_not_pack_the_manifest(self):
        for name, (p, _) in load().items():
            self.assertEqual(p['export_filter'], 'all_resources', name)
            self.assertEqual(p['include_filter'], '', name)

    def _run_step(self, tmp, app_id, make_manifest=True):
        (tmp / 'game' / 'data').mkdir(parents=True)
        (tmp / 'game' / 'steam').mkdir()
        (tmp / 'game' / 'data' / 'steam.json').write_text(json.dumps({'app_id': app_id}))
        if make_manifest:
            (tmp / 'game' / 'steam' / f'game_actions_{app_id}.vdf').write_text('m')
        (tmp / 'game' / 'steam' / 'controller_steamdeck_default.vdf').write_text('l')
        for d in ('linux', 'windows', 'steamdeck'):
            (tmp / 'build' / d).mkdir(parents=True)
        out = {}
        for d in ('linux', 'windows', 'steamdeck'):
            script = self.step()['run'].replace('${{ matrix.dir }}', d)
            out[d] = subprocess.run(['bash', '-e', '-c', script], cwd=tmp,
                                    capture_output=True, text=True)
        return out

    def test_copy_logic_follows_renamed_app_id(self):
        for app_id in (480, 2345670):
            with tempfile.TemporaryDirectory() as t:
                tmp = Path(t)
                res = self._run_step(tmp, app_id)
                for d, r in res.items():
                    self.assertEqual(r.returncode, 0, r.stderr)
                    files = sorted(f.name for f in (tmp / 'build' / d).iterdir())
                    self.assertEqual(files, [f'game_actions_{app_id}.vdf'], d)

    def test_copy_fails_when_manifest_not_renamed(self):
        with tempfile.TemporaryDirectory() as t:
            res = self._run_step(Path(t), 999, make_manifest=False)
            for r in res.values():
                self.assertNotEqual(r.returncode, 0)
                self.assertIn('missing', r.stdout + r.stderr)


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
