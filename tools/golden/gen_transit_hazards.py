#!/usr/bin/env python3
"""Generate golden parity fixtures for Transit, Hazards, and Piracy (Issue #4, PR 5).

Drives Python referee modules (agora.spatial, agora.hazards, agora.piracy, agora.upgrades)
to extract ground-truth physics, odds tables, route windows, fuel burn, food decay,
and reference prices. Output is strictly deterministic.

Usage: python3 tools/golden/gen_transit_hazards.py [out_dir]
"""
import json
import math
import os
import sqlite3
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

import agora.spatial as S
import agora.hazards as H
import agora.piracy as P
import agora.upgrades as U
from agora.referee import AgoraReferee

REFEREE_COMMIT = '587b07f'
DEFAULT_OUT_DIR = os.path.join(ROOT, 'game', 'tests', 'golden', 'transit_hazards')
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

    # 1. Spatial Constants & Base Structures
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

    # Fuel burn cases: engine tiers 0..2 x refinery loop x corp discount x base & aligned fuels
    # Driven directly via AgoraReferee.upgrades.engine_fuel and corporate discount (agora/referee.py:1646-1650)
    ref_fuel = AgoraReferee()
    ref_fuel.new_game(seed=42)
    ref_fuel.upgrades_enabled = True

    def get_fuel(fuel: int, tier: int, refinery_loop: bool, corp_discount: float) -> int:
        agent = f"trader_{tier}_{int(refinery_loop)}"
        ref_fuel.conn.execute("INSERT OR REPLACE INTO fleet_upgrades (agent_id, kind, tier, round) VALUES (?, 'engines', ?, 1)", (agent, tier))
        if refinery_loop:
            ref_fuel.conn.execute("INSERT OR REPLACE INTO fleet_upgrades (agent_id, kind, tier, round) VALUES (?, 'refinery_loop', 1, 1)", (agent,))
        else:
            ref_fuel.conn.execute("DELETE FROM fleet_upgrades WHERE agent_id = ? AND kind = 'refinery_loop'", (agent,))
        req = ref_fuel.upgrades.engine_fuel(agent, fuel)
        if corp_discount > 0.0:
            req = max(1, int(float(req) * (1.0 - corp_discount)))
        return req

    fuel_cases = []
    routes_to_test = [
        ("earth", "luna", 0),  # base 5
        ("earth", "mars", 0),  # base 15
        ("earth", "mars", 4),  # aligned 10
        ("mars", "ceres", 0),  # base 20
        ("mars", "ceres", 5),  # aligned 12
        ("earth", "ceres", 0), # base 30
        ("earth", "ceres", 6), # aligned 18
    ]
    for orig, dest, r in routes_to_test:
        rt = S.get_route(orig, dest, r)
        base_fuel = rt["fuel"]
        for t in [0, 1, 2]:
            for r_loop in [False, True]:
                for corp in [0.0, 0.35, 0.40]:
                    exp_fuel = get_fuel(base_fuel, t, r_loop, corp)
                    fuel_cases.append({
                        "origin": orig,
                        "dest": dest,
                        "round": r,
                        "route_fuel": base_fuel,
                        "engine_tier": t,
                        "has_refinery_loop": r_loop,
                        "corp_fuel_discount": corp,
                        "expected_fuel": exp_fuel
                    })
    data["spatial"]["fuel_cases"] = fuel_cases

    # Food decay cases: arrival (floor) vs projected (half-even rounding) across 30, 50, 58, 70 FOOD
    decay_cases = []
    for orig, dest in [("earth", "ceres"), ("earth", "mars")]:
        is_belt = (f"{orig}:{dest}" in S.BELT_ROUTES) or ((orig, dest) in S.BELT_ROUTES)
        rate = S.BELT_CARGO_DECAY_RATE if is_belt else 0.0
        for q in [30, 50, 58, 70]:
            for el in [1, 2, 3, 5]:
                decay_cases.append({
                    "commodity": "FOOD",
                    "origin": orig,
                    "dest": dest,
                    "qty": q,
                    "elapsed_rounds": el,
                    "is_belt": is_belt,
                    "arrival_decay": min(q, math.floor(q * rate * el)) if is_belt else 0,
                    "projected_decay": min(q, int(round(q * rate * el))) if is_belt else 0
                })
    data["spatial"]["decay_cases"] = decay_cases

    # 2. Hazards
    conn = sqlite3.connect(':memory:')
    h_engine = H.HazardEngine(conn=conn, odds=(0.10, 0.05), seed=7)
    hazard_quotes = []
    for (df, lf, q) in [
        (1.0, 1.0, 1000),
        (0.5, 1.0, 500),
        (1.0, 0.5, 2000),
        (2.0, 1.5, 100),
        (0.1875, 1.0, 100),  # tie case: 0.10 * 0.1875 == 0.01875 -> tests hazards.gd py_round4 tie-breaker
        (15.0, 1.0, 100),    # clamp case: 0.10 * 15.0 == 1.5 -> clamp at 1.0
    ]:
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

    # Chance samples sweeping rounds 0, 1, 20, 60 to verify both hot:true and hot:false,
    # and quantities hitting all value steps (0.5, 0.75, 1.0, 1.25, 1.5, 2.0).
    chance_samples = []
    for r in [0, 1, 20, 60]:
        for orig, dest, tolled in [("ceres", "mars", True), ("earth", "mars", False), ("luna", "mars", False)]:
            for comm, q_list in [
                ("FRAG", [100, 500, 750, 850, 1000, 2000]),
                ("FOOD", [100, 400, 500, 750, 1000, 2000]),
                ("ORE",  [100, 400, 500, 750, 1000, 2000])
            ]:
                for qty in q_list:
                    for escort in [False, True]:
                        c = desk.chance("amos", orig, dest, tolled, comm, qty, escort, r)
                        chance_samples.append({
                            "agent": "amos",
                            "origin": orig,
                            "dest": dest,
                            "tolled": tolled,
                            "comm": comm,
                            "qty": qty,
                            "escort": escort,
                            "round": r,
                            "hot_station": desk.hot_station(r),
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
