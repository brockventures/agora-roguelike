extends RefCounted
## Unit tests for GamepadFocus controller navigation model (#22).

func test_init_defaults() -> String:
	var hud := OrbitalHUD.new()
	var focus := hud.gamepad_focus
	if focus == null:
		return "gamepad_focus not instantiated on OrbitalHUD"
	if focus.current_zone != GamepadFocus.Zone.ORDER_BOOK:
		return "initial zone should be ORDER_BOOK"
	if focus.active_side != GamepadFocus.OrderSide.BUY:
		return "initial side should be BUY"
	if focus.ladder_index != 0:
		return "initial ladder_index should be 0"
	if focus.order_qty != 1:
		return "initial order_qty should be 1"

	var snap: Dictionary = focus.to_dict()
	if snap["active_side"] != "BUY" or snap["ladder_index"] != 0:
		return "to_dict snapshot mismatch on defaults"
	return "ok"

func test_station_tabs_bumpers() -> String:
	var hud := OrbitalHUD.new()
	var focus := hud.gamepad_focus
	var navigated: Array = []
	focus.station_navigated.connect(func(s): navigated.append(s))

	# Initial station is "earth". RB steps forward: luna -> mars -> ceres -> earth
	if not focus.handle_action("rb") or hud.active_station != "luna":
		return "handle_action rb failed to advance to luna"
	focus.handle_action("rb")
	if hud.active_station != "mars":
		return "rb failed to advance to mars"
	focus.handle_action("rb")
	if hud.active_station != "ceres":
		return "rb failed to advance to ceres"
	focus.handle_action("rb")
	if hud.active_station != "earth":
		return "rb failed to wrap to earth"

	# LB steps backward: earth -> ceres
	focus.handle_action("lb")
	if hud.active_station != "ceres":
		return "lb failed to wrap backward to ceres"

	if navigated != ["luna", "mars", "ceres", "earth", "ceres"]:
		return "station_navigated signal sequence mismatch: %s" % str(navigated)
	return "ok"

func test_commodity_tiers_triggers() -> String:
	var hud := OrbitalHUD.new()
	var focus := hud.gamepad_focus
	var navigated: Array = []
	focus.commodity_navigated.connect(func(c): navigated.append(c))

	# Initial commodity is ORE (idx 3 in Transit.COMMODITIES).
	# RT steps forward: MACHINERY (idx 4) -> FRAG (idx 0)
	if not focus.handle_action("rt") or hud.active_commodity != "MACHINERY":
		return "rt failed to step to MACHINERY"
	focus.handle_action("rt")
	if hud.active_commodity != "FRAG":
		return "rt failed to wrap to FRAG"

	# LT steps backward: FRAG (idx 0) -> MACHINERY (idx 4)
	focus.handle_action("lt")
	if hud.active_commodity != "MACHINERY":
		return "lt failed to step backward to MACHINERY"

	return "ok"

func test_dpad_depth_ladder_snapping() -> String:
	var hud := OrbitalHUD.new()
	var focus := hud.gamepad_focus
	var snaps: Array = []
	focus.depth_level_snapped.connect(func(idx, side, px): snaps.append([idx, side, px]))

	if focus.ladder_index != 0:
		return "expected starting index 0"

	# Step down 0 -> 1 -> 2 -> 3 -> 4
	focus.handle_action("dpad_down")
	if focus.ladder_index != 1:
		return "dpad_down step to 1 failed"
	focus.handle_action("dpad_down")
	focus.handle_action("dpad_down")
	focus.handle_action("dpad_down")
	if focus.ladder_index != 4:
		return "dpad_down step to 4 failed"

	# Clamped at max depth (4)
	focus.handle_action("dpad_down")
	if focus.ladder_index != 4:
		return "dpad_down clamp at 4 failed"

	# Step up 4 -> 3 -> 2 -> 1 -> 0
	for i in 4:
		focus.handle_action("dpad_up")
	if focus.ladder_index != 0:
		return "dpad_up step back to 0 failed"

	# Clamped at min depth (0)
	focus.handle_action("dpad_up")
	if focus.ladder_index != 0:
		return "dpad_up clamp at 0 failed"

	if snaps.is_empty():
		return "depth_level_snapped signal never emitted"
	return "ok"

