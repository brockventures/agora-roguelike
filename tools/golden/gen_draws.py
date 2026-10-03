#!/usr/bin/env python3
"""Generate draw-level golden fixtures for bag, hazards, piracy and spatial (#5, checklist 5d).

5c records whole settlement paths. This generator calls the random-consuming functions of
agora/bag.py, agora/hazards.py, agora/piracy.py and agora/spatial.py directly, one fixture per
case, and records for every call: the input, the exact ordered draw log, the output, and the
marble-bag state after it (plus the state at the start and the end of the case).

Draws are recorded by the 5b recorder (tools/golden/record_draws.py). Every Random the modules
build (the bag refill streams, the hazard and piracy desk RNGs, the hot-station Random, the
price-walk RNG) is swapped for a RecordingRandom with the same seed string, so the stream is
unchanged (CPython string seeds are deterministic) and every draw lands, in call order, in one
sink. The sink is drained after each call into that step's `draws`.

Cases that need a ship in flight (raid resolution) get their transit from the referee's
initiate_transit with both desks switched off, so no draw is made or recorded while a case is
being set up. The function under test is then called directly.

Fixture shape (every file):
  case, module, description, referee_commit, setup, bag_start,
  steps[{call, input, draws, output, bag_after}], bag_end

Where the Python module has a documented edge (p <= 0 or p >= 1 never touches the bag, a zero
cargo roll makes no raid draw, a disabled desk draws nothing) the step's `draws` is [] and the
bag state does not change.

initiate_transit builds its transit id from time.time_ns(), so each id is rewritten to
tx-<agent>-<n> (n counts the case's transits from 1) everywhere it appears.

Usage: python3 tools/golden/gen_draws.py [out_dir]
Default out_dir: game/tests/golden/draws
"""
import json
import os
import sqlite3
import sys
import types

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
for p in (ROOT, os.path.dirname(os.path.abspath(__file__))):
    if p not in sys.path:
        sys.path.insert(0, p)

import agora.hazards as hazards_mod  # noqa: E402
import agora.piracy as piracy_mod  # noqa: E402
import agora.spatial as spatial_mod  # noqa: E402
from agora.bag import Bags, SEED_EVENT  # noqa: E402
from agora.hazards import HazardEngine  # noqa: E402
from agora.referee import AgoraReferee  # noqa: E402
from agora.spatial import StationPriceEngine  # noqa: E402
from record_draws import RecordingRandom  # noqa: E402

REFEREE_COMMIT = '587b07f'
DEFAULT_OUT = os.path.join(ROOT, 'game', 'tests', 'golden', 'draws')
BAG_COLUMNS = ['ns', 'event', 'fleet', 'seed', 'p', 'marbles', 'refills', 'credit', 'draws', 'hits']

# Every recorded draw of the call in progress, in call order.
SINK = []


def _recording_random(seed):
    rec = RecordingRandom(seed)
    rec.draws = SINK
    return rec


_RANDOM_SHIM = types.SimpleNamespace(Random=_recording_random)


def _patched_bag_rng(self, event, fleet, seed, n):
    return _recording_random('bag-%s-%s-%s-%s-%s' % (self.ns, seed, event, fleet, n))


class Case:
    """One fixture: a module under test, its steps, and the bag state around them."""

    def __init__(self, name, module, description, setup, conn=None):
        self.name, self.module, self.description, self.setup = name, module, description, setup
        self.conn = conn
        self.steps = []
        self.transit_ids = []
        self.bag_start = self.bag_state()
        del SINK[:]

    def bag_state(self):
        if self.conn is None:
            return []
        rows = self.conn.execute(
            'SELECT %s FROM rng_bags WHERE event != ? ORDER BY ns, event, fleet' % ', '.join(BAG_COLUMNS),
            (SEED_EVENT,)).fetchall()
        return [dict(zip(BAG_COLUMNS, tuple(r))) for r in rows]

    def step(self, call, inp, fn):
        """Run fn() with an empty sink; record its output and every draw it made."""
        del SINK[:]
        output = fn()
        draws = list(SINK)
        del SINK[:]
        self.steps.append({'call': call, 'input': inp, 'draws': draws, 'output': output,
                           'bag_after': self.bag_state()})
        return output

    def fixture(self):
        data = {
            'case': self.name,
            'module': self.module,
            'description': self.description,
            'referee_commit': REFEREE_COMMIT,
            'setup': self.setup,
            'bag_start': self.bag_start,
            'steps': self.steps,
            'bag_end': self.bag_state(),
        }
        text = json.dumps(data, indent=2)
        counts = {}
        for tid, agent in self.transit_ids:
            counts[agent] = counts.get(agent, 0) + 1
            text = text.replace(tid, 'tx-%s-%d' % (agent, counts[agent]))
        return json.loads(text)


