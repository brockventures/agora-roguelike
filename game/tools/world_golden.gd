extends RefCounted
## The scripted player behind the whole-world goldens (Epic 3 task 12, part of #18).
##
## `record(seed)` plays 40 rounds of the SHIPPED world (barons, rival fleets, heat and
## random baron events all on, nothing stripped out) through the real round loop, as a
## player would: every input goes through `Replay.Session.dispatch`, so the run is a
## plain `Replay` recording. The bot looks at the game state to decide what to press, but
## only the presses are kept; the fixture is just those inputs and the final state hash.
##
## Used by tests/test_world_goldens.gd and tools/regen_world_goldens.gd. Not a class_name
## on purpose: callers load() it by path.

const SEEDS: Array = [84, 7]
const ROUNDS: int = 40
const TPR: int = 30
const MAX_FRAMES: int = 6000
## Rounds the bot sets sail on, and where to. Mars -> Ceres -> Earth -> Mars crosses the
## belt toll, a baron's dock and both ends of an inner lane.
const VOYAGES: Dictionary = {7: "ceres", 18: "earth", 29: "mars"}


static func record(p_seed: int) -> Dictionary:
	return _play(Replay.start_recording(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true)).to_recording()


## The finished session itself, for tests that want the live objects.
## `observe` (optional) is called with the session after every frame; it must only look.
## `stop_round` ends the bot's play when the clock reaches that round, before it acts in it.
static func play(p_seed: int, observe: Callable = Callable(), stop_round: int = ROUNDS) -> Replay.Session:
	return _play(Replay.start_recording(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR, true), observe, stop_round)


## No bot: just run the clock on to `ROUNDS`, answering any modal by hand (nothing is
## recorded). The same tail is used on an uninterrupted run and on a restored one, so the
## two can be compared without the bot's UI-only state (selected commodity, tab) mattering.
static func run_quiet(rc: RunController, lp: M0Loop) -> void:
	var frames: int = 0
	while rc.get_current_round() < ROUNDS and frames < MAX_FRAMES:
		match lp.overlay_state:
			M0Loop.OVERLAY_CRISIS:
				lp.acknowledge_crisis()
			M0Loop.OVERLAY_MONOPOLY:
				lp.acknowledge_monopoly()
			M0Loop.OVERLAY_CONTRACT:
				lp.decline_contract()
		lp.advance(Replay.DEFAULT_FRAME_DELTA)
		frames += 1


static func _play(s: Replay.Session, observe: Callable = Callable(), stop_round: int = ROUNDS) -> Replay.Session:
	var last_round: int = -1
	while s.controller.get_current_round() < stop_round and s.frames < MAX_FRAMES:
		if not _answer_overlay(s):
			var r: int = s.controller.get_current_round()
			if r != last_round and s.controller.docked_at != "" and s.controller.transit.is_empty():
				last_round = r
				_act(s, r)
		s.advance()
		if observe.is_valid():
			observe.call(s)
	return s


## One press that answers whichever modal has halted the clock. True when one was up.
static func _answer_overlay(s: Replay.Session) -> bool:
	match s.loop.overlay_state:
		M0Loop.OVERLAY_CRISIS, M0Loop.OVERLAY_MONOPOLY:
			s.dispatch(M0Loop.ACT_SUBMIT)  # A acknowledges
			return true
		M0Loop.OVERLAY_CONTRACT:
			s.dispatch(M0Loop.ACT_CANCEL)  # B declines the baron's offer
			return true
	return false


static func _show(s: Replay.Session, tab: int) -> void:
	for i in 4:
		if int(s.loop.tab) == tab:
			return
		s.dispatch(M0Loop.ACT_TAB_NEXT)


static func _act(s: Replay.Session, r: int) -> void:
	if VOYAGES.has(r):
		# Stock up first: rivals only react to a departure worth reacting to.
		_show(s, M0Loop.Tab.MARKET)
		for i in 4:
			s.dispatch(M0Loop.ACT_RIGHT)
			s.dispatch(M0Loop.ACT_SUBMIT)
		_show(s, M0Loop.Tab.MAP)
		for i in 6:
			if s.loop.hud.active_station == VOYAGES[r]:
				break
			s.dispatch(M0Loop.ACT_STATION_NEXT)
		s.dispatch(M0Loop.ACT_SUBMIT)  # A on the Map tab departs
		return
	_show(s, M0Loop.Tab.MARKET)
	if s.controller.docked_at != "mars":
		# Dump the hold into the local baron's book: sales are what press a baron.
		for i in 6:
			s.dispatch(M0Loop.ACT_LEFT)
			s.dispatch(M0Loop.ACT_SUBMIT)
		s.dispatch(M0Loop.ACT_CREDIT)  # then ask it for a line, which raises its heat
	if r % 5 == 3:
		s.dispatch(M0Loop.ACT_COMMODITY_NEXT)
	if r % 2 == 0:
		s.dispatch(M0Loop.ACT_RIGHT)
		s.dispatch(M0Loop.ACT_SUBMIT)  # buy
	elif r % 4 == 1:
		s.dispatch(M0Loop.ACT_LEFT)
		s.dispatch(M0Loop.ACT_SUBMIT)  # sell
