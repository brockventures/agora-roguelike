extends RefCounted
## Unit tests for the M0 game loop wiring (#84): trading against the resting
## book, SimClock speed and pause, tabs, input mapping, Chapter 11 overlay and
## audio hooks.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FRAME: float = 1.0 / 60.0 + 0.0001


func _loop(p_seed: int = 7) -> Dictionary:
	var rc := RunController.new(null, p_seed)
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	return {"rc": rc, "hud": hud, "loop": lp}


func _press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


func test_market_seeded_for_mars_and_earth() -> String:
	var ctx := _loop()
	var lp: M0Loop = ctx["loop"]
	var hud: OrbitalHUD = ctx["hud"]
	for st in ["earth", "mars"]:
		for c in Transit.COMMODITIES:
			if not lp.market.has_book(st, c):
				return "missing resting book %s:%s" % [st, c]
	if StationMarket.station_name("mars") != "Arcadia Foundries" or StationMarket.station_name("earth") != "Kennedy Elevator":
		return "station names wrong"
	if lp.market.has_book("ceres", "ORE"):
		return "ceres should not have a live book"
	hud.set_station("mars")
	var q: Dictionary = hud.get_market_quote()
	if q["station_name"] != "Arcadia Foundries":
		return "quote missing station name: %s" % str(q)
	var ladder: Dictionary = hud.get_order_book_ladder()
	if ladder["synthetic"] or ladder["asks"].size() != 5 or ladder["bids"].size() != 5:
		return "mars ladder should come from the live book: %s" % str(ladder)
	if float(ladder["best_ask"]) <= float(ladder["best_bid"]):
		return "book is crossed"
	return "ok"


func test_submit_fills_against_resting_book_and_updates_balances() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	lp.set_tab(M0Loop.Tab.MARKET)
	var ask: float = float(hud.get_order_book_ladder()["asks"][0]["price"])
	var ask_qty: int = int(hud.get_order_book_ladder()["asks"][0]["quantity"])
	var cr0: int = rc.cr
	hud.gamepad_focus.set_quantity(3)
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "submit rejected: %s" % hud.gamepad_focus.last_rejection_reason
	if rc.cr != cr0 - int(ask) * 3:
		return "CR after buy %d, expected %d" % [rc.cr, cr0 - int(ask) * 3]
	if int(rc.cargo.get("ORE", 0)) != 3:
		return "cargo not credited: %s" % str(rc.cargo)
	var after: Dictionary = hud.get_order_book_ladder()
	if int(after["asks"][0]["quantity"]) != ask_qty - 3:
		return "resting ask not consumed: %d -> %d" % [ask_qty, int(after["asks"][0]["quantity"])]
	# Sell two back into the bid.
	var cr1: int = rc.cr
	var bid: float = float(after["best_bid"])
	hud.gamepad_focus.set_order_side(GamepadFocus.OrderSide.SELL)
	hud.gamepad_focus.set_quantity(2)
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "sell rejected: %s" % hud.gamepad_focus.last_rejection_reason
	if rc.cr != cr1 + int(bid) * 2 or int(rc.cargo.get("ORE", 0)) != 1:
		return "sell balances wrong: cr %d cargo %s" % [rc.cr, str(rc.cargo)]
	if lp.total_fills != 2:
		return "fill count %d" % lp.total_fills
	return "ok"


func test_order_sweeps_multiple_levels_at_resting_prices() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	lp.set_tab(M0Loop.Tab.MARKET)
	var asks: Array = hud.get_order_book_ladder()["asks"]
	var qty: int = int(asks[0]["quantity"]) + 2
	hud.gamepad_focus.snap_depth_level(1)
	hud.gamepad_focus.set_quantity(qty)
	var expected: int = int(asks[0]["quantity"]) * int(asks[0]["price"]) + 2 * int(asks[1]["price"])
	var cr0: int = rc.cr
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "sweep rejected: %s" % hud.gamepad_focus.last_rejection_reason
	if cr0 - rc.cr != expected:
		return "sweep cost %d, expected %d" % [cr0 - rc.cr, expected]
	return "ok"


