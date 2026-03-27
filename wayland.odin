package Main

import buf_writer "./buf_writer"
import constants "./constants"
import wl_compositor "wayland_protocol/wl_compositor"
import wl_display "wayland_protocol/wl_display"
import wl_registry "wayland_protocol/wl_registry"
import wl_shm "wayland_protocol/wl_shm"
import wl_shm_pool "wayland_protocol/wl_shm_pool"
import wl_surface "wayland_protocol/wl_surface"
import xdg_surface "wayland_protocol/xdg_surface"
import xdg_toplevel "wayland_protocol/xdg_toplevel"
import xdg_wm_base "wayland_protocol/xdg_wm_base"
import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"


wayland_current_id: u32 = 1

wayland_display_object_id: u32 : 1
color_channels: u32 : 4

state_state_t :: enum {
	STATE_NONE,
	STATE_SURFACE_ACKED_CONFIGURE,
	STATE_SURFACE_ATTACHED,
}

state_t :: struct {
	wl_registry:   u32,
	wl_shm:        u32,
	wl_shm_pool:   u32,
	wl_buffer:     u32,
	xdg_wm_base:   u32,
	xdg_surface:   u32,
	wl_compositor: u32,
	wl_surface:    u32,
	xdg_toplevel:  u32,
	stride:        u32,
	w:             u32,
	h:             u32,
	shm_pool_size: u32,
	shm_fd:        linux.Fd,
	shm_pool_data: ^u8,
	state:         state_state_t,
}

HandleContext :: struct {
	fd:    linux.Fd,
	state: ^state_t,
}

// Event handler callbacks

_on_wl_display_error :: proc(object_id: u32, code: u32, message: string, user_data: rawptr) {
	fmt.eprintfln("fatal error: target_object_id=%v code=%v error=%s", object_id, code, message)
	os.exit(int(linux.Errno.EINVAL))
}

_on_wl_registry_global :: proc(name: u32, interface: string, version: u32, user_data: rawptr) {
	ctx := (^HandleContext)(user_data)
	if interface == "wl_shm" {
		ctx.state.wl_shm = registry_bind(ctx.fd, ctx.state.wl_registry, name, interface, version)
	} else if interface == "xdg_wm_base" {
		ctx.state.xdg_wm_base = registry_bind(ctx.fd, ctx.state.wl_registry, name, interface, version)
	} else if interface == "wl_compositor" {
		ctx.state.wl_compositor = registry_bind(ctx.fd, ctx.state.wl_registry, name, interface, version)
	}
}

_on_xdg_wm_base_ping :: proc(serial: u32, user_data: rawptr) {
	ctx := (^HandleContext)(user_data)
	err := xdg_wm_base.pong(ctx.fd, ctx.state.xdg_wm_base, serial)
	if err != nil do os.exit(int(err))
}

_on_xdg_toplevel_close :: proc(user_data: rawptr) {
	running = false
}

_on_xdg_surface_configure :: proc(serial: u32, user_data: rawptr) {
	ctx := (^HandleContext)(user_data)
	err := xdg_surface.ack_configure(ctx.fd, ctx.state.xdg_surface, serial)
	if err != nil do os.exit(int(err))
	ctx.state.state = .STATE_SURFACE_ACKED_CONFIGURE
}

// Per-interface event handler tables
wl_display_handlers := wl_display.EventHandlers {
	on_error = _on_wl_display_error,
}
wl_registry_handlers := wl_registry.EventHandlers {
	on_global = _on_wl_registry_global,
}
wl_shm_handlers: wl_shm.EventHandlers
xdg_wm_base_handlers := xdg_wm_base.EventHandlers {
	on_ping = _on_xdg_wm_base_ping,
}
xdg_toplevel_handlers := xdg_toplevel.EventHandlers {
	on_close = _on_xdg_toplevel_close,
}
xdg_surface_handlers := xdg_surface.EventHandlers {
	on_configure = _on_xdg_surface_configure,
}

wayland_display_connect :: proc() -> linux.Fd {
	xdg_runtime_dir_buf: [64]u8 = ---
	xdg_runtime_dir, xdg_runtime_dir_error := os.lookup_env(
		xdg_runtime_dir_buf[:],
		"XDG_RUNTIME_DIR",
	)

	if xdg_runtime_dir_error != nil {
		fmt.eprintln("XDG_RUNTIME_DIR not found!")
		os.exit(int(linux.Errno.EINVAL))
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
		os.exit(int(socket_err))
	}

	// Connect
	connect_err := linux.connect(fd, &addr)
	if connect_err != nil {
		fmt.eprintln("connect() failed:", connect_err)
		os.exit(int(connect_err))
	}

	return fd
}

wayland_display_connection_cleanup :: proc(fd: linux.Fd) {
	close_err := linux.close(fd)

	if (close_err != nil) {
		fmt.eprintln("close failed")
		os.exit(int(close_err))
	}
}

