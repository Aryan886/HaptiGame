extends CanvasLayer
## Round HUD plus an F1 debug view. The motor ring draws only the layout and
## commanded levels reported by the bridge; it never computes motor output.

var _round_label: Label
var _haptics_label: Label
var _message_label: Label
var _debug_panel: PanelContainer
var _debug_label: Label
var _ring: RingView
var _crosshair: Crosshair


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_round_label = _make_label(22)
	_round_label.position = Vector2(16, 12)
	root.add_child(_round_label)

	_haptics_label = _make_label(18)
	_haptics_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_haptics_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_haptics_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_haptics_label.position = Vector2(-16, 12)
	root.add_child(_haptics_label)

	_message_label = _make_label(30)
	_message_label.set_anchors_preset(Control.PRESET_CENTER)
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_message_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_message_label.position.y = 90
	root.add_child(_message_label)

	_crosshair = Crosshair.new()
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	root.add_child(_crosshair)

	_debug_panel = PanelContainer.new()
	_debug_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_debug_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_debug_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_debug_panel.position = Vector2(-16, -16)
	root.add_child(_debug_panel)
	var box := VBoxContainer.new()
	_debug_panel.add_child(box)
	_ring = RingView.new()
	_ring.custom_minimum_size = Vector2(220, 220)
	box.add_child(_ring)
	_debug_label = _make_label(14)
	_debug_label.custom_minimum_size = Vector2(360, 0)
	box.add_child(_debug_label)


func update_round(text: String) -> void:
	_round_label.text = text


func update_haptics(text: String, enabled: bool) -> void:
	_haptics_label.text = text
	_haptics_label.modulate = Color(0.6, 1.0, 0.6) if enabled else Color(1.0, 0.75, 0.4)


func show_message(text: String) -> void:
	_message_label.text = text


func set_debug_visible(shown: bool) -> void:
	_debug_panel.visible = shown


func is_debug_visible() -> bool:
	return _debug_panel.visible


func flash_hit() -> void:
	_crosshair.flash = 1.0


func update_debug(text: String, telemetry: Dictionary, last_known_angles: Array, game_bearings: Array) -> void:
	_debug_label.text = text
	_ring.telemetry = telemetry
	_ring.last_known_angles = last_known_angles
	_ring.game_bearings = game_bearings
	_ring.queue_redraw()


func _make_label(font_size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


class Crosshair extends Control:
	var flash := 0.0

	func _process(delta: float) -> void:
		if flash > 0.0:
			flash = maxf(flash - delta * 4.0, 0.0)
			queue_redraw()

	func _draw() -> void:
		var color := Color.WHITE.lerp(Color(1, 0.3, 0.2), flash)
		var size := 10.0 + 6.0 * flash
		draw_line(Vector2(-size, 0), Vector2(-3, 0), color, 2.0)
		draw_line(Vector2(3, 0), Vector2(size, 0), color, 2.0)
		draw_line(Vector2(0, -size), Vector2(0, -3), color, 2.0)
		draw_line(Vector2(0, 3), Vector2(0, size), color, 2.0)


class RingView extends Control:
	## Fresh motor_state telemetry, or empty when the bridge is unavailable.
	var telemetry: Dictionary = {}
	var last_known_angles: Array = []
	## Game-side target bearings (for comparison only, never used for output).
	var game_bearings: Array = []

	func _draw() -> void:
		var center := size / 2.0
		var radius := minf(size.x, size.y) / 2.0 - 22.0
		draw_arc(center, radius, 0, TAU, 64, Color(1, 1, 1, 0.25), 2.0)
		# Forward marker: top of the ring is camera forward.
		draw_line(center + Vector2(0, -radius - 14), center + Vector2(0, -radius + 6), Color.WHITE, 2.0)
		var font := ThemeDB.fallback_font

		for b in game_bearings:
			draw_circle(center + _dir(b) * radius * 0.55, 4.0, Color(1, 0.4, 0.3, 0.7))

		var fresh := not telemetry.is_empty()
		var angles: Array = telemetry["motor_angles_deg"] if fresh else last_known_angles
		if angles.is_empty():
			draw_string(font, center + Vector2(-50, 5), "layout unknown", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.7, 0.7, 0.7))
			return
		var levels: Array = telemetry["motor_levels"] if fresh else []
		for i in angles.size():
			var p: Vector2 = center + _dir(angles[i]) * radius
			if fresh:
				var level := float(levels[i])
				draw_circle(p, 9.0 + 9.0 * level, Color(0.2, 0.2, 0.2).lerp(Color(0.2, 1.0, 0.5), level))
				draw_string(font, p + Vector2(-12, 30), "%.2f" % level, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
			else:
				draw_circle(p, 9.0, Color(0.45, 0.45, 0.45))
				draw_string(font, p + Vector2(-4, 30), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.7, 0.7, 0.7))
		if fresh and typeof(telemetry.get("bearing_deg")) != TYPE_NIL:
			draw_line(center, center + _dir(telemetry["bearing_deg"]) * radius * 0.85, Color(1, 0.9, 0.2), 3.0)

	## Bearing is clockwise from forward; screen up is forward.
	func _dir(bearing_deg) -> Vector2:
		var a := deg_to_rad(float(bearing_deg))
		return Vector2(sin(a), -cos(a))
