extends RefCounted
## Epic 6 HUD re-skin sample (#105): the Theme resource loads with the panel styles, and
## the CRT filter (shader, scanlines, chromatic fringe) is off by default.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"


func test_theme_loads_with_ink_outlined_panels() -> String:
	var theme: Theme = HudTheme.load_theme()
	if theme == null:
		return "hud_theme.tres did not load as a Theme"
	for variation in ["HeaderPanel", "MapPanel", "SidebarPanel", "TickerPanel"]:
		var box := theme.get_stylebox("panel", variation) as StyleBoxFlat
		if box == null:
			return "%s has no flat panel style" % variation
		# The ticker is a strip inside the map's own contour (HUD v3): an ink rule on its top edge.
		var edge: int = box.border_width_top if variation == "TickerPanel" else box.border_width_left
		if edge < (2 if variation == "TickerPanel" else 3) or Vector3(box.border_color.r - HudTheme.INK.r, box.border_color.g - HudTheme.INK.g, box.border_color.b - HudTheme.INK.b).length() > 0.01:
			return "%s lacks a heavy ink contour" % variation
	return "ok"


func test_main_scene_applies_the_theme_to_the_hud() -> String:
	var scene: Node = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	var hud := scene.get_node("ViewportContainer/SubViewport/HUDContainer") as Control
	var ok: bool = hud.theme != null and hud.theme == HudTheme.load_theme()
	var variation: String = String(scene.get_node("ViewportContainer/SubViewport/HUDContainer/TacticalMapPanel").theme_type_variation)
	scene.free()
	if not ok:
		return "HUDContainer does not carry hud_theme.tres"
	if variation != "MapPanel":
		return "map panel variation is %s" % variation
	return "ok"


func test_crt_filter_is_off_by_default() -> String:
	var scene: Node = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	var main: Variant = scene
	var mat := (scene.get_node("ViewportContainer") as SubViewportContainer).material as ShaderMaterial
	var scene_flag: Variant = mat.get_shader_parameter("enabled")
	var model_flag: bool = main.vector_orrery.crt_enabled
	scene.free()
	if scene_flag != false:
		return "scene CRT shader is enabled by default"
	if model_flag:
		return "VectorOrrery.crt_enabled is true by default"
	return "ok"


# --- Full pass (#105): every screen uses the theme and palette; focus is visible; CRT is opt-in ---

func _scene() -> Node:
	var scene = load(MAIN_SCENE_PATH).instantiate()
	scene.initialize_systems(RunController.new(null, 84))
	scene._resolve_child_nodes()
	scene._build_readouts()
	scene._refresh_readouts()
	return scene


## True when `panel` carries exactly the theme's StyleBox for `variation`.
func _uses_theme_style(panel: Panel, variation: String) -> bool:
	return String(panel.theme_type_variation) == variation \
		and panel.get_theme_stylebox("panel") == HudTheme.panel_style(variation)


func _near(a: Color, b: Color) -> bool:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length() < 0.01


func _rust_free_of_green(c: Color) -> bool:
	# A phosphor colour is one where green dominates both other channels.
	return not (c.g > c.r * 1.25 and c.g > c.b * 1.25)


func test_every_panel_variation_is_a_flat_ink_or_accent_plate() -> String:
	var theme: Theme = HudTheme.load_theme()
	for variation in HudTheme.PANEL_VARIATIONS:
		var box := theme.get_stylebox("panel", variation) as StyleBoxFlat
		if box == null:
			return "%s has no flat panel style" % variation
		if (box.border_width_top < 2) if variation == "TickerPanel" else (box.border_width_left < 4):
			return "%s lacks a heavy contour" % variation
		if box.corner_radius_top_left != 0:
			return "%s is rounded; the style is flat" % variation
	return "ok"


func test_palette_has_no_phosphor_green() -> String:
	for c in [HudTheme.INK, HudTheme.SLATE, HudTheme.BONE, HudTheme.BONE_DIM, HudTheme.PAPER, HudTheme.OCHRE, HudTheme.RUST, HudTheme.RUST_DARK, HudTheme.RUST_LIGHT, MainScene.HUD_TEXT_COLOR, MainScene.MODAL_BG_COLOR]:
		if not _rust_free_of_green(c):
			return "%s is phosphor green" % c
	return "ok"


