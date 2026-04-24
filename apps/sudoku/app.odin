package demo

import "core:fmt"
import "core:math/rand"
import "core:sys/linux"

import "src:constants"
import "src:platform"
import "src:renderer"
import "src:runtime_log"

log_blacklist: []string : {
	"app.frame.draw",
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

	font, font_err := renderer.load_font(&state.vulkan, 48)
	if font_err != nil do return font_err
	state.font = font

	frame_buf, err := renderer.allocate_vulkan_buffer(&state.vulkan, max_width, max_height)
	if err != nil do return err
	state.frame_buf = frame_buf
	for i in 0 ..< 81 {
		state.board[i] = rand.int_max(9) + 1
	}

	state.initialized = true
	return nil
}

shutdown :: proc(state: ^State) {
	if state.font != nil {
		renderer.destroy_font(&state.vulkan, state.font)
		state.font = nil
	}
	if state.frame_buf.memory != 0 {
		renderer.free_vulkan_buffer(&state.vulkan, &state.frame_buf)
	}
	state.logger = nil
	renderer.cleanup_vulkan(&state.vulkan)
	state.initialized = false
}

render_frame :: proc(
	state: ^State,
	info: platform.FrameInfo,
) -> (
	rendered: bool,
	err: linux.Errno,
) {
	assert(state.frame_buf.memory != 0)
	assert(info.width > 0 && info.height > 0)

	if runtime_log.should_log(state.logger, "app.frame.draw") {
		fmt.printfln("Drawing next frame")
	}

	if info.width < constants.NUM_CELLS || info.height < constants.NUM_CELLS {
		fmt.eprintfln("State is too small to safely draw the next frame")
		return false, nil
	}


	renderer.start_frame(
		&state.vulkan,
		&state.frame_buf,
		renderer.RenderParams {
			width = info.width,
			height = info.height,
			pointer_x = f32(info.pointer.x),
			pointer_y = f32(info.pointer.y),
			bg_color = GRAY,
		},
	) or_return

	draw_grid(state, info)

	renderer.end_frame(&state.vulkan) or_return

	return true, nil
}

draw_grid :: proc(state: ^State, info: platform.FrameInfo) {
	window_width := f32(info.width)
	window_height := f32(info.height)
	square_size := min(window_width, window_height)
	square_x := (window_width - square_size) / 2
	square_y := (window_height - square_size) / 2
	padding: f32 = 10
	grid_x := square_x + padding
	grid_y := square_y + padding
	grid_size := square_size - padding * 2

	renderer.draw_shape(
		&state.vulkan,
		renderer.ShapeData {
			data = renderer.RectData {
				pos = {grid_x - 1, grid_y - 1},
				size = {grid_size + 2, grid_size + 2},
			},
			style = renderer.ShapeStyle {
				border_color = BLACK,
				border_width = LINE_WIDTH,
				fill_color = WHITE,
			},
		},
	)

	for i in 1 ..= 2 {
		x := grid_x + grid_size * f32(i) / 3 - LINE_WIDTH / 2
		y := grid_y + grid_size * f32(i) / 3 - LINE_WIDTH / 2
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

	for i in 1 ..= 8 {
		if i % 3 == 0 do continue

		x := grid_x + grid_size * f32(i) / 9 - LINE_WIDTH / 4
		y := grid_y + grid_size * f32(i) / 9 - LINE_WIDTH / 4
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

	cell_size := grid_size / 9
	digit_style := renderer.TextStyle {
		font  = state.font,
		color = BLACK,
		size  = cell_size * 0.65,
	}
	digit_strs := [10]string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
	for row in 0 ..< 9 {
		for col in 0 ..< 9 {
			digit_str := digit_strs[state.board[row * 9 + col]]
			cell_center := [2]f32 {
				grid_x + (f32(col) + 0.5) * cell_size,
				grid_y + (f32(row) + 0.5) * cell_size,
			}
			bbox := renderer.get_text_bounding_box_top_left(digit_str, {0, 0}, digit_style)
			pos := [2]f32{cell_center.x - bbox.size.x / 2, cell_center.y - bbox.size.y / 2}
			renderer.draw_text_top_left(&state.vulkan, digit_str, pos, digit_style)
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

on_frame :: proc(
	user_data: rawptr,
	info: platform.FrameInfo,
) -> (
	frame_buf: ^renderer.VulkanFrameBuffer,
	err: linux.Errno,
) {
	state := (^State)(user_data)
	rendered: bool
	rendered, err = render_frame(state, info)
	if err != nil || !rendered {
		return nil, err
	}
	return &state.frame_buf, nil
}

on_shutdown :: proc(user_data: rawptr) {
	shutdown((^State)(user_data))
}
