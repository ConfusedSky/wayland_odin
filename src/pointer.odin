package Main

import "core:os"
import wl_pointer "wayland_protocol/wl_pointer"
import wl_seat "wayland_protocol/wl_seat"

wl_pointer_handlers := wl_pointer.EventHandlers{}

initialize_pointer :: proc(state: ^state_t) {
	state.wayland_current_id += 1
	err := wl_seat.get_pointer(state.socket_fd, state.wl_seat, state.wayland_current_id)
	if err != nil do os.exit(int(err))
	state.wl_pointer = state.wayland_current_id
	register_event_handler(state, state.wl_pointer, &wl_pointer_handlers, wl_pointer.handle_event)
}