func test_header_map_sidebar_and_ticker_use_the_theme() -> String:
	# Scene panels pick the theme up through HUDContainer once in the tree, so check the
	# variation name and the theme's own style for it (as the sample's test does).
	var scene := _scene()
	var want: Dictionary = {
		scene.header_panel: "HeaderPanelPaused" if scene.controller.sim_clock.paused else "HeaderPanel",
		scene.tactical_map_panel: "MapPanel",
		scene.sidebar_panel: "SidebarPanel",
		scene.ticker_panel: "TickerPanel",
	}
	var err := ""
	if scene.hud_container.theme != HudTheme.load_theme():
		err = "HUDContainer does not carry hud_theme.tres"
	for panel in want:
		var variation: String = want[panel]
		if String((panel as Panel).theme_type_variation) != variation:
			err = "%s variation is %s, want %s" % [(panel as Panel).name, (panel as Panel).theme_type_variation, variation]
			continue
		var box := HudTheme.panel_style(variation) as StyleBoxFlat
		var edge: int = box.border_width_top if variation == "TickerPanel" else box.border_width_left
		if edge < (2 if variation == "TickerPanel" else 4) or not (_near(box.border_color, HudTheme.INK) or _near(box.border_color, HudTheme.OCHRE)):
			err = "%s lacks an ink contour" % (panel as Panel).name
	scene.free()
	return "ok" if err == "" else err


func test_header_contour_turns_ochre_while_paused() -> String:
	var scene := _scene()
	scene.controller.sim_clock.set_paused(true)
	scene._refresh_readouts()
	var paused: bool = _uses_theme_style(scene.header_panel, "HeaderPanelPaused")
	scene.controller.sim_clock.set_paused(false)
	scene._refresh_readouts()
	var running: bool = _uses_theme_style(scene.header_panel, "HeaderPanel")
	scene.free()
	if not paused:
		return "paused header does not use HeaderPanelPaused"
	if not running:
		return "running header does not return to HeaderPanel"
	return "ok"


func test_trading_overlay_modal_and_its_focus_bar_use_the_theme() -> String:
	var scene := _scene()
	scene.loop.set_tab(M0Loop.Tab.MARKET)
	scene._refresh_readouts()
	# The v3 quote board is a paper plate over the map (the ladder's SidebarPanel), so its
	# focus bar is the paper one.
	var ok_style: bool = _uses_theme_style(scene.market_modal, "SidebarPanel")
	var bar_fill: Color = scene.market_highlight.color
	var bar_visible: bool = scene.market_highlight.visible and scene.market_modal.visible
	var bar_w: float = scene.market_highlight.size.x
	scene.free()
	if not ok_style:
		return "trading overlay is not on the paper plate"
	if not bar_visible or bar_w <= 0.0:
		return "trading overlay row focus bar is not shown"
	if bar_fill != MainScene.FOCUS_BAR_PAPER_FILL:
		return "focus bar is %s, not the theme fill" % bar_fill
	return "ok"


func test_chapter_11_and_collapse_use_the_alert_band_and_perks_the_teal_band() -> String:
	# HUD v3: every modal is the ModalPanel plate; its title band carries the kind.
	var scene := _scene()
	scene.loop._set_overlay(M0Loop.OVERLAY_CHAPTER_11)
	scene._refresh_readouts()
	var ch11: bool = _uses_theme_style(scene.resolution_modal, "ModalPanel") and (scene._res["band"] as HudKit.Plate).fill == MainScene.BANDS["alert"][0]
	scene.loop._set_overlay(M0Loop.OVERLAY_COLLAPSED)
	scene.loop.collapse_phase = M0Loop.PHASE_SUMMARY
	scene._refresh_readouts()
	var summary: bool = _uses_theme_style(scene.resolution_modal, "ModalPanel") and (scene._res["band"] as HudKit.Plate).fill == MainScene.BANDS["alert"][0]
	scene.loop.collapse_phase = M0Loop.PHASE_PERKS
	scene._refresh_readouts()
	var perks: bool = _uses_theme_style(scene.resolution_modal, "ModalPanel") and (scene._res["band"] as HudKit.Plate).fill == MainScene.BANDS["teal"][0]
	var perk_bar: bool = scene.resolution_focus_bar.visible
	scene.free()
	if not ch11:
		return "Chapter 11 is not the ModalPanel with the alert band"
	if not summary:
		return "collapse summary is not the ModalPanel with the alert band"
	if not perks:
		return "Golden Parachutes is not the ModalPanel with the teal band"
	if not perk_bar:
		return "Golden Parachutes cursor has no focus bar"
	return "ok"


