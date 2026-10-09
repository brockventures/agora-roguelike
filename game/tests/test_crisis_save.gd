extends RefCounted
## CrisisDeck in RunSave (#12 + #35): active crises survive save/load, the state
## hash covers them, and a seeded replay that draws a crisis reproduces the hash.

const TMP_ROOT := "user://test_tmp"
const TPR: int = 4


func _session(p_seed: int, recording: bool = false) -> Replay.Session:
	if recording:
		return Replay.start_recording(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR)
	return Replay.Session.new(p_seed, {}, Replay.DEFAULT_FRAME_DELTA, TPR)


## Advances until the crisis modal is up. False if none within the budget.
func _to_crisis(s: Replay.Session, budget: int = 900) -> bool:
	for i in range(budget / 5):
		s.advance_frames(5)
		if s.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
			return true
	return false


func test_round_trip_with_active_crisis_mid_duration() -> String:
	var s := _session(3)
	var deck: CrisisDeck = s.controller.crisis_deck
	var only: Array = []
	for def in deck.data["crises"]:
		if def["id"] == "localized_shortage":
			only.append(def)
	deck.data["crises"] = only
	deck.data["grace_rounds"] = 0
	deck.bags.force("crisis", true)
	if not _to_crisis(s):
		return "no crisis drawn"
	s.dispatch(M0Loop.ACT_SUBMIT)
	s.advance_frames(TPR + 1)  # one round into it
	if deck.active.is_empty():
		return "crisis expired too early for a mid-duration save"
	var c: Dictionary = deck.active[0]
	var left: int = int(c["expires_round"]) - s.controller.get_current_round()
	if left < 1:
		return "crisis has %d rounds left" % left
	var st := SaveStore.new("%s/crisis_%d" % [TMP_ROOT, Time.get_ticks_usec()])
	var before: String = s.state_hash()
	var err: Error = st.save_run(s.controller, s.loop.market, s.bags)
	var r: Dictionary = st.load_run()
	DirAccess.remove_absolute(st.run_path())
	if err != OK or not bool(r["ok"]):
		return "save/load failed: %s" % str(r.get("error", err))
	var rc: RunController = r["controller"]
	var mkt: StationMarket = r["market"]
	if rc.crisis_deck == null or rc.crisis_deck.active.size() != 1:
		return "active crisis lost in the save"
	var back: Dictionary = rc.crisis_deck.active[0]
	if back["id"] != c["id"] or back["commodity"] != c["commodity"] or int(back["expires_round"]) != int(c["expires_round"]):
		return "crisis changed: %s vs %s" % [str(back), str(c)]
	if int(back["expires_round"]) - rc.get_current_round() != left:
		return "remaining rounds changed"
	if RunSave.state_hash(rc, mkt, r["bags"]) != before:
		return "state hash changed across save/load"
	if mkt.crisis_mods.is_empty() or mkt.crisis_mods != s.loop.market.crisis_mods:
		return "market modifiers not restored"
	if RunSave.canonical(mkt.to_dict()) != RunSave.canonical(s.loop.market.to_dict()):
		return "books changed by the restore"
	# Both decks expire it on the same round and end in the same state.
	for i in 20 * TPR:
		s.controller.advance(Replay.DEFAULT_FRAME_DELTA)
		rc.advance(Replay.DEFAULT_FRAME_DELTA)
		for x in [s.controller, rc]:
			if x.crisis_deck.has_pending_ack():
				x.crisis_deck.acknowledge()
				x.sim_clock.resume()
	if rc.crisis_deck.active != s.controller.crisis_deck.active or RunSave.canonical(rc.crisis_deck.to_dict()) != RunSave.canonical(s.controller.crisis_deck.to_dict()):
		return "restored deck diverged from the original"
	return "ok"


func test_state_hash_covers_the_deck() -> String:
	var s := _session(5)
	var with_deck: String = s.state_hash()
	s.controller.crisis_deck.draw_count += 1
	if s.state_hash() == with_deck:
		return "deck state does not affect the hash"
	var c: Dictionary = s.controller.crisis_deck.to_dict()
	c["active"] = [{"uid": 1, "id": "x", "kind": "audit", "tier": "mid", "name": "X", "text": "", "band": "low", "station": "", "commodity": "", "started_round": 1, "expires_round": 4, "rounds": 3, "effects": {"trade_cap_qty": 5}}]
	var other := _session(5)
	other.controller.crisis_deck = CrisisDeck.from_dict(c)
	if other.state_hash() == with_deck:
		return "active crises do not affect the hash"
	return "ok"


func test_seeded_replay_that_draws_a_crisis_reproduces_the_hash() -> String:
	for p_seed in range(1, 30):
		var s := _session(p_seed, true)
		if not _to_crisis(s):
			continue
		s.dispatch(M0Loop.ACT_SUBMIT)
		s.advance_frames(60)
		var rec: Dictionary = s.to_recording()
		if s.controller.crisis_deck.draw_count < 1:
			return "seed %d: no crisis in the deck" % p_seed
		var res: Dictionary = Replay.replay(rec)
		if not bool(res["ok"]) or res["actual"] != rec["state_hash"]:
			return "seed %d: replay did not reproduce: %s" % [p_seed, str(res)]
		# And the hash is not blind to the crisis state.
		var cap: Dictionary = RunSave.capture(s.controller, s.loop.market, s.bags)
		cap.erase("crisis")
		if RunSave.hash_dict(cap) == rec["state_hash"]:
			return "hash ignores the crisis deck"
		return "ok"
	return "no seed in 1..29 drew a crisis within the budget"
