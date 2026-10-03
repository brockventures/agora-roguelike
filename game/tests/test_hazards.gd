class_name TestHazards
extends RefCounted
## Tests for Hazards and HazardEngine ported from agora/hazards.py.

func test_parse_hazards() -> String:
	if Hazards.parse_hazards(null) != null:
		return "expected null for null input"
	if Hazards.parse_hazards(false) != null:
		return "expected null for false input"
	if Hazards.parse_hazards("0") != null:
		return "expected null for '0'"
	if Hazards.parse_hazards("off") != null:
		return "expected null for 'off'"
	if Hazards.parse_hazards("false") != null:
		return "expected null for 'false'"

	var p_def = Hazards.parse_hazards("1")
	if p_def == null or p_def[0] != 0.20 or p_def[1] != 0.25:
		return "expected default [0.20, 0.25] for '1', got %s" % [var_to_str(p_def)]

	var p_on = Hazards.parse_hazards("on")
	if p_on == null or p_on[0] != 0.20 or p_on[1] != 0.25:
		return "expected default [0.20, 0.25] for 'on', got %s" % [var_to_str(p_on)]

	var p_str = Hazards.parse_hazards("0.2,0.1")
	if p_str == null or absf(p_str[0] - 0.2) > 1e-6 or absf(p_str[1] - 0.1) > 1e-6:
		return "expected [0.2, 0.1] for '0.2,0.1', got %s" % [var_to_str(p_str)]

	var p_arr = Hazards.parse_hazards([1, 0])
	if p_arr == null or p_arr[0] != 1.0 or p_arr[1] != 0.0:
		return "expected [1.0, 0.0] for [1, 0], got %s" % [var_to_str(p_arr)]

	var p_dict = Hazards.parse_hazards({"delay": 0.15, "loss": 0.05})
	if p_dict == null or absf(p_dict[0] - 0.15) > 1e-6 or absf(p_dict[1] - 0.05) > 1e-6:
		return "expected [0.15, 0.05] for dict input, got %s" % [var_to_str(p_dict)]

	return "ok"

func test_off_by_default() -> String:
	var engine := Hazards.new()
	if engine.odds != null:
		return "engine.odds should be null by default"

	var q := engine.quote()
	if q["p_delay"] != 0.0 or q["p_loss"] != 0.0:
		return "quote should return 0.0 odds when disabled"

	var r := engine.roll(100)
	if r["delay"] != 0 or r["lost"] != 0 or not r["note"].is_empty():
		return "roll should return zero delay and loss when disabled"

	return "ok"

func test_quote_with_odds_and_scaling() -> String:
	var engine := Hazards.new([0.20, 0.25])
	var q := engine.quote(1.0, 1.0, 1.0, "amos", 1000)
	if absf(q["p_delay"] - 0.20) > 1e-6:
		return "expected p_delay 0.20, got %f" % q["p_delay"]
	if absf(q["p_loss"] - 0.25) > 1e-6:
		return "expected p_loss 0.25, got %f" % q["p_loss"]
	if q["expected_loss_qty"][0] != 100 or q["expected_loss_qty"][1] != 200:
		return "expected loss range [100, 200], got %s" % [var_to_str(q["expected_loss_qty"])]

	# Scaling test (e.g. ship upgrade halving odds and loss size)
	var q_scaled := engine.quote(0.5, 0.5, 0.5, "amos", 1000)
	if absf(q_scaled["p_delay"] - 0.10) > 1e-6:
		return "expected scaled p_delay 0.10, got %f" % q_scaled["p_delay"]
	if absf(q_scaled["p_loss"] - 0.125) > 1e-6:
		return "expected scaled p_loss 0.125, got %f" % q_scaled["p_loss"]
	if q_scaled["expected_loss_qty"][0] != 50 or q_scaled["expected_loss_qty"][1] != 100:
		return "expected scaled loss range [50, 100], got %s" % [var_to_str(q_scaled["expected_loss_qty"])]

	return "ok"

