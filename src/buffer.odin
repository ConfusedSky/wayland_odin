package Main

import constants "./constants"
import "core:os"
import wl_buffer "wayland_protocol/wl_buffer"
import wl_shm "wayland_protocol/wl_shm"
import wl_shm_pool "wayland_protocol/wl_shm_pool"

wl_buffer_handlers := wl_buffer.EventHandlers {
	on_release = proc(source_object_id: u32, user_data: rawptr) {
		state := (^state_t)(user_data)
		if source_object_id == state.wl_buffer {
			state.buffer_ready = true
		} else {
			// Old buffer destroyed while in flight — safe to clean up its handler now
			unregister_event_handler(state, source_object_id)
		}
	},
}

initialize_wl_buffer :: proc(state: ^state_t) {
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
