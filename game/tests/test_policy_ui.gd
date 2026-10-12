extends RefCounted
## #160 row 4: the Policy Committee modal (OVERLAY_POLICY), its input, the desk-notes chip and
## the places Main attaches policies (docs/design/corporate-policies.md sections 9 and 11).
## The grants, saves and goldens are test_policy_state.gd and test_policy_goldens.gd.

const FRAME: float = 1.0 / 60.0 + 0.0001
const TMP_ROOT := "user://test_tmp"
var _counter: int = 0


func _session() -> Replay.Session:
	return Replay.Session.new(5, {}, FRAME, 30, false, true)


## A session run to its round 20 grant: the modal is up and the clock is stopped.
func _at_round_20() -> Replay.Session:
	var s := _session()
	var guard: int = 0
	while s.loop.overlay_state != M0Loop.OVERLAY_POLICY and guard < 2000:
		if s.loop.overlay_state != M0Loop.OVERLAY_NONE:
			s.loop.dispatch_action(M0Loop.ACT_SUBMIT)
		s.advance()
		guard += 1
	return s


func _scene() -> Node:
	var rc := RunController.new(null, 84)
	var scene = load("res://scenes/main.tscn").instantiate()
	scene.initialize_systems(rc)
	scene._resolve_child_nodes()
	scene._build_readouts()
	return scene


func _store() -> SaveStore:
	_counter += 1
	return SaveStore.new("%s/policy_ui_%d_%d" % [TMP_ROOT, Time.get_ticks_usec(), _counter])


func _cleanup(store: SaveStore) -> void:
	var d := DirAccess.open(store.dir)
	if d != null:
		for f in d.get_files():
			DirAccess.remove_absolute(store.dir.path_join(f))
	DirAccess.remove_absolute(store.dir)
	DirAccess.remove_absolute(TMP_ROOT)


# --- raising ---

func test_the_round_20_grant_raises_the_modal_and_stops_the_clock() -> String:
	var s := _at_round_20()
	var rc := s.controller
	if s.loop.overlay_state != M0Loop.OVERLAY_POLICY:
		return "no modal: overlay %s at round %d" % [s.loop.overlay_state, rc.get_current_round()]
	if rc.get_current_round() != 20 or not rc.sim_clock.paused or rc.policies.pending() != 1:
		return "round %d paused=%s pending=%d" % [rc.get_current_round(), str(rc.sim_clock.paused), rc.policies.pending()]
	var rows: Array = s.loop.policy_rows()
	if rows.size() != 4 or rows.any(func(r): return str(r["state"]) != "offer"):
		return "the full eligible list is the four roots, got %s" % str(rows)
	if s.loop.policy_cursor != 0:
		return "the cursor starts on the first offer"
	var ticks: int = rc.sim_clock.total_ticks
	s.advance_frames(30)
	return "ok" if rc.sim_clock.total_ticks == ticks else "the clock ran behind the modal"


func test_dpad_moves_the_cursor_and_a_adopts_the_row_under_it() -> String:
	var s := _at_round_20()
	var lp := s.loop
	if lp.dispatch_action(M0Loop.ACT_UP):
		return "up at the top moved something"
	if not lp.dispatch_action(M0Loop.ACT_DOWN) or not lp.dispatch_action(M0Loop.ACT_DOWN) or lp.policy_cursor != 2:
		return "down twice did not reach row 2: cursor %d" % lp.policy_cursor
	if lp.dispatch_action(M0Loop.ACT_CANCEL):
		return "B declined a pick, which is mandatory"
	if lp.overlay_state != M0Loop.OVERLAY_POLICY:
		return "B closed the modal"
	if not lp.dispatch_action(M0Loop.ACT_SUBMIT):
		return "A did not adopt"
	var rc := s.controller
	if rc.policies.picks != ["training_module"]:
		return "adopted %s, wanted the third root" % str(rc.policies.picks)
	if lp.overlay_state != M0Loop.OVERLAY_NONE or rc.sim_clock.paused:
		return "the modal did not close and resume the clock (overlay %s)" % lp.overlay_state
	if rc.bankruptcy_grace_ticks() < 1800:
		return "the policy is not in force"
	var head: Dictionary = lp.hud.galnet_headlines[0]
	if str(head.get("key", "")) != "HL_POLICY_ADOPTED" or not lp.hud.headline_text(head).contains(Loc.policy_name(rc.policies.tree().perks["training_module"])):
		return "no adoption line on the ticker: %s" % str(head)
	return "ok"


