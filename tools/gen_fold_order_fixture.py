#!/usr/bin/env python3
"""Regenerate game/tests/fixtures/world/fold_order.json (Epic 3 task 2, part of #15).

The golden fold-order fixture for StationMarket._mods_for: world_mods fold first,
then crisis_mods, depth and spread multiply with integer division one mod at a
time, so the order is part of the replay contract. The expected values are
computed here in Python, independently of the GDScript, and test_market_wiring.gd
checks the Godot market against them (and against the swapped order, to prove
the fixture distinguishes the two).

Not under game/tests/golden/ on purpose: that tree is the Python referee's
parity fixtures and tools/golden/check_drift.py owns it. Nothing here comes from
the referee.

Usage: python3 tools/gen_fold_order_fixture.py [out_file]
"""
import json
import math
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
DEFAULT_OUT = os.path.join(ROOT, 'game', 'tests', 'fixtures', 'world', 'fold_order.json')

WORLD = [
    {"station": "mars", "commodity": "ORE", "depth_bps": 7919, "spread_bps": 12500, "price_bps": 300, "ask_price_bps": 800},
    {"station": "mars", "commodity": "*", "depth_bps": 3571, "spread_bps": 8000},
    {"station": "earth", "commodity": "FRAG", "depth_bps": 9999, "price_bps": -250},
]
CRISIS = [
    {"station": "mars", "commodity": "ORE", "depth_bps": 6667, "spread_bps": 15000, "price_bps": -100},
    {"station": "*", "commodity": "*", "depth_bps": 9101, "spread_bps": 9101},
]
BASE = {"earth": {"FRAG": 20.2}, "mars": {"ORE": 16.5, "FUEL": 16.5, "FRAG": 12.8}}
BOOKS = [("mars", "ORE"), ("mars", "FUEL"), ("earth", "FRAG"), ("mars", "FRAG")]


def rnd(x):
    """GDScript round(): half away from zero (all values here are positive)."""
    return int(math.floor(x + 0.5))


def match(m, st, c):
    return m.get("station", "*") in ("*", st) and m.get("commodity", "*") in ("*", c)


def fold(groups, st, c):
    d = s = 10000
    p = a = 0
    for g in groups:
        for m in g:
            if match(m, st, c):
                d = d * m.get("depth_bps", 10000) // 10000
                s = s * m.get("spread_bps", 10000) // 10000
                p += m.get("price_bps", 0)
                a += m.get("ask_price_bps", 0)
    return {"depth_bps": d, "spread_bps": s, "price_bps": p, "ask_price_bps": a}


def ladder(groups, st, c):
    """The five-level seeded book, [price, remaining qty] per level (station_market.gd seed_book)."""
    fx = fold(groups, st, c)
    base = BASE[st][c]
    if fx["price_bps"] != 0:
        base *= (10000 + fx["price_bps"]) / 10000.0
    half = max(1, rnd(base * 0.02))
    if fx["spread_bps"] != 10000:
        half = max(1, rnd(half * fx["spread_bps"] / 10000.0))
    mid = max(2, rnd(base))
    best_bid = max(1, mid - half)
    best_ask = best_bid + 2 * half
    asks, bids = [], []
    for i in range(5):
        bids.append([max(1, best_bid - i * half), max(1, (15 + (i + 1) * 8) * fx["depth_bps"] // 10000)])
        px = best_ask + i * half
        if fx["ask_price_bps"] != 0:
            px = max(1, rnd(px * (10000 + fx["ask_price_bps"]) / 10000.0))
        asks.append([px, max(1, (12 + (i + 1) * 7) * fx["depth_bps"] // 10000)])
    return {"asks": asks, "bids": bids}


def build():
    cases = []
    for st, c in BOOKS:
        cases.append({
            "station": st, "commodity": c,
            "world_then_crisis": fold([WORLD, CRISIS], st, c),
            "crisis_then_world": fold([CRISIS, WORLD], st, c),
            "ladder_world_then_crisis": ladder([WORLD, CRISIS], st, c),
        })
    return {
        "case": "fold_order",
        "description": "StationMarket._mods_for folds world_mods first, then crisis_mods; depth and spread "
                       "multiply with integer division one mod at a time, so swapping the groups changes the "
                       "result. 'ladder_world_then_crisis' is the seeded five-level book ([price, remaining qty] "
                       "per level) for that fold. Computed by tools/gen_fold_order_fixture.py, independently of "
                       "the GDScript; checked by game/tests/test_market_wiring.gd.",
        "world_mods": WORLD,
        "crisis_mods": CRISIS,
        "cases": cases,
    }


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(build(), f, indent=1)
        f.write("\n")
