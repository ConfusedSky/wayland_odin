package component

import renderer "../renderer"

Grid :: struct(N: int) {
	zindex:           f32,
	cells:            [N][N]Component,
	has_border:       bool,
	line_width:       f32,
	line_color:       [4]f32,
	background_color: [4]f32,
}

make_grid_vtable :: proc($N: int) -> ComponentVTable {
	return ComponentVTable {
		update = nil,
		render = proc(this_ptr: rawptr, state: ^renderer.VulkanState, cinfo: ComponentInfo) {
			_render_grid((^Grid(N))(this_ptr), state, cinfo)
		},
	}
}

grid_into_component :: proc(grid: ^Grid($N), component: ^Component) {
	component.vtable = make_grid_vtable(N)
	component.ctx = grid
}

_render_grid :: proc(grid: ^Grid($N), state: ^renderer.VulkanState, cinfo: ComponentInfo) {
	bbox := cinfo.bbox

	border_offset: f32 = grid.line_width if grid.has_border else 0
	origin_x := bbox.pos.x + border_offset
	origin_y := bbox.pos.y + border_offset
	available_w := bbox.size.x - 2 * border_offset
	available_h := bbox.size.y - 2 * border_offset
	cell_w := (available_w - f32(N - 1) * grid.line_width) / f32(N)
	cell_h := (available_h - f32(N - 1) * grid.line_width) / f32(N)

	renderer.draw_shape(
		state,
		renderer.ShapeData {
			data = renderer.RectData{pos = bbox.pos, size = bbox.size},
			style = renderer.ShapeStyle {
				fill_color = grid.background_color,
				border_color = grid.line_color if grid.has_border else {},
				border_width = grid.line_width if grid.has_border else 0,
			},
			transform = renderer.Transform{zindex = grid.zindex},
		},
	)

	line_style := renderer.ShapeStyle {
		fill_color = grid.line_color,
	}
	transform := renderer.Transform {
		zindex = grid.zindex,
	}

	for i in 0 ..< N - 1 {
		sep := f32(i + 1) * cell_w + f32(i) * grid.line_width
		renderer.draw_shape(
			state,
			renderer.ShapeData {
				data = renderer.RectData {
					pos = {origin_x + sep, origin_y},
					size = {grid.line_width, available_h},
				},
				style = line_style,
				transform = transform,
			},
		)
		sep = f32(i + 1) * cell_h + f32(i) * grid.line_width
		renderer.draw_shape(
			state,
			renderer.ShapeData {
				data = renderer.RectData {
					pos = {origin_x, origin_y + sep},
					size = {available_w, grid.line_width},
				},
				style = line_style,
				transform = transform,
			},
		)
	}

	for row in 0 ..< N {
		for col in 0 ..< N {
			if child := &grid.cells[row][col]; child.ctx != nil {
				cx := origin_x + f32(col) * (cell_w + grid.line_width)
				cy := origin_y + f32(row) * (cell_h + grid.line_width)
				cell_bbox := renderer.Rect {
					pos  = {cx, cy},
					size = {cell_w, cell_h},
				}
				render(child, state, ComponentInfo{bbox = cell_bbox})
			}
		}
	}
}
