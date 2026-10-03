#!/usr/bin/env python3
"""Generate golden parity fixtures for Transit, Hazards, and Piracy (Issue #4, PR 5).

Drives Python referee modules (agora.spatial, agora.hazards, agora.piracy) to extract
ground-truth physics, odds tables, route windows, and reference prices.
Output is strictly deterministic.

Usage: python3 tools/golden/gen_transit_hazards.py [out_dir]
"""
import json
import os
import sys
import sqlite3

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

import agora.spatial as S
import agora.hazards as H
import agora.piracy as P
from agora.referee import AgoraReferee

REFEREE_COMMIT = '587b07f'
DEFAULT_OUT_DIR = os.path.join(ROOT, 'game', 'tests', 'golden', 'transit_hazards')
os.makedirs(DEFAULT_OUT_DIR, exist_ok=True)
OUT_FILE = os.path.join(DEFAULT_OUT_DIR, 'transit_hazards_golden.json')


def generate(out_dir=None):
    target_file = os.path.join(out_dir, 'transit_hazards_golden.json') if out_dir else OUT_FILE
    os.makedirs(os.path.dirname(target_file), exist_ok=True)

    data = {
        "referee_commit": REFEREE_COMMIT,
        "spatial": {},
        "hazards": {},
        "piracy": {}
    }

    # 1. Spatial
    data["spatial"]["stations"] = list(S.STATIONS)
    data["spatial"]["commodities"] = list(S.COMMODITIES)
    data["spatial"]["commodity_aliases"] = dict(S.COMMODITY_ALIASES)
    data["spatial"]["perishables"] = sorted(list(S.PERISHABLE_COMMODITIES))
    data["spatial"]["belt_routes"] = sorted([f"{o}:{d}" if isinstance(r, tuple) else r for r in S.BELT_ROUTES for o, d in [r if isinstance(r, tuple) else r.split(':')]])
    data["spatial"]["belt_toll_cr"] = S.BELT_TOLL_CR
    data["spatial"]["belt_decay_rate"] = S.BELT_CARGO_DECAY_RATE
    data["spatial"]["base_prices"] = S.BASE_PRICES

    # Base routes formatted with "origin:dest" string keys
    base_routes = {}
    for k, v in S.ROUTES.items():
        key_str = f"{k[0]}:{k[1]}" if isinstance(k, tuple) else str(k)
        base_routes[key_str] = dict(v)
    data["spatial"]["base_routes"] = base_routes

    # Route and alignment window cases across rounds 0..10
    route_cases = []
    for origin in S.STATIONS:
        for dest in S.STATIONS:
            if origin == dest:
                continue
            for r in [0, 4, 5, 6, 7, 8, 10]:
                rt = S.get_route(origin, dest, r)
                win = S.get_active_window_for_route(origin, dest, r)
                route_cases.append({
                    "origin": origin,
                    "dest": dest,
                    "round": r,
                    "route": rt,
                    "active_window": win
                })
    data["spatial"]["route_cases"] = route_cases

    # 2. Hazards
    conn = sqlite3.connect(':memory:')
    h_engine = H.HazardEngine(conn=conn, odds=(0.10, 0.05), seed=7)
    hazard_quotes = []
    for (df, lf, q) in [(1.0, 1.0, 1000), (0.5, 1.0, 500), (1.0, 0.5, 2000), (2.0, 1.5, 100)]:
        quote = h_engine.quote(delay_factor=df, loss_factor=lf, total_qty=q)
        hazard_quotes.append({
            "delay_factor": df,
            "loss_factor": lf,
            "total_qty": q,
            "quote": quote
        })
    data["hazards"]["quotes"] = hazard_quotes
    data["hazards"]["cme_stations"] = sorted(list(H.CME_STATIONS))
    data["hazards"]["default_p_delay"] = H.DEFAULT_P_DELAY
    data["hazards"]["default_p_loss"] = H.DEFAULT_P_LOSS

    # 3. Piracy
    ref = AgoraReferee(piracy=(0.15, 0.04))
    ref.new_game(seed=42)
    desk = ref.piracy

    data["piracy"]["ref_prices"] = P.REF_PRICE
    data["piracy"]["default_p_belt"] = P.DEFAULT_P_BELT
    data["piracy"]["default_p_inner"] = P.DEFAULT_P_INNER
    data["piracy"]["ransom_pct"] = P.RANSOM_PCT
    data["piracy"]["surrender_pct"] = P.SURRENDER_PCT
    data["piracy"]["fight_escape"] = P.FIGHT_ESCAPE
    data["piracy"]["fight_loss"] = P.FIGHT_LOSS
    data["piracy"]["priv_cost"] = P.PRIV_COST
    data["piracy"]["priv_add"] = P.PRIV_ADD
    data["piracy"]["priv_fine"] = P.PRIV_FINE

    # Bag odds samples
    bag_odds_samples = []
    for p in [0.04, 0.08, 0.1125, 0.15, 0.225, 0.30, 0.45, 0.60, 0.0]:
        bag_odds_samples.append({
            "p": p,
            "bag_odds": desk.bag_odds(p)
        })
    data["piracy"]["bag_odds_samples"] = bag_odds_samples

    # Chance samples
    chance_samples = []
    for tolled in [True, False]:
        for comm in ["FRAG", "FOOD", "ORE"]:
            for qty in [100, 1000, 2000]:
                for escort in [False, True]:
                    c = desk.chance('amos', 'ceres' if tolled else 'earth', 'mars', tolled, comm, qty, escort, 1)
                    chance_samples.append({
                        "agent": "amos",
                        "origin": "ceres" if tolled else "earth",
                        "dest": "mars",
                        "tolled": tolled,
                        "comm": comm,
                        "qty": qty,
                        "escort": escort,
                        "hot_station": desk.hot_station(1),
                        "chance": c
                    })
    data["piracy"]["chance_samples"] = chance_samples

    with open(target_file, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)
    print(f"Generated {target_file} successfully.")
    return target_file


if __name__ == '__main__':
    out_dir = sys.argv[1] if len(sys.argv) > 1 else None
    generate(out_dir)