# ------------------------------------------------------------------ bag (agora/bag.py)

def bag_case(name, description, seed, ns='golden'):
    conn = sqlite3.connect(':memory:')
    bags = Bags(conn, ns)
    bags.reset(seed)
    case = Case(name, 'bag', description, {'ns': ns, 'seed': seed}, conn=conn)
    case.bags = bags
    return case


def bag_draw(case, event, fleet, p, varying=False):
    call = 'draw_varying' if varying else 'draw'
    fn = case.bags.draw_varying if varying else case.bags.draw
    case.step(call, {'event': event, 'fleet': fleet, 'p': p},
              lambda: {'result': fn(event, fleet, p)})


def case_bag_one_in_four_refills():
    c = bag_case('bag_one_in_four_refills',
                 'p = 0.25 is 1 hit in a bag of 4. Nine draws cross two refills: each refill is one shuffle of '
                 'the run sizes and one randrange for the hit position, and every full bag of 4 holds exactly '
                 'one hit (bad-luck protection).', seed=7)
    for _ in range(9):
        bag_draw(c, 'raid', 'amos/1', 0.25)
    return c


def case_bag_three_in_ten_runs():
    c = bag_case('bag_three_in_ten_runs',
                 'p = 0.3 is 3 hits in 10 marbles, laid out as 3 runs of sizes 4, 3, 3 (shuffled) with one hit '
                 'per run. Eleven draws drain the first bag (3 hits in 10) and refill on the eleventh.', seed=3)
    for _ in range(11):
        bag_draw(c, 'delay', 'zero/1', 0.3)
    return c


def case_bag_p_change_rebuilds_bag():
    c = bag_case('bag_p_change_rebuilds_bag',
                 'The same (event, fleet) is drawn at p = 0.25, then 0.5, then 0.25 again. A change of p drops '
                 'the rest of the old bag and rebuilds for the new odds at once (a fresh refill number each '
                 'time).', seed=11)
    for p in (0.25, 0.25, 0.5, 0.5, 0.5, 0.25):
        bag_draw(c, 'loss', 'marvin/1', p)
    return c


def case_bag_fleets_are_isolated():
    c = bag_case('bag_fleets_are_isolated',
                 'Two fleets and two events drawn in an interleaved order at p = 0.2 (1 in 5). Each (event, '
                 'fleet) has its own bag and its own refill stream, so an interleaving never moves another '
                 'key luck.', seed=5)
    for event, fleet in (('delay', 'amos/1'), ('delay', 'zero/1'), ('loss', 'amos/1'), ('delay', 'amos/1'),
                         ('delay', 'zero/1'), ('loss', 'amos/1'), ('delay', 'amos/1'), ('loss', 'zero/1')):
        bag_draw(c, event, fleet, 0.2)
    return c


def case_bag_varying_credit():
    c = bag_case('bag_varying_credit',
                 'draw_varying with a p that changes every call. Each call draws one random() for the '
                 'threshold t = 1 - random(); the credit grows by p and a hit takes 1 off. The threshold stream '
                 'only advances (new cycle) on a hit, so misses repeat the same draw.', seed=2)
    for p in (0.1, 0.3, 0.05, 0.4, 0.25, 0.5, 0.2, 0.35, 0.15, 0.45, 0.3, 0.1):
        bag_draw(c, 'raid', 'amos/1', p, varying=True)
    return c


