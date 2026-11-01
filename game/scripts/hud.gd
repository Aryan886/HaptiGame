extends CanvasLayer
## Round HUD: top bar, HAPTICS OFF strip, status chips, crosshair, the haptics
## widget (F1: off / motors only / full debug) and the practice feedback dial.
## Draws only what the game and bridge report; it never computes motor output.

const UiTheme := preload("res://scripts/ui_theme.gd")
const Menus := preload("res://scripts/menus.gd")
const HeadWidget := preload("res://scripts/head_widget.gd")
const DAMAGE_SHADER := preload("res://shaders/damage_vignette.gdshader")
const DAMAGE_FLASH_S := 0.3

enum Widget { OFF, MOTORS, FULL }

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
var _widget_panel: PanelContainer
var _head: HeadWidget
var _widget_footer: Label
var _debug_panel: PanelContainer
var _debug_label: Label
var _dial_panel: PanelContainer
var _dial: PracticeDial
var _dial_label: Label
var _crosshair: Crosshair
var _damage_rect: ColorRect
var _damage := 0.0
var _widget_mode := Widget.MOTORS
var _in_play := true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UiTheme.theme()
	add_child(root)

	# Under everything else: a symmetric red vignette when the player is hit.
	_damage_rect = ColorRect.new()
	_damage_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_damage_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_damage_rect.material = ShaderMaterial.new()
	_damage_rect.material.shader = DAMAGE_SHADER
	_damage_rect.visible = false
	root.add_child(_damage_rect)

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

	# Bottom-right column, growing upward: practice dial, debug text, widget.
	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	column.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	column.grow_vertical = Control.GROW_DIRECTION_BEGIN
	column.position = Vector2(-16, -16)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 8)
	root.add_child(column)

	_dial_panel = _column_panel(column)
	var dial_box := VBoxContainer.new()
	_dial_panel.add_child(dial_box)
	dial_box.add_child(UiTheme.label("PRACTICE FEEDBACK", UiTheme.SIZE_SMALL, UiTheme.CYAN, true))
	_dial = PracticeDial.new()
	_dial.custom_minimum_size = Vector2(150, 110)
	dial_box.add_child(_dial)
	_dial_label = UiTheme.label("", UiTheme.SIZE_SMALL, UiTheme.TEXT, true)
	dial_box.add_child(_dial_label)
	_dial_panel.visible = false

	_debug_panel = _column_panel(column)
	_debug_label = UiTheme.label("", UiTheme.SIZE_SMALL, UiTheme.MUTED)
	_debug_label.custom_minimum_size = Vector2(360, 0)
	_debug_panel.add_child(_debug_label)

	_widget_panel = _column_panel(column)
	var widget_box := VBoxContainer.new()
	widget_box.add_theme_constant_override("separation", 2)
	_widget_panel.add_child(widget_box)
	_head = HeadWidget.new()
	_head.custom_minimum_size = Vector2(150, 132)
	widget_box.add_child(_head)
	_widget_footer = UiTheme.label("", UiTheme.SIZE_SMALL, UiTheme.MUTED, true)
	_widget_footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	widget_box.add_child(_widget_footer)
	_apply_widget()


