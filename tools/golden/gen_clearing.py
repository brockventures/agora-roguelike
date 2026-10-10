#!/usr/bin/env python3
"""Generate the call-auction clearing-price golden fixture (Epic 3 task 6).

Runs the real agora.circuit_breaker.find_clearing_price over a fixed list of
order sets and records {price, volume} per case; game/core/sol_central.gd ports
that function and game/tests/test_sol_central.gd replays this file against the
port. A price of null is the Python's None (an empty side, or no volume).
Deterministic: no timestamps, no wall-clock ids.

Usage: python3 tools/golden/gen_clearing.py [out_dir]
Default out_dir: game/tests/golden/clearing
"""
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from agora.circuit_breaker import find_clearing_price  # noqa: E402
from agora.order_book import Order  # noqa: E402

DEFAULT_OUT = os.path.join(ROOT, 'game', 'tests', 'golden', 'clearing')
SOURCE = 'agora/circuit_breaker.py:find_clearing_price'

# Each order is (limit_price, qty, filled_qty); each case is
# (name, bids, asks, ref_price, why).
CASES = [
    ('empty_bids', [], [(10, 5, 0)], 10.0, 'no buyers: None'),
    ('empty_asks', [(10, 5, 0)], [], 10.0, 'no sellers: None'),
    ('both_empty', [], [], 10.0, 'empty book: None'),
    ('no_cross', [(9, 5, 0)], [(11, 5, 0)], 10.0, 'bid below ask: zero volume, None'),
    ('single_cross', [(12, 5, 0)], [(10, 5, 0)], 11.0, 'one bid, one ask, ties on 10..12 closest to the ref'),
    ('volume_maximising', [(14, 10, 0), (12, 10, 0), (10, 10, 0)], [(9, 8, 0), (11, 8, 0), (13, 8, 0)], 12.0, 'the price that matches the most'),
    ('tie_nearest_ref_low', [(20, 10, 0)], [(10, 10, 0)], 11.0, 'tie set 10..20, ref nearer the low end'),
    ('tie_nearest_ref_high', [(20, 10, 0)], [(10, 10, 0)], 19.0, 'tie set 10..20, ref nearer the high end'),
    ('tie_ref_midway_lower_wins', [(14, 10, 0)], [(10, 10, 0)], 12.0, 'ref exactly between 10 and 14: equidistant, the lower price wins'),
    ('tie_ref_outside', [(20, 10, 0)], [(10, 10, 0)], 50.0, 'ref above every candidate: the highest candidate'),
    ('fractional_ref', [(20, 10, 0)], [(10, 10, 0)], 14.5, 'a VWAP ref that is not a whole number'),
    ('partly_filled', [(15, 10, 6)], [(12, 10, 2)], 13.0, 'only the remaining quantity counts (4 vs 8)'),
    ('filled_order_ignored', [(15, 10, 10), (13, 3, 0)], [(12, 5, 0)], 13.0, 'a fully filled bid adds no volume'),
    ('zero_remaining_only', [(15, 10, 10)], [(12, 10, 0)], 13.0, 'every bid filled: zero volume, None'),
    ('many_levels', [(25, 7, 0), (24, 9, 0), (23, 11, 0), (22, 13, 0), (21, 15, 0)], [(19, 6, 0), (20, 8, 0), (21, 10, 0), (22, 12, 0), (23, 14, 0)], 21.0, 'five levels a side'),
    ('duplicate_prices', [(15, 4, 0), (15, 6, 0), (12, 5, 0)], [(11, 3, 0), (11, 4, 0), (14, 9, 0)], 13.0, 'several orders at one limit'),
]


def build(rows, side, tag):
    return [Order('%s-%d' % (tag, i), 'golden', 'FRAG', side, qty, price, i, submitted_at=0.0, filled_qty=filled)
            for i, (price, qty, filled) in enumerate(rows)]


def main(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    cases = []
    for name, bids, asks, ref, why in CASES:
        price, volume = find_clearing_price(build(bids, 'bid', 'b'), build(asks, 'ask', 'a'), ref)
        cases.append({
            'name': name, 'why': why, 'ref_price': ref,
            'bids': [{'limit_price': p, 'qty': q, 'filled_qty': f} for p, q, f in bids],
            'asks': [{'limit_price': p, 'qty': q, 'filled_qty': f} for p, q, f in asks],
            'expected': {'price': price, 'volume': volume},
        })
    doc = {'case': 'clearing_price', 'source': SOURCE, 'cases': cases}
    path = os.path.join(out_dir, 'clearing_price.json')
    with open(path, 'w') as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write('\n')
    print('wrote', path, len(cases), 'cases')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT)