func test_receipt_reports_paid_price_not_limit() -> String:
	var ctx := _loop()
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	lp.set_tab(M0Loop.Tab.MARKET)
	var asks: Array = hud.get_order_book_ladder()["asks"]
	hud.gamepad_focus.snap_depth_level(1)
	hud.gamepad_focus.set_quantity(1)
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "rejected: %s" % hud.gamepad_focus.last_rejection_reason
	var o: Dictionary = hud.gamepad_focus.last_executed_order
	if not is_equal_approx(float(o["price"]), float(asks[0]["price"])):
		return "receipt price %s, paid best ask %s" % [str(o["price"]), str(asks[0]["price"])]
	if not is_equal_approx(float(o["limit_price"]), float(asks[1]["price"])):
		return "limit_price %s, expected %s" % [str(o["limit_price"]), str(asks[1]["price"])]
	return "ok"


func test_rejections_leave_book_and_balances_alone() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	lp.set_tab(M0Loop.Tab.MARKET)
	hud.gamepad_focus.set_order_side(GamepadFocus.OrderSide.SELL)
	if lp.dispatch_action(M0Loop.ACT_SUBMIT) or hud.gamepad_focus.last_rejection_reason != "INSUFFICIENT_CARGO":
		return "selling with an empty hold should be rejected"
	hud.gamepad_focus.set_order_side(GamepadFocus.OrderSide.BUY)
	hud.gamepad_focus.set_quantity(500)
	rc.cargo_capacity = 1000
	if lp.dispatch_action(M0Loop.ACT_SUBMIT) or hud.gamepad_focus.last_rejection_reason != "INSUFFICIENT_LIQUIDITY":
		return "order bigger than the book should be rejected, got %s" % hud.gamepad_focus.last_rejection_reason
	if rc.cr != Chapter11.FRESH_START_CR or not rc.cargo.is_empty():
		return "rejected order changed balances"
	hud.set_station("mars")
	hud.gamepad_focus.set_quantity(1)
	if lp.dispatch_action(M0Loop.ACT_SUBMIT) or hud.gamepad_focus.last_rejection_reason != "NOT_DOCKED_AT_STATION":
		return "trading at an undocked station should be rejected"
	return "ok"


func test_speed_toggle_cycle() -> String:
	var ctx := _loop()
	var lp: M0Loop = ctx["loop"]
	var hud: OrbitalHUD = ctx["hud"]
	var seen: Array = [lp.speed_label()]
	for i in 4:
		lp.dispatch_action(M0Loop.ACT_SPEED)
		seen.append(lp.speed_label())
		if hud.get_header_telemetry()["speed_label"] != lp.speed_label():
			return "HUD header out of step with clock at step %d" % i
	if seen != ["1x", "2x", "5x", "PAUSED", "1x"]:
		return "speed cycle was %s" % str(seen)
	return "ok"


func test_pause_halts_ticks_and_speed_scales_them() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	var t1: int = lp.advance(FRAME)
	if t1 != 1 or rc.sim_clock.total_ticks != 1:
		return "1x should run 1 tick per frame, got %d" % t1
	lp.dispatch_action(M0Loop.ACT_SPEED)
	var t2: int = lp.advance(FRAME)
	if t2 != 2:
		return "2x should run 2 ticks per frame, got %d" % t2
	lp.dispatch_action(M0Loop.ACT_SPEED)
	if lp.advance(FRAME) != 5:
		return "5x should run 5 ticks per frame"
	lp.dispatch_action(M0Loop.ACT_SPEED)
	var frozen: int = rc.sim_clock.total_ticks
	var doom: int = rc.doomsday.ticks_remaining
	if lp.advance(0.2) != 0 or rc.sim_clock.total_ticks != frozen or rc.doomsday.ticks_remaining != doom:
		return "paused clock still advanced"
	lp.dispatch_action(M0Loop.ACT_PAUSE)
	if rc.sim_clock.paused or lp.advance(FRAME) < 1:
		return "Start should resume the clock"
	lp.dispatch_action(M0Loop.ACT_PAUSE)
	if not rc.sim_clock.paused or lp.advance(FRAME) != 0:
		return "Start should pause the clock"
	return "ok"


func test_doomsday_ticks_follow_the_clock_into_header() -> String:
	var ctx := _loop()
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	var before: int = int(hud.get_header_telemetry()["ticks_remaining"])
	lp.advance(0.1)
	var after: int = int(hud.get_header_telemetry()["ticks_remaining"])
	if after >= before:
		return "header doomsday ticks did not fall (%d -> %d)" % [before, after]
	return "ok"


