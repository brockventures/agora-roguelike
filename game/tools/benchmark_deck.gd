extends SceneTree
## Steam Deck Physical Hardware Benchmark & Profiler (#38).
## Validates:
##  1. Solid 60 FPS locked frame rate with 0 frame drops during transit/news animations.
##  2. Power draw < 9W (yielding >= 4.5 hours of battery life on OLED/LCD).
##  3. Native 1280x800 resolution with proper 16:10 scaling and no black bars.
##
## Usage:
##   godot --path game -s res://tools/benchmark_deck.gd [--headless] -- [options]
##   ./run_demo.sh --deck --benchmark [-- <options>]
##
## Options:
##   --frames <int>        Sample frames (default 600, ~10s at 60 FPS)
##   --warmup <int>        Warmup frames before sampling (default 30)
##   --out <path>          Write structured JSON telemetry to <path>
##   --verbose             Print detailed per-frame metrics
##   --help                Show usage information

const DEFAULT_FRAMES: int = 600
const DEFAULT_WARMUP: int = 30
const FRAME_BUDGET_MS: float = 16.6667
const FRAME_DROP_THRESHOLD_MS: float = 18.0

## Steam Deck power criteria. Power is measured from sysfs, never modeled.
const DECK_FALLBACK_BATTERY_WH: float = 40.0
const DECK_MAX_POWER_BUDGET_W: float = 9.0
const DECK_MIN_BATTERY_HOURS: float = 4.5
const BAT_DIR: String = "/sys/class/power_supply/BAT1"
const POWER_SAMPLE_EVERY: int = 30

var frames_to_sample: int = DEFAULT_FRAMES
var warmup_frames: int = DEFAULT_WARMUP
var out_path: String = ""
var verbose: bool = false

var main: Node = null


func _initialize() -> void:
	_parse_args()
	var status: String = await _run_benchmark()
	# INCOMPLETE (power unmeasured) exits 0 on purpose; only FAIL exits 1.
	quit(1 if status == "FAIL" else 0)


func _parse_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < args.size():
		var arg: String = args[i]
		match arg:
			"--frames":
				if i + 1 < args.size():
					frames_to_sample = maxi(30, int(args[i + 1]))
					i += 1
			"--warmup":
				if i + 1 < args.size():
					warmup_frames = maxi(0, int(args[i + 1]))
					i += 1
			"--out":
				if i + 1 < args.size():
					out_path = args[i + 1]
					i += 1
			"--verbose":
				verbose = true
			"-h", "--help":
				_print_help()
				quit(0)
				return
		i += 1


func _print_help() -> void:
	print("""AGORA Roguelike — Steam Deck Physical Hardware Benchmark (#38)
Usage:
  godot --path game -s res://tools/benchmark_deck.gd [--headless] -- [options]
  ./run_demo.sh --deck --benchmark

Options:
  --frames <int>   Number of frames to sample during animation workload (default: 600)
  --warmup <int>   Warmup frames before sampling (default: 30)
  --out <path>     Save structured JSON benchmark results to disk
  --verbose        Print extra per-frame telemetry
  -h, --help       Show this help message
""")


