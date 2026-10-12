extends RefCounted
## The Sol System Rescue Project, task 4 (#32, docs/design/rescue-project.md sections 9 and 11): the
## Stabiliser card rows, the delivery chips, the header suffix, the toasts, the rescued modal
## and its summary rows, the achievement and the phase-name keys. Text fit at 130% in the pseudo
## locale lives in test_i18n_fit.gd.

const TPR: int = 30


## A docked run whose player holds every baron, with the project open, at `station`.
func _ctx(station: String = "luna", cr: int = 1000000) -> Dictionary:
	var rc := RunController.new(null, 21, null, {}, TPR)
	rc.world = Barons.for_new_run()
	rc.world.rivals.clear()
	for id in rc.world.ids():
		Takeover.take(rc.world, id, Takeover.PLAYER, rc)
	rc.cr = cr
	rc.doomsday.clear_debt()
	var hud := OrbitalHUD.new(rc)
	var lp := M0Loop.new(hud)
	lp.dock_at(station)
	rc.open_rescue()
	lp._refresh_world_mods()
	return {"rc": rc, "hud": hud, "loop": lp}


func _texts(rows: Array) -> Array:
	var out: Array = []
	for r in rows:
		out.append(str(r["text"]))
	return out


func _has(rows: Array, needle: String) -> bool:
	for t in _texts(rows):
		if t.contains(needle):
			return true
	return false


# --- The Stabiliser card ---

func test_no_card_without_a_project() -> String:
	var rc := RunController.new(null, 21, null, {}, TPR)
	var lp := M0Loop.new(OrbitalHUD.new(rc))
	if not lp.rescue_lines("luna").is_empty() or lp.rescue_tag("luna", "ORE") != "" or lp.rescue_clock_pct() != 100:
		return "a run with no project shows a card"
	return "ok"


func test_the_card_names_the_phase_its_bill_and_its_fee() -> String:
	var c := _ctx("mars")
	var lp: M0Loop = c["loop"]
	var rows: Array = lp.rescue_lines("mars")
	if str(rows[0]["kind"]) != "chip" or str(rows[0]["text"]) != "PHASE 1 OF 4  ANCHOR YARD  LUNA FUEL DEPOT":
		return "chip: %s" % str(rows[0])
	for want in ["MACHINERY 0 / 100", "ORE 0 / 100", "FEE 4000 CR LEFT"]:
		if not _has(rows, want):
			return "missing '%s' in %s" % [want, str(_texts(rows))]
	if _has(rows, "CLOCK") or _has(rows, "DELIVERS"):
		return "clock or delivery row before they apply: %s" % str(_texts(rows))
	return "ok"


func test_the_card_prompts_a_delivery_only_docked_at_the_site_with_cargo() -> String:
	var c := _ctx("luna")
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	if not _has(lp.rescue_lines("luna"), "BRING"):
		return "no bring hint with an empty hold: %s" % str(_texts(lp.rescue_lines("luna")))
	rc.cargo = {"MACHINERY": 100, "FRAG": 40}
	var rows: Array = lp.rescue_lines("luna")
	if not _has(rows, "H / PADDLE 1 DELIVERS 100 MACHINERY  -2000 CR"):
		return "prompt: %s" % str(_texts(rows))
	if _has(lp.rescue_lines("earth"), "DELIVERS"):
		return "the prompt shows at a station that is not the site"
	rc.cargo = {"MACHINERY": 100, "ORE": 20}
	if not _has(lp.rescue_lines("luna"), "100 MACHINERY + 20 ORE"):
		return "two-commodity prompt: %s" % str(_texts(lp.rescue_lines("luna")))
	return "ok"


func test_the_card_says_why_a_delivery_is_blocked() -> String:
	var c := _ctx("luna", 10)
	var lp: M0Loop = c["loop"]
	c["rc"].cargo = {"MACHINERY": 100}
	var rows: Array = lp.rescue_lines("luna")
	var last: Dictionary = rows[rows.size() - 1]
	if str(last["tone"]) != "bad" or not str(last["text"]).contains("NOT ENOUGH CR FOR THE FEE"):
		return "blocked row: %s" % str(last)
	return "ok"


