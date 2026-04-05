package Main

import wl_keyboard "wayland_protocol/wl_keyboard"
import wl_seat "wayland_protocol/wl_seat"

wl_keyboard_handlers := wl_keyboard.EventHandlers{}

initialize_keyboard :: proc(state: ^state_t) -> Errno {
	state.wl_keyboard = wl_seat.get_keyboard(&state.wl_seat) or_return
	register_event_handler(
		state,
		state.wl_keyboard.id,
		&wl_keyboard_handlers,
		wl_keyboard.handle_event,
	)
	return nil
}
