package Main

import constants "./constants"
import "core:fmt"
import "core:os"
import "core:sys/linux"
import wl_buffer "wayland_protocol/wl_buffer"
import wl_compositor "wayland_protocol/wl_compositor"
import wl_shm "wayland_protocol/wl_shm"
import wl_shm_pool "wayland_protocol/wl_shm_pool"
import wl_surface "wayland_protocol/wl_surface"
import xdg_surface "wayland_protocol/xdg_surface"
import xdg_toplevel "wayland_protocol/xdg_toplevel"
import xdg_wm_base "wayland_protocol/xdg_wm_base"

wl_surface_handlers: wl_surface.EventHandlers
xdg_wm_base_handlers := xdg_wm_base.EventHandlers {
	on_ping = proc(_: u32, serial: u32, user_data: rawptr) {
		state := (^state_t)(user_data)
		err := xdg_wm_base.pong(state.socket_fd, state.xdg_wm_base, serial)
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
		err := xdg_surface.ack_configure(state.socket_fd, state.xdg_surface, serial)
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

can_initialize_surface :: proc(state: ^state_t) -> bool {
	return(
		state.max_w > 0 &&
		state.max_h > 0 &&
		state.shm_pool_size > 0 &&
		state.wl_compositor != 0 &&
		state.wl_shm != 0 &&
		state.xdg_wm_base != 0 &&
		state.wl_surface == 0 \
	)
}

initialize_surface :: proc(state: ^state_t) {
	assert(state.state == .STATE_NONE)
	create_shared_memory_file(state)

	state.wayland_current_id += 1
	err := wl_compositor.create_surface(
		state.socket_fd,
		state.wl_compositor,
		state.wayland_current_id,
	)
	if err != nil do os.exit(int(err))
	state.wl_surface = state.wayland_current_id
	register_event_handler(state, state.wl_surface, &wl_surface_handlers, wl_surface.handle_event)

	state.wayland_current_id += 1
	err = xdg_wm_base.get_xdg_surface(
		state.socket_fd,
		state.xdg_wm_base,
		state.wayland_current_id,
		state.wl_surface,
	)
	if err != nil do os.exit(int(err))
	state.xdg_surface = state.wayland_current_id
	register_event_handler(
		state,
		state.xdg_surface,
		&xdg_surface_handlers,
		xdg_surface.handle_event,
	)

	state.wayland_current_id += 1
	err = xdg_surface.get_toplevel(state.socket_fd, state.xdg_surface, state.wayland_current_id)
	if err != nil do os.exit(int(err))
	state.xdg_toplevel = state.wayland_current_id
	register_event_handler(
		state,
		state.xdg_toplevel,
		&xdg_toplevel_handlers,
		xdg_toplevel.handle_event,
	)
	err = xdg_toplevel.set_min_size(state.socket_fd, state.xdg_toplevel, 50, 50)
	if err != nil do os.exit(int(err))

	err = wl_surface.commit(state.socket_fd, state.wl_surface)
	if err != nil do os.exit(int(err))

	state.wayland_current_id += 1
	err = wl_shm.create_pool(
		state.socket_fd,
		state.wl_shm,
		state.wayland_current_id,
		state.shm_fd,
		i32(state.shm_pool_size),
	)
	if err != nil do os.exit(int(err))
	state.wl_shm_pool = state.wayland_current_id
	state.buffer_ready = true
}

draw_next_frame :: proc(state: ^state_t) {
	assert(state.wl_surface != 0)
	assert(state.xdg_surface != 0)
	assert(state.xdg_toplevel != 0)
	assert(state.shm_pool_data != nil)
	assert(state.shm_pool_size != 0)
	assert(state.buffer_ready)

	fmt.printfln("Drawing next frame")

	if state.w != state.buf_w || state.h != state.buf_h {
		if state.wl_buffer != 0 {
			err := wl_buffer.destroy(state.socket_fd, state.wl_buffer)
			if err != nil do os.exit(int(err))
			// Keep the handler registered until the compositor sends on_release
		}
		state.wayland_current_id += 1
		err := wl_shm_pool.create_buffer(
			state.socket_fd,
			state.wl_shm_pool,
			state.wayland_current_id,
			0,
			i32(state.w),
			i32(state.h),
			i32(state.w * constants.COLOR_CHANNELS),
			wl_shm.Format.Xrgb8888,
		)
		if err != nil do os.exit(int(err))
		state.wl_buffer = state.wayland_current_id
		state.buf_w = state.w
		state.buf_h = state.h
		register_event_handler(state, state.wl_buffer, &wl_buffer_handlers, wl_buffer.handle_event)
	}

	if state.w < 10 || state.h < 10 {
		state.state = .STATE_SURFACE_ATTACHED
		fmt.eprintfln("State is to small to safely draw the next frame")
		return
	}

	pixels := ([^]u32)(state.shm_pool_data)
	for y: u32 = 0; y < state.h; y += 1 {
		for x: u32 = 0; x < state.w; x += 1 {
			r, g, b: u8
			x_prime := x * 10 / state.w
			y_prime := y * 10 / state.h
			r = u8((x_prime + y_prime) % 2) * 255
			g = u8((x_prime + y_prime) % 2) * 255
			b = u8((x_prime + y_prime) % 2) * 255
			pixels[y * state.w + x] = (u32(r) << 16) | (u32(g) << 8) | u32(b)
		}
	}

	err: linux.Errno
	err = wl_surface.attach(state.socket_fd, state.wl_surface, state.wl_buffer, 0, 0)
	if err != nil do os.exit(int(err))
	err = wl_surface.damage_buffer(
		state.socket_fd,
		state.wl_surface,
		0,
		0,
		i32(state.w),
		i32(state.h),
	)
	if err != nil do os.exit(int(err))
	err = wl_surface.commit(state.socket_fd, state.wl_surface)
	if err != nil do os.exit(int(err))

	state.buffer_ready = false

	state.state = .STATE_SURFACE_ATTACHED
}
