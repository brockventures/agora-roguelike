class_name TakeoverModal
extends RefCounted
## Baron takeover/monopoly summary, distress auction, and Sol System Rescue win modal model
## builders extracted from `res://scenes/main.gd` (#221). Presentation only: nothing here writes
## sim state, saves or hashes.


static func _fmt(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


static func _maker_name(id: String, world: Barons = null) -> String:
	var english: String = ""
	if world != null:
		var d: Dictionary = world.def(id)
		if d.is_empty():
			d = world.rival_def(id)
		english = str(d.get("name", "")).to_upper()
	return Loc.maker(id, english)


## The monopoly / Baron takeover summary state (Epic 3 task 9, design doc 5.4): every baron held.
static func takeover_model(loop: M0Loop, _controller: RunController = null) -> Dictionary:
	var r: Dictionary = loop.monopoly_summary() if loop != null else {}
	if r.is_empty():
		return {"eyebrow": Loc.t("MONO_EYEBROW"), "title": Loc.t("MONO_TITLE"), "band": "teal", "wide": true, "rows": [], "actions": [[Loc.t("HUD_PAD_A"), Loc.t("HUD_ACT_CONTINUE")]]}
	return {"eyebrow": Loc.t("MONO_EYEBROW"), "title": Loc.t("MONO_TITLE"), "band": "teal", "wide": true,
		"rows": [
			{"kind": "text", "text": Loc.t("MONO_BODY") % Loc.station(str(r["first_site"]))},
			{"kind": "kv", "key": Loc.t("MONO_HELD"), "value": Loc.t("MONO_HELD_VALUE") % [int(r["barons_held"]), int(r["barons_total"])]},
			{"kind": "kv", "key": Loc.t("SUM_NET_WORTH"), "value": Loc.t("HUD_CR_VALUE") % _fmt(int(r["net_worth"]))},
			{"kind": "kv", "key": Loc.t("SUM_PEAK"), "value": Loc.t("HUD_CR_VALUE") % _fmt(int(r["peak_net_worth"]))},
			{"kind": "kv", "key": Loc.t("SUM_ROUNDS"), "value": str(int(r["rounds"]))},
			{"kind": "kv", "key": Loc.t("MONO_SEVERANCE"), "value": Loc.t("MONO_SEVERANCE_VALUE") % int(r["severance_pending"])},
			{"kind": "muted", "text": Loc.t("MONO_NEXT")},
			{"kind": "muted", "text": Loc.t("HUD_CLOCK_HALTED")}],
		"actions": [[Loc.t("HUD_PAD_A"), Loc.t("HUD_ACT_CONTINUE")]]}


static func _takeover_model(loop: M0Loop, controller: RunController = null) -> Dictionary:
	return takeover_model(loop, controller)


static func monopoly_model(loop: M0Loop, controller: RunController = null) -> Dictionary:
	return takeover_model(loop, controller)


## Distress auction / Baron takeover status model for the baron anchoring `station` (or the
## docked station when `station` is omitted).
static func distress_model(loop: M0Loop, controller: RunController = null, station: String = "") -> Dictionary:
	var rc: RunController = controller if controller != null else (loop.controller if loop != null else null)
	var st: String = station if station != "" else (rc.docked_at if rc != null else "")
	var w: Barons = rc.world if rc != null else null
	var id: String = w.baron_at(st) if (w != null and st != "") else ""
	var title: String = _maker_name(id, w) if id != "" else Loc.t("MONO_TITLE")
	var state: String = loop.takeover_state(st) if (loop != null and st != "") else ""
	var lines: Array = loop.takeover_lines(st) if (loop != null and st != "") else []
	var eyebrow: String = str(lines[0]) if not lines.is_empty() else Loc.t("SIDE_DISTRESS_NONE")
	var rows: Array = []
	for i in range(1, lines.size()):
		rows.append({"kind": "text", "text": str(lines[i])})
	rows.append({"kind": "muted", "text": Loc.t("HUD_CLOCK_HALTED")})
	return {
		"eyebrow": eyebrow,
		"title": title,
		"band": "teal" if state == "held" else "alert",
		"wide": true,
		"state": state,
		"baron": id,
		"station": st,
		"rows": rows,
		"actions": [[Loc.t("HUD_PAD_A"), Loc.t("HUD_ACT_CONTINUE")]],
	}


static func _distress_model(loop: M0Loop, controller: RunController = null, station: String = "") -> Dictionary:
	return distress_model(loop, controller, station)


## The Sol System Rescue win modal (#32, design 6.1): wide and teal like the monopoly summary.
static func rescued_model(loop: M0Loop, _controller: RunController = null) -> Dictionary:
	var r: Dictionary = loop.run_summary() if loop != null else {}
	var st: Dictionary = r.get("rescue", {})
	var rows: Array = [{"kind": "text", "text": Loc.t("RESC_BODY")}]
	if not st.is_empty():
		rows.append({"kind": "kv", "key": Loc.t("SUM_RESC_ROUND"), "value": str(int(st["round"]))})
		rows.append({"kind": "kv", "key": Loc.t("SUM_RESC_CLOCK"), "value": str(int(st["clock_rounds_left"]))})
		rows.append({"kind": "kv", "key": Loc.t("SUM_RESC_PHASES"), "value": Loc.t("SUM_RESC_PHASES_VALUE") % [int(st["phases_done"]), int(st["phases_total"])]})
		rows.append({"kind": "kv", "key": Loc.t("SUM_RESC_UNITS"), "value": _fmt(int(st["units"]))})
		rows.append({"kind": "kv", "key": Loc.t("SUM_RESC_CR"), "value": Loc.t("HUD_CR_VALUE") % _fmt(int(st["cr_paid"]))})
	rows.append({"kind": "kv", "key": Loc.t("SUM_NET_WORTH"), "value": Loc.t("HUD_CR_VALUE") % _fmt(int(r.get("net_worth", 0)))})
	rows.append({"kind": "kv", "key": Loc.t("SUM_SEV_RESCUE"), "value": Loc.t("SUM_SEV_VALUE") % int(r.get("severance_rescue_pts", 0))})
	rows.append({"kind": "muted", "text": Loc.t("HUD_CLOCK_HALTED")})
	return {"eyebrow": Loc.t("RESC_EYEBROW"), "title": Loc.t("RESC_TITLE"), "band": "teal", "wide": true, "rows": rows,
		"actions": [[Loc.t("HUD_PAD_A"), Loc.t("HUD_ACT_CONTINUE")]]}


static func _rescued_model(loop: M0Loop, controller: RunController = null) -> Dictionary:
	return rescued_model(loop, controller)


## The rescue rows of the run summary: a win's round, clock left and counter, or on a lost run
## with a project the phase it reached.
static func rescue_summary_rows(r: Dictionary) -> Array:
	var rows: Array = []
	var st: Dictionary = r.get("rescue", {})
	if st.is_empty():
		return rows
	if bool(st["rescued"]) and str(r["reason"]) == "rescued":
		rows.append({"kind": "kv", "key": Loc.t("SUM_RESC_ROUND"), "value": str(int(st["round"]))})
		rows.append({"kind": "kv", "key": Loc.t("SUM_RESC_CLOCK"), "value": str(int(st["clock_rounds_left"]))})
		rows.append({"kind": "kv", "key": Loc.t("SUM_RESC_COUNT"), "value": Loc.t("SUM_RESC_COUNT_VALUE") % int(st["rescues_completed"])})
	elif str(r["reason"]) == "collapse":
		rows.append({"kind": "kv", "key": Loc.t("SUM_STAB_PHASE"), "value": Loc.t("SUM_STAB_PHASE_VALUE") % [mini(int(st["phases_done"]) + 1, int(st["phases_total"])), int(st["phases_total"])]})
	return rows
