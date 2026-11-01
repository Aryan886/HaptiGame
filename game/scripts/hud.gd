extends CanvasLayer
## Round HUD: top bar, HAPTICS OFF strip, status chips, crosshair and the F1
## debug view. Draws only what the game and bridge report; the motor ring shows
## the layout and commanded levels from telemetry and never computes output.

const UiTheme := preload("res://scripts/ui_theme.gd")
const Menus := preload("res://scripts/menus.gd")

var menus: Menus

var _top_bar: PanelContainer
var _scenario_label: Label
var _tag_label: Label
var _timer_box: HBoxContainer
var _timer_bar: TimerBar
var _timer_label: Label
var _pips: Pips
var _score_label: Label
var _off_strip: PanelContainer
var _haptics_chip: UiTheme.Chip
var _mode_chip: UiTheme.Chip
var _bridge_chip: UiTheme.Chip
var _debug_panel: PanelContainer
var _debug_label: Label
var _ring: RingView
var _crosshair: Crosshair
var _debug_wanted := true
var _in_play := true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UiTheme.theme()
	add_child(root)

	_build_top_bar(root)

	menus = Menus.new()
	root.add_child(menus)

	_off_strip = PanelContainer.new()
	_off_strip.add_theme_stylebox_override("panel", UiTheme.panel_box(UiTheme.AMBER, UiTheme.AMBER, Color(0.25, 0.15, 0.0, 0.7), 6.0))
	_off_strip.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_off_strip.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_off_strip.position.y = 72
	_off_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var strip_label := UiTheme.label("HAPTICS OFF  ·  PRESS E", UiTheme.SIZE_BODY, UiTheme.AMBER, true)
	_off_strip.add_child(strip_label)
	root.add_child(_off_strip)

	var chips := VBoxContainer.new()
	chips.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	chips.grow_vertical = Control.GROW_DIRECTION_BEGIN
	chips.position = Vector2(16, -16)
	chips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chips.add_theme_constant_override("separation", 6)
	root.add_child(chips)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chips.add_child(row)
	_haptics_chip = UiTheme.chip()
	row.add_child(_haptics_chip)
	_mode_chip = UiTheme.chip()
	row.add_child(_mode_chip)
	_bridge_chip = UiTheme.chip()
	_bridge_chip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	chips.add_child(_bridge_chip)

	_crosshair = Crosshair.new()
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_crosshair)

	_debug_panel = PanelContainer.new()
	_debug_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_debug_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_debug_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_debug_panel.position = Vector2(-16, -16)
	_debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_debug_panel)
	var box := VBoxContainer.new()
	_debug_panel.add_child(box)
	_ring = RingView.new()
	_ring.custom_minimum_size = Vector2(220, 220)
	box.add_child(_ring)
	_debug_label = UiTheme.label("", UiTheme.SIZE_SMALL, UiTheme.MUTED)
	_debug_label.custom_minimum_size = Vector2(360, 0)
	box.add_child(_debug_label)


func _build_top_bar(root: Control) -> void:
	var bar := PanelContainer.new()
	_top_bar = bar
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE, Control.PRESET_MODE_MINSIZE, 12)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(row)

	_scenario_label = UiTheme.label("", UiTheme.SIZE_LARGE, UiTheme.TEXT, true)
	row.add_child(_scenario_label)
	_tag_label = UiTheme.label("", UiTheme.SIZE_SMALL, UiTheme.MUTED, true)
	row.add_child(_tag_label)
	row.add_child(_spacer())

	_timer_box = HBoxContainer.new()
	_timer_box.add_theme_constant_override("separation", 10)
	_timer_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer_bar = TimerBar.new()
	_timer_bar.custom_minimum_size = Vector2(280, 12)
	_timer_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_timer_box.add_child(_timer_bar)
	_timer_label = UiTheme.label("", UiTheme.SIZE_LARGE, UiTheme.TEXT, true)
	_timer_label.custom_minimum_size = Vector2(54, 0)
	_timer_box.add_child(_timer_label)
	row.add_child(_timer_box)
	row.add_child(_spacer())

	_pips = Pips.new()
	_pips.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_pips)
	_score_label = UiTheme.label("", UiTheme.SIZE_LARGE, UiTheme.CYAN, true)
	_score_label.custom_minimum_size = Vector2(120, 0)
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_score_label)


