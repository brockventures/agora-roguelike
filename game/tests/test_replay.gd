extends RefCounted
## Tests for seeded run replays (#35).

const TMP_ROOT := "user://test_tmp"


func _record(p_seed: int = 35) -> Dictionary:
	var s: Replay.Session = Replay.start_recording(p_seed)
	s.advance_frames(30)
	s.dispatch(M0Loop.ACT_TAB_NEXT)
	for i in 3:
		s.dispatch(M0Loop.ACT_RIGHT)
		s.dispatch(M0Loop.ACT_SUBMIT)
		s.advance_frames(400)
	s.dispatch(M0Loop.ACT_SPEED)
	s.advance_frames(500)
	s.dispatch(M0Loop.ACT_DOWN)
	s.dispatch(M0Loop.ACT_SUBMIT)
	s.advance_frames(300)
	return s.to_recording()


func test_recording_captures_inputs_with_ticks() -> String:
	var rec := _record()
	var inputs: Array = rec["inputs"]
	if inputs.size() != 10:
		return "expected 10 inputs, got %d" % inputs.size()
	if inputs[0]["action"] != M0Loop.ACT_TAB_NEXT or int(inputs[0]["tick"]) <= 0:
		return "first input wrong: %s" % str(inputs[0])
	if int(rec["seed"]) != 35 or str(rec["state_hash"]).length() != 64:
		return "seed or hash missing"
	return "ok"


func test_session_actually_traded() -> String:
	# Guards the replay tests against passing on an empty session.
	var rec := _record()
	var s := Replay.Session.new(35)
	var res: Dictionary = Replay.replay(rec)
	if not bool(res["ok"]):
		return "replay failed: %s" % str(res)
	var fresh: String = s.state_hash()
	if fresh == rec["state_hash"]:
		return "recorded session never changed state"
	return "ok"


func test_replay_reproduces_hash() -> String:
	var rec := _record()
	var res: Dictionary = Replay.replay(rec)
	if not bool(res["ok"]) or res["actual"] != rec["state_hash"]:
		return "replay did not reproduce: %s" % str(res)
	if int(res["final_tick"]) != int(rec["final_tick"]):
		return "final tick differs"
	return "ok"


func test_replay_survives_file_roundtrip() -> String:
	var st := SaveStore.new(TMP_ROOT + "/replay_%d" % Time.get_ticks_usec())
	var path: String = st.dir.path_join("session.replay.json")
	var rec := _record(99)
	if Replay.save_recording(st, path, rec) != OK:
		return "could not write recording"
	var loaded: Dictionary = Replay.load_recording(st, path)
	var res: Dictionary = Replay.replay(loaded["data"]) if bool(loaded["ok"]) else {"ok": false, "error": loaded["error"]}
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(st.dir)
	DirAccess.remove_absolute(TMP_ROOT)  # only succeeds once empty
	return "ok" if bool(res["ok"]) else "replay from file failed: %s" % str(res)


func test_different_seed_gives_different_hash() -> String:
	var a := _record(1)
	var b := _record(2)
	return "ok" if a["state_hash"] != b["state_hash"] else "seed does not affect the hash"


func test_tampered_action_log_mismatches() -> String:
	var rec := _record()
	# Drop one purchase.
	var t: Dictionary = rec.duplicate(true)
	var idx := -1
	for i in t["inputs"].size():
		if t["inputs"][i]["action"] == M0Loop.ACT_SUBMIT:
			idx = i
			break
	t["inputs"].remove_at(idx)
	var res: Dictionary = Replay.replay(t)
	if bool(res["ok"]):
		return "dropped input still validated"
	# Change an action.
	var t2: Dictionary = rec.duplicate(true)
	t2["inputs"][1]["action"] = M0Loop.ACT_LEFT
	if bool(Replay.replay(t2)["ok"]):
		return "altered action still validated"
	# Shift an input to another tick.
	var t3: Dictionary = rec.duplicate(true)
	t3["inputs"][3]["tick"] = int(t3["inputs"][3]["tick"]) + 1
	if bool(Replay.replay(t3)["ok"]):
		return "wrong tick still validated"
	return "ok"


func test_tampered_hash_or_seed_mismatches() -> String:
	var rec := _record()
	var t: Dictionary = rec.duplicate(true)
	t["state_hash"] = "0".repeat(64)
	var r1 := Replay.replay(t)
	if bool(r1["ok"]) or r1["error"] != "state hash mismatch":
		return "bad hash not reported as mismatch: %s" % str(r1)
	var t2: Dictionary = rec.duplicate(true)
	t2["seed"] = int(t2["seed"]) + 1
	if bool(Replay.replay(t2)["ok"]):
		return "changed seed still validated"
	return "ok"


func test_malformed_recording_rejected() -> String:
	if bool(Replay.replay({"seed": 1})["ok"]):
		return "missing fields accepted"
	var bad := _record()
	bad["inputs"] = [{"frame": 1}]
	var r := Replay.replay(bad)
	if bool(r["ok"]) or not str(r["error"]).begins_with("malformed"):
		return "malformed input not reported: %s" % str(r)
	return "ok"
