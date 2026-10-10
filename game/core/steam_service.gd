class_name SteamService
extends RefCounted
## Optional Steamworks layer (#27, Integrate godot-steam SDK; part of #26, Epic 5).
##
## The game never depends on Steam. GodotSteam is found at RUNTIME
## (Engine.has_singleton / ClassDB) and driven only through dynamic .call(), so
## no script here has a hard reference to the `Steam` class and everything
## parses and runs with no GodotSteam binary and no Steam client. When Steam is
## unavailable every method is a logged no-op (see `log_lines`).
##
## What it does:
##  - Achievements and stats (data/achievements.json). A LOCAL MIRROR of
##    unlocks and stats is always kept (and persisted through SaveStore), so
##    unlocks are testable without Steam and are pushed to Steam on the first
##    launch that has it.
##  - Cloud saves: SaveStore calls cloud_push/cloud_restore/cloud_delete around
##    its own file IO. Local files stay the source of truth; save format is
##    untouched.
##  - Steam Input: input_init() registers the action manifest and poll_input()
##    reports edges for the m0_* actions (see docs/steam.md).
##
## The App ID comes from ONE place: data/steam.json (override: AGORA_STEAM_APP_ID).
## It is 480 (Spacewar) until #30, Steamworks onboarding, gives us a real one.
## Not named `Steam`: that is the GodotSteam singleton's own name.

signal achievement_unlocked(id: String)

const DEFAULT_APP_ID: int = 480
const CONFIG_PATH: String = "res://data/steam.json"
const ACHIEVEMENTS_PATH: String = "res://data/achievements.json"
const ENV_APP_ID: String = "AGORA_STEAM_APP_ID"
const BACKEND_NAME: String = "Steam"
const LOG_CAP: int = 200
const INPUT_ACTION_SET: String = "InGame"

## The shared instance lives in Engine metadata, not a `static var`: a static
## holding a script instance leaks the script resource at exit, which run.sh
## (rightly) reports as an engine ERROR.
const SHARED_META: String = "agora_steam_service"
static var _offline_announced: bool = false

var app_id: int = DEFAULT_APP_ID
## True only after a successful GodotSteam init.
var available: bool = false
var backend: Object = null
## achievement id -> {"name", "desc", "stat"?, "threshold"?, "hook"?}
var achievement_defs: Dictionary = {}
var stat_defs: Dictionary = {}
## Local mirror: achievement id -> unix time unlocked; stat id -> int.
var unlocked: Dictionary = {}
var stats: Dictionary = {}
var log_lines: Array[String] = []

## Weak: SaveStore.cloud points back at this service, and a strong pair would be a
## reference cycle that leaks both at exit.
var _store_ref: WeakRef = null
var _input_ready: bool = false
var _input_controller: int = 0
var _action_set: int = 0
var _input_down: Dictionary = {}


func _init() -> void:
	app_id = load_app_id()
	_load_definitions()


## The process-wide instance (what the SteamHub autoload drives).
static func shared() -> SteamService:
	if not Engine.has_meta(SHARED_META):
		Engine.set_meta(SHARED_META, SteamService.new())
	return Engine.get_meta(SHARED_META)


## Tests swap the shared instance; pass null to reset.
static func set_shared(s: SteamService) -> void:
	if s == null:
		if Engine.has_meta(SHARED_META):
			Engine.remove_meta(SHARED_META)
	else:
		Engine.set_meta(SHARED_META, s)


## App ID: AGORA_STEAM_APP_ID, else data/steam.json, else 480.
static func load_app_id() -> int:
	var env: String = OS.get_environment(ENV_APP_ID)
	if env.is_valid_int() and int(env) > 0:
		return int(env)
	var cfg: Dictionary = _read_json(CONFIG_PATH)
	var v = cfg.get("app_id", DEFAULT_APP_ID)
	return int(v) if (v is int or v is float) and int(v) > 0 else DEFAULT_APP_ID


## The GodotSteam object when the extension is loaded, else null. Never throws.
static func detect_backend() -> Object:
	if Engine.has_singleton(BACKEND_NAME):
		return Engine.get_singleton(BACKEND_NAME)
	if ClassDB.class_exists(BACKEND_NAME) and ClassDB.can_instantiate(BACKEND_NAME):
		return ClassDB.instantiate(BACKEND_NAME)
	return null


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _load_definitions() -> void:
	var d: Dictionary = _read_json(ACHIEVEMENTS_PATH)
	for a in d.get("achievements", []):
		if a is Dictionary and str(a.get("id", "")) != "":
			achievement_defs[str(a["id"])] = a
	for s in d.get("stats", []):
		if s is Dictionary and str(s.get("id", "")) != "":
			stat_defs[str(s["id"])] = s


func _log(msg: String) -> void:
	log_lines.append(msg)
	if log_lines.size() > LOG_CAP:
		log_lines.remove_at(0)