func test_crisis_sleep_banner_and_settings_use_the_theme() -> String:
	var scene := _scene()
	var crisis_modal: bool = _uses_theme_style(scene.resolution_modal, "ModalPanel")
	var banner: bool = _uses_theme_style(scene.sleep_modal, "BannerPanel")
	var settings: bool = _uses_theme_style(scene.settings_modal, "ModalPanel")
	scene.free()
	if not crisis_modal:
		return "resolution modal does not start on the ModalPanel plate"
	if not banner:
		return "sleep banner is not a BannerPanel"
	if not settings:
		return "settings screen is not a ModalPanel"
	return "ok"


func test_every_modal_text_is_readable_on_its_plate() -> String:
	for variation in ["ModalPanel", "AlertPanel", "BannerPanel", "HeaderPanel", "TickerPanel"]:
		var box := HudTheme.panel_style(variation) as StyleBoxFlat
		# The ticker strip is paper (ink text), like the map and the ladder.
		var text_color: Color = HudTheme.INK if variation == "TickerPanel" else MainScene.HUD_TEXT_COLOR
		var ratio: float = HudTheme.contrast(text_color, box.bg_color)
		if ratio < HudTheme.MIN_TEXT_CONTRAST:
			return "%s: bone text only %.2f:1" % [variation, ratio]
	for sev in ["INFO", "WARNING", "CRITICAL"]:
		# HUD v3 carries severity on the category chip; its text must read on the chip.
		var chip: Array = MainScene._severity_chip(sev)
		var ratio2: float = HudTheme.contrast(chip[1], chip[0])
		if ratio2 < HudTheme.MIN_TEXT_CONTRAST:
			return "ticker %s chip text only %.2f:1" % [sev, ratio2]
		var ratio3: float = HudTheme.contrast(HudTheme.INK, (HudTheme.panel_style("TickerPanel") as StyleBoxFlat).bg_color)
		if ratio3 < HudTheme.MIN_TEXT_CONTRAST:
			return "ticker body text only %.2f:1 on the strip" % ratio3
	# Ink text on the ochre ladder bar, bone text on the dark focus bar.
	if HudTheme.contrast(HudTheme.INK, MainScene.FOCUS_BAR_PAPER_FILL) < HudTheme.MIN_TEXT_CONTRAST:
		return "ink on the ladder focus bar is below 4.5:1"
	if HudTheme.contrast(HudTheme.BONE, MainScene.FOCUS_BAR_DARK_FILL) < HudTheme.MIN_TEXT_CONTRAST:
		return "bone on the dark focus bar is below 4.5:1"
	return "ok"


func test_galnet_ticker_colours_follow_severity() -> String:
	var scene := _scene()
	scene.hud.post_headline("Test warning line", "MARKET", "WARNING")
	scene.hud.post_headline("Test critical line", "MARKET", "CRITICAL")
	scene._refresh_readouts()
	# Severity rides on the category chip (newest first): critical on top, then warning.
	var top: Color = (scene.ticker_chips[0] as HudKit.Plate).fill
	var next: Color = (scene.ticker_chips[1] as HudKit.Plate).fill
	var panel_ok: bool = String(scene.ticker_panel.theme_type_variation) == "TickerPanel"
	scene.free()
	if not panel_ok:
		return "ticker is not on the TickerPanel plate"
	if top != MainScene._severity_chip("CRITICAL")[0] or next != MainScene._severity_chip("WARNING")[0]:
		return "ticker chip colours %s / %s do not follow severity" % [top, next]
	return "ok"


func test_every_palette_keeps_ladder_swatches_contrasting_with_their_ink_outline() -> String:
	for id in Palette.CHOICES:
		for side in [Palette.bid_color(id), Palette.ask_color(id)]:
			var ratio: float = HudTheme.contrast(side, HudTheme.INK)
			# The design system's default bid teal (#1a6b75) is 2.81:1 on ink; the swatch
			# sits on the sidebar's PAPER_DEEP plate (3.39:1), so it must clear 3:1 on
			# the outline or on that ground.
			var on_ground: float = HudTheme.contrast(side, HudTheme.PAPER_DEEP)
			if maxf(ratio, on_ground) < HudTheme.MIN_GRAPHIC_CONTRAST:
				return "%s swatch %s is %.2f:1 against ink and %.2f:1 against the sidebar plate" % [id, side, ratio, on_ground]
	return "ok"


