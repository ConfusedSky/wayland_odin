package component

import platform "../platform"
import rect "../rect"
import renderer "../renderer"

Grid :: struct {
	cells:            [][]Component,
	zindex:           f32,
	has_border:       bool,
	line_width:       f32,
	line_color:       [4]f32,
	background_color: [4]f32,
}

@(private = "file")
GRID_VTABLE :: ComponentVTable {
	update = proc(this_ptr: rawptr, cinfo: ComponentInfo, finfo: platform.FrameInfo) -> bool {
		return update_grid((^Grid)(this_ptr), cinfo, finfo)
	},
	render = proc(this_ptr: rawptr, state: ^renderer.VulkanState, cinfo: ComponentInfo) {
		render_grid((^Grid)(this_ptr), state, cinfo)
	},
	destroy = proc(this_ptr: rawptr) {
		grid := (^Grid)(this_ptr)
		for row in 0 ..< len(grid.cells) {
			for col in 0 ..< len(grid.cells[row]) {
				if child := &grid.cells[row][col]; child.ctx != nil {
					destroy(child)
				}
			}
		}
		for row in grid.cells {
			delete(row)
		}
		delete(grid.cells)
	},
}

make_grid :: proc(n: int) -> ^Grid {
	grid := new(Grid)
	grid.cells = make([][]Component, n)
	for i in 0 ..< n {
		grid.cells[i] = make([]Component, n)
	}
	return grid
}

// Ownership is passed to the component; it is responsible for destroying the grid.
grid_into_component :: proc(grid: ^Grid, component: ^Component) {
	component.vtable = GRID_VTABLE
	component.type = Grid
	component.ctx = grid
}

grid_from_component :: proc(component: ^Component) -> (^Grid, bool) {
	if (component.type == Grid) {
		return (^Grid)(component.ctx), true
	}
	return nil, false
}

@(private = "file")
grid_cell_layout :: proc(
	grid: ^Grid,
	bbox: rect.Rect,
) -> (
	origin_x, origin_y, available_w, available_h, cell_w, cell_h: f32,
) {
	n := len(grid.cells)
	border_offset: f32 = grid.line_width if grid.has_border else 0
	origin_x = bbox.pos.x + border_offset
	origin_y = bbox.pos.y + border_offset
	available_w = bbox.size.x - 2 * border_offset
	available_h = bbox.size.y - 2 * border_offset
	cell_w = (available_w - f32(n - 1) * grid.line_width) / f32(n)
	cell_h = (available_h - f32(n - 1) * grid.line_width) / f32(n)
	return
}

@(private = "file")
update_grid :: proc(grid: ^Grid, cinfo: ComponentInfo, finfo: platform.FrameInfo) -> bool {
	n := len(grid.cells)
	origin_x, origin_y, _, _, cell_w, cell_h := grid_cell_layout(grid, cinfo.bbox)
	dirty := false
	for row in 0 ..< n {
		for col in 0 ..< n {
			if child := &grid.cells[row][col]; child.ctx != nil {
				cx := origin_x + f32(col) * (cell_w + grid.line_width)
				cy := origin_y + f32(row) * (cell_h + grid.line_width)
				child_cinfo := ComponentInfo {
					bbox = rect.Rect{pos = {cx, cy}, size = {cell_w, cell_h}},
				}
				if update(child, child_cinfo, finfo) do dirty = true
			}
		}
	}
	return dirty
}

@(private = "file")
render_grid :: proc(grid: ^Grid, state: ^renderer.VulkanState, cinfo: ComponentInfo) {
	n := len(grid.cells)
	bbox := cinfo.bbox

	origin_x, origin_y, available_w, available_h, cell_w, cell_h := grid_cell_layout(grid, bbox)

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

	for i in 0 ..< n - 1 {
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

	for row in 0 ..< n {
		for col in 0 ..< n {
			if child := &grid.cells[row][col]; child.ctx != nil {
				cx := origin_x + f32(col) * (cell_w + grid.line_width)
				cy := origin_y + f32(row) * (cell_h + grid.line_width)
				cell_bbox := rect.Rect {
					pos  = {cx, cy},
					size = {cell_w, cell_h},
				}
				render(child, state, ComponentInfo{bbox = cell_bbox})
			}
		}
	}
}
