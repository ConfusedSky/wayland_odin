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

	for running {
		wayland_handle_messages(&state)

		if (can_initialize_surface(&state)) {
			initialize_surface(&state)
		}

		if (state.wl_shm_pool.id > 0 &&
			   state.w > 0 &&
			   state.h > 0 &&
			   state.buffer_ready &&
			   state.state == .STATE_SURFACE_ACKED_CONFIGURE) {
			draw_next_frame(&state)
		}
	}

	fmt.println("Got termination signal. Terminating...")
	cleanup(&state)
}
