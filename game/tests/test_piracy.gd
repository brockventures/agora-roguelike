class_name TestPiracy
extends RefCounted
## Tests for Piracy and PiracyDesk ported from agora/piracy.py.

func test_parse_piracy() -> String:
	if Piracy.parse_piracy(null) != null:
		return "expected null for null input"
	if Piracy.parse_piracy(false) != null:
		return "expected null for false input"
	if Piracy.parse_piracy("0") != null:
		return "expected null for '0'"
	if Piracy.parse_piracy("off") != null:
		return "expected null for 'off'"
	if Piracy.parse_piracy("false") != null:
		return "expected null for 'false'"

	var p_true = Piracy.parse_piracy(true)
	if p_true == null or p_true[0] != 0.15 or p_true[1] != 0.04:
		return "expected default [0.15, 0.04] for true, got %s" % [var_to_str(p_true)]

	var p_def = Piracy.parse_piracy("1")
	if p_def == null or p_def[0] != 0.15 or p_def[1] != 0.04:
		return "expected default [0.15, 0.04] for '1', got %s" % [var_to_str(p_def)]

	var p_str = Piracy.parse_piracy("0.15,0.04")
	if p_str == null or absf(p_str[0] - 0.15) > 1e-6 or absf(p_str[1] - 0.04) > 1e-6:
		return "expected [0.15, 0.04] for '0.15,0.04', got %s" % [var_to_str(p_str)]

	var p_dict = Piracy.parse_piracy({"belt": 0.20, "inner": 0.05})
	if p_dict == null or absf(p_dict[0] - 0.20) > 1e-6 or absf(p_dict[1] - 0.05) > 1e-6:
		return "expected [0.20, 0.05] for dict input, got %s" % [var_to_str(p_dict)]

	# Zero odds return null
	if Piracy.parse_piracy([0, 0]) != null:
		return "expected null for [0, 0]"
	if Piracy.parse_piracy("0.0, 0.0") != null:
		return "expected null for '0.0, 0.0'"

	# Partly bad inputs return null matching Python ValueError handling
	if Piracy.parse_piracy("0.15,abc") != null:
		return "expected null for '0.15,abc'"
	if Piracy.parse_piracy({"belt": "x", "inner": 0.04}) != null:
		return "expected null for invalid belt in dict"
	if Piracy.parse_piracy([0.15, "bad"]) != null:
		return "expected null for invalid element in array"

	return "ok"

func test_cargo_value_and_escort_fee() -> String:
	# REF_PRICE: FRAG: 15.0, ORE: 19.25, FOOD: 19.3, FUEL: 16.0, MACHINERY: 21.2
	if Piracy.cargo_value("FRAG", 1000) != 15000:
		return "expected 15000 for 1000 FRAG, got %d" % Piracy.cargo_value("FRAG", 1000)
	if Piracy.cargo_value("ORE", 500) != 9625:
		return "expected 9625 for 500 ORE, got %d" % Piracy.cargo_value("ORE", 500)
	if Piracy.cargo_value("FOOD", 100) != 1930:
		return "expected 1930 for 100 FOOD, got %d" % Piracy.cargo_value("FOOD", 100)
	if Piracy.cargo_value("MACHINERY", 100) != 2120:
		return "expected 2120 for 100 MACHINERY, got %d" % Piracy.cargo_value("MACHINERY", 100)
	if Piracy.cargo_value("FUEL", 100) != 1600:
		return "expected 1600 for 100 FUEL, got %d" % Piracy.cargo_value("FUEL", 100)

	# Escort fee is 4% of cargo value
	if Piracy.escort_fee("FRAG", 1000) != 600:
		return "expected 600 CR escort fee for 1000 FRAG, got %d" % Piracy.escort_fee("FRAG", 1000)

	return "ok"

