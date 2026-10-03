"""Settlement and ledger golden fixtures (#5, checklist 5c) are deterministic and current.

Regenerates every fixture into a temp dir and requires byte-identical output
against the committed files in game/tests/golden/settlement, then checks the
ledger and bag-state invariants on the committed copies.
"""
import importlib.util
import json
import os
import tempfile
import unittest
from collections import defaultdict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
COMMITTED = os.path.join(ROOT, 'game', 'tests', 'golden', 'settlement')
BAG_KEYS = {'ns', 'event', 'fleet', 'seed', 'p', 'marbles', 'refills', 'credit', 'draws', 'hits'}
LEDGER_KEYS = {'txn_id', 'seq', 'agent_id', 'instrument', 'delta'}


def _load(name):
    with open(os.path.join(COMMITTED, name + '.json'), encoding='utf-8') as f:
        return json.load(f)


def _load_generator():
    spec = importlib.util.spec_from_file_location(
        'gen_settlement', os.path.join(ROOT, 'tools', 'golden', 'gen_settlement.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _all_ledger(d):
    rows = list(d['prep_ledger'])
    for s in d['steps']:
        rows.extend(s['ledger'])
    return rows


class TestGoldenSettlementFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gen = _load_generator()

    def test_one_file_per_case(self):
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

    def test_fixture_shape(self):
        for name in self.gen.CASES:
            d = _load(name)
            self.assertEqual(d['case'], name)
            self.assertEqual(d['referee_commit'], '587b07f')
            self.assertTrue(d['initial_accounts'])
            self.assertTrue(d['steps'])
            for step in d['steps']:
                for k in ('call', 'input', 'response', 'round', 'ledger', 'fills', 'balances', 'ship_accounts'):
                    self.assertIn(k, step, name)
                for row in step['ledger']:
                    self.assertEqual(set(row), LEDGER_KEYS, name)

    def test_every_txn_sums_to_zero_per_instrument(self):
        for name in self.gen.CASES:
            sums = defaultdict(int)
            rows = _all_ledger(_load(name))
            self.assertTrue(rows, name)
            for r in rows:
                sums[(r['txn_id'], r['instrument'])] += r['delta']
            bad = {k: v for k, v in sums.items() if v != 0}
            self.assertEqual(bad, {}, name)

    def test_bag_rows_present_at_start_and_end(self):
        for name in self.gen.CASES:
            d = _load(name)
            for key in ('rng_bags_start', 'rng_bags_end'):
                rows = d[key]
                self.assertTrue(rows, '%s %s is empty' % (name, key))
                for r in rows:
                    self.assertEqual(set(r), BAG_KEYS, name)
                # new_game seeds one __seed__ row per desk with the case seed.
                seeds = [r for r in rows if r['event'] == '__seed__']
                self.assertTrue(seeds, name)
                self.assertTrue(all(r['seed'] == d['setup']['seed'] for r in seeds), name)

    def test_non_bag_cases_leave_bags_untouched(self):
        for name in ('simple_fill', 'non_default_ship_fill', 'partial_fill_two_rounds', 'equity_fee'):
            d = _load(name)
            self.assertEqual(d['rng_bags_start'], d['rng_bags_end'], name)

    # --- case contents ---

    def test_simple_fill_moves_cr_and_goods(self):
        step = _load('simple_fill')['steps'][1]
        by = {(r['agent_id'], r['instrument']): r['delta'] for r in step['ledger']}
        self.assertEqual(by[('marvin', 'CR')], -65)
        self.assertEqual(by[('amos', 'CR')], 65)
        self.assertEqual(by[('marvin/1', 'FRAG')], 5)
        self.assertEqual(by[('amos/1', 'FRAG')], -5)

    def test_non_default_ship_settles_on_named_vessel(self):
        d = _load('non_default_ship_fill')
        sale = d['steps'][1]
        goods = {r['agent_id'] for r in sale['ledger'] if r['instrument'] == 'FRAG'}
        self.assertEqual(goods, {'amos/2', 'marvin/1'})
        buy = d['steps'][3]
        goods = {r['agent_id'] for r in buy['ledger'] if r['instrument'] == 'FRAG'}
        self.assertEqual(goods, {'amos/1', 'zero/1'})
        self.assertEqual(buy['ship_accounts']['amos']['amos/2']['FRAG'], 6)

    def test_partial_fill_spans_two_rounds(self):
        d = _load('partial_fill_two_rounds')
        trades = [(s['round'], [r for r in s['ledger'] if r['instrument'] == 'FRAG' and '/' in r['agent_id']])
                  for s in d['steps'] if s['ledger']]
        self.assertEqual([t[0] for t in trades], [0, 1])
        qty = [sum(r['delta'] for r in rows if r['delta'] > 0) for _, rows in trades]
        self.assertEqual(qty, [4, 6])

    def test_equity_fee_is_its_own_balanced_txn(self):
        d = _load('equity_fee')
        fee_rows = [r for r in _all_ledger(d) if r['txn_id'].startswith('exchange-fee-')]
        self.assertEqual(len(fee_rows), 4)
        self.assertEqual({r['agent_id'] for r in fee_rows}, {'amos', 'ceres_exchange'})
        self.assertEqual(sorted(r['delta'] for r in fee_rows), [-2, -1, 1, 2])

    def test_escorted_raid_case_charges_escort_and_ransom(self):
        d = _load('escorted_departure_raid_paid')
        txns = {r['txn_id'].split('-tx-')[0] for r in _all_ledger(d)}
        self.assertTrue({'fuel', 'escrow', 'piracy-escort', 'piracy-ransom', 'release'} <= txns, txns)
        raid = [r for r in d['rng_bags_end'] if r['event'] == 'raid']
        self.assertEqual(len(raid), 1)
        self.assertEqual((raid[0]['draws'], raid[0]['hits']), (1, 1))

    def test_hazard_case_advances_the_bags(self):
        d = _load('hazard_round_trip_bags')
        start_events = {r['event'] for r in d['rng_bags_start']}
        self.assertEqual(start_events, {'__seed__'})
        end = {r['event']: r for r in d['rng_bags_end'] if r['event'] in ('delay', 'loss')}
        self.assertEqual(set(end), {'delay', 'loss'})
        for r in end.values():
            self.assertEqual(r['fleet'], 'amos/1')
            self.assertEqual(r['draws'], 2)
        txns = {r['txn_id'].split('-tx-')[0] for r in _all_ledger(d)}
        self.assertIn('hazard-hold', txns)


if __name__ == '__main__':
    unittest.main()