func test_tab_switching() -> String:
	var ctx := _loop()
	var lp: M0Loop = ctx["loop"]
	var hud: OrbitalHUD = ctx["hud"]
	var seen: Array = []
	lp.tab_changed.connect(func(n): seen.append(n))
	if lp.tab_name() != "MAP":
		return "should start on MAP"
	lp.dispatch_action(M0Loop.ACT_TAB_NEXT)
	if lp.tab_name() != "MARKET" or not hud.is_trading_overlay_open():
		return "RB should open MARKET and the board"
	lp.dispatch_action(M0Loop.ACT_TAB_NEXT)
	if lp.tab_name() != "FLEET" or hud.is_trading_overlay_open():
		return "RB should reach FLEET and close the board"
	lp.dispatch_action(M0Loop.ACT_TAB_NEXT)
	if lp.tab_name() != "MAP":
		return "tabs should wrap to MAP"
	lp.dispatch_action(M0Loop.ACT_TAB_PREV)
	if lp.tab_name() != "FLEET":
		return "LB should wrap back to FLEET"
	if seen != ["MARKET", "FLEET", "MAP", "FLEET"]:
		return "tab_changed sequence %s" % str(seen)
	return "ok"


func test_actions_map_to_focus_submit_and_cancel() -> String:
	var ctx := _loop()
	var lp: M0Loop = ctx["loop"]
	var hud: OrbitalHUD = ctx["hud"]
	var f: GamepadFocus = hud.gamepad_focus
	# Order-entry actions are inert outside the Market tab.
	if lp.dispatch_action(M0Loop.ACT_DOWN) or f.ladder_index != 0:
		return "d-pad should do nothing on MAP"
	lp.set_tab(M0Loop.Tab.MARKET)
	lp.dispatch_action(M0Loop.ACT_UP)
	lp.dispatch_action(M0Loop.ACT_UP)
	if f.ladder_index != 2 or f.active_side != GamepadFocus.OrderSide.BUY:
		return "up x2 on BUY should deepen the ask cursor to level 2, got %d" % f.ladder_index
	lp.dispatch_action(M0Loop.ACT_DOWN)
	if f.ladder_index != 1:
		return "down should step back toward the spread (level 1)"
	lp.dispatch_action(M0Loop.ACT_RIGHT)
	if f.active_side != GamepadFocus.OrderSide.BUY or f.order_qty != 2:
		return "right on BUY must raise quantity and keep BUY"
	lp.dispatch_action(M0Loop.ACT_LEFT)
	if f.active_side != GamepadFocus.OrderSide.BUY or f.order_qty != 1:
		return "left on BUY must lower quantity and keep BUY"
	lp.dispatch_action(M0Loop.ACT_COMMODITY_NEXT)
	if hud.active_commodity != "MACHINERY":
		return "commodity step failed: %s" % hud.active_commodity
	lp.dispatch_action(M0Loop.ACT_STATION_NEXT)
	if hud.active_station != "luna":
		return "station step failed: %s" % hud.active_station
	lp.dispatch_action(M0Loop.ACT_STATION_PREV)
	# B backs out of the Market tab to the Map.
	lp.dispatch_action(M0Loop.ACT_CANCEL)
	if lp.tab_name() != "MAP" or f.current_zone != GamepadFocus.Zone.TACTICAL_MAP:
		return "B should return to MAP with map focus"
	# A submits from the Market tab.
	lp.set_tab(M0Loop.Tab.MARKET)
	f.set_quantity(1)
	f.snap_depth_level(0)
	hud.set_commodity("ORE")
	var cr0: int = ctx["rc"].cr
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT) or ctx["rc"].cr >= cr0:
		return "A should submit the order"
	return "ok"


func test_input_actions_are_declared_with_pad_and_keyboard() -> String:
	for action in M0Loop.ALL_ACTIONS:
		if not InputMap.has_action(action):
			return "InputMap missing %s" % action
		var pad := false
		var key := false
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey:
				key = true
			elif ev is InputEventJoypadButton or ev is InputEventJoypadMotion:
				pad = true
		# The language button (View) became the settings button (#37); on a pad the
		# language is the Language row of the settings screen, the L key stays direct.
		if action == M0Loop.ACT_LOCALE:
			pad = true
		if not (pad and key):
			return "%s needs both a joypad and a keyboard binding (pad %s key %s)" % [action, pad, key]
	return "ok"