func test_ladder_tags_carry_the_ink_outline_and_the_glyphs_remain() -> String:
	var scene := _scene()
	scene.loop.set_tab(M0Loop.Tab.MARKET)
	var err := ""
	for id in Palette.CHOICES:
		scene.settings.set_palette(id)
		scene._refresh_readouts()
		var shown: int = 0
		for row in scene._ladder["rows"]:
			var tag: HudKit.Plate = row["tag"]
			if not tag.visible:
				continue
			shown += 1
			if tag.edge != HudTheme.INK or tag.border < 2.0:
				err = "%s: side tag has no ink outline" % id
		if shown < 2:
			err = "%s: ladder side tags missing" % id
		var text: String = scene.panel_text(scene.sidebar_panel)
		if not text.contains(Palette.BID_GLYPH + " BID") or not text.contains(Palette.ASK_GLYPH + " ASK"):
			err = "%s: +BID / -ASK markers missing" % id
	scene.settings.set_palette(Palette.DEFAULT)
	scene.free()
	return "ok" if err == "" else err


func test_gamepad_focus_is_drawn_on_the_ladder_the_zone_frame_and_the_settings_list() -> String:
	var scene := _scene()
	scene.loop.set_tab(M0Loop.Tab.MARKET)
	scene.hud.gamepad_focus.set_zone(GamepadFocus.Zone.ORDER_BOOK)
	scene._refresh_readouts()
	var ladder_bar: bool = scene.sidebar_focus_bar.visible and scene.sidebar_focus_bar.size.y > 0.0
	var ladder_rect: Rect2 = Rect2(scene.sidebar_focus_bar.position, scene.sidebar_focus_bar.size)
	var frame_on: bool = (scene.focus_frames[GamepadFocus.Zone.ORDER_BOOK] as Panel).visible
	var frame_off: bool = not (scene.focus_frames[GamepadFocus.Zone.TACTICAL_MAP] as Panel).visible
	scene.hud.gamepad_focus.step_ladder_cursor(1)
	scene._refresh_readouts()
	var moved: bool = scene.sidebar_focus_bar.position.y != ladder_rect.position.y
	scene.settings_menu.open()
	scene.settings_menu.cursor = 2
	scene._refresh_readouts()
	var settings_bar: bool = scene.settings_focus_bar.visible
	var frames_hidden: bool = not (scene.focus_frames[GamepadFocus.Zone.ORDER_BOOK] as Panel).visible and not scene.sidebar_focus_bar.visible
	scene.free()
	if not ladder_bar:
		return "ladder cursor has no focus bar"
	if not frame_on or not frame_off:
		return "zone frame does not follow the gamepad zone"
	if not moved:
		return "ladder focus bar did not move with the cursor"
	if not settings_bar:
		return "settings cursor has no focus bar"
	if not frames_hidden:
		return "map-level focus stays drawn behind the settings screen"
	return "ok"


func test_zone_frames_contrast_with_their_panels() -> String:
	var rust_frame := HudTheme.panel_style("FocusFrameRust") as StyleBoxFlat
	var ochre_frame := HudTheme.panel_style("FocusFrameOchre") as StyleBoxFlat
	var paper := HudTheme.panel_style("SidebarPanel") as StyleBoxFlat
	var slate := HudTheme.panel_style("ModalPanel") as StyleBoxFlat
	if HudTheme.contrast(rust_frame.border_color, paper.bg_color) < HudTheme.MIN_GRAPHIC_CONTRAST:
		return "rust focus frame is below 3:1 on the paper panels"
	if HudTheme.contrast(ochre_frame.border_color, slate.bg_color) < HudTheme.MIN_GRAPHIC_CONTRAST:
		return "ochre focus frame is below 3:1 on the slate panels"
	return "ok"