func _run_benchmark() -> String:
	print("============================================================")
	print(" AGORA ROGUELIKE — STEAM DECK PHYSICAL HARDWARE BENCHMARK   ")
	print("============================================================")

	# --- 1. Resolution, Scaling, and Viewport Verification ---
	var res_ok: bool = _verify_resolution_and_scaling()
	if not res_ok:
		printerr("FAIL: Viewport resolution, 16:10 scaling, or layout verification failed.")
		return "FAIL"

	# --- 2. Instantiate Main Scene and Setup Workload ---
	Palette.set_current(Palette.DEFAULT)
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		printerr("FAIL: Could not load res://scenes/main.tscn")
		return "FAIL"

	main = packed.instantiate()
	root.add_child(main)
	main.settings.reset_defaults()
	main.settings.set_text_scale(1.0)
	var rc: RunController = main.start_new_run(84)
	main.run_motion_from(0.0)

	# Setup destination and depart on transit corridor (Mars -> Ceres)
	if main.hud != null:
		main.hud.active_station = "ceres"
	main.loop.depart_to_selected()
	rc.sim_clock.resume()

	# Warmup frames to let shaders compile and layouts settle
	for w in range(warmup_frames):
		await process_frame

	if not rc.is_in_transit():
		printerr("FAIL: Transit corridor failed to initiate.")
		return "FAIL"

	# --- 3. Animation Workload & Frame Sampling Loop ---
	print("Sampling %d frames with active transit and news animations..." % frames_to_sample)
	var process_times_ms: Array = []
	var frame_deltas_ms: Array = []
	var draw_calls_samples: Array = []
	var apu_power_samples: Array = []
	var battery_power_samples: Array = []
	var apu_power_path: String = _amdgpu_power_path()
	var frame_drops: int = 0

	for f in range(frames_to_sample):
		# Exercise GalNet ticker wipe-in & news stream every 20 frames
		if f % 20 == 0 and main.hud != null:
			main.hud.post_headline(
				"Benchmark headline %d: convoy orbital transit Ceres corridor underway" % f,
				"MARKET",
				"INFO"
			)

		var t_start: int = Time.get_ticks_usec()
		await process_frame
		var t_elapsed_usec: int = Time.get_ticks_usec() - t_start
		var delta_ms: float = float(t_elapsed_usec) / 1000.0

		var proc_sec: float = Performance.get_monitor(Performance.TIME_PROCESS)
		var proc_ms: float = proc_sec * 1000.0

		# On headless/fast systems, process_frame runs at unbounded speed;
		# proc_ms measures actual engine work done in the frame.
		# In real display / VSync mode, delta_ms measures actual wall clock interval.
		var effective_frame_work_ms: float = proc_ms if DisplayServer.get_name() == "headless" else delta_ms

		process_times_ms.append(proc_ms)
		frame_deltas_ms.append(delta_ms)

		var dc: float = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		draw_calls_samples.append(dc)

		if f % POWER_SAMPLE_EVERY == 0:
			_sample_power(apu_power_path, apu_power_samples, battery_power_samples)

		if effective_frame_work_ms > FRAME_DROP_THRESHOLD_MS:
			frame_drops += 1
			if verbose:
				print("Frame drop detected at frame %d: %.2f ms (proc=%.2f ms)" % [f, delta_ms, proc_ms])

	# --- 4. Statistical Aggregation ---
	process_times_ms.sort()
	var sample_count: int = process_times_ms.size()
	var sum_proc: float = 0.0
	for t in process_times_ms:
		sum_proc += t
	var avg_proc_ms: float = sum_proc / float(sample_count)
	var median_proc_ms: float = process_times_ms[int(sample_count * 0.50)]
	var p95_proc_ms: float = process_times_ms[int(sample_count * 0.95)]
	var p99_proc_ms: float = process_times_ms[int(sample_count * 0.99)]
	var max_proc_ms: float = process_times_ms[sample_count - 1]

	var sum_dc: float = 0.0
	for dc_val in draw_calls_samples:
		sum_dc += dc_val
	var avg_draw_calls: float = sum_dc / float(sample_count)
	var static_mem_mb: float = Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)

	# --- 5. Power & Battery: measured from sysfs, never modeled ---
	var apu_power_w: float = _mean_or_unmeasured(apu_power_samples)
	var system_power_w: float = _mean_or_unmeasured(battery_power_samples)
	var battery_wh: float = _battery_capacity_wh()
	var battery_hours: float = -1.0
	if system_power_w > 0.0:
		battery_hours = battery_wh / system_power_w

	var power_status: String = "UNMEASURED"
	if system_power_w < 0.0:
		power_status = "UNMEASURED"
	elif system_power_w < DECK_MAX_POWER_BUDGET_W and battery_hours >= DECK_MIN_BATTERY_HOURS:
		power_status = "PASS"
	else:
		power_status = "FAIL"

	# Acceptance criteria checks
	var crit_fps: bool = (frame_drops == 0) and (avg_proc_ms < FRAME_BUDGET_MS)
	var crit_power: bool = power_status == "PASS"
	var crit_res: bool = res_ok

	var headless: bool = DisplayServer.get_name() == "headless"
	var fps_note: String = " (headless: engine work only, not display pacing)" if headless else ""

	var overall_status: String = "PASS"
	if not crit_fps or not crit_res or power_status == "FAIL":
		overall_status = "FAIL"
	elif power_status == "UNMEASURED":
		overall_status = "INCOMPLETE"

	# --- 6. Formatted Output ---
	print("------------------------------------------------------------")
	print("host: %s" % DisplayServer.get_name())
	print("Target Hardware:      Valve Steam Deck (Aerith LCD / Sephiroth OLED)")
	print("Native Resolution:    1280x800 (16:10 Display Aspect)")
	print("Scaling & Stretch:    canvas_items / keep (Zero Letterbox / Black Bars)")
	print("Target Frame Rate:    60 FPS Locked (16.67ms frame budget)")
	print("Workload:             Animated Sol Transit + GalNet News Ticker Wipes")
	print("------------------------------------------------------------")
	print("Frame results%s:" % fps_note)
	print("Frames Sampled:       %d frames" % sample_count)
	print("Average Process Time: %.2f ms / frame (%.1f%% of 16.67ms budget)" % [avg_proc_ms, (avg_proc_ms / FRAME_BUDGET_MS) * 100.0])
	print("Median Process Time:  %.2f ms" % median_proc_ms)
	print("P95 Process Time:     %.2f ms" % p95_proc_ms)
	print("P99 Process Time:     %.2f ms" % p99_proc_ms)
	print("Max Process Time:     %.2f ms" % max_proc_ms)
	print("Frame Drops (>18ms):  %d drops (%.2f%%)" % [frame_drops, (float(frame_drops) / float(sample_count)) * 100.0])
	print("Draw Calls (Avg):     %.1f calls / frame" % avg_draw_calls)
	print("Static Memory Footprint: %.2f MB" % static_mem_mb)
	print("------------------------------------------------------------")
	print("Power & Battery (measured on the Deck, not modeled):")
	print("  APU Power (amdgpu):   %s  (%d samples)" % [_fmt_w(apu_power_w), apu_power_samples.size()])
	print("  System Power (BAT1):  %s  (%d samples)" % [_fmt_w(system_power_w), battery_power_samples.size()])
	print("  Battery Capacity:     %.2f Wh" % battery_wh)
	var hours_text: String = ("%.2f hours" % battery_hours) if battery_hours >= 0.0 else "unmeasured"
	print("  Battery Life:         %s  (Target: >=4.5h)" % hours_text)
	print("  Power status:         %s" % power_status)
	if power_status == "UNMEASURED":
		print("  Reason: not on battery or no BAT1; run undocked on the Deck")
	print("------------------------------------------------------------")
	print("ACCEPTANCE CRITERIA STATUS:")
	print("  [%s] 60 FPS locked frame rate with 0 frame drops during transit/news%s" % ["PASS" if crit_fps else "FAIL", fps_note])
	print("  [%s] Power draw < 9W (>= 4.5h battery life on OLED/LCD)" % power_status)
	print("  [%s] Native 1280x800 resolution with 16:10 scaling and no black bars" % ("PASS" if crit_res else "FAIL"))
	print("============================================================")
	print("OVERALL RESULT: %s" % overall_status)
	if overall_status == "INCOMPLETE":
		print("Power was not measured, so this run cannot PASS. Undock, unplug, and re-run on the Deck.")

	# --- 7. Save JSON Telemetry if Requested ---
	if out_path != "":
		var telemetry: Dictionary = {
			"benchmark": "steam_deck_physical_hardware",
			"issue": 38,
			"timestamp": Time.get_datetime_string_from_system(true),
			"host": DisplayServer.get_name(),
			"resolution": {
				"width": 1280,
				"height": 800,
				"aspect_ratio": "16:10",
				"stretch_mode": "canvas_items",
				"stretch_aspect": "keep",
				"letterboxing": false,
				"passed": crit_res
			},
			"framerate": {
				"target_fps": 60,
				"budget_ms": FRAME_BUDGET_MS,
				"frames_sampled": sample_count,
				"avg_proc_time_ms": avg_proc_ms,
				"median_proc_time_ms": median_proc_ms,
				"p95_proc_time_ms": p95_proc_ms,
				"p99_proc_time_ms": p99_proc_ms,
				"max_proc_time_ms": max_proc_ms,
				"frame_drops": frame_drops,
				"headless": headless,
				"passed": crit_fps
			},
			"power_profiling": {
				"apu_power_w": apu_power_w,
				"system_power_w": system_power_w,
				"battery_wh": battery_wh,
				"battery_hours": battery_hours,
				"samples": {"apu": apu_power_samples.size(), "battery": battery_power_samples.size()},
				"status": power_status
			},
			"overall_status": overall_status,
			"overall_passed": overall_status == "PASS"
		}
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(telemetry, "\t"))
			f.close()
			print("Structured telemetry saved to: %s" % out_path)
		else:
			printerr("Warning: Could not open %s for writing." % out_path)

	if main != null:
		main.queue_free()

	return overall_status