func test_real_input_events_drive_the_loop() -> String:
	var ctx := _loop()
	var lp: M0Loop = ctx["loop"]
	var hud: OrbitalHUD = ctx["hud"]
	var f: GamepadFocus = hud.gamepad_focus
	var rb := InputEventJoypadButton.new()
	rb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	rb.pressed = true
	if not lp.handle_input(rb) or lp.tab_name() != "MARKET":
		return "RB did not switch to MARKET"
	var y := InputEventJoypadButton.new()
	y.button_index = JOY_BUTTON_Y
	y.pressed = true
	lp.handle_input(y)
	if lp.speed_label() != "2x":
		return "Y did not toggle speed"
	var a := InputEventJoypadButton.new()
	a.button_index = JOY_BUTTON_A
	a.pressed = true
	var cr0: int = ctx["rc"].cr
	if not lp.handle_input(a) or ctx["rc"].cr >= cr0:
		return "A did not submit"
	var released := InputEventJoypadButton.new()
	released.button_index = JOY_BUTTON_A
	released.pressed = false
	if lp.handle_input(released):
		return "button release must not act"
	var down := InputEventKey.new()
	down.physical_keycode = KEY_S
	down.pressed = true
	lp.handle_input(down)
	if f.active_side != GamepadFocus.OrderSide.SELL or f.ladder_index != 0:
		return "S key from the best ask should cross the spread to the best bid"
	down.echo = true
	lp.handle_input(down)
	if f.ladder_index != 0:
		return "key echo must not repeat"
	# Left stick: one step per push, re-arms after returning to centre.
	var push := InputEventJoypadMotion.new()
	push.axis = JOY_AXIS_LEFT_Y
	push.axis_value = 1.0
	lp.handle_input(push)
	lp.handle_input(push)
	if f.ladder_index != 1:
		return "held stick should step once, ladder at %d" % f.ladder_index
	var centre := InputEventJoypadMotion.new()
	centre.axis = JOY_AXIS_LEFT_Y
	centre.axis_value = 0.0
	lp.handle_input(centre)
	lp.handle_input(push)
	if f.ladder_index != 2:
		return "stick should re-arm after centring, ladder at %d" % f.ladder_index
	var lt := InputEventJoypadMotion.new()
	lt.axis = JOY_AXIS_TRIGGER_RIGHT
	lt.axis_value = 1.0
	lp.handle_input(lt)
	if hud.active_station != "luna":
		return "RT did not step the station"
	return "ok"


func test_bankruptcy_halts_clock_and_raises_chapter11_overlay() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	var states: Array = []
	lp.overlay_changed.connect(func(s): states.append(s))
	rc.doomsday.principal_debt = 1000000
	lp.advance(FRAME)
	if not rc.pending_bankruptcy:
		return "insolvency should set pending_bankruptcy"
	if lp.overlay_state != M0Loop.OVERLAY_CHAPTER_11:
		return "overlay state %s, expected chapter11" % lp.overlay_state
	if not rc.sim_clock.paused:
		return "clock should be halted"
	var frozen: int = rc.sim_clock.total_ticks
	if lp.advance(0.2) != 0 or rc.sim_clock.total_ticks != frozen:
		return "clock advanced under the overlay"
	if lp.dispatch_action(M0Loop.ACT_SPEED) or lp.dispatch_action(M0Loop.ACT_PAUSE) or rc.sim_clock.paused == false:
		return "speed/pause must be locked while the overlay is up"
	if lp.dispatch_action(M0Loop.ACT_TAB_NEXT) or lp.tab_name() != "MAP":
		return "tabs must be locked while the overlay is up"
	var report_nonempty: bool = lp.dispatch_action(M0Loop.ACT_CHAPTER_11)
	if not report_nonempty:
		return "X should file Chapter 11"
	if lp.overlay_state != M0Loop.OVERLAY_NONE or rc.pending_bankruptcy:
		return "overlay should clear after filing"
	if rc.corp_number != 2 or rc.cr != rc.fresh_start_cr():
		return "a new corp should be founded with the fresh-start stake"
	if rc.sim_clock.paused or lp.advance(FRAME) < 1:
		return "clock should run again after filing"
	if states != [M0Loop.OVERLAY_CHAPTER_11, M0Loop.OVERLAY_NONE]:
		return "overlay sequence %s" % str(states)
	return "ok"


