package Main

import "core:os"
import wl_seat "wayland_protocol/wl_seat"

wl_seat_handlers := wl_seat.EventHandlers {
	on_capabilities = proc(
		source_object_id: u32,
		capabilities: wl_seat.Capability,
		user_data: rawptr,
	) {
		state := (^state_t)(user_data)
		if .Keyboard in capabilities {
			initialize_keyboard(state)
		}
		if .Pointer in capabilities {
			initialize_pointer(state)
		}
	},
}

initialize_seat :: proc(state: ^state_t, name: u32, version: u32) {
	seat, err := wl_seat.from_global(&state.wl_registry, name, version)
	if err != nil do os.exit(int(err))
	state.wl_seat = seat
	register_event_handler(state, state.wl_seat.id, &wl_seat_handlers, wl_seat.handle_event)
}