## `timer_fraction` < 0 hides the timer bar (only the survival round has one).
func update_round(scenario_name: String, tag: String, health: int, max_health: int, score: int,
		timer_fraction: float, seconds_left: float) -> void:
	_scenario_label.text = scenario_name.to_upper()
	_tag_label.text = tag
	_pips.set_health(health, max_health)
	_score_label.text = "SCORE %02d" % score
	_timer_box.visible = timer_fraction >= 0.0
	if _timer_box.visible:
		_timer_bar.set_fraction(timer_fraction, seconds_left)
		_timer_label.text = "%ds" % ceili(seconds_left)
		_timer_label.add_theme_color_override("font_color", UiTheme.AMBER if seconds_left <= 10.0 else UiTheme.TEXT)


## `enabled` is the game's latch; `in_play` says whether output can be active.
func update_haptics(enabled: bool, in_play: bool, haptic_mode: String, status: String, telemetry: Dictionary) -> void:
	_off_strip.visible = not enabled
	if not enabled:
		_haptics_chip.set_state("HAPTICS OFF", UiTheme.AMBER)
	elif in_play:
		_haptics_chip.set_state("HAPTICS ON", UiTheme.GREEN)
	else:
		_haptics_chip.set_state("HAPTICS ON · STANDBY", UiTheme.GREEN.darkened(0.3))
	_mode_chip.set_state("NEAREST" if haptic_mode == "nearest" else "BLEND", UiTheme.CYAN)
	var chip := bridge_chip(status, telemetry)
	_bridge_chip.set_state(chip[0], chip[1])


func haptics_chip_text() -> String:
	return _haptics_chip.get_text()


func bridge_chip_text() -> String:
	return _bridge_chip.get_text()


func is_off_strip_visible() -> bool:
	return _off_strip.visible


## Honest label and colour for the bridge link. A UDP send is never "hardware
## connected"; an ACK means the firmware accepted a frame, not that it vibrated.
static func bridge_chip(status: String, telemetry: Dictionary) -> Array:
	match status:
		"simulated output":
			return ["SIMULATED OUTPUT", UiTheme.CYAN]
		"fake serial device (no hardware)":
			return ["FAKE DEVICE (NO HARDWARE)", UiTheme.CYAN]
		"bridge unavailable":
			return ["BRIDGE UNAVAILABLE", UiTheme.RED]
		"telemetry socket error":
			return ["TELEMETRY SOCKET ERROR ?", UiTheme.GREY]
	if status.begins_with("serial ready"):
		var ack = telemetry.get("last_ack_seq")
		return ["HARDWARE READY · ACK %s" % ("-" if ack == null else str(ack)), UiTheme.GREEN]
	var device := "FAKE DEVICE" if telemetry.get("output_backend") == "fake_serial" else "SERIAL"
	var link: String = telemetry.get("link_state", "unknown")
	if link == "stale":
		return ["%s STALE ?" % device, UiTheme.GREY]
	return ["%s %s" % [device, link.to_upper()], UiTheme.RED]


## Top bar, crosshair and debug view show only in play and pause; menus keep
## the chips and the HAPTICS OFF strip.
func set_in_play(in_play: bool) -> void:
	_in_play = in_play
	_top_bar.visible = in_play
	_crosshair.visible = in_play
	_debug_panel.visible = _debug_wanted and in_play


func set_debug_visible(shown: bool) -> void:
	_debug_wanted = shown
	_debug_panel.visible = shown and _in_play


func is_debug_visible() -> bool:
	return _debug_wanted


func flash_hit() -> void:
	_crosshair.flash = 1.0


func is_hit_marker_showing() -> bool:
	return _crosshair.flash > 0.0


func update_debug(text: String, telemetry: Dictionary, last_known_angles: Array, game_bearings: Array) -> void:
	_debug_label.text = text
	_ring.telemetry = telemetry
	_ring.last_known_angles = last_known_angles
	_ring.game_bearings = game_bearings
	_ring.queue_redraw()


func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## Thin corner brackets around the aim point, plus an X hit marker.
class Crosshair extends Control:
	var flash := 0.0

	func _process(delta: float) -> void:
		if flash > 0.0:
			flash = maxf(flash - delta * 4.0, 0.0)
			queue_redraw()

	func _draw() -> void:
		var color := Color(UiTheme.TEXT, 0.85)
		var gap := 7.0
		var arm := 5.0
		for s in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			var corner: Vector2 = s * gap
			draw_line(corner, corner - Vector2(s.x * arm, 0), color, 1.5)
			draw_line(corner, corner - Vector2(0, s.y * arm), color, 1.5)
		draw_circle(Vector2.ZERO, 1.5, color)
		if flash > 0.0:
			var hit := Color(UiTheme.RED, flash)
			var inner := 10.0
			var outer := 18.0 + 4.0 * (1.0 - flash)
			for s in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				draw_line(s * inner, s * outer, hit, 2.5)