func test_the_dpad_stops_at_the_last_offer() -> String:
	var s := _at_round_20()
	for i in 10:
		s.loop.dispatch_action(M0Loop.ACT_DOWN)
	return "ok" if s.loop.policy_cursor == 3 else "cursor ran to %d of 4 rows" % s.loop.policy_cursor


func test_two_pending_picks_show_one_after_the_other() -> String:
	var s := _at_round_20()
	var rc := s.controller
	rc.policies.earned = 2
	s.loop.dispatch_action(M0Loop.ACT_DOWN)
	s.loop.dispatch_action(M0Loop.ACT_SUBMIT)
	if s.loop.overlay_state != M0Loop.OVERLAY_POLICY or not rc.sim_clock.paused or s.loop.policy_cursor != 0:
		return "the second pick did not follow (overlay %s, cursor %d)" % [s.loop.overlay_state, s.loop.policy_cursor]
	s.loop.dispatch_action(M0Loop.ACT_SUBMIT)
	return "ok" if s.loop.overlay_state == M0Loop.OVERLAY_NONE and not rc.sim_clock.paused and rc.policies.picks.size() == 2 else "second A left overlay %s" % s.loop.overlay_state


func test_an_owned_capstone_shows_its_sibling_as_unavailable_and_the_cursor_skips_it() -> String:
	var s := _at_round_20()
	var rc := s.controller
	rc.policies.picks = ["supply_chain", "risk_transfer"] as Array[String]
	rc.policies.earned = 3
	var rows: Array = s.loop.policy_rows()
	var offers: Array = []
	var shut: Array = []
	for r in rows:
		(offers if str(r["state"]) == "offer" else shut).append(str(r["id"]))
	if shut != ["corridor_access"] or offers.has("corridor_access") or offers.size() != 3:
		return "offers %s, unavailable %s" % [str(offers), str(shut)]
	if str(rows[rows.size() - 1]["id"]) != "corridor_access":
		return "the unavailable row is not listed after the offers"
	for i in 6:
		s.loop.dispatch_action(M0Loop.ACT_DOWN)
	return "ok" if s.loop.policy_cursor == 2 else "the cursor reached an unavailable row: %d" % s.loop.policy_cursor


# --- precedence ---

func test_a_pick_waits_behind_a_higher_modal_and_is_raised_when_it_closes() -> String:
	var s := _session()
	var lp := s.loop
	var rc := s.controller
	rc.policies.earned = 1
	lp._set_overlay(M0Loop.OVERLAY_CONTRACT)
	lp._raise_policy_if_pending()
	if lp.overlay_state != M0Loop.OVERLAY_CONTRACT:
		return "the pick outranked a contract"
	# The modal closes the way acknowledge/decline do: overlay off, clock resumed. The controller
	# stops the clock again on the next sub-tick (the pending pick) and the pause raises the modal.
	lp._set_overlay(M0Loop.OVERLAY_NONE)
	rc.sim_clock.resume()
	s.advance()
	if lp.overlay_state != M0Loop.OVERLAY_POLICY or not rc.sim_clock.paused:
		return "the waiting pick was not raised: overlay %s paused=%s" % [lp.overlay_state, str(rc.sim_clock.paused)]
	return "ok"


func test_a_takeover_pick_is_raised_where_the_takeover_lands() -> String:
	var s := Replay.Session.new(9, {}, FRAME, 30, true, true)
	var rc := s.controller
	rc.cr = 100000
	rc.sim_clock.pause()
	var id: String = rc.world.ids()[0]
	s.loop._post_baron_event(Takeover.take(rc.world, id, Takeover.PLAYER, rc))
	if rc.policies.pending() != 1:
		return "the first takeover granted no pick"
	return "ok" if s.loop.overlay_state == M0Loop.OVERLAY_POLICY else "overlay %s after the takeover" % s.loop.overlay_state


func test_a_filing_clears_a_pending_pick() -> String:
	var s := _at_round_20()
	var rc := s.controller
	rc.doomsday.principal_debt = 10000000
	s.loop.dispatch_action(M0Loop.ACT_CHAPTER_11)  # X is live behind the modal
	if rc.policies.pending() != 0 or rc.policies.picks.size() != 0:
		return "the filing kept the pick: %s" % str(rc.policies.to_dict())
	return "ok" if s.loop.overlay_state != M0Loop.OVERLAY_POLICY else "the modal outlived the filing"


