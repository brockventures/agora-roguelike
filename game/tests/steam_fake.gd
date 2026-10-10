class_name SteamFake
extends RefCounted
## In-memory stand-in for the GodotSteam singleton (#27): the same method names
## SteamService calls, with enough behaviour to assert on. Not a test itself
## (no test_ prefix), so the runner does not discover it.

var init_status: int = 0
var cloud_on: bool = true
var achievements: Dictionary = {}
var stat_values: Dictionary = {}
var store_calls: int = 0
var files: Dictionary = {}
var file_times: Dictionary = {}
var pads: Array = [7]
var digital: Dictionary = {}
var manifest: String = ""
var action_set_activations: int = 0


func steamInitEx(_app_id: int, _embed: bool) -> Dictionary:
	return {"status": init_status, "verbal": "fake"}

func run_callbacks() -> void:
	pass

func setAchievement(id: String) -> bool:
	achievements[id] = true
	return true

func setStatInt(id: String, v: int) -> bool:
	stat_values[id] = v
	return true

func storeStats() -> bool:
	store_calls += 1
	return true

func isCloudEnabledForApp() -> bool:
	return cloud_on

func isCloudEnabledForAccount() -> bool:
	return cloud_on

func fileWrite(name: String, data: PackedByteArray) -> bool:
	files[name] = data
	file_times[name] = int(Time.get_unix_time_from_system())
	return true

func fileExists(name: String) -> bool:
	return files.has(name)

func getFileSize(name: String) -> int:
	return (files[name] as PackedByteArray).size() if files.has(name) else 0

func getFileTimestamp(name: String) -> int:
	return int(file_times.get(name, 0))

func fileRead(name: String, _length: int) -> Dictionary:
	return {"ret": files.has(name), "buf": files.get(name, PackedByteArray())}

func fileDelete(name: String) -> bool:
	files.erase(name)
	return true

func setInputActionManifestFilePath(p: String) -> bool:
	manifest = p
	return true

func inputInit() -> bool:
	return true

func getConnectedControllers() -> Array:
	return pads

func getActionSetHandle(_n: String) -> int:
	return 99

func activateActionSet(_pad: int, _set: int) -> void:
	action_set_activations += 1

func getDigitalActionHandle(name: String) -> int:
	return name.hash()

func getDigitalActionData(_pad: int, handle: int) -> Dictionary:
	return {"state": bool(digital.get(handle, false)), "active": true}
