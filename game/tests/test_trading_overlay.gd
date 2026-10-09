extends RefCounted
## Unit tests for TradingOverlay modal state and telemetry binding (#21).

func test_overlay_visibility_lifecycle() -> String:
	var o := TradingOverlay.new()
	if o.is_visible or o.active_station != "earth":
		return "initial visibility or active station mismatch"

	var opened: Array = []
	var closed: Array = []
	o.overlay_opened.connect(func(st): opened.append(st))
	o.overlay_closed.connect(func(): closed.append(true))

	if not o.open_overlay("ceres"):
		return "open_overlay failed"
	if not o.is_visible or o.active_station != "ceres" or opened != ["ceres"]:
		return "open_overlay state/signal mismatch"

	o.close_overlay()
	if o.is_visible or closed.size() != 1:
		return "close_overlay state/signal mismatch"

	# Toggle tests
	var is_open := o.toggle_overlay("mars")
	if not is_open or not o.is_visible or o.active_station != "mars":
		return "toggle_overlay to open failed"

	is_open = o.toggle_overlay()
	if is_open or o.is_visible:
		return "toggle_overlay to close failed"

	return "ok"

func test_station_and_commodity_tabs() -> String:
	var o := TradingOverlay.new()
	var station_signals: Array = []
	var commodity_signals: Array = []
	o.station_changed.connect(func(st): station_signals.append(st))
	o.commodity_selected.connect(func(c): commodity_signals.append(c))

	if not o.set_station("mars"):
		return "set_station(mars) failed"
	if o.active_station != "mars" or station_signals != ["mars"]:
		return "active station or signal mismatch"

	# Invalid station rejected
	if o.set_station("jupiter"):
		return "invalid station should be rejected"

	if not o.set_commodity("ORE"):
		return "set_commodity(ORE) failed"
	if o.selected_commodity != "ORE" or commodity_signals != ["ORE"]:
		return "selected commodity or signal mismatch"

	# Normalization helper handles lowercase/aliases
	if not o.set_commodity("banana"):
		return "set_commodity(banana) should normalize to FRAG"
	if o.selected_commodity != "FRAG":
		return "BANANA did not normalize to FRAG"

	# Invalid commodity rejected
	if o.set_commodity("DIAMONDS"):
		return "invalid commodity should be rejected"

	return "ok"

func test_financial_telemetry_from_controller() -> String:
	var d := DoomsdayClock.new(36000, 15000, 10, 500)
	var rc := RunController.new(null, 100, d)
	rc.cr = 8500
	var o := TradingOverlay.new(rc)

	var fin := o.get_financial_summary()
	if fin["cr"] != 8500 or fin["principal_debt"] != 15000:
		return "cr or debt mismatch in summary"
	if fin["stage"] != DoomsdayClock.Stage.NORMAL or fin["stage_name"] != "NORMAL":
		return "stage telemetry mismatch"
	if bool(fin["pending_bankruptcy"]) or bool(fin["is_collapsed"]):
		return "pending or collapsed should be false"

	# Advance until unstable stage (at 75% remaining = 27000 ticks)
	d.ticks_remaining = 26900
	d.stage = DoomsdayClock.Stage.UNSTABLE
	var unstable_fin := o.get_financial_summary()
	if unstable_fin["stage_name"] != "UNSTABLE":
		return "stage_name failed to reflect UNSTABLE"

	return "ok"

func test_market_quote_data() -> String:
	var o := TradingOverlay.new(null, "ceres")
	o.set_commodity("FUEL")

	var quote := o.get_active_market_quote()
	if quote["station"] != "ceres" or quote["commodity"] != "FUEL":
		return "quote station/commodity mismatch"

	# Ceres FUEL equilibrium price is 24.5
	if absf(float(quote["base_price_cr"]) - 24.5) > 0.01:
		return "ceres FUEL base price mismatch: %f" % float(quote["base_price_cr"])
	if bool(quote["is_perishable"]):
		return "FUEL is not perishable"

	# Switch to Earth FOOD
	o.set_station("earth")
	o.set_commodity("FOOD")
	var food_quote := o.get_active_market_quote()
	if not bool(food_quote["is_perishable"]):
		return "FOOD must be flagged perishable"

	return "ok"

func test_cargo_hold_reflection() -> String:
	var d := DoomsdayClock.new(36000, 0, 0, 0)
	var rc := RunController.new(null, 1, d)
	rc.cargo = {"ORE": 42, "FRAG": 7}
	var o := TradingOverlay.new(rc)

	o.set_commodity("ORE")
	if o.get_cargo_hold_qty() != 42:
		return "cargo hold ORE qty mismatch"

	o.set_commodity("FRAG")
	if o.get_cargo_hold_qty() != 7:
		return "cargo hold FRAG qty mismatch"

	o.set_commodity("FUEL")
	if o.get_cargo_hold_qty() != 0:
		return "unheld commodity should return 0"

	return "ok"

func test_overlay_to_dict_roundtrip() -> String:
	var o := TradingOverlay.new(null, "mars")
	o.open_overlay("mars")
	o.set_commodity("MACHINERY")
	var d := o.to_dict()

	if not bool(d["is_visible"]) or d["active_station"] != "mars":
		return "dict visibility/station mismatch"
	if d["selected_commodity"] != "MACHINERY":
		return "dict commodity mismatch"
	if not d.has("financials") or not d.has("market_quote"):
		return "dict telemetry keys missing"

	return "ok"

func test_financial_summary_names_every_doomsday_stage() -> String:
	var rc := RunController.new(null, 5)
	var o := TradingOverlay.new(rc)
	var names := {
		DoomsdayClock.Stage.NORMAL: "NORMAL",
		DoomsdayClock.Stage.UNSTABLE: "UNSTABLE",
		DoomsdayClock.Stage.CRITICAL: "CRITICAL",
		DoomsdayClock.Stage.IMMINENT: "IMMINENT",
		DoomsdayClock.Stage.COLLAPSED: "COLLAPSED",
	}
	for stage in names:
		rc.doomsday.stage = stage
		var fs := o.get_financial_summary()
		if fs["stage_name"] != names[stage] or fs["stage"] != int(stage):
			return "stage %d reported as '%s', expected %s" % [int(stage), fs["stage_name"], names[stage]]
	return "ok"
