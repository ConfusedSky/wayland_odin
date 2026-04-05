package Main

import constants "./constants"
import wl_buffer "wayland_protocol/wl_buffer"
import wl_shm "wayland_protocol/wl_shm"
import wl_shm_pool "wayland_protocol/wl_shm_pool"

wl_buffer_handlers := wl_buffer.EventHandlers {
	on_release = proc(source_object_id: u32, user_data: rawptr) {
		state := (^state_t)(user_data)
		if source_object_id == state.wl_buffer.id {
			state.buffer_ready = true
		} else {
			// Old buffer destroyed while in flight — safe to clean up its handler now
			unregister_event_handler(state, source_object_id)
		}
	},
}

initialize_wl_buffer :: proc(state: ^state_t) -> Errno {
	state.wl_buffer = wl_shm_pool.create_buffer(
		&state.shm_pool.wl_shm_pool,
		0,
		i32(state.w),
		i32(state.h),
		i32(state.w * constants.COLOR_CHANNELS),
		wl_shm.Format.Xrgb8888,
	) or_return
	state.buf_w = state.w
	state.buf_h = state.h
	register_event_handler(state, state.wl_buffer.id, &wl_buffer_handlers, wl_buffer.handle_event)
	return nil
}