func _column_panel(column: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", UiTheme.panel_box(UiTheme.CYAN_DIM, UiTheme.CYAN, UiTheme.PANEL, 8.0))
	column.add_child(panel)
	return panel


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


## `timer_fraction` < 0 hides the timer bar (only the survival round has one);
## `score` < 0 hides the score and `max_health` 0 the pips (the trial has neither).
func update_round(scenario_name: String, tag: String, health: int, max_health: int, score: int,
		timer_fraction: float, seconds_left: float) -> void:
	_scenario_label.text = scenario_name.to_upper()
	_tag_label.text = tag
	_pips.set_health(health, max_health)
	_score_label.text = "SCORE %02d" % score
	_score_label.visible = score >= 0
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


## Top bar, crosshair and widget show only in play and pause; menus keep
## the chips and the HAPTICS OFF strip.
func set_in_play(in_play: bool) -> void:
	_in_play = in_play
	_top_bar.visible = in_play
	_crosshair.visible = in_play
	_apply_widget()


## Widget.OFF, MOTORS (head and motors) or FULL (adds drone dots, the selected
## bearing and telemetry text). game.gd decides the mode.
func set_widget_mode(mode: Widget) -> void:
	_widget_mode = mode
	_apply_widget()


func widget_mode() -> Widget:
	return _widget_mode


func is_widget_visible() -> bool:
	return _widget_panel.visible


func _apply_widget() -> void:
	_widget_panel.visible = _in_play and _widget_mode != Widget.OFF
	_debug_panel.visible = _in_play and _widget_mode == Widget.FULL
	_head.full_debug = _widget_mode == Widget.FULL
	_dial_panel.visible = _dial_panel.visible and _in_play


func _process(delta: float) -> void:
	if _damage > 0.0:
		_damage = maxf(_damage - delta / DAMAGE_FLASH_S, 0.0)
		_damage_rect.material.set_shader_parameter("strength", _damage)
		_damage_rect.visible = _damage > 0.0


## Uniform red flash on every screen edge; never directional.
func flash_damage() -> void:
	_damage = 1.0
	_damage_rect.material.set_shader_parameter("strength", 1.0)
	_damage_rect.visible = true


func is_damage_flash_showing() -> bool:
	return _damage_rect.visible


func flash_hit() -> void:
	_crosshair.flash = 1.0


func is_hit_marker_showing() -> bool:
	return _crosshair.flash > 0.0


## `game_bearings` and `debug_text` are only drawn in full debug.
func update_widget(telemetry: Dictionary, last_known_angles: Array, game_bearings: Array,
		footer: String, debug_text: String) -> void:
	_head.telemetry = telemetry
	_head.last_known_angles = last_known_angles
	_head.game_bearings = game_bearings if _widget_mode == Widget.FULL else []
	_widget_footer.text = footer
	_debug_label.text = debug_text if _widget_mode == Widget.FULL else ""


## Practice only, after a response: true bearing against the answer, in the
## trial frame (0 = view at spawn, clockwise).
func show_practice_feedback(true_bearing: float, response: float, signed_error: float) -> void:
	_dial.true_bearing = true_bearing
	_dial.response = response
	_dial.queue_redraw()
	_dial_label.text = "TRUE %d°   ANSWER %d°\nERROR %+d°" % [roundi(true_bearing), roundi(response), roundi(signed_error)]
	_dial_panel.visible = _in_play


func clear_practice_feedback() -> void:
	_dial_panel.visible = false


func is_practice_feedback_visible() -> bool:
	return _dial_panel.visible


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


## Dial for practice feedback: forward tick, true bearing (green) and the
## answer (cyan).
class PracticeDial extends Control:
	var true_bearing := 0.0
	var response := 0.0

	func _draw() -> void:
		var c := size / 2.0
		var r := minf(size.x, size.y) / 2.0 - 6.0
		draw_arc(c, r, 0, TAU, 48, UiTheme.CYAN_DIM, 1.5)
		draw_line(c + Vector2(0, -r - 4), c + Vector2(0, -r + 5), UiTheme.TEXT, 2.0)
		draw_line(c, c + _dir(true_bearing) * r, UiTheme.GREEN, 3.0)
		draw_circle(c + _dir(true_bearing) * r, 4.0, UiTheme.GREEN)
		draw_line(c, c + _dir(response) * r * 0.85, UiTheme.CYAN, 2.0)
		draw_circle(c, 3.0, UiTheme.TEXT)

	func _dir(bearing_deg: float) -> Vector2:
		var a := deg_to_rad(bearing_deg)
		return Vector2(sin(a), -cos(a))