func test_crt_is_an_opt_in_setting_off_by_default_and_it_toggles_on() -> String:
	var scene := _scene()
	var mat := (scene.get_node("ViewportContainer") as SubViewportContainer).material as ShaderMaterial
	if AccessibilitySettings.new().crt_filter:
		scene.free()
		return "settings default to CRT on"
	if mat.get_shader_parameter("enabled") != false or scene.vector_orrery.crt_enabled:
		scene.free()
		return "CRT is on before the player asks for it"
	var row_index: int = -1
	var rows: Array = scene.settings_menu.rows()
	for i in rows.size():
		if int(rows[i]["kind"]) == SettingsMenu.Row.CRT:
			row_index = i
	if row_index < 0:
		scene.free()
		return "settings screen has no CRT row"
	scene.settings_menu.open()
	scene.settings_menu.cursor = row_index
	scene.settings_menu._activate()
	var on_shader: bool = mat.get_shader_parameter("enabled") == true
	var on_model: bool = scene.vector_orrery.crt_enabled
	scene._refresh_readouts()
	var row_text: String = scene.settings_label.text
	scene.settings_menu._activate()
	var off_again: bool = mat.get_shader_parameter("enabled") == false and not scene.vector_orrery.crt_enabled
	scene.free()
	if not on_shader or not on_model:
		return "activating the CRT row did not turn the filter on"
	if not row_text.contains(Loc.t("SET_CRT")) or not row_text.contains(Loc.t("SET_ON")):
		return "CRT row text is not the localized label and value: %s" % row_text
	if not off_again:
		return "activating the CRT row again did not turn it off"
	return "ok"


func test_crt_setting_persists_resets_and_ignores_hostile_values() -> String:
	var s := AccessibilitySettings.new()
	s.set_crt_filter(true)
	if not bool(s.to_dict()["crt_filter"]) or not AccessibilitySettings.from_dict(s.to_dict()).crt_filter:
		return "crt_filter did not round trip"
	s.reset_defaults()
	if s.crt_filter:
		return "reset_defaults left the CRT filter on"
	if AccessibilitySettings.from_dict({"crt_filter": "yes"}).crt_filter or AccessibilitySettings.from_dict({}).crt_filter:
		return "a missing or non-bool crt_filter did not fall back to off"
	return "ok"


func test_crt_label_is_localized_in_the_string_table() -> String:
	var csv: String = FileAccess.get_file_as_string("res://localization/agora_strings.csv")
	for key in ["SET_CRT", "SET_ON", "SET_OFF"]:
		if not csv.contains("\n%s," % key):
			return "%s missing from agora_strings.csv" % key
	return "ok"


# --- Design system foundations (docs/design-system, part of #73 Epic 6: Visual Identity) ---

const TOKENS_DIR := "res://../docs/design-system/tokens/"


func _css_vars(file: String) -> Dictionary:
	var out: Dictionary = {}
	var f := FileAccess.open(TOKENS_DIR + file, FileAccess.READ)
	if f == null:
		return out
	var re := RegEx.create_from_string("--(ag-[a-z0-9-]+)\\s*:\\s*([^;]+);")
	for m in re.search_all(f.get_as_text()):
		if not out.has(m.get_string(1)):  # first definition wins; palette overrides come later
			out[m.get_string(1)] = m.get_string(2).strip_edges()
	return out


func test_palette_constants_match_the_design_system_tokens() -> String:
	var css := _css_vars("colors.css")
	if css.size() < 20:
		return "tokens/colors.css not read (%d vars)" % css.size()
	var pairs := {"ag-ink": HudTheme.INK, "ag-slate": HudTheme.SLATE, "ag-bone": HudTheme.BONE, "ag-bone-dim": HudTheme.BONE_DIM, "ag-paper": HudTheme.PAPER, "ag-paper-deep": HudTheme.PAPER_DEEP, "ag-ochre": HudTheme.OCHRE, "ag-ochre-dark": HudTheme.OCHRE_DARK, "ag-rust": HudTheme.RUST, "ag-rust-dark": HudTheme.RUST_DARK, "ag-teal": HudTheme.TEAL, "ag-teal-dark": HudTheme.TEAL_DARK, "ag-void": HudTheme.VOID}
	for k in pairs:
		if not Color(css[k]).is_equal_approx(pairs[k]):
			return "%s: tokens %s, HudTheme %s" % [k, css[k], pairs[k].to_html(false)]
	if not Palette.bid_color(Palette.DEFAULT).is_equal_approx(Color(css["ag-bid"])) or not Palette.ask_color(Palette.DEFAULT).is_equal_approx(Color(css["ag-ask"])):
		return "default bid/ask differ from tokens %s / %s" % [css["ag-bid"], css["ag-ask"]]
	var pal := RegEx.create_from_string("data-palette=\"(\\w+)\"\\] \\{ --ag-bid: (#\\w+); --ag-ask: (#\\w+);")
	var f := FileAccess.open(TOKENS_DIR + "colors.css", FileAccess.READ)
	var seen: int = 0
	for m in pal.search_all(f.get_as_text()):
		seen += 1
		if not Palette.bid_color(m.get_string(1)).is_equal_approx(Color(m.get_string(2))) or not Palette.ask_color(m.get_string(1)).is_equal_approx(Color(m.get_string(3))):
			return "%s bid/ask differ from tokens" % m.get_string(1)
	return "ok" if seen == 2 else "expected deuteranopia and protanopia rows, saw %d" % seen


