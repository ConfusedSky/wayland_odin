package Main

import "core:os"
import wl_keyboard "wayland_protocol/wl_keyboard"
import wl_seat "wayland_protocol/wl_seat"

wl_keyboard_handlers := wl_keyboard.EventHandlers{}

initialize_keyboard :: proc(state: ^state_t) {
	keyboard, err := wl_seat.get_keyboard(&state.wl_seat)
	if err != nil do os.exit(int(err))
	state.wl_keyboard = keyboard
	register_event_handler(
		state,
		state.wl_keyboard.id,
		&wl_keyboard_handlers,
		wl_keyboard.handle_event,
	)
}
