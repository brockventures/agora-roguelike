class_name CommissionModal
extends RefCounted
## Ministry of Commerce hearing (#149) and Sovereign Expropriation Decree modal model builders
## extracted from `res://scenes/main.gd` (#221). Presentation only: nothing here writes sim state,
## saves or hashes.


static func _fmt(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


## Builds the Ministry of Commerce Emergency Dissolution Hearing (or 100% Regulatory Capture
## True Ending) modal model (#149).
static func hearing_model(loop: M0Loop, controller: RunController = null) -> Dictionary:
	var rc: RunController = controller if controller != null else (loop.controller if loop != null else null)
	var p: MetaProfile = rc.profile if (rc != null and rc.profile != null) else MetaProfile.new()
	var pct: int = Commission.capture_pct(p)
	var true_ending: bool = Commission.dissolution_fails(p)
	var rows: Array = []
	if true_ending:
		rows.append({"kind": "text", "text": Loc.t("COMM_TRUE_BODY")})
		rows.append({"kind": "kv", "key": Loc.t("COMM_CAPTURE_KEY"), "value": Loc.t("COMM_CAPTURE_VALUE") % [pct, p.consultants.size(), Commission.ids().size()]})
		rows.append({"kind": "kv", "key": Loc.t("COMM_TRUE_TICKER_KEY"), "value": Loc.t("COMM_TRUE_TICKER_VAL")})
		rows.append({"kind": "start", "cursor": true, "text": Loc.t("COMM_ACT_PARACHUTES")})
		return {
			"eyebrow": Loc.t("COMM_TRUE_EYEBROW"),
			"title": Loc.t("COMM_TRUE_TITLE"),
			"band": "teal",
			"wide": true,
			"rows": rows,
			"actions": [[Loc.t("HUD_PAD_A"), Loc.t("HUD_ACT_CONTINUE")], [Loc.t("HUD_PAD_B"), Loc.t("HUD_ACT_BACK")]],
		}
	rows.append({"kind": "text", "text": Loc.t("COMM_HEARING_BODY")})
	var c_rows: Array = loop.commission_rows() if loop != null else []
	var cursor_idx: int = loop.hearing_cursor if loop != null else 0
	for i in c_rows.size():
		var r: Dictionary = c_rows[i]
		var cid: String = str(r["id"]).to_upper()
		var tag: String = Loc.t("COMM_TAG_RETAINED") if bool(r["retained"]) else (Loc.t("COMM_TAG_COST") % int(r["cost"]) if bool(r["can_retain"]) else (Loc.t("COMM_TAG_CHAIR_LAST") if str(r["reason"]) == "CHAIR_LAST" else Loc.t("COMM_TAG_LOCKED") % int(r["cost"])))
		rows.append({
			"kind": "perk",
			"cursor": i == cursor_idx,
			"dim": not bool(r["can_retain"]) and not bool(r["retained"]),
			"tier": "",
			"name": Loc.t("COMM_NAME_" + cid),
			"branch": Loc.t("COMM_PORTFOLIO_" + cid),
			"tag": tag,
		})
	if cursor_idx < c_rows.size() and not c_rows.is_empty():
		var cur_id: String = str(c_rows[clampi(cursor_idx, 0, c_rows.size() - 1)]["id"]).to_upper()
		rows.append({"kind": "muted", "text": Loc.t("COMM_DESC_" + cur_id)})
	rows.append({"kind": "start", "cursor": cursor_idx >= c_rows.size(), "text": Loc.t("COMM_ACT_PARACHUTES")})
	return {
		"eyebrow": Loc.t("COMM_HEARING_EYEBROW") % [p.skeletons, pct],
		"title": Loc.t("COMM_HEARING_TITLE"),
		"band": "teal",
		"wide": true,
		"rows": rows,
		"actions": [[Loc.t("HUD_PAD_DPAD"), Loc.t("HUD_ACT_SELECT")], [Loc.t("HUD_PAD_A"), Loc.t("COMM_ACT_RETAIN")], [Loc.t("HUD_PAD_B"), Loc.t("HUD_ACT_BACK")]],
	}


static func _hearing_model(loop: M0Loop, controller: RunController = null) -> Dictionary:
	return hearing_model(loop, controller)


## Builds the Emergency Sovereign Expropriation Decree modal model.
static func sovereign_decree_model(loop: M0Loop, controller: RunController = null) -> Dictionary:
	var rc: RunController = controller if controller != null else (loop.controller if loop != null else null)
	var sov: SovereignTakeover = rc.sovereign if rc != null else null
	var rounds_left: int = sov.rounds_remaining(rc.ticks_per_round) if (sov != null and rc != null) else 0
	var reg: bool = rc.has_regulatory_perk() if rc != null else false
	var lev: bool = rc.has_debt_leverage() if rc != null else false
	var buy: bool = rc.has_buyout_perk() if rc != null else false
	var cr: int = rc.cr if rc != null else 0
	var debt: int = rc.doomsday.principal_debt if (rc != null and rc.doomsday != null) else 0

	var can_b: bool = sov.can_bribe(cr, reg) if sov != null else false
	var can_d: bool = sov.can_debt_choke(cr, debt, lev) if sov != null else false
	var can_p: bool = sov.can_privatize(cr, buy) if sov != null else false

	var rows: Array = [
		{"kind": "text", "text": Loc.t("SOVEREIGN_DECREE_BODY")},
		{"kind": "kv", "key": Loc.t("SOVEREIGN_SEIZURE_TIMER"), "value": Loc.t("SOVEREIGN_ROUNDS_LEFT") % rounds_left},
	]

	var b_cost: int = sov.get_bribe_cost(reg) if sov != null else 0
	var d_req: int = (sov.debt_choke_leverage_debt if lev else sov.debt_choke_required_debt) if sov != null else 0
	var d_cost: int = sov.get_debt_choke_cost(lev) if sov != null else 0
	var p_cost: int = sov.get_privatize_cost(buy) if sov != null else 0

	var options: Array = [
		{
			"name": Loc.t("SOVEREIGN_ACT_BRIBE"),
			"branch": Loc.t("SOVEREIGN_BRANCH_CORRUPT"),
			"tag": Loc.t("HUD_CR_VALUE") % _fmt(b_cost),
			"enabled": can_b,
			"desc": Loc.t("SOVEREIGN_DESC_BRIBE") % _fmt(b_cost),
		},
		{
			"name": Loc.t("SOVEREIGN_ACT_DEBT_CHOKE"),
			"branch": Loc.t("SOVEREIGN_BRANCH_LEVERAGE"),
			"tag": Loc.t("SOVEREIGN_TAG_DEBT") % [_fmt(d_req), _fmt(d_cost)],
			"enabled": can_d,
			"desc": Loc.t("SOVEREIGN_DESC_DEBT_CHOKE") % [_fmt(d_req), _fmt(d_cost)],
		},
		{
			"name": Loc.t("SOVEREIGN_ACT_PRIVATIZE"),
			"branch": Loc.t("SOVEREIGN_BRANCH_BUYOUT"),
			"tag": Loc.t("HUD_CR_VALUE") % _fmt(p_cost),
			"enabled": can_p,
			"desc": Loc.t("SOVEREIGN_DESC_PRIVATIZE") % _fmt(p_cost),
		},
		{
			"name": Loc.t("SOVEREIGN_ACT_DISMISS"),
			"branch": Loc.t("SOVEREIGN_BRANCH_STAND_DOWN"),
			"tag": Loc.t("SOVEREIGN_TAG_RESUME"),
			"enabled": true,
			"desc": Loc.t("SOVEREIGN_DESC_DISMISS"),
		},
	]

	var cursor_idx: int = loop.sovereign_cursor if loop != null else 0
	for i in range(options.size()):
		var opt: Dictionary = options[i]
		rows.append({
			"kind": "perk",
			"cursor": i == cursor_idx,
			"dim": not bool(opt["enabled"]),
			"branch_share": 0.28,
			"tier": "",
			"name": str(opt["name"]),
			"branch": str(opt["branch"]),
			"tag": str(opt["tag"]),
		})

	var cur_opt: Dictionary = options[clampi(cursor_idx, 0, options.size() - 1)]
	rows.append({"kind": "muted", "text": str(cur_opt["desc"])})
	rows.append({"kind": "muted", "text": Loc.t("HUD_CLOCK_HALTED")})

	return {
		"eyebrow": Loc.t("SOVEREIGN_DECREE_EYEBROW"),
		"title": Loc.t("SOVEREIGN_DECREE_TITLE"),
		"band": "alert",
		"wide": true,
		"rows": rows,
		"actions": [
			[Loc.t("HUD_PAD_DPAD"), Loc.t("HUD_ACT_SELECT")],
			[Loc.t("HUD_PAD_A"), Loc.t("HUD_ACT_EXECUTE") if bool(cur_opt["enabled"]) else Loc.t("HUD_ACT_LOCKED")],
			[Loc.t("HUD_PAD_B"), Loc.t("HUD_ACT_DISMISS")]
		]
	}


static func _sovereign_decree_model(loop: M0Loop, controller: RunController = null) -> Dictionary:
	return sovereign_decree_model(loop, controller)