func test_progress_and_the_clock_speed_show_after_a_delivery_and_a_finished_phase() -> String:
	var c := _ctx("luna")
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	rc.cargo = {"MACHINERY": 60}
	if not lp.deliver_to_project():
		return "delivery refused: %s" % lp.last_project_reason
	if not _has(lp.rescue_lines("luna"), "MACHINERY 60 / 100"):
		return "no progress row: %s" % str(_texts(lp.rescue_lines("luna")))
	rc.cargo = {"MACHINERY": 40, "ORE": 100}
	lp.deliver_to_project()
	var rows: Array = lp.rescue_lines("earth")
	if str(rows[0]["text"]) != "PHASE 2 OF 4  COIL FOUNDRY  KENNEDY ELEVATOR" or not _has(rows, "CLOCK 60%"):
		return "after phase 1: %s" % str(_texts(rows))
	if lp.rescue_clock_pct() != 60:
		return "clock pct %d" % lp.rescue_clock_pct()
	return "ok"


# --- Delivery chips ---

func test_chips_mark_the_site_and_the_books_the_phase_needs() -> String:
	var c := _ctx("mars")
	var lp: M0Loop = c["loop"]
	if lp.rescue_tag("luna", "ORE") != "SITE: NO ASK" or lp.rescue_tag("luna", "MACHINERY") != "SITE: NO ASK":
		return "site chips: %s / %s" % [lp.rescue_tag("luna", "ORE"), lp.rescue_tag("luna", "MACHINERY")]
	if lp.rescue_tag("luna", "FUEL") != "":
		return "an unneeded commodity at the site is tagged"
	if lp.rescue_tag("mars", "ORE") != "NEEDED: ORE" or lp.rescue_tag("earth", "MACHINERY") != "NEEDED: MACHINERY":
		return "needed chips: %s / %s" % [lp.rescue_tag("mars", "ORE"), lp.rescue_tag("earth", "MACHINERY")]
	if lp.rescue_tag("mars", "FOOD") != "":
		return "FOOD is not in the bill"
	# A filled need stops being NEEDED elsewhere; the site's embargo stays on.
	c["rc"].rescue.deposits = {"ORE": 100}
	if lp.rescue_tag("mars", "ORE") != "" or lp.rescue_tag("luna", "ORE") != "SITE: NO ASK":
		return "a filled need still asks for goods"
	return "ok"


# --- Phase names, strings and the header ---

func test_every_phase_name_has_a_key_and_the_ticker_names_it() -> String:
	var rp := RescueProject.new()
	for ph in rp.phases():
		var key: String = "RESCUE_PHASE_%s_NAME" % Loc.slug(str(ph["id"]))
		if Loc.t(key) == key or Loc.t(key) != str(ph["name"]):
			return "no English row for %s (%s)" % [key, Loc.t(key)]
	var c := _ctx("mars")
	c["loop"]._post_rescue_open()
	var found: bool = false
	for h in (c["hud"] as OrbitalHUD).galnet_headlines:
		found = found or str(h["text"]).contains("Phase 1, Anchor Yard, is at LUNA FUEL DEPOT")
	return "ok" if found else "the open line does not name the phase"


func _scene(c: Dictionary) -> Node:
	var scene = load("res://scenes/main.tscn").instantiate()
	scene.initialize_systems(c["rc"])
	scene._resolve_child_nodes()
	scene._build_readouts()
	return scene


