#!/usr/bin/env python3
"""Generate settlement and ledger golden fixtures (#5, checklist 5c).

Drives a fresh AgoraReferee through scripted cases using its real public entry
points (submit_envelope, cancel_order, initiate_transit, piracy.respond,
step_round). Nothing in the settlement path is mocked. For every step it records
the input, the response, the ledger_entries rows the step wrote (grouped by
txn_id, with per-txn and per-instrument sums so the double-entry invariant is
checkable), the balances of every account the step touched, and the marble-bag
state (rng_bags) after the step. Each case also records the bag state at its
start and end and the verify_ledger_invariants() result.

Randomness: where a case draws, every draw is recorded as {call, args, result}
by the 5b recorder (tools/golden/record_draws.py). The bags' own per-refill
Randoms and the hazard/piracy desk RNGs are swapped for RecordingRandom with the
same seed string, so the stream is unchanged (CPython string seeds are
deterministic). Draws are recorded per step, in the order they were made.

The output is deterministic: no timestamps. initiate_transit builds its transit
id from time.time_ns(), so each id is rewritten to tx-<agent>-<n> (n counts the
case's transits from 1) everywhere it appears.

Usage: python3 tools/golden/gen_settlement.py [out_dir]
Default out_dir: game/tests/golden/settlement
"""
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
for p in (ROOT, os.path.dirname(os.path.abspath(__file__))):
    if p not in sys.path:
        sys.path.insert(0, p)

from agora.bag import Bags  # noqa: E402
from agora.referee import AgoraReferee  # noqa: E402
from gen_orderbook import AGENTS, SETUP as MARS_SETUP, STATION, fresh_referee  # noqa: E402
from record_draws import RecordingRandom  # noqa: E402

REFEREE_COMMIT = '587b07f'
INSTRUMENT = 'FRAG'
DEFAULT_OUT = os.path.join(ROOT, 'game', 'tests', 'golden', 'settlement')
# The draw sink of the case being built; the patched Bags._rng records into it.
_SINK_HOLDER = []
BAG_COLUMNS = 'ns, event, fleet, seed, p, marbles, refills, credit, draws, hits'


