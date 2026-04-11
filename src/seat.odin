package Main

import wl_seat "wayland_protocol/wl_seat"

wl_seat_handlers := wl_seat.EventHandlers {
	on_capabilities = proc(
		source_object_id: u32,
		capabilities: wl_seat.Capability,
		user_data: rawptr,
	) {
		state := (^state_t)(user_data)
		if .Keyboard in capabilities {
			err := initialize_keyboard(state)
			if err != nil {state.last_err = err; return}
		}
		if .Pointer in capabilities {
			err := initialize_pointer(state)
			if err != nil {state.last_err = err; return}
		}
	},
}

initialize_seat :: proc(state: ^state_t, name: u32, version: u32) -> Errno {
	state.wl_seat = wl_seat.from_global(&state.wl_registry, name, version) or_return
	register_event_handler(state, state.wl_seat.id, &wl_seat_handlers, wl_seat.handle_event)
	return nil
}
