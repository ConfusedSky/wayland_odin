package Main

import constants "./constants"
import renderer "./renderer"
import "core:fmt"
import "core:math"
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

	renderer.initialize_grid_pipeline(&state.vulkan) or_return
	renderer.initialize_vulkan_commands(&state.vulkan) or_return
	renderer.initialize_shape_renderer(&state.vulkan) or_return
	renderer.initialize_text_renderer(&state.vulkan) or_return

	font, font_err := renderer.load_font(&state.vulkan)
	if font_err != nil do return font_err
	state.font = font

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

	// Submit shapes and text for this frame
	renderer.start_shapes(&state.vulkan)
	renderer.start_text(&state.vulkan)

	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.LineData{p0 = {100, 100}, p1 = {400, 200}, width = 16, cap = .Round},
			style = {fill_color = {1, 0.2, 0.2, 1}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
	)
	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.LineData{p0 = {100, 160}, p1 = {400, 260}, width = 24, cap = .Square},
			style = {
				fill_color = {0.2, 0.5, 1, 0.8},
				border_color = {1, 1, 1, 1},
				border_width = 4,
			},
		},
	)

	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.RectData{pos = {120, 280}, size = {160, 80}},
			style = {
				fill_color = {0.3, 0.8, 0.3, 1},
				border_color = {1, 1, 0, 1},
				border_width = 4,
			},
		},
	)
	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.RectData{pos = {280, 260}, size = {120, 120}},
			transform = {angle = math.PI / 4, zindex = 1},
			style = {
				fill_color = {0.8, 0.3, 0.8, 0.5},
				border_color = {1, 1, 1, 1},
				border_width = 4,
			},
		},
	)

	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.RoundedRectData{pos = {90, 395}, size = {140, 70}, corner_radius = 12},
			style = {fill_color = {1, 0.6, 0.1, 1}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
	)
	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.RoundedRectData {
				pos = {230, 390},
				size = {160, 80},
				corner_radius = 20,
			},
			style = {
				fill_color = {0.1, 0.8, 0.9, 0.7},
				border_color = {1, 1, 1, 1},
				border_width = 4,
			},
		},
	)

	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.TriangleData{p0 = {510, 110}, p1 = {590, 260}, p2 = {430, 260}},
			style = {fill_color = {1, 0.4, 0, 1}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
	)
	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.TriangleData{p0 = {510, 290}, p1 = {570, 390}, p2 = {450, 390}},
			style = {fill_color = {0.5, 0, 1, 0.8}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
	)

	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.OvalData{center = {210, 530}, radii = {90, 40}},
			style = {fill_color = {1, 0.2, 0.5, 1}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
	)
	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.OvalData{center = {390, 530}, radii = {40, 70}},
			style = {
				fill_color = {0.2, 0.9, 0.4, 0.6},
				border_color = {1, 1, 1, 1},
				border_width = 4,
			},
		},
	)

	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.CircleData{center = {530, 430}, radius = 45},
			style = {fill_color = {1, 1, 1, 1}},
		},
	)
	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.CircleData{center = {640, 430}, radius = 30},
			style = {fill_color = {0, 0.6, 1, 0.7}, border_color = {1, 1, 1, 1}, border_width = 4},
		},
	)

	renderer.draw_text_top_left(
		&state.vulkan,
		"Hello, World!",
		{100, 200},
		renderer.TextStyle{font = state.font, color = {1, 1, 1, 1}},
	)

	rect := renderer.get_text_bounding_box_top_left(
		"Hello, World!",
		{100, 200},
		{font = state.font},
	)
	fmt.println(rect)

	renderer.draw_shape(
		&state.vulkan,
		{
			data = renderer.RectData{pos = rect.pos, size = rect.size},
			style = {fill_color = {1, 0, 0, 0.7}},
		},
	)

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
