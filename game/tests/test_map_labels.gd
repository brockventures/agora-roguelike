extends RefCounted
## Epic 6 (#124): the map's labels as the map prints them. No two label boxes (station
## names, SOL, the YOU tag, rival fleet tags, the route card) may intersect, none may sit
## on a station or Sun disc, and all stay in the map panel above the ticker; for both
## test seeds, across a sweep of rounds, docked and under way. The layout is deterministic.

const SEEDS: Array = [84, 7]
const ROUNDS: int = 48


## Text scale and locale pairs the sweeps run at: the shipped default, and the worst case
## (130% in the pseudo-locale, whose names run 30% longer).
const MODES: Array = [[1.0, "en"], [1.3, "pseudo"]]


func _scene(p_seed: int, mode: Array = [1.0, "en"]) -> Node:
	Loc.set_locale(str(mode[1]))
	var scene = load("res://scenes/main.tscn").instantiate()
	var rc := RunController.new(null, p_seed)
	rc.world = Barons.for_new_run()
	scene.initialize_systems(rc)
	scene._resolve_child_nodes()
	scene._build_readouts()
	scene.settings.set_text_scale(float(mode[0]))
	scene.apply_text_scale()
	scene.controller.cr = 100000
	scene._refresh_readouts()
	return scene


## Findings for one layout: [] when every box is clear.
func _problems(scene: Node, layout: Dictionary, tag: String) -> Array:
	var out: Array = []
	var boxes: Dictionary = layout["boxes"]
	var keys: Array = boxes.keys()
	keys.sort()
	var bounds: Rect2 = scene._map_label_bounds()
	var sun: Vector2 = scene._map_center()
	for a in keys:
		var box: Rect2 = boxes[a]
		if not bounds.encloses(box):
			out.append("%s: label %s leaves the map: %s" % [tag, a, str(box)])
		if scene._circle_hits(sun, SolTacticalMap.SOL_NODE_RADIUS_PX, box):
			out.append("%s: label %s covers the Sun" % [tag, a])
		for st in layout["discs"]:
			if scene._circle_hits(Vector2(layout["discs"][st]), SolTacticalMap.STATION_NODE_RADIUS_PX, box):
				out.append("%s: label %s covers the %s disc" % [tag, a, st])
		for b in keys:
			if str(a) < str(b) and (boxes[a] as Rect2).intersects(boxes[b]):
				out.append("%s: labels %s and %s intersect: %s vs %s" % [tag, a, b, str(boxes[a]), str(boxes[b])])
	return out


func test_no_two_map_labels_intersect_docked_across_rounds_both_seeds() -> String:
	var found: Array = []
	for sd in SEEDS:
		for mode in MODES:
			var scene := _scene(sd, mode)
			for dest in ["mars", "ceres", "luna", "earth"]:
				scene.hud.set_station(dest)
				scene._refresh_readouts()
				for r in ROUNDS:
					found.append_array(_problems(scene, scene.map_layout(r), "seed %d x%s %s docked %s pick %s round %d" % [sd, str(mode[0]), mode[1], scene.controller.docked_at, dest, r]))
			scene.free()
	Loc.set_locale(Loc.LOCALE_EN)
	return "ok" if found.is_empty() else "%d overlaps: %s" % [found.size(), "\n  ".join(PackedStringArray(found.slice(0, 12)))]


func test_no_two_map_labels_intersect_in_transit_across_rounds_both_seeds() -> String:
	var found: Array = []
	var tags: int = 0
	for sd in SEEDS:
		for mode in MODES:
			var scene := _scene(sd, mode)
			scene.loop.dock_at("mars")
			scene.controller.depart("ceres")
			scene._refresh_readouts()
			for r in ROUNDS:
				var layout: Dictionary = scene.map_layout(r)
				if layout["boxes"].has("you"):
					tags += 1
				found.append_array(_problems(scene, layout, "seed %d x%s %s in transit round %d" % [sd, str(mode[0]), mode[1], r]))
			scene.free()
	Loc.set_locale(Loc.LOCALE_EN)
	if tags == 0:
		return "the YOU tag was never placed, so it was never checked"
	return "ok" if found.is_empty() else "%d overlaps: %s" % [found.size(), "\n  ".join(PackedStringArray(found.slice(0, 12)))]