func test_header_gains_a_clock_suffix_once_a_phase_is_done() -> String:
	var c := _ctx("luna")
	var scene := _scene(c)
	scene._refresh_readouts()
	var chips: Array = scene._hdr["chips"]
	var before: String = (chips[4]["value"] as Label).text
	if before.contains("CLOCK"):
		scene.free()
		return "suffix before any phase: %s" % before
	c["rc"].rescue.keep_bps = 6000
	scene._refresh_readouts()
	var after: String = (chips[4]["value"] as Label).text
	scene.free()
	return "ok" if after.ends_with("CLOCK 60%") and after.begins_with(before.split(" ")[0].substr(0, 1)) else "header value '%s'" % after


func test_a_refused_delivery_raises_a_rejected_toast_and_a_phase_a_notice() -> String:
	var c := _ctx("mars")
	var scene := _scene(c)
	var lp: M0Loop = scene.loop
	scene.controller.cargo = {}
	lp.dock_at("mars")
	lp.deliver_to_project()  # WRONG_SITE
	var kinds: Array = []
	for t in scene.toasts.toasts:
		kinds.append([str(t["kind"]), str(t["text"])])
	if kinds.is_empty() or kinds[0][0] != ToastTray.KIND_REJECTED or not str(kinds[0][1]).contains("this is not the build site"):
		scene.free()
		return "refusal toast: %s" % str(kinds)
	scene.toasts.clear()
	scene.controller.docked_at = "luna"
	scene.controller.cargo = {"MACHINERY": 100, "ORE": 100}
	lp.deliver_to_project()
	var got: Array = []
	for t in scene.toasts.toasts:
		got.append(str(t["kind"]))
	scene.free()
	# a delivery (filled) and the finished phase (notice) and its field line
	return "ok" if got.has(ToastTray.KIND_FILLED) and got.has(ToastTray.KIND_INFO) else "toast kinds: %s" % str(got)


# --- The win: the rescued modal, the summary, the achievement ---

## Delivers every phase through the loop (refilling the hold and the books' limits aside), as the player would.
func _win(c: Dictionary) -> void:
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	for i in 4:
		var ph: Dictionary = rc.rescue.current()
		rc.docked_at = str(ph["site"])
		rc.cargo = {}
		for com in ph["needs"]:
			rc.cargo[com] = int(ph["needs"][com])
		lp.deliver_to_project()


func test_the_last_delivery_raises_the_rescued_modal_then_the_summary_then_perks() -> String:
	var c := _ctx("luna")
	var lp: M0Loop = c["loop"]
	var rc: RunController = c["rc"]
	_win(c)
	if not rc.is_rescued() or lp.overlay_state != M0Loop.OVERLAY_RESCUED or not rc.sim_clock.paused:
		return "no rescued modal: overlay '%s' rescued %s" % [lp.overlay_state, str(rc.is_rescued())]
	if lp.dispatch_action(M0Loop.ACT_PROJECT) or lp.dispatch_action(M0Loop.ACT_CANCEL):
		return "something other than A is live behind the rescued modal"
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "A did not continue"
	if lp.overlay_state != M0Loop.OVERLAY_COLLAPSED or lp.collapse_phase != M0Loop.PHASE_SUMMARY:
		return "A should land on the run summary, got '%s'/'%s'" % [lp.overlay_state, lp.collapse_phase]
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT) or lp.collapse_phase != M0Loop.PHASE_PERKS:
		return "A on the summary should open the perks"
	return "ok"


func test_rescue_stats_are_derived_from_the_project() -> String:
	var c := _ctx("luna")
	var lp: M0Loop = c["loop"]
	_win(c)
	var st: Dictionary = lp.rescue_stats()
	if not bool(st["rescued"]) or int(st["phases_done"]) != 4 or int(st["units"]) != 900 or int(st["cr_paid"]) != 24000:
		return "stats: %s" % str(st)
	if int(st["rescues_completed"]) != 1 or int(st["round"]) != c["rc"].get_current_round():
		return "stats: %s" % str(st)
	var r: Dictionary = lp.run_summary()
	if str(r["reason"]) != "rescued" or int(r["severance_rescue_pts"]) <= 0 or r["rescue"] != st:
		return "summary: %s" % str(r)
	return "ok"


