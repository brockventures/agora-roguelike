#!/usr/bin/env python3
"""Generate settlement and ledger golden fixtures (#5, checklist 5c).

Drives a fresh AgoraReferee through scripted cases using its real public entry
points (submit_envelope, initiate_transit, step_round, get_accounts,
get_ship_accounts, get_ticks). Nothing in settlement, escrow, fee or bag code is
reimplemented or mocked: every ledger row recorded here is read back out of the
referee's own `ledger_entries` table, and every bag row out of `rng_bags`.

The one thing the generator pins is the wall clock. `initiate_transit` names a
transit `tx-<agent>-<time.time_ns()>`, so `agora.referee.time` is wrapped so
that `time_ns()` counts up from a fixed value. Nothing else about the referee
is touched.

Each step records:
  input, response, round,
  ledger      every ledger_entries row the step wrote, in write order
              ({txn_id, seq, agent_id, instrument, delta}),
  fills       trade payloads (order steps),
  balances    get_accounts rows after the step, for every corp and every other
              account the step's ledger touched (SYSTEM, ceres_exchange ...),
  ship_accounts  get_ship_accounts per corp after the step.
Each case also records `rng_bags_start` / `rng_bags_end`: every rng_bags row
(the marble-bag state, agora/bag.py) at the start and end of the case.

Every txn's deltas must sum to zero per instrument; the generator asserts it
(and the referee's own verify_ledger_invariants) after every step, prep
included.

Usage: python3 tools/golden/gen_settlement.py [out_dir]
Default out_dir: game/tests/golden/settlement
"""
import json
import os
import sys
import time as _real_time
from collections import defaultdict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

import agora.referee as referee_mod  # noqa: E402
from agora.referee import AgoraReferee  # noqa: E402

REFEREE_COMMIT = '587b07f'
AGENTS = ('amos', 'zero', 'marvin', 'aerial')
DEFAULT_OUT = os.path.join(ROOT, 'game', 'tests', 'golden', 'settlement')
BAG_COLUMNS = ('ns', 'event', 'fleet', 'seed', 'p', 'marbles', 'refills', 'credit', 'draws', 'hits')


class _FixedClock:
    """Stand-in for the `time` module inside agora.referee: time_ns() is a
    counter, everything else is the real module."""

    def __init__(self):
        self.n = 1_000_000_000

    def time_ns(self):
        self.n += 1
        return self.n

    def __getattr__(self, name):
        return getattr(_real_time, name)


def assert_zero_sum(rows, label):
    """Every txn's deltas sum to zero per instrument."""
    sums = defaultdict(int)
    for r in rows:
        sums[(r['txn_id'], r['instrument'])] += r['delta']
    bad = {k: v for k, v in sums.items() if v != 0}
    assert not bad, '%s: unbalanced txns %r' % (label, bad)