## Logs a no-op once to the console (every call is still recorded in log_lines).
func _noop(what: String) -> void:
	_log("steam unavailable: %s skipped" % what)
	if not _offline_announced:
		_offline_announced = true
		print("Steam: not available, running offline (achievements mirrored locally, saves local-only)")


# --- Init ---

## Connects to Steam. `p_backend` null means "detect GodotSteam"; tests pass a
## fake. Returns `available`. Safe to call with no extension present.
func initialize(p_backend: Object = null) -> bool:
	available = false
	backend = p_backend if p_backend != null else detect_backend()
	if backend == null:
		_noop("initialize")
		return false
	# Steam reads these when a game is started outside the Steam client (dev runs).
	OS.set_environment("SteamAppId", str(app_id))
	OS.set_environment("SteamGameId", str(app_id))
	var ok: bool = false
	if backend.has_method("steamInitEx"):
		var r = backend.call("steamInitEx", app_id, true)
		ok = r is Dictionary and int(r.get("status", -1)) == 0
		if not ok:
			_log("steamInitEx failed: %s" % str(r))
	elif backend.has_method("steamInit"):
		var r2 = backend.call("steamInit", app_id, true)
		ok = r2 is Dictionary and int(r2.get("status", 0)) == 1
		if not ok:
			_log("steamInit failed: %s" % str(r2))
	else:
		_log("backend has neither steamInitEx nor steamInit")
	if not ok:
		backend = null
		_noop("initialize")
		return false
	available = true
	_log("steam initialised (app %d)" % app_id)
	if backend.has_method("requestCurrentStats"):
		backend.call("requestCurrentStats")
	_push_mirror_to_backend()
	return true


## Pumps Steam callbacks; the SteamHub autoload calls this every frame.
func run_callbacks() -> void:
	if available and backend.has_method("run_callbacks"):
		backend.call("run_callbacks")


## Offline unlocks and stats reach Steam on the first launch that has it.
func _push_mirror_to_backend() -> void:
	for id in unlocked:
		_backend_unlock(str(id))
	for sid in stats:
		_backend_stat(str(sid), int(stats[sid]))
	_backend_store()


# --- Local mirror persistence ---

## Attaches the SaveStore: merges any persisted mirror into memory (union of
## unlocks, max of stats, so a merge never loses progress) and persists changes.
func attach_store(store: SaveStore) -> void:
	_store_ref = weakref(store)
	var r: Dictionary = store.read(store.steam_path(), SaveStore.KIND_STEAM)
	if bool(r["ok"]):
		merge_dict(r["data"])


func to_dict() -> Dictionary:
	return {"unlocked": unlocked.duplicate(), "stats": stats.duplicate()}


func merge_dict(d: Dictionary) -> void:
	var u = d.get("unlocked", {})
	if u is Dictionary:
		for id in u:
			if achievement_defs.has(str(id)) and not unlocked.has(str(id)):
				unlocked[str(id)] = int(u[id]) if (u[id] is int or u[id] is float) else 0
	var s = d.get("stats", {})
	if s is Dictionary:
		for sid in s:
			if stat_defs.has(str(sid)) and (s[sid] is int or s[sid] is float):
				stats[str(sid)] = maxi(int(stats.get(str(sid), 0)), int(s[sid]))


func _persist() -> void:
	var store: SaveStore = _store_ref.get_ref() if _store_ref != null else null
	if store != null:
		store.write(store.steam_path(), SaveStore.KIND_STEAM, to_dict())


# --- Achievements and stats ---

func is_unlocked(id: String) -> bool:
	return unlocked.has(id)


## Unlocks `id` in the mirror and, when Steam is up, on Steam. True only the
## first time. Unknown ids are logged and ignored.
func unlock(id: String) -> bool:
	if not achievement_defs.has(id):
		_log("unknown achievement '%s'" % id)
		return false
	if unlocked.has(id):
		return false
	unlocked[id] = int(Time.get_unix_time_from_system())
	if available:
		_backend_unlock(id)
		_backend_store()
	else:
		_noop("setAchievement(%s)" % id)
	_persist()
	achievement_unlocked.emit(id)
	return true


func get_stat(id: String) -> int:
	return int(stats.get(id, 0))


func set_stat(id: String, value: int) -> void:
	if not stat_defs.has(id):
		_log("unknown stat '%s'" % id)
		return
	stats[id] = value
	if available:
		_backend_stat(id, value)
		_backend_store()
	else:
		_noop("setStatInt(%s)" % id)
	_check_stat_achievements(id)
	_persist()


func add_stat(id: String, delta: int = 1) -> void:
	set_stat(id, get_stat(id) + delta)


## Raises the stat to `value` when that is higher; never lowers it.
func max_stat(id: String, value: int) -> void:
	if value > get_stat(id):
		set_stat(id, value)


