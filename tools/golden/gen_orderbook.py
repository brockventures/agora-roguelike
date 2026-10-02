#!/usr/bin/env python3
"""Generate order-book golden fixtures for station Mars (#5, checklist 5a).

Drives a fresh AgoraReferee through scripted order streams using its real
public entry points (submit_envelope, cancel_order, get_book_snapshot,
get_accounts, get_ticks). Nothing in the matching path is mocked. The output is
deterministic: no timestamps, no wall-clock ids.

Usage: python3 tools/golden/gen_orderbook.py [out_dir]
Default out_dir: game/tests/golden/orderbook
"""
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from agora.referee import AgoraReferee  # noqa: E402

REFEREE_COMMIT = '587b07f'
STATION = 'mars'
INSTRUMENT = 'FRAG'
AGENTS = ('amos', 'zero', 'marvin', 'aerial')
SETUP = {'asymmetric': True, 'seed': 1, 'warmup_rounds': 0,
         'ships_docked_at': STATION, 'agents': list(AGENTS)}
DEFAULT_OUT = os.path.join(ROOT, 'game', 'tests', 'golden', 'orderbook')


def fresh_referee():
    ref = AgoraReferee(asymmetric=True)
    ref.new_game(seed=SETUP['seed'], warmup_rounds=SETUP['warmup_rounds'])
    ref.set_asymmetric_roster({a: STATION for a in AGENTS})
    return ref


def balances(ref, agents):
    """get_accounts rows (CR and the traded good) for the given agents."""
    rows = []
    for a in sorted(agents):
        rows.extend(r for r in ref.get_accounts(a) if r['instrument'] in ('CR', INSTRUMENT))
    return rows


class Stream:
    def __init__(self, description):
        self.ref = fresh_referee()
        self.description = description
        self.initial = balances(self.ref, AGENTS)
        self.steps = []

    def _record(self, call, inp, response, before_seq, agents):
        fills = [t['payload'] for t in self.ref.get_ticks(before_seq) if t['kind'] == 'trade']
        touched = set(agents)
        for f in fills:
            touched.update((f['buyer_id'], f['seller_id']))
        assert response.get('status') != 'circuit_breaker_halted' and response.get('floor', 'open') == 'open', \
            'scripted stream tripped the circuit breaker: %r' % (response,)
        self.steps.append({
            'call': call,
            'input': inp,
            'response': response,
            'fills': fills,
            'book': self.ref.get_book_snapshot(STATION, INSTRUMENT),
            'balances': balances(self.ref, touched),
        })

    def order(self, order_id, agent, side, qty, price):
        env = {'v': 1, 'kind': 'order', 'payload': {
            'order_id': order_id, 'agent_id': agent, 'side': side, 'qty': qty,
            'limit_price': price, 'instrument': INSTRUMENT, 'station_id': STATION,
            'seq_seen': self.ref.current_seq}}
        before = self.ref.current_seq
        inp = json.loads(json.dumps(env))  # copy: the referee may mutate the payload
        resp = self.ref.submit_envelope(env)
        self._record('submit_envelope', inp, resp, before, [agent])

    def cancel(self, agent, order_id):
        before = self.ref.current_seq
        resp = self.ref.cancel_order(agent, order_id)
        self._record('cancel_order', {'agent_id': agent, 'order_id': order_id}, resp, before, [agent])

    def fixture(self, case):
        return {
            'case': case,
            'description': self.description,
            'referee_commit': REFEREE_COMMIT,
            'station_id': STATION,
            'instrument': INSTRUMENT,
            'setup': SETUP,
            'initial_accounts': self.initial,
            'steps': self.steps,
        }


# Mars FRAG reference price is 12.8, so the +-10% band is [11.52, 14.08]
# (agora/circuit_breaker.py). Every crossing price below sits inside it.

def case_rest_no_cross():
    s = Stream('Resting bids and asks that do not cross; the book sorts by price then arrival.')
    s.order('b1', 'marvin', 'bid', 10, 12)
    s.order('b2', 'zero', 'bid', 5, 13)
    s.order('b3', 'aerial', 'bid', 5, 13)
    s.order('a1', 'amos', 'ask', 8, 14)
    s.order('a2', 'zero', 'ask', 4, 15)
    return s


def case_price_time_priority():
    s = Stream('Two asks rest at the same price; a crossing bid fills the older first, at the resting price.')
    s.order('a1', 'amos', 'ask', 5, 13)
    s.order('z1', 'zero', 'ask', 5, 13)
    s.order('m1', 'marvin', 'bid', 7, 14)
    return s


def case_partial_fill_remainder():
    s = Stream('A partial fill leaves the remainder of the incoming order resting, then the reverse on the ask side.')
    s.order('a1', 'amos', 'ask', 4, 13)
    s.order('m1', 'marvin', 'bid', 10, 14)
    s.order('z1', 'zero', 'ask', 10, 14)
    return s


def case_cancel_resting():
    s = Stream('Cancel a resting order, then cancel it again and cancel an unknown order.')
    s.order('b1', 'marvin', 'bid', 5, 12)
    s.order('a1', 'amos', 'ask', 5, 14)
    s.cancel('marvin', 'b1')
    s.cancel('marvin', 'b1')
    s.cancel('amos', 'nope')
    return s


def case_self_cross():
    s = Stream('An agent bids into its own resting ask. Records what the referee does (no self-trade prevention).')
    s.order('a1', 'amos', 'ask', 5, 13)
    s.order('a2', 'amos', 'bid', 5, 13)
    return s


def case_sweep_multi_level():
    s = Stream('One bid sweeps three ask levels, each fill at its resting price, and the remainder rests.')
    s.order('a1', 'amos', 'ask', 3, 12)
    s.order('z1', 'zero', 'ask', 4, 13)
    s.order('r1', 'aerial', 'ask', 5, 14)
    s.order('m1', 'marvin', 'bid', 10, 14)
    return s


CASES = {
    'rest_no_cross': case_rest_no_cross,
    'price_time_priority': case_price_time_priority,
    'partial_fill_remainder': case_partial_fill_remainder,
    'cancel_resting': case_cancel_resting,
    'self_cross': case_self_cross,
    'sweep_multi_level': case_sweep_multi_level,
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
