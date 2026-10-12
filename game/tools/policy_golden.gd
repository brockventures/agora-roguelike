extends RefCounted
## The scripted player behind the policy goldens (#160 row 3, docs/design/corporate-policies.md
## section 8). It plays the same shipped world as tools/world_golden.gd, with corporate
## policies attached, for ROUNDS rounds (past the round 20 and round 50 milestones), and takes
## the FIRST LISTED OFFER at every pick. Every press, picks included, goes through
## Replay.Session, so a run is a plain Replay recording (a pick is the input "policy:<id>").
##
## Used by tests/test_policy_goldens.gd and tools/regen_policy_goldens.gd. Not a class_name:
## callers load() it by path.

const WG := "res://tools/world_golden.gd"
const SEEDS: Array = [84, 7]
const ROUNDS: int = 60
const MAX_FRAMES: int = 9000


static func record(p_seed: int) -> Dictionary:
	return play(p_seed).to_recording()


## The finished session, for tests that want the live objects. `stop_round` ends play when the
## clock reaches that round, before the bot acts in it.
static func play(p_seed: int, stop_round: int = ROUNDS) -> Replay.Session:
	var wg = load(WG)
	var s := Replay.start_recording(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, wg.TPR, true, true)
	var last_round: int = -1
	while s.controller.get_current_round() < stop_round and s.frames < MAX_FRAMES:
		if not wg._answer_overlay(s):
			if s.controller.policies.pending() > 0:
				var offers: Array[String] = s.controller.policies.offers()
				if offers.is_empty() or not s.adopt_policy(offers[0]):
					break  # nothing to take: a stuck run, which the test reports
			else:
				var r: int = s.controller.get_current_round()
				if r != last_round and s.controller.docked_at != "" and s.controller.transit.is_empty():
					last_round = r
					wg._act(s, r)
		s.advance()
	return s


## [{round, id}] for every pick in a recording, from the sim tick each landed on.
static func picks_of(rec: Dictionary) -> Array:
	var out: Array = []
	for e in rec["inputs"]:
		if str(e["action"]).begins_with(Replay.POLICY_PREFIX):
			out.append({"round": int(int(e["tick"]) / int(rec["ticks_per_round"])), "id": str(e["action"]).substr(Replay.POLICY_PREFIX.length())})
	return out