## Data-driven achievements: {"stat": id, "threshold": n} unlocks at stat >= n.
func _check_stat_achievements(stat_id: String) -> void:
	for id in achievement_defs:
		var a: Dictionary = achievement_defs[id]
		if str(a.get("stat", "")) == stat_id and get_stat(stat_id) >= int(a.get("threshold", 1 << 62)):
			unlock(str(id))


func _backend_unlock(id: String) -> void:
	if backend.has_method("setAchievement"):
		backend.call("setAchievement", id)


func _backend_stat(id: String, value: int) -> void:
	if backend.has_method("setStatInt"):
		backend.call("setStatInt", id, value)


func _backend_store() -> void:
	if backend.has_method("storeStats"):
		backend.call("storeStats")


# --- Cloud saves (Steam Remote Storage) ---
#
# Remote Storage filenames are flat; the SaveStore file name (profile.json,
# settings.json, run_slot_0.json, steam_mirror.json) is used as-is. The Steamworks
# partner site needs Remote Storage enabled for the app (docs/steam.md).

func cloud_enabled() -> bool:
	if not available:
		return false
	for m in ["isCloudEnabledForApp", "isCloudEnabledForAccount"]:
		if not backend.has_method(m) or not bool(backend.call(m)):
			return false
	return backend.has_method("fileWrite") and backend.has_method("fileRead")


## Mirrors a file SaveStore just wrote into Steam Cloud. True when it was sent.
func cloud_push(file_name: String, text: String) -> bool:
	if not cloud_enabled():
		_noop("cloud write %s" % file_name)
		return false
	return bool(backend.call("fileWrite", file_name, text.to_utf8_buffer()))


func cloud_delete(file_name: String) -> void:
	if cloud_enabled() and backend.has_method("fileDelete"):
		backend.call("fileDelete", file_name)


## Before SaveStore reads `path`: when Steam Cloud has a newer copy (or the
## local one is missing) it replaces the local file. SaveStore then validates it
## exactly like any local save. True when the local file was replaced.
func cloud_restore(path: String) -> bool:
	if not cloud_enabled():
		return false
	var name: String = path.get_file()
	if not backend.has_method("fileExists") or not bool(backend.call("fileExists", name)):
		return false
	var local_exists: bool = FileAccess.file_exists(path)
	if local_exists and backend.has_method("getFileTimestamp"):
		if int(backend.call("getFileTimestamp", name)) <= int(FileAccess.get_modified_time(path)):
			return false
	var size: int = int(backend.call("getFileSize", name)) if backend.has_method("getFileSize") else 0
	if size <= 0:
		return false
	var r = backend.call("fileRead", name, size)
	if not (r is Dictionary) or not (r.get("buf") is PackedByteArray):
		_log("cloud read of %s failed" % name)
		return false
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp: String = path + SaveStore.TMP_SUFFIX
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(r["buf"])
	f.close()
	if DirAccess.rename_absolute(tmp, path) != OK:
		DirAccess.remove_absolute(tmp)
		return false
	_log("restored %s from Steam Cloud" % name)
	return true


# --- Steam Input ---

## Registers the action manifest and starts Steam Input. Returns true when up.
## `manifest_path` is the absolute path of game_actions_<appid>.vdf (the depot
## root in a shipped build); "" skips registration (Steam Input then falls back
## to the manifest uploaded in Steamworks).
func input_init(manifest_path: String = "") -> bool:
	_input_ready = false
	if not available or not backend.has_method("inputInit"):
		_noop("inputInit")
		return false
	if manifest_path != "" and backend.has_method("setInputActionManifestFilePath"):
		backend.call("setInputActionManifestFilePath", manifest_path)
	backend.call("inputInit")
	_input_ready = true
	return true


## One poll of the connected controller. Returns {"pressed": [...], "released":
## [...]} of m0_* action names that changed state since the last poll. The
## action names are the InputMap actions, so the caller turns them into
## InputEventAction.
func poll_input() -> Dictionary:
	var out := {"pressed": [], "released": []}
	if not _input_ready:
		return out
	var pads = backend.call("getConnectedControllers") if backend.has_method("getConnectedControllers") else []
	if not (pads is Array) or pads.is_empty():
		return out
	_input_controller = int(pads[0])
	if _action_set == 0 and backend.has_method("getActionSetHandle"):
		_action_set = int(backend.call("getActionSetHandle", INPUT_ACTION_SET))
	if _action_set != 0 and backend.has_method("activateActionSet"):
		backend.call("activateActionSet", _input_controller, _action_set)
	for action in M0Loop.ALL_ACTIONS + [InputRemap.ACT_SETTINGS]:
		var handle: int = int(backend.call("getDigitalActionHandle", action))
		var data = backend.call("getDigitalActionData", _input_controller, handle)
		var down: bool = data is Dictionary and bool(data.get("state", false))
		var was: bool = bool(_input_down.get(action, false))
		if down and not was:
			out["pressed"].append(action)
		elif was and not down:
			out["released"].append(action)
		_input_down[action] = down
	return out