def case_bag_non_bag_odds_use_credit():
    c = bag_case('bag_non_bag_odds_use_credit',
                 'A p that is not k/n for any n <= 200 (1/3 + 1e-6) is not rounded into a bag: draw() hands it '
                 'to the credit accumulator. No bag is built (marbles stay empty, no shuffle, no randrange), '
                 'each call draws one random().', seed=4)
    for _ in range(8):
        bag_draw(c, 'raid', 'amos/1', 1.0 / 3 + 1e-6)
    return c


def case_bag_edge_odds_no_draw():
    c = bag_case('bag_edge_odds_no_draw',
                 'p <= 0 never hits and p >= 1 always hits, for draw and for draw_varying, and none of them '
                 'makes a draw or touches bag state. A real draw at the end proves the bag still starts '
                 'fresh.', seed=9)
    for p in (0.0, -0.5, 1.0, 1.5):
        bag_draw(c, 'raid', 'amos/1', p)
    for p in (0.0, -0.25, 1.0, 2.0):
        bag_draw(c, 'raid', 'amos/1', p, varying=True)
    bag_draw(c, 'raid', 'amos/1', 0.5)
    return c


# ------------------------------------------------------------------ hazards (agora/hazards.py)

def hazard_case(name, description, seed, odds):
    conn = sqlite3.connect(':memory:')
    eng = HazardEngine(conn, odds=odds, seed=seed)
    eng.reset(seed)
    case = Case(name, 'hazards', description,
                {'seed': seed, 'odds': list(odds) if odds else None}, conn=conn)
    case.engine = eng
    return case


def hazard_roll(case, cargo_qty, agent_id='amos/1', delay_factor=1.0, loss_factor=1.0, loss_size_factor=1.0,
                total_qty=None):
    inp = {'cargo_qty': cargo_qty, 'delay_factor': delay_factor, 'loss_factor': loss_factor,
           'loss_size_factor': loss_size_factor, 'agent_id': agent_id, 'total_qty': total_qty}

    def run():
        delay, lost, note = case.engine.roll(cargo_qty, delay_factor=delay_factor, loss_factor=loss_factor,
                                             loss_size_factor=loss_size_factor, agent_id=agent_id,
                                             total_qty=total_qty)
        return {'delay': delay, 'lost': lost, 'note': note}
    case.step('roll', inp, run)


def case_hazard_roll_both_types():
    c = hazard_case('hazard_roll_both_types',
                    'Delay and loss at 0.5 / 0.5 for one ship over ten trips. Every roll draws randint(1, 3) '
                    'and uniform(0.10, 0.20) from the desk RNG first, then a delay marble, then (cargo > 0) a '
                    'loss marble. The sequence contains hits and misses of both kinds; a loss is '
                    'int(qty * fraction), a delay is the randint.', seed=1, odds=(0.5, 0.5))
    for _ in range(10):
        hazard_roll(c, 200)
    return c


def case_hazard_roll_delay_only():
    c = hazard_case('hazard_roll_delay_only',
                    'p_loss = 0: the delay roll is a real marble (0.4 = 2 in 5) but the loss roll never touches '
                    'a bag. The two desk draws are still made every trip.', seed=6, odds=(0.4, 0.0))
    for _ in range(6):
        hazard_roll(c, 120)
    return c


def case_hazard_roll_loss_only():
    c = hazard_case('hazard_roll_loss_only',
                    'p_delay = 0: only the loss roll draws a marble (0.5). The desk still draws randint and '
                    'uniform every trip so one outcome never shifts the next trip.', seed=8, odds=(0.0, 0.5))
    for _ in range(6):
        hazard_roll(c, 120)
    return c


