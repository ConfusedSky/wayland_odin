package demo

import "core:fmt"
import "core:sys/linux"

import component "src:component"
import "src:platform"
import "src:renderer"
import "src:runtime_log"

log_blacklist: []string : {
	"wayland.request.wl_surface.attach",
	"wayland.request.wl_surface.damage_buffer",
	"wayland.request.wl_surface.frame",
	"wayland.request.wl_surface.commit",
	"wayland.event.wl_callback.done",
	"wayland.event.wl_display.delete_id",
	"wayland.event.wl_pointer.motion",
	"wayland.event.wl_pointer.frame",
	"wayland.event.xdg_wm_base.ping",
	"wayland.request.xdg_wm_base.pong",
	"platform.recv_batch",
}

BLACK :: [4]f32{0, 0, 0, 1}
WHITE :: [4]f32{1, 1, 1, 1}
GRAY :: [4]f32{0.8, 0.8, 0.8, 1}
RED :: [4]f32{1, 0, 0, 1}

BG_COLOR :: GRAY
PADDING :: f32(20)

@(private = "file")
grid_cinfo :: proc(width, height: u32) -> component.ComponentInfo {
	w := f32(width)
	h := f32(height)
	square := min(w, h)
	return component.ComponentInfo {
		bbox = renderer.Rect {
			pos = {(w - square) / 2 + PADDING, (h - square) / 2 + PADDING},
			size = {square - PADDING * 2, square - PADDING * 2},
		},
	}
}

@(private = "file")
compute_conflicts :: proc(state: ^State) {
	state.conflicted_cells = {}
	state.conflicted_rows = {}
	state.conflicted_cols = {}
	state.conflicted_boxes = {}

	for r in 0 ..< 9 {
		counts := [10]int{}
		for c in 0 ..< 9 {
			if v := state.board[r * 9 + c]; v != 0 {counts[v] += 1}
		}
		for c in 0 ..< 9 {
			if v := state.board[r * 9 + c]; v != 0 && counts[v] > 1 {
				state.conflicted_cells[r * 9 + c] = true
				state.conflicted_rows[r] = true
			}
		}
	}

	for c in 0 ..< 9 {
		counts := [10]int{}
		for r in 0 ..< 9 {
			if v := state.board[r * 9 + c]; v != 0 {counts[v] += 1}
		}
		for r in 0 ..< 9 {
			if v := state.board[r * 9 + c]; v != 0 && counts[v] > 1 {
				state.conflicted_cells[r * 9 + c] = true
				state.conflicted_cols[c] = true
			}
		}
	}

	for box in 0 ..< 9 {
		br, bc := box / 3, box % 3
		counts := [10]int{}
		for r in 0 ..< 3 {
			for c in 0 ..< 3 {
				if v := state.board[(br * 3 + r) * 9 + (bc * 3 + c)]; v != 0 {counts[v] += 1}
			}
		}
		for r in 0 ..< 3 {
			for c in 0 ..< 3 {
				idx := (br * 3 + r) * 9 + (bc * 3 + c)
				if v := state.board[idx]; v != 0 && counts[v] > 1 {
					state.conflicted_cells[idx] = true
					state.conflicted_boxes[box] = true
				}
			}
		}
	}
}

