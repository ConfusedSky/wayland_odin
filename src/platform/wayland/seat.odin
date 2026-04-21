package wayland

import wl_seat "../../wayland_protocol/wl_seat"

wl_seat_handlers := wl_seat.EventHandlers {
	on_capabilities = proc(
		source_object_id: u32,
		capabilities: wl_seat.Capability,
		user_data: rawptr,
	) {
		client := (^Client)(user_data)
		if .Keyboard in capabilities {
			err := initialize_keyboard(client)
			if err != nil {
				client.last_err = err
				return
			}
		}
		if .Pointer in capabilities {
			err := initialize_pointer(client)
			if err != nil {
				client.last_err = err
				return
			}
		}
	},
}

initialize_seat :: proc(client: ^Client, name: u32, version: u32) -> Errno {
	client.wl_seat = wl_seat.from_global(&client.wl_registry, name, version) or_return
	register_event_handler(client, client.wl_seat.id, &wl_seat_handlers, wl_seat.handle_event)
	return nil
}
