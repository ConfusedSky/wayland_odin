package rect

Rect :: struct {
	pos:  [2]f32,
	size: [2]f32,
}

contains_point :: proc(r: Rect, point: [2]f32) -> bool {
	return(
		point.x >= r.pos.x &&
		point.y >= r.pos.y &&
		point.x <= r.pos.x + r.size.x &&
		point.y <= r.pos.y + r.size.y \
	)
}
