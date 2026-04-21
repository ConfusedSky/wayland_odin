package Main

import app "./app"
import wayland "./platform/wayland"
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

	wl: wayland.Client
	app_state: app.State

	err := run(&wl, &app_state)
	app.shutdown(&app_state)
	wayland.shutdown(&wl)
	if err != nil {
		fmt.eprintfln("Fatal error: %v", err)
		os.exit(int(err))
	}
}

run :: proc(wl: ^wayland.Client, app_state: ^app.State) -> wayland.Errno {
	wayland.init(wl, wayland.Init_Params{title = "odin", min_w = 50, min_h = 50}) or_return

	for running && !wayland.should_close(wl) {
		wayland.pump(wl) or_return

		if !app_state.initialized {
			max_width, max_height := wayland.max_surface_size(wl)
			if max_width > 0 && max_height > 0 {
				app.initialize(app_state, max_width, max_height) or_return
			}
		}

		if !app_state.initialized || !wayland.ready_for_frame(wl) {
			continue
		}

		frame_info := wayland.frame_info(wl)
		rendered, render_err := app.render_frame(app_state, frame_info)
		if render_err != nil {
			return render_err
		}
		if rendered {
			wayland.present_dmabuf(wl, &app_state.frame_buf) or_return
		} else {
			wayland.skip_frame(wl)
		}
	}

	fmt.println("Got termination signal. Terminating...")
	return nil
}
