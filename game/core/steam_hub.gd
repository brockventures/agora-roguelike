extends Node
## Autoload "SteamHub" (#27). Starts the optional Steam layer and pumps it. The
## autoload is deliberately not named `Steam`: that is the GodotSteam singleton.
## With no GodotSteam present this does nothing visible: initialize() logs once
## and every later call is a no-op.


func _ready() -> void:
	var svc: SteamService = SteamService.shared()
	if svc.initialize():
		svc.input_init(OS.get_executable_path().get_base_dir().path_join("game_actions_%d.vdf" % svc.app_id))


func _process(_delta: float) -> void:
	var svc: SteamService = SteamService.shared()
	if not svc.available:
		return
	svc.run_callbacks()
	var edges: Dictionary = svc.poll_input()
	for a in edges["pressed"]:
		_send(str(a), true)
	for a in edges["released"]:
		_send(str(a), false)


static func _send(action: String, pressed: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _exit_tree() -> void:
	SteamService.set_shared(null)