def case_hazard_roll_upgrade_factors():
    c = hazard_case('hazard_roll_upgrade_factors',
                    'Upgrade factors scale the odds and the loss size: delay_factor 0.5 and loss_factor 0.4 '
                    'turn 0.5 / 0.5 into 0.25 / 0.2, loss_size_factor 0.8 shrinks the loss, and total_qty '
                    '(the whole hold) replaces cargo_qty as the quantity at risk.', seed=12, odds=(0.5, 0.5))
    for _ in range(5):
        hazard_roll(c, 100, delay_factor=0.5, loss_factor=0.4, loss_size_factor=0.8, total_qty=300)
    return c


def case_hazard_roll_zero_cargo():
    c = hazard_case('hazard_roll_zero_cargo',
                    'A trip with nothing to lose: cargo 0 and no total_qty. The loss marble is not drawn '
                    '(nothing to lose) but the delay marble and both desk draws are. A trip with cargo then '
                    'follows, to show the loss bag was left untouched.', seed=13, odds=(0.5, 0.5))
    for _ in range(3):
        hazard_roll(c, 0)
    hazard_roll(c, 150)
    return c


def case_hazard_roll_certain_odds():
    c = hazard_case('hazard_roll_certain_odds',
                    'Odds of 1.0 / 1.0: both rolls always hit and neither touches a bag (p >= 1), so the bag '
                    'state stays empty; the desk still draws randint and uniform on every trip.',
                    seed=14, odds=(1.0, 1.0))
    for _ in range(3):
        hazard_roll(c, 100)
    return c


def case_hazard_roll_ships_isolated():
    c = hazard_case('hazard_roll_ships_isolated',
                    'Two ships rolling alternately at 0.5 / 0.5. Each ship has its own delay and loss bag '
                    '(keyed by agent_id), while the desk RNG is shared and advances on every roll.',
                    seed=15, odds=(0.5, 0.5))
    for agent in ('amos/1', 'zero/1', 'amos/1', 'zero/1', 'amos/1', 'zero/1'):
        hazard_roll(c, 100, agent_id=agent)
    return c


def case_hazard_roll_disabled():
    c = hazard_case('hazard_roll_disabled',
                    'A game without hazards (odds None): roll returns (0, 0, "") and draws nothing, not even '
                    'the two desk values.', seed=16, odds=None)
    for _ in range(3):
        hazard_roll(c, 200)
    return c


# ------------------------------------------------------------------ piracy (agora/piracy.py)