func test_raid_key_formatting() -> String:
	var c := {
		"tolled": true,
		"hot": false,
		"value_mult": 1.5,
		"privateers": false,
		"armor_tier": 0,
		"stealth_tier": 0,
		"salvage_surge": false,
		"escort": false,
	}
	var k := Piracy.raid_key("amos/1", c)
	if k != "amos/1|belt|cool|v1.5|free|a0|s0|bare":
		return "expected 'amos/1|belt|cool|v1.5|free|a0|s0|bare', got '%s'" % k

	var c_escort := c.duplicate()
	c_escort["escort"] = true
	c_escort["hot"] = true
	var k_escort := Piracy.raid_key("vessel-9", c_escort)
	if k_escort != "vessel-9|belt|hot|v1.5|free|a0|s0|escort":
		return "expected 'vessel-9|belt|hot|v1.5|free|a0|s0|escort', got '%s'" % k_escort

	return "ok"

func test_chance_calculation_and_escort_cut() -> String:
	var desk := Piracy.new([0.15, 0.04], null, null, 7)
	# Override hot station to luna for predictable test
	var c_belt := desk.chance("amos", "ceres", "mars", true, "FRAG", 1000, false, 1)
	if absf(c_belt["base"] - 0.15) > 1e-6:
		return "expected base 0.15 for tolled route, got %f" % c_belt["base"]
	if absf(c_belt["value_mult"] - 1.5) > 1e-6:
		return "expected value_mult 1.5 for 15,000 CR cargo, got %f" % c_belt["value_mult"]

	# Escorted trip cuts odds by 75%
	var c_esc := desk.chance("amos", "ceres", "mars", true, "FRAG", 1000, true, 1)
	if absf(c_esc["odds"] - roundf(c_belt["odds"] * (1.0 - Piracy.ESCORT_CUT) * 10000.0) / 10000.0) > 1e-4:
		return "escort should cut odds by 75%%, unescorted=%f, escorted=%f" % [c_belt["odds"], c_esc["odds"]]

	return "ok"

func test_departure_roll_and_demand_creation() -> String:
	# Certain raid odds
	var desk := Piracy.new([1.0, 1.0], null, null, 42)
	var r = desk.roll_departure("tx-1", "amos", "ceres", "mars", true, "FRAG", 1000, false, 1)
	if r == null or not r["raided"]:
		return "expected transit to be raided under 100% odds"

	var demand: Dictionary = r["demand"]
	if demand["status"] != "pending":
		return "expected demand status to be 'pending', got '%s'" % demand["status"]
	# Ransom is 15% of 15,000 CR cargo value = 2250 CR
	if demand["ransom"] != 2250:
		return "expected ransom 2250 CR, got %d" % demand["ransom"]
	# Surrender is 25% of 1000 units = 250 units
	if demand["surrender_qty"] != 250:
		return "expected surrender_qty 250, got %d" % demand["surrender_qty"]

	return "ok"

func test_respond_pay_choice() -> String:
	var desk := Piracy.new([1.0, 1.0], null, null, 10)
	desk.roll_departure("tx-pay", "amos", "ceres", "mars", true, "FRAG", 1000, false, 1)

	# Reject when short on credits
	var r_short := desk.respond("amos", "tx-pay", "pay", 100)
	if r_short["kind"] != "reject" or r_short["payload"]["reason"] != "insufficient_credits":
		return "expected insufficient_credits reject when credits < ransom"

	# Success with sufficient credits
	var r_ok := desk.respond("amos", "tx-pay", "pay", 5000)
	if r_ok["kind"] != "piracy_respond_ok":
		return "expected piracy_respond_ok"
	var p: Dictionary = r_ok["payload"]
	if p["status"] != "paid" or p["cr_taken"] != 2250:
		return "expected status 'paid' and cr_taken 2250"

	# Already resolved reject
	var r_again := desk.respond("amos", "tx-pay", "pay", 5000)
	if r_again["kind"] != "reject" or r_again["payload"]["reason"] != "already_resolved":
		return "expected already_resolved reject on duplicate response"

	return "ok"

func test_respond_surrender_choice() -> String:
	var desk := Piracy.new([1.0, 1.0], null, null, 20)
	desk.roll_departure("tx-surr", "amos", "ceres", "mars", true, "FRAG", 1000, false, 1)

	var r := desk.respond("amos", "tx-surr", "surrender")
	if r["kind"] != "piracy_respond_ok":
		return "expected piracy_respond_ok"
	var p: Dictionary = r["payload"]
	if p["status"] != "surrendered" or p["qty_taken"] != 250:
		return "expected status 'surrendered' and qty_taken 250"
	if p["fenced_at"] != "ceres":
		return "expected fenced_at 'ceres', got '%s'" % str(p["fenced_at"])

	return "ok"

