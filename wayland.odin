package Main

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/linux"
import "core:sys/posix"

roundup_4 :: proc(n: $T) -> T where intrinsics.type_is_numeric(T) {
	return T(int((n) + 3) & -4)
}

cstring_len :: proc(s: $T) -> int {
	return size_of(s) - 1
}

wayland_current_id: u32 = 1

wayland_display_object_id: u32 : 1
wayland_wl_registry_event_global: u16 : 0
wayland_shm_pool_event_format: u16 : 0
wayland_wl_buffer_event_release: u16 : 0
wayland_xdg_wm_base_event_ping: u16 : 0
wayland_xdg_toplevel_event_configure: u16 : 0
wayland_xdg_toplevel_event_close: u16 : 1
wayland_xdg_surface_event_configure: u16 : 0
wayland_wl_display_get_registry_opcode: u16 : 1
wayland_wl_registry_bind_opcode: u16 : 0
wayland_wl_compositor_create_surface_opcode: u16 : 0
wayland_xdg_wm_base_pong_opcode: u16 : 3
wayland_xdg_surface_ack_configure_opcode: u16 : 4
wayland_wl_shm_create_pool_opcode: u16 : 0
wayland_xdg_wm_base_get_xdg_surface_opcode: u16 : 2
wayland_wl_shm_pool_create_buffer_opcode: u16 : 0
wayland_wl_surface_attach_opcode: u16 : 1
wayland_xdg_surface_get_toplevel_opcode: u16 : 1
wayland_wl_surface_commit_opcode: u16 : 6
wayland_wl_display_error_event: u16 : 0
wayland_format_xrgb8888: u32 : 1
wayland_header_size: u16 : 8
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

	// fd := posix.socket(.UNIX, .STREAM, {})
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

buf_writer_t :: struct($N: int) {
	buf:                   [N]u8,
	buf_size:              int,
	announced_size_offset: int,
}

buf_writer_initialize :: proc(writer: ^buf_writer_t($N), object_id: u32, opcode: u16) {
	// We write these manually because we don't want it to affect the announced
	// size
	buf_write(u32, &writer.buf[0], &writer.buf_size, size_of(writer.buf), object_id)
	buf_write(u16, &writer.buf[0], &writer.buf_size, size_of(writer.buf), opcode)

	writer.announced_size_offset = writer.buf_size
	buf_write(u16, &writer.buf[0], &writer.buf_size, size_of(writer.buf), wayland_header_size)

	assert(buf_writer_announced_size(writer)^ == wayland_header_size)
}

buf_writer_announced_size :: proc(writer: ^buf_writer_t($N)) -> ^u16 {
	return (^u16)(mem.ptr_offset(&writer.buf[0], writer.announced_size_offset))
}

buf_writer_send :: proc(writer: ^buf_writer_t($N), fd: linux.Fd) -> linux.Errno {
	announced_size := buf_writer_announced_size(writer)^
	assert(roundup_4(announced_size) == announced_size)
	bytes_sent, send_err := linux.send(fd, writer.buf[:writer.buf_size], {})
	assert(bytes_sent == writer.buf_size)
	return send_err
}

buf_write_unsigned_int :: proc(
	$T: typeid,
	buf: ^u8,
	buf_size: ^int,
	buf_cap: int,
	x: T,
) where intrinsics.type_is_numeric(T) &&
	intrinsics.type_is_unsigned(T) {
	destination := mem.ptr_offset(buf, buf_size^)

	assert(buf_size^ + size_of(x) <= buf_cap)
	assert(uintptr(destination) % size_of(x) == 0)

	(^T)(destination)^ = x
	buf_size^ += size_of(T)
}

buf_write_unsigned_int_writer :: proc(
	$T: typeid,
	writer: ^buf_writer_t($N),
	x: T,
) where intrinsics.type_is_numeric(T) &&
	intrinsics.type_is_unsigned(T) {
	buf_write_unsigned_int(T, &writer.buf[0], &writer.buf_size, size_of(writer.buf), x)
	buf_writer_announced_size(writer)^ += size_of(x)
}

