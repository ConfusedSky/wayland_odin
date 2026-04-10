package Main

import "core:fmt"
import "core:os"
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
	err := run(&state)
	cleanup(&state)
	if err != nil {
		fmt.eprintfln("Fatal error: %v", err)
		os.exit(int(err))
	}
}

run :: proc(state: ^state_t) -> Errno {
	initialize_display(state) or_return
	initialize_wl_registry(state) or_return
	initialize_vulkan(&state.vulkan) or_return

	for !state.cursor.initialized {
		wayland_handle_messages(state) or_return
		if state.wl_compositor.id > 0 && state.wl_shm.id > 0 {
			initialize_cursor(&state.wl_compositor, &state.wl_shm, &state.cursor) or_return
		}
	}

	for !state.buffer_ready && state.wl_surface.id == 0 {
		wayland_handle_messages(state) or_return
		if can_initialize_surface(state) {
			initialize_surface(state) or_return
		}
	}

	for running {
		wayland_handle_messages(state) or_return
		if state.buffer_ready && state.state == .STATE_SURFACE_ACKED_CONFIGURE {
			draw_next_frame(state) or_return
		}
	}

	fmt.println("Got termination signal. Terminating...")
	return nil
}