## Health as filled or empty diamonds.
class Pips extends Control:
	var health := 0
	var max_health := 0

	func set_health(h: int, m: int) -> void:
		if h == health and m == max_health:
			return
		health = h
		max_health = m
		custom_minimum_size = Vector2(maxi(m, 0) * 24.0, 20.0)
		queue_redraw()

	func _draw() -> void:
		for i in max_health:
			var c := Vector2(12.0 + i * 24.0, size.y / 2.0)
			var pts := PackedVector2Array([c + Vector2(0, -8), c + Vector2(8, 0), c + Vector2(0, 8), c + Vector2(-8, 0), c + Vector2(0, -8)])
			var color := UiTheme.RED if health == 1 else UiTheme.CYAN
			if i < health:
				draw_colored_polygon(pts.slice(0, 4), Color(color, 0.85))
				draw_polyline(pts, color, 1.5)
			else:
				draw_polyline(pts, UiTheme.CYAN_DIM, 1.5)


## Segmented bar of the time left in the survival round.
class TimerBar extends Control:
	var fraction := 1.0
	var seconds := 0.0

	func set_fraction(f: float, s: float) -> void:
		fraction = clampf(f, 0.0, 1.0)
		seconds = s
		queue_redraw()

	func _draw() -> void:
		var segments := 12
		var gap := 3.0
		var w := (size.x - gap * (segments - 1)) / segments
		var color := UiTheme.AMBER if seconds <= 10.0 else UiTheme.CYAN
		for i in segments:
			var rect := Rect2(i * (w + gap), 0, w, size.y)
			draw_rect(rect, Color(UiTheme.CYAN_DIM, 0.35))
			var fill := clampf(fraction * segments - i, 0.0, 1.0)
			if fill > 0.0:
				draw_rect(Rect2(rect.position, Vector2(w * fill, size.y)), color)


class RingView extends Control:
	## Fresh motor_state telemetry, or empty when the bridge is unavailable.
	var telemetry: Dictionary = {}
	var last_known_angles: Array = []
	## Game-side target bearings (for comparison only, never used for output).
	var game_bearings: Array = []

	func _draw() -> void:
		var center := size / 2.0
		var radius := minf(size.x, size.y) / 2.0 - 22.0
		draw_arc(center, radius, 0, TAU, 64, Color(UiTheme.CYAN_DIM, 0.8), 1.5)
		# Forward marker: top of the ring is camera forward.
		draw_line(center + Vector2(0, -radius - 14), center + Vector2(0, -radius + 6), UiTheme.CYAN, 2.0)
		var font := UiTheme.FONT

		for b in game_bearings:
			draw_circle(center + _dir(b) * radius * 0.55, 4.0, Color(UiTheme.RED, 0.7))

		var fresh := not telemetry.is_empty()
		var angles: Array = telemetry["motor_angles_deg"] if fresh else last_known_angles
		if angles.is_empty():
			draw_string(font, center + Vector2(-50, 5), "layout unknown", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, UiTheme.MUTED)
			return
		var levels: Array = telemetry["motor_levels"] if fresh else []
		for i in angles.size():
			var p: Vector2 = center + _dir(angles[i]) * radius
			if fresh:
				var level := float(levels[i])
				draw_circle(p, 9.0 + 9.0 * level, Color(0.12, 0.16, 0.2).lerp(UiTheme.CYAN, level))
				draw_string(font, p + Vector2(-12, 30), "%.2f" % level, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UiTheme.TEXT)
			else:
				draw_circle(p, 9.0, UiTheme.GREY)
				draw_string(font, p + Vector2(-4, 30), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UiTheme.MUTED)
		if fresh and typeof(telemetry.get("bearing_deg")) != TYPE_NIL:
			draw_line(center, center + _dir(telemetry["bearing_deg"]) * radius * 0.85, UiTheme.AMBER, 3.0)

	## Bearing is clockwise from forward; screen up is forward.
	func _dir(bearing_deg) -> Vector2:
		var a := deg_to_rad(float(bearing_deg))
		return Vector2(sin(a), -cos(a))