func test_respond_fight_choice_escape_and_loss() -> String:
	var desk := Piracy.new([1.0, 1.0], null, null, 30)

	# Case 1: Escaped
	desk.roll_departure("tx-fight-1", "amos", "ceres", "mars", true, "FRAG", 1000, false, 1)
	desk.bags.force("escape", true)
	var r_esc := desk.respond("amos", "tx-fight-1", "fight")
	var p_esc: Dictionary = r_esc["payload"]
	if p_esc["status"] != "escaped" or p_esc["qty_taken"] != 0 or p_esc["delay"] != 0:
		return "expected escaped fight to have 0 lost and 0 delay"

	# Case 2: Lost fight
	desk.roll_departure("tx-fight-2", "amos", "ceres", "mars", true, "FRAG", 1000, false, 1)
	desk.bags.force("escape", false)
	var r_lost := desk.respond("amos", "tx-fight-2", "fight")
	var p_lost: Dictionary = r_lost["payload"]
	if p_lost["status"] != "lost":
		return "expected lost fight status, got '%s'" % p_lost["status"]
	# 50% cargo loss = 500 units
	if p_lost["qty_taken"] != 500:
		return "expected 500 units lost in fight, got %d" % p_lost["qty_taken"]
	if p_lost["delay"] < 1 or p_lost["delay"] > 2:
		return "expected fight delay in [1, 2], got %d" % p_lost["delay"]

	return "ok"

func test_privateers_hire_and_records_intact_across_reset() -> String:
	var desk := Piracy.new([0.15, 0.04], null, null, 50)

	# Cannot target self
	var r_self := desk.hire("amos", "amos", 1)
	if r_self["kind"] != "reject" or r_self["payload"]["reason"] != "invalid_target":
		return "expected invalid_target for self-targeting"

	# Successful hire
	var r_hire := desk.hire("amos", "marvin", 1, 1000)
	if r_hire["kind"] != "privateer_hire_ok":
		return "expected privateer_hire_ok, got %s" % [var_to_str(r_hire)]

	var c = desk.active_contract("marvin", 5)
	if c == null or c["sponsor"] != "amos":
		return "expected active contract for amos against marvin"

	# One contract at a time
	var r_dup := desk.hire("amos", "zero", 1, 1000)
	if r_dup["kind"] != "reject" or r_dup["payload"]["reason"] != "contract_active":
		return "expected contract_active reject on second contract"

	# Reset leaves records and contracts intact matching Python referee
	desk.reset(999)
	var c_after = desk.active_contract("marvin", 5)
	if c_after == null or c_after["sponsor"] != "amos":
		return "reset() must leave active contracts intact"

	return "ok"

func test_fight_escape_draws_from_raided_vessel_id() -> String:
	var desk := Piracy.new([1.0, 1.0], null, null, 77)
	# Raiding amos/2
	var r = desk.roll_departure("tx-ship2", "amos", "ceres", "mars", true, "FRAG", 1000, false, 1, "amos/2")
	if r == null or not r["raided"]:
		return "expected raid on 100% odds"
	if r["demand"]["vessel_id"] != "amos/2":
		return "expected demand vessel_id 'amos/2', got '%s'" % str(r["demand"]["vessel_id"])

	# Fight choice: should draw from amos/2's bag (not forced, so stats are tracked)
	var resp := desk.respond("amos", "tx-ship2", "fight")
	if resp["kind"] != "piracy_respond_ok":
		return "expected piracy_respond_ok"

	var stats_ship2 = desk.bags.stats("escape", "amos/2")
	if stats_ship2["draws"] != 1:
		return "expected 1 draw from amos/2 escape bag, got %d" % stats_ship2["draws"]

	var stats_ship1 = desk.bags.stats("escape", "amos/1")
	if stats_ship1["draws"] != 0:
		return "expected 0 draws from amos/1 escape bag (cross-ship bleed!), got %d" % stats_ship1["draws"]

	return "ok"

