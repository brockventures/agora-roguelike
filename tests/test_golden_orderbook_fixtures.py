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


def _load_fixture(name):
    with open(os.path.join(COMMITTED, name + '.json'), encoding='utf-8') as f:
        return json.load(f)


def _seq_of(step):
    return step['response']['payload']['seq']


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
        self.assertGreaterEqual(len(self.gen.CASES), 9)
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
                for k in ('input', 'response', 'fills', 'book', 'balances', 'ship_accounts'):
                    self.assertIn(k, step, name)
                self.assertIn('bids', step['book'])
                self.assertIn('asks', step['book'])

    # --- seq rules (referee behaviour at 587b07f, recorded in the fixtures) ---

    def test_trade_consumes_a_seq_number(self):
        # price_time_priority: two resting asks (seq 1, 2), then one bid that
        # trades twice. The order takes one seq and each trade takes one more,
        # so the next recorded seq is 2 + 1 + 2 = 5, not 3.
        steps = _load_fixture('price_time_priority')['steps']
        self.assertEqual([_seq_of(s) for s in steps], [1, 2, 5])
        self.assertEqual(len(steps[2]['fills']), 2)
        self.assertEqual(_seq_of(steps[2]) - _seq_of(steps[1]), 1 + len(steps[2]['fills']))
        # Holds for every submitted order that fills, in every case.
        for name in self.gen.CASES:
            prev = 0
            for step in _load_fixture(name)['steps']:
                payload = step['response'].get('payload', {})
                if step['response']['kind'] == 'market_tick' and step['call'] == 'submit_envelope':
                    if step['fills']:
                        self.assertEqual(payload['seq'] - prev, 1 + len(step['fills']), name)
                    else:
                        self.assertEqual(payload['seq'] - prev, 1, name)
                prev = payload.get('seq', prev)

    def test_rejected_cancel_does_not_advance_seq(self):
        # cancel_resting: orders take seq 1 and 2, the real cancel takes seq 3,
        # then a repeat cancel and an unknown-order cancel are rejected and
        # leave seq at 3.
        steps = _load_fixture('cancel_resting')['steps']
        self.assertEqual([s['call'] for s in steps], ['submit_envelope', 'submit_envelope',
                                                      'cancel_order', 'cancel_order', 'cancel_order'])
        self.assertEqual([_seq_of(s) for s in steps], [1, 2, 3, 3, 3])
        self.assertEqual(steps[2]['response']['status'], 'cancelled')
        for rejected in steps[3:]:
            self.assertEqual(rejected['response']['kind'], 'reject')
            self.assertEqual(rejected['response']['payload']['reason'], 'order_not_cancellable')

    def test_rejected_orders_do_not_advance_seq(self):
        for name in ('reject_unfunded_ask', 'reject_insufficient_cr_bid', 'two_ship_settlement'):
            prev = 0
            rejects = 0
            for step in _load_fixture(name)['steps']:
                if step['response']['kind'] == 'reject':
                    rejects += 1
                    self.assertEqual(_seq_of(step), prev, name)
                    self.assertEqual(step['response']['payload']['reason'], 'insufficient_balance', name)
                prev = _seq_of(step)
            self.assertGreaterEqual(rejects, 1, name)

    # --- ship vs corp settlement ---

    def test_two_ship_settlement_settles_on_the_named_ship(self):
        d = _load_fixture('two_ship_settlement')
        self.assertEqual(d['initial_ship_accounts']['amos']['amos/1']['FRAG'], 990)
        self.assertEqual(d['initial_ship_accounts']['amos']['amos/2']['FRAG'], 10)
        s = d['steps']
        # amos/2 sold 4: only that ship's hold drops; amos/1 is untouched.
        self.assertEqual(s[1]['fills'][0]['seller_vessel'], 'amos/2')
        self.assertEqual(s[1]['ship_accounts']['amos']['amos/1']['FRAG'], 990)
        self.assertEqual(s[1]['ship_accounts']['amos']['amos/2']['FRAG'], 6)
        # amos/1 bought 3: only that ship's hold grows.
        self.assertEqual(s[3]['fills'][0]['buyer_vessel'], 'amos/1')
        self.assertEqual(s[3]['ship_accounts']['amos']['amos/1']['FRAG'], 993)
        self.assertEqual(s[3]['ship_accounts']['amos']['amos/2']['FRAG'], 6)
        # Corp total is the sum of its ships, and differs from either ship.
        for step in s:
            ships = step['ship_accounts'].get('amos')
            if ships is None:
                continue
            total = next(r['balance'] for r in step['balances']
                         if r['agent_id'] == 'amos' and r['instrument'] == 'FRAG')
            self.assertEqual(total, sum(v.get('FRAG', 0) for v in ships.values()))
        # The final ask fits the corp total but not amos/2: rejected per ship.
        self.assertIn("Account 'amos/2'", s[4]['response']['payload']['detail'])
        rejected = s[4]['input']['payload']['qty']
        corp_total = next(r['balance'] for r in s[3]['balances']
                          if r['agent_id'] == 'amos' and r['instrument'] == 'FRAG')
        self.assertGreater(rejected, s[3]['ship_accounts']['amos']['amos/2']['FRAG'])
        self.assertLessEqual(rejected, corp_total)

    def test_funding_boundary_ask_for_exactly_available_rests(self):
        # amos/1 holds 1000 FRAG with 5 committed to a resting ask: 995 available.
        # 996 is rejected; exactly 995 is accepted, so the check is '>' not '>='.
        steps = _load_fixture('reject_unfunded_ask')['steps']
        over, exact = steps[2], steps[3]
        self.assertEqual(over['input']['payload']['order_id'], 'u3')
        self.assertEqual(over['input']['payload']['qty'], 996)
        self.assertEqual(over['response']['kind'], 'reject')
        self.assertEqual(over['response']['payload']['reason'], 'insufficient_balance')
        self.assertIn('balance 1000 - committed 5', over['response']['payload']['detail'])
        self.assertEqual(exact['input']['payload']['order_id'], 'u4')
        self.assertEqual(exact['input']['payload']['qty'], 995)
        self.assertEqual(exact['response']['kind'], 'market_tick')
        self.assertEqual(_seq_of(exact), _seq_of(steps[1]) + 1)
        self.assertEqual([o['order_id'] for o in exact['book']['asks']], ['u2', 'u4'])
        self.assertEqual(exact['book']['asks'][1]['qty'], 995)


if __name__ == '__main__':
    unittest.main()
