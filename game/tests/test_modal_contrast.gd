extends RefCounted
## Modal body text must be readable: WCAG contrast >= 4.5 against the modal panel.
## Regression: the resolution modal (run summary, perk select, Chapter 11, crisis)
## forced a dark red font that was illegible on the near-black panel.

const MIN_RATIO := 4.5


static func _lin(c: float) -> float:
	return c / 12.92 if c <= 0.03928 else pow((c + 0.055) / 1.055, 2.4)


static func _luminance(c: Color) -> float:
	return 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b)


static func contrast(a: Color, b: Color) -> float:
	var la: float = _luminance(a)
	var lb: float = _luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


## Font colour after the label's own and every ancestor's modulate is applied.
static func _effective_color(label: Control) -> Color:
	var c: Color = label.get_theme_color("font_color")
	var n: Node = label
	while n is CanvasItem:
		var ci := n as CanvasItem
		c = Color(c.r * ci.modulate.r * ci.self_modulate.r, c.g * ci.modulate.g * ci.self_modulate.g, c.b * ci.modulate.b * ci.self_modulate.b, 1.0)
		n = n.get_parent()
	return c


func _scene():
	var scene = load("res://scenes/main.tscn").instantiate()
	scene.initialize_systems(RunController.new(null, 84))
	scene._resolve_child_nodes()
	scene._build_readouts()
	return scene


func test_resolution_modal_text_contrast() -> String:
	var scene = _scene()
	var label: Label = scene.resolution_label
	var box := scene.resolution_modal.get_theme_stylebox("panel") as StyleBoxFlat
	var fg: Color = _effective_color(label)
	var ratio: float = contrast(fg, box.bg_color)
	scene.free()
	if ratio < MIN_RATIO:
		return "resolution modal contrast %.2f < %.1f (fg %s on %s)" % [ratio, MIN_RATIO, fg, box.bg_color]
	return "ok"


func test_resolution_modal_uses_hud_text_palette() -> String:
	var scene = _scene()
	var modal_fg: Color = scene.resolution_label.get_theme_color("font_color")
	var hud_fg: Color = scene._ticket["title"].get_theme_color("font_color")
	scene.free()
	if modal_fg != hud_fg:
		return "modal text %s differs from HUD text %s" % [modal_fg, hud_fg]
	return "ok"


func test_contrast_helper_sanity() -> String:
	if absf(contrast(Color.WHITE, Color.BLACK) - 21.0) > 0.01:
		return "white on black should be 21:1"
	if contrast(Color(1.0, 0.45, 0.4), Color(0.02, 0.06, 0.04)) < 1.0:
		return "ratio below 1"
	return "ok"
