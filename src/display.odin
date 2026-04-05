package Main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/linux"
import wl_display "wayland_protocol/wl_display"

wl_display_handlers := wl_display.EventHandlers {
	on_error = proc(_: u32, object_id: u32, code: u32, message: string, user_data: rawptr) {
		fmt.eprintfln(
			"fatal error: target_object_id=%v code=%v error=%s",
			object_id,
			code,
			message,
		)
		// wl_display errors are unrecoverable per the Wayland spec
		os.exit(int(linux.Errno.EINVAL))
	},
}

initialize_display :: proc(state: ^state_t) -> Errno {
	socket_fd := wayland_display_connect() or_return
	state.wl_display = wl_display.init(socket_fd)
	register_event_handler(
		state,
		1, // wl_display always has object id 1
		&wl_display_handlers,
		wl_display.handle_event,
	)
	return nil
}

wayland_display_connect :: proc() -> (linux.Fd, Errno) {
	xdg_runtime_dir_buf: [64]u8 = ---
	xdg_runtime_dir, xdg_runtime_dir_error := os.lookup_env(
		xdg_runtime_dir_buf[:],
		"XDG_RUNTIME_DIR",
	)

	if xdg_runtime_dir_error != nil {
		fmt.eprintln("XDG_RUNTIME_DIR not found!")
		return -1, linux.Errno.EINVAL
	}

	wayland_display_buf: [64]u8 = ---
	wayland_display, wayland_display_error := os.lookup_env(
		wayland_display_buf[:],
		"WAYLAND_DISPLAY",
	)

	display_name := wayland_display if wayland_display_error == nil else "wayland-0"

	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX

	assert(
		len(xdg_runtime_dir) + len(display_name) + 2 < len(addr.sun_path),
		"Socket path too long!",
	)

	socket_path_length := len(xdg_runtime_dir)
	mem.copy(&addr.sun_path[0], raw_data(xdg_runtime_dir[:]), len(xdg_runtime_dir))

	addr.sun_path[socket_path_length] = '/'
	socket_path_length += 1

	mem.copy(&addr.sun_path[socket_path_length], raw_data(display_name[:]), len(display_name))

	fd, socket_err := linux.socket(.UNIX, .STREAM, {}, {})
	if fd == -1 || socket_err != nil {
		fmt.eprintln("socket() failed:", socket_err)
		return -1, socket_err
	}

	connect_err := linux.connect(fd, &addr)
	if connect_err != nil {
		fmt.eprintln("connect() failed:", connect_err)
		return -1, connect_err
	}

	return fd, nil
}

wayland_display_connection_cleanup :: proc(fd: linux.Fd) -> Errno {
	close_err := linux.close(fd)
	if close_err != nil {
		fmt.eprintln("close failed")
		return close_err
	}
	return nil
}