buf_write_string :: proc($T: typeid/string, buf: ^u8, buf_size: ^int, buf_cap: int, src: T) {
	assert(buf_size^ + len(src) <= buf_cap)

	// a cstring must be written here, this should probably be made more robust
	str_len := u32(len(src))
	buf_write(u32, buf, buf_size, buf_cap, str_len)
	mem.copy(mem.ptr_offset(buf, buf_size^), raw_data(src[:]), roundup_4(int(str_len)))
	buf_size^ += roundup_4(len(src))
}

buf_write_string_writer :: proc($T: typeid/string, writer: ^buf_writer_t($N), src: T) {
	buf_write_string(T, &writer.buf[0], &writer.buf_size, size_of(writer.buf), src)
	buf_writer_announced_size(writer)^ += u16(size_of(u32) + roundup_4(len(src)))
}

buf_write :: proc {
	buf_write_string,
	buf_write_string_writer,
	buf_write_unsigned_int,
	buf_write_unsigned_int_writer,
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

buf_read_n :: proc(buf: ^^u8, buf_size: ^int, dst: ^u8, n: int) {
	assert(buf_size^ >= n)

	mem.copy(dst, buf^, n)
	buf^ = mem.ptr_offset(buf^, n)
	buf_size^ -= n
}

buf_read :: proc {
	buf_read_unsigned_int,
	buf_read_n,
}

wayland_wl_display_get_registry :: proc(fd: linux.Fd) -> u32 {
	writer: buf_writer_t(128)
	buf_writer_initialize(
		&writer,
		wayland_display_object_id,
		wayland_wl_display_get_registry_opcode,
	)

	wayland_current_id += 1
	buf_write(u32, &writer, wayland_current_id)

	send_err := buf_writer_send(&writer, fd)
	if (send_err != nil) {
		fmt.eprint(
			"get_registry message failed to send to wl_display@%d",
			wayland_display_object_id,
		)
		os.exit(int(send_err))
	}

	fmt.printfln(
		"-> wl_display@%d.get_registry: wl_registry=%d",
		wayland_display_object_id,
		wayland_current_id,
	)

	return wayland_current_id
}

wayland_wl_registry_bind :: proc(
	fd: linux.Fd,
	registry: u32,
	name: u32,
	interface: string,
	version: u32,
) -> u32 {
	writer: buf_writer_t(512)
	buf_writer_initialize(&writer, registry, wayland_wl_registry_bind_opcode)

	buf_write(u32, &writer, name)
	buf_write(string, &writer, interface)
	buf_write(u32, &writer, version)

	wayland_current_id += 1
	buf_write(u32, &writer, wayland_current_id)

	send_err := buf_writer_send(&writer, fd)
	if (send_err != nil) {
		fmt.eprintfln("bind message failed to send to wl_registry@%d", registry)
		os.exit(int(send_err))
	}

	fmt.printfln(
		"-> wl_registry@%d.bind: name=%d interface=%s version=%d",
		registry,
		name,
		interface,
		version,
	)

	return wayland_current_id

}

wayland_wl_compositor_create_surface :: proc(fd: linux.Fd, state: ^state_t) -> u32 {
	assert(state.wl_compositor > 0)

	writer: buf_writer_t(128)
	buf_writer_initialize(
		&writer,
		state.wl_compositor,
		wayland_wl_compositor_create_surface_opcode,
	)

	wayland_current_id += 1
	buf_write(u32, &writer, wayland_current_id)

	send_err := buf_writer_send(&writer, fd)
	if (send_err != nil) {
		fmt.eprint(
			"create_surface message failed to send to wl_compositor@%d",
			state.wl_compositor,
		)
		os.exit(int(send_err))
	}

	fmt.printfln(
		"-> wl_compositor@%d.create_surface: wl_surface=%d",
		state.wl_compositor,
		wayland_current_id,
	)

	return wayland_current_id

}

create_shared_memory_file :: proc(size: u64, state: ^state_t) {
	fd, memfd_err := linux.memfd_create("shm_file", {})

	if fd == -1 || memfd_err != nil {
		fmt.eprintln("open failed")
		os.exit(int(memfd_err))
	}

	ftruncate_err := linux.ftruncate(fd, i64(size))
	if ftruncate_err != nil {
		fmt.eprintln("ftruncate failed")
		os.exit(int(ftruncate_err))
	}

	// this needs to be mmunmaped and closed if the screen is resized and this
	// function is used to create a new memory file
	data, mmap_err := linux.mmap(uintptr(0), uint(size), {.READ, .WRITE}, {.SHARED}, fd)

	if mmap_err != nil {
		fmt.eprintln("mmap failed")
		os.exit(int(mmap_err))
	}

	state.shm_pool_data = (^u8)(data)
	assert(state.shm_pool_data != (^u8)(~uintptr(0)))
	assert(state.shm_pool_data != nil)
	state.shm_fd = fd
}

wayland_xdg_wm_base_pong :: proc(fd: linux.Fd, state: ^state_t, ping: u32) {
	assert(state.xdg_wm_base > 0)
	assert(state.wl_surface > 0)

	writer: buf_writer_t(128)
	buf_writer_initialize(&writer, state.xdg_wm_base, wayland_xdg_wm_base_pong_opcode)

	buf_write(u32, &writer, ping)

	send_err := buf_writer_send(&writer, fd)
	if (send_err != nil) {
		fmt.eprint("pong message failed to send to xdg_wm_base@%d", state.xdg_wm_base)
		os.exit(int(send_err))
	}

	fmt.printfln("-> xdg_wm_base@%d.pong: ping=%d", state.xdg_wm_base, ping)
}

wayland_xdg_surface_ack_configure :: proc(fd: linux.Fd, state: ^state_t, configure: u32) {
	assert(state.xdg_surface > 0)

	writer: buf_writer_t(128)
	buf_writer_initialize(&writer, state.xdg_surface, wayland_xdg_surface_ack_configure_opcode)

	buf_write(u32, &writer, configure)

	send_err := buf_writer_send(&writer, fd)
	if (send_err != nil) {
		fmt.eprint("ack_configure message failed to send to xdg_surface@%d", state.xdg_surface)
		os.exit(int(send_err))
	}

	fmt.printfln("-> xdg_surface@%d.ack_configure: configure=%d", state.xdg_surface, configure)
}

wayland_wl_shm_create_pool :: proc(fd: linux.Fd, state: ^state_t) -> u32 {
	assert(state.shm_pool_size > 0)

	writer: buf_writer_t(128)
	buf_writer_initialize(&writer, state.wl_shm, wayland_wl_shm_create_pool_opcode)

	wayland_current_id += 1
	buf_write(u32, &writer, wayland_current_id)
	buf_write(u32, &writer, state.shm_pool_size)
	msg := &writer.buf[0]
	msg_size := writer.buf_size


	// #define CMSG_ALIGN(len) (((len) + sizeof (size_t) - 1) \
	// 			 & (size_t) ~(sizeof (size_t) - 1))
	// #define CMSG_SPACE(len) (CMSG_ALIGN (len) \
	// 			 + CMSG_ALIGN (sizeof (struct cmsghdr)))
	// #define CMSG_LEN(len)   (CMSG_ALIGN (sizeof (struct cmsghdr)) + (len))
	CMSG_ALIGN :: proc(len: $T) -> T {
		return (len + size_of(u64) - 1) & (~(int(size_of(u64) - 1)))
	}
	CMSG_SPACE :: proc(len: $T) -> T {
		return CMSG_ALIGN(len) + CMSG_ALIGN(size_of(posix.cmsghdr))
	}
	CMSG_LEN :: proc(len: $T) -> T {
		return len + CMSG_ALIGN(size_of(posix.cmsghdr))
	}

	buf: [128]u8

	io := posix.iovec {
		iov_base = msg,
		iov_len  = uint(msg_size),
	}

	socket_msg := posix.msghdr {
		msg_iov        = &io,
		msg_iovlen     = 1,
		msg_control    = &buf[0],
		msg_controllen = size_of(buf),
	}

	cmsg := posix.CMSG_FIRSTHDR(&socket_msg)
	cmsg.cmsg_level = posix.SOL_SOCKET
	cmsg.cmsg_type = posix.SCM_RIGHTS
	cmsg.cmsg_len = uint(CMSG_LEN(size_of(state.shm_fd)))

	(^int)(posix.CMSG_DATA(cmsg))^ = int(state.shm_fd)
	socket_msg.msg_controllen = uint(CMSG_SPACE(size_of(state.shm_fd)))

	bytes_sent := posix.sendmsg((posix.FD)(fd), &socket_msg, {})
	if bytes_sent != msg_size {
		fmt.eprintfln("create_pool message failed to send to wl_shm@%d", state.wl_shm)
		os.exit(int(posix.errno()))
	}

	fmt.printfln("-> wl_shm@%d.create_pool: wl_shm_pool=%d", state.wl_shm, wayland_current_id)

	return wayland_current_id
}

wayland_wl_shm_pool_create_buffer :: proc(fd: linux.Fd, state: ^state_t) -> u32 {
	assert(state.wl_shm_pool > 0)

	writer: buf_writer_t(128)
	buf_writer_initialize(&writer, state.wl_shm_pool, wayland_wl_shm_pool_create_buffer_opcode)

	wayland_current_id += 1
	buf_write(u32, &writer, wayland_current_id)

	offset: u32 = 0
	buf_write(u32, &writer, offset)
	buf_write(u32, &writer, state.w)
	buf_write(u32, &writer, state.h)
	buf_write(u32, &writer, state.stride)
	buf_write(u32, &writer, wayland_format_xrgb8888)

	send_err := buf_writer_send(&writer, fd)
	if (send_err != nil) {
		fmt.eprint("create_buffer message failed to send to wl_shm_pool@%d", state.wl_shm_pool)
		os.exit(int(send_err))
	}

	fmt.printfln(
		"-> wl_shm_pool@%d.create_buffer: wl_buffer=%d",
		state.wl_shm_pool,
		wayland_current_id,
	)

	return wayland_current_id
}

wayland_xdg_wm_base_get_xdg_surface :: proc(fd: linux.Fd, state: ^state_t) -> u32 {
	assert(state.xdg_wm_base > 0)
	assert(state.wl_surface > 0)

	writer: buf_writer_t(128)
	buf_writer_initialize(&writer, state.xdg_wm_base, wayland_xdg_wm_base_get_xdg_surface_opcode)

	wayland_current_id += 1
	buf_write(u32, &writer, wayland_current_id)
	buf_write(u32, &writer, state.wl_surface)

	send_err := buf_writer_send(&writer, fd)
	if (send_err != nil) {
		fmt.eprint("get_xdg_surface message failed to send to xdg_wm_base@%d", wayland_current_id)
		os.exit(int(send_err))
	}

	fmt.printfln(
		"-> xdg_wm_base@%d.get_xdg_surface: xdg_surface=%d wl_surface=%d",
		state.xdg_wm_base,
		wayland_current_id,
		state.wl_surface,
	)

	return wayland_current_id
}

wayland_wl_surface_attach :: proc(fd: linux.Fd, state: ^state_t) {
	assert(state.wl_surface > 0)
	assert(state.wl_buffer > 0)

	writer: buf_writer_t(128)
	buf_writer_initialize(&writer, state.wl_surface, wayland_wl_surface_attach_opcode)

	buf_write(u32, &writer, state.wl_buffer)

	x, y: u32
	buf_write(u32, &writer, x)
	buf_write(u32, &writer, y)

	send_err := buf_writer_send(&writer, fd)
	if (send_err != nil) {
		fmt.eprint("attach message failed to send to wl_buffer@%d", state.wl_buffer)
		os.exit(int(send_err))
	}

	fmt.printfln("-> wl_surface@%d.attach: wl_buffer=%d", state.wl_surface, state.wl_buffer)
}

wayland_xdg_surface_get_toplevel :: proc(fd: linux.Fd, state: ^state_t) -> u32 {
	assert(state.wl_surface > 0)

	writer: buf_writer_t(128)
	buf_writer_initialize(&writer, state.xdg_surface, wayland_xdg_surface_get_toplevel_opcode)

	wayland_current_id += 1
	buf_write(u32, &writer, wayland_current_id)

	send_err := buf_writer_send(&writer, fd)
	if (send_err != nil) {
		fmt.eprint("get_toplevel message failed to send to xdg_surface@%d", state.xdg_surface)
		os.exit(int(send_err))
	}

	fmt.printfln(
		"-> xdg_surface@%d.get_toplevel: xdg_toplevel=%d",
		state.xdg_surface,
		wayland_current_id,
	)

	return wayland_current_id
}

wayland_wl_surface_commit :: proc(fd: linux.Fd, state: ^state_t) {
	assert(state.wl_surface > 0)

	writer: buf_writer_t(128)
	buf_writer_initialize(&writer, state.wl_surface, wayland_wl_surface_commit_opcode)

	send_err := buf_writer_send(&writer, fd)
	if (send_err != nil) {
		fmt.eprint("commit message failed to send to wl_surface@%d", state.wl_surface)
		os.exit(int(send_err))
	}

	fmt.printfln("-> wl_surface@%d.commit: ", state.wl_surface)
}

wayland_handle_message :: proc(fd: linux.Fd, state: ^state_t, msg: ^^u8, msg_len: ^int) {
	assert(msg_len^ >= 8)

	object_id := buf_read(msg, msg_len, u32)
	assert(object_id <= wayland_current_id)

	opcode := buf_read(msg, msg_len, u16)

	announced_size := buf_read(msg, msg_len, u16)
	assert(roundup_4(announced_size) <= announced_size)

	header_size: u16 = size_of(object_id) + size_of(opcode) + size_of(announced_size)
	assert(int(announced_size) <= int(header_size) + msg_len^)

	if (object_id == state.wl_registry && opcode == wayland_wl_registry_event_global) {
		name := buf_read(msg, msg_len, u32)
		interface_len := buf_read(msg, msg_len, u32)
		padded_interface_len := roundup_4(int(interface_len))

		interface_buf: [512]u8
		assert(padded_interface_len <= cstring_len(interface_buf))

		buf_read(msg, msg_len, &interface_buf[0], padded_interface_len)
		assert(interface_buf[interface_len - 1] == 0)

		interface := string(interface_buf[:interface_len]) // -1 to strip null terminator
		version := buf_read(msg, msg_len, u32)

		fmt.printfln(
			"<- wl_registry@%d.global: name=%d interface=%s version=%d",
			state.wl_registry,
			name,
			interface,
			version,
		)

		if interface == "wl_shm\000" {
			state.wl_shm = wayland_wl_registry_bind(
				fd,
				state.wl_registry,
				name,
				interface,
				version,
			)
		} else if interface == "xdg_wm_base\000" {
			state.xdg_wm_base = wayland_wl_registry_bind(
				fd,
				state.wl_registry,
				name,
				interface,
				version,
			)
		} else if interface == "wl_compositor\000" {
			state.wl_compositor = wayland_wl_registry_bind(
				fd,
				state.wl_registry,
				name,
				interface,
				version,
			)

		}

		return
	} else if (object_id == wayland_display_object_id &&
		   opcode == wayland_wl_display_error_event) {
		target_obejct_id := buf_read(msg, msg_len, u32)
		code := buf_read(msg, msg_len, u32)
		error: [512]u8
		error_len := buf_read(msg, msg_len, u32)
		buf_read(msg, msg_len, &error[0], roundup_4(int(error_len)))
		message := string(error[:error_len - 1]) // -1 to strip null terminator

		fmt.eprintfln(
			"fatal error: target_object_id=%d code=%d error=%s",
			target_obejct_id,
			code,
			message,
		)
		os.exit(int(linux.Errno.EINVAL))
	} else if object_id == state.wl_shm && opcode == wayland_shm_pool_event_format {
		format := buf_read(msg, msg_len, u32)
		fmt.printfln("<- wl_shm: format=%#x", format)

		return
	} else if (object_id == state.xdg_wm_base && opcode == wayland_xdg_wm_base_event_ping) {
		ping := buf_read(msg, msg_len, u32)

		fmt.printfln("<- xdg_wm_base@%d.ping: ping=%d", state.xdg_wm_base, ping)
		wayland_xdg_wm_base_pong(fd, state, ping)

		return
	} else if (object_id == state.xdg_toplevel && opcode == wayland_xdg_toplevel_event_configure) {
		w, h, len: u32 =
			buf_read(msg, msg_len, u32), buf_read(msg, msg_len, u32), buf_read(msg, msg_len, u32)
		buf: [256]u8
		assert(len < size_of(buf))
		buf_read(msg, msg_len, &buf[0], int(len))

		fmt.printfln(
			"<- xdg_toplevel@%d.configure: w=%d h=%d states[%d]",
			state.xdg_toplevel,
			w,
			h,
			len,
		)

		return
	} else if (object_id == state.xdg_surface && opcode == wayland_xdg_surface_event_configure) {
		configure := buf_read(msg, msg_len, u32)
		fmt.printf("<- xdg_surface@%d.configure: configure=%d\n", state.xdg_surface, configure)
		wayland_xdg_surface_ack_configure(fd, state, configure)
		state.state = .STATE_SURFACE_ACKED_CONFIGURE

		return
	}

	fmt.eprintfln(
		"unknown event: object_id=%d opcode=%d size=%d state=%v, skipping...",
		object_id,
		opcode,
		announced_size,
		state,
	)

	remaining := announced_size - header_size
	msg^ = mem.ptr_offset(msg^, remaining)
	msg_len^ -= int(remaining)
}

main :: proc() {
	fd := wayland_display_connect()

	state: state_t = {
		wl_registry = wayland_wl_display_get_registry(fd),
		w           = 117,
		h           = 150,
		stride      = 117 * color_channels,
	}

	state.shm_pool_size = state.h * state.stride
	create_shared_memory_file(u64(state.shm_pool_size), &state)

	for {
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

			state.wl_surface = wayland_wl_compositor_create_surface(fd, &state)
			state.xdg_surface = wayland_xdg_wm_base_get_xdg_surface(fd, &state)
			state.xdg_toplevel = wayland_xdg_surface_get_toplevel(fd, &state)
			wayland_wl_surface_commit(fd, &state)
		}

		if (state.state == .STATE_SURFACE_ACKED_CONFIGURE) {
			assert(state.wl_surface != 0)
			assert(state.xdg_surface != 0)
			assert(state.xdg_toplevel != 0)

			if (state.wl_shm_pool == 0) {
				state.wl_shm_pool = wayland_wl_shm_create_pool(fd, &state)
			}
			if (state.wl_buffer == 0) {
				state.wl_buffer = wayland_wl_shm_pool_create_buffer(fd, &state)
			}

			assert(state.shm_pool_data != nil)
			assert(state.shm_pool_size != 0)

			pixels := ([^]u32)(state.shm_pool_data)
			for i: u32 = 0; i < state.w * state.h; i += 1 {
				x := u8(i % state.w)
				y := u8(i / state.w)

				r: u8 = (((x / 10) + (y / 10)) % 2) * 255
				g: u8 = (((x / 10) + (y / 10)) % 2) * 255
				b: u8 = (((x / 10) + (y / 10)) % 2) * 255

				pixels[i] = (u32(r) << 16) | (u32(g) << 8) | u32(b)
			}

			wayland_wl_surface_attach(fd, &state)
			wayland_wl_surface_commit(fd, &state)

			state.state = .STATE_SURFACE_ATTACHED
		}
	}
}
