package Main

import constants "./constants"
import renderer "./renderer"
import "core:fmt"
import wl_buffer "wayland_protocol/wl_buffer"
import wl_callback "wayland_protocol/wl_callback"
import wl_compositor "wayland_protocol/wl_compositor"
import wl_surface "wayland_protocol/wl_surface"
import xdg_surface "wayland_protocol/xdg_surface"
import xdg_toplevel "wayland_protocol/xdg_toplevel"
import xdg_wm_base "wayland_protocol/xdg_wm_base"

wl_surface_handlers: wl_surface.EventHandlers
xdg_wm_base_handlers := xdg_wm_base.EventHandlers {
	on_ping = proc(_: u32, serial: u32, user_data: rawptr) {
		state := (^state_t)(user_data)
		err := xdg_wm_base.pong(&state.xdg_wm_base, serial)
		if err != nil {state.last_err = err}
	},
}
xdg_toplevel_handlers := xdg_toplevel.EventHandlers {
	on_close = proc(_: u32, user_data: rawptr) {
		running = false
	},
	on_configure = proc(_: u32, width: i32, height: i32, states: []u8, user_data: rawptr) {
		state := (^state_t)(user_data)
		if width < 50 || height < 50 {
			state.w, state.h = 50, 50
			return
		}
		state.w = u32(width)
		state.h = u32(height)
	},
}
xdg_surface_handlers := xdg_surface.EventHandlers {
	on_configure = proc(_: u32, serial: u32, user_data: rawptr) {
		state := (^state_t)(user_data)
		err := xdg_surface.ack_configure(&state.xdg_surface, serial)
		if err != nil {state.last_err = err; return}
		state.state = .STATE_SURFACE_ACKED_CONFIGURE
	},
}

initialize_xdg_wm_base :: proc(state: ^state_t, name: u32, version: u32) -> Errno {
	state.xdg_wm_base = xdg_wm_base.from_global(&state.wl_registry, name, version) or_return
	register_event_handler(
		state,
		state.xdg_wm_base.id,
		&xdg_wm_base_handlers,
		xdg_wm_base.handle_event,
	)
	return nil
}

initialize_wl_surface :: proc(state: ^state_t) -> Errno {
	state.wl_surface = wl_compositor.create_surface(&state.wl_compositor) or_return
	register_event_handler(
		state,
		state.wl_surface.id,
		&wl_surface_handlers,
		wl_surface.handle_event,
	)
	return nil
}

initialize_xdg_surface :: proc(state: ^state_t) -> Errno {
	state.xdg_surface = xdg_wm_base.get_xdg_surface(
		&state.xdg_wm_base,
		&state.wl_surface,
	) or_return
	register_event_handler(
		state,
		state.xdg_surface.id,
		&xdg_surface_handlers,
		xdg_surface.handle_event,
	)
	return nil
}

initialize_xdg_toplevel :: proc(state: ^state_t) -> Errno {
	state.xdg_toplevel = xdg_surface.get_toplevel(&state.xdg_surface) or_return
	register_event_handler(
		state,
		state.xdg_toplevel.id,
		&xdg_toplevel_handlers,
		xdg_toplevel.handle_event,
	)
	return nil
}

can_initialize_surface :: proc(state: ^state_t) -> bool {
	return(
		state.cursor.initialized &&
		state.max_w > 0 &&
		state.max_h > 0 &&
		state.wl_compositor.id != 0 &&
		state.zwp_linux_dmabuf.id != 0 &&
		state.xdg_wm_base.id != 0 &&
		state.wl_surface.id == 0 \
	)
}

initialize_surface :: proc(state: ^state_t) -> Errno {
	assert(state.state == .STATE_NONE)
	initialize_wl_surface(state) or_return
	initialize_xdg_surface(state) or_return
	initialize_xdg_toplevel(state) or_return
	xdg_toplevel.set_min_size(&state.xdg_toplevel, 50, 50) or_return
	wl_surface.commit(&state.wl_surface) or_return

	renderer.initialize_vulkan_pipeline(&state.vulkan) or_return
	renderer.initialize_vulkan_commands(&state.vulkan) or_return
	renderer.initialize_shape_renderer(&state.vulkan) or_return

	vk_buf, err := renderer.allocate_vulkan_buffer(&state.vulkan, state.max_w, state.max_h)
	if err != nil do return err
	state.vk_buf = vk_buf

	state.buffer_ready = true
	return nil
}

