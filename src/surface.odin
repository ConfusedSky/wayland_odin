package Main

import constants "./constants"
import "core:fmt"
import "core:os"
import "core:sys/linux"
import wl_buffer "wayland_protocol/wl_buffer"
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
		if err != nil do os.exit(int(err))
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
		if err != nil do os.exit(int(err))
		state.state = .STATE_SURFACE_ACKED_CONFIGURE
	},
}

set_dimensions :: proc(state: ^state_t, w: u32, h: u32) {
	assert(w < state.max_w)
	assert(h < state.max_h)
	state.w = w
	state.h = h

	state.stride = state.w * constants.COLOR_CHANNELS
}

initialize_xdg_wm_base :: proc(state: ^state_t, name: u32, version: u32) {
	base, err := xdg_wm_base.from_global(&state.wl_registry, name, version)
	if err != nil do os.exit(int(err))
	state.xdg_wm_base = base
	register_event_handler(
		state,
		state.xdg_wm_base.id,
		&xdg_wm_base_handlers,
		xdg_wm_base.handle_event,
	)
}

initialize_wl_surface :: proc(state: ^state_t) {
	surface, err := wl_compositor.create_surface(&state.wl_compositor)
	if err != nil do os.exit(int(err))
	state.wl_surface = surface
	register_event_handler(state, state.wl_surface.id, &wl_surface_handlers, wl_surface.handle_event)
}

initialize_xdg_surface :: proc(state: ^state_t) {
	surf, err := xdg_wm_base.get_xdg_surface(&state.xdg_wm_base, &state.wl_surface)
	if err != nil do os.exit(int(err))
	state.xdg_surface = surf
	register_event_handler(
		state,
		state.xdg_surface.id,
		&xdg_surface_handlers,
		xdg_surface.handle_event,
	)
}

initialize_xdg_toplevel :: proc(state: ^state_t) {
	toplevel, err := xdg_surface.get_toplevel(&state.xdg_surface)
	if err != nil do os.exit(int(err))
	state.xdg_toplevel = toplevel
	register_event_handler(
		state,
		state.xdg_toplevel.id,
		&xdg_toplevel_handlers,
		xdg_toplevel.handle_event,
	)
}

can_initialize_surface :: proc(state: ^state_t) -> bool {
	return(
		state.max_w > 0 &&
		state.max_h > 0 &&
		state.shm_pool_size > 0 &&
		state.wl_compositor.id != 0 &&
		state.wl_shm.id != 0 &&
		state.xdg_wm_base.id != 0 &&
		state.wl_surface.id == 0 \
	)
}

initialize_surface :: proc(state: ^state_t) {
	assert(state.state == .STATE_NONE)
	create_shared_memory_file(state)
	initialize_wl_surface(state)
	initialize_xdg_surface(state)
	initialize_xdg_toplevel(state)
	err := xdg_toplevel.set_min_size(&state.xdg_toplevel, 50, 50)
	if err != nil do os.exit(int(err))
	err = wl_surface.commit(&state.wl_surface)
	if err != nil do os.exit(int(err))
	initialize_wl_shm_pool(state)
	state.buffer_ready = true
}

draw_next_frame :: proc(state: ^state_t) {
	assert(state.wl_surface.id != 0)
	assert(state.xdg_surface.id != 0)
	assert(state.xdg_toplevel.id != 0)
	assert(state.shm_pool_data != nil)
	assert(state.shm_pool_size != 0)
	assert(state.buffer_ready)

	fmt.printfln("Drawing next frame")

	if state.w != state.buf_w || state.h != state.buf_h {
		if state.wl_buffer.id != 0 {
			err := wl_buffer.destroy(&state.wl_buffer)
			if err != nil do os.exit(int(err))
			// Keep the handler registered until the compositor sends on_release
		}
		initialize_wl_buffer(state)
	}

	if state.w < constants.NUM_CELLS || state.h < constants.NUM_CELLS {
		state.state = .STATE_SURFACE_ATTACHED
		fmt.eprintfln("State is to small to safely draw the next frame")
		return
	}

	pixels := ([^]u32)(state.shm_pool_data)
	p_x_prime := u32(state.pointer.surface_x) * constants.NUM_CELLS / state.w
	p_y_prime := u32(state.pointer.surface_y) * constants.NUM_CELLS / state.h
	for y: u32 = 0; y < state.h; y += 1 {
		for x: u32 = 0; x < state.w; x += 1 {
			r, g, b: u8
			x_prime := x * constants.NUM_CELLS / state.w
			y_prime := y * constants.NUM_CELLS / state.h
			if p_x_prime == x_prime && p_y_prime == y_prime {
				r = 255
			} else {
				r = u8((x_prime + y_prime) % 2) * 255
				g = u8((x_prime + y_prime) % 2) * 255
				b = u8((x_prime + y_prime) % 2) * 255
			}
			pixels[y * state.w + x] = (u32(r) << 16) | (u32(g) << 8) | u32(b)
		}
	}

	err: linux.Errno
	err = wl_surface.attach(&state.wl_surface, &state.wl_buffer, 0, 0)
	if err != nil do os.exit(int(err))
	err = wl_surface.damage_buffer(&state.wl_surface, 0, 0, i32(state.w), i32(state.h))
	if err != nil do os.exit(int(err))
	err = wl_surface.commit(&state.wl_surface)
	if err != nil do os.exit(int(err))

	state.buffer_ready = false

	state.state = .STATE_SURFACE_ATTACHED
}