class PiracyCase(Case):
    """A referee with the piracy desk under test. Transits are set up with both desks off."""

    def __init__(self, name, description, seed, odds=(0.5, 0.5), agents=('amos',)):
        self.ref = AgoraReferee(hazards=(0.5, 0.5), piracy=odds, depots=True)
        self.ref.new_game(seed=seed, warmup_rounds=2, depots=True, hazards=(0.5, 0.5), piracy=odds)
        self.ref.hazards.odds = None  # these cases are about the piracy desk only
        self.desk_odds = self.ref.piracy.odds
        self.preps = []
        setup = {'seed': seed, 'warmup_rounds': 2, 'depots': True, 'piracy': list(odds) if odds else None,
                 'agents': list(agents), 'prep': self.preps}
        super().__init__(name, 'piracy', description, setup, conn=self.ref.conn)

    def depart(self, agent, dest, commodity, qty, escort=False):
        """Put a ship in flight with no rolls (piracy and hazards off). Returns the roll_departure arguments."""
        ref = self.ref
        ref.piracy.odds = None
        try:
            resp = ref.initiate_transit(agent, dest, commodity, qty, escort=escort)
        finally:
            ref.piracy.odds = self.desk_odds
        assert resp['kind'] != 'reject', resp
        pl = resp['payload']
        self.transit_ids.append((pl['transit_id'], agent))
        self.preps.append({'op': 'initiate_transit', 'agent': agent, 'dest': dest, 'commodity': commodity,
                           'qty': qty, 'escort': escort})
        fee = ref.piracy.escort_fee(commodity, qty) if escort else 0
        return {'transit_id': pl['transit_id'], 'agent': agent, 'origin': pl['origin'], 'dest': pl['destination'],
                'tolled': pl['toll_paid'] > 0, 'commodity': commodity, 'qty': qty, 'escort': escort,
                'escort_fee': fee, 'round': pl['departure_round'], 'vessel_id': pl['vessel_id'],
                'hold_value': pl['total_cargo_value'], 'total_qty': sum(pl['hold_cargo'].values())}

    def raw_raid(self, transit_id):
        row = self.ref.piracy._row(transit_id)
        if row is None:
            return None
        keys = ('transit_id', 'agent_id', 'status', 'ransom', 'surrender_qty', 'cargo_qty', 'cargo_value',
                'odds', 'escorted', 'contract_id', 'sponsor', 'traced', 'fine', 'choice', 'cr_taken',
                'qty_taken', 'delay', 'fenced_at')
        return {k: row[k] for k in keys}

    def roll(self, args):
        inp = dict(args)

        def run():
            ref = self.ref
            with ref.lock, ref.conn:
                out = ref.piracy.roll_departure_locked(
                    args['transit_id'], args['agent'], args['origin'], args['dest'], args['tolled'],
                    args['commodity'], args['qty'], args['escort'], args['escort_fee'], args['round'],
                    vessel_id=args['vessel_id'], hold_value=args['hold_value'], total_qty=args['total_qty'])
            if out is None:
                return {'result': None}
            demand = self.raw_raid(args['transit_id']) if out['raided'] else None
            return {'result': {k: out[k] for k in ('odds', 'hot_station', 'hot_route', 'cargo_value', 'escort',
                                                   'escort_fee', 'raided')},
                    'demand': demand}
        self.step('roll_departure', inp, run)

    def respond(self, agent, transit_id, choice):
        ref = self.ref
        inp = {'agent_id': agent, 'transit_id': transit_id, 'choice': choice,
               'available_cr': ref.peer._available(agent, 'CR')}

        def run():
            resp = ref.piracy.respond(agent, transit_id, choice)
            if resp['kind'] == 'reject':
                return {'kind': 'reject', 'reason': resp['payload']['reason']}
            row = self.raw_raid(transit_id)
            return {'kind': resp['kind'],
                    'raid': {k: row[k] for k in ('status', 'choice', 'cr_taken', 'qty_taken', 'delay',
                                                 'fenced_at')}}
        self.step('respond', inp, run)

    def hot_station(self, round_num):
        self.step('hot_station', {'round': round_num},
                  lambda: {'station': self.ref.piracy.hot_station(round_num)})


def case_piracy_hot_station_windows():
    c = PiracyCase('piracy_hot_station_windows',
                   'hot_station(round) draws choice(STATIONS) from a Random seeded by (game seed, '
                   'round // 20). Rounds in the same 20-round window ask the same question and get the same '
                   'answer; each call makes its own choice draw.', seed=1)
    for r in (0, 19, 20, 39, 40, 41, 100):
        c.hot_station(r)
    return c


def case_piracy_raid_roll_miss():
    c = PiracyCase('piracy_raid_roll_miss',
                   'A bare belt trip (ceres to mars, 500 FRAG; the hold of 1000 sets the cargo value) at '
                   '0.5 / 0.5. roll_departure draws choice(STATIONS) for the hot station twice (once in '
                   'chance(), once for the result), then one marble from the raid bag. Here the marble '
                   'misses: no demand.', seed=RAID_MISS_SEED)
    c.roll(c.depart('amos', 'mars', 'FRAG', 500))
    return c


def case_piracy_raid_roll_hit():
    c = PiracyCase('piracy_raid_roll_hit',
                   'Same trip, seed where the raid marble hits: a pending demand is written (ransom = 15% of '
                   'the cargo value, surrender = 25% of the quantity) and no further draw is made.',
                   seed=RAID_HIT_SEED)
    c.roll(c.depart('amos', 'mars', 'FRAG', 500))
    return c