class Scenario:
    def __init__(self, description, station, seed, setup=None, prep=None, roster=None):
        """setup: kwargs for AgoraReferee(...) and new_game(...) (hazards,
        piracy, upgrades, exchange_shares ...), recorded verbatim.
        prep: ops applied before the first step, recorded with the ledger rows
        they wrote. Ops: mint_cr, buy_ship, transfer (see gen_orderbook.py)."""
        referee_mod.time = _FixedClock()
        self.description = description
        self.station = station
        self.seed = seed
        self.setup = dict(setup or {})
        self.ref = AgoraReferee(asymmetric=True, **self.setup)
        self.ref.new_game(seed=seed, warmup_rounds=0, **self.setup)
        self.ref.set_asymmetric_roster({a: station for a in AGENTS})
        self.prep = prep or []
        self._last_entry = self._max_entry()
        self.prep_ledger = []
        for op in self.prep:
            self._apply_prep(op)
        self.prep_ledger = self._new_ledger()
        assert_zero_sum(self.prep_ledger, 'prep')
        self._check_invariants('prep')
        self.initial_balances = self._balances(AGENTS)
        self.initial_ship_accounts = self._ships()
        self.bags_start = self._bags()
        self.steps = []

    # ---------------------------------------------------------- readers

    def _max_entry(self):
        return self.ref.conn.execute('SELECT COALESCE(MAX(entry_id), 0) FROM ledger_entries').fetchone()[0]

    def _new_ledger(self):
        rows = self.ref.conn.execute(
            'SELECT txn_id, seq, agent_id, instrument, delta FROM ledger_entries WHERE entry_id > ? '
            'ORDER BY entry_id', (self._last_entry,)).fetchall()
        self._last_entry = self._max_entry()
        return [dict(r) for r in rows]

    def _bags(self):
        cols = ', '.join(BAG_COLUMNS)
        rows = self.ref.conn.execute(
            'SELECT %s FROM rng_bags ORDER BY ns, event, fleet' % cols).fetchall()
        return [dict(r) for r in rows]

    def _balances(self, ids):
        out = []
        for a in sorted(ids):
            out.extend(self.ref.get_accounts(a))
        return out

    def _ships(self):
        return {a: self.ref.get_ship_accounts(a) for a in sorted(AGENTS)}

    def _check_invariants(self, label):
        ok, errs = self.ref.verify_ledger_invariants()
        assert ok, '%s: referee ledger invariants failed: %r' % (label, errs)

    # ---------------------------------------------------------- prep

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

    # ---------------------------------------------------------- steps

    def _record(self, call, inp, response, before_seq=None, agent=None):
        ledger = self._new_ledger()
        assert_zero_sum(ledger, '%s step %d' % (call, len(self.steps)))
        self._check_invariants('%s step %d' % (call, len(self.steps)))
        fills = []
        if before_seq is not None:
            fills = [t['payload'] for t in self.ref.get_ticks(before_seq) if t['kind'] == 'trade']
        touched = set(AGENTS)
        for r in ledger:
            if '/' not in r['agent_id']:
                touched.add(r['agent_id'])
        self.steps.append({
            'call': call,
            'input': inp,
            'response': response,
            'round': self.ref.current_round,
            'ledger': ledger,
            'fills': fills,
            'balances': self._balances(touched),
            'ship_accounts': self._ships(),
        })

    def order(self, order_id, agent, side, qty, price, vessel=None, instrument='FRAG', station=None):
        env = {'v': 1, 'kind': 'order', 'payload': {
            'order_id': order_id, 'agent_id': agent, 'side': side, 'qty': qty,
            'limit_price': price, 'instrument': instrument, 'station_id': station or self.station,
            'seq_seen': self.ref.current_seq}}
        if vessel is not None:
            env['payload']['vessel_id'] = vessel
        before = self.ref.current_seq
        inp = json.loads(json.dumps(env))
        resp = self.ref.submit_envelope(env)
        assert resp.get('status') != 'circuit_breaker_halted', resp
        self._record('submit_envelope', inp, resp, before_seq=before, agent=agent)

    def depart(self, agent, destination, commodity='FRAG', cargo_qty=0, escort=False, vessel=None):
        inp = {'agent_id': agent, 'destination': destination, 'commodity': commodity,
               'cargo_qty': cargo_qty, 'escort': escort, 'vessel_id': vessel}
        resp = self.ref.initiate_transit(agent, destination, commodity=commodity, cargo_qty=cargo_qty,
                                         escort=escort, vessel_id=vessel)
        self._record('initiate_transit', inp, resp)
        return resp

    def respond_piracy(self, agent, transit_id, choice):
        inp = {'agent_id': agent, 'transit_id': transit_id, 'choice': choice}
        resp = self.ref.piracy.respond(agent, transit_id, choice)
        self._record('piracy_respond', inp, resp)
        return resp

    def advance(self, rounds=1):
        for _ in range(rounds):
            resp = self.ref.step_round()
            self._record('step_round', {}, _scrub_round(resp))

    def fixture(self, case):
        return {
            'case': case,
            'description': self.description,
            'referee_commit': REFEREE_COMMIT,
            'station_id': self.station,
            'setup': {'seed': self.seed, 'warmup_rounds': 0, 'asymmetric': True,
                      'agents': list(AGENTS), 'ships_docked_at': self.station,
                      'referee_kwargs': self.setup, 'prep': self.prep},
            'prep_ledger': self.prep_ledger,
            'initial_accounts': self.initial_balances,
            'initial_ship_accounts': self.initial_ship_accounts,
            'rng_bags_start': self.bags_start,
            'steps': self.steps,
            'rng_bags_end': self._bags(),
        }


def _scrub_round(resp):
    """step_round's response is the referee's own; keep it whole."""
    return json.loads(json.dumps(resp, default=str))


# Mars FRAG reference price is 12.8, so the +-10% band is [11.52, 14.08]
# (agora/circuit_breaker.py). Every crossing price below sits inside it.

def case_simple_fill():
    s = Scenario('One crossing fill between two corps at mars: CR moves buyer to seller, FRAG moves seller to '
                 'buyer, on each corp default ship. Commodity trades carry no fee.', 'mars', 1)
    s.order('a1', 'amos', 'ask', 5, 13)
    s.order('m1', 'marvin', 'bid', 5, 13)
    return s


