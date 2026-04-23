package renderer

Rect :: struct {
	pos:  [2]f32,
	size: [2]f32,
}

Renderable :: union {
	ShapeData,
	TextData,
}

draw :: proc(state: ^VulkanState, renderable: Renderable) {
	switch value in renderable {
	case ShapeData:
		draw_shape(state, value)
	case TextData:
		switch value.anchor {
		case .Baseline:
			draw_text(state, value.text, value.pos, value.style, value.zindex)
		case .TopLeft:
			draw_text_top_left(state, value.text, value.pos, value.style, value.zindex)
		}
	}
}

get_bounding_box :: proc(renderable: Renderable) -> Rect {
	switch value in renderable {
	case ShapeData:
		return get_shape_bounding_box(value)
	case TextData:
		switch value.anchor {
		case .Baseline:
			return get_text_bounding_box(value.text, value.pos, value.style)
		case .TopLeft:
			return get_text_bounding_box_top_left(value.text, value.pos, value.style)
		}
	}
	panic("unreachable")
}

point_in_renderable :: proc(point: [2]f32, renderable: Renderable) -> bool {
	switch value in renderable {
	case ShapeData:
		return point_in_shape(point, value)
	case TextData:
		return true
	}
	return false
}
