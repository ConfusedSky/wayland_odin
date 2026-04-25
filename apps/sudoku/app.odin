package demo

import "core:fmt"
import "core:sys/linux"

import "src:constants"
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

WHITE := [4]f32{1, 1, 1, 1}
BLACK := [4]f32{0, 0, 0, 1}
GRAY := [4]f32{0.8, 0.8, 0.8, 1}
GRAY_STYLE := renderer.ShapeStyle {
	fill_color = GRAY,
}
BLACK_STYLE := renderer.ShapeStyle {
	fill_color = BLACK,
}
LINE_WIDTH: f32 = 4

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

	state.initialized = true
	return nil
}

shutdown :: proc(state: ^State) {
	if state.frame_buf.memory != 0 {
		renderer.free_frame_buffer(&state.vulkan, &state.frame_buf)
	}
	state.logger = nil
	renderer.cleanup_vulkan(&state.vulkan)
	state.initialized = false
}

update :: proc(state: ^State, info: platform.FrameInfo) -> bool {
	should_render := false

	state.pointer_x = f32(info.pointer.x)
	state.pointer_y = f32(info.pointer.y)

	grid_x, grid_y, grid_size, cell_size := grid_geometry(info.width, info.height)

	prev_hovered, prev_selected := state.hovered_cell, state.selected_cell

	// Compute hovered cell from pointer position.
	// Check each cell's exact pixel range (accounting for line widths between cells).
	hovered_col := -1
	for c in 0 ..< 9 {
		cx := grid_x + f32(c) * cell_size + cell_offset(c)
		if state.pointer_x >= cx && state.pointer_x < cx + cell_size {
			hovered_col = c
			break
		}
	}
	hovered_row := -1
	for r in 0 ..< 9 {
		cy := grid_y + f32(r) * cell_size + cell_offset(r)
		if state.pointer_y >= cy && state.pointer_y < cy + cell_size {
			hovered_row = r
			break
		}
	}
	state.hovered_cell =
		hovered_row * 9 + hovered_col if hovered_col >= 0 && hovered_row >= 0 else -1

	// Click: select hovered cell; clicking the already-selected cell deselects it.
	if info.pointer.left_button_pressed {
		if state.hovered_cell == state.selected_cell {
			state.selected_cell = -1
		} else {
			state.selected_cell = state.hovered_cell
		}
	}

	if prev_hovered != state.hovered_cell || prev_selected != state.selected_cell do should_render = true

	// Digit keys: 1-9 fill selected cell; 0/Backspace/Delete clears it.
	if state.selected_cell >= 0 {
		for i in 0 ..< int(info.keyboard.n_keys) {
			key := info.keyboard.keys_pressed[i]
			if key >= 2 && key <= 10 {
				state.board[state.selected_cell] = int(key) - 1
				should_render = true
			} else if key == 11 || key == 14 || key == 111 {
				// KEY_0, KEY_BACKSPACE, KEY_DELETE
				state.board[state.selected_cell] = 0
				should_render = true
			}
		}
	}

	return should_render
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

	if width < constants.NUM_CELLS || height < constants.NUM_CELLS {
		fmt.eprintfln("State is too small to safely draw the next frame")
		return false, nil
	}

	grid_x, grid_y, grid_size, cell_size := grid_geometry(width, height)

	renderer.start_frame(
		&state.vulkan,
		&state.frame_buf,
		renderer.RenderParams {
			width = width,
			height = height,
			pointer_x = state.pointer_x,
			pointer_y = state.pointer_y,
			bg_color = GRAY,
		},
	) or_return

	draw_grid(state, grid_x, grid_y, grid_size, cell_size)

	renderer.end_frame(&state.vulkan) or_return

	return true, nil
}

// Total pixels consumed by internal grid lines: 2 thick (LINE_WIDTH) + 6 thin (LINE_WIDTH/2).
total_internal_line_px: f32

@(init)
init_total_internal_line_px :: proc "contextless" () {
	total_internal_line_px = 2 * LINE_WIDTH + 6 * (LINE_WIDTH / 2)
}

grid_geometry :: proc(width, height: u32) -> (grid_x, grid_y, grid_size, cell_size: f32) {
	window_width := f32(width)
	window_height := f32(height)
	square_size := min(window_width, window_height)
	square_x := (window_width - square_size) / 2
	square_y := (window_height - square_size) / 2
	padding: f32 = 20
	grid_x = square_x + padding
	grid_y = square_y + padding
	grid_size = square_size - padding * 2
	cell_size = (grid_size - total_internal_line_px) / 9
	return
}

// Returns the pixel offset of cell/separator index idx from the grid origin,
// accounting for the widths of all preceding thin and thick lines.
cell_offset :: proc(idx: int) -> f32 {
	thin_before := f32(idx - idx / 3)
	thick_before := f32(idx / 3)
	return thin_before * (LINE_WIDTH / 2) + thick_before * LINE_WIDTH
}