func test_certain_delay_adds_rounds_and_note() -> String:
	var engine := Hazards.new([1.0, 0.0], null, null, 42)
	for i in range(10):
		var r := engine.roll(50, 1.0, 1.0, 1.0, "vessel/1")
		if r["delay"] < 1 or r["delay"] > 3:
			return "expected delay in [1, 3], got %d" % r["delay"]
		if r["lost"] != 0:
			return "expected 0 lost when p_loss is 0.0, got %d" % r["lost"]
		if not ("storm on the route" in r["note"]):
			return "expected note to mention storm on the route, got '%s'" % r["note"]
	return "ok"

func test_certain_loss_fraction_clamped_10_20_pct() -> String:
	var engine := Hazards.new([0.0, 1.0], null, null, 1234)
	var qty := 1000
	for i in range(50):
		var r := engine.roll(qty, 1.0, 1.0, 1.0, "vessel/2")
		if r["delay"] != 0:
			return "expected 0 delay when p_delay is 0.0, got %d" % r["delay"]
		if r["lost"] < 100 or r["lost"] > 200:
			return "loss must be between 10% and 20% (100-200), got %d" % r["lost"]
		if not ("hull breach" in r["note"]):
			return "expected note to mention hull breach, got '%s'" % r["note"]
	return "ok"

func test_hazard_records_and_recent() -> String:
	var engine := Hazards.new()
	engine.record("tx-1", "amos", 5, 2, 0, "FRAG", "storm delay")
	engine.record("tx-2", "zero", 8, 0, 15, "FOOD", "hull breach")
	engine.record("tx-3", "marvin", 12, 1, 25, "ORE", "storm + breach")

	# Update existing record
	engine.record("tx-1", "amos", 5, 3, 0, "FRAG", "severe storm delay")

	var all_recent := engine.recent(0)
	if all_recent.size() != 3:
		return "expected 3 records, got %d" % all_recent.size()
	# Check order: round DESC (12, 8, 5)
	if all_recent[0]["round"] != 12 or all_recent[1]["round"] != 8 or all_recent[2]["round"] != 5:
		return "records not sorted by round DESC"
	if all_recent[2]["delay"] != 3:
		return "tx-1 record update failed, expected delay 3, got %d" % all_recent[2]["delay"]

	var recent_round_8 := engine.recent(8)
	if recent_round_8.size() != 2:
		return "expected 2 records since round 8, got %d" % recent_round_8.size()

	return "ok"

func test_cme_relay_interference() -> String:
	# 1. Inactive CME
	var r_off := Hazards.check_cme_relay_interference(false, "amos", "mars")
	if r_off["active"] != false or r_off["interfered"] != false or r_off["reason"] != "no_cme":
		return "expected no_cme when CME inactive"

	# 2. Admin bypass
	var r_admin := Hazards.check_cme_relay_interference(true, "admin", "mars")
	if r_admin["interfered"] != false or r_admin["reason"] != "admin_or_system":
		return "admin should bypass CME interference"

	# 3. Local docked bypass
	var r_docked := Hazards.check_cme_relay_interference(true, "amos", "mars", "earth", ["mars"])
	if r_docked["interfered"] != false or r_docked["reason"] != "local_docked":
		return "docked vessel should bypass CME interference"

	# 4. Hardened comm upgrade bypass
	var r_hard := Hazards.check_cme_relay_interference(true, "amos", "mars", "earth", [], true)
	if r_hard["interfered"] != false or r_hard["reason"] != "hardened_comm":
		return "hardened_comm should bypass CME interference"

	# 5. Inner corridor interference (Earth-Mars)
	var r_interf := Hazards.check_cme_relay_interference(true, "amos", "mars", "earth", [], false)
	if r_interf["interfered"] != true or r_interf["reason"] != "cme_relay_blackout":
		return "expected cme_relay_blackout for Earth-Mars corridor"
	if r_interf["corridor"] != "earth_mars":
		return "expected corridor 'earth_mars', got '%s'" % r_interf["corridor"]

	# 6. Outside corridor (e.g. Ceres to Ceres with no inner station involved)
	var r_out := Hazards.check_cme_relay_interference(true, "amos", "ceres", "ceres", [], false)
	if r_out["interfered"] != false or r_out["reason"] != "outside_corridor":
		return "expected outside_corridor for Ceres-Ceres, got %s" % [var_to_str(r_out)]

	return "ok"
