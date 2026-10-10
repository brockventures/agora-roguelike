class_name Replay
extends RefCounted
## Seeded run replays (#35): record the player's m0_* actions with the tick
## they happened on, then re-execute them headless and compare a state hash.
##
## A Session is a headless M0 game (RunController + OrbitalHUD + M0Loop + Bags)
## built from a seed and an optional starting profile. It is driven in fixed
## frames of `frame_delta` seconds, never wall-clock time, so the same inputs on
## the same seed always produce the same state.
##
## Recording file (JSON envelope, kind "replay", written through SaveStore):
##   seed, profile (starting MetaProfile dict), frame_delta, ticks_per_round,
##   inputs: [{frame, tick, action}, ...], frames (total), final_tick,
##   state_hash (RunSave.state_hash at the end of the session)
## `frame` is the count of advance() calls before the action; `tick` is the sim
## total_ticks when it fired. Replay steps to each `frame`, asserts the sim is
## on the recorded `tick`, dispatches the action, and finally compares hashes.

const KIND_REPLAY: String = "replay"
const DEFAULT_FRAME_DELTA: float = 1.0 / 60.0 + 0.0001


class Session extends RefCounted:
	var controller: RunController
	var hud: OrbitalHUD
	var loop: M0Loop
	var bags: Bags
	var seed: int = 0
	var frame_delta: float = DEFAULT_FRAME_DELTA
	var frames: int = 0
	var inputs: Array = []
	var recording: bool = false
	var _start_profile: Dictionary = {}
	## True when the run was started with the sector barons attached (what a new
	## game does). Off by default: a plain session has no world and hashes as it
	## did before Epic 3. Recorded as `world` only when set.
	var with_world: bool = false

	func _init(p_seed: int, p_profile: Dictionary = {}, p_frame_delta: float = DEFAULT_FRAME_DELTA, p_ticks_per_round: int = RunController.DEFAULT_TICKS_PER_ROUND, p_world: bool = false) -> void:
		seed = p_seed
		with_world = p_world
		frame_delta = p_frame_delta
		_start_profile = p_profile.duplicate(true)
		var profile := MetaProfile.from_dict(p_profile)
		controller = RunController.new(profile, p_seed, null, {}, p_ticks_per_round)
		if p_world:
			controller.world = Barons.for_new_run()
		hud = OrbitalHUD.new(controller)
		loop = M0Loop.new(hud)
		loop.dock_at(M0Loop.M0_STATION)
		bags = Bags.new("m0", null, p_seed)

	## One fixed frame. Returns sub-ticks executed.
	func advance() -> int:
		frames += 1
		return loop.advance(frame_delta)

	func advance_frames(n: int) -> void:
		for i in n:
			advance()

	## Dispatches one m0_* action, logging it when recording.
	func dispatch(action: String) -> bool:
		if recording:
			inputs.append({"frame": frames, "tick": controller.sim_clock.total_ticks, "action": action})
		return loop.dispatch_action(action)

	func state_hash() -> String:
		return RunSave.state_hash(controller, loop.market, bags)

	func to_recording() -> Dictionary:
		var rec: Dictionary = {
			"seed": seed,
			"profile": _start_profile.duplicate(true),
			"frame_delta": frame_delta,
			"frame_delta_hex": Replay.double_to_hex(frame_delta),
			"ticks_per_round": controller.ticks_per_round,
			"inputs": inputs.duplicate(true),
			"frames": frames,
			"final_tick": controller.sim_clock.total_ticks,
			"state_hash": state_hash(),
		}
		if with_world:
			rec["world"] = true
		return rec


static func start_recording(p_seed: int, p_profile: Dictionary = {}, p_frame_delta: float = DEFAULT_FRAME_DELTA, p_ticks_per_round: int = RunController.DEFAULT_TICKS_PER_ROUND, p_world: bool = false) -> Session:
	var s := Session.new(p_seed, p_profile, p_frame_delta, p_ticks_per_round, p_world)
	s.recording = true
	return s


## Re-executes a recording. Returns {"ok": bool, "error": String,
## "expected": String, "actual": String, "frames": int, "final_tick": int}.
## ok is true only when every input landed on its recorded tick and the final
## state hash equals the recorded one.
static func replay(rec: Dictionary) -> Dictionary:
	var result := {"ok": false, "error": "", "expected": str(rec.get("state_hash", "")), "actual": "", "frames": 0, "final_tick": 0}
	for key in ["seed", "inputs", "frames", "state_hash"]:
		if not rec.has(key):
			result["error"] = "malformed recording: missing '%s'" % key
			return result
	if not (rec["inputs"] is Array):
		result["error"] = "malformed recording: inputs is not an array"
		return result
	var profile = rec.get("profile", {})
	var s := Session.new(int(rec["seed"]), profile if profile is Dictionary else {},
		_frame_delta_of(rec),
		int(rec.get("ticks_per_round", RunController.DEFAULT_TICKS_PER_ROUND)),
		bool(rec.get("world", false)))
	var total_frames: int = int(rec["frames"])
	var idx: int = 0
	for entry in rec["inputs"]:
		if not (entry is Dictionary) or not entry.has("frame") or not entry.has("tick") or not entry.has("action"):
			result["error"] = "malformed input #%d" % idx
			return result
		var frame: int = int(entry["frame"])
		if frame < s.frames or frame > total_frames:
			result["error"] = "input #%d: frame %d out of order or past the end" % [idx, frame]
			return result
		s.advance_frames(frame - s.frames)
		var tick: int = s.controller.sim_clock.total_ticks
		if tick != int(entry["tick"]):
			result["error"] = "input #%d: sim is on tick %d, recording says %d" % [idx, tick, int(entry["tick"])]
			return _finish(result, s)
		s.loop.dispatch_action(str(entry["action"]))
		idx += 1
	s.advance_frames(maxi(0, total_frames - s.frames))
	_finish(result, s)
	if result["error"] == "":
		if s.controller.sim_clock.total_ticks != int(rec.get("final_tick", s.controller.sim_clock.total_ticks)):
			result["error"] = "final tick %d does not match recorded %d" % [s.controller.sim_clock.total_ticks, int(rec["final_tick"])]
		elif result["actual"] != result["expected"]:
			result["error"] = "state hash mismatch"
		else:
			result["ok"] = true
	return result


## JSON (and str()) keep only ~15 significant digits, which is not enough to
## reproduce a frame step bit-for-bit, so the exact double travels as hex bytes.
static func double_to_hex(v: float) -> String:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_double(0, v)
	return b.hex_encode()


static func hex_to_double(h: String) -> float:
	if h.length() != 16 or not h.is_valid_hex_number():
		return NAN
	return h.hex_decode().decode_double(0)


static func _frame_delta_of(rec: Dictionary) -> float:
	var exact: float = hex_to_double(str(rec.get("frame_delta_hex", "")))
	if is_finite(exact) and exact > 0.0:
		return exact
	return float(rec.get("frame_delta", DEFAULT_FRAME_DELTA))


static func _finish(result: Dictionary, s: Session) -> Dictionary:
	result["actual"] = s.state_hash()
	result["frames"] = s.frames
	result["final_tick"] = s.controller.sim_clock.total_ticks
	return result


## Writes a recording through SaveStore's atomic envelope writer.
static func save_recording(store: SaveStore, path: String, rec: Dictionary) -> Error:
	return store.write(path, KIND_REPLAY, rec)


static func load_recording(store: SaveStore, path: String) -> Dictionary:
	return store.read(path, KIND_REPLAY)
