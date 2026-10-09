class_name SaveStore
extends RefCounted
## Atomic JSON persistence for the run slot and the meta profile (#35).
##
## Steam Cloud layout (everything under one directory, fixed filenames, so the
## Cloud auto-sync root is the single folder `user://saves/`):
##   user://saves/profile.json      MetaProfile + bought Golden Parachutes perks
##   user://saves/run_slot_0.json   the in-progress run (ledger, cargo, clocks,
##                                  order books, Bags marble state)
## The two are separate files so a lost or corrupt run never takes the profile
## with it. Each file is an envelope:
##   {"schema_version": 1, "kind": "run" | "profile", "data": {...}}
##
## Writes are atomic: the JSON goes to "<file>.tmp", is flushed and closed, and
## only then renamed over the real file. A failed or interrupted write leaves
## the previous save untouched. Reads reject unknown kinds and any schema
## version other than SCHEMA_VERSION with a clear error instead of guessing.
##
## The directory is a constructor argument so tests never touch the real
## user://. SaveStore.default_dir() honours the AGORA_SAVE_DIR environment
## variable, then falls back to DEFAULT_DIR.

const SCHEMA_VERSION: int = 1
const DEFAULT_DIR: String = "user://saves"
const PROFILE_FILE: String = "profile.json"
const RUN_FILE: String = "run_slot_0.json"
const TMP_SUFFIX: String = ".tmp"
const KIND_RUN: String = "run"
const KIND_PROFILE: String = "profile"

var dir: String = DEFAULT_DIR
## Test hook: abort the next write halfway through the temp file, as a full
## disk or a crash would. The final file must survive untouched.
var simulate_write_failure: bool = false


func _init(p_dir: String = "") -> void:
	dir = p_dir if p_dir != "" else default_dir()


static func default_dir() -> String:
	var env: String = OS.get_environment("AGORA_SAVE_DIR")
	return env if env != "" else DEFAULT_DIR


func profile_path() -> String:
	return dir.path_join(PROFILE_FILE)


func run_path() -> String:
	return dir.path_join(RUN_FILE)


# --- Generic envelope IO ---

## Writes {schema_version, kind, data} to `path` atomically. Returns OK or an Error.
func write(path: String, kind: String, data: Dictionary) -> Error:
	var mk: Error = DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if mk != OK:
		return mk
	var envelope := {"schema_version": SCHEMA_VERSION, "kind": kind, "data": data}
	var text: String = JSON.stringify(envelope, "\t", true)
	var tmp: String = path + TMP_SUFFIX
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	if simulate_write_failure:
		f.store_string(text.substr(0, text.length() / 2))
		f.close()
		DirAccess.remove_absolute(tmp)
		return ERR_FILE_CANT_WRITE
	f.store_string(text)
	f.flush()
	var werr: Error = f.get_error()
	f.close()
	if werr != OK:
		DirAccess.remove_absolute(tmp)
		return werr
	var rn: Error = DirAccess.rename_absolute(tmp, path)
	if rn != OK:
		DirAccess.remove_absolute(tmp)
	return rn


## Reads and validates an envelope. Returns {"ok": bool, "error": String,
## "data": Dictionary}. A missing file is {"ok": false, "error": "missing"}.
func read(path: String, kind: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _fail("missing")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _fail("unreadable: error %d" % FileAccess.get_open_error())
	var text: String = f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		return _fail("corrupt: not valid JSON (line %d)" % json.get_error_line())
	var parsed = json.data
	if not (parsed is Dictionary):
		return _fail("corrupt: not a JSON object")
	if not parsed.has("schema_version") or not (parsed["schema_version"] is float or parsed["schema_version"] is int):
		return _fail("corrupt: no schema_version")
	var ver: int = int(parsed["schema_version"])
	if ver != SCHEMA_VERSION:
		return _fail("schema_version %d is not supported (expected %d)" % [ver, SCHEMA_VERSION])
	if str(parsed.get("kind", "")) != kind:
		return _fail("wrong kind '%s' (expected '%s')" % [str(parsed.get("kind", "")), kind])
	var data = parsed.get("data", null)
	if not (data is Dictionary):
		return _fail("corrupt: no data object")
	return {"ok": true, "error": "", "data": data}


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "data": {}}


# --- Profile ---

func save_profile(profile: MetaProfile) -> Error:
	return write(profile_path(), KIND_PROFILE, profile.to_dict())


## Loads the persisted profile, or null when there is none or it is unusable.
## (A bad profile never blocks startup: the game just begins with a fresh one.)
func load_profile() -> MetaProfile:
	var r: Dictionary = read(profile_path(), KIND_PROFILE)
	if not bool(r["ok"]):
		return null
	return MetaProfile.from_dict(r["data"])


# --- Run slot ---

func save_run(controller: RunController, market: StationMarket, bags: Bags) -> Error:
	return write(run_path(), KIND_RUN, RunSave.capture(controller, market, bags))


## Returns {"ok", "error", "controller", "market", "bags"}.
func load_run() -> Dictionary:
	var r: Dictionary = read(run_path(), KIND_RUN)
	if not bool(r["ok"]):
		return r
	return RunSave.restore(r["data"])


func has_run() -> bool:
	return FileAccess.file_exists(run_path())


func delete_run() -> void:
	if has_run():
		DirAccess.remove_absolute(run_path())
