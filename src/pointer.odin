package Main

import constants "constants"
import "core:os"
import wl_pointer "wayland_protocol/wl_pointer"
import wl_seat "wayland_protocol/wl_seat"

Pointer :: struct {
	surface_x:   f64,
	surface_y:   f64,
	prev_x_cell: u32,
	prev_y_cell: u32,
}

wl_pointer_handlers := wl_pointer.EventHandlers {
	on_motion = proc(
		source_object_id: u32,
		time: u32,
		surface_x: f64,
		surface_y: f64,
		user_data: rawptr,
	) {
		state := (^state_t)(user_data)
		state.pointer.surface_x = surface_x
		state.pointer.surface_y = surface_y

		x_cell := u32(surface_x) * constants.NUM_CELLS / state.w
		y_cell := u32(surface_y) * constants.NUM_CELLS / state.h
		if state.state == .STATE_SURFACE_ATTACHED &&
		   (x_cell != state.pointer.prev_x_cell || y_cell != state.pointer.prev_y_cell) {
			state.pointer.prev_x_cell = x_cell
			state.pointer.prev_y_cell = y_cell

			state.state = .STATE_SURFACE_ACKED_CONFIGURE
		}
	},
}

initialize_pointer :: proc(state: ^state_t) {
	pointer, err := wl_seat.get_pointer(&state.wl_seat)
	if err != nil do os.exit(int(err))
	state.wl_pointer = pointer
	register_event_handler(state, state.wl_pointer.id, &wl_pointer_handlers, wl_pointer.handle_event)
}