buf_read_unsigned_int :: proc(
	buf: ^^u8,
	buf_size: ^int,
	$T: typeid,
) -> T where intrinsics.type_is_unsigned(T) &&
	intrinsics.type_is_numeric(T) {
	assert(buf_size^ >= size_of(T))
	assert(uintptr(buf^) % size_of(T) == 0)

	res := (^T)(buf^)^
	buf^ = mem.ptr_offset(buf^, size_of(T))
	buf_size^ -= size_of(T)

	return res
}

// registry_bind sends the full wl_registry.bind wire message including the
// interface string and version, which are required for the untyped new_id arg.
// The generated wl_registry.bind does not yet handle this special case.
// interface must not include a null terminator; registry_bind appends one.
registry_bind :: proc(
	socket: linux.Fd,
	registry: u32,
	name: u32,
	interface: string,
	version: u32,
) -> u32 {
	writer: buf_writer.Writer(constants.BUF_WRITER_SIZE_STRING)
	buf_writer.initialize(&writer, registry, wl_registry.BIND_REQUEST_OPCODE)
	buf_writer.write_u32(&writer, name)
	// Wayland strings include null terminator in the length field
	interface_wire := strings.concatenate({interface, "\x00"})
	defer delete(interface_wire)
	buf_writer.write_string(&writer, interface_wire)
	buf_writer.write_u32(&writer, version)
	wayland_current_id += 1
	buf_writer.write_u32(&writer, wayland_current_id)
	send_err := buf_writer.send(&writer, socket)
	if send_err != nil do os.exit(int(send_err))
	fmt.printfln(
		"-> wl_registry@%v.bind: name=%v interface=%v version=%v id=%v",
		registry,
		name,
		interface,
		version,
		wayland_current_id,
	)
	return wayland_current_id
}

create_shared_memory_file :: proc(state: ^state_t) {
	fd, memfd_err := linux.memfd_create("shm_file", {})

	if fd == -1 || memfd_err != nil {
		fmt.eprintln("open failed")
		os.exit(int(memfd_err))
	}

	ftruncate_err := linux.ftruncate(fd, i64(state.shm_pool_size))
	if ftruncate_err != nil {
		fmt.eprintln("ftruncate failed")
		os.exit(int(ftruncate_err))
	}

	// this needs to be mmunmaped and closed if the screen is resized and this
	// function is used to create a new memory file
	data, mmap_err := linux.mmap(
		uintptr(0),
		uint(state.shm_pool_size),
		{.READ, .WRITE},
		{.SHARED},
		fd,
	)

	if mmap_err != nil {
		fmt.eprintln("mmap failed")
		os.exit(int(mmap_err))
	}

	state.shm_pool_data = (^u8)(data)
	assert(state.shm_pool_data != (^u8)(~uintptr(0)))
	assert(state.shm_pool_data != nil)
	state.shm_fd = fd
}

cleanup_shared_memory_file :: proc(state: ^state_t) {
	assert(state.shm_pool_data != nil)
	assert(state.shm_pool_size > 0)
	assert(state.shm_fd > 0)

	munmap_err := linux.munmap(rawptr(state.shm_pool_data), uint(state.shm_pool_size))
	state.shm_pool_data = nil
	state.shm_pool_size = 0

	if munmap_err != nil {
		fmt.eprintln("munmap failed")
		os.exit(int(munmap_err))
	}

	close_err := linux.close(state.shm_fd)

	if close_err != nil {
		fmt.eprintln("close failed")
		os.exit(int(close_err))
	}

	state.shm_fd = 0
}

wayland_handle_message :: proc(fd: linux.Fd, state: ^state_t, msg: ^^u8, msg_len: ^int) {
	assert(msg_len^ >= 8)

	object_id      := buf_read_unsigned_int(msg, msg_len, u32)
	assert(object_id <= wayland_current_id)
	opcode         := buf_read_unsigned_int(msg, msg_len, u16)
	announced_size := buf_read_unsigned_int(msg, msg_len, u16)

	header_size: u16 = size_of(object_id) + size_of(opcode) + size_of(announced_size)
	assert(announced_size % 4 == 0)
	assert(int(announced_size) <= int(header_size) + msg_len^)

	body_size           := int(announced_size) - int(header_size)
	msg_len_before_body := msg_len^

	ctx := HandleContext{fd = fd, state = state}

	if object_id == wayland_display_object_id {
		wl_display.handle_event(object_id, opcode, msg, msg_len, &wl_display_handlers, &ctx)
	} else if object_id == state.wl_registry {
		wl_registry.handle_event(object_id, opcode, msg, msg_len, &wl_registry_handlers, &ctx)
	} else if object_id == state.wl_shm {
		wl_shm.handle_event(object_id, opcode, msg, msg_len, &wl_shm_handlers, &ctx)
	} else if object_id == state.xdg_wm_base {
		xdg_wm_base.handle_event(object_id, opcode, msg, msg_len, &xdg_wm_base_handlers, &ctx)
	} else if object_id == state.xdg_toplevel {
		xdg_toplevel.handle_event(object_id, opcode, msg, msg_len, &xdg_toplevel_handlers, &ctx)
	} else if object_id == state.xdg_surface {
		xdg_surface.handle_event(object_id, opcode, msg, msg_len, &xdg_surface_handlers, &ctx)
	} else {
		fmt.eprintfln(
			"unknown event: object_id=%d opcode=%d size=%d state=%v, skipping...",
			object_id,
			opcode,
			announced_size,
			state,
		)
	}

	// Skip any remaining bytes in this message (unknown opcodes or unknown objects)
	bytes_consumed := msg_len_before_body - msg_len^
	if bytes_consumed < body_size {
		to_skip := body_size - bytes_consumed
		msg^ = mem.ptr_offset(msg^, to_skip)
		msg_len^ -= to_skip
	}
}