class Run:
    """One scripted case: a referee plus the recorders around it."""

    def __init__(self, description, ref, setup, prep=None, recorded_rngs=None):
        self.description = description
        self.ref = ref
        self.setup = setup
        self.steps = []
        self.sink = []  # every recorded draw, in call order
        _SINK_HOLDER[:] = [self.sink]
        self.transit_ids = []
        self.cursor = self._max_entry()
        for op in prep or []:
            self._apply_prep(op)
        self.cursor = self._max_entry()
        self.setup = dict(setup, prep=prep or [])
        for attr, seed_str in (recorded_rngs or {}).items():
            desk = getattr(ref, attr)
            rec = RecordingRandom(seed_str)
            rec.draws = self.sink
            desk.rng = rec
        self.bag_start = self.bag_state()
        self.initial_accounts = self.all_accounts()

    # ---- state readers

    def _max_entry(self):
        return self.ref.conn.execute('SELECT COALESCE(MAX(entry_id), 0) FROM ledger_entries').fetchone()[0]

    def bag_state(self):
        rows = self.ref.conn.execute(
            'SELECT %s FROM rng_bags ORDER BY ns, event, fleet' % BAG_COLUMNS).fetchall()
        return [dict(zip(BAG_COLUMNS.replace(' ', '').split(','), tuple(r))) for r in rows]

    def all_accounts(self):
        return [dict(r) for r in self.ref.conn.execute(
            'SELECT agent_id, instrument, balance FROM accounts ORDER BY agent_id, instrument')]

    def _accounts_of(self, agents):
        marks = ','.join('?' for _ in agents)
        return [dict(r) for r in self.ref.conn.execute(
            'SELECT agent_id, instrument, balance FROM accounts WHERE agent_id IN (%s) '
            'ORDER BY agent_id, instrument' % marks, sorted(agents))]

    def _new_ledger(self):
        rows = self.ref.conn.execute(
            'SELECT entry_id, txn_id, seq, agent_id, instrument, delta FROM ledger_entries '
            'WHERE entry_id > ? ORDER BY entry_id', (self.cursor,)).fetchall()
        if rows:
            self.cursor = rows[-1][0]
        return [dict(txn_id=r[1], seq=r[2], agent_id=r[3], instrument=r[4], delta=r[5]) for r in rows]

    @staticmethod
    def _txn_sums(entries):
        """Per txn: total delta and per-instrument deltas. Double entry means every total is 0."""
        txns = {}
        for e in entries:
            t = txns.setdefault(e['txn_id'], {'txn_id': e['txn_id'], 'sum': 0, 'by_instrument': {}})
            t['sum'] += e['delta']
            t['by_instrument'][e['instrument']] = t['by_instrument'].get(e['instrument'], 0) + e['delta']
        for t in txns.values():
            t['by_instrument'] = dict(sorted(t['by_instrument'].items()))
        return list(txns.values())

    def _apply_prep(self, op):
        ref = self.ref
        if op['op'] == 'mint_cr':
            with ref.lock, ref.conn:
                ref.fleet._move('golden-mint-%s' % op['agent'],
                                ((op['agent'], 'CR', op['qty']), ('SYSTEM', 'CR', -op['qty'])))
        elif op['op'] == 'buy_ship':
            r = ref.fleet.buy(op['agent'])
            assert r['kind'] == 'ship_bought', r
        elif op['op'] == 'transfer':
            r = ref.fleet.transfer(op['agent'], op['src'], op['dst'], op['instrument'], op['qty'])
            assert r.get('kind') != 'reject', r
        else:
            raise ValueError(op)

    # ---- recording

    def record(self, call, inp, response, touched=()):
        ledger = self._new_ledger()
        agents = set(touched) | {e['agent_id'] for e in ledger}
        ok, errors = self.ref.verify_ledger_invariants()
        draws = list(self.sink)
        del self.sink[:]
        step = {
            'call': call,
            'input': inp,
            'response': response,
            'ledger_entries': ledger,
            'ledger_txns': self._txn_sums(ledger),
            'ledger_sum': sum(e['delta'] for e in ledger),
            'balances': self._accounts_of(agents) if agents else [],
            'bag_after': self.bag_state(),
            'draws': draws,
            'invariants_ok': ok,
            'invariant_errors': list(errors),
        }
        self.steps.append(step)
        return step

    # ---- trade calls (same envelope shape as gen_orderbook)

    def order(self, order_id, agent, side, qty, price, instrument=INSTRUMENT, station=STATION, vessel=None):
        payload = {'order_id': order_id, 'agent_id': agent, 'side': side, 'qty': qty,
                   'limit_price': price, 'instrument': instrument, 'seq_seen': self.ref.current_seq}
        if station is not None:
            payload['station_id'] = station
        if vessel is not None:
            payload['vessel_id'] = vessel
        env = {'v': 1, 'kind': 'order', 'payload': payload}
        inp = json.loads(json.dumps(env))  # copy: the referee may mutate the payload
        resp = self.ref.submit_envelope(env)
        assert resp.get('floor', 'open') == 'open', resp
        self.record('submit_envelope', inp, resp, [agent])

    # ---- transit / piracy / round calls

    def transit(self, agent, dest, commodity, qty, escort=False):
        resp = self.ref.initiate_transit(agent, dest, commodity, qty, escort=escort)
        assert resp['kind'] == 'transit_started' or resp['kind'] != 'reject', resp
        self.transit_ids.append((resp['payload']['transit_id'], agent))
        self.record('initiate_transit',
                    {'agent_id': agent, 'dest': dest, 'commodity': commodity, 'cargo_qty': qty, 'escort': escort},
                    resp, [agent])

    def respond(self, agent, choice, n=1):
        tid = [t for t, a in self.transit_ids if a == agent][n - 1]
        resp = self.ref.piracy.respond(agent, tid, choice)
        assert resp['kind'] == 'piracy_respond_ok', resp
        self.record('piracy_respond', {'agent_id': agent, 'transit_n': n, 'choice': choice}, resp, [agent])

    def step_round(self, touched=()):
        resp = self.ref.step_round()
        self.record('step_round', {}, resp, touched)

    def fixture(self, case):
        data = {
            'case': case,
            'description': self.description,
            'referee_commit': REFEREE_COMMIT,
            'setup': self.setup,
            'initial_accounts': self.initial_accounts,
            'bag_start': self.bag_start,
            'steps': self.steps,
            'bag_end': self.bag_state(),
            'final_invariants_ok': self.ref.verify_ledger_invariants()[0],
        }
        text = json.dumps(data, indent=2)
        counts = {}
        for tid, agent in self.transit_ids:
            counts[agent] = counts.get(agent, 0) + 1
            text = text.replace(tid, 'tx-%s-%d' % (agent, counts[agent]))
        return json.loads(text)


def mars_run(description, prep=None, referee=None):
    return Run(description, referee or fresh_referee(), dict(MARS_SETUP, station_id=STATION,
                                                             instrument=INSTRUMENT), prep=prep)