func test_fight_loss_base_uses_manifest_qty_not_hold_qty() -> String:
	var desk := Piracy.new([1.0, 1.0], null, null, 88)
	# Manifest is 40 units, hold has 100 units
	desk.roll_departure("tx-loss-base", "amos", "ceres", "mars", true, "FRAG", 40, false, 1, "amos/1", null, 100)
	desk.bags.force("escape", false)

	var resp := desk.respond("amos", "tx-loss-base", "fight")
	if resp["kind"] != "piracy_respond_ok":
		return "expected piracy_respond_ok"
	var p: Dictionary = resp["payload"]
	if p["status"] != "lost":
		return "expected lost fight status"
	# 50% of 40 manifest units = 20 units (not 50% of 100 hold units = 50)
	if p["qty_taken"] != 20:
		return "expected 20 units lost from manifest qty, got %d" % p["qty_taken"]

	return "ok"

func test_privateer_trace_fine_capped_at_sponsor_cr() -> String:
	var desk := Piracy.new([1.0, 1.0], null, null, 99)
	desk.hire("amos", "marvin", 1, 1000)

	# Case 1: Sponsor has 500 CR, fine capped at 500 CR (base is 1500)
	desk.bags.force("trace", true)
	var r_cap = desk.roll_departure("tx-trace-500", "marvin", "ceres", "mars", true, "FRAG", 1000, false, 1, "marvin/1", null, null, 1.0, 0, 1.0, 0, false, 500)
	if r_cap["demand"]["traced"] != 1:
		return "expected traced == 1"
	if r_cap["demand"]["fine"] != 500:
		return "expected trace fine capped at 500 CR, got %d" % r_cap["demand"]["fine"]

	# Case 2: Broke sponsor (0 CR), fine capped at 0 CR
	desk.bags.force("trace", true)
	var r_zero = desk.roll_departure("tx-trace-0", "marvin", "ceres", "mars", true, "FRAG", 1000, false, 1, "marvin/1", null, null, 1.0, 0, 1.0, 0, false, 0)
	if r_zero["demand"]["fine"] != 0:
		return "expected trace fine capped at 0 CR, got %d" % r_zero["demand"]["fine"]

	# Case 3: Rich sponsor (5000 CR), full 1500 fine charged
	desk.bags.force("trace", true)
	var r_full = desk.roll_departure("tx-trace-rich", "marvin", "ceres", "mars", true, "FRAG", 1000, false, 1, "marvin/1", null, null, 1.0, 0, 1.0, 0, false, 5000)
	if r_full["demand"]["fine"] != 1500:
		return "expected full 1500 fine, got %d" % r_full["demand"]["fine"]

	return "ok"

func test_hot_station_replay_and_override() -> String:
	var desk := Piracy.new([0.15, 0.04], null, null, 123)

	# hot_override in chance
	var c_hot := desk.chance("amos", "earth", "mars", false, "FRAG", 1000, false, 1, null, false, 1.0, 0, 1.0, 0, false, "earth")
	if not c_hot["hot"]:
		return "expected route to be hot when hot_override is 'earth'"

	var c_cool := desk.chance("amos", "earth", "mars", false, "FRAG", 1000, false, 1, null, false, 1.0, 0, 1.0, 0, false, "luna")
	if c_cool["hot"]:
		return "expected route to be cool when hot_override is 'luna'"

	# hot_override in roll_departure
	var r = desk.roll_departure("tx-hot", "amos", "earth", "mars", false, "FRAG", 1000, false, 1, "amos/1", null, null, 1.0, 0, 1.0, 0, false, null, 1.0, "earth")
	if r["hot_station"] != "earth":
		return "expected hot_station 'earth', got '%s'" % r["hot_station"]
	if not r["hot_route"]:
		return "expected hot_route true"

	return "ok"

func test_hire_sponsor_casing_preserved() -> String:
	var desk := Piracy.new([0.15, 0.04], null, null, 145)
	var r := desk.hire("AmosCorp", "target_corp", 1, 1000)
	if r["kind"] != "privateer_hire_ok":
		return "expected privateer_hire_ok"
	var c = desk.active_contract("target_corp", 5)
	if c == null or c["sponsor"] != "AmosCorp":
		return "expected sponsor casing 'AmosCorp' preserved, got '%s'" % str(c["sponsor"] if c else null)

	return "ok"