func test_dpad_side_toggle_and_quantity() -> String:
	var hud := OrbitalHUD.new()
	var focus := hud.gamepad_focus

	if focus.active_side != GamepadFocus.OrderSide.BUY:
		return "expected initial BUY"

	# D-pad right switches BUY to SELL
	focus.handle_action("dpad_right")
	if focus.active_side != GamepadFocus.OrderSide.SELL:
		return "dpad_right failed to switch to SELL"

	# D-pad right on SELL increments quantity
	focus.handle_action("dpad_right")
	if focus.order_qty != 2:
		return "dpad_right on SELL should increment quantity to 2, got %d" % focus.order_qty

	# D-pad left on SELL switches to BUY
	focus.handle_action("dpad_left")
	if focus.active_side != GamepadFocus.OrderSide.BUY:
		return "dpad_left failed to switch to BUY"

	# D-pad left on BUY decrements quantity
	focus.handle_action("dpad_left")
	if focus.order_qty != 1:
		return "dpad_left on BUY should decrement quantity to 1, got %d" % focus.order_qty

	# Lower bound clamp at 1
	focus.handle_action("dpad_left")
	if focus.order_qty != 1:
		return "quantity must not decrement below 1"

	return "ok"

func test_face_buttons_navigation() -> String:
	var hud := OrbitalHUD.new()
	var focus := hud.gamepad_focus

	# Button X toggles trading overlay
	focus.handle_action("button_x")
	if not hud.is_trading_overlay_open():
		return "button_x failed to open trading overlay"
	if focus.current_zone != GamepadFocus.Zone.TRADING_OVERLAY:
		return "zone should transition to TRADING_OVERLAY"

	# Button B closes overlay
	focus.handle_action("button_b")
	if hud.is_trading_overlay_open():
		return "button_b failed to close trading overlay"

	# Button B again sets zone to TACTICAL_MAP
	focus.handle_action("button_b")
	if focus.current_zone != GamepadFocus.Zone.TACTICAL_MAP:
		return "button_b failed to set zone to TACTICAL_MAP"

	# Button Y cycles sim speed
	var d := DoomsdayClock.new(36000, 0, 0, 0)
	var rc := RunController.new(null, 1, d)
	hud.bind_controller(rc)

	focus.handle_action("button_y")
	if rc.sim_clock.speed != 2:
		return "button_y failed to cycle speed to 2"

	# Start button toggles pause
	focus.handle_action("start")
	if not rc.sim_clock.paused:
		return "start button failed to pause clock"

	return "ok"

func test_face_button_a_order_execution_buy() -> String:
	var d := DoomsdayClock.new(36000, 0, 0, 0)
	var rc := RunController.new(null, 1, d)
	rc.docked_at = "ceres"
	rc.cargo_capacity = 100
	rc.cr = 50000
	rc.cargo = {"ORE": 0}
	var hud := OrbitalHUD.new(rc, "ceres", "ORE")
	var focus := hud.gamepad_focus

	focus.set_order_side(GamepadFocus.OrderSide.BUY)
	focus.snap_depth_level(0) # Best ask
	focus.set_quantity(5)

	var executed: Array = []
	focus.order_executed.connect(func(payload): executed.append(payload))

	var ok := focus.handle_action("button_a")
	if not ok:
		return "button_a execute order failed"
	if executed.size() != 1:
		return "order_executed signal failed to emit"

	var res: Dictionary = executed[0]
	if res["side"] != "BUY" or res["qty"] != 5 or res["commodity"] != "ORE":
		return "order execution payload mismatch"
	if rc.cr >= 50000:
		return "player CR should be deducted after buy"
	if int(rc.cargo["ORE"]) != 5:
		return "cargo ORE should be credited 5 units"

	return "ok"