def bag_run(description, seed, piracy=(0.5, 0.5), agents=('amos',)):
    """A game with hazards (0.5/0.5) and piracy on. A roll whose p is 0 or at least 1 never touches
    bag state, so odds are chosen to make every roll a real marble where the case needs it."""
    odds = (0.5, 0.5)
    ref = AgoraReferee(hazards=odds, piracy=piracy, depots=True)
    ref.new_game(seed=seed, warmup_rounds=2, depots=True, hazards=odds, piracy=piracy)
    setup = {'seed': seed, 'warmup_rounds': 2, 'depots': True, 'hazards': list(odds), 'piracy': list(piracy),
             'agents': list(agents)}
    rngs = {'hazards': 'hazards-%d' % seed, 'piracy': 'piracy-%d' % seed}
    return Run(description, ref, setup, recorded_rngs=rngs)


# ------------------------------------------------------------ trade settlement
# Mars FRAG reference price is 12.8, so the +-10% band is [11.52, 14.08]
# (agora/circuit_breaker.py). Every crossing price below sits inside it.

def case_simple_trade():
    r = mars_run('One resting ask and one crossing bid at the resting price: the buyer CR is debited and the '
                 'seller credited, the goods move the other way, in one txn trade-<id> with four entries.')
    r.order('a1', 'amos', 'ask', 5, 13)
    r.order('m1', 'marvin', 'bid', 5, 13)
    return r


def case_multi_party_sweep():
    r = mars_run('One bid sweeps asks from three different sellers. Four parties, three trades, three txns, each '
                 'summing to 0; the buyer pays each seller at that seller resting price.')
    r.order('a1', 'amos', 'ask', 3, 12)
    r.order('z1', 'zero', 'ask', 4, 13)
    r.order('r1', 'aerial', 'ask', 5, 14)
    r.order('m1', 'marvin', 'bid', 12, 14)
    return r


def case_two_ship_ledger():
    r = mars_run('Corp amos owns two ships. The goods legs of the ledger name the ship (amos/2 sells, amos/1 '
                 'buys); the CR legs name the corp.',
                 prep=[{'op': 'mint_cr', 'agent': 'amos', 'qty': 30000},
                       {'op': 'buy_ship', 'agent': 'amos'},
                       {'op': 'transfer', 'agent': 'amos', 'src': 'amos/1', 'dst': 'amos/2',
                        'instrument': INSTRUMENT, 'qty': 10}])
    r.order('a1', 'amos', 'ask', 6, 13, vessel='amos/2')
    r.order('m1', 'marvin', 'bid', 4, 13)
    r.order('z1', 'zero', 'ask', 3, 12)
    r.order('a2', 'amos', 'bid', 3, 12, vessel='amos/1')
    return r


def case_self_cross_ledger():
    r = mars_run('An agent bids into its own resting ask. The trade settles like any other (no self-trade '
                 'prevention): the ledger has four entries, and the agent net balance does not change.')
    r.order('a1', 'amos', 'ask', 5, 13)
    r.order('a2', 'amos', 'bid', 5, 13)
    return r


def case_reject_insufficient_balance():
    r = mars_run('Orders the corp cannot fund are rejected insufficient_balance before anything settles: a bid '
                 'over the CR balance, then an ask over the goods balance. A rejected order writes no ledger '
                 'entry and changes no balance.')
    r.order('r1', 'marvin', 'bid', 1001, 12)
    r.order('r2', 'amos', 'ask', 1001, 13)
    r.order('ok', 'marvin', 'bid', 1, 12)  # a funded order still rests with no ledger entry (no trade)
    return r


def case_stock_exchange_fee():
    ref = AgoraReferee(depots=True, rival_shares=100)
    ref.new_game(seed=1, warmup_rounds=0)
    ref.upgrades_enabled = True
    r = Run('Stock trades carry the exchange transaction fee (#165) when upgrades are on: the taker pays '
            'round(cost * 0.005) CR to ceres_exchange in a separate txn exchange-fee-<trade_id>, which also '
            'sums to 0. Both trades here have the bidder as taker.',
            ref, {'seed': 1, 'warmup_rounds': 0, 'depots': True, 'rival_shares': 100,
                  'upgrades_enabled': True, 'agents': ['amos', 'marvin', 'zero', 'aerial']})
    r.order('s1', 'zero', 'ask', 10, 40, instrument='EQ_AMOS', station='earth')
    r.order('b1', 'marvin', 'bid', 10, 40, instrument='EQ_AMOS', station=None)
    r.order('s2', 'zero', 'ask', 10, 41, instrument='EQ_AMOS', station='earth')
    r.order('b2', 'marvin', 'bid', 10, 41, instrument='EQ_AMOS', station=None)
    return r


