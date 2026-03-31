package Main

import "core:os"
import wl_keyboard "wayland_protocol/wl_keyboard"
import wl_seat "wayland_protocol/wl_seat"

wl_keyboard_handlers := wl_keyboard.EventHandlers{}

initialize_keyboard :: proc(state: ^state_t) {
	state.wayland_current_id += 1
	err := wl_seat.get_keyboard(state.socket_fd, state.wl_seat, state.wayland_current_id)
	if err != nil do os.exit(int(err))
	state.wl_keyboard = state.wayland_current_id
	register_event_handler(
		state,
		state.wl_keyboard,
		&wl_keyboard_handlers,
		wl_keyboard.handle_event,
	)
}
