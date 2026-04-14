package Main

import buf_reader "./buf_reader"
import cmsg "./cmsg"
import "core:fmt"
import "core:mem"
import "core:sys/linux"

wayland_handle_messages :: proc(state: ^state_t) -> Errno {
	read_buf: [4096]u8
	cmsg_buf: [128]u8
	iov := [1]linux.IO_Vec{{base = ([^]byte)(&read_buf[0]), len = size_of(read_buf)}}
	socket_msg := linux.Msg_Hdr {
		iov     = iov[:],
		control = cmsg_buf[:],
	}

	read_bytes, recv_err := linux.recvmsg(state.wl_display.socket, &socket_msg, {.CMSG_CLOEXEC})

	if recv_err == .EINTR {
		return nil
	} else if read_bytes == -1 || recv_err != nil {
		fmt.eprintln("Failed to receive new events")
		return recv_err
	} else if read_bytes == 0 {
		fmt.eprintln("Compositor closed the connection")
		return .ECONNRESET
	}

	fmt.printfln("Received %d bytes", read_bytes)

	// Extract fds from ancillary data (SCM_RIGHTS).
	// Wayland guarantees all fds in a recvmsg batch are consumed by the
	// messages in that same batch, so a local array is sufficient.
	fd_buf: [dynamic]linux.Fd
	fd_buf.allocator = context.temp_allocator
	reserve(&fd_buf, 4)
	control := socket_msg.control // kernel updates controllen on return
	cmsg_hdr_size := cmsg.CMSG_ALIGN(size_of(cmsg.Cmsghdr))
	for len(control) >= size_of(cmsg.Cmsghdr) {
		cmsg_hdr := (^cmsg.Cmsghdr)(raw_data(control))
		cmsg_len := int(cmsg_hdr.cmsg_len)
		if cmsg_hdr.cmsg_level == i32(linux.SOL_SOCKET) && cmsg_hdr.cmsg_type == cmsg.SCM_RIGHTS {
			n := (cmsg_len - cmsg_hdr_size) / size_of(linux.Fd)
			fds_raw := ([^]linux.Fd)(mem.ptr_offset(raw_data(control), cmsg_hdr_size))
			for i in 0 ..< n {
				append(&fd_buf, fds_raw[i])
			}
		}
		aligned_len := cmsg.CMSG_ALIGN(cmsg_len)
		if aligned_len >= len(control) do break
		control = control[aligned_len:]
	}
	fds := fd_buf[:]

	msg := &read_buf[0]
	msg_len := int(read_bytes)
	for msg_len > 0 {
		wayland_handle_message(state, &msg, &msg_len, &fds)
	}
	assert(len(fds) == 0, "not all fds were consumed by messages in this batch")
	return state.last_err
}

wayland_handle_message :: proc(state: ^state_t, msg: ^^u8, msg_len: ^int, fds: ^[]linux.Fd) {
	assert(msg_len^ >= 8)

	object_id := buf_reader.read_u32(msg, msg_len)
	assert(object_id <= state.wl_display.next_id)
	opcode := buf_reader.read_u16(msg, msg_len)
	announced_size := buf_reader.read_u16(msg, msg_len)

	header_size: u16 = size_of(object_id) + size_of(opcode) + size_of(announced_size)
	assert(announced_size % 4 == 0)
	assert(int(announced_size) <= int(header_size) + msg_len^)

	body_size := int(announced_size) - int(header_size)
	msg_len_before_body := msg_len^

	idx, object_found := find_event_handler(state.event_handlers[:], object_id)

	if object_found {
		handler := state.event_handlers[idx]
		handler.handle_event(
			object_id,
			opcode,
			msg,
			msg_len,
			handler.event_handlers,
			handler.user_data,
			fds,
		)
	} else {
		fmt.eprintfln(
			"unknown event: object_id=%d opcode=%d size=%d skipping...",
			object_id,
			opcode,
			announced_size,
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
