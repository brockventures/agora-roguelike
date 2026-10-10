"""Static guards for the Steam layer (#27, Integrate godot-steam SDK; part of
#26, Epic 5): config, achievement data, and the Steam Input action manifest
must stay in step with game/project.godot's InputMap."""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game'


def input_actions():
    text = (GAME / 'project.godot').read_text(encoding='utf-8')
    body = text.split('[input]', 1)[1].split('\n[', 1)[0]
    return set(re.findall(r'^(m0_\w+)=\{', body, re.M))


class SteamFiles(unittest.TestCase):
    def test_app_id_config(self):
        cfg = json.loads((GAME / 'data' / 'steam.json').read_text())
        self.assertIsInstance(cfg['app_id'], int)
        self.assertEqual(cfg['app_id'], 480, 'dev App ID until #30 (Steamworks onboarding)')
        self.assertIn('#30', cfg['todo'])
        self.assertTrue((GAME / 'steam' / f"game_actions_{cfg['app_id']}.vdf").exists(),
                        'action manifest must be named for the configured App ID')

    def test_achievement_data(self):
        d = json.loads((GAME / 'data' / 'achievements.json').read_text())
        stats = {s['id'] for s in d['stats']}
        ids = [a['id'] for a in d['achievements']]
        self.assertEqual(len(ids), len(set(ids)))
        for a in d['achievements']:
            self.assertRegex(a['id'], r'^[A-Z0-9_]+$')
            self.assertTrue(a['name'] and a['desc'])
            if 'stat' in a:
                self.assertIn(a['stat'], stats)
                self.assertGreater(a['threshold'], 0)
            else:
                self.assertIn('hook', a)

    def test_manifest_covers_every_inputmap_action(self):
        vdf = (GAME / 'steam' / 'game_actions_480.vdf').read_text()
        declared = set(re.findall(r'^\s*"(m0_\w+)"\s+"#Action_', vdf, re.M))
        self.assertEqual(declared, input_actions())
        labels = set(re.findall(r'^\s*"Action_(m0_\w+)"', vdf, re.M))
        self.assertEqual(labels, declared)

    def test_default_layout_binds_only_declared_actions(self):
        layout = (GAME / 'steam' / 'controller_steamdeck_default.vdf').read_text()
        bound = set(re.findall(r'game_action InGame (m0_\w+)', layout))
        self.assertTrue(bound)
        self.assertLessEqual(bound, input_actions())
        # every gamepad-reachable action is on the layout (locale is keyboard-only)
        self.assertEqual(input_actions() - bound, {'m0_locale'})


if __name__ == '__main__':
    unittest.main()
