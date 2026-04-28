package grid_test

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

PADDING: f32 : 20
BG_COLOR: [4]f32 : {0.8, 0.8, 0.8, 1}

initialize :: proc(
	state: ^State,
	logger: ^runtime_log.Logger,
	max_width: u32,
	max_height: u32,
) -> linux.Errno {
	state.logger = logger
	renderer.initialize_vulkan(&state.vulkan, logger) or_return

	frame_buf, err := renderer.allocate_frame_buffer(&state.vulkan, max_width, max_height)
	if err != nil do return err
	state.frame_buf = frame_buf

	grid := component.make_grid(3)
	grid.has_border = true
	grid.line_width = 4
	grid.line_color = {0, 0, 0, 1}
	grid.background_color = {1, 1, 1, 1}
	component.grid_into_component(grid, &state.grid_component)

	for y in 0 ..= 2 {
		for x in 0 ..= 2 {
			subgrid := component.make_grid(3)
			subgrid.line_width = 2
			subgrid.line_color = {0, 0, 0, 1}
			component.grid_into_component(subgrid, &grid.cells[y][x])
		}
	}

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
	return false
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

	w := f32(width)
	h := f32(height)
	square := min(w, h)
	grid_x := (w - square) / 2 + PADDING
	grid_y := (h - square) / 2 + PADDING
	grid_size := square - PADDING * 2

	renderer.start_frame(
		&state.vulkan,
		&state.frame_buf,
		renderer.RenderParams{width = width, height = height, bg_color = BG_COLOR},
	) or_return

	component.render(
		&state.grid_component,
		&state.vulkan,
		component.ComponentInfo {
			bbox = renderer.Rect{pos = {grid_x, grid_y}, size = {grid_size, grid_size}},
		},
	)

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
