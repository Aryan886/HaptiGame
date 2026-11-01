extends Control
## Top-down head wearing the haptic headband. Screen up is camera forward
## (the nose). Motors sit at the telemetry motor_angles_deg and grow and glow
## with their commanded level. Draws only what the bridge reports; it never
## computes motor output.

const UiTheme := preload("res://scripts/ui_theme.gd")

## Fresh motor_state telemetry, or empty when the bridge is unavailable.
var telemetry: Dictionary = {}
## Last layout the bridge reported; drawn grey with "?" while telemetry is stale.
var last_known_angles: Array = []
## Full debug only: game-side target bearings, for comparison (never used for output).
var game_bearings: Array = []
var full_debug := false

var _shown: Array = []  # displayed levels, eased toward the commanded ones


func _process(delta: float) -> void:
	var target: Array = telemetry.get("motor_levels", [])
	if _shown.size() != target.size():
		_shown = target.duplicate()
	var k := minf(delta * 18.0, 1.0)
	for i in _shown.size():
		_shown[i] = lerpf(_shown[i], float(target[i]), k)
	queue_redraw()


func _draw() -> void:
	var c := size / 2.0
	var band := minf(size.x, size.y) / 2.0 - 17.0
	var head := Vector2(band * 0.5, band * 0.6)
	var font := UiTheme.FONT_BOLD

	# Head, ears and nose wedge.
	for side in [-1.0, 1.0]:
		var start: float = -PI / 2 if side > 0 else PI / 2
		draw_arc(c + Vector2(side * head.x, 0), 4.0, start, start + PI, 10, UiTheme.CYAN_DIM, 1.5)
	var outline := _ellipse(c, head, 32)
	draw_colored_polygon(outline, Color(0.07, 0.11, 0.17, 0.95))
	outline.append(outline[0])
	draw_polyline(outline, UiTheme.CYAN_DIM, 1.5)
	draw_colored_polygon(PackedVector2Array([c + Vector2(-6, -head.y + 2), c + Vector2(0, -head.y - 8), c + Vector2(6, -head.y + 2)]), UiTheme.CYAN)
	draw_arc(c, band, 0, TAU, 72, Color(UiTheme.CYAN_DIM, 0.7), 1.0)

	var fresh := not telemetry.is_empty()
	if full_debug:
		for b in game_bearings:
			draw_circle(c + _dir(b) * band * 0.8, 3.0, Color(UiTheme.RED, 0.8))
		if fresh and typeof(telemetry.get("bearing_deg")) != TYPE_NIL:
			draw_line(c, c + _dir(telemetry["bearing_deg"]) * band * 0.92, UiTheme.AMBER, 2.0)

	var angles: Array = telemetry["motor_angles_deg"] if fresh else last_known_angles
	if angles.is_empty():
		_text(font, c + Vector2(0, band * 0.85), "LAYOUT UNKNOWN", 11, UiTheme.MUTED)
		return
	var lit := UiTheme.RED if fresh and telemetry.get("pulse_active", false) == true else UiTheme.CYAN
	for i in angles.size():
		var p: Vector2 = c + _dir(angles[i]) * band
		var label_pos: Vector2 = c + _dir(angles[i]) * (band + 11.0)
		if not fresh or i >= _shown.size():
			draw_circle(p, 4.5, UiTheme.GREY)
			_text(font, label_pos, "?", 11, UiTheme.MUTED)
			continue
		var level: float = clampf(_shown[i], 0.0, 1.0)
		var r := 4.0 + 7.0 * level
		if level > 0.01:
			for g in 3:
				draw_circle(p, r + 3.0 * (g + 1), Color(lit, (0.12 + 0.25 * level) / (g + 1)))
		draw_circle(p, r, Color(0.12, 0.17, 0.22).lerp(lit, minf(level * 1.6, 1.0)))
		draw_arc(p, r, 0, TAU, 16, Color(lit, 0.5 + 0.5 * level), 1.0)
		_text(font, label_pos, "M%d" % (i + 1), 10, UiTheme.TEXT if level > 0.01 else UiTheme.MUTED)


func _text(font: Font, center: Vector2, text: String, font_size: int, color: Color) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	draw_string(font, center + Vector2(-w.x / 2.0, w.y / 2.0 - 3.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


static func _ellipse(c: Vector2, radii: Vector2, points: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in points:
		var a := TAU * i / points
		out.append(c + Vector2(cos(a) * radii.x, sin(a) * radii.y))
	return out


## Bearing is clockwise from forward; screen up is forward.
static func _dir(bearing_deg) -> Vector2:
	var a := deg_to_rad(float(bearing_deg))
	return Vector2(sin(a), -cos(a))