def case_non_default_ship_fill():
    s = Scenario('Corp amos owns two ships. Goods settle on the ship named in vessel_id (amos/2 sells, amos/1 '
                 'buys); CR settles on the corp. Ledger rows name the ship accounts.', 'mars', 1,
                 prep=[{'op': 'mint_cr', 'agent': 'amos', 'qty': 30000},
                       {'op': 'buy_ship', 'agent': 'amos'},
                       {'op': 'transfer', 'agent': 'amos', 'src': 'amos/1', 'dst': 'amos/2',
                        'instrument': 'FRAG', 'qty': 10}])
    s.order('a1', 'amos', 'ask', 6, 13, vessel='amos/2')
    s.order('m1', 'marvin', 'bid', 4, 13)
    s.order('z1', 'zero', 'ask', 3, 12)
    s.order('a2', 'amos', 'bid', 3, 12, vessel='amos/1')
    return s


def case_partial_fill_two_rounds():
    s = Scenario('A resting bid is filled in two pieces on either side of a round boundary. The first ask fills '
                 'part of it, step_round runs, the second ask fills the rest; each fill settles at the resting '
                 'bid price.', 'mars', 1)
    s.order('b1', 'marvin', 'bid', 10, 13)
    s.order('a1', 'amos', 'ask', 4, 13)
    s.advance(1)
    s.order('z1', 'zero', 'ask', 6, 12)
    return s


def case_equity_fee():
    s = Scenario('Stock trades at ceres carry an exchange fee (0.5% of cost, rounded, debited from the taker and '
                 'credited to ceres_exchange as its own txn). amos buys EQ_ZERO from the exchange market maker, '
                 'then sells part back.', 'ceres', 42,
                 setup={'depots': True, 'corporate': True, 'upgrades': True,
                        'rival_shares': 100, 'exchange_shares': 100})
    s.order('e1', 'amos', 'bid', 10, 31, instrument='EQ_ZERO')
    s.order('e2', 'amos', 'ask', 4, 28, instrument='EQ_ZERO')
    return s


def _fly_home(s, agent='amos'):
    """Step rounds until the agent's ship has landed."""
    while s.ref.get_vessel_location(agent).get('status') != 'docked':
        s.advance(1)


def case_escorted_departure_raid_paid():
    s = Scenario('An escorted cargo departure with piracy odds on. The escort fee is its own txn; the raid marble '
                 'comes out of the ship raid bag (rng_bags), the pirates demand a ransom, amos pays it (CR to '
                 'SYSTEM), and the cargo lands on amos/1 from SYSTEM escrow.', 'mars', 7,
                 setup={'piracy': '0.25,0.25'})
    r = s.depart('amos', 'earth', commodity='FRAG', cargo_qty=100, escort=True)
    assert r['payload']['piracy']['raided'], 'seed no longer draws a raid; pick another'
    s.respond_piracy('amos', r['payload']['transit_id'], 'pay')
    _fly_home(s)
    return s


def case_hazard_round_trip_bags():
    s = Scenario('Hazards at 0.5/0.5: a cargo departure draws a delay marble and a loss marble from the ship bags '
                 '(rng_bags), loses cargo from the escrowed manifest and then the hold (hazard-hold txn), lands, '
                 'and flies back: the second departure draws again, so the bag rows advance.', 'mars', 7,
                 setup={'hazards': '0.5,0.5'})
    s.depart('amos', 'earth', commodity='FRAG', cargo_qty=100)
    _fly_home(s)
    s.depart('amos', 'mars', commodity='FRAG', cargo_qty=50)
    _fly_home(s)
    return s


CASES = {
    'simple_fill': case_simple_fill,
    'non_default_ship_fill': case_non_default_ship_fill,
    'partial_fill_two_rounds': case_partial_fill_two_rounds,
    'equity_fee': case_equity_fee,
    'escorted_departure_raid_paid': case_escorted_departure_raid_paid,
    'hazard_round_trip_bags': case_hazard_round_trip_bags,
}


def generate(out_dir=DEFAULT_OUT):
    os.makedirs(out_dir, exist_ok=True)
    written = []
    for name, build in CASES.items():
        path = os.path.join(out_dir, name + '.json')
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            json.dump(build().fixture(name), f, indent=2)
            f.write('\n')
        written.append(path)
    return written


if __name__ == '__main__':
    for p in generate(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT):
        print(os.path.relpath(p, ROOT))
