package Main

import app "./app"
import platform "./platform"
import runtime_log "./runtime_log"
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
	params := platform.InitParams {
		title         = "odin",
		min_w         = 50,
		min_h         = 50,
		log_blacklist = {
			"app.frame.draw",
			"wayland.request.wl_surface.attach",
			"wayland.request.wl_surface.damage_buffer",
			"wayland.request.wl_surface.frame",
			"wayland.request.wl_surface.commit",
			"wayland.event.wl_callback.done",
			"wayland.event.wl_display.delete_id",
			"wayland.event.wl_pointer.motion",
			"wayland.event.wl_pointer.frame",
			"wayland.event.xdg_wm_base.ping",
			"wayland.request.xdg_wm_base.pong",
			"platform.recv_batch",
		},
	}
	main_logger: runtime_log.Logger
	runtime_log.initialize(&main_logger, params.log_blacklist)
	defer runtime_log.cleanup(&main_logger)
	platform.init(ctx, params) or_return

	for running && !platform.should_close(ctx) {
		platform.pump(ctx) or_return

		if !app_state.initialized {
			max_width, max_height := platform.max_surface_size(ctx)
			if max_width > 0 && max_height > 0 {
				app.initialize(app_state, params.log_blacklist, max_width, max_height) or_return
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

	if runtime_log.should_log(&main_logger, "app.shutdown.signal") {
		fmt.println("Got termination signal. Terminating...")
	}
	return nil
}