func _verify_resolution_and_scaling() -> bool:
	var width = ProjectSettings.get_setting("display/window/size/viewport_width")
	var height = ProjectSettings.get_setting("display/window/size/viewport_height")
	var stretch_mode = ProjectSettings.get_setting("display/window/stretch/mode")
	var stretch_aspect = ProjectSettings.get_setting("display/window/stretch/aspect")
	var max_fps = ProjectSettings.get_setting("application/run/max_fps")

	if width != 1280:
		printerr("display/window/size/viewport_width != 1280 (got %s)" % str(width))
		return false
	if height != 800:
		printerr("display/window/size/viewport_height != 800 (got %s)" % str(height))
		return false
	if stretch_mode != "canvas_items":
		printerr("display/window/stretch/mode != 'canvas_items' (got %s)" % str(stretch_mode))
		return false
	if stretch_aspect != "keep":
		printerr("display/window/stretch/aspect != 'keep' (got %s)" % str(stretch_aspect))
		return false
	if max_fps != 60:
		printerr("application/run/max_fps != 60 (got %s)" % str(max_fps))
		return false

	# Verify aspect ratio is 16:10 (1.6)
	var aspect_ratio: float = float(width) / float(height)
	if absf(aspect_ratio - 1.6) > 0.001:
		printerr("Aspect ratio is not 16:10 (got %f)" % aspect_ratio)
		return false

	# Verify OrbitalHUD panels cover the 1280x800 area with no gaps
	var header_rect: Rect2 = OrbitalHUD.HEADER_RECT
	var map_rect: Rect2 = OrbitalHUD.TACTICAL_MAP_RECT
	var sidebar_rect: Rect2 = OrbitalHUD.SIDEBAR_RECT
	var ticker_rect: Rect2 = OrbitalHUD.TICKER_RECT

	if header_rect.size.x != 1280.0 or header_rect.size.y != 64.0:
		printerr("Header rect geometry mismatch")
		return false
	if map_rect.size.x != 880.0 or map_rect.size.y != 672.0:
		printerr("Map rect geometry mismatch")
		return false
	if sidebar_rect.size.x != 400.0 or sidebar_rect.size.y != 672.0:
		printerr("Sidebar rect geometry mismatch")
		return false
	if ticker_rect.size.x != 1280.0 or ticker_rect.size.y != 64.0:
		printerr("Ticker rect geometry mismatch")
		return false

	var total_h: float = header_rect.size.y + map_rect.size.y + ticker_rect.size.y
	if total_h != 800.0:
		printerr("Total panel height != 800.0 (got %f)" % total_h)
		return false
	var total_w: float = map_rect.size.x + sidebar_rect.size.x
	if total_w != 1280.0:
		printerr("Total panel width != 1280.0 (got %f)" % total_w)
		return false

	return true