func test_line_shadow_focus_and_space_tokens_match_the_design_system() -> String:
	var css := _css_vars("form.css")
	if css.is_empty():
		return "tokens/form.css not read"
	if css["ag-line-panel"] != "%dpx" % HudTheme.OUTLINE_PANEL or css["ag-line-control"] != "%dpx" % HudTheme.OUTLINE_CONTROL or css["ag-line-rule"] != "%dpx" % HudTheme.OUTLINE_RULE:
		return "line widths differ from tokens"
	if css["ag-shadow-offset"] != "%dpx" % int(HudTheme.SHADOW_OFFSET.x) or HudTheme.SHADOW_OFFSET.x != HudTheme.SHADOW_OFFSET.y:
		return "shadow offset differs from tokens"
	for i in HudTheme.SPACE_SCALE.size():
		if css["ag-space-%d" % (i + 1)] != "%dpx" % HudTheme.SPACE_SCALE[i]:
			return "ag-space-%d differs" % (i + 1)
	if HudTheme.OUTLINE_NODE != float(HudTheme.OUTLINE_CONTROL) or HudTheme.OUTLINE_RING != float(HudTheme.OUTLINE_RULE) or HudTheme.RADIUS_FRAME != 0:
		return "node/ring/radius constants disagree"
	return "ok"


func test_type_roles_match_spec_and_the_theme_default_is_archivo_body() -> String:
	var want := {"display": [40, 800, 70], "title": [24, 800, 75], "readout": [20, 700, 85], "body": [16, 500, 100], "hint": [14, 600, 100], "label": [12, 700, 100]}
	var theme: Theme = HudTheme.load_theme()
	for role in want:
		if HudTheme.role_size(role) != want[role][0]:
			return "%s size %d" % [role, HudTheme.role_size(role)]
		var fv := HudTheme.role_font(role)
		if int(fv.variation_opentype[HudTheme.TAG_WGHT]) != want[role][1] or int(fv.variation_opentype[HudTheme.TAG_WDTH]) != want[role][2]:
			return "%s axes %s" % [role, str(fv.variation_opentype)]
		# The .tres Label variations carry the same roles.
		var tv: String = "Label" + role.capitalize()
		var tfv := theme.get_font("font", tv) as FontVariation
		if tfv == null or tfv.variation_opentype != fv.variation_opentype or theme.get_font_size("font_size", tv) != want[role][0]:
			return "%s differs from the .tres role" % tv
	if HudTheme.role_font("readout").opentype_features.get(HudTheme.TAG_TNUM, 0) != 1:
		return "READOUT lacks tabular figures"
	if HudTheme.role_font("label").spacing_glyph < 1:
		return "LABEL is not tracked"
	var dflt := theme.default_font as FontVariation
	if dflt == null or dflt.variation_opentype != HudTheme.role_font("body").variation_opentype or dflt.base_font.resource_path != HudTheme.FONT_PATH:
		return "theme default font is not Archivo BODY"
	if HudTheme.role_font("readout", 70).variation_opentype[HudTheme.TAG_WDTH] != 70:
		return "width override ignored"
	for role in want:
		if HudTheme.role_size(role) < AccessibilitySettings.MIN_FONT_SIZE:
			return "%s is under the 12 px floor" % role
	return "ok"
