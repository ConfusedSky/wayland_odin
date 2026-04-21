package wayland

import wl_seat "../../wayland_protocol/wl_seat"

wl_seat_handlers := wl_seat.EventHandlers {
	on_capabilities = proc(
		source_object_id: u32,
		capabilities: wl_seat.Capability,
		user_data: rawptr,
	) -> Errno {
		client := (^Client)(user_data)
		if .Keyboard in capabilities {
			initialize_keyboard(client) or_return
		}
		if .Pointer in capabilities {
			initialize_pointer(client) or_return
		}
		return nil
	},
}

initialize_seat :: proc(client: ^Client, name: u32, version: u32) -> Errno {
	client.wl_seat = wl_seat.from_global(&client.wl_registry, name, version) or_return
	wl_seat_handlers.logger = &client.logger
	register_event_handler(client, client.wl_seat.id, &wl_seat_handlers, wl_seat.handle_event)
	return nil
}