## Battery and APU power readings from sysfs. Every value here is microunits
## (uW, uA, uV, uAh, uWh-free); _read_sysfs_uw converts to base units.
## Returns -1.0 when the file is missing or unreadable.
func _read_sysfs_uw(path: String) -> float:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1.0
	var line: String = f.get_line().strip_edges()
	f.close()
	if line.is_valid_int():
		return float(line.to_int()) / 1e6
	return -1.0


## Path to amdgpu's power1_average (APU package power, microwatts), or "" if absent.
func _amdgpu_power_path() -> String:
	for i in range(16):
		var name_path: String = "/sys/class/hwmon/hwmon%d/name" % i
		var f := FileAccess.open(name_path, FileAccess.READ)
		if f == null:
			continue
		var hwmon_name: String = f.get_line().strip_edges()
		f.close()
		if hwmon_name == "amdgpu":
			return "/sys/class/hwmon/hwmon%d/power1_average" % i
	return ""


func _battery_discharging() -> bool:
	var f := FileAccess.open(BAT_DIR + "/status", FileAccess.READ)
	if f == null:
		return false
	var status: String = f.get_line().strip_edges()
	f.close()
	return status == "Discharging"


## One power sample: APU watts always when readable; battery watts only while discharging.
func _sample_power(apu_path: String, apu_samples: Array, battery_samples: Array) -> void:
	if apu_path != "":
		var apu_w: float = _read_sysfs_uw(apu_path)
		if apu_w >= 0.0:
			apu_samples.append(apu_w)
	if _battery_discharging():
		var current_a: float = _read_sysfs_uw(BAT_DIR + "/current_now")
		var voltage_v: float = _read_sysfs_uw(BAT_DIR + "/voltage_now")
		if current_a != -1.0 and voltage_v != -1.0:
			battery_samples.append(absf(current_a) * voltage_v)


func _mean_or_unmeasured(samples: Array) -> float:
	if samples.is_empty():
		return -1.0
	var total: float = 0.0
	for s in samples:
		total += float(s)
	return total / float(samples.size())


## Pack capacity in Wh from charge_full (uAh) x voltage_min_design (uV); fallback 40 Wh.
func _battery_capacity_wh() -> float:
	var charge_ah: float = _read_sysfs_uw(BAT_DIR + "/charge_full")
	var design_v: float = _read_sysfs_uw(BAT_DIR + "/voltage_min_design")
	if charge_ah > 0.0 and design_v > 0.0:
		return charge_ah * design_v
	return DECK_FALLBACK_BATTERY_WH


func _fmt_w(watts: float) -> String:
	if watts < 0.0:
		return "unmeasured"
	return "%.2f W" % watts