def case_piracy_raid_roll_escorted():
    c = PiracyCase('piracy_raid_roll_escorted',
                   'An escorted trip cuts the odds by 75% and draws from its own bag (the raid_key ends in '
                   'escort). Four rolls for the same ship: escorted, bare, escorted, bare. The two escorted '
                   'rolls share a bag and the two bare rolls share another, so neither pair is moved by the '
                   'other. (The ship departs once; the later rolls reuse its trip details under new '
                   'transit ids, which a roll that does not hit never writes.)', seed=21)
    esc = c.depart('amos', 'mars', 'FRAG', 100, escort=True)
    bare = dict(esc, escort=False, escort_fee=0)
    for n, args in enumerate((esc, bare, esc, bare)):
        c.roll(dict(args, transit_id=esc['transit_id'] if n == 0 else 'tx-amos-extra-%d' % n))
    return c


def case_piracy_raid_roll_certain():
    c = PiracyCase('piracy_raid_roll_certain',
                   'Odds that cap at 1.0 (a hold value of 30000 is the maximum 2.0x multiplier): the raid is '
                   'certain, so bag_odds returns p unchanged and draw(p >= 1) makes no draw. Only the two '
                   'hot-station choices are drawn.', seed=1, odds=(1.0, 1.0))
    args = c.depart('amos', 'mars', 'FRAG', 500)
    args['hold_value'] = 30000
    c.roll(args)
    return c


def case_piracy_zero_cargo_no_raid_draw():
    c = PiracyCase('piracy_zero_cargo_no_raid_draw',
                   'A trip with nothing aboard (qty 0): chance() returns early, the result still names a hot '
                   'station (one choice draw) and the raid roll is skipped: no marble, no bag state.', seed=1)
    args = c.depart('amos', 'mars', 'FRAG', 500)
    args['qty'] = 0
    args['total_qty'] = 0
    args['hold_value'] = 0
    c.roll(args)
    return c


def case_piracy_disabled_no_draw():
    c = PiracyCase('piracy_disabled_no_draw',
                   'A game with piracy off: roll_departure returns None at once and draws nothing, not even '
                   'the hot station.', seed=1, odds=None)
    args = c.depart('amos', 'mars', 'FRAG', 500)
    c.roll(args)
    return c


def _respond_case(name, description, seed, choice, hit_seed_note=None):
    c = PiracyCase(name, description, seed=seed)
    args = c.depart('amos', 'mars', 'FRAG', 500)
    c.roll(args)
    assert c.steps[-1]['output']['result']['raided'], name
    c.respond('amos', args['transit_id'], choice)
    return c


def case_piracy_respond_pay():
    return _respond_case('piracy_respond_pay',
                         'Raid hit, then pay: the ransom moves CR and no random draw is made.',
                         RAID_HIT_SEED, 'pay')


def case_piracy_respond_surrender():
    return _respond_case('piracy_respond_surrender',
                         'Raid hit, then surrender cargo: 25% of the quantity is taken and fenced, and no '
                         'random draw is made.', RAID_HIT_SEED, 'surrender')


def case_piracy_respond_fight_escaped():
    return _respond_case('piracy_respond_fight_escaped',
                         'Raid hit, then fight, at a seed where the escape marble hits: randint(1, 2) for the '
                         'fight delay is drawn first, then one escape marble (0.5) from the ship bag; the ship '
                         'escapes with no loss and no delay.', FIGHT_ESCAPE_SEED, 'fight')


def case_piracy_respond_fight_lost():
    return _respond_case('piracy_respond_fight_lost',
                         'Raid hit, then fight, at a seed where the escape marble misses: the same two draws, '
                         'then half the cargo is taken and the arrival is delayed by the randint.',
                         FIGHT_LOST_SEED, 'fight')


def case_piracy_respond_rejects_draw_nothing():
    c = PiracyCase('piracy_respond_rejects_draw_nothing',
                   'Responses that are rejected make no draw and leave the bag alone: an unknown choice, a '
                   'transit with no demand, and a repeat answer after a real fight settled the demand (the fight '
                   'is drawn once; the repeat draws nothing).', seed=FIGHT_ESCAPE_SEED)
    args = c.depart('amos', 'mars', 'FRAG', 500)
    c.roll(args)
    c.respond('amos', args['transit_id'], 'bribe')
    c.respond('amos', 'tx-amos-nonexistent', 'fight')
    c.respond('amos', args['transit_id'], 'fight')
    c.respond('amos', args['transit_id'], 'fight')
    return c


