package Main

import app "./app"
import platform "./platform"
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

	ctx: platform.Context
	app_state: app.State

	err := run(&ctx, &app_state)
	app.shutdown(&app_state)
	platform.shutdown(&ctx)
	if err != nil {
		fmt.eprintfln("Fatal error: %v", err)
		os.exit(int(err))
	}
}

run :: proc(ctx: ^platform.Context, app_state: ^app.State) -> platform.Errno {
	platform.init(ctx, platform.InitParams{title = "odin", min_w = 50, min_h = 50}) or_return

	for running && !platform.should_close(ctx) {
		platform.pump(ctx) or_return

		if !app_state.initialized {
			max_width, max_height := platform.max_surface_size(ctx)
			if max_width > 0 && max_height > 0 {
				app.initialize(app_state, max_width, max_height) or_return
			}
		}

		if !app_state.initialized || !platform.ready_for_frame(ctx) {
			continue
		}

		frame_info := platform.frame_info(ctx)
		rendered, render_err := app.render_frame(app_state, frame_info)
		if render_err != nil {
			return render_err
		}
		if rendered {
			platform.present_dmabuf(ctx, &app_state.frame_buf) or_return
		} else {
			platform.skip_frame(ctx)
		}
	}

	fmt.println("Got termination signal. Terminating...")
	return nil
}
