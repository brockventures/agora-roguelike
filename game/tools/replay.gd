extends SceneTree
## Headless seeded-replay entry point (#35).
##
##   godot --headless --path game -s res://tools/replay.gd -- <file>
##       Replays <file>; prints PASS / FAIL with both hashes.
##       Exit 0 on a matching state hash, 1 on mismatch, 2 on unreadable input.
##   godot --headless --path game -s res://tools/replay.gd -- --record-demo <file> [seed]
##       Records a short scripted M0 session to <file> (default seed 35).

const DEMO_SEED: int = 35


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: replay.gd -- <file> | --record-demo <file> [seed]")
		quit(2)
		return
	var store := SaveStore.new()
	if args[0] == "--record-demo":
		if args.size() < 2:
			printerr("--record-demo needs an output file")
			quit(2)
			return
		var seed_value: int = int(args[2]) if args.size() > 2 else DEMO_SEED
		var rec: Dictionary = _record_demo(seed_value)
		var err: Error = Replay.save_recording(store, args[1], rec)
		if err != OK:
			printerr("could not write %s: error %d" % [args[1], err])
			quit(2)
			return
		print("RECORDED %s seed=%d inputs=%d frames=%d hash=%s" % [args[1], seed_value, rec["inputs"].size(), rec["frames"], rec["state_hash"]])
		quit(0)
		return
	var loaded: Dictionary = Replay.load_recording(store, args[0])
	if not bool(loaded["ok"]):
		printerr("cannot load %s: %s" % [args[0], loaded["error"]])
		quit(2)
		return
	var res: Dictionary = Replay.replay(loaded["data"])
	if bool(res["ok"]):
		print("PASS %s frames=%d final_tick=%d hash=%s" % [args[0], res["frames"], res["final_tick"], res["actual"]])
		quit(0)
	else:
		print("FAIL %s: %s (expected %s, got %s)" % [args[0], res["error"], res["expected"], res["actual"]])
		quit(1)


## A scripted session: open the Market tab, place some orders, let rounds pass.
func _record_demo(seed_value: int) -> Dictionary:
	var s: Replay.Session = Replay.start_recording(seed_value)
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