func test_chapter11_does_nothing_when_solvent() -> String:
	var ctx := _loop()
	var lp: M0Loop = ctx["loop"]
	if lp.dispatch_action(M0Loop.ACT_CHAPTER_11) or ctx["rc"].corp_number != 1:
		return "X must not file while solvent"
	return "ok"


func test_collapse_halts_clock_and_raises_overlay() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var lp: M0Loop = ctx["loop"]
	rc.doomsday.ticks_remaining = 1
	lp.advance(FRAME)
	if lp.overlay_state != M0Loop.OVERLAY_COLLAPSED or not rc.sim_clock.paused:
		return "collapse should halt the clock and raise the overlay (%s)" % lp.overlay_state
	return "ok"


func test_fill_triggers_market_bell() -> String:
	var ctx := _loop()
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	var heard: Array = []
	hud.tactile_audio.sound_played.connect(func(id, bus, _db, _pitch): heard.append([id, bus]))
	lp.set_tab(M0Loop.Tab.MARKET)
	hud.tactile_audio.advance_time(1.0)
	lp.dispatch_action(M0Loop.ACT_SUBMIT)
	if not heard.has([TactileAudio.MARKET_BELL, TactileAudio.BUS_MARKET]):
		return "fill did not ring the market bell: %s" % str(heard)
	# A rejected order bumps instead of ringing.
	heard.clear()
	hud.tactile_audio.advance_time(1.0)
	hud.gamepad_focus.set_order_side(GamepadFocus.OrderSide.SELL)
	hud.gamepad_focus.set_quantity(999)
	lp.dispatch_action(M0Loop.ACT_SUBMIT)
	for h in heard:
		if h[0] == TactileAudio.MARKET_BELL:
			return "rejected order must not ring the bell"
	return "ok"


func test_button_clicks_carry_pitch_jitter() -> String:
	var a := TactileAudio.new()
	var pitches: Array = []
	a.sound_played.connect(func(_id, _bus, _db, p): pitches.append(p))
	for i in 12:
		a.advance_time(0.037 * float(i + 1) + 0.1)
		a.play_sfx(TactileAudio.KEY_CLICK_DOWN)
	var distinct: Dictionary = {}
	for p in pitches:
		distinct[snappedf(p, 0.001)] = true
		if absf(p - 1.0) > TactileAudio.PITCH_JITTER_RANGE + 0.0001:
			return "pitch %f outside jitter range" % p
	if distinct.size() < 3:
		return "clicks should vary in pitch, saw %d distinct values" % distinct.size()
	return "ok"


func test_stage_change_modulates_drone() -> String:
	var ctx := _loop()
	var rc: RunController = ctx["rc"]
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	var audio: TactileAudio = hud.tactile_audio
	var events: Array = []
	audio.tension_level_changed.connect(func(stage, freq): events.append([stage, freq]))
	var vol0: float = audio.current_drone_volume_db
	var freq0: float = audio.current_drone_freq
	rc.doomsday.ticks_remaining = 27001
	lp.advance(FRAME)
	if events.size() != 1 or events[0][0] != DoomsdayClock.Stage.UNSTABLE:
		return "stage change did not reach the audio engine: %s" % str(events)
	if audio.current_drone_freq <= freq0 or audio.current_drone_volume_db <= vol0:
		return "drone should rise in pitch and volume on UNSTABLE"
	var last_vol: float = audio.current_drone_volume_db
	for stage in [DoomsdayClock.Stage.CRITICAL, DoomsdayClock.Stage.IMMINENT, DoomsdayClock.Stage.COLLAPSED]:
		audio.update_doomsday_stage(stage)
		if audio.current_drone_volume_db <= last_vol:
			return "drone volume must climb with each stage (stage %d)" % stage
		last_vol = audio.current_drone_volume_db
	if absf(audio.get_drone_pitch_scale() - TactileAudio.DRONE_STAGE_HZ[4] / TactileAudio.PAD_BASE_HZ) > 0.001:
		return "COLLAPSED pad pitch scale should follow DRONE_STAGE_HZ"
	return "ok"


