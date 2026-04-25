package runner

import platform "../platform"
import renderer "../renderer"
import runtime_log "../runtime_log"
import "core:fmt"
import "core:sys/linux"
import "core:sys/posix"

OnInit :: proc(
	user_data: rawptr,
	logger: ^runtime_log.Logger,
	max_width: u32,
	max_height: u32,
) -> linux.Errno
OnFrame :: proc(
	user_data: rawptr,
	info: platform.FrameInfo,
) -> (
	frame_buf: ^renderer.VulkanFrameBuffer,
	err: linux.Errno,
)
OnShutdown :: proc(user_data: rawptr)

AppConfig :: struct {
	title:         string,
	min_w:         i32,
	min_h:         i32,
	log_blacklist: []string,
	user_data:     rawptr,
	on_init:       OnInit,
	on_frame:      OnFrame,
	on_shutdown:   OnShutdown,
}

_running: bool
_platform_ctx: ^platform.Context
_request_next_frame: bool

// request_frame schedules an additional render after the current frame is presented.
// Safe to call from on_frame callbacks.
request_frame :: proc() {
	_request_next_frame = true
}

_handle_signal :: proc "c" (sig: posix.Signal) {
	#partial switch sig {
	case .SIGTERM, .SIGINT:
		_running = false
	}
}

run :: proc(config: AppConfig) -> linux.Errno {
	_running = true
	sa := posix.sigaction_t {
		sa_handler = _handle_signal,
	}
	posix.sigaction(.SIGINT, &sa, nil)
	posix.sigaction(.SIGTERM, &sa, nil)

	logger: runtime_log.Logger
	runtime_log.initialize(&logger, config.log_blacklist)
	defer runtime_log.cleanup(&logger)

	ctx: platform.Context
	_platform_ctx = &ctx
	defer _platform_ctx = nil
	platform.init(
		&ctx,
		platform.InitParams {
			title = config.title,
			min_w = config.min_w,
			min_h = config.min_h,
			logger = &logger,
		},
	) or_return
	defer platform.shutdown(&ctx)

	initialized := false
	defer if initialized {
		config.on_shutdown(config.user_data)
	}

	for _running && !platform.should_close(&ctx) {
		platform.pump(&ctx) or_return

		if !initialized {
			max_width, max_height := platform.max_surface_size(&ctx)
			if max_width > 0 && max_height > 0 {
				config.on_init(config.user_data, &logger, max_width, max_height) or_return
				initialized = true
			}
		}

		if !initialized || !platform.ready_for_frame(&ctx) {
			continue
		}

		info := platform.consume_frame_info(&ctx)
		frame_buf, frame_err := config.on_frame(config.user_data, info)
		if frame_err != nil do return frame_err
		if frame_buf != nil {
			platform.present_dmabuf(&ctx, frame_buf) or_return
			if _request_next_frame {
				_request_next_frame = false
				platform.request_frame(&ctx)
			}
		} else {
			platform.skip_frame(&ctx)
		}
	}

	fmt.println("Got termination signal. Terminating...")
	return nil
}
