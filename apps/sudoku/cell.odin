package demo

import component "src:component"
import platform "src:platform"
import renderer "src:renderer"

SudokuCell :: struct {
	state:      ^State,
	cell_index: int,
}

@(private = "file")
sudoku_cell_vtable :: component.ComponentVTable {
	update = proc(
		this_ptr: rawptr,
		cinfo: component.ComponentInfo,
		finfo: platform.FrameInfo,
	) -> bool {
		return update_sudoku_cell((^SudokuCell)(this_ptr), cinfo, finfo)
	},
	render = proc(this_ptr: rawptr, state: ^renderer.VulkanState, cinfo: component.ComponentInfo) {
		render_sudoku_cell((^SudokuCell)(this_ptr), state, cinfo)
	},
	destroy = proc(this_ptr: rawptr) {},
}

make_sudoku_cell :: proc(state: ^State, cell_index: int) -> ^SudokuCell {
	cell := new(SudokuCell)
	cell^ = {
		state      = state,
		cell_index = cell_index,
	}
	return cell
}

sudoku_cell_into_component :: proc(cell: ^SudokuCell, comp: ^component.Component) {
	comp.vtable = sudoku_cell_vtable
	comp.type = typeid_of(SudokuCell)
	comp.ctx = cell
}

CELL_INSET_FRACTION :: f32(0.10)
CELL_HOVER_COLOR :: [4]f32{0, 0, 0, 0.15}
CELL_SELECTED_COLOR :: [4]f32{0, 0, 0, 0.3}
CELL_GROUP_CONFLICT_COLOR :: [4]f32{1, 0, 0, 0.15}
CELL_CONFLICT_COLOR :: [4]f32{1, 0, 0, 0.5}
CELL_DIGIT_SIZE_FRACTION :: f32(0.65)

@(private = "file")
update_sudoku_cell :: proc(
	cell: ^SudokuCell,
	cinfo: component.ComponentInfo,
	finfo: platform.FrameInfo,
) -> bool {
	dirty := false

	if cinfo.contains_mouse {
		cell.state.hovered_cell = cell.cell_index
		if finfo.pointer.left_button_pressed {
			if cell.state.selected_cell == cell.cell_index {
				cell.state.selected_cell = -1
			} else {
				cell.state.selected_cell = cell.cell_index
			}
			dirty = true
		}
	}

	return dirty
}

@(private = "file")
render_sudoku_cell :: proc(
	cell: ^SudokuCell,
	state: ^renderer.VulkanState,
	cinfo: component.ComponentInfo,
) {
	bbox := cinfo.bbox
	cell_size := bbox.size.x
	row := cell.cell_index / 9
	col := cell.cell_index % 9
	box := (row / 3) * 3 + (col / 3)

	if cell.state.conflicted_cells[cell.cell_index] {
		renderer.draw_shape(
			state,
			renderer.ShapeData {
				data = renderer.RectData{pos = bbox.pos, size = bbox.size},
				style = renderer.ShapeStyle{fill_color = CELL_CONFLICT_COLOR},
			},
		)
	} else if cell.state.conflicted_rows[row] ||
	   cell.state.conflicted_cols[col] ||
	   cell.state.conflicted_boxes[box] {
		renderer.draw_shape(
			state,
			renderer.ShapeData {
				data = renderer.RectData{pos = bbox.pos, size = bbox.size},
				style = renderer.ShapeStyle{fill_color = CELL_GROUP_CONFLICT_COLOR},
			},
		)
	}

	color: [4]f32
	if cell.state.selected_cell == cell.cell_index {
		color = CELL_SELECTED_COLOR
	} else if cell.state.hovered_cell == cell.cell_index {
		color = CELL_HOVER_COLOR
	}
	if color.w > 0 {
		inset := cell_size * CELL_INSET_FRACTION
		renderer.draw_shape(
			state,
			renderer.ShapeData {
				data = renderer.RectData {
					pos = {bbox.pos.x + inset, bbox.pos.y + inset},
					size = {cell_size - inset * 2, cell_size - inset * 2},
				},
				style = renderer.ShapeStyle{fill_color = color},
			},
		)
	}

	if cell.state.board[cell.cell_index] != 0 {
		digit_strs := [10]string{"", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
		digit_style := renderer.TextStyle {
			color = BLACK,
			size  = cell_size * CELL_DIGIT_SIZE_FRACTION,
		}
		text := digit_strs[cell.state.board[cell.cell_index]]
		cell_center := [2]f32{bbox.pos.x + cell_size / 2, bbox.pos.y + cell_size / 2}
		text_bbox := renderer.get_text_bounding_box_top_left(state, text, {0, 0}, digit_style)
		pos := [2]f32{cell_center.x - text_bbox.size.x / 2, cell_center.y - text_bbox.size.y / 2}
		renderer.draw_text_top_left(state, text, pos, digit_style)
	}
}