func test_face_button_a_order_execution_sell() -> String:
	var d := DoomsdayClock.new(36000, 0, 0, 0)
	var rc := RunController.new(null, 1, d)
	rc.docked_at = "ceres"
	rc.cr = 1000
	rc.cargo = {"ORE": 10}
	var hud := OrbitalHUD.new(rc, "ceres", "ORE")
	var focus := hud.gamepad_focus

	focus.set_order_side(GamepadFocus.OrderSide.SELL)
	focus.snap_depth_level(0) # Best bid
	focus.set_quantity(3)

	var executed: Array = []
	focus.order_executed.connect(func(payload): executed.append(payload))

	var ok := focus.handle_action("button_a")
	if not ok:
		return "button_a execute sell order failed"
	if executed.size() != 1:
		return "order_executed signal failed to emit on sell"

	var res: Dictionary = executed[0]
	if res["side"] != "SELL" or res["qty"] != 3:
		return "sell payload mismatch"
	if int(rc.cargo["ORE"]) != 7:
		return "cargo ORE should be reduced from 10 to 7"
	if rc.cr <= 1000:
		return "player CR should increase after sell"

	return "ok"

func test_face_button_a_rejection_validation() -> String:
	var d := DoomsdayClock.new(36000, 0, 0, 0)
	var rc := RunController.new(null, 1, d)
	rc.cr = 5 # Very low CR
	rc.cargo = {"ORE": 0}
	var hud := OrbitalHUD.new(rc, "earth", "ORE")
	var focus := hud.gamepad_focus

	var rejections: Array = []
	focus.order_rejected.connect(func(reason, p): rejections.append(reason))

	# Attempt buy with insufficient CR
	focus.set_order_side(GamepadFocus.OrderSide.BUY)
	focus.set_quantity(10)
	var buy_ok := focus.handle_action("button_a")
	if buy_ok:
		return "buy with 5 CR should be rejected"
	if rejections.size() != 1 or rejections[0] != "INSUFFICIENT_CR":
		return "expected INSUFFICIENT_CR rejection, got: %s" % str(rejections)

	# Attempt sell with 0 cargo
	focus.set_order_side(GamepadFocus.OrderSide.SELL)
	focus.set_quantity(1)
	var sell_ok := focus.handle_action("button_a")
	if sell_ok:
		return "sell with 0 cargo should be rejected"
	if rejections.size() != 2 or rejections[1] != "INSUFFICIENT_CARGO":
		return "expected INSUFFICIENT_CARGO rejection, got: %s" % str(rejections)

	return "ok"

func test_input_event_translation() -> String:
	var hud := OrbitalHUD.new()
	var focus := hud.gamepad_focus

	# Test Joypad Button Event for RB
	var ev_rb := InputEventJoypadButton.new()
	ev_rb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	ev_rb.pressed = true
	if not focus.handle_input(ev_rb) or hud.active_station != "luna":
		return "InputEventJoypadButton RB translation failed"

	# Unpressed event should be ignored
	ev_rb.pressed = false
	if focus.handle_input(ev_rb):
		return "unpressed joypad event should return false"

	# Test Joypad Motion Event for RT
	var ev_rt := InputEventJoypadMotion.new()
	ev_rt.axis = JOY_AXIS_TRIGGER_RIGHT
	ev_rt.axis_value = 0.8
	if not focus.handle_input(ev_rt) or hud.active_commodity != "MACHINERY":
		return "InputEventJoypadMotion RT translation failed"

	# Test Key Event for Q (LB equivalent)
	var ev_key := InputEventKey.new()
	ev_key.keycode = KEY_Q
	ev_key.pressed = true
	if not focus.handle_input(ev_key) or hud.active_station != "earth":
		return "InputEventKey Q translation failed"

	return "ok"

func test_to_dict_roundtrip() -> String:
	var hud := OrbitalHUD.new(null, "mars", "FOOD")
	var focus := hud.gamepad_focus
	focus.set_order_side(GamepadFocus.OrderSide.SELL)
	focus.snap_depth_level(2)
	focus.set_quantity(4)

	var snap: Dictionary = hud.to_dict()
	if not snap.has("gamepad_focus"):
		return "OrbitalHUD.to_dict missing gamepad_focus key"

	var gf: Dictionary = snap["gamepad_focus"]
	if gf["active_side"] != "SELL" or gf["ladder_index"] != 2 or gf["order_qty"] != 4:
		return "gamepad_focus snapshot field mismatch: %s" % str(gf)

	return "ok"

