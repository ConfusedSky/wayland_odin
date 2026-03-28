package Main

import buf_writer "./buf_writer"
import constants "./constants"
import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import wl_buffer "wayland_protocol/wl_buffer"
import wl_compositor "wayland_protocol/wl_compositor"
import wl_display "wayland_protocol/wl_display"
import wl_output "wayland_protocol/wl_output"
import wl_registry "wayland_protocol/wl_registry"
import wl_shm "wayland_protocol/wl_shm"
import wl_shm_pool "wayland_protocol/wl_shm_pool"
import wl_surface "wayland_protocol/wl_surface"
import xdg_surface "wayland_protocol/xdg_surface"
import xdg_toplevel "wayland_protocol/xdg_toplevel"
import xdg_wm_base "wayland_protocol/xdg_wm_base"

running := true

wayland_display_object_id: u32 : 1
color_channels: u32 : 4
MAX_OUTPUTS :: 8

Output :: struct {
	object_id: u32,
	is_done:   bool,
	w:         u32,
	h:         u32,
	user_data: OutputUserData,
}

state_state_t :: enum {
	STATE_NONE,
	STATE_SURFACE_ACKED_CONFIGURE,
	STATE_SURFACE_ATTACHED,
}

state_t :: struct {
	socket_fd:          linux.Fd,
	wl_registry:        u32,
	wl_shm:             u32,
	wl_shm_pool:        u32,
	wl_buffer:          u32,
	buffer_ready:       bool,
	xdg_wm_base:        u32,
	xdg_surface:        u32,
	wl_compositor:      u32,
	wl_surface:         u32,
	wl_output:          [MAX_OUTPUTS]Output,
	wl_output_count:    int,
	xdg_toplevel:       u32,
	stride:             u32,
	max_stride:         u32,
	w:                  u32,
	max_w:              u32,
	h:                  u32,
	max_h:              u32,
	buf_w:              u32,
	buf_h:              u32,
	shm_pool_size:      u32,
	shm_fd:             linux.Fd,
	shm_pool_data:      ^u8,
	state:              state_state_t,
	wayland_current_id: u32,
	event_handlers:     [dynamic]RegisteredEventHandler,
}

// Event handler callbacks

_on_wl_display_error :: proc(
	_: u32,
	object_id: u32,
	code: u32,
	message: string,
	user_data: rawptr,
) {
	fmt.eprintfln("fatal error: target_object_id=%v code=%v error=%s", object_id, code, message)
	os.exit(int(linux.Errno.EINVAL))
}

_on_wl_registry_global :: proc(
	_: u32,
	name: u32,
	interface: string,
	version: u32,
	user_data: rawptr,
) {
	state := (^state_t)(user_data)
	if interface == "wl_shm" {
		state.wayland_current_id += 1
		state.wl_shm = registry_bind(
			state.socket_fd,
			state.wl_registry,
			name,
			interface,
			version,
			state.wayland_current_id,
		)
		register_event_handler(state, state.wl_shm, &wl_shm_handlers, wl_shm.handle_event)
	} else if interface == "wl_output" {
		state.wayland_current_id += 1
		output := Output {
			object_id = registry_bind(
				state.socket_fd,
				state.wl_registry,
				name,
				interface,
				version,
				state.wayland_current_id,
			),
			is_done   = false,
		}
		assert(state.wl_output_count < MAX_OUTPUTS)
		state.wl_output[state.wl_output_count] = output
		state.wl_output[state.wl_output_count].user_data = OutputUserData {
			state  = state,
			output = &state.wl_output[state.wl_output_count],
		}
		state.wl_output_count += 1
		register_event_handler(
			state,
			output.object_id,
			&wl_output_handlers,
			wl_output.handle_event,
			&state.wl_output[state.wl_output_count - 1].user_data,
		)
	} else if interface == "xdg_wm_base" {
		state.wayland_current_id += 1
		state.xdg_wm_base = registry_bind(
			state.socket_fd,
			state.wl_registry,
			name,
			interface,
			version,
			state.wayland_current_id,
		)
		register_event_handler(
			state,
			state.xdg_wm_base,
			&xdg_wm_base_handlers,
			xdg_wm_base.handle_event,
		)
	} else if interface == "wl_compositor" {
		state.wayland_current_id += 1
		state.wl_compositor = registry_bind(
			state.socket_fd,
			state.wl_registry,
			name,
			interface,
			version,
			state.wayland_current_id,
		)
	}
}