func test_main_scene_runs_the_loop() -> String:
	var packed: PackedScene = load(MAIN_SCENE_PATH)
	var main: Variant = packed.instantiate()
	var rc: RunController = main.start_new_run(11)
	if main.controller != rc or main.hud.controller != rc or main.loop.controller != rc:
		main.free()
		return "start_new_run did not bind the controller everywhere"
	if not main.loop.market.has_book("mars", "FUEL") or not main.loop.market.has_book("earth", "FUEL"):
		main.free()
		return "Mars and Earth books missing"
	main._process(0.1)
	if rc.sim_clock.total_ticks < 5:
		main.free()
		return "_process did not advance the SimClock (%d ticks)" % rc.sim_clock.total_ticks
	var rb := InputEventJoypadButton.new()
	rb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	rb.pressed = true
	if not main.handle_input(rb) or main.loop.tab_name() != "MARKET":
		main.free()
		return "Main.handle_input did not reach the loop"
	var d: Dictionary = main.to_dict()
	if d["loop"]["tab"] != "MARKET" or d["hud"]["header"]["speed_label"] != "1x":
		main.free()
		return "to_dict missing loop state: %s" % str(d["loop"])
	main.initialize_systems(null)
	if main.loop.controller != null or main._process(0.1) != null:
		main.free()
		return "unbinding should leave the loop controller-less"
	main.free()
	return "ok"


func test_main_scene_audio_nodes_follow_the_drone() -> String:
	var packed: PackedScene = load(MAIN_SCENE_PATH)
	var main: Variant = packed.instantiate()
	main.start_new_run(3)
	main._setup_audio()
	if main.sfx_players.size() != main.SFX_POLYPHONY + main.PRIORITY_VOICES or main.drone_player == null:
		main.free()
		return "audio players not created"
	if main.drone_player.stream == null or main.drone_player.volume_db != main.tactile_audio.current_drone_volume_db:
		main.free()
		return "drone not primed from the NORMAL stage"
	var vol0: float = main.drone_player.volume_db
	main.tactile_audio.update_doomsday_stage(DoomsdayClock.Stage.CRITICAL)
	if main.drone_player.volume_db <= vol0 or absf(main.drone_player.pitch_scale - TactileAudio.DRONE_STAGE_HZ[2] / TactileAudio.PAD_BASE_HZ) > 0.001:
		main.free()
		return "drone player not modulated: vol %f pitch %f" % [main.drone_player.volume_db, main.drone_player.pitch_scale]
	main.free()
	return "ok"



func test_navigation_plays_exactly_one_sound() -> String:
	var ctx := _loop()
	var hud: OrbitalHUD = ctx["hud"]
	var lp: M0Loop = ctx["loop"]
	lp.set_tab(M0Loop.Tab.MARKET)
	var heard: Array = []
	hud.tactile_audio.sound_played.connect(func(id, _bus, _db, _pitch): heard.append(id))
	for action in [M0Loop.ACT_STATION_NEXT, M0Loop.ACT_COMMODITY_NEXT, M0Loop.ACT_UP, M0Loop.ACT_RIGHT, M0Loop.ACT_TAB_NEXT]:
		heard.clear()
		hud.tactile_audio.advance_time(1.0)
		if not lp.dispatch_action(action):
			return "%s was not handled" % action
		if heard.size() != 1:
			return "%s played %d sounds: %s" % [action, heard.size(), str(heard)]
	return "ok"


func test_default_bus_layout_declares_every_modelled_bus() -> String:
	var layout := load("res://default_bus_layout.tres") as AudioBusLayout
	if layout == null:
		return "res://default_bus_layout.tres missing"
	# The project loads it as AudioServer's layout at startup (default setting).
	for bus_name in TactileAudio.ALL_BUSES:
		if AudioServer.get_bus_index(bus_name) < 0:
			return "AudioServer has no bus '%s'" % bus_name
	var a := TactileAudio.new()
	for bus_name in TactileAudio.ALL_BUSES:
		var idx := AudioServer.get_bus_index(bus_name)
		if AudioServer.get_bus_send(idx) != "Master" and idx != 0:
			return "bus %s does not send to Master" % bus_name
		if idx != 0 and absf(AudioServer.get_bus_volume_db(idx) - a.get_bus_base_db(bus_name) + a.get_bus_base_db(TactileAudio.BUS_MASTER)) > 0.01:
			return "bus %s layout volume disagrees with the model default" % bus_name
	return "ok"