func test_the_rescued_modal_and_summary_rows() -> String:
	var c := _ctx("luna")
	_win(c)
	var scene := _scene(c)
	var lp: M0Loop = scene.loop
	if lp.overlay_state != M0Loop.OVERLAY_RESCUED:
		scene.free()
		return "overlay '%s'" % lp.overlay_state
	var m: Dictionary = scene._resolution_model()
	var keys: Array = []
	for r in m["rows"]:
		keys.append(str(r.get("key", r.get("text", ""))))
	if str(m["band"]) != "teal" or not bool(m["wide"]) or str(m["eyebrow"]) != "SOL SYSTEM RESCUED":
		scene.free()
		return "model head: %s" % str(m)
	for want in ["RESCUED IN ROUND", "ROUNDS OF CLOCK LEFT", "PHASES", "UNITS HAULED", "PROJECT CR PAID", "SOL RESCUED BONUS"]:
		if not keys.has(want):
			scene.free()
			return "rescued modal lacks %s: %s" % [want, str(keys)]
	lp.acknowledge_rescued()
	var s: Dictionary = scene._resolution_model()
	var skeys: Array = []
	var vals: Dictionary = {}
	for r in s["rows"]:
		if str(r["kind"]) == "kv":
			skeys.append(str(r["key"]))
			vals[str(r["key"])] = str(r["value"])
	scene.free()
	for want in ["RESCUED IN ROUND", "ROUNDS OF CLOCK LEFT", "SOL RESCUED", "SOL RESCUED BONUS"]:
		if not skeys.has(want):
			return "summary lacks %s: %s" % [want, str(skeys)]
	if vals["SOL RESCUED"] != "x 1":
		return "summary values: %s" % str(vals)
	return "ok"


func test_a_lost_run_shows_the_stabiliser_phase_and_its_consolation() -> String:
	var c := _ctx("luna")
	var rc: RunController = c["rc"]
	rc.cargo = {"MACHINERY": 100, "ORE": 100}
	c["loop"].deliver_to_project()
	rc.end_run("collapse")
	var scene := _scene(c)
	scene.loop.overlay_state = M0Loop.OVERLAY_COLLAPSED
	scene.loop.collapse_phase = M0Loop.PHASE_SUMMARY
	var vals: Dictionary = {}
	for r in scene._resolution_model()["rows"]:
		if str(r["kind"]) == "kv":
			vals[str(r["key"])] = str(r["value"])
	scene.free()
	if vals.get("STABILISER", "") != "PHASE 2 OF 4":
		return "no phase row: %s" % str(vals)
	if not vals.has("STABILISER PHASES x1 OF 4") or vals["STABILISER PHASES x1 OF 4"] != "+100":
		return "no consolation row: %s" % str(vals)
	return "ok"


func test_a_saved_rescued_run_reopens_on_the_rescued_modal() -> String:
	var c := _ctx("luna")
	_win(c)
	var lp2 := M0Loop.new(OrbitalHUD.new(c["rc"]))
	return "ok" if lp2.overlay_state == M0Loop.OVERLAY_RESCUED else "overlay '%s'" % lp2.overlay_state


func test_the_win_unlocks_sol_saved_and_bumps_its_stat() -> String:
	var fake := SteamFake.new()
	var svc := SteamService.new()
	svc.initialize(fake)
	var hooks := SteamHooks.new(svc)
	var c := _ctx("luna")
	hooks.bind(c["rc"])
	_win(c)
	var ok: bool = svc.is_unlocked("SOL_RESCUED") and svc.get_stat("rescues_completed") == 1
	hooks.unbind()
	if not svc.achievement_defs.has("SOL_RESCUED") or not svc.stat_defs.has("rescues_completed"):
		return "SOL_RESCUED or its stat is not in achievements.json"
	return "ok" if ok else "achievement %s, stat %d" % [str(svc.is_unlocked("SOL_RESCUED")), svc.get_stat("rescues_completed")]
