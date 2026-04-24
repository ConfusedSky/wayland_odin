package demo

import "core:fmt"
import "core:math"
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

initialize :: proc(
	state: ^State,
	logger: ^runtime_log.Logger,
	max_width: u32,
	max_height: u32,
) -> linux.Errno {
	state.logger = logger
	renderer.initialize_vulkan(&state.vulkan, logger) or_return

	font, font_err := renderer.load_font(&state.vulkan)
	if font_err != nil do return font_err
	state.font = font

	frame_buf, err := renderer.allocate_vulkan_buffer(&state.vulkan, max_width, max_height)
	if err != nil do return err
	state.frame_buf = frame_buf
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


	white := [4]f32{1, 1, 1, 1}
	black := [4]f32{0, 0, 0, 1}
	gray := [4]f32{0.8, 0.8, 0.8, 1}
	gray_style := renderer.ShapeStyle {
		fill_color = gray,
	}
	black_style := renderer.ShapeStyle {
		fill_color = black,
	}
	line_width: f32 = 2

	renderer.start_frame(
		&state.vulkan,
		&state.frame_buf,
		renderer.RenderParams {
			width = info.width,
			height = info.height,
			pointer_x = f32(info.pointer.x),
			pointer_y = f32(info.pointer.y),
			bg_color = gray,
		},
	) or_return

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
				border_color = black,
				border_width = line_width,
				fill_color = white,
			},
		},
	)

	for i in 1 ..= 2 {
		x := grid_x + grid_size * f32(i) / 3 - line_width / 2
		y := grid_y + grid_size * f32(i) / 3 - line_width / 2
		renderer.draw_shape(
			&state.vulkan,
			renderer.ShapeData {
				data = renderer.RectData{pos = {x, grid_y}, size = {line_width, grid_size}},
				style = black_style,
			},
		)

		renderer.draw_shape(
			&state.vulkan,
			renderer.ShapeData {
				data = renderer.RectData{pos = {grid_x, y}, size = {grid_size, line_width}},
				style = black_style,
			},
		)
	}

	for i in 1 ..= 8 {
		if i % 3 == 0 do continue

		x := grid_x + grid_size * f32(i) / 9 - line_width / 2
		y := grid_y + grid_size * f32(i) / 9 - line_width / 2
		renderer.draw_shape(
			&state.vulkan,
			renderer.ShapeData {
				data = renderer.RectData{pos = {x, grid_y}, size = {1, grid_size}},
				style = black_style,
			},
		)

		renderer.draw_shape(
			&state.vulkan,
			renderer.ShapeData {
				data = renderer.RectData{pos = {grid_x, y}, size = {grid_size, 1}},
				style = black_style,
			},
		)
	}

	renderer.end_frame(&state.vulkan) or_return

	return true, nil
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
