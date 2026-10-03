"""Draw-level golden fixtures (#5, checklist 5d) are deterministic, current and self-consistent.

Regenerates every fixture with tools/golden/gen_draws.py into a temp dir and requires byte-identical
output against the committed files in game/tests/golden/draws, then checks the bookkeeping recorded
in them (edge odds make no draw and leave the bag alone, hits add up, outcomes the case names are
the outcomes recorded) and replays the bag and hazard fixtures back through the real Python modules
with the recorded draws, which fails on any draw the log does not contain.
"""
import importlib.util
import json
import os
import sqlite3
import tempfile
import types
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
COMMITTED = os.path.join(ROOT, 'game', 'tests', 'golden', 'draws')
NOT_A_CASE = {'sample.json'}  # the 5b recorder sample: a bare array of draws


def _load_generator():
    spec = importlib.util.spec_from_file_location(
        'gen_draws', os.path.join(ROOT, 'tools', 'golden', 'gen_draws.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _fixture(name):
    with open(os.path.join(COMMITTED, name + '.json'), encoding='utf-8') as f:
        return json.load(f)


class ReplayRandom:
    """Serves recorded draws in order; any call that is not the next recorded draw raises."""

    def __init__(self, draws):
        self.draws = list(draws)
        self.pos = 0

    def _next(self, call, args):
        if self.pos >= len(self.draws):
            raise AssertionError('extra draw %s%s after %d recorded' % (call, args, len(self.draws)))
        d = self.draws[self.pos]
        if d['call'] != call or d['args'] != json.loads(json.dumps(args)):
            raise AssertionError('draw %d is %s%s, recorded %s%s' % (self.pos, call, args, d['call'], d['args']))
        self.pos += 1
        return d['result']

    def randint(self, a, b):
        return self._next('randint', [a, b])

    def randrange(self, start, stop=None, step=1):
        if stop is None:
            start, stop = 0, start
        return self._next('randrange', [start, stop, step])

    def uniform(self, a, b):
        return self._next('uniform', [a, b])

    def random(self):
        return self._next('random', [])

    def choice(self, seq):
        return self._next('choice', [list(seq)])

    def shuffle(self, x):
        perm = self._next('shuffle', [list(x)])
        x[:] = [list(x)[i] for i in perm]

    def exhausted(self):
        return self.pos == len(self.draws)


class TestGoldenDrawFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gen = _load_generator()

    # ---- generator output

    def test_one_file_per_case(self):
        self.assertGreaterEqual(len(self.gen.CASES), 28)
        committed = sorted(f for f in os.listdir(COMMITTED) if f.endswith('.json') and f not in NOT_A_CASE)
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
            self.assertEqual(sorted(os.listdir(t1)), sorted(os.listdir(t2)))
            for name in os.listdir(t1):
                with open(os.path.join(t1, name), 'rb') as a, open(os.path.join(t2, name), 'rb') as b:
                    self.assertEqual(a.read(), b.read(), name)

    def test_generation_restores_the_patched_modules(self):
        import random
        import agora.bag
        import agora.hazards
        import agora.piracy
        import agora.spatial
        original = agora.bag.Bags._rng
        with tempfile.TemporaryDirectory() as tmp:
            self.gen.generate(tmp)
        self.assertIs(agora.bag.Bags._rng, original)
        for mod in (agora.hazards, agora.piracy, agora.spatial):
            self.assertIs(mod.random, random)

    # ---- shape

    def test_fixture_shape(self):
        for name in self.gen.CASES:
            d = _fixture(name)
            self.assertEqual(d['case'], name)
            self.assertEqual(d['referee_commit'], '587b07f')
            self.assertIn(d['module'], ('bag', 'hazards', 'piracy', 'spatial'))
            self.assertTrue(name.startswith(d['module']) or name.startswith('hazard') and d['module'] == 'hazards',
                            name)
            for k in ('description', 'setup', 'bag_start', 'steps', 'bag_end'):
                self.assertIn(k, d, name)
            self.assertTrue(d['steps'], name)
            for step in d['steps']:
                for k in ('call', 'input', 'draws', 'output', 'bag_after'):
                    self.assertIn(k, step, name)
                for draw in step['draws']:
                    self.assertEqual(sorted(draw), ['args', 'call', 'result'], name)
                    self.assertIn(draw['call'], ('randint', 'randrange', 'uniform', 'random', 'choice', 'gauss',
                                                 'shuffle'), name)
                for row in step['bag_after']:
                    self.assertEqual(sorted(row), sorted(self.gen.BAG_COLUMNS), name)
            text = json.dumps(d).replace('timed_out', '')
            self.assertNotIn('time_ns', text, name)
            self.assertFalse([t for t in text.split('"') if t.startswith('tx-') and t.split('-')[-1].isdigit()
                              and len(t.split('-')[-1]) > 6], name + ': a raw transit id leaked')

    def test_every_module_is_covered(self):
        modules = {_fixture(n)['module'] for n in self.gen.CASES}
        self.assertEqual(modules, {'bag', 'hazards', 'piracy', 'spatial'})

    # ---- bookkeeping

    @staticmethod
    def _rows(bag_state):
        return {(r['ns'], r['event'], r['fleet']): r for r in bag_state}

    def test_edge_odds_steps_make_no_draw_and_keep_the_bag(self):
        d = _fixture('bag_edge_odds_no_draw')
        before = d['bag_start']
        edge = 0
        for step in d['steps']:
            p = step['input']['p']
            if p <= 0 or p >= 1:
                edge += 1
                self.assertEqual(step['draws'], [], p)
                self.assertEqual(step['bag_after'], before, p)
                self.assertEqual(step['output']['result'], p >= 1)
            before = step['bag_after']
        self.assertEqual(edge, 8)
        self.assertEqual(d['steps'][-1]['bag_after'][0]['draws'], 1)  # the closing real draw

    def test_bag_fixed_p_draws_advance_one_marble_and_hits_add_up(self):
        for name in ('bag_one_in_four_refills', 'bag_three_in_ten_runs', 'bag_fleets_are_isolated',
                     'bag_p_change_rebuilds_bag', 'bag_varying_credit', 'bag_non_bag_odds_use_credit'):
            d = _fixture(name)
            hits, draws = {}, {}
            for step in d['steps']:
                inp = step['input']
                key = ('golden', inp['event'], inp['fleet'])
                draws[key] = draws.get(key, 0) + 1
                hits[key] = hits.get(key, 0) + int(step['output']['result'])
                row = self._rows(step['bag_after'])[key]
                self.assertEqual((row['draws'], row['hits']), (draws[key], hits[key]), name)
            for key, row in self._rows(d['bag_end']).items():
                self.assertEqual((row['draws'], row['hits']), (draws[key], hits[key]), name)

    def test_full_bags_hold_exactly_k_hits(self):
        # Bad-luck protection: every full bag of n marbles has exactly k hits.
        d = _fixture('bag_one_in_four_refills')
        results = [s['output']['result'] for s in d['steps']]
        self.assertEqual([sum(results[i:i + 4]) for i in (0, 4)], [1, 1])
        d = _fixture('bag_three_in_ten_runs')
        self.assertEqual(sum(s['output']['result'] for s in d['steps'][:10]), 3)
        first = d['steps'][0]['draws']
        self.assertEqual(first[0], {'call': 'shuffle', 'args': [[4, 3, 3]], 'result': first[0]['result']})
        self.assertEqual([x['call'] for x in first], ['shuffle', 'randrange', 'randrange', 'randrange'])

    def test_refill_draws_only_on_the_first_draw_of_a_bag(self):
        d = _fixture('bag_one_in_four_refills')
        self.assertEqual([len(s['draws']) for s in d['steps']], [2, 0, 0, 0, 2, 0, 0, 0, 2])
        self.assertEqual([r['refills'] for r in (s['bag_after'][0] for s in d['steps'])],
                         [1, 1, 1, 1, 2, 2, 2, 2, 3])

    def test_p_change_rebuilds_the_bag(self):
        d = _fixture('bag_p_change_rebuilds_bag')
        self.assertEqual([len(s['draws']) > 0 for s in d['steps']], [True, False, True, False, True, True])
        self.assertEqual([s['bag_after'][0]['p'] for s in d['steps']], [0.25, 0.25, 0.5, 0.5, 0.5, 0.25])

    def test_non_bag_odds_never_build_a_bag(self):
        d = _fixture('bag_non_bag_odds_use_credit')
        for step in d['steps']:
            self.assertEqual([x['call'] for x in step['draws']], ['random'])
            self.assertEqual(step['bag_after'][0]['marbles'], '')

    def test_hazard_rolls_always_draw_the_desk_values_when_enabled(self):
        for name in ('hazard_roll_both_types', 'hazard_roll_delay_only', 'hazard_roll_loss_only',
                     'hazard_roll_upgrade_factors', 'hazard_roll_zero_cargo', 'hazard_roll_certain_odds',
                     'hazard_roll_ships_isolated'):
            for step in _fixture(name)['steps']:
                self.assertEqual([x['call'] for x in step['draws']][:2], ['randint', 'uniform'], name)
                self.assertEqual(step['draws'][0]['args'], [1, 3], name)
                self.assertEqual(step['draws'][1]['args'], [0.1, 0.2], name)
        for step in _fixture('hazard_roll_disabled')['steps']:
            self.assertEqual(step['draws'], [])
            self.assertEqual(step['output'], {'delay': 0, 'lost': 0, 'note': ''})

    def test_hazard_both_types_cover_every_outcome_kind(self):
        outs = [s['output'] for s in _fixture('hazard_roll_both_types')['steps']]
        self.assertTrue(any(o['delay'] and not o['lost'] for o in outs))
        self.assertTrue(any(o['lost'] and not o['delay'] for o in outs))
        outs = [s['output'] for s in _fixture('hazard_roll_delay_only')['steps']]
        self.assertTrue(any(o['delay'] for o in outs))
        self.assertFalse(any(o['lost'] for o in outs))
        outs = [s['output'] for s in _fixture('hazard_roll_loss_only')['steps']]
        self.assertTrue(any(o['lost'] for o in outs))
        self.assertFalse(any(o['delay'] for o in outs))

    def test_hazard_one_sided_odds_draw_marbles_for_one_event_only(self):
        for name, event in (('hazard_roll_delay_only', 'delay'), ('hazard_roll_loss_only', 'loss')):
            events = {r['event'] for r in _fixture(name)['bag_end']}
            self.assertEqual(events, {event}, name)
        self.assertEqual(_fixture('hazard_roll_certain_odds')['bag_end'], [])

    def test_hazard_zero_cargo_skips_only_the_loss_marble(self):
        d = _fixture('hazard_roll_zero_cargo')
        for step in d['steps'][:3]:
            self.assertEqual({r['event'] for r in step['bag_after']}, {'delay'})
        self.assertEqual({r['event'] for r in d['bag_end']}, {'delay', 'loss'})
        self.assertEqual(self._rows(d['bag_end'])[('hazards', 'loss', 'amos/1')]['draws'], 1)

    def test_hazard_ships_have_their_own_bags(self):
        rows = self._rows(_fixture('hazard_roll_ships_isolated')['bag_end'])
        for ship in ('amos/1', 'zero/1'):
            for event in ('delay', 'loss'):
                self.assertEqual(rows[('hazards', event, ship)]['draws'], 3)

    # ---- piracy outcomes the cases name

    def test_raid_roll_outcomes(self):
        miss = _fixture('piracy_raid_roll_miss')['steps'][0]['output']
        self.assertFalse(miss['result']['raided'])
        self.assertIsNone(miss['demand'])
        hit = _fixture('piracy_raid_roll_hit')['steps'][0]['output']
        self.assertTrue(hit['result']['raided'])
        self.assertEqual(hit['demand']['ransom'], 2250)
        self.assertEqual(hit['demand']['surrender_qty'], 250)
        self.assertEqual(hit['demand']['status'], 'pending')

    def test_raid_roll_draw_order(self):
        # Hot station twice (chance() then the result), then the refill, then nothing else.
        for name in ('piracy_raid_roll_miss', 'piracy_raid_roll_hit'):
            calls = [x['call'] for x in _fixture(name)['steps'][0]['draws']]
            self.assertEqual(calls[:3], ['choice', 'choice', 'shuffle'], name)
            self.assertEqual(set(calls[3:]), {'randrange'}, name)

    def test_escorted_trips_use_their_own_bag(self):
        d = _fixture('piracy_raid_roll_escorted')
        keys = sorted(r['fleet'] for r in d['bag_end'])
        self.assertEqual(len(keys), 2)
        self.assertTrue(keys[0].endswith('|bare') and keys[1].endswith('|escort'), keys)
        rows = {r['fleet'].rsplit('|', 1)[1]: r for r in d['bag_end']}
        self.assertEqual((rows['escort']['draws'], rows['bare']['draws']), (2, 2))
        self.assertEqual([s['output']['result']['odds'] for s in d['steps']], [0.1875, 0.75, 0.1875, 0.75])

    def test_certain_and_disabled_and_zero_cargo_rolls_leave_no_bag(self):
        certain = _fixture('piracy_raid_roll_certain')
        self.assertEqual([x['call'] for x in certain['steps'][0]['draws']], ['choice', 'choice'])
        self.assertTrue(certain['steps'][0]['output']['result']['raided'])
        self.assertEqual(certain['bag_end'], [])
        zero = _fixture('piracy_zero_cargo_no_raid_draw')
        self.assertEqual([x['call'] for x in zero['steps'][0]['draws']], ['choice'])
        self.assertEqual(zero['bag_end'], [])
        off = _fixture('piracy_disabled_no_draw')
        self.assertEqual(off['steps'][0]['draws'], [])
        self.assertEqual(off['steps'][0]['output'], {'result': None})

    def test_hot_station_is_one_choice_per_call_and_constant_in_a_window(self):
        d = _fixture('piracy_hot_station_windows')
        rounds = [s['input']['round'] for s in d['steps']]
        stations = [s['output']['station'] for s in d['steps']]
        for step in d['steps']:
            self.assertEqual([x['call'] for x in step['draws']], ['choice'])
            self.assertEqual(step['draws'][0]['args'], [['earth', 'luna', 'mars', 'ceres']])
        for i in range(len(rounds)):
            for j in range(i):
                if rounds[i] // 20 == rounds[j] // 20:
                    self.assertEqual(stations[i], stations[j])

    def test_respond_draws(self):
        def respond_step(name):
            return _fixture(name)['steps'][-1]
        for name in ('piracy_respond_pay', 'piracy_respond_surrender'):
            self.assertEqual(respond_step(name)['draws'], [], name)
        pay = respond_step('piracy_respond_pay')['output']['raid']
        self.assertEqual((pay['status'], pay['cr_taken'], pay['qty_taken']), ('paid', 2250, 0))
        sur = respond_step('piracy_respond_surrender')['output']['raid']
        self.assertEqual((sur['status'], sur['qty_taken'], sur['cr_taken']), ('surrendered', 250, 0))
        for name, status in (('piracy_respond_fight_escaped', 'escaped'), ('piracy_respond_fight_lost', 'lost')):
            step = respond_step(name)
            self.assertEqual(step['output']['raid']['status'], status, name)
            calls = [x['call'] for x in step['draws']]
            self.assertEqual(calls[0], 'randint', name)
            self.assertEqual(step['draws'][0]['args'], [1, 2], name)
            self.assertEqual(calls[1:], ['shuffle', 'randrange'], name)
        lost = respond_step('piracy_respond_fight_lost')['output']['raid']
        self.assertEqual((lost['qty_taken'], lost['delay']), (250, 1))
        esc = respond_step('piracy_respond_fight_escaped')['output']['raid']
        self.assertEqual((esc['qty_taken'], esc['delay']), (0, 0))

    def test_documented_fence_account_difference(self):
        # The referee fences at the depot account; piracy.gd writes the station name. The GDScript
        # test skips this one field for these two cases and says so (KNOWN_DIVERGENCES).
        for name in ('piracy_respond_surrender', 'piracy_respond_fight_lost'):
            self.assertEqual(_fixture(name)['steps'][-1]['output']['raid']['fenced_at'], 'depot_ceres', name)

    def test_rejected_responses_draw_nothing(self):
        d = _fixture('piracy_respond_rejects_draw_nothing')
        responds = d['steps'][1:]
        self.assertEqual([s['output'].get('reason') for s in responds],
                         ['invalid_choice', 'no_demand', None, 'already_resolved'])
        self.assertEqual([len(s['draws']) > 0 for s in responds], [False, False, True, False])

    def test_privateer_trace_roll(self):
        hit = _fixture('piracy_privateer_trace_hit')
        miss = _fixture('piracy_privateer_trace_miss')
        for d, traced in ((hit, 1), (miss, 0)):
            demand = d['steps'][0]['output']['demand']
            self.assertEqual(demand['traced'], traced)
            self.assertEqual(demand['sponsor'], 'marvin')
            self.assertEqual(d['setup']['prep'][0]['op'], 'hire')
            events = {r['event']: r for r in d['bag_end']}
            self.assertEqual(sorted(events), ['raid', 'trace'])
            self.assertEqual(events['trace']['fleet'], 'marvin')
            self.assertEqual(events['trace']['p'], 0.1)
            self.assertEqual(events['trace']['hits'], traced)
            self.assertEqual(demand['odds'], 0.9)
        self.assertEqual(hit['steps'][0]['output']['demand']['fine'], 1500)
        self.assertEqual(miss['steps'][0]['output']['demand']['fine'], 0)

    # ---- spatial

    def test_spatial_price_walk_draws_one_gauss_per_station_commodity(self):
        d = _fixture('spatial_price_walk_gauss')
        n = len(d['setup']['stations']) * len(d['setup']['commodities'])
        for step in d['steps']:
            self.assertEqual(len(step['draws']), n)
            self.assertEqual({x['call'] for x in step['draws']}, {'gauss'})
            self.assertEqual({tuple(x['args']) for x in step['draws']}, {(0, d['setup']['vol'])})
        self.assertEqual(d['bag_start'], [])
        self.assertEqual(d['bag_end'], [])

    def test_spatial_routes_and_tables_have_no_randomness(self):
        import agora.spatial as spatial
        with open(spatial.__file__, encoding='utf-8') as f:
            src = f.read()
        uses = [ln.strip() for ln in src.splitlines() if 'self.rng' in ln or 'random.' in ln]
        self.assertEqual(sorted(set(uses)), sorted({'self.rng = random.Random(seed)',
                                                    'noise = self.rng.gauss(0, self.vol)'}))

    # ---- replay through the real Python modules

    def test_bag_fixtures_replay_through_the_python_bag(self):
        from agora.bag import Bags
        for name in [n for n in self.gen.CASES if n.startswith('bag_')]:
            d = _fixture(name)
            conn = sqlite3.connect(':memory:')
            bags = Bags(conn, d['setup']['ns'])
            bags.reset(d['setup']['seed'])
            for i, step in enumerate(d['steps']):
                rr = ReplayRandom(step['draws'])
                bags._rng = lambda event, fleet, seed, n, rr=rr: rr
                inp = step['input']
                fn = bags.draw_varying if step['call'] == 'draw_varying' else bags.draw
                self.assertEqual(fn(inp['event'], inp['fleet'], inp['p']), step['output']['result'], (name, i))
                self.assertTrue(rr.exhausted(), (name, i, 'recorded draws not consumed'))
                rows = conn.execute('SELECT %s FROM rng_bags WHERE event != ? ORDER BY ns, event, fleet'
                                    % ', '.join(self.gen.BAG_COLUMNS), (self.gen.SEED_EVENT,)).fetchall()
                self.assertEqual([dict(zip(self.gen.BAG_COLUMNS, r)) for r in rows], step['bag_after'], (name, i))

    def test_hazard_fixtures_replay_through_the_python_engine(self):
        from agora.hazards import HazardEngine
        import agora.hazards as hazards_mod
        for name in [n for n in self.gen.CASES if n.startswith('hazard_')]:
            d = _fixture(name)
            conn = sqlite3.connect(':memory:')
            odds = tuple(d['setup']['odds']) if d['setup']['odds'] else None
            engine = HazardEngine(conn, odds=odds, seed=d['setup']['seed'])
            engine.reset(d['setup']['seed'])
            for i, step in enumerate(d['steps']):
                rr = ReplayRandom(step['draws'])
                engine.rng = rr
                engine.bags._rng = lambda event, fleet, seed, n, rr=rr: rr
                inp = step['input']
                delay, lost, note = engine.roll(
                    inp['cargo_qty'], delay_factor=inp['delay_factor'], loss_factor=inp['loss_factor'],
                    loss_size_factor=inp['loss_size_factor'], agent_id=inp['agent_id'], total_qty=inp['total_qty'])
                self.assertEqual({'delay': delay, 'lost': lost, 'note': note}, step['output'], (name, i))
                self.assertTrue(rr.exhausted(), (name, i, 'recorded draws not consumed'))
        self.assertTrue(hasattr(hazards_mod, 'HazardEngine'))


if __name__ == '__main__':
    unittest.main()