_on_xdg_wm_base_ping :: proc(_: u32, serial: u32, user_data: rawptr) {
	state := (^state_t)(user_data)
	err := xdg_wm_base.pong(state.socket_fd, state.xdg_wm_base, serial)
	if err != nil do os.exit(int(err))
}

_on_xdg_toplevel_close :: proc(_: u32, user_data: rawptr) {
	running = false
}

_on_xdg_surface_configure :: proc(_: u32, serial: u32, user_data: rawptr) {
	state := (^state_t)(user_data)
	err := xdg_surface.ack_configure(state.socket_fd, state.xdg_surface, serial)
	if err != nil do os.exit(int(err))
	state.state = .STATE_SURFACE_ACKED_CONFIGURE
}

// Per-interface event handler tables
wl_buffer_handlers := wl_buffer.EventHandlers {
	on_release = proc(source_object_id: u32, user_data: rawptr) {
		state := (^state_t)(user_data)
		if source_object_id == state.wl_buffer {
			state.buffer_ready = true
		} else {
			// Old buffer destroyed while in flight — safe to clean up its handler now
			for handler, i in state.event_handlers {
				if handler.object_id == source_object_id {
					ordered_remove(&state.event_handlers, i)
					break
				}
			}
		}
	},
}
wl_display_handlers := wl_display.EventHandlers {
	on_error = _on_wl_display_error,
}

OutputUserData :: struct {
	output: ^Output,
	state:  ^state_t,
}

wl_output_handlers := wl_output.EventHandlers {
	on_mode = proc(
		source_object_id: u32,
		flags: wl_output.Mode,
		width: i32,
		height: i32,
		refresh: i32,
		user_data: rawptr,
	) {
		data := (^OutputUserData)(user_data)
		if .Current in flags {
			assert(data.output != nil)
			data.output.w = u32(width)
			data.output.h = u32(height)
		}
	},
	on_done = proc(source_object_id: u32, user_data: rawptr) {
		data := (^OutputUserData)(user_data)
		assert(data.output != nil)
		data.output.is_done = true

		all_done := true
		max_w, max_h: u32
		for &output in data.state.wl_output[:data.state.wl_output_count] {
			if !output.is_done {
				all_done = false
				break
			} else {
				max_w = max(max_w, output.w)
				max_h = max(max_h, output.h)
			}
		}

		if all_done {
			data.state.max_w = max_w
			data.state.max_h = max_h
			data.state.max_stride = data.state.max_w * color_channels
			data.state.shm_pool_size = data.state.max_h * data.state.max_stride
		}
	},
}
wl_registry_handlers := wl_registry.EventHandlers {
	on_global = _on_wl_registry_global,
}
wl_surface_handlers: wl_surface.EventHandlers
wl_shm_handlers: wl_shm.EventHandlers
xdg_wm_base_handlers := xdg_wm_base.EventHandlers {
	on_ping = _on_xdg_wm_base_ping,
}
xdg_toplevel_handlers := xdg_toplevel.EventHandlers {
	on_close = _on_xdg_toplevel_close,
	on_configure = proc(_: u32, width: i32, height: i32, states: []u8, user_data: rawptr) {
		state := (^state_t)(user_data)
		if width < 50 || height < 50 {
			state.w, state.h = 50, 50
			return
		}
		state.w = u32(width)
		state.h = u32(height)
	},
}
xdg_surface_handlers := xdg_surface.EventHandlers {
	on_configure = _on_xdg_surface_configure,
}

HandleEventProc :: proc(
	object_id: u32,
	opcode: u16,
	msg: ^^u8,
	msg_len: ^int,
	handlers_raw: rawptr,
	user_data: rawptr,
)

RegisteredEventHandler :: struct {
	event_handlers: rawptr,
	handle_event:   HandleEventProc,
	object_id:      u32,
	user_data:      rawptr,
}

register_event_handler :: proc(
	state: ^state_t,
	object_id: u32,
	event_handlers: rawptr,
	handle_event: HandleEventProc,
	user_data: rawptr = nil,
) {
	append(
		&state.event_handlers,
		RegisteredEventHandler {
			event_handlers = event_handlers,
			object_id = object_id,
			handle_event = handle_event,
			user_data = user_data if user_data != nil else state,
		},
	)
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
	new_id: u32,
) -> u32 {
	writer: buf_writer.Writer(constants.BUF_WRITER_SIZE_STRING)
	buf_writer.initialize(&writer, registry, wl_registry.BIND_REQUEST_OPCODE)
	buf_writer.write_u32(&writer, name)
	// Wayland strings include null terminator in the length field
	interface_wire := strings.concatenate({interface, "\x00"})
	defer delete(interface_wire)
	buf_writer.write_string(&writer, interface_wire)
	buf_writer.write_u32(&writer, version)
	buf_writer.write_u32(&writer, new_id)
	send_err := buf_writer.send(&writer, socket)
	if send_err != nil do os.exit(int(send_err))
	fmt.printfln(
		"-> wl_registry@%v.bind: name=%v interface=%v version=%v id=%v",
		registry,
		name,
		interface,
		version,
		new_id,
	)
	return new_id
}