func test_station_docking_and_arbitrage_gate() -> String:
	var d := DoomsdayClock.new(36000, 0, 0, 0)
	var rc := RunController.new(null, 1, d)
	rc.docked_at = "earth"
	rc.cr = 50000
	rc.cargo = {"ORE": 10}
	var hud := OrbitalHUD.new(rc, "earth", "ORE")
	var focus := hud.gamepad_focus

	var rejections: Array = []
	focus.order_rejected.connect(func(reason, p): rejections.append(reason))

	# Player is docked at earth. Switching HUD active station to ceres (e.g. via bumper RB)
	focus.handle_action("rb") # earth -> luna
	focus.handle_action("rb") # luna -> mars
	focus.handle_action("rb") # mars -> ceres
	if hud.active_station != "ceres":
		return "expected hud active station ceres"

	# Attempt buy order while viewing remote station
	focus.set_order_side(GamepadFocus.OrderSide.BUY)
	focus.set_quantity(1)
	var buy_ok := focus.handle_action("button_a")
	if buy_ok:
		return "arbitrage exploit: buy order at ceres while docked at earth should fail"
	if rejections.is_empty() or rejections[-1] != "NOT_DOCKED_AT_STATION":
		return "expected NOT_DOCKED_AT_STATION rejection, got: %s" % str(rejections)

	# Cycle back to docked station (earth)
	focus.handle_action("rb") # ceres -> earth
	if hud.active_station != "earth":
		return "expected hud active station earth"

	# Buy order at docked station should now succeed
	var docked_buy_ok := focus.handle_action("button_a")
	if not docked_buy_ok:
		return "buy order at docked station earth failed"

	return "ok"

func test_depth_available_quantity_and_cargo_capacity_gates() -> String:
	var d := DoomsdayClock.new(36000, 0, 0, 0)
	var rc := RunController.new(null, 1, d)
	rc.docked_at = "ceres"
	rc.cargo_capacity = 20
	rc.cr = 50000
	rc.cargo = {"ORE": 15} # 5 units remaining capacity
	var hud := OrbitalHUD.new(rc, "ceres", "ORE")
	var focus := hud.gamepad_focus

	var rejections: Array = []
	focus.order_rejected.connect(func(reason, p): rejections.append(reason))

	focus.set_order_side(GamepadFocus.OrderSide.BUY)
	focus.snap_depth_level(0) # Level 0 typically has ~5 units in default ladder

	# 1. Test cargo capacity gate: attempt to buy 10 units when remaining capacity is 5
	focus.set_quantity(10)
	# Even if ladder had 10, capacity is 5. But let's verify if available_qty or capacity trips first
	# If ladder available_qty is 5, EXCEEDS_AVAILABLE_QTY trips first.
	# Let's inspect ladder level 0 available qty
	var quote: Dictionary = focus.get_focused_quote()
	var avail: int = int(quote.get("available_qty", 0))

	# Test available quantity gate: request avail + 10 units
	focus.set_quantity(avail + 10)
	var qty_ok := focus.handle_action("button_a")
	if qty_ok:
		return "order exceeding available liquidity should fail"
	if rejections[-1] != "EXCEEDS_AVAILABLE_QTY":
		return "expected EXCEEDS_AVAILABLE_QTY, got %s" % str(rejections[-1])

	# Test cargo capacity gate:
	# Set capacity to 2, remaining capacity to 2 (total cargo 0), but request 4 units where ladder has 5
	rc.cargo["ORE"] = 0
	rc.cargo_capacity = 2 # only 2 slots
	focus.set_quantity(3) # ladder has 5 units available, but ship only holds 2
	var cap_ok := focus.handle_action("button_a")
	if cap_ok:
		return "order exceeding cargo capacity should fail"
	if rejections[-1] != "INSUFFICIENT_CARGO_CAPACITY":
		return "expected INSUFFICIENT_CARGO_CAPACITY, got %s" % str(rejections[-1])

	return "ok"
