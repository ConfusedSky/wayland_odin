package Main

import wl_buffer "wayland_protocol/wl_buffer"
import wl_callback "wayland_protocol/wl_callback"

wl_buffer_handlers := wl_buffer.EventHandlers {
	on_release = proc(source_object_id: u32, user_data: rawptr) {
		state := (^state_t)(user_data)
		if source_object_id != state.dmabuf.wl_buf.id {
			// Old buffer destroyed while in flight — safe to clean up its handler now
			unregister_event_handler(state, source_object_id)
		}
	},
}

wl_callback_handlers := wl_callback.EventHandlers {
	on_done = proc(source_object_id: u32, _: u32, user_data: rawptr) {
		state := (^state_t)(user_data)
		unregister_event_handler(state, source_object_id)
		state.dmabuf.buffer_ready = true
	},
}
