package wayland

import wl_keyboard "../../wayland_protocol/wl_keyboard"
import wl_seat "../../wayland_protocol/wl_seat"

wl_keyboard_handlers := wl_keyboard.EventHandlers{}

initialize_keyboard :: proc(client: ^Client) -> Errno {
	client.wl_keyboard = wl_seat.get_keyboard(&client.wl_seat) or_return
	register_event_handler(
		client,
		client.wl_keyboard.id,
		&wl_keyboard_handlers,
		wl_keyboard.handle_event,
	)
	return nil
}