create_shared_memory_file :: proc(state: ^state_t) {
	assert(state.max_w > 0)
	assert(state.max_h > 0)
	assert(state.max_stride == state.max_w * color_channels)
	assert(state.shm_pool_size > 0)
	assert(state.shm_pool_size == state.max_h * state.max_stride)

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

wayland_handle_messages :: proc(state: ^state_t) {
	read_buf: [4096]u8
	read_bytes, recv_error := linux.recv(state.socket_fd, read_buf[:], {})

	if recv_error == .EINTR {
		return
	} else if read_bytes == -1 || recv_error != nil {
		fmt.eprintln("Failed to receive new events")
		os.exit(int(recv_error))
	}

	fmt.printfln("Received %d bytes", read_bytes)

	msg := &read_buf[0]
	msg_len := int(read_bytes)

	for msg_len > 0 {
		wayland_handle_message(state, &msg, &msg_len)
	}
}

wayland_handle_message :: proc(state: ^state_t, msg: ^^u8, msg_len: ^int) {
	assert(msg_len^ >= 8)

	object_id := buf_read_unsigned_int(msg, msg_len, u32)
	assert(object_id <= state.wayland_current_id)
	opcode := buf_read_unsigned_int(msg, msg_len, u16)
	announced_size := buf_read_unsigned_int(msg, msg_len, u16)

	header_size: u16 = size_of(object_id) + size_of(opcode) + size_of(announced_size)
	assert(announced_size % 4 == 0)
	assert(int(announced_size) <= int(header_size) + msg_len^)

	body_size := int(announced_size) - int(header_size)
	msg_len_before_body := msg_len^

	object_found := false

	for handler in state.event_handlers {
		if object_id == handler.object_id {
			object_found = true
			handler.handle_event(
				object_id,
				opcode,
				msg,
				msg_len,
				handler.event_handlers,
				handler.user_data,
			)
			break
		}
	}

	if !object_found {
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

can_initialize_surface :: proc(state: ^state_t) -> bool {
	return(
		state.max_w > 0 &&
		state.max_h > 0 &&
		state.shm_pool_size > 0 &&
		state.wl_compositor != 0 &&
		state.wl_shm != 0 &&
		state.xdg_wm_base != 0 &&
		state.wl_surface == 0 \
	)
}

initialize_surface :: proc(state: ^state_t) {
	assert(state.state == .STATE_NONE)
	create_shared_memory_file(state)

	state.wayland_current_id += 1
	err := wl_compositor.create_surface(
		state.socket_fd,
		state.wl_compositor,
		state.wayland_current_id,
	)
	if err != nil do os.exit(int(err))
	state.wl_surface = state.wayland_current_id
	register_event_handler(state, state.wl_surface, &wl_surface_handlers, wl_surface.handle_event)

	state.wayland_current_id += 1
	err = xdg_wm_base.get_xdg_surface(
		state.socket_fd,
		state.xdg_wm_base,
		state.wayland_current_id,
		state.wl_surface,
	)
	if err != nil do os.exit(int(err))
	state.xdg_surface = state.wayland_current_id
	register_event_handler(
		state,
		state.xdg_surface,
		&xdg_surface_handlers,
		xdg_surface.handle_event,
	)

	state.wayland_current_id += 1
	err = xdg_surface.get_toplevel(state.socket_fd, state.xdg_surface, state.wayland_current_id)
	if err != nil do os.exit(int(err))
	state.xdg_toplevel = state.wayland_current_id
	register_event_handler(
		state,
		state.xdg_toplevel,
		&xdg_toplevel_handlers,
		xdg_toplevel.handle_event,
	)
	err = xdg_toplevel.set_min_size(state.socket_fd, state.xdg_toplevel, 50, 50)
	if err != nil do os.exit(int(err))

	err = wl_surface.commit(state.socket_fd, state.wl_surface)
	if err != nil do os.exit(int(err))

	state.wayland_current_id += 1
	err = wl_shm.create_pool(
		state.socket_fd,
		state.wl_shm,
		state.wayland_current_id,
		state.shm_fd,
		i32(state.shm_pool_size),
	)
	if err != nil do os.exit(int(err))
	state.wl_shm_pool = state.wayland_current_id
	state.buffer_ready = true
}

draw_next_frame :: proc(state: ^state_t) {
	assert(state.wl_surface != 0)
	assert(state.xdg_surface != 0)
	assert(state.xdg_toplevel != 0)
	assert(state.shm_pool_data != nil)
	assert(state.shm_pool_size != 0)
	assert(state.buffer_ready)

	fmt.printfln("Drawing next frame")

	if state.w != state.buf_w || state.h != state.buf_h {
		if state.wl_buffer != 0 {
			err := wl_buffer.destroy(state.socket_fd, state.wl_buffer)
			if err != nil do os.exit(int(err))
			// Keep the handler registered until the compositor sends on_release
		}
		state.wayland_current_id += 1
		err := wl_shm_pool.create_buffer(
			state.socket_fd,
			state.wl_shm_pool,
			state.wayland_current_id,
			0,
			i32(state.w),
			i32(state.h),
			i32(state.w * color_channels),
			wl_shm.Format.Xrgb8888,
		)
		if err != nil do os.exit(int(err))
		state.wl_buffer = state.wayland_current_id
		state.buf_w = state.w
		state.buf_h = state.h
		register_event_handler(state, state.wl_buffer, &wl_buffer_handlers, wl_buffer.handle_event)
	}

	if state.w < 10 || state.h < 10 {
		state.state = .STATE_SURFACE_ATTACHED
		fmt.eprintfln("State is to small to safely draw the next frame")
		return
	}

	pixels := ([^]u32)(state.shm_pool_data)
	for y: u32 = 0; y < state.h; y += 1 {
		for x: u32 = 0; x < state.w; x += 1 {
			r, g, b: u8
			x_prime := x * 10 / state.w
			y_prime := y * 10 / state.h
			r = u8((x_prime + y_prime) % 2) * 255
			g = u8((x_prime + y_prime) % 2) * 255
			b = u8((x_prime + y_prime) % 2) * 255
			pixels[y * state.w + x] = (u32(r) << 16) | (u32(g) << 8) | u32(b)
		}
	}

	err: linux.Errno
	err = wl_surface.attach(state.socket_fd, state.wl_surface, state.wl_buffer, 0, 0)
	if err != nil do os.exit(int(err))
	err = wl_surface.damage_buffer(
		state.socket_fd,
		state.wl_surface,
		0,
		0,
		i32(state.w),
		i32(state.h),
	)
	if err != nil do os.exit(int(err))
	err = wl_surface.commit(state.socket_fd, state.wl_surface)
	if err != nil do os.exit(int(err))

	state.buffer_ready = false

	state.state = .STATE_SURFACE_ATTACHED
}

handle_signal :: proc "c" (sig: posix.Signal) {
	#partial switch sig {
	case .SIGTERM, .SIGINT:
		running = false
	}
}

set_dimensions :: proc(state: ^state_t, w: u32, h: u32) {
	assert(w < state.max_w)
	assert(h < state.max_h)
	state.w = w
	state.h = h

	state.stride = state.w * color_channels
}

main :: proc() {
	sa := posix.sigaction_t {
		sa_handler = handle_signal,
	}
	posix.sigaction(.SIGINT, &sa, nil)
	posix.sigaction(.SIGTERM, &sa, nil)

	socket_fd := wayland_display_connect()

	state: state_t = {
		wayland_current_id = 1,
		socket_fd          = socket_fd,
	}

	register_event_handler(
		&state,
		wayland_display_object_id,
		&wl_display_handlers,
		wl_display.handle_event,
	)

	state.wayland_current_id += 1
	err := wl_display.get_registry(socket_fd, wayland_display_object_id, state.wayland_current_id)
	if err != nil do os.exit(int(err))
	state.wl_registry = state.wayland_current_id
	register_event_handler(
		&state,
		state.wl_registry,
		&wl_registry_handlers,
		wl_registry.handle_event,
	)

	for running {
		wayland_handle_messages(&state)

		if (can_initialize_surface(&state)) {
			initialize_surface(&state)
		}

		if (state.wl_shm_pool > 0 &&
			   state.w > 0 &&
			   state.h > 0 &&
			   state.buffer_ready &&
			   state.state == .STATE_SURFACE_ACKED_CONFIGURE) {
			draw_next_frame(&state)
		}
	}

	fmt.println("Got termination signal. Terminating...")
	if (state.shm_pool_data != nil) do cleanup_shared_memory_file(&state)
	wayland_display_connection_cleanup(socket_fd)
}
