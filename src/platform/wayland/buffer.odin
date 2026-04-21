package wayland

import wl_buffer "../../wayland_protocol/wl_buffer"
import wl_callback "../../wayland_protocol/wl_callback"

wl_buffer_handlers := wl_buffer.EventHandlers {
	on_release = proc(source_object_id: u32, user_data: rawptr) {
		client := (^Client)(user_data)
		if source_object_id != client.wl_buffer.id {
			unregister_event_handler(client, source_object_id)
		}
	},
}

wl_callback_handlers := wl_callback.EventHandlers {
	on_done = proc(source_object_id: u32, _: u32, user_data: rawptr) {
		client := (^Client)(user_data)
		unregister_event_handler(client, source_object_id)
		client.buffer_ready = true
	},
}
