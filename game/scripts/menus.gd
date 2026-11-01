extends Control
## Title, intro card, results, pause and controls screens. Owns no game state:
## every button emits chosen(action) and game.gd decides what happens.

signal chosen(action: String)

const UiTheme := preload("res://scripts/ui_theme.gd")
const CONTROLS := [
	["Mouse / left click", "Turn and look / shoot (trial: submit a direction)"],
	["1 – 5", "Start a scenario directly"],
	["E / S", "Enable haptics / stop haptics immediately"],
	["M", "Nearest-motor or blended (interpolated) output"],
	["H", "Hidden mode on or off (restarts the scenario)"],
	["F1", "Show or hide the motor dashboard (hidden in the trial)"],
	["Esc", "Pause or resume"],
	["R", "Restart with a new session (haptics turn off)"],
]

var screen := ""

var _dim: ColorRect
var _title: Control
var _title_buttons: HBoxContainer
var _center: CenterContainer
var _panel: PanelContainer
var _body: VBoxContainer


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	_dim = ColorRect.new()
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)

	_title = MarginContainer.new()
	_title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_title.add_theme_constant_override("margin_left", 96)
	_title.add_theme_constant_override("margin_top", 120)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_title)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	_title.add_child(column)
	column.add_child(UiTheme.label("PHANTOM DEFENSE", UiTheme.SIZE_TITLE, UiTheme.TEXT, true))
	var rule := ColorRect.new()
	rule.color = UiTheme.CYAN
	rule.custom_minimum_size = Vector2(420, 2)
	rule.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	column.add_child(rule)
	column.add_child(UiTheme.label("Find what you can't see.", UiTheme.SIZE_LARGE + 4, UiTheme.MUTED))
	column.add_child(_gap(24))
	_title_buttons = HBoxContainer.new()
	_title_buttons.add_theme_constant_override("separation", 40)
	column.add_child(_title_buttons)

	_center = CenterContainer.new()
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UiTheme.panel_box(UiTheme.CYAN_DIM, UiTheme.CYAN, Color(UiTheme.PANEL, 0.92), 28.0))
	_panel.custom_minimum_size = Vector2(620, 0)
	_center.add_child(_panel)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 12)
	_panel.add_child(_body)
	hide_all()


## `entries` is a list of [action, label, caption]; a caption starts a new column.
func show_title(entries: Array) -> void:
	_show("title", 0.35)
	_title.visible = true
	_clear(_title_buttons)
	var first: Button
	var column: VBoxContainer
	for e in entries:
		if e[2] != "" or column == null:
			column = VBoxContainer.new()
			column.add_theme_constant_override("separation", 8)
			_title_buttons.add_child(column)
			column.add_child(UiTheme.label(e[2], UiTheme.SIZE_SMALL, UiTheme.MUTED, true))
		var b := _button(e[1], e[0], column, 340.0)
		if first == null:
			first = b
	first.grab_focus.call_deferred()


func show_intro(heading: String, step: String, do_text: String, feel_text: String) -> void:
	_show("intro", 0.55)
	_center.visible = true
	_clear(_body)
	_header(heading, step)
	for part in [["DO", do_text], ["FEEL", feel_text]]:
		_body.add_child(UiTheme.label(part[0], UiTheme.SIZE_SMALL, UiTheme.CYAN, true))
		var text := UiTheme.label(part[1], UiTheme.SIZE_LARGE)
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.custom_minimum_size = Vector2(560, 0)
		_body.add_child(text)
	_buttons([["start", "Start"], ["back", "Back"]])


## `rows` is a list of [label, value]; `next_label` "" hides the Next button.
func show_results(heading: String, step: String, rows: Array, next_label: String) -> void:
	_show("results", 0.55)
	_center.visible = true
	_clear(_body)
	_header(heading, step)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 28)
	grid.add_theme_constant_override("v_separation", 8)
	_body.add_child(grid)
	for row in rows:
		grid.add_child(UiTheme.label(str(row[0]).to_upper(), UiTheme.SIZE_SMALL + 1, UiTheme.MUTED, true))
		var value := UiTheme.label(str(row[1]), UiTheme.SIZE_LARGE, UiTheme.TEXT, true)
		value.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		value.custom_minimum_size = Vector2(380, 0)
		grid.add_child(value)
	var actions := []
	if next_label != "":
		actions.append(["next", next_label])
	actions.append_array([["retry", "Retry"], ["title", "Title"]])
	_buttons(actions)


func show_pause() -> void:
	_show("paused", 0.55)
	_center.visible = true
	_clear(_body)
	_header("Paused", "")
	_buttons([["resume", "Resume"], ["restart", "Restart"], ["controls", "Controls"], ["title", "Title"]], true)


func show_controls() -> void:
	_show("controls", 0.55)
	_center.visible = true
	_clear(_body)
	_header("Controls", "")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 6)
	_body.add_child(grid)
	for row in CONTROLS:
		grid.add_child(UiTheme.label(row[0], UiTheme.SIZE_BODY, UiTheme.CYAN, true))
		grid.add_child(UiTheme.label(row[1], UiTheme.SIZE_BODY))
	_buttons([["controls_back", "Back"]])


func hide_all() -> void:
	screen = ""
	visible = false
	_title.visible = false
	_center.visible = false


## Labels of the buttons on the current screen, in order (used by the checks).
func button_labels() -> Array:
	var root: Control = _title_buttons if screen == "title" else _body
	return root.find_children("*", "Button", true, false).map(func(b): return b.text)


func _show(name: String, dim: float) -> void:
	screen = name
	visible = true
	_title.visible = false
	_center.visible = false
	_dim.color = Color(0.01, 0.02, 0.05, dim)


func _header(heading: String, step: String) -> void:
	if step != "":
		_body.add_child(UiTheme.label(step.to_upper(), UiTheme.SIZE_SMALL, UiTheme.CYAN, true))
	_body.add_child(UiTheme.label(heading.to_upper(), UiTheme.SIZE_HEADING, UiTheme.TEXT, true))
	var rule := ColorRect.new()
	rule.color = UiTheme.CYAN_DIM
	rule.custom_minimum_size = Vector2(0, 1)
	_body.add_child(rule)


func _buttons(actions: Array, vertical := false) -> void:
	_body.add_child(_gap(6))
	var box: BoxContainer = VBoxContainer.new() if vertical else HBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_body.add_child(box)
	var first: Button
	for a in actions:
		var b := _button(a[1], a[0], box, 260.0 if vertical else 150.0)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT if vertical else HORIZONTAL_ALIGNMENT_CENTER
		if first == null:
			first = b
	first.grab_focus.call_deferred()


func _button(text: String, action: String, parent: Control, width: float) -> Button:
	var b := UiTheme.button(text, width)
	b.pressed.connect(func(): chosen.emit(action))
	parent.add_child(b)
	return b


func _gap(height: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
