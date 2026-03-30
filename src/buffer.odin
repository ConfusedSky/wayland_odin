package Main

import wl_buffer "wayland_protocol/wl_buffer"

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