func test_a_saved_pending_pick_re_raises_the_modal_on_load() -> String:
	var s := _at_round_20()
	var cap: Dictionary = RunSave.capture(s.controller, s.loop.market, s.bags)
	var r: Dictionary = RunSave.restore(JSON.parse_string(JSON.stringify(cap)))
	if not bool(r["ok"]):
		return "restore failed: %s" % str(r["error"])
	var hud := OrbitalHUD.new(r["controller"])
	var loop := M0Loop.new(hud)
	loop._sync_overlay_from_controller()
	return "ok" if loop.overlay_state == M0Loop.OVERLAY_POLICY else "no modal after load: %s" % loop.overlay_state


# --- where Main attaches policies ---

func test_main_attaches_policies_to_a_new_run_and_the_next_one() -> String:
	var main := MainScene.new()
	var rc := main.start_new_run(5)
	var first: bool = rc.policies != null and not rc.policies.has_granted()
	rc.policies.earned = 1
	rc.policies.picks = ["supply_chain"] as Array[String]
	var key_before: bool = RunSave.capture(rc, main.loop.market, main.bags).has("policies")
	rc.doomsday.ticks_remaining = 1
	main.loop.advance(FRAME)
	main.loop.dispatch_action(M0Loop.ACT_SUBMIT)  # the summary on to the perks
	var next: RunController = main.loop.start_next_run()
	var carried: bool = next != null and next.policies != null and next.policies.picks.is_empty() and next.policies.earned == 0
	main.free()
	if not first:
		return "start_new_run attached no fresh PolicyState"
	if not key_before:
		return "a held pick is not saved"
	return "ok" if carried else "start_next_run did not attach a fresh PolicyState"


func test_a_replay_session_never_gains_policies_even_after_a_collapse() -> String:
	var s := Replay.Session.new(5, {}, FRAME, 30, true)
	s.controller.doomsday.ticks_remaining = 1
	s.advance()
	s.loop.dispatch_action(M0Loop.ACT_SUBMIT)
	var next: RunController = s.loop.start_next_run()
	return "ok" if next != null and next.policies == null else "a policy-less session gained policies on its next run"


func test_a_save_without_the_policies_key_gets_a_fresh_state_on_continue() -> String:
	var st := _store()
	var plain := RunController.new(null, 21)  # attaches nothing: the shape of a pre-policy save
	plain.world = Barons.for_new_run()
	var bags := Bags.new("m0", null, 21)
	st.save_run(plain, StationMarket.new(), bags)
	var main := MainScene.new()
	main.enable_persistence(st)
	var ok: bool = main.continue_saved_run()
	var attached: bool = ok and main.controller.policies != null and not main.controller.policies.has_granted()
	var hash_kept: bool = ok and not RunSave.capture(main.controller, main.loop.market, main.bags).has("policies")
	main.free()
	_cleanup(st)
	if not ok:
		return "continue_saved_run failed"
	if not attached:
		return "the loaded run has no PolicyState"
	return "ok" if hash_kept else "a fresh PolicyState wrote a policies key before any grant"


func test_a_save_holding_policies_keeps_them_on_continue() -> String:
	var st := _store()
	var rc := RunController.new(null, 22)
	rc.world = Barons.for_new_run()
	rc.attach_policies()
	rc.policies.earned = 1
	rc.policies.milestones_done = 1
	rc.policies.picks = ["cost_containment"] as Array[String]
	rc.apply_modifiers(rc.perk_modifiers)
	st.save_run(rc, StationMarket.new(), Bags.new("m0", null, 22))
	var main := MainScene.new()
	main.enable_persistence(st)
	var ok: bool = main.continue_saved_run()
	var kept: bool = ok and main.controller.policies.picks == ["cost_containment"]
	main.free()
	_cleanup(st)
	return "ok" if kept else "the held policy was lost or replaced on continue"


# --- the model and the chip ---