running := true

handle_signal :: proc "c" (sig: posix.Signal) {
	#partial switch sig {
	case .SIGTERM, .SIGINT:
		running = false
	}
}

main :: proc() {
	posix.signal(.SIGTERM, handle_signal)
	posix.signal(.SIGINT, handle_signal)

	fd := wayland_display_connect()

	wayland_current_id += 1
	err := wl_display.get_registry(fd, wayland_display_object_id, wayland_current_id)
	if err != nil do os.exit(int(err))
	state: state_t = {
		wl_registry = wayland_current_id,
		w           = 117,
		h           = 150,
		stride      = 117 * color_channels,
	}

	state.shm_pool_size = state.h * state.stride
	create_shared_memory_file(&state)

	for running {
		read_buf: [4096]u8
		read_bytes, recv_error := linux.recv(fd, read_buf[:], {})

		if read_bytes == -1 || recv_error != nil {
			fmt.eprintln("Failed to receive new events")
			os.exit(int(recv_error))
		}

		fmt.printfln("Received %d bytes", read_bytes)

		msg := &read_buf[0]
		msg_len := int(read_bytes)

		for msg_len > 0 {
			wayland_handle_message(fd, &state, &msg, &msg_len)
		}

		if (state.wl_compositor != 0 &&
			   state.wl_shm != 0 &&
			   state.xdg_wm_base != 0 &&
			   state.wl_surface == 0) {
			assert(state.state == .STATE_NONE)

			wayland_current_id += 1
			err = wl_compositor.create_surface(fd, state.wl_compositor, wayland_current_id)
			if err != nil do os.exit(int(err))
			state.wl_surface = wayland_current_id

			wayland_current_id += 1
			err = xdg_wm_base.get_xdg_surface(
				fd,
				state.xdg_wm_base,
				wayland_current_id,
				state.wl_surface,
			)
			if err != nil do os.exit(int(err))
			state.xdg_surface = wayland_current_id

			wayland_current_id += 1
			err = xdg_surface.get_toplevel(fd, state.xdg_surface, wayland_current_id)
			if err != nil do os.exit(int(err))
			state.xdg_toplevel = wayland_current_id

			err = wl_surface.commit(fd, state.wl_surface)
			if err != nil do os.exit(int(err))
		}

		if (state.state == .STATE_SURFACE_ACKED_CONFIGURE) {
			assert(state.wl_surface != 0)
			assert(state.xdg_surface != 0)
			assert(state.xdg_toplevel != 0)

			if (state.wl_shm_pool == 0) {
				wayland_current_id += 1
				err = wl_shm.create_pool(
					fd,
					state.wl_shm,
					wayland_current_id,
					state.shm_fd,
					i32(state.shm_pool_size),
				)
				if err != nil do os.exit(int(err))
				state.wl_shm_pool = wayland_current_id
			}
			if (state.wl_buffer == 0) {
				wayland_current_id += 1
				err = wl_shm_pool.create_buffer(
					fd,
					state.wl_shm_pool,
					wayland_current_id,
					0,
					i32(state.w),
					i32(state.h),
					i32(state.stride),
					wl_shm.Format.Xrgb8888,
				)
				if err != nil do os.exit(int(err))
				state.wl_buffer = wayland_current_id
			}

			assert(state.shm_pool_data != nil)
			assert(state.shm_pool_size != 0)

			pixels := ([^]u32)(state.shm_pool_data)
			for i: u32 = 0; i < state.w * state.h; i += 1 {
				border_size :: 4
				x := u8(i % state.w)
				y := u8(i / state.w)

				r, g, b: u8
				// if (x > border_size && u32(x) < state.w - border_size) &&
				//    (y > border_size && u32(y) < state.h - border_size) {
				r = (((x / 10) + (y / 10)) % 2) * 255
				g = (((x / 10) + (y / 10)) % 2) * 255
				b = (((x / 10) + (y / 10)) % 2) * 255
				//}

				pixels[i] = (u32(r) << 16) | (u32(g) << 8) | u32(b)
			}

			err = wl_surface.attach(fd, state.wl_surface, state.wl_buffer, 0, 0)
			if err != nil do os.exit(int(err))
			err = wl_surface.commit(fd, state.wl_surface)
			if err != nil do os.exit(int(err))

			state.state = .STATE_SURFACE_ATTACHED
		}
	}

	fmt.println("Got termination signal. Terminating...")
	cleanup_shared_memory_file(&state)
	wayland_display_connection_cleanup(fd)
}
