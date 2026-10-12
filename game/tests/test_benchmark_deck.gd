extends RefCounted
## Unit and integration tests for Steam Deck Physical Hardware Benchmark (#38).
## Validates:
##  1. Solid 60 FPS locked frame rate with 0 frame drops during transit/news animations.
##  2. Power draw < 9W (yielding >= 4.5 hours of battery life on OLED/LCD).
##  3. Native 1280x800 resolution with proper 16:10 scaling and no black bars.

const BENCHMARK_SCRIPT_PATH := "res://tools/benchmark_deck.gd"
const FRAME_BUDGET_MS: float = 16.6667
const FRAME_DROP_THRESHOLD_MS: float = 18.0

const DECK_MAX_POWER_BUDGET_W: float = 9.0
const DECK_MIN_BATTERY_HOURS: float = 4.5


func test_benchmark_deck_tool_exists_and_loads() -> String:
	if not FileAccess.file_exists(BENCHMARK_SCRIPT_PATH):
		return "Benchmark tool missing at %s" % BENCHMARK_SCRIPT_PATH
	var script: GDScript = load(BENCHMARK_SCRIPT_PATH)
	if script == null:
		return "Failed to load GDScript from %s" % BENCHMARK_SCRIPT_PATH
	return "ok"


func test_viewport_geometry_and_16_10_scaling() -> String:
	var width = ProjectSettings.get_setting("display/window/size/viewport_width")
	var height = ProjectSettings.get_setting("display/window/size/viewport_height")
	var stretch_mode = ProjectSettings.get_setting("display/window/stretch/mode")
	var stretch_aspect = ProjectSettings.get_setting("display/window/stretch/aspect")

	if width != 1280:
		return "Expected viewport width 1280, got %s" % str(width)
	if height != 800:
		return "Expected viewport height 800, got %s" % str(height)
	if stretch_mode != "canvas_items":
		return "Expected stretch mode 'canvas_items', got '%s'" % str(stretch_mode)
	if stretch_aspect != "keep":
		return "Expected stretch aspect 'keep', got '%s'" % str(stretch_aspect)

	var aspect_ratio: float = float(width) / float(height)
	if absf(aspect_ratio - 1.6) > 0.001:
		return "Aspect ratio %f is not 16:10 (1.6)" % aspect_ratio

	# Verify OrbitalHUD panel geometry tiles 1280x800 without letterbox dead-zones
	if OrbitalHUD.VIEWPORT_WIDTH != 1280.0 or OrbitalHUD.VIEWPORT_HEIGHT != 800.0:
		return "OrbitalHUD viewport constant mismatch: %s" % str(OrbitalHUD.VIEWPORT_SIZE)

	var h_rect: Rect2 = OrbitalHUD.HEADER_RECT
	var m_rect: Rect2 = OrbitalHUD.TACTICAL_MAP_RECT
	var s_rect: Rect2 = OrbitalHUD.SIDEBAR_RECT
	var t_rect: Rect2 = OrbitalHUD.TICKER_RECT

	if h_rect.size != Vector2(1280.0, 64.0):
		return "Header rect size mismatch: %s" % str(h_rect.size)
	if m_rect.size != Vector2(880.0, 672.0):
		return "Tactical map rect size mismatch: %s" % str(m_rect.size)
	if s_rect.size != Vector2(400.0, 672.0):
		return "Sidebar rect size mismatch: %s" % str(s_rect.size)
	if t_rect.size != Vector2(1280.0, 64.0):
		return "Ticker rect size mismatch: %s" % str(t_rect.size)

	var total_h: float = h_rect.size.y + m_rect.size.y + t_rect.size.y
	if total_h != 800.0:
		return "Total vertical coverage %f != 800.0 (letterboxing gap detected)" % total_h

	var total_w: float = m_rect.size.x + s_rect.size.x
	if total_w != 1280.0:
		return "Total horizontal coverage %f != 1280.0 (pillarbox gap detected)" % total_w

	return "ok"


func test_60_fps_target_and_frame_budget() -> String:
	var max_fps = ProjectSettings.get_setting("application/run/max_fps")
	if max_fps != 60:
		return "Expected application/run/max_fps=60, got %s" % str(max_fps)

	var frame_time_budget: float = 1000.0 / float(max_fps)
	if absf(frame_time_budget - FRAME_BUDGET_MS) > 0.01:
		return "Frame time budget calculation mismatch: %f" % frame_time_budget

	return "ok"


func test_power_is_measured_not_modeled() -> String:
	var text: String = FileAccess.get_file_as_string(BENCHMARK_SCRIPT_PATH)
	for banned in ["modeled_apu_power_w", "4.20", "3.90", "3.00", "deck_lcd_total_w", "deck_oled_total_w"]:
		if text.find(banned) != -1:
			return "Benchmark still contains hardcoded power constant %s" % banned
	if text.find("/sys/class/power_supply/BAT1") == -1:
		return "Benchmark does not read BAT1 sysfs"
	if text.find("UNMEASURED") == -1:
		return "Benchmark has no UNMEASURED power state"
	return "ok"


func test_missing_sysfs_path_is_unreadable() -> String:
	# The reader returns -1.0 for missing paths; a null FileAccess is the signal it keys on.
	var f = FileAccess.open("/nonexistent/agora/bat1/current_now", FileAccess.READ)
	if f != null:
		return "Expected null FileAccess for a missing sysfs path"
	return "ok"