func test_main_scene_syncs_mutes_and_volumes_to_audio_server() -> String:
	var packed: PackedScene = load(MAIN_SCENE_PATH)
	var main: Variant = packed.instantiate()
	main.start_new_run(3)
	main._setup_audio()
	var ui_idx := AudioServer.get_bus_index(TactileAudio.BUS_UI)
	main.tactile_audio.set_bus_mute(TactileAudio.BUS_UI, true)
	var muted := AudioServer.is_bus_mute(ui_idx)
	main.tactile_audio.set_bus_mute(TactileAudio.BUS_UI, false)
	var unmuted := not AudioServer.is_bus_mute(ui_idx)
	main.tactile_audio.set_bus_volume(TactileAudio.BUS_UI, 0.5)
	var db := AudioServer.get_bus_volume_db(ui_idx)
	main.tactile_audio.set_bus_volume(TactileAudio.BUS_UI, 0.85)
	main.free()
	if not muted or not unmuted:
		return "model mute did not reach the AudioServer bus"
	if absf(db - linear_to_db(0.5)) > 0.01:
		return "model volume did not reach the AudioServer bus: %f" % db
	return "ok"


func test_priority_sounds_are_never_dropped_behind_clicks() -> String:
	var packed: PackedScene = load(MAIN_SCENE_PATH)
	var main: Variant = packed.instantiate()
	main.start_new_run(3)
	main._setup_audio()
	var routine: int = main.SFX_POLYPHONY
	var total: int = main.sfx_players.size()
	if total != routine + main.PRIORITY_VOICES:
		main.free()
		return "expected reserved priority voices"
	var busy: Array[bool] = []
	busy.resize(total)
	busy.fill(false)
	for i in routine:
		busy[i] = true
	var routine_drop: int = main.choose_sfx_voice(false, busy)
	var alarm_voice: int = main.choose_sfx_voice(true, busy)
	# All voices busy: an alarm steals the oldest routine voice, never a priority one.
	busy.fill(true)
	main._voice_order.assign([5, 2, 9, 7, 3, 4])
	main._voice_priority.assign([false, false, false, false, true, true])
	var stolen: int = main.choose_sfx_voice(true, busy)
	var routine_none: int = main.choose_sfx_voice(false, busy)
	var is_prio: bool = main.tactile_audio.is_priority_sound(TactileAudio.ALARM_CRITICAL) and main.tactile_audio.is_priority_sound(TactileAudio.ALARM_WARNING) and main.tactile_audio.is_priority_sound(TactileAudio.MARKET_BELL) and not main.tactile_audio.is_priority_sound(TactileAudio.KEY_CLICK_DOWN)
	main.free()
	if routine_drop != -1:
		return "routine sound should be dropped when its voices are busy, got %d" % routine_drop
	if alarm_voice < routine:
		return "alarm must take a reserved voice when clicks hold the routine ones, got %d" % alarm_voice
	if stolen != 1:
		return "with every voice busy an alarm must steal the oldest routine voice (1), got %d" % stolen
	if routine_none != -1:
		return "routine sounds must not steal"
	if not is_prio:
		return "priority set wrong"
	return "ok"


func test_market_board_marks_selected_commodity_and_hints_right_stick() -> String:
	var packed: PackedScene = load(MAIN_SCENE_PATH)
	var main: Variant = packed.instantiate()
	main.start_new_run(3)
	main.hud.set_commodity("ORE")
	main.loop.set_tab(M0Loop.Tab.MARKET)
	main._resolve_child_nodes()
	main._build_readouts()
	main._refresh_readouts()
	var rows: PackedStringArray = main.panel_text(main.market_modal).split("\n")
	var marked: Array = []
	for i in rows.size() - 1:
		if rows[i] == Loc.t("HUD_LADDER_MARKER"):
			marked.append(rows[i + 1])
	var ok_marker: bool = marked.size() == 1 and "ORE" in marked[0]
	var hint_ok: bool = "R-STICK" in main.panel_text(main.sidebar_panel) and "R-STICK commodity" in main.panel_text(main.market_modal)
	main.free()
	if not ok_marker:
		return "selected commodity not uniquely marked at its row: %s" % str(marked)
	if not hint_ok:
		return "right-stick commodity control missing from the hints"
	return "ok"