func test_the_modal_model_lists_rows_tags_the_description_and_has_no_b() -> String:
	var scene := _scene()
	var rc: RunController = scene.controller
	rc.attach_policies()
	rc.policies.earned = 3
	rc.policies.picks = ["supply_chain", "risk_transfer"] as Array[String]
	scene.loop.overlay_state = M0Loop.OVERLAY_POLICY
	var m: Dictionary = scene._policy_model()
	scene.free()
	if str(m["eyebrow"]) != "POLICY COMMITTEE 3 OF 4" or str(m["title"]) != "Quarterly Policy Review":
		return "heading %s / %s" % [m["eyebrow"], m["title"]]
	var rows: Array = m["rows"]
	var perk_rows: Array = rows.filter(func(r): return str(r["kind"]) == "perk")
	if perk_rows.size() != 4:
		return "wanted 3 offers and 1 unavailable row, got %d" % perk_rows.size()
	var tags: Array = perk_rows.map(func(r): return str(r["tag"]))
	if tags != ["ROOT", "ROOT", "ROOT", "BARRED"]:
		return "tags %s" % str(tags)
	if not bool(perk_rows[3]["dim"]) or bool(perk_rows[0]["dim"]):
		return "only the unavailable row is dimmed"
	if perk_rows.filter(func(r): return bool(r["cursor"])).size() != 1 or not bool(perk_rows[0]["cursor"]):
		return "exactly the first offer carries the cursor"
	var muted: Array = rows.filter(func(r): return str(r["kind"]) == "muted")
	if muted.size() != 2 or not str(muted[0]["text"]).contains("burn 10%"):
		return "the cursor row's description is not the one muted line before the halted notice: %s" % str(muted)
	var captions: Array = (m["actions"] as Array).map(func(a): return str(a[1]))
	return "ok" if captions == ["Select", "Adopt"] else "actions %s (no B: the pick is mandatory)" % str(captions)


func test_a_capstone_is_tagged_fork() -> String:
	var scene := _scene()
	scene.controller.attach_policies()
	scene.controller.policies.earned = 2
	scene.controller.policies.picks = ["supply_chain"] as Array[String]
	scene.loop.overlay_state = M0Loop.OVERLAY_POLICY
	var tags: Dictionary = {}
	for r in scene._policy_model()["rows"]:
		if str(r["kind"]) == "perk":
			tags[str(r["name"])] = str(r["tag"])
	scene.free()
	return "ok" if tags.get("Risk Transfer Framework") == "FORK" and tags.get("Cost Containment Initiative") == "ROOT" else str(tags)


func test_the_chip_is_hidden_until_the_first_grant_then_lists_the_adopted_names() -> String:
	var scene := _scene()
	var rc: RunController = scene.controller
	rc.attach_policies()
	if not scene._policy_notes().is_empty():
		return "a chip before any grant"
	rc.policies.earned = 1
	rc.policies.milestones_done = 1
	var empty: Array = scene._policy_notes()
	if empty.size() != 1 or str(empty[0]["text"]) != "POLICIES 0/4":
		return "granted, none adopted: %s" % str(empty)
	rc.policies.picks = ["supply_chain"] as Array[String]
	var held: Array = scene._policy_notes()
	if str(held[0]["kind"]) != "chip" or str(held[0]["text"]) != "POLICIES 1/4" or held.size() != 2 or str(held[1]["text"]) != "· Synergized Supply Chain":
		return "one adopted: %s" % str(held)
	# It reaches the card, and a filing sends it back to 0/4 with the names gone.
	scene._refresh_readouts()
	var texts: Array = scene._card_notes().filter(func(n): return str(n["kind"]) == "chip").map(func(n): return str(n["text"]))
	rc.policies.reset_for_new_corp()
	var after: Array = scene._policy_notes()
	scene.free()
	if not texts.has("POLICIES 1/4"):
		return "the card notes lack the chip: %s" % str(texts)
	return "ok" if after.size() == 1 and str(after[0]["text"]) == "POLICIES 0/4" else "after a filing: %s" % str(after)


func test_no_policies_attached_means_no_modal_and_no_pause_for_one() -> String:
	var s := Replay.Session.new(5, {}, FRAME, 30, true)
	var rc := s.controller
	var guard: int = 0
	while rc.get_current_round() < 25 and guard < 4000:
		match s.loop.overlay_state:
			M0Loop.OVERLAY_POLICY:
				return "a policy modal on a run with none attached"
			M0Loop.OVERLAY_CRISIS, M0Loop.OVERLAY_MONOPOLY:
				s.loop.dispatch_action(M0Loop.ACT_SUBMIT)
			M0Loop.OVERLAY_CONTRACT:
				s.loop.dispatch_action(M0Loop.ACT_CANCEL)
		s.advance()
		guard += 1
	return "ok" if rc.policies == null and rc.get_current_round() >= 25 else "stopped at round %d (%s)" % [rc.get_current_round(), s.loop.overlay_state]
