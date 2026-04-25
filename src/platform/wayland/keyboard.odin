package wayland

import wl_keyboard "../../wayland_protocol/wl_keyboard"
import wl_seat "../../wayland_protocol/wl_seat"
import "core:sys/linux"

wl_keyboard_handlers := wl_keyboard.EventHandlers {
	on_key = proc(
		source_object_id: u32,
		serial: u32,
		time: u32,
		key: u32,
		state: wl_keyboard.KeyState,
		user_data: rawptr,
	) -> linux.Errno {
		client := (^Client)(user_data)
		if state == .Pressed && client.keyboard.n_keys < 16 {
			client.keyboard.keys_pressed[client.keyboard.n_keys] = key
			client.keyboard.n_keys += 1
		}
		return nil
	},
}

initialize_keyboard :: proc(client: ^Client) -> Errno {
	client.wl_keyboard = wl_seat.get_keyboard(&client.wl_seat) or_return
	wl_keyboard_handlers.logger = client.logger
	register_event_handler(
		client,
		client.wl_keyboard.id,
		&wl_keyboard_handlers,
		wl_keyboard.handle_event,
	)
	return nil
}
