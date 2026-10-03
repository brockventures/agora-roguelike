"""Settlement and ledger golden fixtures (#5, checklist 5c) are deterministic, current and self-consistent.

Regenerates every fixture into a temp dir and requires byte-identical output against the committed
files in game/tests/golden/settlement, then checks the double-entry invariant, balance reconciliation
and bag-state bookkeeping recorded in them.
"""
import importlib.util
import json
import os
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
COMMITTED = os.path.join(ROOT, 'game', 'tests', 'golden', 'settlement')


def _load_fixture(name):
    with open(os.path.join(COMMITTED, name + '.json'), encoding='utf-8') as f:
        return json.load(f)


def _load_generator():
    spec = importlib.util.spec_from_file_location(
        'gen_settlement', os.path.join(ROOT, 'tools', 'golden', 'gen_settlement.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _balance_map(rows):
    return {(r['agent_id'], r['instrument']): r['balance'] for r in rows}


class TestGoldenSettlementFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gen = _load_generator()

    def test_one_file_per_case(self):
        self.assertGreaterEqual(len(self.gen.CASES), 11)
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
            d = _load_fixture(name)
            self.assertEqual(d['case'], name)
            self.assertEqual(d['referee_commit'], '587b07f')
            for k in ('description', 'setup', 'initial_accounts', 'bag_start', 'steps', 'bag_end'):
                self.assertIn(k, d, name)
            self.assertTrue(d['initial_accounts'], name)
            self.assertTrue(d['steps'], name)
            self.assertTrue(d['final_invariants_ok'], name)
            for step in d['steps']:
                for k in ('call', 'input', 'response', 'ledger_entries', 'ledger_txns', 'ledger_sum',
                          'balances', 'bag_after', 'draws', 'invariants_ok', 'invariant_errors'):
                    self.assertIn(k, step, name)
                self.assertTrue(step['invariants_ok'], name)
                self.assertEqual(step['invariant_errors'], [], name)
            self.assertNotIn('time', json.dumps(d).replace('timed_out', ''), name + ': wall-clock field leaked')

    def test_transit_ids_are_normalised(self):
        for name in self.gen.CASES:
            with open(os.path.join(COMMITTED, name + '.json'), encoding='utf-8') as f:
                text = f.read()
            self.assertNotRegex(text, r'tx-[a-z]+-\d{12,}', name)

    # --- double entry ---

    def test_every_step_and_txn_sums_to_zero(self):
        entries = 0
        for name in self.gen.CASES:
            for step in _load_fixture(name)['steps']:
                self.assertEqual(step['ledger_sum'], sum(e['delta'] for e in step['ledger_entries']), name)
                self.assertEqual(step['ledger_sum'], 0, name)
                for t in step['ledger_txns']:
                    self.assertEqual(t['sum'], 0, '%s %s' % (name, t['txn_id']))
                    for inst, net in t['by_instrument'].items():
                        self.assertEqual(net, 0, '%s %s %s' % (name, t['txn_id'], inst))
                self.assertEqual({e['txn_id'] for e in step['ledger_entries']},
                                 {t['txn_id'] for t in step['ledger_txns']}, name)
                entries += len(step['ledger_entries'])
        self.assertGreater(entries, 50)

    def test_balances_reconcile_with_ledger_deltas(self):
        for name in self.gen.CASES:
            d = _load_fixture(name)
            state = _balance_map(d['initial_accounts'])
            for i, step in enumerate(d['steps']):
                delta = {}
                for e in step['ledger_entries']:
                    k = (e['agent_id'], e['instrument'])
                    delta[k] = delta.get(k, 0) + e['delta']
                after = _balance_map(step['balances'])
                for k, v in delta.items():
                    self.assertEqual(after.get(k), state.get(k, 0) + v, '%s step %d %s' % (name, i, k))
                for k, v in after.items():
                    self.assertEqual(v, state.get(k, 0) + delta.get(k, 0), '%s step %d %s' % (name, i, k))
                state.update(after)

    # --- trade settlement ---

    def test_simple_trade_ledger(self):
        d = _load_fixture('simple_trade')
        self.assertEqual([len(s['ledger_entries']) for s in d['steps']], [0, 4])
        entries = {(e['agent_id'], e['instrument']): e['delta'] for e in d['steps'][1]['ledger_entries']}
        self.assertEqual(entries, {('marvin', 'CR'): -65, ('amos', 'CR'): 65,
                                   ('marvin/1', 'FRAG'): 5, ('amos/1', 'FRAG'): -5})

    def test_multi_party_sweep_has_four_parties_three_txns(self):
        step = _load_fixture('multi_party_sweep')['steps'][3]
        self.assertEqual(len(step['ledger_txns']), 3)
        parties = {e['agent_id'] for e in step['ledger_entries'] if e['instrument'] == 'CR'}
        self.assertEqual(parties, {'marvin', 'amos', 'zero', 'aerial'})
        buyer_cr = sum(e['delta'] for e in step['ledger_entries']
                       if e['agent_id'] == 'marvin' and e['instrument'] == 'CR')
        self.assertEqual(buyer_cr, -(3 * 12 + 4 * 13 + 5 * 14))

    def test_two_ship_goods_legs_name_the_ship_and_cr_legs_the_corp(self):
        d = _load_fixture('two_ship_ledger')
        sale = d['steps'][1]['ledger_entries']
        self.assertIn(('amos/2', 'FRAG', -4), [(e['agent_id'], e['instrument'], e['delta']) for e in sale])
        self.assertIn(('amos', 'CR', 52), [(e['agent_id'], e['instrument'], e['delta']) for e in sale])
        buy = d['steps'][3]['ledger_entries']
        self.assertIn(('amos/1', 'FRAG', 3), [(e['agent_id'], e['instrument'], e['delta']) for e in buy])

    def test_self_cross_nets_to_zero(self):
        step = _load_fixture('self_cross_ledger')['steps'][1]
        net = {}
        for e in step['ledger_entries']:
            k = (e['agent_id'].split('/')[0], e['instrument'])
            net[k] = net.get(k, 0) + e['delta']
        self.assertEqual(set(net.values()), {0})
        self.assertEqual(len(step['ledger_entries']), 4)

    def test_rejects_write_nothing(self):
        d = _load_fixture('reject_insufficient_balance')
        rejects = [s for s in d['steps'] if s['response']['kind'] == 'reject']
        self.assertEqual(len(rejects), 2)
        for s in d['steps']:
            self.assertEqual(s['ledger_entries'], [])
            if s['response']['kind'] == 'reject':
                self.assertEqual(s['response']['payload']['reason'], 'insufficient_balance')
        initial = _balance_map(d['initial_accounts'])
        for s in d['steps']:
            for k, v in _balance_map(s['balances']).items():
                self.assertEqual(v, initial[k])
        self.assertEqual(d['bag_start'], d['bag_end'])

    def test_exchange_fee_is_a_separate_balanced_txn_paid_by_the_taker(self):
        d = _load_fixture('stock_exchange_fee')
        fees = []
        for step in d['steps']:
            for t in step['ledger_txns']:
                if t['txn_id'].startswith('exchange-fee-'):
                    fees.append(t)
                    rows = [e for e in step['ledger_entries'] if e['txn_id'] == t['txn_id']]
                    self.assertEqual({e['agent_id'] for e in rows}, {'marvin', 'ceres_exchange'})
                    self.assertEqual({e['instrument'] for e in rows}, {'CR'})
        self.assertEqual(len(fees), 2)
        paid = [next(e['delta'] for e in s['ledger_entries'] if e['agent_id'] == 'ceres_exchange')
                for s in d['steps'] if any(t['txn_id'].startswith('exchange-fee-') for t in s['ledger_txns'])]
        self.assertEqual(paid, [2, 2])  # round(400 * 0.005), round(410 * 0.005)

    def test_idle_fee_charges_idlers_only(self):
        step = _load_fixture('idle_fee')['steps'][0]
        txns = sorted(t['txn_id'] for t in step['ledger_txns'])
        self.assertEqual(txns, ['idle-fee-aerial-0', 'idle-fee-marvin-0', 'idle-fee-zero-0'])
        self.assertEqual(step['response']['idle_fees'], {'aerial': 10, 'marvin': 10, 'zero': 10})

    # --- bag state and draws ---

    def test_bag_bookkeeping_chains(self):
        for name in self.gen.CASES:
            d = _load_fixture(name)
            self.assertEqual(d['bag_end'], d['steps'][-1]['bag_after'], name)

            def keyed(rows):
                return {(r['ns'], r['event'], r['fleet']): r for r in rows}
            start, end = keyed(d['bag_start']), keyed(d['bag_end'])
            drawn = sum(len(s['draws']) for s in d['steps'])
            advanced = sum(end[k]['draws'] - start.get(k, {'draws': 0})['draws'] for k in end)
            if advanced == 0:
                self.assertEqual(d['bag_start'], d['bag_end'], name)
            else:
                self.assertGreater(drawn, 0, name)

    def test_bag_cases_record_draws_and_marbles(self):
        for name in ('transit_hazard_loss_and_pay_ransom', 'piracy_surrender', 'piracy_fight_escape_bag',
                     'transit_no_hit'):
            d = _load_fixture(name)
            self.assertNotEqual(d['bag_start'], d['bag_end'], name)
            calls = {c['call'] for s in d['steps'] for c in s['draws']}
            self.assertTrue(calls <= {'randint', 'uniform', 'random', 'choice', 'gauss', 'shuffle', 'randrange'}, name)
            self.assertIn('shuffle', calls, name)  # a bag refill
            for s in d['steps']:
                for c in s['draws']:
                    self.assertEqual(set(c), {'call', 'args', 'result'}, name)
        # Seed 1: the delay marble misses, the loss marble hits, the raid marble hits.
        end = {r['event']: r for r in _load_fixture('transit_hazard_loss_and_pay_ransom')['bag_end']
               if r['fleet'] == 'amos/1' or r['event'] == 'raid'}
        self.assertEqual((end['delay']['draws'], end['delay']['hits']), (1, 0))
        self.assertEqual((end['loss']['draws'], end['loss']['hits']), (1, 1))
        self.assertEqual((end['raid']['draws'], end['raid']['hits']), (1, 1))
        # No marble of any kind hit.
        quiet = _load_fixture('transit_no_hit')['bag_end']
        self.assertEqual(sum(r['hits'] for r in quiet), 0)

    def test_hazard_loss_stays_with_system_and_ransom_balances(self):
        d = _load_fixture('transit_hazard_loss_and_pay_ransom')
        depart = d['steps'][0]
        self.assertEqual(depart['response']['payload']['hazard']['lost_qty'], 124)
        self.assertEqual([t['txn_id'] for t in depart['ledger_txns']],
                         ['fuel-tx-amos-1', 'toll-tx-amos-1', 'escrow-tx-amos-1'])
        ransom = d['steps'][1]
        self.assertEqual([t['txn_id'] for t in ransom['ledger_txns']], ['piracy-ransom-tx-amos-1'])
        self.assertEqual(ransom['response']['payload']['status'], 'paid')
        release = d['steps'][-1]
        self.assertEqual([t['txn_id'] for t in release['ledger_txns']], ['release-tx-amos-1'])
        # 500 shipped, 124 lost in flight: 376 come out of escrow.
        self.assertEqual(sorted(e['delta'] for e in release['ledger_entries']), [-376, 376])

    def test_surrender_and_fight_loot_move_goods_not_cr(self):
        for name in ('piracy_surrender', 'piracy_fight_escape_bag'):
            step = _load_fixture(name)['steps'][1]
            self.assertTrue(all(t['txn_id'].startswith('piracy-loot-') for t in step['ledger_txns']), name)
            self.assertEqual({e['instrument'] for e in step['ledger_entries']}, {'FRAG'}, name)
        fight = _load_fixture('piracy_fight_escape_bag')['steps'][1]
        self.assertEqual(fight['response']['payload']['status'], 'lost')
        self.assertEqual([c['call'] for c in fight['draws']][:1], ['randint'])


if __name__ == '__main__':
    unittest.main()