initialize :: proc(
	state: ^State,
	logger: ^runtime_log.Logger,
	max_width: u32,
	max_height: u32,
) -> linux.Errno {
	state.logger = logger
	renderer.initialize_vulkan(&state.vulkan, logger) or_return

	renderer.acquire_atlas(&state.vulkan, 48) or_return

	frame_buf, err := renderer.allocate_frame_buffer(&state.vulkan, max_width, max_height)
	if err != nil do return err
	state.frame_buf = frame_buf

	state.selected_cell = -1
	state.hovered_cell = -1
	compute_conflicts(state)

	outer_grid := component.make_grid(3)
	outer_grid.has_border = true
	outer_grid.line_width = 4
	outer_grid.background_color = WHITE
	outer_grid.line_color = BLACK

	for row_box in 0 ..< 3 {
		for col_box in 0 ..< 3 {
			inner_grid := component.make_grid(3)
			inner_grid.line_width = 2
			inner_grid.line_color = BLACK

			for row_cell in 0 ..< 3 {
				for col_cell in 0 ..< 3 {
					flat := (row_box * 3 + row_cell) * 9 + (col_box * 3 + col_cell)
					cell := make_sudoku_cell(state, flat)
					sudoku_cell_into_component(cell, &inner_grid.cells[row_cell][col_cell])
				}
			}

			component.grid_into_component(inner_grid, &outer_grid.cells[row_box][col_box])
		}
	}

	component.grid_into_component(outer_grid, &state.grid_component)

	state.initialized = true
	return nil
}

shutdown :: proc(state: ^State) {
	if state.frame_buf.memory != 0 {
		renderer.free_frame_buffer(&state.vulkan, &state.frame_buf)
	}
	component.destroy(&state.grid_component)
	state.logger = nil
	renderer.cleanup_vulkan(&state.vulkan)
	state.initialized = false
}

update :: proc(state: ^State, info: platform.FrameInfo) -> bool {
	dirty := false

	for i in 0 ..< int(info.keyboard.n_keys) {
		key := info.keyboard.keys_pressed[i]
		switch key {
		case 2 ..= 10:
			if state.selected_cell >= 0 {
				state.board[state.selected_cell] = int(key) - 1
				dirty = true
			}
		case 11, 14, 111:
			if state.selected_cell >= 0 {
				state.board[state.selected_cell] = 0
				dirty = true
			}
		case 103, 105, 106, 108:
			if state.selected_cell < 0 {
				state.selected_cell = 0
			} else {
				row := state.selected_cell / 9
				col := state.selected_cell % 9
				switch key {
				case 103:
					row = max(0, row - 1)
				case 108:
					row = min(8, row + 1)
				case 105:
					col = max(0, col - 1)
				case 106:
					col = min(8, col + 1)
				}
				state.selected_cell = row * 9 + col
			}
			dirty = true
		}
	}

	compute_conflicts(state)

	prev_hovered := state.hovered_cell
	state.hovered_cell = -1
	dirty =
		component.update(&state.grid_component, grid_cinfo(info.width, info.height), info) || dirty
	return dirty || state.hovered_cell != prev_hovered
}

render_frame :: proc(
	state: ^State,
	width: u32,
	height: u32,
) -> (
	rendered: bool,
	err: linux.Errno,
) {
	assert(state.frame_buf.memory != 0)
	assert(width > 0 && height > 0)

	if runtime_log.should_log(state.logger, "app.frame.draw") {
		fmt.printfln("Drawing next frame")
	}

	renderer.start_frame(
		&state.vulkan,
		&state.frame_buf,
		renderer.RenderParams{width = width, height = height, bg_color = BG_COLOR},
	) or_return

	component.render(&state.grid_component, &state.vulkan, grid_cinfo(width, height))

	renderer.end_frame(&state.vulkan) or_return
	return true, nil
}

on_init :: proc(
	user_data: rawptr,
	logger: ^runtime_log.Logger,
	max_width: u32,
	max_height: u32,
) -> linux.Errno {
	return initialize((^State)(user_data), logger, max_width, max_height)
}

on_update :: proc(user_data: rawptr, info: platform.FrameInfo) -> bool {
	return update((^State)(user_data), info)
}

on_frame :: proc(
	user_data: rawptr,
	width: u32,
	height: u32,
) -> (
	frame_buf: ^renderer.VulkanFrameBuffer,
	err: linux.Errno,
) {
	state := (^State)(user_data)
	rendered: bool
	rendered, err = render_frame(state, width, height)
	if err != nil || !rendered {
		return nil, err
	}
	return &state.frame_buf, nil
}

on_shutdown :: proc(user_data: rawptr) {
	shutdown((^State)(user_data))
}
