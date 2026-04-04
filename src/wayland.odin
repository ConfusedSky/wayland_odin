package Main

import "core:fmt"
import "core:sys/posix"

running := true

handle_signal :: proc "c" (sig: posix.Signal) {
	#partial switch sig {
	case .SIGTERM, .SIGINT:
		running = false
	}
}

main :: proc() {
	sa := posix.sigaction_t {
		sa_handler = handle_signal,
	}
	posix.sigaction(.SIGINT, &sa, nil)
	posix.sigaction(.SIGTERM, &sa, nil)

	state: state_t
	initialize_display(&state)
	initialize_wl_registry(&state)

	wayland_handle_messages(&state)
	if (state.wl_compositor.id > 0 && state.wl_shm.id > 0 && !state.cursor.initialized) {
		initialize_cursor(&state.wl_compositor, &state.wl_shm, &state.cursor)
	} else {
		panic("Cursor failed to initialize")
	}

	wayland_handle_messages(&state)
	if (can_initialize_surface(&state)) {
		initialize_surface(&state)
	} else {
		panic("Surface failed to initialize")
	}

	for running {
		wayland_handle_messages(&state)

		if (state.buffer_ready && state.state == .STATE_SURFACE_ACKED_CONFIGURE) {
			draw_next_frame(&state)
		}
	}

	fmt.println("Got termination signal. Terminating...")
	cleanup(&state)
}