func test_no_two_map_labels_intersect_while_the_run_plays_both_seeds() -> String:
	# Live: the clock runs, rival fleets fly (their tags join the layout) and the bodies move.
	var found: Array = []
	var fleets_seen: int = 0
	for sd in SEEDS:
		var scene := _scene(sd)
		var rc: RunController = scene.controller
		rc.sim_clock.resume()
		var last: int = -1
		var guard: int = 0
		while rc.get_current_round() < 14 and guard < 200000:
			guard += 1
			if scene.loop.overlay_state == M0Loop.OVERLAY_CRISIS:
				scene.loop.acknowledge_crisis()
			elif scene.loop.overlay_state == M0Loop.OVERLAY_CONTRACT:
				scene.loop.decline_contract()
			elif scene.loop.overlay_state != M0Loop.OVERLAY_NONE:
				break
			scene.loop.advance(1.0 / 60.0 + 0.0001)
			if rc.get_current_round() != last:
				last = rc.get_current_round()
				var layout: Dictionary = scene.map_layout(last)
				for k in layout["boxes"]:
					if str(k).begins_with("fleet_"):
						fleets_seen += 1
				found.append_array(_problems(scene, layout, "seed %d live round %d" % [sd, last]))
		scene.free()
	if fleets_seen == 0:
		return "no rival fleet tag was ever placed, so none was checked"
	return "ok" if found.is_empty() else "%d overlaps: %s" % [found.size(), "\n  ".join(PackedStringArray(found.slice(0, 12)))]


func test_map_layout_is_deterministic() -> String:
	var scene := _scene(84)
	for r in [0, 1, 7, 23]:
		var a: Dictionary = scene.map_layout(r)
		var b: Dictionary = scene.map_layout(r)
		if var_to_str(a) != var_to_str(b):
			scene.free()
			return "round %d laid out differently twice" % r
	scene.free()
	return "ok"


func test_route_card_shows_the_pick_with_a_belt_toll_only_on_a_belt_lane() -> String:
	var scene := _scene(84)
	scene.loop.dock_at("mars")
	scene.hud.set_station("mars")
	scene._refresh_readouts()
	if scene._route_card["plate"].visible:
		scene.free()
		return "the card is up with no destination picked"
	scene.hud.set_station("ceres")
	scene._refresh_readouts()
	var card: Control = scene._route_card["plate"]
	var belt_on: bool = card.visible and (scene._route_card["belt"] as Control).visible
	var body: String = scene.panel_text(card)
	scene.hud.set_station("earth")
	scene._refresh_readouts()
	var belt_off: bool = (scene._route_card["belt"] as Control).visible
	scene.free()
	if not belt_on:
		return "no belt toll indicator on Mars to Ceres"
	for want in ["ARCADIA FOUNDRIES", "CERES", "BELT TOLL 25 CR", "rounds"]:
		if not body.contains(want):
			return "route card text %s lacks %s" % [var_to_str(body), want]
	if belt_off:
		return "belt toll indicator on Mars to Earth, which does not cross the belt"
	return "ok"


func test_ticker_chips_follow_the_ticker_line_tones() -> String:
	var scene := _scene(84)
	scene.hud.post_headline("Hazard line", "HAZARD", "INFO")
	scene.hud.post_headline("Debt line", "DEBT", "WARNING")
	scene._refresh_readouts()
	var top_fill: Color = (scene.ticker_chips[0] as HudKit.Plate).fill
	var next_fill: Color = (scene.ticker_chips[1] as HudKit.Plate).fill
	scene.free()
	if top_fill != HudTheme.INK:
		return "DEBT chip is %s, not ink" % str(top_fill)
	if next_fill != HudTheme.RUST:
		return "HAZARD chip is %s, not rust" % str(next_fill)
	return "ok"
