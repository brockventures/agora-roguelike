extends RefCounted
## The scripted player behind the policy goldens (#160 row 3, docs/design/corporate-policies.md
## section 8). It plays the same shipped world as tools/world_golden.gd, with corporate
## policies attached, for ROUNDS rounds (past the round 20 and round 50 milestones), and takes
## the FIRST LISTED OFFER at every pick. Every press, picks included, goes through
## Replay.Session, so a run is a plain Replay recording. A pick is the Policy Committee modal's
## own input: the cursor starts on the first offer, so the bot presses A (m0_submit) and nothing
## else. (Until the modal landed, #184 recorded it as a private "policy:<id>" input.)
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
## clock reaches that round, before the bot acts in it. The picks it made, [{round, id}], are on
## the session as the meta "picks" (see picks_of), and the index in `inputs` of the press that made
## each one as "pick_inputs".
static func play(p_seed: int, stop_round: int = ROUNDS) -> Replay.Session:
	var wg = load(WG)
	var s := Replay.start_recording(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, wg.TPR, true, true)
	var picks: Array = []
	var pick_inputs: Array = []
	s.set_meta("picks", picks)
	s.set_meta("pick_inputs", pick_inputs)
	var last_round: int = -1
	while s.controller.get_current_round() < stop_round and s.frames < MAX_FRAMES:
		if s.loop.overlay_state == M0Loop.OVERLAY_POLICY:
			var offers: Array[String] = s.controller.policies.offers()
			var round_num: int = int(s.controller.sim_clock.total_ticks / s.controller.ticks_per_round)
			if offers.is_empty() or not s.dispatch(M0Loop.ACT_SUBMIT):
				break  # nothing to take: a stuck run, which the test reports
			picks.append({"round": round_num, "id": offers[0]})
			pick_inputs.append(s.inputs.size() - 1)  # the m0_submit just recorded
		elif not wg._answer_overlay(s):
			var r: int = s.controller.get_current_round()
			if r != last_round and s.controller.docked_at != "" and s.controller.transit.is_empty():
				last_round = r
				wg._act(s, r)
		s.advance()
	return s


## [{round, id}] for every pick the bot made in `s`, from the round each landed on.
static func picks_of(s: Replay.Session) -> Array:
	return s.get_meta("picks", [])