def case_idle_fee():
    ref = AgoraReferee(depots=True, idle_fee=10)
    ref.new_game(seed=1, warmup_rounds=0)
    r = Run('Idle fee settlement: when one fleet acts in a round, every docked fleet that did nothing pays '
            'idle_fee CR to SYSTEM in a txn idle-fee-<agent>-<round>. The acting fleet pays nothing.',
            ref, {'seed': 1, 'warmup_rounds': 0, 'depots': True, 'idle_fee': 10,
                  'agents': ['amos', 'marvin', 'zero', 'aerial']})
    ref.cancel_all('amos')  # any action marks the fleet active this round
    r.step_round()
    return r


# ------------------------------------------------------------ settlement that draws from the bag
# Seed 1 at hazards 0.5/0.5, piracy 0.5/0.5: amos/1 flies ceres -> mars with 500 FRAG. The delay marble
# misses, the loss marble hits (124 units lost), the raid marble hits (a pending ransom demand).

def _arrive(r, agent='amos'):
    for _ in range(8):
        in_flight = [t for t in r.ref.fleet_locations(agent) if t.get('status') != 'docked']
        if not in_flight:
            break
        r.step_round([agent])


def case_transit_hazard_loss_and_pay_ransom():
    r = bag_run('Transit settlement with real marbles. Departure writes fuel, toll and cargo escrow txns; the '
                'hazard loss marble hits and the lost units stay with SYSTEM; the raid marble hits and the '
                'ransom is paid (piracy-ransom txn). Arrival releases the surviving cargo from escrow. Bag '
                'state and every draw are recorded.', seed=1)
    r.transit('amos', 'mars', 'FRAG', 500)
    r.respond('amos', 'pay')
    _arrive(r)
    return r


def case_piracy_surrender():
    r = bag_run('Same departure as the ransom case, but the fleet surrenders cargo: the stolen goods leave the '
                'escrow to SYSTEM and the black-market depot, with no CR moving. Arrival releases what is left.',
                seed=1)
    r.transit('amos', 'mars', 'FRAG', 500)
    r.respond('amos', 'surrender')
    _arrive(r)
    return r


def case_piracy_fight_escape_bag():
    r = bag_run('Same departure, but the fleet fights: the escape marble is drawn from the ship bag and the '
                'fight-delay randint from the desk RNG. At this seed the escape marble misses, so the cargo is '
                'lost to the raiders (piracy-loot txn) and the arrival is delayed.', seed=1)
    r.transit('amos', 'mars', 'FRAG', 500)
    r.respond('amos', 'fight')
    _arrive(r)
    return r


def case_transit_no_hit():
    r = bag_run('A trip where none of the delay, loss or raid marbles hits (piracy odds 0.1): departure writes '
                'fuel, toll and escrow txns, the bags advance one marble per roll, and arrival releases the '
                'whole cargo with no other ledger entry.', seed=2, piracy=(0.1, 0.1))
    r.transit('amos', 'mars', 'FRAG', 500)
    _arrive(r)
    return r


CASES = {
    'simple_trade': case_simple_trade,
    'multi_party_sweep': case_multi_party_sweep,
    'two_ship_ledger': case_two_ship_ledger,
    'self_cross_ledger': case_self_cross_ledger,
    'reject_insufficient_balance': case_reject_insufficient_balance,
    'stock_exchange_fee': case_stock_exchange_fee,
    'idle_fee': case_idle_fee,
    'transit_hazard_loss_and_pay_ransom': case_transit_hazard_loss_and_pay_ransom,
    'piracy_surrender': case_piracy_surrender,
    'piracy_fight_escape_bag': case_piracy_fight_escape_bag,
    'transit_no_hit': case_transit_no_hit,
}


def generate(out_dir=DEFAULT_OUT):
    os.makedirs(out_dir, exist_ok=True)
    written = []
    for name, build in CASES.items():
        path = os.path.join(out_dir, name + '.json')
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            json.dump(_run_case(build).fixture(name), f, indent=2)
            f.write('\n')
        written.append(path)
    return written


def _run_case(build):
    """Patch Bags._rng so refill randoms record into the case's sink, then build the case.

    Run.__init__ registers its draw sink in _SINK_HOLDER."""
    original = Bags._rng

    def recording(self, event, fleet, seed, n):
        rec = RecordingRandom('bag-%s-%s-%s-%s-%s' % (self.ns, seed, event, fleet, n))
        if _SINK_HOLDER:
            rec.draws = _SINK_HOLDER[-1]
        return rec

    Bags._rng = recording
    _SINK_HOLDER.clear()
    try:
        return build()
    finally:
        Bags._rng = original
        _SINK_HOLDER.clear()


if __name__ == '__main__':
    for p in generate(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT):
        print(os.path.relpath(p, ROOT))