cell_inset_FRACTION :: f32(0.10)
HOVER_COLOR :: [4]f32{0, 0, 0, 0.15}
SELECTED_COLOR :: [4]f32{0, 0, 0, 0.3}

draw_grid :: proc(state: ^State, grid_x, grid_y, grid_size, cell_size: f32) {
	renderer.draw_shape(
		&state.vulkan,
		renderer.ShapeData {
			data = renderer.RectData {
				pos = {grid_x - LINE_WIDTH, grid_y - LINE_WIDTH},
				size = {grid_size + LINE_WIDTH * 2, grid_size + LINE_WIDTH * 2},
			},
			style = renderer.ShapeStyle {
				border_color = BLACK,
				border_width = LINE_WIDTH,
				fill_color = WHITE,
			},
		},
	)

	// Cell hover and selection overlays — drawn before grid lines so lines render on top.
	cell_inset := cell_size * cell_inset_FRACTION
	for row in 0 ..< 9 {
		for col in 0 ..< 9 {
			idx := row * 9 + col
			color: [4]f32
			if idx == state.selected_cell {
				color = SELECTED_COLOR
			} else if idx == state.hovered_cell {
				color = HOVER_COLOR
			} else {
				continue
			}
			cx := grid_x + f32(col) * cell_size + cell_offset(col)
			cy := grid_y + f32(row) * cell_size + cell_offset(row)
			renderer.draw_shape(
				&state.vulkan,
				renderer.ShapeData {
					data = renderer.RectData {
						pos = {cx + cell_inset, cy + cell_inset},
						size = {cell_size - cell_inset * 2, cell_size - cell_inset * 2},
					},
					style = renderer.ShapeStyle{fill_color = color},
				},
			)
		}
	}

	// Thick box lines (separators at i=3 and i=6).
	// Each starts exactly where the preceding cell ends.
	for i in 1 ..= 2 {
		sep := i * 3
		x := grid_x + f32(sep) * cell_size + cell_offset(sep) - LINE_WIDTH
		y := grid_y + f32(sep) * cell_size + cell_offset(sep) - LINE_WIDTH
		renderer.draw_shape(
			&state.vulkan,
			renderer.ShapeData {
				data = renderer.RectData{pos = {x, grid_y}, size = {LINE_WIDTH, grid_size}},
				style = BLACK_STYLE,
			},
		)
		renderer.draw_shape(
			&state.vulkan,
			renderer.ShapeData {
				data = renderer.RectData{pos = {grid_x, y}, size = {grid_size, LINE_WIDTH}},
				style = BLACK_STYLE,
			},
		)
	}

	// Thin cell lines (all separators except the box ones).
	for i in 1 ..= 8 {
		if i % 3 == 0 do continue
		x := grid_x + f32(i) * cell_size + cell_offset(i) - LINE_WIDTH / 2
		y := grid_y + f32(i) * cell_size + cell_offset(i) - LINE_WIDTH / 2
		renderer.draw_shape(
			&state.vulkan,
			renderer.ShapeData {
				data = renderer.RectData{pos = {x, grid_y}, size = {LINE_WIDTH / 2, grid_size}},
				style = BLACK_STYLE,
			},
		)
		renderer.draw_shape(
			&state.vulkan,
			renderer.ShapeData {
				data = renderer.RectData{pos = {grid_x, y}, size = {grid_size, LINE_WIDTH / 2}},
				style = BLACK_STYLE,
			},
		)
	}

	digit_style := renderer.TextStyle {
		color = BLACK,
		size  = cell_size * 0.65,
	}
	digit_strs := [10]string{"", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
	for row in 0 ..< 9 {
		for col in 0 ..< 9 {
			digit := state.board[row * 9 + col]
			if digit == 0 do continue
			cx := grid_x + f32(col) * cell_size + cell_offset(col)
			cy := grid_y + f32(row) * cell_size + cell_offset(row)
			cell_center := [2]f32{cx + cell_size / 2, cy + cell_size / 2}
			bbox := renderer.get_text_bounding_box_top_left(
				&state.vulkan,
				digit_strs[digit],
				{0, 0},
				digit_style,
			)
			pos := [2]f32{cell_center.x - bbox.size.x / 2, cell_center.y - bbox.size.y / 2}
			renderer.draw_text_top_left(&state.vulkan, digit_strs[digit], pos, digit_style)
		}
	}
}

point_in_rect :: proc(point: [2]f32, rect: renderer.Rect) -> bool {
	return(
		point.x >= rect.pos.x &&
		point.y >= rect.pos.y &&
		point.x <= rect.pos.x + rect.size.x &&
		point.y <= rect.pos.y + rect.size.y \
	)
}
// Runner callbacks — adapt package-internal procs to runner.AppConfig signatures.

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
