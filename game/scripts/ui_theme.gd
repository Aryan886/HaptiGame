extends RefCounted
## Shared look for every screen: palette, bundled font, sizes and the panel,
## button and status-chip factories. Tactical style: dark translucent panels,
## thin cyan lines and corner brackets; amber warns, red marks threats.

const FONT := preload("res://fonts/ChakraPetch-Regular.ttf")
const FONT_BOLD := preload("res://fonts/ChakraPetch-SemiBold.ttf")

const PANEL := Color(0.043, 0.071, 0.125, 0.75)  # #0B1220 at 75 %
const CYAN := Color("38e1ff")
const CYAN_DIM := Color("1f6f86")
const AMBER := Color("ffb020")
const RED := Color("ff3b3b")
const GREEN := Color("3ddc84")
const TEXT := Color("e6f1f5")
const MUTED := Color("8aa0ad")
const GREY := Color("5c6b75")

const SIZE_SMALL := 13
const SIZE_BODY := 17
const SIZE_LARGE := 22
const SIZE_HEADING := 34
const SIZE_TITLE := 76

static var _theme: Theme


## Theme for a UI root Control; children inherit it.
static func theme() -> Theme:
	if _theme == null:
		_theme = _build_theme()
	return _theme


## Translucent panel with a thin outline and bright corner brackets.
static func panel_box(border := CYAN_DIM, bracket := CYAN, fill := PANEL, margin := 10.0) -> StyleBox:
	var box := BracketBox.new()
	box.fill = fill
	box.border = border
	box.bracket = bracket
	box.set_content_margin_all(margin)
	return box


static func label(text := "", font_size := SIZE_BODY, color := TEXT, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	if bold:
		l.add_theme_font_override("font", FONT_BOLD)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func button(text: String, min_width := 280.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_width, 44)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	return b


## A small coloured status chip; call set_state() to change it.
static func chip() -> Chip:
	return Chip.new()


static func _build_theme() -> Theme:
	var t := Theme.new()
	t.default_font = FONT
	t.default_font_size = SIZE_BODY
	t.set_color("font_color", "Label", TEXT)
	t.set_stylebox("panel", "PanelContainer", panel_box())

	var normal := panel_box(CYAN_DIM, CYAN_DIM)
	var hover := panel_box(CYAN, CYAN, Color(CYAN, 0.16))
	var pressed := panel_box(CYAN, CYAN, Color(CYAN, 0.3))
	var focus := panel_box(CYAN, CYAN, Color(0, 0, 0, 0))
	var disabled := panel_box(GREY, GREY, Color(PANEL, 0.4))
	for box in [normal, hover, pressed, focus, disabled]:
		box.content_margin_left = 16.0
		box.content_margin_right = 16.0
	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("hover_pressed", "Button", pressed)
	t.set_stylebox("focus", "Button", focus)
	t.set_stylebox("disabled", "Button", disabled)
	t.set_font("font", "Button", FONT_BOLD)
	t.set_font_size("font_size", "Button", SIZE_LARGE - 2)
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", CYAN)
	t.set_color("font_focus_color", "Button", CYAN)
	t.set_color("font_pressed_color", "Button", TEXT)
	t.set_color("font_hover_pressed_color", "Button", TEXT)
	t.set_color("font_disabled_color", "Button", GREY)
	return t


## StyleBox drawn by hand: fill, 1 px outline and L-shaped corner brackets.
class BracketBox extends StyleBox:
	var fill := Color(0, 0, 0, 0)
	var border := Color(0, 0, 0, 0)
	var bracket := Color(0, 0, 0, 0)
	var bracket_len := 10.0

	func _draw(to_canvas_item: RID, rect: Rect2) -> void:
		var rs := RenderingServer
		if fill.a > 0.0:
			rs.canvas_item_add_rect(to_canvas_item, rect, fill)
		var r := rect.grow(-0.5)
		if border.a > 0.0:
			var corners := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y), r.position])
			rs.canvas_item_add_polyline(to_canvas_item, corners, PackedColorArray([border]), 1.0)
		if bracket.a <= 0.0 or bracket_len <= 0.0:
			return
		var n := minf(bracket_len, minf(r.size.x, r.size.y) / 2.0)
		for corner in [[r.position, 1, 1], [Vector2(r.end.x, r.position.y), -1, 1], [r.end, -1, -1], [Vector2(r.position.x, r.end.y), 1, -1]]:
			var p: Vector2 = corner[0]
			var line := PackedVector2Array([p + Vector2(0, n * corner[2]), p, p + Vector2(n * corner[1], 0)])
			rs.canvas_item_add_polyline(to_canvas_item, line, PackedColorArray([bracket]), 2.0)


class Chip extends PanelContainer:
	var _dot: ColorRect
	var _label: Label
	var _box: BracketBox

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_box = BracketBox.new()
		_box.bracket_len = 0.0
		_box.set_content_margin_all(5.0)
		_box.content_margin_left = 9.0
		_box.content_margin_right = 11.0
		add_theme_stylebox_override("panel", _box)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(row)
		_dot = ColorRect.new()
		_dot.custom_minimum_size = Vector2(8, 8)
		_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(_dot)
		_label = Label.new()
		_label.add_theme_font_override("font", FONT_BOLD)
		_label.add_theme_font_size_override("font_size", SIZE_SMALL + 1)
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(_label)

	func set_state(text: String, color: Color) -> void:
		_label.text = text
		_label.add_theme_color_override("font_color", color)
		_dot.color = color
		_box.fill = PANEL.blend(Color(color, 0.14))
		_box.border = Color(color, 0.7)
		queue_redraw()

	func get_text() -> String:
		return _label.text