def _trace_case(name, description, seed):
    c = PiracyCase(name, description, seed=seed, agents=('amos', 'marvin'))
    r = c.ref.piracy.hire('marvin', 'amos')
    assert r['kind'] == 'privateer_hire_ok', r
    c.preps.append({'op': 'hire', 'sponsor': 'marvin', 'target': 'amos', 'round': c.ref.current_round})
    c.roll(c.depart('amos', 'mars', 'FRAG', 500))
    assert c.steps[-1]['output']['result']['raided'], name
    return c


def case_piracy_privateer_trace_hit():
    return _trace_case('piracy_privateer_trace_hit',
                       'Marvin hires privateers against amos (hire makes no draw). A raid on amos then draws '
                       'the raid marble (odds raised by the contract) and, on a hit, one trace marble '
                       '(p = 0.10, 1 in 10, keyed by the sponsor). At this seed the trace marble hits: the '
                       'sponsor is traced and fined.', TRACE_HIT_SEED)


def case_piracy_privateer_trace_miss():
    return _trace_case('piracy_privateer_trace_miss',
                       'Same contract; at this seed the trace marble misses: the raid is not traced and the '
                       'sponsor stays hidden.', TRACE_MISS_SEED)


# ------------------------------------------------------------------ spatial (agora/spatial.py)

def case_spatial_price_walk_gauss():
    seed = 42
    eng = StationPriceEngine(seed=seed)
    case = Case('spatial_price_walk_gauss', 'spatial',
                'StationPriceEngine.step_round is the only random-consuming function in agora/spatial.py '
                '(routes, windows, fuel, decay and price tables are deterministic): one rng.gauss(0, vol) per '
                '(station, commodity), in STATIONS x COMMODITIES order, 20 draws a round. Two rounds. '
                'Content generation, not a player-facing roll, so it does not use a bag.',
                {'seed': seed, 'theta': eng.theta, 'vol': eng.vol, 'stations': list(spatial_mod.STATIONS),
                 'commodities': list(spatial_mod.COMMODITIES)})
    for rnd in (1, 2):
        def run(rnd=rnd):
            entries = eng.step_round(rnd)
            return {'spots': {st: dict(eng.spots[st]) for st in spatial_mod.STATIONS},
                    'entries': len(entries)}
        case.step('step_round', {'round_num': rnd}, run)
    return case


# ------------------------------------------------------------------ driver

# Seeds that give the outcome the case names (found by tools/golden/gen_draws.py --search; the Python
# test pins every outcome, so a drifted seed fails loudly).
RAID_MISS_SEED = 19
RAID_HIT_SEED = 1
FIGHT_ESCAPE_SEED = 2
FIGHT_LOST_SEED = 1
TRACE_HIT_SEED = 7
TRACE_MISS_SEED = 1

CASES = {}


def _register():
    for name, obj in sorted(globals().items()):
        if name.startswith('case_') and callable(obj):
            CASES[name[len('case_'):]] = obj


def _build(builder):
    """Build one case with every Random the modules make swapped for a recorder."""
    saved = (Bags._rng, hazards_mod.random, piracy_mod.random, spatial_mod.random)
    Bags._rng = _patched_bag_rng
    hazards_mod.random = piracy_mod.random = spatial_mod.random = _RANDOM_SHIM
    del SINK[:]
    try:
        return builder().fixture()
    finally:
        Bags._rng, hazards_mod.random, piracy_mod.random, spatial_mod.random = saved
        del SINK[:]


def generate(out_dir=DEFAULT_OUT):
    os.makedirs(out_dir, exist_ok=True)
    written = []
    for name, builder in CASES.items():
        path = os.path.join(out_dir, name + '.json')
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            json.dump(_build(builder), f, indent=2)
            f.write('\n')
        written.append(path)
    return written


_register()

if __name__ == '__main__':
    for p in generate(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT):
        print(os.path.relpath(p, ROOT))
