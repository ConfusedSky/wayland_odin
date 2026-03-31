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
			initialize_keyboard(state)
		}
		if .Pointer in capabilities {
			initialize_pointer(state)
		}
	},
}

initialize_seat :: proc(state: ^state_t, name: u32, version: u32) {
	state.wayland_current_id += 1
	state.wl_seat = registry_bind(
		state.socket_fd,
		state.wl_registry,
		name,
		"wl_seat",
		version,
		state.wayland_current_id,
	)
	register_event_handler(state, state.wl_seat, &wl_seat_handlers, wl_seat.handle_event)
}