initialize_buffer :: proc(state: ^state_t) -> Errno {
	if state.wl_buffer.id != 0 {
		wl_buffer.destroy(&state.wl_buffer) or_return
		// Keep the handler registered until the compositor sends on_release
	}
	state.wl_buffer = import_as_wl_buffer(state, &state.vk_buf, state.w, state.h) or_return
	register_event_handler(state, state.wl_buffer.id, &wl_buffer_handlers, wl_buffer.handle_event)
	state.buf_w = state.w
	state.buf_h = state.h

	return nil
}

draw_next_frame :: proc(state: ^state_t) -> Errno {
	assert(state.wl_surface.id != 0)
	assert(state.xdg_surface.id != 0)
	assert(state.xdg_toplevel.id != 0)
	assert(state.vk_buf.memory != 0)
	assert(state.w > 0 && state.h > 0)
	assert(state.buffer_ready)

	fmt.printfln("Drawing next frame")

	if state.w != state.buf_w || state.h != state.buf_h {
		initialize_buffer(state) or_return
	}

	if state.w < constants.NUM_CELLS || state.h < constants.NUM_CELLS {
		state.state = .STATE_SURFACE_ATTACHED
		fmt.eprintfln("State is too small to safely draw the next frame")
		return nil
	}

	// Submit shapes for this frame
	renderer.start_shapes(&state.vulkan)

	renderer.draw_line(
		&state.vulkan,
		{100, 100},
		{400, 200},
		8,
		.Round,
		{1, 0.2, 0.2, 1},
		{1, 1, 1, 1},
		2,
	)
	renderer.draw_line(
		&state.vulkan,
		{100, 160},
		{400, 260},
		12,
		.Square,
		{0.2, 0.5, 1, 0.8},
		{},
		0,
	)

	renderer.draw_rect(&state.vulkan, {200, 320}, {80, 40}, {0.3, 0.8, 0.3, 1}, {1, 1, 0, 1}, 4)
	renderer.draw_rect(&state.vulkan, {340, 320}, {60, 60}, {0.8, 0.3, 0.8, 0.5}, {}, 0)

	renderer.draw_rounded_rect(
		&state.vulkan,
		{160, 430},
		{70, 35},
		12,
		{1, 0.6, 0.1, 1},
		{1, 1, 1, 1},
		3,
	)
	renderer.draw_rounded_rect(
		&state.vulkan,
		{310, 430},
		{80, 40},
		20,
		{0.1, 0.8, 0.9, 0.7},
		{0, 0, 0, 1},
		2,
	)

	renderer.draw_triangle(
		&state.vulkan,
		{510, 110},
		{590, 260},
		{430, 260},
		{1, 0.4, 0, 1},
		{1, 1, 1, 1},
		3,
	)
	renderer.draw_triangle(
		&state.vulkan,
		{510, 290},
		{570, 390},
		{450, 390},
		{0.5, 0, 1, 0.8},
		{},
		0,
	)

	renderer.draw_oval(&state.vulkan, {210, 530}, {90, 40}, {1, 0.2, 0.5, 1}, {1, 1, 1, 1}, 3)
	renderer.draw_oval(&state.vulkan, {390, 530}, {40, 70}, {0.2, 0.9, 0.4, 0.6}, {}, 0)

	renderer.draw_circle(&state.vulkan, {530, 430}, 45, {1, 0.8, 0, 1}, {0.4, 0.2, 0, 1}, 4)
	renderer.draw_circle(&state.vulkan, {640, 430}, 30, {0, 0.6, 1, 0.7}, {}, 0)

	renderer.render_frame(
		&state.vulkan,
		&state.vk_buf,
		renderer.RenderParams {
			width = state.w,
			height = state.h,
			pointer_x = f32(state.pointer.surface_x),
			pointer_y = f32(state.pointer.surface_y),
		},
	) or_return

	wl_surface.attach(&state.wl_surface, &state.wl_buffer, 0, 0) or_return
	wl_surface.damage_buffer(&state.wl_surface, 0, 0, i32(state.w), i32(state.h)) or_return

	frame_cb := wl_surface.frame(&state.wl_surface) or_return
	register_event_handler(state, frame_cb.id, &wl_callback_handlers, wl_callback.handle_event)

	state.buffer_ready = false
	wl_surface.commit(&state.wl_surface) or_return

	state.state = .STATE_SURFACE_ATTACHED
	return nil
}
